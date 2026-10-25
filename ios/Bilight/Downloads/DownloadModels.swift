import Foundation

enum DownloadState: String, Codable {
    case queued, resolving, downloading, paused, merging, completed, failed
    var title: String {
        switch self {
        case .queued: "等待下载"
        case .resolving: "正在获取下载地址"
        case .downloading: "正在下载"
        case .paused: "已暂停"
        case .merging: "正在合并音视频"
        case .completed: "已下载"
        case .failed: "下载未完成"
        }
    }
}
struct DownloadFile: Codable {
    var role: String
    var url: URL
    var resumeData: Data?
    var received: Int64 = 0
    var expected: Int64 = 0
    var finished = false
}
struct DownloadRecord: Codable, Identifiable {
    var id: UUID
    var video: Video
    var part: VideoPart
    var quality: Int
    var qualityLabel: String
    var state: DownloadState = .queued
    var files: [DownloadFile] = []
    var message: String?
    var createdAt = Date()
    var interrupted = false
    var bytes: Int64 { files.reduce(0) { $0 + $1.received } }
    var expected: Int64 { files.reduce(0) { $0 + $1.expected } }
    var progress: Double? {
        guard expected > 0, files.allSatisfy({ $0.expected > 0 }) else { return nil }
        return min(state == .completed ? 1 : 0.99, Double(bytes) / Double(expected))
    }
    var fileName: String { "\(id.uuidString).mp4" }
    func fileName(_ role: String) -> String { "\(id.uuidString)-\(role).mp4" }
}
enum DownloadValidation {
    static func response(_ response: URLResponse?, size: Int64) throws {
        guard let http = response as? HTTPURLResponse, let url = http.url, MediaLoader.allowed(url),
            [200, 206].contains(http.statusCode),
            ["video/mp4", "audio/mp4", "application/octet-stream"].contains(http.mimeType?.lowercased() ?? ""), size > 0
        else { throw BiliFailure(code: "DOWNLOAD_RESPONSE", message: "下载地址已失效或视频不可读取，请重新下载以获取新地址。") }
        let total =
            http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) }
            ?? (http.statusCode == 200 ? http.expectedContentLength : -1)
        guard total <= 0 || total == size else {
            throw BiliFailure(code: "DOWNLOAD_INCOMPLETE", message: "下载文件不完整，请重新下载。")
        }
    }
}
