#if DEBUG
import SwiftUI

/// Publication previews are opt-in and entirely offline, including images and session storage.
enum DemoFixtures {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--demo") }
    static func client() -> BiliClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DemoProtocol.self]
        return BiliClient(http: BiliHTTP(configuration: config, vault: DemoVault()))
    }
    @MainActor static func prepare(_ app: AppModel) async {
        try? await app.client.http.restore()
        app.user = try? await app.client.currentUser()
        app.history.account(app.user?.mid)
        app.watchLater.account(app.user?.mid)
        app.restoring = false
    }
    static func image(_ url: URL) -> UIImage? {
        guard url.host == "i0.hdslb.com", url.path.hasPrefix("/bilight-demo/demo-"),
            ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
            let file = Bundle.main.url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: url.pathExtension, subdirectory: "DemoAssets")
        else { return nil }
        return UIImage(contentsOfFile: file.path)
    }
}
private struct DemoVault: SessionVault {
    func load() -> [StoredCookie] {
        ["SESSDATA", "bili_jct", "buvid3"].map {
            StoredCookie(HTTPCookie(properties: [.name: $0, .value: "OFFLINE_DEMO_ONLY", .domain: ".bilibili.com", .path: "/", .secure: "TRUE"])!)
        }
    }
    func save(_ cookies: [StoredCookie]) {}
    func remove() {}
}
final class DemoProtocol: URLProtocol {
    private static let commentLock = NSLock()
    private static var dynamicCommentLiked = false
    private static var dynamicReplyAttempts = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url else { throw BiliFailure.invalid }
            if InteractionRegression.dynamicComments, let data = try dynamicCommentData(url) {
                try deliver(data, at: url)
                return
            }
            guard request.httpMethod == "GET",
                let file = Bundle.main.url(forResource: "fixtures", withExtension: "json"),
                let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? JSON
            else { throw BiliFailure(code: "DEMO_ONLY", message: "此操作未纳入离线演示。") }
            let browseRegression = ProcessInfo.processInfo.arguments.contains("--browse-return-regression")
            let favoritePaths = ["/x/v3/fav/folder/created/list", "/x/v3/fav/folder/collected/list", "/x/v3/fav/resource/list"]
            let commentSearch = InteractionRegression.commentComposer && url.path == "/x/v2/reply/at"
            let commentThread = InteractionRegression.commentComposer && ["/x/v2/reply/wbi/main", "/x/v2/reply/reply"].contains(url.path)
            guard var data = fixtures[url.path] as? JSON ?? (commentSearch || commentThread || (browseRegression && favoritePaths.contains(url.path)) ? [:] : nil)
            else { throw BiliFailure(code: "DEMO_ONLY", message: "此操作未纳入离线演示。") }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let preview = obj(fixtures["_preview"])
            func parameter(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
            let arguments = ProcessInfo.processInfo.arguments
            let followingFeed = url.path == "/x/polymer/web-dynamic/v1/feed/all"
            if followingFeed && arguments.contains("--regression-following-empty") {
                data = ["items": [] as [JSON], "has_more": false]
            } else if followingFeed && arguments.contains("--regression-following-error") {
                throw URLError(.notConnectedToInternet)
            }
            if commentSearch {
                let users = (1...8).filter { "Alice \($0)".localizedCaseInsensitiveContains(parameter("keyword")) }
                    .map { ["mid": 100 + $0, "name": "Alice \($0)"] as JSON }
                data = ["groups": [["items": users]]]
            }
            if commentThread {
                let root: JSON = ["rpid_str": "11", "oid": 42, "rcount": 1,
                    "member": ["mid": 31, "uname": "测试主评论"], "content": ["message": "示例主评论🙂[示例表情]",
                        "emote": ["[示例表情]": ["url": InteractionRegression.imageURL.absoluteString]]]]
                let child: JSON = ["rpid_str": "12", "oid": 42, "root_str": "11",
                    "member": ["mid": 32, "uname": "测试楼中楼"], "content": ["message": "示例回复"]]
                data = url.path == "/x/v2/reply/reply"
                    ? ["root": root, "page": ["num": 1, "size": 20, "count": 1], "replies": [child]]
                    : ["cursor": ["is_end": true, "all_count": 1], "replies": [root]]
            }
            // A separate, explicit test flag supplies long lists without changing publication previews.
            if browseRegression,
                (["/x/web-interface/wbi/search/type", "/x/space/wbi/arc/search"] + favoritePaths).contains(url.path)
            {
                let page = max(1, Int(parameter(url.path.hasSuffix("/search/type") ? "page" : "pn")) ?? 1)
                let template = list(obj(fixtures["/x/web-interface/wbi/search/type"])["result"]).first!
                let values: [JSON] = (1...30).map { index in
                    var value = template
                    value["bvid"] = String(format: "BV%010d", (page - 1) * 30 + index)
                    value["aid"] = 0
                    value["title"] = "浏览回归 \(page)-\(index)"
                    value["pic"] = ""; value["cover"] = ""
                    return value
                }
                let folder: JSON = ["id": 9, "mid": 7, "title": "浏览回归收藏夹", "media_count": 40, "type": 11]
                data = url.path.hasSuffix("/search/type")
                    ? ["result": values, "numPages": 2, "numResults": 60]
                    : ["list": ["vlist": values], "page": ["count": 60]]
                if favoritePaths.contains(url.path) {
                    if url.path.hasSuffix("/resource/list") {
                        let medias = values.prefix(20).enumerated().map { index, value -> JSON in
                            var item = value; item["id"] = (page - 1) * 20 + index + 1; item["type"] = 2
                            return item
                        }
                        data = ["info": folder, "medias": medias, "has_more": page < 2]
                    } else { data = ["count": 1, "list": [folder], "has_more": false] }
                }
                let body = try JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
                return
            }
            if ["/x/web-interface/view", "/x/web-interface/wbi/view"].contains(url.path) {
                guard let video = obj(preview["videos"])[parameter("bvid")] as? JSON else { throw BiliFailure.invalid }
                data = video
            } else if url.path == "/x/space/wbi/acc/info" {
                guard let creator = obj(preview["creators"])[parameter("mid")] as? JSON else { throw BiliFailure.invalid }
                data = creator
            } else if url.path == "/x/space/wbi/arc/search" {
                let values = list(obj(fixtures["/x/web-interface/wbi/search/type"])["result"]).filter { int(obj($0["owner"])["mid"]) == Int(parameter("mid")) }
                data = ["list": ["vlist": values], "page": ["count": values.count]]
            } else if url.path == "/x/polymer/web-space/seasons_series_list" {
                guard let directory = obj(preview["directories"])[parameter("mid")] as? JSON else { throw BiliFailure.invalid }
                data = directory
            }
            if url.path.hasSuffix("/search/type"), query.contains(where: { $0.name == "search_type" && $0.value == "bili_user" }) {
                data["result"] = list(obj(fixtures["/x/relation/followings"])["list"]).map { raw in
                    ["mid": raw["mid"] ?? 0, "uname": raw["name"] ?? "", "upic": raw["face"] ?? "", "usign": raw["sign"] ?? "", "fans": raw["fans"] ?? 0]
                }
            } else if url.path.hasSuffix("/search/type"), let order = VideoSearchOrder(rawValue: parameter("order")), order != .relevance {
                let videos = list(data["result"])
                if order == .latest {
                    data["result"] = videos.sorted { num($0["pubdate"]) > num($1["pubdate"]) }
                } else {
                    data["result"] = videos.sorted { int(obj($0["stat"])["view"]) > int(obj($1["stat"])["view"]) }
                }
            }
            let body = try JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func dynamicCommentData(_ url: URL) throws -> JSON? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func parameter(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let id = InteractionRegression.dynamicID, oid = InteractionRegression.dynamicCommentOID
        if url.path == "/x/polymer/web-dynamic/v1/detail", parameter("id") == id, request.httpMethod == "GET" {
            return ["item": ["type": "DYNAMIC_TYPE_WORD", "id_str": id,
                "basic": ["comment_type": 17, "comment_id_str": oid], "modules": [
                    "module_author": ["mid": 7, "name": "动态作者"],
                    "module_dynamic": ["desc": ["text": "动态评论回归"]],
                ]]]
        }
        if url.path == "/x/web-interface/nav", request.httpMethod == "GET" {
            return ["mid": 3, "uname": "隔离测试账号", "isLogin": true, "wbi_img": [
                "img_url": "https://i0.hdslb.com/bfs/wbi/0123456789abcdef0123456789abcdef.png",
                "sub_url": "https://i0.hdslb.com/bfs/wbi/fedcba9876543210fedcba9876543210.png",
            ]]
        }
        let liked = Self.commentLock.withLock { Self.dynamicCommentLiked }
        let root: JSON = ["rpid_str": "11", "oid_str": oid, "type": 17, "root_str": "0", "parent_str": "0",
            "action": liked ? 1 : 0, "like": liked ? 6 : 5, "rcount": 0,
            "member": ["mid": 31, "uname": "动态评论者"], "content": ["message": "示例主评论🙂[示例表情]",
                "emote": ["[示例表情]": ["url": InteractionRegression.imageURL.absoluteString]]]]
        switch (request.httpMethod, url.path) {
        case ("GET", "/x/v2/reply/wbi/main"):
            guard parameter("oid") == oid, parameter("type") == "17" else { throw BiliFailure.invalid }
            return ["cursor": ["is_end": true, "all_count": 1], "replies": [root]]
        case ("GET", "/x/v2/reply/detail"), ("GET", "/x/v2/reply/reply"):
            guard parameter("oid") == oid, parameter("type") == "17", parameter("root") == "11" else { throw BiliFailure.invalid }
            return ["root": root, "page": ["num": 1, "size": 20, "count": 0], "replies": [] as [JSON]]
        case ("POST", "/x/v2/reply/action"), ("POST", "/x/v2/reply/add"):
            if url.path.hasSuffix("/add") {
                let first = Self.commentLock.withLock {
                    Self.dynamicReplyAttempts += 1
                    return Self.dynamicReplyAttempts == 1
                }
                guard first else { throw BiliFailure.invalid }
            }
            let form = commentForm()
            guard form["oid"] == oid, form["type"] == "17", form["csrf"] == "OFFLINE_DEMO_ONLY",
                request.value(forHTTPHeaderField: "Referer") == "https://t.bilibili.com/\(id)"
            else { throw BiliFailure.invalid }
            if url.path.hasSuffix("/action") {
                guard form["rpid"] == "11", let action = form["action"], ["0", "1"].contains(action) else { throw BiliFailure.invalid }
                Self.commentLock.withLock { Self.dynamicCommentLiked = action == "1" }
                return [:]
            }
            guard form["root"] == "11", form["parent"] == "11", let message = form["message"], !message.isEmpty else { throw BiliFailure.invalid }
            return ["reply": ["rpid_str": "13", "oid_str": oid, "type": 17, "root_str": "11", "parent_str": "11",
                "member": ["mid": 3, "uname": "隔离测试账号"], "content": ["message": message]]]
        default:
            return nil
        }
    }

    private func commentForm() -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(bytes, count: count)
            }
        }
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func deliver(_ data: JSON, at url: URL) throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": 0, "data": data])
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
