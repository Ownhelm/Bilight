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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard request.httpMethod == "GET", let url = request.url,
                let file = Bundle.main.url(forResource: "fixtures", withExtension: "json"),
                let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? JSON
            else { throw BiliFailure(code: "DEMO_ONLY", message: "此操作未纳入离线演示。") }
            let browseRegression = ProcessInfo.processInfo.arguments.contains("--browse-return-regression")
            let favoritePaths = ["/x/v3/fav/folder/created/list", "/x/v3/fav/folder/collected/list", "/x/v3/fav/resource/list"]
            guard var data = fixtures[url.path] as? JSON ?? (browseRegression && favoritePaths.contains(url.path) ? [:] : nil)
            else { throw BiliFailure(code: "DEMO_ONLY", message: "此操作未纳入离线演示。") }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let preview = obj(fixtures["_preview"])
            func parameter(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
            // A separate, explicit test flag supplies long lists without changing publication previews.
            if browseRegression,
                (["/x/web-interface/wbi/search/type", "/x/space/wbi/arc/search"] + favoritePaths).contains(url.path)
            {
                let page = max(1, Int(parameter(url.path.hasSuffix("/search/type") ? "page" : "pn")) ?? 1)
                let template = list(obj(fixtures["/x/web-interface/wbi/search/type"])["result"]).first!
                let values: [JSON] = (1...30).map { index in
                    var value = template
                    value["bvid"] = String(format: "BV%010d", (page - 1) * 30 + index)
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
    override func stopLoading() {}
}
#endif
