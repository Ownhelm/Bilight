import Foundation

struct PostImage: Hashable, Identifiable {
    var url: URL
    var width: Double
    var height: Double
    var id: URL { url }
    var aspect: Double { width > 0 && height > 0 ? width / height : 1 }
    static func map(_ raw: JSON) -> PostImage? {
        guard let url = secureURL(raw["src"] ?? raw["url"]) else { return nil }
        return PostImage(url: url, width: num(raw["width"]), height: num(raw["height"]))
    }
}
struct PostLink: Hashable {
    var title: String
    var summary: String
    var cover: URL?
    var url: URL?
    var label: String
}
indirect enum PostContent: Hashable {
    case text
    case video(Video)
    case pictures([PostImage])
    case repost(DynamicPost)
    case link(PostLink)
    case unavailable(String)
}
struct DynamicPost: Hashable, Identifiable {
    var id: String
    var author: User
    var publishedAt: Double
    var action: String
    var text: String
    var title: String
    var content: PostContent
    var comments: Int
    var forwards: Int
    var likes: Int
    var liked: Bool
    var commentID: String?
    var commentType: Int
    var warning: String
    var url: URL { URL(string: "https://t.bilibili.com/\(id)")! }
    static func validID(_ value: String) -> Bool {
        value.range(of: "^[1-9][0-9]{0,31}$", options: .regularExpression) != nil
    }
    /// Keep dynamic IDs as strings: converting them through Double loses precision.
    static func map(_ item: JSON, depth: Int = 0) -> DynamicPost? {
        let modules = obj(item["modules"])
        let rawAuthor = obj(modules["module_author"])
        let type = clean(item["type"])
        let id = clean(item["id_str"])
        guard validID(id), int(rawAuthor["mid"]) > 0, depth < 3,
            type.hasPrefix("DYNAMIC_TYPE_"), !["DYNAMIC_TYPE_AD", "DYNAMIC_TYPE_BANNER"].contains(type),
            modules["module_ad"] == nil || modules["module_ad"] is NSNull
        else { return nil }
        let author = User.map(rawAuthor)
        let dynamic = obj(modules["module_dynamic"])
        let major = obj(dynamic["major"])
        let opus = obj(major["opus"])
        let summary = obj(opus["summary"])
        var text = clean(obj(dynamic["desc"])["text"], limit: 30000)
        if text.isEmpty { text = clean(summary["text"], limit: 30000) }
        var title = clean(opus["title"])
        let content: PostContent
        if type == "DYNAMIC_TYPE_FORWARD" {
            if let original = map(obj(item["orig"]), depth: depth + 1) {
                content = .repost(original)
            } else {
                content = .unavailable("原动态已失效或暂时无法查看")
            }
        } else {
            // A non-forward must not smuggle another author's original into the feed.
            guard item["orig"] == nil || item["orig"] is NSNull else { return nil }
            switch clean(major["type"]) {
            case "MAJOR_TYPE_ARCHIVE", "MAJOR_TYPE_UGC_SEASON":
                var archive = obj(major["archive"] ?? major["ugc_season"])
                if let owner = archive["owner"] as? JSON, int(owner["mid"]) != author.mid { return nil }
                archive["pubdate"] = rawAuthor["pub_ts"]
                // Season updates may provide the BV only in their official video link.
                if !validBVID(clean(archive["bvid"])), let url = secureURL(archive["jump_url"]), BiliHTTP.trusted(url),
                    let bvid = url.pathComponents.first(where: validBVID)
                {
                    archive["bvid"] = bvid
                }
                if let video = Video.map(archive, owner: author) {
                    content = .video(video)
                } else if clean(major["type"]) == "MAJOR_TYPE_UGC_SEASON" {
                    content = .link(
                        PostLink(
                            title: clean(archive["title"]), summary: clean(archive["desc"]),
                            cover: secureURL(archive["cover"]), url: secureURL(archive["jump_url"]), label: "合集更新"))
                } else {
                    content = .unavailable("视频暂时无法读取")
                }
            case "MAJOR_TYPE_DRAW":
                content = .pictures(uniqueImages(list(obj(major["draw"])["items"])))
            case "MAJOR_TYPE_OPUS":
                let images = uniqueImages(list(opus["pics"]))
                content = images.isEmpty ? .text : .pictures(images)
            case "MAJOR_TYPE_ARTICLE":
                let article = obj(major["article"])
                content = .link(
                    PostLink(
                        title: clean(article["title"]), summary: clean(article["desc"], limit: 10000),
                        cover: (article["covers"] as? [String])?.first.flatMap(secureURL),
                        url: secureURL(article["jump_url"]), label: "专栏"))
            case "MAJOR_TYPE_NONE":
                content = .unavailable(
                    clean(obj(major["none"])["tips"]).isEmpty ? "动态暂时无法查看" : clean(obj(major["none"])["tips"]))
            case "", "MAJOR_TYPE_BLOCKED":
                content = text.isEmpty ? .unavailable("动态内容暂时无法查看") : .text
            default:
                let key = clean(major["type"]).replacingOccurrences(of: "MAJOR_TYPE_", with: "").lowercased()
                var card = obj(major[key])
                if key == "live_rcmd", let raw = card["content"] as? String,
                    let data = raw.data(using: .utf8), let live = try? JSONSerialization.jsonObject(with: data) as? JSON
                {
                    card = obj(live["live_play_info"])
                }
                let cardTitle = clean(card["title"] ?? card["name"])
                let cardText = clean(card["desc"] ?? card["summary"], limit: 10000)
                if !cardTitle.isEmpty || !cardText.isEmpty {
                    content = .link(
                        PostLink(
                            title: cardTitle, summary: cardText, cover: secureURL(card["cover"]),
                            url: secureURL(card["jump_url"]), label: key.contains("live") ? "直播动态" : "动态"))
                } else {
                    content = .unavailable(text.isEmpty ? "此动态类型暂时无法完整展示" : "附加内容暂时无法展示")
                }
            }
        }
        if title == text { title = "" }
        let stats = obj(modules["module_stat"])
        let basic = obj(item["basic"])
        let commentID = clean(basic["comment_id_str"])
        let dispute = obj(modules["module_dispute"])
        return DynamicPost(
            id: id, author: author, publishedAt: num(rawAuthor["pub_ts"]),
            action: clean(rawAuthor["pub_action"]), text: text, title: title, content: content,
            comments: int(obj(stats["comment"])["count"]), forwards: int(obj(stats["forward"])["count"]),
            likes: int(obj(stats["like"])["count"]), liked: int(obj(stats["like"])["status"]) == 1,
            commentID: validID(commentID) ? commentID : nil, commentType: int(basic["comment_type"]),
            warning: clean(dispute["title"] ?? dispute["desc"]))
    }
    private static func uniqueImages(_ raw: [JSON]) -> [PostImage] {
        var seen = Set<URL>()
        return raw.compactMap(PostImage.map).filter { seen.insert($0.url).inserted }
    }
}
