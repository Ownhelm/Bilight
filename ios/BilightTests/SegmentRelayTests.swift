import XCTest

@testable import Bilight

final class SegmentRelayTests: XCTestCase {
    final class Upstream: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0, finished = false
        var mediaRequests: Int { lock.withLock { count } }
        var mediaFinished: Bool { lock.withLock { finished } }
        func requested() { lock.withLock { count += 1 } }
        func completed() { lock.withLock { finished = true } }
    }
    final class SegmentProtocol: URLProtocol, @unchecked Sendable {
        static var upstream = Upstream()
        enum Mode { case valid, truncated, invalidType }
        static var mode = Mode.valid
        static let index: Data = {
            func bytes(_ n: UInt64, _ size: Int) -> Data { Data((0..<size).reversed().map { UInt8((n >> ($0*8)) & 255) }) }
            var data = bytes(44, 4) + Data("sidx".utf8)
            for (value, size): (UInt64, Int) in [(0, 4), (1, 4), (1000, 4), (0, 4), (0, 4), (0, 2), (1, 2), (1024, 4), (6000, 4), (0x90000000, 4)] { data += bytes(value, size) }
            return data
        }()
        private let lock = NSLock()
        private var stopped = false
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let raw = request.value(forHTTPHeaderField: "Range"),
                let range = ByteSegment.range(String(raw.dropFirst(6)))
            else { client?.urlProtocol(self, didFailWithError: BiliFailure.invalid); return }
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let body = range == (16...59) ? Self.index : Data((range.lowerBound...range.upperBound).map { UInt8($0 % 251) })
            let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: [
                "Content-Type": Self.mode == .invalidType && range != (16...59) ? "text/html" : "video/mp4", "Content-Length": "\(body.count)",
                "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/1084",
            ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if range == (16...59) {
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                let upstream = Self.upstream
                let mode = Self.mode
                upstream.requested()
                client?.urlProtocol(self, didLoad: body.prefix(512))
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                    guard !lock.withLock({ stopped }) else { return }
                    if mode != .truncated { client?.urlProtocol(self, didLoad: body.dropFirst(512)) }
                    upstream.completed()
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
        }
        override func stopLoading() { lock.withLock { stopped = true } }
    }
    func testRelayDeliversFirstBytesBeforeUpstreamFinishesAndReusesCompletedRange() async throws {
        let upstream = Upstream()
        SegmentProtocol.upstream = upstream
        SegmentProtocol.mode = .valid
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SegmentProtocol.self]
        let track = StreamTrack(id: 80, url: URL(string: "https://test.bilivideo.com/video.mp4")!, codecs: "avc1.640028", bandwidth: 1000, initialization: 0...15, index: 16...59)
        let playback = Playback(quality: 80, qualities: [], duration: 6, video: track)
        let stream = try await SegmentedStream.make(playback, configuration: configuration)
        defer { stream.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: stream.url.deletingLastPathComponent().appendingPathComponent("video.mp4"))
        request.timeoutInterval = 4
        request.setValue("bytes=60-1083", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        var iterator = bytes.makeAsyncIterator()
        let next = try await iterator.next()
        let first = try XCTUnwrap(next)
        XCTAssertFalse(upstream.mediaFinished, "The decoder must receive bytes while a large CDN fragment is still downloading")
        var received = Data([first])
        while let byte = try await iterator.next() { received.append(byte) }
        let expected = Data((60...1083).map { UInt8($0 % 251) })
        XCTAssertEqual(received, expected)
        let (again, _) = try await session.data(for: request)
        XCTAssertEqual(again, expected)
        XCTAssertEqual(upstream.mediaRequests, 1, "A completed range must not be downloaded again when AVKit rereads it")
    }
    func testRelayDoesNotCacheTruncatedSegmentsOrForwardErrorPages() async throws {
        for mode in [SegmentProtocol.Mode.truncated, .invalidType] {
            let upstream = Upstream()
            SegmentProtocol.upstream = upstream; SegmentProtocol.mode = mode
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SegmentProtocol.self]
            let track = StreamTrack(id: 80, url: URL(string: "https://test.bilivideo.com/video.mp4")!, codecs: "avc1.640028", bandwidth: 1000, initialization: 0...15, index: 16...59)
            let stream = try await SegmentedStream.make(Playback(quality: 80, qualities: [], duration: 6, video: track), configuration: configuration)
            let session = URLSession(configuration: .ephemeral)
            defer { stream.stop(); session.invalidateAndCancel() }
            var request = URLRequest(url: stream.url.deletingLastPathComponent().appendingPathComponent("video.mp4"))
            request.timeoutInterval = 4
            request.setValue("bytes=60-1083", forHTTPHeaderField: "Range")
            for _ in 0..<2 {
                do {
                    let (data, response) = try await session.data(for: request)
                    XCTAssertEqual(mode, .invalidType, "An incomplete media response must fail")
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
                    XCTAssertTrue(data.isEmpty)
                } catch {
                    XCTAssertEqual(mode, .truncated)
                }
            }
            XCTAssertEqual(upstream.mediaRequests, 2, "Invalid or partial data must never enter the completed-range cache")
        }
        SegmentProtocol.mode = .valid
    }
}
