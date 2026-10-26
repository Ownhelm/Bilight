import XCTest

@testable import Bilight

final class DemoTests: XCTestCase {
    func testPublicationFixtureUsesRealParsingWithoutAccountOrNetwork() async throws {
        let client = DemoFixtures.client()
        let user = try await client.restore()
        XCTAssertEqual(user?.name, "Bilight 演示")
        let feed = try await client.following(mid: 910000, cursor: nil)
        XCTAssertEqual(feed.items.count, 8)
        XCTAssertFalse(feed.hasMore)
        XCTAssertEqual(Set(feed.items.map { $0.author.name }), Set(["影视飓风", "小鹿Lawrence", "超Carry的柴西"]))
        let people = try await client.followedPeople(mid: 910000, page: 1, frequent: true)
        XCTAssertEqual(people.items.count, 3)
        for person in people.items {
            let creator = try await client.creator(person.user.mid)
            XCTAssertEqual(creator.name, person.user.name)
            let videos = try await client.creatorVideos(creator.mid, page: 1, owner: creator)
            XCTAssertFalse(videos.items.isEmpty)
            XCTAssertTrue(videos.items.allSatisfy { $0.owner.mid == creator.mid })
            let groups = try await client.collections(creator.mid, page: 1)
            XCTAssertFalse(groups.items.isEmpty)
            XCTAssertTrue(groups.items.allSatisfy { $0.mid == creator.mid })
            let video = try XCTUnwrap(videos.items.first)
            let detail = try await client.video(video.bvid)
            XCTAssertEqual(detail.video.bvid, video.bvid)
            XCTAssertEqual(detail.video.owner.mid, creator.mid)
            XCTAssertNotNil(detail.statistics)
            let cover = try XCTUnwrap(video.cover)
            if Bundle.main.url(forResource: "DemoAssets", withExtension: nil) != nil {
                XCTAssertNotNil(DemoFixtures.image(cover))
            } else {
                // The portable code checkout intentionally has no publication images.
                XCTAssertNil(DemoFixtures.image(cover))
            }
        }
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
