import Foundation

typealias JSON = [String: Any]
func obj(_ value: Any?) -> JSON { value as? JSON ?? [:] }
func list(_ value: Any?) -> [JSON] { value as? [JSON] ?? [] }
func num(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? Double(value as? String ?? "") ?? 0 }
func int(_ value: Any?) -> Int { Int(num(value)) }
func clean(_ value: Any?, limit: Int = 1000) -> String {
    let raw = value as? String ?? ""
    let text = raw.replacingOccurrences(
        of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression
    ).replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    return String(
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").prefix(limit)
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}
func secureURL(_ value: Any?) -> URL? {
    guard let text = value as? String, var parts = URLComponents(string: text.hasPrefix("//") ? "https:\(text)" : text)
    else { return nil }
    if parts.scheme == "http", let host = parts.host,
        ["hdslb.com", "bilivideo.com", "bilivideo.cn"].contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    {
        parts.scheme = "https"
    }
    guard let url = parts.url, url.scheme == "https", url.user == nil, url.password == nil,
        url.port == nil || url.port == 443
    else { return nil }
    return url
}
func validBVID(_ text: String) -> Bool { text.range(of: "^BV[0-9A-Za-z]{10}$", options: .regularExpression) != nil }
func seconds(_ value: Any?) -> Double {
    guard let text = value as? String, text.contains(":") else { return num(value) }
    return text.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
}
func timeLabel(_ time: Double) -> String {
    guard time.isFinite else { return "0:00" }
    let value = max(0, Int(time))
    return value >= 3600
        ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        : String(format: "%d:%02d", value / 60, value % 60)
}
func countLabel(_ count: Int) -> String { count >= 10000 ? String(format: "%.1f万", Double(count) / 10000) : "\(count)" }
struct BiliFailure: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
    static let invalid = BiliFailure(code: "INVALID_RESPONSE", message: "B 站返回的数据不完整，请稍后重试。")
}
struct User: Codable, Hashable, Identifiable {
    var mid: Int
    var name: String
    var avatar: URL?
    var description: String = ""
    var fans: Int?
    var id: Int { mid }
    static func map(_ data: JSON) -> User {
        User(
            mid: int(data["mid"] ?? data["uid"]), name: clean(data["name"] ?? data["uname"]),
            avatar: secureURL(data["face"] ?? data["avatar"] ?? data["upic"]),
            description: clean(data["sign"] ?? data["usign"], limit: 3000),
            fans: data["fans"] == nil ? nil : int(data["fans"]))
    }
}
struct Video: Codable, Hashable, Identifiable {
    var bvid: String
    var aid: Int
    var title: String
    var cover: URL?
    var duration: Double
    var publishedAt: Double
    var owner: User
    var views: Int
    var id: String { bvid }
    static func map(_ data: JSON, owner: User? = nil) -> Video? {
        guard let bvid = data["bvid"] as? String, validBVID(bvid) else { return nil }
        let rawViews = data["play"] ?? obj(data["stat"])["view"] ?? obj(data["stat"])["play"]
        let views =
            (rawViews as? String).map {
                Int(
                    (Double($0.replacingOccurrences(of: "万", with: "").replacingOccurrences(of: "亿", with: "")) ?? 0)
                        * ($0.contains("亿") ? 1e8 : $0.contains("万") ? 1e4 : 1))
            } ?? int(rawViews)
        return Video(
            bvid: bvid, aid: int(data["aid"] ?? data["id"]), title: clean(data["title"]),
            cover: secureURL(data["pic"] ?? data["cover"]),
            duration: seconds(data["duration"] ?? data["length"] ?? data["duration_text"]),
            publishedAt: num(data["pubdate"] ?? data["created"]),
            owner: data["owner"] is JSON
                ? User.map(obj(data["owner"]))
                : owner ?? User(mid: int(data["mid"]), name: clean(data["author"]), avatar: secureURL(data["upic"])),
            views: views)
    }
}
struct VideoPart: Codable, Hashable, Identifiable {
    var cid: Int
    var page: Int
    var title: String
    var duration: Double
    var id: Int { cid }
}
struct VideoDetail {
    var video: Video
    var parts: [VideoPart]
    var description: String
    var coinLimit: Int?
    var warning: String? = nil
    var statistics: VideoStatistics? = nil
}
struct VideoStatistics: Equatable {
    var likes: Int
    var coins: Int
    var favorites: Int
    static func map(_ data: JSON) throws -> VideoStatistics {
        let values = ["like", "coin", "favorite"].compactMap { data[$0] as? NSNumber }
        guard values.count == 3, values.allSatisfy({ $0.doubleValue.isFinite && $0.doubleValue >= 0 && $0.doubleValue.rounded() == $0.doubleValue }) else { throw BiliFailure.invalid }
        return VideoStatistics(likes: values[0].intValue, coins: values[1].intValue, favorites: values[2].intValue)
    }
}
enum VideoWrite: Equatable {
    case triple, like(Bool), coin(target: Int, like: Bool), favorite([Int])
}
struct VideoFavoriteFolder: Identifiable {
    var id: Int
    var title: String
    var count: Int
    var selected: Bool
    var isPrivate: Bool
    var capacity: Int
}
struct VideoEngagement: Equatable {
    var liked: Bool
    var coins: Int
    var favorited: Bool
    var complete: Bool { liked && coins > 0 && favorited }
    static func map(_ data: JSON) throws -> VideoEngagement {
        guard let liked = data["like"] as? Bool, let favorited = data["favorite"] as? Bool,
            let coins = data["coin"] as? NSNumber, coins.doubleValue.rounded() == coins.doubleValue,
            (0...2).contains(coins.intValue)
        else {
            throw BiliFailure(code: "ENGAGEMENT_UNAVAILABLE", message: "暂时无法确认三连状态。")
        }
        return VideoEngagement(liked: liked, coins: coins.intValue, favorited: favorited)
    }
}
enum CollectionKind: String, Codable, CaseIterable {
    case season, series
    var title: String { self == .season ? "合集" : "列表" }
}
struct CreatorCollection: Hashable, Identifiable {
    var number: Int
    var mid: Int
    var kind: CollectionKind
    var title: String
    var description: String
    var cover: URL?
    var count: Int
    var id: String { "\(kind.rawValue)-\(number)" }
    static func map(_ raw: JSON, kind: CollectionKind, mid: Int) throws -> CreatorCollection {
        let meta = obj(raw["meta"])
        let id = int(meta[kind == .season ? "season_id" : "series_id"])
        guard id > 0, int(meta["mid"]) == mid else {
            throw BiliFailure(code: "COLLECTION_OWNERSHIP", message: "合集或列表与当前 UP 主不匹配。")
        }
        return CreatorCollection(
            number: id, mid: mid, kind: kind, title: clean(meta["name"] ?? meta["title"]),
            description: clean(meta["description"], limit: 5000),
            cover: secureURL(meta["cover"]) ?? secureURL(list(raw["archives"]).first?["pic"]),
            count: int(meta["total"] ?? meta["count"]))
    }
}
struct Page<Item> {
    var items: [Item]
    var hasMore: Bool
    var cursor: String? = nil
}
struct SearchResult {
    var videos: [Video]
    var users: [User]
    var hasMore: Bool
}
struct Relation {
    var following: Bool
    var mutual: Bool
    var blocked: Bool
    static func map(_ data: JSON) throws -> Relation {
        guard let value = data["attribute"] as? NSNumber else { throw BiliFailure.invalid }
        return Relation(
            following: [1, 2, 6].contains(value.intValue), mutual: value.intValue == 6, blocked: value.intValue >= 128)
    }
}
struct StreamTrack {
    var id: Int
    var url: URL
    var codecs: String
    var bandwidth: Int
    var width: Int = 0
    var height: Int = 0
    var initialization: ClosedRange<Int64>?
    var index: ClosedRange<Int64>?
    static func map(_ data: JSON?) -> StreamTrack? {
        guard let data else { return nil }
        let candidates =
            [data["baseUrl"] ?? data["base_url"]]
            + (data["backupUrl"] as? [Any] ?? data["backup_url"] as? [Any] ?? []).map(Optional.some)
        guard let url = candidates.compactMap({ secureURL($0) }).first(where: MediaLoader.allowed) else { return nil }
        let segment = obj(data["SegmentBase"] ?? data["segment_base"])
        return StreamTrack(
            id: int(data["id"]), url: url, codecs: data["codecs"] as? String ?? "", bandwidth: int(data["bandwidth"]),
            width: int(data["width"]), height: int(data["height"]),
            initialization: ByteSegment.range(segment["Initialization"] ?? segment["initialization"]),
            index: ByteSegment.range(segment["indexRange"] ?? segment["index_range"]))
    }
}
struct Quality: Identifiable {
    var id: Int
    var label: String
}
struct SubtitleTrack: Identifiable {
    var id: Int
    var language: String
    var label: String
    var url: URL
}
struct Playback {
    var quality: Int
    var qualities: [Quality]
    var duration: Double
    var video: StreamTrack?
    var audio: StreamTrack?
    var mp4: URL?
    var subtitles: [SubtitleTrack] = []
}
struct Comment: Identifiable {
    var id: String
    var user: User
    var text: String
    var createdAt: Double
    var likes: Int
}
struct WatchRecord: Codable, Identifiable {
    var video: Video
    var cid: Int
    var page: Int
    var part: String
    var progress: Double
    var viewedAt: Date
    var completed: Bool
    var id: String { video.bvid }
}
struct SubtitleCue {
    var from: Double
    var to: Double
    var text: String
}
