import AVKit
import SwiftUI
import XCTest

@testable import Bilight

final class VideoSupportTests: XCTestCase {
    @MainActor func testCommentPlaceholderClearsDuringUncommittedPinyin() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        let composer = VideoCommentComposer(channel: .video(aid: 42, bvid: "BV12qnt6VEM1"), target: nil,
            participants: [], onPost: { _, _ in XCTFail("Entering text must not publish a comment") })
        window.rootViewController = UIHostingController(rootView: composer.environmentObject(AppModel()))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }

        func findEditor(in view: UIView) -> UITextView? {
            if view.accessibilityIdentifier == "video-comment-input" { return view as? UITextView }
            for subview in view.subviews {
                if let editor = findEditor(in: subview) { return editor }
            }
            return nil
        }
        try await Task.sleep(for: .milliseconds(250))
        let editor = try XCTUnwrap(findEditor(in: window))
        XCTAssertTrue(editor.becomeFirstResponder())

        func screenshot() -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }

        func pixels(in image: UIImage, at sample: CGRect, matching matches: (Int, Int, Int) -> Bool) throws -> Int {
            let patch = try XCTUnwrap(image.cgImage?.cropping(to: sample.integral))
            let count = patch.width * patch.height
            var bytes = [UInt8](repeating: 0, count: count * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: patch.width, height: patch.height,
                    bitsPerComponent: 8, bytesPerRow: patch.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(patch, in: CGRect(x: 0, y: 0, width: patch.width, height: patch.height))
            }
            return stride(from: 0, to: bytes.count, by: 4).filter {
                matches(Int(bytes[$0]), Int(bytes[$0 + 1]), Int(bytes[$0 + 2]))
            }.count
        }
        func hintPixels(in image: UIImage) throws -> Int {
            // Sample the part of the first line beyond the width of the marked word.
            let editorFrame = editor.convert(editor.bounds, to: window)
            let sample = CGRect(x: editorFrame.minX + 70, y: editorFrame.minY + 8, width: 60, height: 25)
            return try pixels(in: image, at: sample) { red, _, _ in red > 90 }
        }
        func publishHighlight(in image: UIImage) throws -> Int {
            let sample = CGRect(x: window.bounds.maxX - 104, y: window.safeAreaInsets.top, width: 100, height: 65)
            return try pixels(in: image, at: sample) { red, green, blue in red > 120 && red > green + 25 && blue >= green }
        }

        let empty = screenshot()
        let highlight = try publishHighlight(in: empty)
        XCTAssertGreaterThan(highlight, 10, "Publish is already highlighted with an empty draft")
        XCTAssertGreaterThan(try hintPixels(in: empty), 10, "The empty editor shows its placeholder")
        editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        try await Task.sleep(for: .milliseconds(150))
        let composing = screenshot()
        XCTAssertEqual(try hintPixels(in: composing), 0, "Marked Pinyin must not overlap the placeholder")
        XCTAssertEqual(try publishHighlight(in: composing), highlight, "Marked text must not change the Publish highlight")
        let attachment = XCTAttachment(image: composing)
        attachment.name = "未选字时的输入框与发布按钮"
        attachment.lifetime = .keepAlways
        add(attachment)

        editor.insertText("你好")
        XCTAssertNil(editor.markedTextRange)
        XCTAssertEqual(editor.text, "你好")
        try await Task.sleep(for: .milliseconds(150))
        let committed = screenshot()
        XCTAssertEqual(try hintPixels(in: committed), 0, "Committed text keeps the placeholder hidden")
        XCTAssertEqual(try publishHighlight(in: committed), highlight, "Committing text must not change the Publish highlight")
        editor.deleteBackward()
        editor.deleteBackward()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(try hintPixels(in: screenshot()), 10, "Deleting all text restores the placeholder")
    }

    @MainActor func testOnlineExtrasForCachedVideoPreserveTheLocalPlayerAndExplicitPreferences() async throws {
        let lock = NSLock()
        var paths: [String] = []
        let (client, _) = fixture { request in
            let path = request.url!.path
            lock.withLock { paths.append(path) }
            XCTAssertEqual(path, "/x/player/wbi/v2", "Cached playback must not request a network playback source")
            return ["code": 0, "data": ["subtitle": ["subtitles": []]]]
        }
        let suite = "Bilight.CachedPlayback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.quality = 120; preferences.rate = 1.5; preferences.danmakuEnabled = false
        let model = PlayerModel(preferences: preferences)
        defer { model.stop() }
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        let video = Video(bvid: "BV12qnt6VEM1", aid: 42, title: "缓存播放测试", cover: nil, duration: 12,
            publishedAt: 0, owner: User(mid: 42, name: "隔离测试", avatar: nil), views: 0)
        let record = DownloadRecord(id: UUID(), video: video, part: VideoPart(cid: 43, page: 1, title: "P1", duration: 12), quality: 80, qualityLabel: "1080P")
        model.loadLocal(media, record: record)
        let deadline = Date().addingTimeInterval(5)
        while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        model.player.pause()
        let player = model.player, item = try XCTUnwrap(model.player.currentItem)
        model.loadLocalSupport(client: client, bvid: video.bvid, cid: record.part.cid)
        while lock.withLock({ paths.isEmpty }) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(lock.withLock { paths }, ["/x/player/wbi/v2"])
        XCTAssertTrue(model.player === player); XCTAssertTrue(model.player.currentItem === item)
        XCTAssertFalse(model.player.timeControlStatus == .playing)
        XCTAssertEqual(model.rate, 1.5); XCTAssertEqual(preferences.quality, 120)
        XCTAssertEqual(model.playback?.quality, 80)
    }
    func testExternalShareUsesThePublicSelectedPartURL() {
        let url = videoShareURL(bvid: "BV1xx411c7mD", page: 3)
        XCTAssertEqual(url.absoluteString, "https://www.bilibili.com/video/BV1xx411c7mD/?p=3")
        XCTAssertEqual(videoShareURL(bvid: "BV1xx411c7mD", page: 1).absoluteString, "https://www.bilibili.com/video/BV1xx411c7mD/")

    }
    @MainActor func testDownloadSourceUsesDASHWithoutWaitingForANativeProbe() async throws {
        let lock = NSLock()
        var formats: [String] = []
        let (client, _) = fixture { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            lock.withLock { formats.append(query.first { $0.name == "fnval" }!.value!) }
            return ["code": 0, "data": ["dash": ["duration": 10, "video": [
                ["id": 80, "codecs": "avc1.640028", "base_url": "https://edge.bilivideo.com/video.m4s"]
            ]]]]
        }
        let source = try await client.playback(bvid, cid: 5, quality: 80, preferNative: false)
        XCTAssertEqual(source.quality, 80); XCTAssertNotNil(source.video)
        XCTAssertEqual(lock.withLock { formats }, ["4048"])
    }
    @MainActor func testDownloadRetainsNativeFallbackWhenDASHIsUnavailable() async throws {
        let lock = NSLock()
        var formats: [String] = []
        let (client, _) = fixture { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let format = query.first { $0.name == "fnval" }!.value!
            lock.withLock { formats.append(format) }
            if format == "4048" { return ["code": 0, "data": ["dash": ["video": []]]] }
            return ["code": 0, "data": ["quality": 80, "timelength": 10000,
                "durl": [["url": "https://edge.bilivideo.com/video.mp4"]]]]
        }
        let source = try await client.playback(bvid, cid: 5, quality: 80, preferNative: false)
        XCTAssertEqual(source.quality, 80); XCTAssertNotNil(source.mp4)
        XCTAssertEqual(lock.withLock { formats }, ["4048", "1"])
    }
    @MainActor func testInteractionCountsUpdateBeforeTheRequestAndRestoreOnFailure() async throws {
        let (client, http) = fixture { request in
            XCTAssertEqual(request.httpMethod, "GET", "This test cannot send a real or simulated engagement write")
            Thread.sleep(forTimeInterval: 0.15)
            throw URLError(.notConnectedToInternet)
        }
        _ = try await http.acceptLogin(cookies)
        let before = VideoEngagement(liked: true, coins: 1, favorited: false)
        let totals = VideoStatistics(likes: 10, coins: 20, favorites: 30)
        let actions: [(VideoWrite, VideoEngagement, VideoStatistics)] = [
            (.like(false), VideoEngagement(liked: false, coins: 1, favorited: false), VideoStatistics(likes: 9, coins: 20, favorites: 30)),
            (.coin(target: 2, like: true), VideoEngagement(liked: true, coins: 2, favorited: false), VideoStatistics(likes: 10, coins: 21, favorites: 30)),
            (.triple, VideoEngagement(liked: true, coins: 1, favorited: true), VideoStatistics(likes: 10, coins: 20, favorites: 31)),
            (.favorite([1]), VideoEngagement(liked: true, coins: 1, favorited: true), VideoStatistics(likes: 10, coins: 20, favorites: 31)),
        ]
        for (action, expected, expectedTotals) in actions {
            let model = VideoSupportModel()
            model.reset(totals); model.state = before
            let request = Task { await model.write(client: client, bvid: bvid, action: action) }
            while !model.busy { await Task.yield() }
            XCTAssertEqual(model.state, expected, "The icon state must change while the read is still pending")
            XCTAssertEqual(model.statistics, expectedTotals, "The visible counts must change during the request")
            let result = await request.value
            XCTAssertFalse(result); XCTAssertEqual(model.state, before)
            XCTAssertEqual(model.statistics, totals); XCTAssertFalse(model.busy)
            if case .favorite = action { XCTAssertNotNil(model.error) } else { XCTAssertNil(model.error) }
            XCTAssertTrue(model.refreshRequired, "An uncertain result still needs a real read before the next write")
        }
        let model = VideoSupportModel(); model.state = before
        let request = Task { await model.write(client: client, bvid: bvid, action: .triple) }
        while !model.busy { await Task.yield() }
        model.reset(nil)
        _ = await request.value
        XCTAssertNil(model.state, "An old failure cannot restore the previous account's state")
        XCTAssertNil(model.error)
    }
    @MainActor func testConfirmedLikeKeepsItsCountWithoutRequiringPublicTotals() async throws {
        let lock = NSLock(); var liked = false, posts = 0, reads = 0
        let (client, http) = fixture { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url!.path, "/x/web-interface/archive/like")
                lock.withLock { liked = true; posts += 1 }; return ["code": 0, "data": NSNull()]
            }
            XCTAssertEqual(request.url!.path, "/x/web-interface/archive/relation")
            return lock.withLock { reads += 1; return ["code": 0, "data": ["like": liked, "coin": 0, "favorite": false]] }
        }
        _ = try await http.acceptLogin(cookies)
        let model = VideoSupportModel()
        model.reset(VideoStatistics(likes: 10, coins: 20, favorites: 30))
        model.state = VideoEngagement(liked: false, coins: 0, favorited: false)
        let success = await model.write(client: client, bvid: bvid, action: .like(true))
        XCTAssertTrue(success)
        XCTAssertTrue(lock.withLock { reads >= 2 && posts == 1 })
        XCTAssertEqual(model.state?.liked, true)
        XCTAssertFalse(model.busy, "Confirmed likes must not keep coin and favorite disabled while only totals are pending")
        XCTAssertEqual(model.statistics?.likes, 11)
        let repeated = await model.write(client: client, bvid: bvid, action: .like(true))
        XCTAssertTrue(repeated)
        XCTAssertEqual(model.statistics?.likes, 11, "A second confirmation of the same like adds nothing")
        XCTAssertEqual(lock.withLock { posts }, 1)
        model.reset(nil)
        XCTAssertNil(model.statistics)
        await client.logout()
    }
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
    @MainActor func testCaptionChoicesSpeedAndFontSurviveNewVideosAndRecreatedPreferences() async throws {
        let suite = "Bilight.CaptionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        let lock = NSLock()
        var languages = ["en", "zh-CN"]
        let (client, _) = fixture { request in
            if request.url!.path.hasSuffix("/playurl") { return ["code": -403, "message": "Test-only unavailable media"] }
            if request.url!.path.hasSuffix("/list.so") { throw URLError(.notConnectedToInternet) }
            if request.url!.path.hasSuffix(".json") { return ["body": [["from": 0, "to": 10, "content": "Test caption"]]] }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let cid = Int(query.first { $0.name == "cid" }!.value!)!
            return ["code": 0, "data": ["subtitle": ["subtitles": lock.withLock { languages }.enumerated().map { index, language in
                ["id": cid * 100 + index, "lan": language, "lan_doc": language, "subtitle_url": "https://i0.hdslb.com/\(language).json"] as JSON
            }]]]
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        func makePlayer() throws -> PlayerModel {
            PlayerModel(preferences: PlaybackPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))), subtitleConfiguration: configuration)
        }
        func load(_ model: PlayerModel, cid: Int, expectedCount: Int) async throws {
            model.load(client: client, bvid: bvid, part: VideoPart(cid: cid, page: 1, title: "P1", duration: 60))
            let deadline = Date().addingTimeInterval(3)
            while (model.busy || model.subtitleTracks.count != expectedCount || (expectedCount > 0 && model.subtitleTracks.first!.id / 100 != cid)), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(model.subtitleTracks.count, expectedCount)
            if expectedCount > 0 { XCTAssertEqual(model.subtitleTracks.first!.id / 100, cid) }
        }
        let first = try makePlayer()
        try await load(first, cid: 5, expectedCount: 2)
        XCTAssertEqual(first.subtitleTracks.first { $0.id == first.selectedSubtitle }?.language, "zh-CN")
        first.selectSubtitle(first.subtitleTracks.first { $0.language == "en" })
        first.setRate(1.5); first.danmakuFontSize = 24; first.danmakuArea = .half
        first.setDanmakuEnabled(true, client: client, cid: 5)
        first.stop()
        let second = try makePlayer()
        defer { second.stop() }
        XCTAssertEqual(second.rate, 1.5); XCTAssertEqual(second.player.defaultRate, 1.5)
        XCTAssertEqual(second.danmakuFontSize, 24); XCTAssertEqual(second.danmakuArea, .half); XCTAssertTrue(second.danmakuEnabled)
        try await load(second, cid: 6, expectedCount: 2)
        XCTAssertEqual(second.subtitleTracks.first { $0.id == second.selectedSubtitle }?.language, "en")
        second.selectSubtitle(nil); second.setDanmakuEnabled(false, client: client, cid: 6)
        try await load(second, cid: 7, expectedCount: 2)
        XCTAssertNil(second.selectedSubtitle); XCTAssertEqual(second.subtitleText, "")
        XCTAssertFalse(preferences.subtitlesEnabled); XCTAssertEqual(preferences.subtitleLanguage, "en")
        second.stop()
        let restarted = try makePlayer()
        defer { restarted.stop() }
        try await load(restarted, cid: 8, expectedCount: 2)
        XCTAssertNil(restarted.selectedSubtitle); XCTAssertFalse(restarted.danmakuEnabled)
        restarted.setSubtitlesEnabled(true)
        XCTAssertEqual(restarted.subtitleTracks.first { $0.id == restarted.selectedSubtitle }?.language, "en")
        lock.withLock { languages = ["zh-CN"] }
        try await load(restarted, cid: 9, expectedCount: 1)
        XCTAssertEqual(restarted.subtitleTracks.first { $0.id == restarted.selectedSubtitle }?.language, "zh-CN")
        XCTAssertEqual(preferences.subtitleLanguage, "en", "Fallbacks must not replace explicit language choices")
        lock.withLock { languages = [] }
        try await load(restarted, cid: 10, expectedCount: 0)
        XCTAssertNil(restarted.selectedSubtitle); XCTAssertTrue(preferences.subtitlesEnabled)
        lock.withLock { languages = ["zh-CN", "en"] }
        try await load(restarted, cid: 11, expectedCount: 2)
        XCTAssertEqual(restarted.subtitleTracks.first { $0.id == restarted.selectedSubtitle }?.language, "en")
        restarted.selectSubtitle(nil)
        restarted.load(client: client, bvid: bvid, part: VideoPart(cid: 12, page: 1, title: "P1", duration: 60))
        restarted.setSubtitlesEnabled(true); restarted.setSubtitlesEnabled(false)
        let deadline = Date().addingTimeInterval(3)
        while restarted.subtitleTracks.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(restarted.subtitleTracks.count, 2)
        XCTAssertNil(restarted.selectedSubtitle); XCTAssertFalse(preferences.subtitlesEnabled)
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
    @MainActor func testCaptionSwitchRemembersLanguageAndClearsDisabledCuesAndErrors() throws {
        let suite = "Bilight.CaptionSwitch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(preferences: PlaybackPreferences(defaults: defaults))
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
    @MainActor func testPlayerSettingsReflectActualCaptionsAndAvailableDanmakuStyles() throws {
        let suite = "Bilight-area-panel-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(preferences: PlaybackPreferences(defaults: defaults))
        defer { model.stop() }
        let panel = PlaybackSettingsPanel(model: model, onQuality: { _ in }, onDanmaku: { model.danmakuEnabled = $0 }, onClose: {})
        XCTAssertEqual(panel.subtitleLabel, "暂不可用")
        model.subtitleTracks = [SubtitleTrack(id: 1, language: "zh-CN", label: "中文", url: URL(string: "https://example.com/zh.json")!)]
        XCTAssertEqual(panel.subtitleLabel, "关闭")
        model.selectedSubtitle = 1
        XCTAssertEqual(panel.subtitleLabel, "中文")
        XCTAssertFalse(panel.showsDanmakuStyles)
        panel.onDanmaku?(true)
        XCTAssertTrue(panel.showsDanmakuStyles)
        XCTAssertEqual(PlaybackSettingsPanel.fontSizes.map { $0.0 }, ["小", "中", "大"])
        XCTAssertEqual(DanmakuArea.allCases.map(\.title), ["1/4", "1/2", "3/4", "全屏"])
        let offline = PlaybackSettingsPanel(model: model, onQuality: { _ in }, onDanmaku: nil, onClose: {})
        XCTAssertFalse(offline.showsDanmakuStyles)
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
    func testVideoCommentMentionSearchAndPublishingUseRealUserIDsAndReplyTargets() async throws {
        let writes = NSLock()
        var parents: [String?] = []
        let (client, http) = fixture { request in
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            switch url.path {
            case "/x/v2/reply/at":
                let keyword = try XCTUnwrap(query.first { $0.name == "keyword" }?.value)
                XCTAssertTrue(["", "隔"].contains(keyword))
                let item: JSON = ["mid": 24, "name": "隔离测试", "face": "https://i0.hdslb.com/test.jpg"]
                return ["code": 0, "data": ["groups": [["items": [item]], ["items": [item]]]]]
            case "/x/v2/reply/detail":
                XCTAssertEqual(query.first { $0.name == "root" }?.value, "258802991234567890")
                return ["code": 0, "data": ["root": ["rpid_str": "258802991234567890", "root_str": "11",
                    "oid_str": "42", "type": 1, "action": 0, "like": 5]]]
            case "/x/v2/reply/add":
                let form = try self.commentForm(request)
                XCTAssertEqual(query.first { $0.name == "w_rid" }?.value?.count, 32)
                XCTAssertEqual(form["oid"], "42"); XCTAssertEqual(form["type"], "1"); XCTAssertEqual(form["plat"], "1")
                XCTAssertEqual(form["message"], "你好 @隔离测试 "); XCTAssertEqual(form["csrf"], "test-only")
                XCTAssertEqual(form["gaia_source"], "main_web"); XCTAssertEqual(form["root"], form["parent"] == nil ? nil : "11")
                let at = try XCTUnwrap(form["at_name_to_mid"])
                XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(at.utf8)) as? [String: Int], ["隔离测试": 24])
                writes.withLock { parents.append(form["parent"]) }
                let content: JSON = ["message": form["message"]!, "members": [["mid": 24, "uname": "隔离测试"]]]
                let reply: JSON = ["rpid_str": "258802991234567891", "oid_str": "42", "type": 1,
                    "root_str": form["root"] ?? "0", "parent_str": form["parent"] ?? "0",
                    "member": ["mid": 3, "uname": "Viewer"], "content": content]
                return ["code": 0, "data": ["reply": reply, "success_toast": "评论正在审核"]]
            default: XCTFail("Unexpected request path"); throw BiliFailure.invalid
            }
        }
        _ = try await http.acceptLogin(cookies)
        let initialUsers = try await client.commentMentionUsers("")
        XCTAssertEqual(initialUsers.map(\.mid), [24])
        let users = try await client.commentMentionUsers("隔")
        let user = try XCTUnwrap(users.first)
        XCTAssertEqual(users.map(\.mid), [24]); XCTAssertEqual(user.avatar?.host, "i0.hdslb.com")
        let mention = ["隔离测试": 24, "删除后不应发送": 28]
        let channel = CommentChannel.video(aid: 42, bvid: bvid)
        let posted = try await client.postComment(channel: channel, authorMid: 3, message: "你好 @隔离测试 ", mentions: mention)
        XCTAssertEqual(posted.comment.id, "258802991234567891"); XCTAssertEqual(posted.comment.mentions, ["隔离测试": 24])
        XCTAssertEqual(posted.notice, "评论正在审核")
        let target = CommentReplyTarget(root: "11", parent: "258802991234567890", user: user)
        _ = try await client.postComment(channel: channel, authorMid: 3, message: "你好 @隔离测试 ", mentions: mention, target: target)
        XCTAssertEqual(writes.withLock { parents }, [nil, target.parent])
    }
    func testVideoCommentLikeReadsTheExactTargetAndNeverRepeatsTheSameWrite() async throws {
        let lock = NSLock(), rpid = "258802991234567890"
        var liked = false
        var actions: [String] = []
        let (client, http) = fixture { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/x/v2/reply/action" {
                let form = try self.commentForm(request)
                XCTAssertEqual(form["rpid"], rpid); XCTAssertEqual(form["oid"], "42"); XCTAssertEqual(form["type"], "1")
                XCTAssertEqual(form["csrf"], "test-only")
                lock.withLock { actions.append(form["action"] ?? ""); liked = form["action"] == "1" }
                return ["code": 0, "data": NSNull()]
            }
            XCTAssertEqual(url.path, "/x/v2/reply/detail")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "root" }?.value, rpid)
            return lock.withLock { ["code": 0, "data": ["root": ["rpid_str": rpid,
                "oid_str": "42", "type": 1, "action": liked ? 1 : 0, "like": liked ? 6 : 5]]] }
        }
        _ = try await http.acceptLogin(cookies)
        let channel = CommentChannel.video(aid: 42, bvid: bvid)
        let selected = try await client.setCommentLike(channel: channel, actorMid: 3, rpid: rpid, liked: true)
        XCTAssertTrue(selected.liked); XCTAssertEqual(selected.likes, 6)
        _ = try await client.setCommentLike(channel: channel, actorMid: 3, rpid: rpid, liked: true)
        let cancelled = try await client.setCommentLike(channel: channel, actorMid: 3, rpid: rpid, liked: false)
        XCTAssertFalse(cancelled.liked); XCTAssertEqual(cancelled.likes, 5)
        do {
            _ = try await client.setCommentLike(channel: .video(aid: 43, bvid: bvid), actorMid: 3, rpid: rpid, liked: true)
            XCTFail("Must reject comments belonging to another video")
        } catch { XCTAssertEqual((error as? BiliFailure)?.code, "COMMENT_UNAVAILABLE") }
        XCTAssertEqual(lock.withLock { actions }, ["1", "0"])
    }
    @MainActor func testCommentAndReplyLikeBurstsSendOnlyTheFinalTargetAndVerifyTheCount() async throws {
        let lock = NSLock()
        var writes: [String] = [], detailReads = 0
        let (client, http) = fixture { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/x/v2/reply/action" {
                let form = try self.commentForm(request)
                lock.withLock { writes.append("\(form["rpid"] ?? ""):\(form["action"] ?? "")") }
                return ["code": 0, "data": NSNull()]
            }
            XCTAssertEqual(url.path, "/x/v2/reply/detail")
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "root" }?.value
            XCTAssertEqual(id, "12", "A top-level comment that was toggled back must not read or write")
            return lock.withLock {
                detailReads += 1
                return ["code": 0, "data": ["root": ["rpid_str": "12", "oid_str": "42", "type": 1,
                    "action": writes.isEmpty ? 0 : 1, "like": detailReads < 3 ? 12012 : 12019]]]
            }
        }
        _ = try await http.acceptLogin(cookies)
        let app = AppModel(client: client)
        let user = User(mid: 3, name: "隔离账号", avatar: nil)
        app.user = user
        let root = Comment(id: "11", user: user, text: "主评论", createdAt: 0, likes: 5)
        let reply = Comment(id: "12", user: user, text: "回复", createdAt: 0, likes: 12012)
        let channel = CommentChannel.video(aid: 42, bvid: bvid)
        let rootKey = CommentLikeKey(oid: "42", type: 1, id: "11")
        let replyKey = CommentLikeKey(oid: "42", type: 1, id: "12")
        let olderRead = app.commentLikes.revision
        app.toggleCommentLike(root, channel: channel)
        XCTAssertEqual(app.commentLikes.pending[rootKey]?.state, LikeState(liked: true, likes: 6))
        app.toggleCommentLike(root, channel: channel)
        XCTAssertEqual(app.commentLikes.pending[rootKey]?.state, LikeState(liked: false, likes: 5))

        app.toggleCommentLike(reply, channel: channel)
        try await Task.sleep(for: .milliseconds(450))
        app.toggleCommentLike(reply, channel: channel)
        XCTAssertEqual(app.commentLikes.pending[replyKey]?.state, LikeState(liked: false, likes: 12012))
        app.toggleCommentLike(reply, channel: channel)
        XCTAssertEqual(app.commentLikes.pending[replyKey]?.state, LikeState(liked: true, likes: 12013))
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(lock.withLock { detailReads }, 0, "The debounce interval runs from the last tap")

        let end = ContinuousClock.now.advanced(by: .seconds(4))
        while !app.commentLikes.pending.isEmpty && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(app.commentLikes.pending.isEmpty)
        XCTAssertEqual(lock.withLock { writes }, ["12:1"])
        XCTAssertEqual(lock.withLock { detailReads }, 3)
        app.recordCommentLikes([reply], oid: "42", type: 1, readVersion: olderRead)
        XCTAssertEqual(app.commentLikes.confirmed[replyKey], LikeState(liked: true, likes: 12019))
    }
    func testTimedOutVideoCommentPublishReportsUncertaintyWithoutRetrying() async throws {
        let lock = NSLock()
        var writes = 0
        let (client, http) = fixture { request in
            XCTAssertEqual(request.url?.path, "/x/v2/reply/add")
            XCTAssertEqual(request.httpMethod, "POST")
            lock.withLock { writes += 1 }
            throw URLError(.timedOut)
        }
        _ = try await http.acceptLogin(cookies)
        do {
            _ = try await client.postComment(channel: .video(aid: 42, bvid: bvid), authorMid: 3, message: "隔离试验", mentions: [:])
            XCTFail("A timed-out write cannot be confirmed")
        } catch { XCTAssertEqual((error as? BiliFailure)?.code, "COMMENT_UNCONFIRMED") }
        XCTAssertEqual(lock.withLock { writes }, 1)
    }
    func testCommentMentionFindsTheTokenAtTheCaretAndSkipsExistingMentions() throws {
        let message = "🙂你好＠隔离 后面的文字"
        let selection = NSRange(location: "🙂你好＠隔离".utf16.count, length: 0)
        let query = try XCTUnwrap(CommentMentionQuery(text: message, selection: selection))
        XCTAssertEqual(query.keyword, "隔离")
        let range = try XCTUnwrap(Range(query.range, in: message))
        XCTAssertEqual(message.replacingCharacters(in: range, with: "@隔离测试"), "🙂你好@隔离测试 后面的文字")
        for text in ["@隔离测试 ", "name@example", "@隔离测试 后面的文字"] {
            XCTAssertNil(CommentMentionQuery(text: text, selection: NSRange(location: text.utf16.count, length: 0)))
        }
    }
    func testDynamicRepliesAndLikesUseVerifiedCommentOIDAndType() async throws {
        let lock = NSLock()
        let id = "1057955152016703512", oid = "1057955152016703513"
        let root = "258802991234567890", parent = "258802991234567891"
        var liked = false, writes: [String] = []
        let (client, http) = fixture { request in
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            switch url.path {
            case "/x/polymer/web-dynamic/v1/detail":
                XCTAssertEqual(query.first { $0.name == "id" }?.value, id)
                return ["code": 0, "data": ["item": ["type": "DYNAMIC_TYPE_WORD", "id_str": id,
                    "basic": ["comment_type": 17, "comment_id_str": oid], "modules": [
                        "module_author": ["mid": 7, "name": "动态作者"],
                        "module_dynamic": ["desc": ["text": "示例动态"]],
                    ]]]]
            case "/x/v2/reply/detail":
                XCTAssertEqual(query.first { $0.name == "oid" }?.value, oid)
                XCTAssertEqual(query.first { $0.name == "type" }?.value, "17")
                XCTAssertEqual(query.first { $0.name == "root" }?.value, parent)
                return lock.withLock { ["code": 0, "data": ["root": ["rpid_str": parent, "root_str": root,
                    "oid_str": oid, "type": 17, "action": liked ? 1 : 0, "like": liked ? 6 : 5]]] }
            case "/x/v2/reply/action", "/x/v2/reply/add":
                let form = try self.commentForm(request)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://t.bilibili.com/\(id)")
                XCTAssertEqual(form["oid"], oid); XCTAssertEqual(form["type"], "17")
                lock.withLock { writes.append(url.path) }
                if url.path.hasSuffix("/action") {
                    XCTAssertEqual(form["rpid"], parent); XCTAssertEqual(form["action"], "1")
                    lock.withLock { liked = true }
                    return ["code": 0, "data": NSNull()]
                }
                XCTAssertEqual(form["root"], root); XCTAssertEqual(form["parent"], parent)
                return ["code": 0, "data": ["reply": ["rpid_str": "258802991234567892", "oid_str": oid, "type": 17,
                    "root_str": root, "parent_str": parent, "member": ["mid": 3, "uname": "Viewer"],
                    "content": ["message": form["message"] ?? ""]]]]
            default: XCTFail("Unexpected request path"); throw BiliFailure.invalid
            }
        }
        _ = try await http.acceptLogin(cookies)
        let channel = CommentChannel.dynamic(id: id, oid: oid, type: 17)
        let target = CommentReplyTarget(root: root, parent: parent, user: User(mid: 27, name: "回复对象", avatar: nil))
        let after = try await client.setCommentLike(channel: channel, actorMid: 3, rpid: parent, liked: true)
        XCTAssertTrue(after.liked); XCTAssertEqual(after.likes, 6)
        let posted = try await client.postComment(channel: channel, authorMid: 3, message: "动态回复🙂", mentions: [:], target: target)
        XCTAssertEqual(posted.comment.text, "动态回复🙂")
        let stale = CommentChannel.dynamic(id: id, oid: id, type: 17)
        do {
            _ = try await client.postComment(channel: stale, authorMid: 3, message: "不能写到另一评论区", mentions: [:])
            XCTFail("A stale OID must not be written")
        } catch { XCTAssertEqual((error as? BiliFailure)?.code, "COMMENT_UNAVAILABLE") }
        do {
            _ = try await client.setCommentLike(channel: channel, actorMid: 8, rpid: parent, liked: false)
            XCTFail("A different account must not change the like")
        } catch { XCTAssertEqual((error as? BiliFailure)?.code, "ACCOUNT_CHANGED") }
        XCTAssertEqual(lock.withLock { writes }, ["/x/v2/reply/action", "/x/v2/reply/add"])
    }

    func testCommentEmotesUseOfficialMetadataWithoutReplacingNativeEmojiOrUnknownTokens() async throws {
        let imageURL = try XCTUnwrap(URL(string: "https://i0.hdslb.com/bfs/emote/sample.png"))
        let (client, http) = fixture { request in
            XCTAssertEqual(request.url?.path, "/x/v2/reply/wbi/main")
            let row: JSON = ["rpid_str": "12", "content": [
                "message": "🙂@读者 [试验表情][无效来源][原样保留]",
                "at_name_to_mid": ["读者": 24],
                "emote": ["[试验表情]": ["url": imageURL.absoluteString], "[无效来源]": ["url": "https://untrusted.example/a.png"]],
            ]]
            return ["code": 0, "data": ["cursor": ["is_end": true], "replies": [row]]]
        }
        _ = try await http.acceptLogin(cookies)
        let page = try await client.comments(oid: "42", type: 17)
        let comment = try XCTUnwrap(page.items.first)
        XCTAssertEqual(comment.emotes, ["[试验表情]": imageURL])
        XCTAssertEqual(comment.textParts, [
            .text("🙂"), .mention("@读者", 24), .text(" "), .emote("[试验表情]", imageURL), .text("[无效来源][原样保留]"),
        ])
    }
    private func commentForm(_ request: URLRequest) throws -> [String: String] {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = request.httpBody ?? streamData(request.httpBodyStream)
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
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
