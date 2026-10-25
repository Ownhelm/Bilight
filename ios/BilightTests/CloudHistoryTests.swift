import XCTest

@testable import Bilight

final class CloudHistoryTests: XCTestCase {
    private let bvid = "BV0000000001"
    private var video: Video {
        Video(
            bvid: bvid, aid: 42, title: "Video", cover: nil, duration: 60, publishedAt: 1,
            owner: User(mid: 9, name: "UP", avatar: nil), views: 0)
    }
    private let part = VideoPart(cid: 52, page: 2, title: "Part 2", duration: 60)
    private func row(_ progress: Int = 12) -> JSON {
        [
            "title": "From B站", "duration": 60, "author_mid": 9, "author_name": "UP", "view_at": 1_700_000_000,
            "progress": progress,
            "history": ["business": "archive", "oid": 42, "bvid": bvid, "cid": 52, "page": 2, "part": "Part 2"],
        ]
    }
    private func fixture(_ handler: @escaping (URLRequest) throws -> JSON) async throws -> BiliClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        MockProtocol.responseHeaders = [:]
        MockProtocol.stalledPath = nil
        MockProtocol.handler = { request in
            switch request.url!.path {
            case "/x/web-interface/nav": return ["code": 0, "data": ["isLogin": true, "mid": 7, "uname": "Viewer"]]
            case "/x/frontend/finger/spi": return ["code": 0, "data": ["b_3": "test-official-device-0001"]]
            default: return try handler(request)
            }
        }
        let client = BiliClient(http: BiliHTTP(configuration: configuration, vault: MemoryVault()))
        let cookies = ["SESSDATA", "bili_jct"].map {
            HTTPCookie(properties: [
                .name: $0, .value: "test-only", .domain: ".bilibili.com", .path: "/", .secure: "TRUE",
            ])!
        }
        _ = try await client.acceptLogin(cookies)
        return client
    }
    func testCloudHistoryKeepsRealPartProgressAndCursorWithoutLoadingOtherBusinesses() async throws {
        let client = try await fixture { request in
            XCTAssertEqual(request.url!.path, "/x/web-interface/history/cursor")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "type" }?.value, "archive")
            if query.contains(where: { $0.name == "max" }) {
                XCTAssertEqual(query.first { $0.name == "max" }?.value, "999")
                return ["code": 0, "data": ["list": [], "cursor": [:]]]
            }
            var live = self.row()
            live["history"] = ["business": "live", "bvid": "BV0000000002"]
            return [
                "code": 0,
                "data": [
                    "list": [self.row(-1), live, self.row()],
                    "cursor": ["max": 999, "view_at": 1_700_000_000, "business": "archive"],
                ],
            ]
        }
        let first = try await client.history(mid: 7)
        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(first.items.first?.cid, 52)
        XCTAssertEqual(first.items.first?.page, 2)
        XCTAssertTrue(first.items.first?.completed == true)
        XCTAssertTrue(first.hasMore)
        let last = try await client.history(mid: 7, cursor: first.cursor)
        XCTAssertFalse(last.hasMore)
        XCTAssertTrue(last.items.isEmpty)
    }
    func testMalformedHistoryAndUnsafeCursorDoNotBecomeEmptySuccess() async throws {
        let client = try await fixture { _ in ["code": 0, "data": ["cursor": [:]]] }
        do {
            _ = try await client.history(mid: 7)
            XCTFail("Missing list must be visible failure")
        } catch let error as BiliFailure { XCTAssertEqual(error.code, "INVALID_RESPONSE") }
        do {
            _ = try await client.history(mid: 7, cursor: "https://evil.example")
            XCTFail("Unsafe cursor")
        } catch let error as BiliFailure { XCTAssertEqual(error.code, "INVALID_CURSOR") }
    }
    func testHistoryReportUsesAccountAndActualPartAndAcceptsNoDataSuccess() async throws {
        var writes = 0
        let client = try await fixture { request in
            XCTAssertEqual(request.url!.path, "/x/v2/history/report")
            XCTAssertEqual(request.httpMethod, "POST")
            let values = self.form(request)
            XCTAssertEqual(values["aid"], "42")
            XCTAssertEqual(values["cid"], "52")
            XCTAssertEqual(values["progress"], "60")
            XCTAssertEqual(values["csrf"], "test-only")
            XCTAssertNil(values["platform"], "Do not pretend to be an Android client")
            writes += 1
            return ["code": 0]
        }
        try await client.reportHistory(mid: 7, video: video, part: part, progress: 70)
        XCTAssertEqual(writes, 1)
        do {
            try await client.reportHistory(mid: 8, video: video, part: part, progress: 10)
            XCTFail("Foreign account")
        } catch let error as BiliFailure { XCTAssertEqual(error.code, "-101") }
        XCTAssertEqual(writes, 1)
    }
    @MainActor func testDisplayedHistoryAlwaysComesFromCloudAndRefreshSeesExternalUpdates() async throws {
        var progress = 12
        let client = try await fixture { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return ["code": 0, "data": ["list": [self.row(progress)], "cursor": [:]]]
        }
        let history = WatchHistory(client: client)
        history.account(7)
        XCTAssertTrue(history.items.isEmpty)
        await history.load(reset: true)
        XCTAssertEqual(history.items.first?.progress, 12)
        progress = 25
        await history.load(reset: true)
        XCTAssertEqual(history.items.first?.progress, 25)
        history.account(nil)
        XCTAssertTrue(history.items.isEmpty)
    }
    @MainActor func testSlowUploadsAreSerializedAndIntermediateProgressIsCoalesced() async throws {
        let lock = NSLock()
        var reports: [Int] = []
        let client = try await fixture { request in
            let progress = Int(self.form(request)["progress"]!)!
            lock.withLock { reports.append(progress) }
            Thread.sleep(forTimeInterval: 0.1)
            return ["code": 0]
        }
        let history = WatchHistory(client: client)
        history.account(7)
        try history.record(video, part: part, progress: 1, completed: false)
        let deadline = Date().addingTimeInterval(3)
        while lock.withLock({ reports.isEmpty }), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try history.record(video, part: part, progress: 2, completed: false)
        try history.record(video, part: part, progress: 3, completed: false)
        while history.revision < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(lock.withLock { reports }, [1, 3])
        XCTAssertNil(history.syncError)
        XCTAssertTrue(history.items.isEmpty, "A reported watch is not fabricated into a separate local history")
        history.account(nil)
    }
    @MainActor func testRapidVideoChangesKeepEachVideoWhileCoalescingOnlyItsOwnProgress() async throws {
        let lock = NSLock()
        var reports: [String] = []
        let client = try await fixture { request in
            let aid = self.form(request)["aid"]!
            lock.withLock { reports.append(aid) }
            Thread.sleep(forTimeInterval: 0.1)
            return ["code": 0]
        }
        let history = WatchHistory(client: client)
        history.account(7)
        try history.record(video, part: part, progress: 1, completed: false)
        let deadline = Date().addingTimeInterval(3)
        while lock.withLock({ reports.isEmpty }), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        var second = video
        second.bvid = "BV0000000002"
        second.aid = 43
        var third = video
        third.bvid = "BV0000000003"
        third.aid = 44
        try history.record(second, part: part, progress: 2, completed: false)
        try history.record(third, part: part, progress: 3, completed: false)
        while history.revision < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(lock.withLock { reports }, ["42", "43", "44"])
        XCTAssertNil(history.syncError)
        history.account(nil)
    }
    @MainActor func testFailedUploadStaysVisibleAndOnlyExplicitRetryResends() async throws {
        var available = false
        var writes = 0
        let client = try await fixture { _ in
            writes += 1
            if !available { throw URLError(.timedOut) }
            return ["code": 0]
        }
        let history = WatchHistory(client: client)
        history.account(7)
        try history.record(video, part: part, progress: 10, completed: false)
        let deadline = Date().addingTimeInterval(3)
        while history.syncError == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(history.syncError)
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(history.items.isEmpty)
        available = true
        history.retry()
        while history.revision < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(writes, 2)
        XCTAssertNil(history.syncError)
        history.account(nil)
    }
    @MainActor func testAccountChangeDiscardsPendingProgressAndOldCloudRows() async throws {
        let client = try await fixture { _ in ["code": 0, "data": ["list": [self.row()], "cursor": [:]]] }
        let history = WatchHistory(client: client)
        history.account(7)
        await history.load(reset: true)
        XCTAssertEqual(history.items.count, 1)
        history.account(8)
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertNil(history.syncError)
        history.account(nil)
        try history.record(video, part: part, progress: 10, completed: false)
        XCTAssertTrue(history.items.isEmpty)
    }
    private func form(_ request: URLRequest) -> [String: String] {
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
        let query =
            URLComponents(string: "https://test.invalid/?" + String(data: data, encoding: .utf8)!)!.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
    }
}
