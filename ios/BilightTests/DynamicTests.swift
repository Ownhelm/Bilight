import XCTest

@testable import Bilight

final class DynamicTests: XCTestCase {
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
