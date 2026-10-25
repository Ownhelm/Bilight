import Foundation
import Network

/// Only the loopback player can read these random resource IDs. Upstream URLs remain HTTPS and CDN restricted.
final class SegmentedStream: @unchecked Sendable {
    struct Resource {
        var track: StreamTrack
        var length: Int64
        var segments: [ByteSegment]
    }
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "app.bilight.segments")
    private let transport = SegmentTransport()
    private var listener: NWListener?
    private var startup: CheckedContinuation<Void, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var resources: [String: Resource] = [:]
    private var playlists: [String: Data] = [:]
    private(set) var url: URL!
    static func make(_ playback: Playback) async throws -> SegmentedStream {
        let stream = SegmentedStream()
        do {
            guard let video = playback.video else { throw BiliFailure.invalid }
            async let videoIndex = stream.transport.index(video)
            async let audioIndex = stream.transport.optionalIndex(playback.audio)
            let (v, a) = try await (videoIndex, audioIndex)
            NativeTrace.mark(
                .segmentReady,
                [
                    "videoSegments": v.segments.count, "audioSegments": a?.segments.count ?? 0,
                    "maxMB": Int(
                        (v.segments.map { $0.range.upperBound - $0.range.lowerBound + 1 }.max() ?? 0) / 1_000_000),
                ])
            try Task.checkCancellation()
            stream.resources["video.mp4"] = v
            stream.playlists["video.m3u8"] = ByteSegment.playlist(
                v.segments, initialization: video.initialization!, path: "video.mp4")
            let audio = playback.audio
            if let a, let track = audio {
                stream.resources["audio.mp4"] = a
                stream.playlists["audio.m3u8"] = ByteSegment.playlist(
                    a.segments, initialization: track.initialization!, path: "audio.mp4")
            }
            var master = "#EXTM3U\n#EXT-X-VERSION:7\n"
            if audio != nil {
                master +=
                    "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"原声\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n"
            }
            let codecs = video.codecs + (audio.map { "," + $0.codecs } ?? "")
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(video.bandwidth + (audio?.bandwidth ?? 0)),CODECS=\"\(codecs)\""
            if video.width > 0, video.height > 0 { master += ",RESOLUTION=\(video.width)x\(video.height)" }
            if audio != nil { master += ",AUDIO=\"audio\"" }
            master += "\nvideo.m3u8\n"
            stream.playlists["master.m3u8"] = Data(master.utf8)
            try await stream.start()
            return stream
        } catch {
            stream.stop()
            throw error
        }
    }
    private func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startup = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let pending = self.startup else { return }
                switch state {
                case .ready:
                    self.startup = nil
                    guard let port = listener.port else {
                        pending.resume(throwing: BiliFailure.invalid)
                        return
                    }
                    self.url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/master.m3u8")!
                    pending.resume()
                case .failed(let error):
                    self.startup = nil
                    pending.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.connections[ObjectIdentifier(connection)] = connection
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    if case .cancelled = state, let connection { self?.connections[ObjectIdentifier(connection)] = nil }
                }
                connection.start(queue: self.queue)
                self.receive(connection, buffer: Data())
            }
            queue.asyncAfter(deadline: .now() + 3) {
                if let pending = self.startup {
                    self.startup = nil
                    listener.cancel()
                    pending.resume(throwing: URLError(.timedOut))
                }
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self, error == nil, let data else {
                connection.cancel()
                return
            }
            let next = buffer + data
            guard next.count <= 8192 else {
                self.reject(connection, status: 431)
                return
            }
            if let text = String(data: next, encoding: .utf8), text.contains("\r\n\r\n") {
                self.serve(connection, header: text)
            } else if !ended {
                self.receive(connection, buffer: next)
            } else {
                connection.cancel()
            }
        }
    }
    private func serve(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, ["GET", "HEAD"].contains(request[0]) else {
            reject(connection, status: 405)
            return
        }
        let prefix = "/\(token)/"
        let path = String(request[1])
        guard path.hasPrefix(prefix), !path.dropFirst(prefix.count).contains("/") else {
            reject(connection, status: 404)
            return
        }
        let name = String(path.dropFirst(prefix.count))
        if let data = playlists[name] {
            let headers =
                "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(
                content: Data(headers.utf8) + (request[0] == "HEAD" ? Data() : data),
                completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        guard let resource = resources[name] else {
            reject(connection, status: 404)
            return
        }
        let rangeText = lines.first { $0.lowercased().hasPrefix("range:") }?.split(separator: ":", maxSplits: 1).last
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let text = rangeText, text.hasPrefix("bytes="), let range = ByteSegment.range(String(text.dropFirst(6))),
            range.upperBound < resource.length, range.upperBound - range.lowerBound < 128_000_000
        else {
            reject(connection, status: 416)
            return
        }
        let length = range.upperBound - range.lowerBound + 1
        let headers = Data(
            "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: \(length)\r\nContent-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(resource.length)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
                .utf8)
        if request[0] == "HEAD" {
            connection.send(content: headers, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        var input = SegmentTransport.request(resource.track.url, range: range)
        input.timeoutInterval = 25
        transport.session.downloadTask(with: input) { [weak self] location, response, error in
            guard let self, error == nil, let location,
                (try? SegmentTransport.validate(response, range: range, total: resource.length)) != nil,
                let handle = try? FileHandle(forReadingFrom: location),
                (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(length)
            else {
                self?.reject(connection, status: 502)
                return
            }
            self.queue.async {
                connection.send(
                    content: headers,
                    completion: .contentProcessed { error in
                        if error != nil {
                            try? handle.close()
                            connection.cancel()
                        } else {
                            self.send(handle, connection: connection, remaining: length)
                        }
                    })
            }
        }.resume()
    }
    private func send(_ handle: FileHandle, connection: NWConnection, remaining: Int64) {
        guard remaining > 0, let data = try? handle.read(upToCount: Int(min(remaining, 64 * 1024))), !data.isEmpty
        else {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(
            content: data,
            completion: .contentProcessed { error in
                if error != nil {
                    try? handle.close()
                    connection.cancel()
                } else {
                    self.send(handle, connection: connection, remaining: remaining - Int64(data.count))
                }
            })
    }
    private func reject(_ connection: NWConnection, status: Int) {
        connection.send(
            content: Data("HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
            completion: .contentProcessed { _ in connection.cancel() })
    }
    func stop() {
        transport.session.invalidateAndCancel()
        queue.async {
            self.listener?.cancel()
            self.connections.values.forEach { $0.cancel() }
            self.connections = [:]
        }
    }
}

private final class SegmentTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var session: URLSession!
    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func optionalIndex(_ track: StreamTrack?) async throws -> SegmentedStream.Resource? {
        guard let track else { return nil }
        return try await index(track)
    }
    static func request(_ url: URL, range: ClosedRange<Int64>) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        request.setValue(BiliHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        return request
    }
    static func validate(_ response: URLResponse?, range: ClosedRange<Int64>, total: Int64? = nil) throws -> Int64 {
        guard let http = response as? HTTPURLResponse, let url = http.url, MediaLoader.allowed(url),
            http.statusCode == 206,
            ["video/mp4", "audio/mp4", "application/octet-stream"].contains(http.mimeType?.lowercased() ?? ""),
            let value = http.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes "),
            let actual = ByteSegment.range(String(value.dropFirst(6).split(separator: "/").first ?? "")),
            actual == range,
            let size = Int64(value.split(separator: "/").last ?? ""), size > range.upperBound,
            total == nil || total == size
        else { throw BiliFailure(code: "SEGMENT_UNAVAILABLE", message: "视频分段读取失败，请重新获取地址。") }
        return size
    }
    func index(_ track: StreamTrack) async throws -> SegmentedStream.Resource {
        guard MediaLoader.allowed(track.url), let range = track.index, let initial = track.initialization,
            range.upperBound - range.lowerBound < 1_000_000, initial.lowerBound >= 0
        else { throw BiliFailure.invalid }
        let (bytes, response) = try await session.bytes(for: Self.request(track.url, range: range))
        let total = try Self.validate(response, range: range)
        let expected = Int(range.upperBound - range.lowerBound + 1)
        var data = Data()
        data.reserveCapacity(expected)
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= expected else { throw BiliFailure.invalid }
        }
        guard data.count == expected, initial.upperBound < total else { throw BiliFailure.invalid }
        return SegmentedStream.Resource(
            track: track, length: total,
            segments: try ByteSegment.parse(data, absoluteOffset: range.lowerBound, total: total))
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, MediaLoader.allowed(url) else {
            completionHandler(nil)
            return
        }
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Cookie")
        next.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        completionHandler(next)
    }
}
