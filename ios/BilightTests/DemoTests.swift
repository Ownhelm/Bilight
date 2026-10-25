import XCTest

@testable import Bilight

final class DemoTests: XCTestCase {
    func testPublicationFixtureUsesRealParsingWithoutAccountOrNetwork() async throws {
        let client = DemoFixtures.client()
        let user = try await client.restore()
        XCTAssertEqual(user?.name, "Bilight 演示")
        let feed = try await client.following(mid: 910000, cursor: nil)
        XCTAssertEqual(feed.items.count, 3)
        XCTAssertFalse(feed.hasMore)
        XCTAssertEqual(feed.items.first?.author.name, "山间放映室")
        let people = try await client.followedPeople(mid: 910000, page: 1, frequent: true)
        XCTAssertEqual(people.items.count, 3)
        do {
            _ = try await client.http.request("/uncovered-endpoint")
            XCTFail("Unknown requests must not reach the live API")
        } catch {}
        do {
            _ = try await client.http.request("/x/v2/history/report", form: ["progress": "1"])
            XCTFail("Publication previews must not submit writes")
        } catch {}
    }
}
