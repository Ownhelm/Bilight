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
            case "/x/web-interface/nav": return ["code": 0, "data": ["isLogin": true, "mid": 3, "uname": "Viewer", "wbi_img": ["img_url": "https://i0.hdslb.com/" + String(repeating: "a", count: 32) + ".png", "sub_url": "https://i0.hdslb.com/" + String(repeating: "b", count: 32) + ".png"]]]
            case "/x/frontend/finger/spi": return ["code": 0, "data": ["b_3": "test-official-device-0001"]]
            default: return try handler(request)
            }
        }
        let http = BiliHTTP(configuration: configuration, vault: MemoryVault())
        return (BiliClient(http: http), http)
    }
    @MainActor func testPlaybackPreferencesRestoreAcrossModelsAndOnlyExplicitChoicesReplaceQuality() throws {
        let suite = "Bilight.PlaybackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertFalse(preferences.danmakuEnabled)
        XCTAssertEqual(preferences.quality, 127)
        preferences.danmakuEnabled = true
        preferences.quality = 120
        let restored = PlaybackPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let model = PlayerModel(preferences: restored)
        defer { model.stop() }
        XCTAssertTrue(model.danmakuEnabled)
        func playback(_ ids: [Int]) throws -> Playback {
            try BiliClient.mapPlayback(["dash": ["duration": 60, "video": ids.map {
                ["id": $0, "codecs": "avc1.640028", "base_url": "https://edge.bilivideo.com/video.m4s"] as JSON
            }]], native: nil, quality: restored.quality)
        }
        let lower = try playback([64, 80])
        XCTAssertEqual(lower.quality, 80)
        XCTAssertEqual(restored.quality, 120)
        XCTAssertEqual(try playback([32, 64]).quality, 64)
        XCTAssertEqual(try playback([80, 120]).quality, 120)
        model.playback = lower; model.qualityChoices = lower.qualities
        let (client, _) = fixture { _ in XCTFail("Selecting the current quality must not reload media"); return [:] }
        model.selectQuality(80, client: client, bvid: bvid, part: VideoPart(cid: 5, page: 1, title: "P1", duration: 60))
        XCTAssertEqual(PlaybackPreferences(defaults: defaults).quality, 80)
        preferences.danmakuEnabled = false
        model.stop()
        let next = PlayerModel(preferences: PlaybackPreferences(defaults: defaults))
        XCTAssertFalse(next.danmakuEnabled)
        next.stop()
        defaults.set(-1, forKey: "bilight.playback.quality")
        XCTAssertEqual(preferences.quality, 127)
    }
    @MainActor func testNewPartsAndRecreatedPlayerRestoreDanmakuWithoutSavingTransientFailures() async throws {
        let suite = "Bilight.PlaybackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.danmakuEnabled = true; preferences.quality = 120
        let lock = NSLock()
        var qualities: [String] = [], danmaku: [String] = []
        let (client, _) = fixture { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if request.url!.path.hasSuffix("/playurl") {
                lock.withLock { qualities.append(query.first { $0.name == "qn" }!.value!) }
                return ["code": -403, "message": "Test-only unavailable media"]
            }
            if request.url!.path.hasSuffix("/list.so") {
                lock.withLock { danmaku.append(query.first { $0.name == "oid" }!.value!) }
                throw URLError(.notConnectedToInternet)
            }
            return ["code": 0, "data": ["subtitle": ["subtitles": []]]]
        }
        let first = PlayerModel(preferences: preferences)
        first.load(client: client, bvid: bvid, part: VideoPart(cid: 5, page: 1, title: "P1", duration: 60))
        let deadline = Date().addingTimeInterval(3)
        while (first.error == nil || first.danmakuError == nil), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(first.error); XCTAssertNotNil(first.danmakuError)
        XCTAssertTrue(preferences.danmakuEnabled); XCTAssertTrue(first.danmakuEnabled)
        first.stop()
        let second = PlayerModel(preferences: PlaybackPreferences(defaults: defaults))
        defer { second.stop() }
        second.load(client: client, bvid: bvid, part: VideoPart(cid: 6, page: 2, title: "P2", duration: 60))
        let secondDeadline = Date().addingTimeInterval(3)
        while (second.error == nil || second.danmakuError == nil), Date() < secondDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(lock.withLock { qualities }, ["120", "120"])
        XCTAssertEqual(lock.withLock { danmaku }, ["5", "6"])
        second.setDanmakuEnabled(false, client: client, cid: 6)
        second.load(client: client, bvid: bvid, part: VideoPart(cid: 7, page: 3, title: "P3", duration: 60))
        let thirdDeadline = Date().addingTimeInterval(3)
        while second.error == nil, Date() < thirdDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(second.danmakuEnabled); XCTAssertFalse(preferences.danmakuEnabled)
        XCTAssertEqual(lock.withLock { danmaku }, ["5", "6"], "Disabled preferences must not fetch danmaku")
        XCTAssertEqual(preferences.quality, 120)
    }
    func testQualityBelowAvailableMinimumUsesLowestStreamWithoutUpshiftingToHighest() throws {
        let data: JSON = ["dash": ["duration": 60, "video": [64, 120, 80].map {
            ["id": $0, "codecs": "avc1.640028", "base_url": "https://edge.bilivideo.com/video.m4s"] as JSON
        }]]
        XCTAssertEqual(try BiliClient.mapPlayback(data, native: nil, quality: 16).quality, 64)
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
    @MainActor func testDanmakuAreaRestoresAcrossPlayersAndInvalidStoredValueFallsBack() throws {
        let suite = "Bilight-area-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.danmakuArea, .full)
        let model = PlayerModel(preferences: preferences)
        defer { model.stop() }
        model.danmakuArea = .quarter
        let next = PlayerModel(preferences: PlaybackPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
        defer { next.stop() }
        XCTAssertEqual(next.danmakuArea, .quarter)
        defaults.set(0.1, forKey: "bilight.playback.danmakuArea")
        XCTAssertEqual(preferences.danmakuArea, .full)
    }
    @MainActor func testPlayerSettingsGroupCaptionsAndMinimalDanmakuControls() throws {
        let suite = "Bilight-area-menu-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(preferences: PlaybackPreferences(defaults: defaults))
        defer { model.stop() }
        let player = NativePlayer(model: model, onDanmaku: { model.danmakuEnabled = $0 }, onQuality: { _ in })
        func section(_ title: String) throws -> UIMenu {
            try XCTUnwrap(player.settingsMenu().children.compactMap { $0 as? UIMenu }.first { $0.title == title })
        }
        func perform(_ action: UIAction) {
            let button = UIButton()
            button.addAction(action, for: .touchUpInside)
            button.sendActions(for: .touchUpInside)
        }
        let unavailable = try XCTUnwrap(section("字幕").children.first as? UIAction)
        XCTAssertTrue(unavailable.attributes.contains(.disabled))
        model.subtitleTracks = [SubtitleTrack(id: 1, language: "zh-CN", label: "中文", url: URL(string: "https://example.com/zh.json")!)]
        model.selectedSubtitle = 1
        let captions = try section("字幕").children.compactMap { $0 as? UIAction }
        XCTAssertEqual(captions.map(\.title), ["关闭字幕", "中文"])
        XCTAssertEqual(captions[1].state, .on)
        perform(captions[0])
        XCTAssertNil(model.selectedSubtitle)
        XCTAssertEqual(try (section("字幕").children[0] as? UIAction)?.state, .on)

        XCTAssertEqual(try section("弹幕").children.count, 1)
        perform(try XCTUnwrap(section("弹幕").children.first as? UIAction))
        XCTAssertTrue(model.danmakuEnabled)
        let danmaku = try section("弹幕")
        XCTAssertEqual((danmaku.children[0] as? UIAction)?.state, .on)
        let sizes = try XCTUnwrap(danmaku.children[1] as? UIMenu)
        XCTAssertEqual(danmaku.children.count, 3)
        let area = try XCTUnwrap(danmaku.children[2] as? UIMenu)
        XCTAssertEqual(area.title, "显示区域")
        XCTAssertTrue(area.options.contains(.displayInline))
        XCTAssertTrue(area.options.contains(.singleSelection))
        XCTAssertEqual(area.children.map(\.title), ["1/4", "1/2", "3/4", "全屏"])
        perform(try XCTUnwrap(area.children[1] as? UIAction))
        XCTAssertEqual(model.danmakuArea, .half)
        let updatedArea = try XCTUnwrap(section("弹幕").children[2] as? UIMenu)
        XCTAssertEqual((updatedArea.children[1] as? UIAction)?.state, .on)
        perform(try XCTUnwrap(sizes.children.last as? UIAction))
        XCTAssertEqual(model.danmakuFontSize, 24)
        perform(try XCTUnwrap(section("弹幕").children.first as? UIAction))
        XCTAssertFalse(model.danmakuEnabled)
        XCTAssertEqual(try section("弹幕").children.count, 1)
        // Offline playback does not expose an unavailable online danmaku control.
        let offline = NativePlayer(model: model, onQuality: { _ in })
        XCTAssertFalse(offline.settingsMenu().children.contains { $0.title == "弹幕" })
    }
    private var detail: JSON {
        ["bvid": bvid, "aid": 10, "title": "Mock video", "copyright": 1,
         "owner": ["mid": 7, "name": "Creator"], "pages": [["cid": 20, "page": 1, "part": "P1", "duration": 60]],
         "stat": ["like": 3007000, "coin": 339000, "favorite": 370000]]
    }
    func testSeparateLikeTogglesAndDoesNotRepeatAnAlreadyAppliedWrite() async throws {
        var liked = false, posts = 0
        let (client, http) = fixture { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url!.path, "/x/web-interface/archive/like")
                let text = String(data: request.httpBody ?? self.streamData(request.httpBodyStream), encoding: .utf8)!
                liked = text.contains("like=1"); posts += 1
                return ["code": 0]
            }
            return ["code": 0, "data": ["like": liked, "coin": 0, "favorite": false]]
        }
        _ = try await http.acceptLogin(cookies)
        let yes = try await client.writeVideo(bvid, action: .like(true))
        XCTAssertTrue(yes.liked)
        _ = try await client.writeVideo(bvid, action: .like(true))
        XCTAssertEqual(posts, 1)
        let no = try await client.writeVideo(bvid, action: .like(false))
        XCTAssertFalse(no.liked); XCTAssertEqual(posts, 2)
    }
    func testCoinUsesRemainingDifferenceAndNeverSpendsAgainForTheSameTarget() async throws {
        var coins = 1, posts = 0
        let (client, http) = fixture { request in
            if request.url!.path == "/x/web-interface/wbi/view" { return ["code": 0, "data": self.detail] }
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url!.path, "/x/web-interface/coin/add")
                let body = String(data: request.httpBody ?? self.streamData(request.httpBodyStream), encoding: .utf8)!
                XCTAssertTrue(body.contains("multiply=1")); XCTAssertTrue(body.contains("select_like=1"))
                posts += 1; coins += 1
                return ["code": 0, "data": ["like": true]]
            }
            return ["code": 0, "data": ["like": coins == 2, "coin": coins, "favorite": false]]
        }
        _ = try await http.acceptLogin(cookies)
        let state = try await client.writeVideo(bvid, action: .coin(target: 2, like: true))
        XCTAssertEqual(state.coins, 2)
        _ = try await client.writeVideo(bvid, action: .coin(target: 2, like: true))
        XCTAssertEqual(posts, 1)
        do { _ = try await client.writeVideo(bvid, action: .coin(target: 3, like: true)); XCTFail("must enforce copyright limit") } catch {}
        XCTAssertEqual(posts, 1)
    }
    func testFavoritesSubmitOnlyFolderDifferencesAndRejectAnotherAccountsFolder() async throws {
        var selected = Set([11]), posts = 0
        let (client, http) = fixture { request in
            switch request.url!.path {
            case "/x/web-interface/wbi/view": return ["code": 0, "data": self.detail]
            case "/x/v3/fav/folder/created/list-all":
                return ["code": 0, "data": ["count": 2, "list": [11, 12].map { id in
                    ["id": id, "mid": 3, "title": "Folder", "media_count": 2, "fav_state": selected.contains(id) ? 1 : 0, "attr": 2] as JSON
                }]]
            case "/x/v3/fav/resource/deal":
                let body = String(data: request.httpBody ?? self.streamData(request.httpBodyStream), encoding: .utf8)!
                XCTAssertTrue(body.contains("add_media_ids=12")); XCTAssertTrue(body.contains("del_media_ids=11")); XCTAssertTrue(body.contains("rid=10"))
                posts += 1; selected = [12]; return ["code": 0]
            default: return ["code": 0, "data": ["like": false, "coin": 0, "favorite": !selected.isEmpty]]
            }
        }
        _ = try await http.acceptLogin(cookies)
        _ = try await client.writeVideo(bvid, action: .favorite([12]))
        _ = try await client.writeVideo(bvid, action: .favorite([12]))
        XCTAssertEqual(posts, 1)
        do { _ = try await client.writeVideo(bvid, action: .favorite([999])); XCTFail("foreign folder must be rejected") } catch {}
        XCTAssertEqual(posts, 1)
    }
    @MainActor func testLikePressSeparatesTapHoldCancelAndExactlyOneTriple() async throws {
        let press = LikePressState(hold: .milliseconds(20), charge: .milliseconds(60))
        var taps = 0, triples = 0, charging = false
        press.onTap = { taps += 1 }; press.onTriple = { triples += 1 }; press.onCharge = { charging = $0 }
        press.begin(); press.end()
        XCTAssertEqual(taps, 1); XCTAssertEqual(triples, 0)
        press.begin(); try await Task.sleep(for: .milliseconds(35)); XCTAssertTrue(charging)
        press.cancel(); try await Task.sleep(for: .milliseconds(80)); press.end()
        XCTAssertFalse(charging); XCTAssertEqual(taps, 1); XCTAssertEqual(triples, 0)
        press.begin(); try await Task.sleep(for: .milliseconds(130)); press.end(); press.end()
        XCTAssertEqual(triples, 1); XCTAssertEqual(taps, 1)
    }
    func testStatisticsAndDanmakuParseRealShapesAndRejectMalformedOrExternalEntities() throws {
        let counts = try VideoStatistics.map(["like": 3007000, "coin": 339000, "favorite": 370000])
        XCTAssertEqual(counts.likes, 3007000)
        XCTAssertThrowsError(try VideoStatistics.map(["like": -1, "coin": 1, "favorite": 1]))
        XCTAssertThrowsError(try VideoStatistics.map(["like": 1]))
        let xml = "<i><d p='1.2,1,25,16777215'>hello &amp; world</d><d p='2,5,25,16711680'>top</d><d p='3,7,25,1'>unsupported</d></i>"
        let items = try Danmaku.parse(Data(xml.utf8))
        XCTAssertEqual(items.count, 2); XCTAssertEqual(items[0].text, "hello & world"); XCTAssertEqual(items[1].mode, 5)
        XCTAssertThrowsError(try Danmaku.parse(Data("<!DOCTYPE i [<!ENTITY x SYSTEM 'file:///private'>]><i>&x;</i>".utf8)))
        XCTAssertThrowsError(try Danmaku.parse(Data("<i><d>broken".utf8)))
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
