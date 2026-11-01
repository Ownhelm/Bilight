import XCTest
import SwiftUI

@testable import Bilight

final class DynamicTests: XCTestCase {
    @MainActor func testProgrammaticRefreshRevealsTheNativeIndicatorAboveTheScrolledFeed() async throws {
        let gate = DispatchSemaphore(value: 0)
        var held = false, reads = 0
        let (client, http) = fixture { request in
            if request.url!.path == "/x/relation/relations" { return ["code": 0, "data": ["7": ["attribute": 2]]] }
            reads += 1
            if held { _ = gate.wait(timeout: .now() + 4) }
            return ["code": 0, "data": ["items": (1...20).map { self.item(String(1057955152016703500 + $0)) }, "has_more": false]]
        }
        _ = try await http.acceptLogin(cookies)
        let app = AppModel(client: client); app.user = User(mid: 3, name: "隔离测试", avatar: nil); app.restoring = false
        let model = app.following; await model.enter(client: client, mid: 3)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: FollowingView(model: model).environmentObject(app))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { gate.signal(); model.account(nil); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        func scrolls(_ view: UIView) -> [UIScrollView] { (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
        try await Task.sleep(for: .milliseconds(150))
        let scroll = try XCTUnwrap(scrolls(host.view).first)
        scroll.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        held = true; model.requestEntry()
        try await Task.sleep(for: .milliseconds(450))
        let control = try XCTUnwrap(scroll.refreshControl)
        XCTAssertTrue(control.isRefreshing, "An entry refresh must visibly open the native top refresh control")
        XCTAssertLessThan(scroll.contentOffset.y, -20, "The indicator must be revealed above the feed, rather than merely jumping to its first card")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "following-refresh-visible"; attachment.lifetime = .keepAlways; add(attachment)
        model.requestEntry()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reads, 2, "Repeated entry taps must share the same refresh")
        held = false; gate.signal()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(control.isRefreshing)
        XCTAssertEqual(model.posts.count, 20)
    }

    func testDynamicLikeWritesJSONOnceAndConfirmsBeforeChangingCounts() async throws {
        let id = "1057955152016703512"
        var liked = true, writes: [Int] = [], reads = 0
        let (client, http) = fixture { request in
            if request.url!.path == "/x/dynamic/feed/dyn/thumb" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "csrf" }?.value, "test-only")
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
                }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSON)
                XCTAssertEqual(body["dyn_id_str"] as? String, id)
                let up = int(body["up"]); writes.append(up); liked = up == 1
                return ["code": 0, "data": NSNull()]
            }
            XCTAssertEqual(request.httpMethod, "GET"); reads += 1
            var value = self.item(id), modules = obj(value["modules"])
            modules["module_stat"] = ["like": ["count": liked ? 19 : 18, "status": liked], "comment": ["count": 3]]
            value["modules"] = modules
            return ["code": 0, "data": ["item": value]]
        }
        _ = try await http.acceptLogin(cookies)
        let cancelled = try await client.setDynamicLike(id, liked: false)
        XCTAssertFalse(cancelled.liked); XCTAssertEqual(cancelled.likes, 18)
        _ = try await client.setDynamicLike(id, liked: false)
        let selected = try await client.setDynamicLike(id, liked: true)
        XCTAssertTrue(selected.liked); XCTAssertEqual(selected.likes, 19)
        XCTAssertEqual(writes, [2, 1]); XCTAssertEqual(reads, 5)
    }
    func testFailedDynamicLikeDoesNotRetryTheWriteOrClaimSuccess() async throws {
        var writes = 0, reads = 0
        let (client, http) = fixture { request in
            if request.httpMethod == "POST" { writes += 1; throw URLError(.notConnectedToInternet) }
            reads += 1; return ["code": 0, "data": ["item": self.item()]]
        }
        _ = try await http.acceptLogin(cookies)
        do { _ = try await client.setDynamicLike("1057955152016703512", liked: false); XCTFail("Unconfirmed state must fail") } catch {}
        XCTAssertEqual(writes, 1); XCTAssertEqual(reads, 4)
    }
    @MainActor func testDynamicLikeStateIsSharedAndLateFeedReadsCannotOverwriteConfirmedMutation() async throws {
        var liked = true, writes = 0
        let (client, http) = fixture { request in
            if request.httpMethod == "POST" { writes += 1; Thread.sleep(forTimeInterval: 0.1); liked = false; return ["code": 0, "data": NSNull()] }
            var value = self.item(), modules = obj(value["modules"])
            modules["module_stat"] = ["like": ["count": liked ? 12 : 11, "status": liked]]; value["modules"] = modules
            return ["code": 0, "data": ["item": value]]
        }
        _ = try await http.acceptLogin(cookies)
        let app = AppModel(client: client), post = try XCTUnwrap(DynamicPost.map(item()))
        app.user = User(mid: 3, name: "隔离账号", avatar: nil)
        app.recordDynamic(post, readVersion: app.dynamicLikeRevision)
        let oldRead = app.dynamicLikeRevision
        app.toggleDynamicLike(post); app.toggleDynamicLike(post)
        XCTAssertEqual(app.dynamicLikePending[post.id], false)
        XCTAssertEqual(app.dynamicLikeState(post).likes, 12, "Pending icon must not invent a public count")
        let end = Date().addingTimeInterval(3)
        while app.dynamicLikePending[post.id] != nil && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(writes, 1); XCTAssertEqual(app.dynamicLikeState(post), DynamicLikeState(liked: false, likes: 11))
        app.recordDynamic(post, readVersion: oldRead)
        XCTAssertEqual(app.dynamicLikeState(post).likes, 11)
    }
    @MainActor func testDynamicAndCommentsShareOneLoadingIndicatorWhenDetailFinishesFirst() async throws {
        try await checkDynamicLoading(commentsFirst: false)
    }
    @MainActor func testDynamicAndCommentsShareOneLoadingIndicatorWhenCommentsFinishFirst() async throws {
        try await checkDynamicLoading(commentsFirst: true)
    }
    @MainActor private func checkDynamicLoading(commentsFirst: Bool) async throws {
        let lock = NSLock()
        var pending: [String: (JSON) -> Void] = [:], reads: [String: Int] = [:]
        let detailPath = "/x/polymer/web-dynamic/v1/detail", commentPath = "/x/v2/reply/wbi/main"
        let raw = item(), id = "1057955152016703512"
        DynamicLoadingProtocol.respond = { request, reply in
            XCTAssertEqual(request.httpMethod, "GET", "Loading regression must never write to a platform")
            let path = request.url!.path
            if [detailPath, commentPath].contains(path) {
                lock.withLock { reads[path, default: 0] += 1; pending[path] = reply }; return
            }
            let data: JSON
            switch path {
            case "/x/frontend/finger/spi": data = ["b_3": "test-official-device-0001"]
            case "/x/web-interface/nav": data = ["isLogin": true, "mid": 3, "uname": "隔离账号", "wbi_img": [
                "img_url": "https://i0.hdslb.com/" + String(repeating: "a", count: 32) + ".png",
                "sub_url": "https://i0.hdslb.com/" + String(repeating: "b", count: 32) + ".png"]]
            default: XCTFail("Unexpected fixture endpoint: \(path)"); data = [:]
            }
            reply(["code": 0, "data": data])
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DynamicLoadingProtocol.self]
        let client = BiliClient(http: BiliHTTP(configuration: configuration, vault: MemoryVault()))
        let app = AppModel(client: client); app.restoring = false; app.dynamics[id] = try XCTUnwrap(DynamicPost.map(raw))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: DynamicDetailView(id: id).environmentObject(app))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); DynamicLoadingProtocol.respond = nil }
        func indicators(_ view: UIView) -> [UIActivityIndicatorView] {
            (view as? UIActivityIndicatorView).map { [$0] } ?? view.subviews.flatMap(indicators)
        }
        func count() -> Int {
            indicators(host.view).filter { indicator in
                guard indicator.window === window, indicator.isAnimating else { return false }
                var area = indicator.convert(indicator.bounds, to: window).intersection(window.bounds)
                var ancestor: UIView? = indicator
                while let view = ancestor {
                    if view.isHidden || view.alpha <= 0.01 { return false }
                    if view.clipsToBounds { area = area.intersection(view.convert(view.bounds, to: window)) }
                    ancestor = view.superview
                }
                return !area.isEmpty && !area.isNull
            }.count
        }
        func wait(_ condition: () -> Bool) async throws {
            let end = Date().addingTimeInterval(3)
            while !condition() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(condition())
            try await Task.sleep(for: .milliseconds(100))
        }
        func complete(_ path: String) {
            let reply = lock.withLock { pending.removeValue(forKey: path) }
            let data: JSON = path == detailPath ? ["item": raw] : ["cursor": ["is_end": 1, "all_count": 0], "replies": []]
            reply?(["code": 0, "data": data])
        }
        try await wait { lock.withLock { pending.count == 2 } }
        XCTAssertEqual(count(), 1, "Opening a cached dynamic while detail and comments both wait must show exactly one spinner")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "dynamic-single-loading-\(commentsFirst ? "comments-first" : "detail-first")"; attachment.lifetime = .keepAlways; add(attachment)
        complete(commentsFirst ? commentPath : detailPath)
        try await wait { count() == 1 }
        XCTAssertEqual(count(), 1, "One remaining request must retain one spinner")
        complete(commentsFirst ? detailPath : commentPath)
        try await wait { count() == 0 }
        XCTAssertEqual(count(), 0)
        XCTAssertEqual(lock.withLock { reads[detailPath] }, 1); XCTAssertEqual(lock.withLock { reads[commentPath] }, 1)
    }
    private func item(
        _ id: String = "1057955152016703512", mid: Int = 7, type: String = "DYNAMIC_TYPE_WORD", major: JSON? = nil
    ) -> JSON {
        [
            "id_str": id, "type": type, "orig": NSNull(),
            "basic": ["comment_id_str": id, "comment_type": 17],
            "modules": [
                "module_author": ["mid": mid, "name": "作者", "pub_ts": 1_700_000_000, "pub_action": "发布了动态"],
                "module_dynamic": ["desc": ["text": "一条真实格式的文字"], "major": major as Any? ?? NSNull()],
                "module_stat": [
                    "like": ["count": 12, "status": true], "comment": ["count": 3], "forward": ["count": 2],
                ],
            ],
        ]
    }
    private var cookies: [HTTPCookie] {
        ["SESSDATA", "bili_jct"].map {
            HTTPCookie(properties: [
                .name: $0, .value: "test-only", .domain: ".bilibili.com", .path: "/", .secure: "TRUE",
            ])!
        }
    }
    private func fixture(_ handler: @escaping (URLRequest) throws -> JSON) -> (BiliClient, BiliHTTP) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        MockProtocol.responseHeaders = [:]
        MockProtocol.stalledPath = nil
        MockProtocol.handler = { request in
            switch request.url!.path {
            case "/x/web-interface/nav":
                return [
                    "code": 0,
                    "data": [
                        "isLogin": true, "mid": 3, "uname": "Viewer",
                        "wbi_img": [
                            "img_url": "https://i0.hdslb.com/" + String(repeating: "a", count: 32) + ".png",
                            "sub_url": "https://i0.hdslb.com/" + String(repeating: "b", count: 32) + ".png",
                        ],
                    ],
                ]
            case "/x/frontend/finger/spi": return ["code": 0, "data": ["b_3": "test-official-device-0001"]]
            default: return try handler(request)
            }
        }
        let http = BiliHTTP(configuration: configuration, vault: MemoryVault())
        return (BiliClient(http: http), http)
    }
    func testOpusAndLegacyPicturesKeepExactIDsAndRealCommentTargets() throws {
        var raw = item(major: [
            "type": "MAJOR_TYPE_OPUS",
            "opus": [
                "title": "图文标题", "summary": ["text": "图文正文"],
                "pics": [["url": "https://i0.hdslb.com/p.jpg", "width": 1200, "height": 800]],
            ],
        ])
        var modules = obj(raw["modules"])
        var dynamic = obj(modules["module_dynamic"])
        dynamic["desc"] = NSNull()
        modules["module_dynamic"] = dynamic
        raw["modules"] = modules
        let post = try XCTUnwrap(DynamicPost.map(raw))
        XCTAssertEqual(post.id, "1057955152016703512")
        XCTAssertEqual(post.commentID, post.id)
        XCTAssertEqual(post.commentType, 17)
        XCTAssertEqual(post.text, "图文正文")
        XCTAssertEqual(post.title, "图文标题")
        XCTAssertTrue(post.liked)
        guard case .pictures(let images) = post.content else { return XCTFail("Opus must retain pictures") }
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.aspect, 1.5)
        let draw = try XCTUnwrap(
            DynamicPost.map(
                item(
                    type: "DYNAMIC_TYPE_DRAW",
                    major: [
                        "type": "MAJOR_TYPE_DRAW",
                        "draw": ["items": [["src": "//i0.hdslb.com/draw.jpg", "width": 500, "height": 1000]]],
                    ])))
        guard case .pictures(let legacy) = draw.content else { return XCTFail("Legacy pictures must be retained") }
        XCTAssertEqual(legacy.first?.url.scheme, "https")
    }
    func testRepostPreservesOriginalAuthorAndDoesNotBecomeAnInsertedVideo() throws {
        var raw = item(type: "DYNAMIC_TYPE_FORWARD")
        raw["orig"] = item("1057955152016703513", mid: 99)
        let post = try XCTUnwrap(DynamicPost.map(raw))
        guard case .repost(let original) = post.content else { return XCTFail("Expected attributed original") }
        XCTAssertEqual(post.author.mid, 7)
        XCTAssertEqual(original.author.mid, 99)
        raw["orig"] = NSNull()
        guard case .unavailable = try XCTUnwrap(DynamicPost.map(raw)).content else {
            return XCTFail("Missing original must be explicit")
        }
    }
    func testInsertedAdsForgedVideoOwnersAndUnattributedOriginalsAreRejected() {
        XCTAssertNil(DynamicPost.map(item(type: "DYNAMIC_TYPE_AD")))
        XCTAssertNil(DynamicPost.map(item(type: "DYNAMIC_TYPE_BANNER")))
        let forged = item(
            type: "DYNAMIC_TYPE_AV",
            major: [
                "type": "MAJOR_TYPE_ARCHIVE",
                "archive": [
                    "bvid": "BV0000000001", "owner": ["mid": 99], "title": "Inserted",
                ],
            ])
        XCTAssertNil(DynamicPost.map(forged))
        var raw = item()
        raw["orig"] = item("1057955152016703513", mid: 99)
        XCTAssertNil(DynamicPost.map(raw))
        raw = item()
        raw["id_str"] = NSNumber(value: 1_057_955_152_016_703_512 as Int64)
        XCTAssertNil(DynamicPost.map(raw), "Do not round a numeric dynamic ID into another post")
    }
    func testUnknownContentAndDeletedOriginalsHaveVisibleStatesInsteadOfFakeEmptyLists() throws {
        let raw = item(major: ["type": "MAJOR_TYPE_NEW_UNKNOWN", "new_unknown": ["title": "真实卡片标题", "desc": "真实摘要"]])
        guard case .link(let card) = try XCTUnwrap(DynamicPost.map(raw)).content else {
            return XCTFail("Keep actual card data")
        }
        XCTAssertEqual(card.title, "真实卡片标题")
        let unavailable = item(major: ["type": "MAJOR_TYPE_NONE", "none": ["tips": "内容已删除"]])
        guard case .unavailable(let reason) = try XCTUnwrap(DynamicPost.map(unavailable)).content else {
            return XCTFail()
        }
        XCTAssertEqual(reason, "内容已删除")
    }
    func testSeasonVideoLinkAndArticleSummaryArePreserved() throws {
        let season = item(
            type: "DYNAMIC_TYPE_UGC_SEASON",
            major: [
                "type": "MAJOR_TYPE_UGC_SEASON",
                "ugc_season":
                    ["aid": 7, "title": "合集更新", "jump_url": "//www.bilibili.com/video/BV0000000001"],
            ])
        guard case .video(let video) = try XCTUnwrap(DynamicPost.map(season)).content else {
            return XCTFail("Season BV must open natively")
        }
        XCTAssertEqual(video.bvid, "BV0000000001")
        let article = item(
            type: "DYNAMIC_TYPE_ARTICLE",
            major: [
                "type": "MAJOR_TYPE_ARTICLE",
                "article":
                    [
                        "title": "专栏标题", "desc": "摘要", "covers": ["//i0.hdslb.com/cover.jpg"],
                        "jump_url": "//www.bilibili.com/read/cv123",
                    ],
            ])
        guard case .link(let link) = try XCTUnwrap(DynamicPost.map(article)).content else {
            return XCTFail("Keep article preview")
        }
        XCTAssertEqual(link.title, "专栏标题")
        XCTAssertEqual(link.label, "专栏")
        XCTAssertEqual(link.cover?.host, "i0.hdslb.com")
    }
    func testAllFeedChecksOnlyOuterAuthorsAndKeepsDistinctPostsOfSameVideo() async throws {
        var forward = item("1057955152016703514", type: "DYNAMIC_TYPE_FORWARD")
        forward["orig"] = item("1057955152016703515", mid: 99)
        let archive: JSON = ["type": "MAJOR_TYPE_ARCHIVE", "archive": ["bvid": "BV0000000001", "title": "同一个视频"]]
        let values = [
            item(), item("1057955152016703513", mid: 8), forward,
            item("1057955152016703516", type: "DYNAMIC_TYPE_AV", major: archive),
            item("1057955152016703517", type: "DYNAMIC_TYPE_AV", major: archive), item(type: "DYNAMIC_TYPE_AD"),
        ]
        var relationReads = 0
        let (client, http) = fixture { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            switch request.url!.path {
            case "/x/polymer/web-dynamic/v1/feed/all":
                XCTAssertEqual(query.first { $0.name == "type" }?.value, "all")
                return ["code": 0, "data": ["items": values, "has_more": false]]
            case "/x/relation/relations":
                relationReads += 1
                XCTAssertEqual(query.first { $0.name == "fids" }?.value, "7,8")
                return ["code": 0, "data": ["7": ["attribute": 2]]]
            default:
                XCTFail("Unexpected endpoint: \(request.url!.path)")
                return [:]
            }
        }
        _ = try await http.acceptLogin(cookies)
        let result = try await client.following(mid: 3, cursor: nil)
        XCTAssertEqual(result.items.count, 4)
        XCTAssertTrue(result.items.allSatisfy { $0.author.mid == 7 })
        _ = try await client.following(mid: 3, cursor: nil)
        XCTAssertEqual(relationReads, 1)
        await client.invalidateFollowing()
        _ = try await client.following(mid: 3, cursor: nil)
        XCTAssertEqual(relationReads, 2)
    }
    @MainActor func testSingleColumnPublishesOnePostImmediatelyAndPaginatesByDynamicID() async throws {
        let first = item()
        let second = item("1057955152016703513")
        var reads = 0
        let (client, http) = fixture { request in
            if request.url!.path == "/x/relation/relations" { return ["code": 0, "data": ["7": ["attribute": 2]]] }
            XCTAssertEqual(request.url!.path, "/x/polymer/web-dynamic/v1/feed/all")
            reads += 1
            let next = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first {
                $0.name == "offset"
            }?.value
            return [
                "code": 0,
                "data": next == nil
                    ? ["items": [first], "has_more": true, "offset": "page1"]
                    : ["items": [first, second], "has_more": false],
            ]
        }
        _ = try await http.acceptLogin(cookies)
        let model = FollowingModel()
        await model.load(client: client, mid: 3, reset: true)
        XCTAssertEqual(model.posts.count, 1)
        XCTAssertEqual(reads, 1, "The first card must not wait for a row or another page")
        await model.load(client: client, mid: 3)
        XCTAssertEqual(model.posts.map(\.id), ["1057955152016703512", "1057955152016703513"])
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.error)
    }
    func testMalformedPagingAndStalledAllFeedAreVisibleFailures() async throws {
        let (client, http) = fixture { request in
            if request.url!.path == "/x/relation/relations" { return ["code": 0, "data": [:]] }
            return ["code": 0, "data": ["items": [], "has_more": true]]
        }
        _ = try await http.acceptLogin(cookies)
        do {
            _ = try await client.following(mid: 3, cursor: nil)
            XCTFail("Missing cursor must not look terminal")
        } catch let error as BiliFailure { XCTAssertEqual(error.code, "CURSOR_LOOP") }
        MockProtocol.stalledPath = "/x/polymer/web-dynamic/v1/feed/all"
        let short = BiliClient(http: http, followingTimeout: .milliseconds(150))
        let began = Date()
        do {
            _ = try await short.following(mid: 3, cursor: nil)
            XCTFail("Expected timeout")
        } catch let error as BiliFailure { XCTAssertEqual(error.code, "FOLLOW_TIMEOUT") }
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
    }
    @MainActor func testReenterKeepsFeedPagesAndPositionUntilExplicitRefresh() async throws {
        let first = item("1057955152016703512"), second = item("1057955152016703513")
        var reads = 0, failing = false
        let (client, http) = fixture { request in
            if request.url!.path == "/x/relation/relations" { return ["code": 0, "data": ["7": ["attribute": 2]]] }
            reads += 1
            if failing { throw URLError(.timedOut) }
            let next = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "offset" }?.value
            return ["code": 0, "data": next == nil ? ["items": [first], "has_more": true, "offset": "page1"] : ["items": [second], "has_more": false]]
        }
        _ = try await http.acceptLogin(cookies)
        let model = FollowingModel()
        await model.enter(client: client, mid: 3)
        await model.load(client: client, mid: 3)
        model.visiblePostID = second["id_str"] as? String
        await model.enter(client: client, mid: 3)
        XCTAssertEqual(reads, 2, "Returning from video must not request the feed again")
        XCTAssertEqual(model.posts.count, 2)
        XCTAssertEqual(model.visiblePostID, second["id_str"] as? String)
        failing = true
        await model.load(client: client, mid: 3, reset: true)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.posts.count, 2, "A failed refresh must keep the visible cache")
        await model.enter(client: client, mid: 3)
        XCTAssertEqual(reads, 3)
        failing = false
        await model.retry(client: client, mid: 3)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(model.posts.count, 1)
        XCTAssertNil(model.visiblePostID)
        model.requestEntry()
        XCTAssertTrue(model.consumeEntry())
        await model.refreshLatest(client: client, mid: 3)
        XCTAssertEqual(reads, 5, "An explicit following-entry tap requests one fresh first page")
        XCTAssertFalse(model.consumeEntry(), "Remounting the view must not consume the same tap twice")
        await model.enter(client: client, mid: 3)
        XCTAssertEqual(reads, 5, "Returning from a video after the tap still restores the cache")
        model.account(nil)
        XCTAssertTrue(model.posts.isEmpty)
        XCTAssertFalse(model.initialized)
    }
    @MainActor func testEmptyFeedStaysCachedAndUnfollowOnlyRemovesItsAuthor() async throws {
        var reads = 0
        let (client, http) = fixture { request in
            reads += 1
            return ["code": 0, "data": ["items": [], "has_more": false]]
        }
        _ = try await http.acceptLogin(cookies)
        let model = FollowingModel()
        await model.enter(client: client, mid: 3)
        await model.enter(client: client, mid: 3)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(model.initialized)
        model.posts = [try XCTUnwrap(DynamicPost.map(item(mid: 7))), try XCTUnwrap(DynamicPost.map(item("1057955152016703513", mid: 8)))]
        model.removeAuthor(7)
        XCTAssertEqual(model.posts.map(\.author.mid), [8])
    }
    func testReplyPaginationValidatesRootAndKeepsTheRequestedThreadAndType() async throws {
        let (client, _) = fixture { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url!.path, "/x/v2/reply/reply")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "oid" }?.value, "1057955152016703512")
            XCTAssertEqual(query.first { $0.name == "root" }?.value, "289123456789")
            XCTAssertEqual(query.first { $0.name == "type" }?.value, "17")
            let page = Int(query.first { $0.name == "pn" }!.value!)!
            return ["code": 0, "data": ["page": ["num": page, "size": 20, "count": 21], "root": ["rpid_str": "289123456789", "oid": "1057955152016703512"], "replies": [["rpid_str": "289123456790", "root": "289123456789", "oid": "1057955152016703512", "member": ["mid": 8, "uname": "Reader"], "content": ["message": "Child"]]]]]
        }
        let first = try await client.commentReplies(oid: "1057955152016703512", type: 17, root: "289123456789")
        XCTAssertEqual(first.items.first?.text, "Child"); XCTAssertEqual(first.total, 21); XCTAssertTrue(first.hasMore)
        let last = try await client.commentReplies(oid: "1057955152016703512", type: 17, root: "289123456789", page: 2)
        XCTAssertFalse(last.hasMore)
    }
    func testRepliesDoNotAcceptMismatchedRootsOrIncompleteEmptyPages() async throws {
        for wrongRoot in [true, false] {
            let (client, _) = fixture { _ in
                ["code": 0, "data": ["page": ["num": 1, "size": 20, "count": 40], "root": ["rpid_str": wrongRoot ? "99" : "11"], "replies": []]]
            }
            do { _ = try await client.commentReplies(oid: "9", root: "11"); XCTFail("Must reject incomplete reply data") }
            catch { XCTAssertTrue(error is BiliFailure) }
        }
    }
    func testDynamicCommentsUseReturnedTypeAndExactOID() async throws {
        let (client, _) = fixture { request in
            XCTAssertEqual(request.url!.path, "/x/v2/reply/wbi/main")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "type" }?.value, "17")
            XCTAssertEqual(query.first { $0.name == "oid" }?.value, "1057955152016703512")
            return ["code": 0, "data": ["cursor": ["is_end": true, "all_count": 0], "replies": []]]
        }
        let result = try await client.comments(oid: "1057955152016703512", type: 17)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(result.hasMore)
    }
}

/// Per-request gates keep independent SwiftUI loading paths pending without blocking URLSession.
private final class DynamicLoadingProtocol: URLProtocol {
    static var respond: ((URLRequest, @escaping (JSON) -> Void) -> Void)?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.respond?(request) { [weak self] body in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            do {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}
