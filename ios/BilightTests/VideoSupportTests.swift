import AVKit
import XCTest

@testable import Bilight

final class VideoSupportTests: XCTestCase {
    private let bvid = "BV0000000001"
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
            case "/x/web-interface/nav": return ["code": 0, "data": ["isLogin": true, "mid": 3, "uname": "Viewer"]]
            case "/x/frontend/finger/spi": return ["code": 0, "data": ["b_3": "test-official-device-0001"]]
            default: return try handler(request)
            }
        }
        let http = BiliHTTP(configuration: configuration, vault: MemoryVault())
        return (BiliClient(http: http), http)
    }
    func testAlreadyCompleteTripleDoesNotWriteOrSpendAgain() async throws {
        let (client, http) = fixture { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url!.path, "/x/web-interface/archive/relation")
            return ["code": 0, "data": ["like": true, "coin": 1, "favorite": true]]
        }
        _ = try await http.acceptLogin(cookies)
        let state = try await client.triple(bvid)
        XCTAssertTrue(state.complete)
        XCTAssertEqual(state.coins, 1)
    }
    func testConcurrentTripleUsesOneOfficialWriteThenConfirmsState() async throws {
        let lock = NSLock()
        var posts = 0
        var reads = 0
        let (client, http) = fixture { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url!.path, "/x/web-interface/archive/like/triple")
                let body = String(data: request.httpBody ?? self.streamData(request.httpBodyStream), encoding: .utf8)!
                XCTAssertTrue(body.contains("bvid=BV0000000001"))
                XCTAssertTrue(body.contains("csrf=test-only"))
                XCTAssertTrue(
                    request.value(forHTTPHeaderField: "Cookie")?.contains("buvid3=test-official-device-0001") == true)
                lock.withLock { posts += 1 }
                Thread.sleep(forTimeInterval: 0.1)
                return ["code": 0, "data": ["like": true, "coin": true, "fav": true]]
            }
            let completed = lock.withLock {
                reads += 1
                return posts > 0
            }
            return ["code": 0, "data": ["like": completed, "coin": completed ? 2 : 0, "favorite": completed]]
        }
        _ = try await http.acceptLogin(cookies)
        async let first = client.triple(bvid)
        async let second = client.triple(bvid)
        let states = try await [first, second]
        XCTAssertTrue(states.allSatisfy(\.complete))
        XCTAssertEqual(lock.withLock { posts }, 1)
        XCTAssertEqual(lock.withLock { reads }, 2)
    }
    func testUncertainWriteCannotRepeatUntilExplicitStateRefresh() async throws {
        var posts = 0
        let (client, http) = fixture { request in
            if request.httpMethod == "POST" {
                posts += 1
                throw URLError(.timedOut)
            }
            return ["code": 0, "data": ["like": posts > 0, "coin": posts > 0 ? 2 : 0, "favorite": posts > 0]]
        }
        _ = try await http.acceptLogin(cookies)
        for _ in 0..<2 {
            do {
                _ = try await client.triple(bvid)
                XCTFail("An uncertain result must require a fresh read")
            } catch let error as BiliFailure { XCTAssertEqual(error.code, "TRIPLE_UNCONFIRMED") }
        }
        XCTAssertEqual(posts, 1)
        let refreshed = try await client.videoEngagement(bvid)
        XCTAssertTrue(refreshed.complete)
        _ = try await client.triple(bvid)
        XCTAssertEqual(posts, 1)
    }
    func testPartialTripleNeverPretendsAllThreeSucceeded() async throws {
        var posts = 0
        let (client, http) = fixture { request in
            if request.httpMethod == "POST" {
                posts += 1
                return ["code": 0, "data": ["like": true, "coin": false, "fav": true]]
            }
            return ["code": 0, "data": ["like": posts > 0, "coin": 0, "favorite": posts > 0]]
        }
        _ = try await http.acceptLogin(cookies)
        let state = try await client.triple(bvid)
        XCTAssertFalse(state.complete)
        XCTAssertTrue(state.liked)
        XCTAssertTrue(state.favorited)
        XCTAssertEqual(state.coins, 0)
        XCTAssertEqual(posts, 1)
    }
    func testMalformedStateBlocksAnyTripleWrite() async throws {
        let (client, http) = fixture { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return ["code": 0, "data": ["like": false, "coin": 0]]
        }
        _ = try await http.acceptLogin(cookies)
        do {
            _ = try await client.triple(bvid)
            XCTFail("Unknown favorites must not become a false state")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "ENGAGEMENT_UNAVAILABLE") }
        XCTAssertThrowsError(try VideoEngagement.map(["like": true, "coin": 0.5, "favorite": true]))
        XCTAssertThrowsError(try VideoEngagement.map(["like": true, "coin": -1, "favorite": true]))
    }
    func testLogoutWhileReadingStatePreventsTheWrite() async throws {
        let lock = NSLock()
        var reading = false
        var posts = 0
        let (client, http) = fixture { request in
            if request.httpMethod == "POST" {
                lock.withLock { posts += 1 }
                return ["code": 0, "data": [:]]
            }
            lock.withLock { reading = true }
            Thread.sleep(forTimeInterval: 0.2)
            return ["code": 0, "data": ["like": false, "coin": 0, "favorite": false]]
        }
        _ = try await http.acceptLogin(cookies)
        let task = Task { try await client.triple(bvid) }
        let deadline = Date().addingTimeInterval(2)
        while !lock.withLock({ reading }), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(lock.withLock { reading })
        await client.logout()
        do {
            _ = try await task.value
            XCTFail("The previous account must not write")
        } catch {}
        XCTAssertEqual(lock.withLock { posts }, 0)
    }
    @MainActor func testCaptionSwitchRemembersLanguageAndClearsDisabledCuesAndErrors() {
        let model = PlayerModel()
        defer { model.stop() }
        // These intentionally non-CDN URLs are rejected before any network request.
        let english = SubtitleTrack(
            id: 1, language: "en", label: "English", url: URL(string: "https://example.com/en.json")!)
        let chinese = SubtitleTrack(
            id: 2, language: "zh-CN", label: "中文", url: URL(string: "https://example.com/zh.json")!)
        model.subtitleTracks = [english, chinese]
        model.setSubtitlesEnabled(true)
        XCTAssertEqual(model.selectedSubtitle, 2)
        model.selectSubtitle(english)
        model.subtitleText = "Old cue"
        model.subtitleError = "Old error"
        model.setSubtitlesEnabled(false)
        XCTAssertNil(model.selectedSubtitle)
        XCTAssertEqual(model.subtitleText, "")
        XCTAssertNil(model.subtitleError)
        model.setSubtitlesEnabled(true)
        XCTAssertEqual(model.selectedSubtitle, 1)
        model.setSubtitlesEnabled(false)
        model.subtitleTracks = [chinese]
        model.setSubtitlesEnabled(true)
        XCTAssertEqual(model.selectedSubtitle, 2)
        model.setSubtitlesEnabled(false)
        model.subtitleTracks = []
        model.setSubtitlesEnabled(true)
        XCTAssertNil(model.selectedSubtitle)
    }
    private func streamData(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 2048)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(bytes, count: count)
        }
        return data
    }
}
