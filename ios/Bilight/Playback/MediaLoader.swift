import AVFoundation
import UniformTypeIdentifiers

/// A per-asset HTTPS byte-range loader, entirely on iPhone. No local server or remote proxy.
final class MediaLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    private let source: URL
    private let queue = DispatchQueue(label: "app.bilight.media.\(UUID().uuidString)")
    private var pending: [Int: AVAssetResourceLoadingRequest] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 120
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue
        return URLSession(configuration: config, delegate: self, delegateQueue: operations)
    }()
    init(_ source: URL) {
        self.source = source
        super.init()
    }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host, url.port == nil || url.port == 443, url.user == nil,
            url.password == nil
        else { return false }
        return ["bilivideo.com", "bilivideo.cn", "hdslb.com"].contains { host == $0 || host.hasSuffix(".\($0)") }
    }
    func asset() -> AVURLAsset {
        let asset = AVURLAsset(
            url: URL(string: "bilight-stream://media/\(UUID().uuidString).mp4")!,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard Self.allowed(source) else {
            request.finishLoading(with: BiliFailure(code: "UNSAFE_MEDIA", message: "视频来源不受支持。"))
            return false
        }
        var input = URLRequest(url: source)
        input.setValue(BiliHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        input.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        if let range = request.dataRequest {
            let start = max(range.requestedOffset, range.currentOffset)
            let end =
                range.requestsAllDataToEndOfResource
                ? "" : "\(range.requestedOffset + Int64(range.requestedLength) - 1)"
            input.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        } else {
            input.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: input)
        pending[task.taskIdentifier] = request
        task.resume()
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        let ids = pending.filter { $0.value === request }.map(\.key)
        session.getAllTasks { tasks in for task in tasks where ids.contains(task.taskIdentifier) { task.cancel() } }
        for id in ids { pending[id] = nil }
    }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let request = pending[dataTask.taskIdentifier], let http = response as? HTTPURLResponse,
            [200, 206].contains(http.statusCode), let url = response.url, Self.allowed(url),
            ["video/mp4", "audio/mp4", "application/octet-stream"].contains(http.mimeType?.lowercased() ?? "")
        else {
            pending.removeValue(forKey: dataTask.taskIdentifier)?.finishLoading(
                with: BiliFailure(code: "MEDIA_UNAVAILABLE", message: "视频流读取失败，地址可能已过期，请重新加载。"))
            completionHandler(.cancel)
            return
        }
        let range = http.value(forHTTPHeaderField: "Content-Range")
        let length = range?.split(separator: "/").last.flatMap { Int64($0) } ?? http.expectedContentLength
        let expectedOffset = request.dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
        if http.statusCode == 206 {
            let start = range?.replacingOccurrences(of: "bytes ", with: "").split(separator: "-").first.flatMap {
                Int64($0)
            }
            guard start == expectedOffset, length > expectedOffset else {
                pending[dataTask.taskIdentifier] = nil
                request.finishLoading(with: BiliFailure.invalid)
                completionHandler(.cancel)
                return
            }
        }
        if http.statusCode == 200, let data = request.dataRequest, max(data.currentOffset, data.requestedOffset) > 0 {
            pending[dataTask.taskIdentifier] = nil
            request.finishLoading(with: BiliFailure.invalid)
            completionHandler(.cancel)
            return
        }
        if let info = request.contentInformationRequest {
            info.contentType = (http.mimeType == "audio/mp4" ? UTType.mpeg4Audio : UTType.mpeg4Movie).identifier
            info.contentLength = length
            info.isByteRangeAccessSupported =
                http.statusCode == 206 || http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes"
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pending[dataTask.taskIdentifier]?.dataRequest?.respond(with: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = pending.removeValue(forKey: task.taskIdentifier) else { return }
        if let error { request.finishLoading(with: error) } else { request.finishLoading() }
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, Self.allowed(url) else {
            completionHandler(nil)
            return
        }
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Cookie")
        next.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        completionHandler(next)
    }
    func invalidate() {
        queue.async {
            for request in self.pending.values { request.finishLoading(with: URLError(.cancelled)) }
            self.pending = [:]
            self.session.invalidateAndCancel()
        }
    }
}
