import XCTest

@testable import Bilight

final class WatchLaterTests: XCTestCase {
    func testPaginationSkipsOfficialDividerAndKeepsActualCID() throws {
        let result = try WatchLaterPage(data: ["count": 21, "list": [row(1), ["aid": -1], row(2)]], page: 1)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.count, 21)
        XCTAssertEqual(result.items.map(\.id), [1, 2])
        XCTAssertEqual(result.items.first?.cid, 10)
        XCTAssertEqual(result.items.first?.progress, 17)
        XCTAssertThrowsError(try WatchLaterPage(data: ["count": 21, "list": [["aid": -1]]], page: 1))
        XCTAssertFalse(try WatchLaterPage(data: ["count": 1, "list": [row(1)]], page: 1).hasMore)
    }

    @MainActor func testCloudAddRemoveUndoAndBatchUseConfirmedAccountState() async throws {
        let lock = NSLock()
        var saved = [1, 2], paths: [String] = []
        let client = try await fixture { request in
            let path = request.url!.path
            if request.httpMethod == "GET" {
                let items = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
                XCTAssertEqual(path, "/x/v2/history/toview/web")
                XCTAssertEqual(items.first(where: { $0.name == "viewed" })?.value, "0")
                XCTAssertEqual(items.first(where: { $0.name == "ps" })?.value, "20")
                let current = lock.withLock { saved }
                return ["code": 0, "data": ["count": current.count, "list": current.map(self.row)]]
            }
            let body = self.body(request)
            var components = URLComponents()
            components.percentEncodedQuery = body.contains("\r\n") ? nil : body
            let form = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if path != "/x/v2/history/toview/v2/dels" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                XCTAssertEqual(form["csrf"], "offline-fixture")
            }
            try lock.withLock {
                paths.append(path)
                switch path {
                case "/x/v2/history/toview/add": saved.insert(try XCTUnwrap(Int(form["aid"] ?? "")), at: 0)
                case "/x/v2/history/toview/del": saved.removeAll { String($0) == form["aid"] }
                case "/x/v2/history/toview/v2/dels":
                    let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
                    let prefix = "multipart/form-data; boundary="
                    XCTAssertTrue(contentType.hasPrefix(prefix))
                    let boundary = contentType.dropFirst(prefix.count)
                    XCTAssertTrue(body.contains("--\(boundary)\r\nContent-Disposition: form-data; name=\"resources\"\r\n\r\n1,2\r\n"))
                    XCTAssertTrue(body.contains("--\(boundary)\r\nContent-Disposition: form-data; name=\"csrf\"\r\n\r\noffline-fixture\r\n"))
                    XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
                    saved.removeAll { $0 == 1 || $0 == 2 }
                default: XCTFail("Unexpected mock route \(path)")
                }
            }
            return ["code": 0]
        }
        let store = WatchLaterStore(client: client)
        store.account(7)
        await store.read()
        XCTAssertEqual(store.items.map(\.id), [1, 2])
        let candidate = try XCTUnwrap(Video.map(row(3)))
        store.toggle(candidate)
        store.toggle(candidate)
        try await waitForWrites(store)
        XCTAssertEqual(store.items.map(\.id), [3, 1, 2])
        XCTAssertEqual(store.notice?.text, "已加入稍后再看")

        store.remove(Array(store.items.suffix(2)))
        try await waitForWrites(store)
        XCTAssertEqual(store.items.map(\.id), [3])
        let removal = try XCTUnwrap(store.notice)
        XCTAssertEqual(removal.removed.count, 2)
        store.undo(removal)
        try await waitForWrites(store)
        XCTAssertEqual(store.items.map(\.id), [1, 2, 3])
        store.remove([try XCTUnwrap(store.items.first)])
        try await waitForWrites(store)
        XCTAssertEqual(store.items.map(\.id), [2, 3])
        XCTAssertEqual(lock.withLock { paths }, [
            "/x/v2/history/toview/add", "/x/v2/history/toview/v2/dels", "/x/v2/history/toview/add",
            "/x/v2/history/toview/add", "/x/v2/history/toview/del",
        ])
        store.account(nil)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.notice)
    }

    @MainActor func testTappingAnUnconfirmedAddDoesNotRemoveAnItemOnALaterPage() async throws {
        let client = try await fixture { request in
            XCTAssertEqual(request.httpMethod, "GET", "A user who taps Add must not accidentally remove a saved item")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let pn = query.first { $0.name == "pn" }?.value
            let current = pn == "1" ? [self.row(1)] : [self.row(7)]
            return ["code": 0, "data": ["count": 21, "list": current]]
        }
        let store = WatchLaterStore(client: client)
        store.account(7)
        await store.read()
        XCTAssertFalse(store.contains(7))
        store.toggle(try XCTUnwrap(Video.map(row(7))))
        try await waitForWrites(store)
        XCTAssertTrue(store.contains(7))
        XCTAssertEqual(store.notice?.text, "已加入稍后再看")
    }

    @MainActor private func waitForWrites(_ store: WatchLaterStore) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !store.pending.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.pending.isEmpty)
    }

    private func row(_ aid: Int) -> JSON {
        ["aid": aid, "bvid": "BV000000000\(aid)", "cid": aid * 10, "title": "视频 \(aid)", "progress": 17,
         "owner": ["mid": 20, "name": "UP"]]
    }

    private func fixture(_ handler: @escaping (URLRequest) throws -> JSON) async throws -> BiliClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        MockProtocol.responseHeaders = [:]
        MockProtocol.stalledPath = nil
        MockProtocol.handler = { request in
            if request.url!.path == "/x/web-interface/nav" {
                return ["code": 0, "data": ["isLogin": true, "mid": 7, "uname": "Fixture"]]
            }
            return try handler(request)
        }
        let client = BiliClient(http: BiliHTTP(configuration: config, vault: MemoryVault()))
        let cookies = ["SESSDATA", "bili_jct"].map {
            HTTPCookie(properties: [.name: $0, .value: "offline-fixture", .domain: ".bilibili.com", .path: "/", .secure: "TRUE"])!
        }
        _ = try await client.acceptLogin(cookies)
        return client
    }

    private func body(_ request: URLRequest) -> String {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
