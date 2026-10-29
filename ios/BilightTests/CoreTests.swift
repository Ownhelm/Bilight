import AVKit
import Combine
import CryptoKit
import XCTest

@testable import Bilight

final class MemoryVault: SessionVault {
    var cookies: [StoredCookie] = []
    func load() -> [StoredCookie] { cookies }
    func save(_ cookies: [StoredCookie]) { self.cookies = cookies }
    func remove() { cookies = [] }
}
final class MockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> JSON)?
    static var responseHeaders: [String: String] = [:]
    static var stalledPath: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == Self.stalledPath { return }
        do {
            let body = try Self.handler!(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: Self.responseHeaders.merging(["Content-Type": "application/json"]) { _, new in new })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class CoreTests: XCTestCase {
    @MainActor func testPortraitVideoManualFullscreenSurvivesLandscapeAndPortrait() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let model = PlayerModel()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        let asset = AVURLAsset(url: url), composition = AVMutableComposition()
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let source = try XCTUnwrap(tracks.first)
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600)), of: source, at: .zero)
        track.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0)
        let item = AVPlayerItem(asset: composition)
        model.player.replaceCurrentItem(with: item)
        let controller = AVPlayerViewController(); controller.player = model.player
        let host = PlayerContainer(controller: controller, model: model), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.shutdown(); model.stop(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let ready = Date().addingTimeInterval(5)
        while item.presentationSize.height <= item.presentationSize.width && Date() < ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(item.presentationSize.height, item.presentationSize.width)
        host.enterFullscreen()
        try await Task.sleep(for: .milliseconds(200))
        let fullscreen = try XCTUnwrap(host.presentedViewController)
        XCTAssertEqual(fullscreen.preferredInterfaceOrientationForPresentation, .portrait, "A portrait video must enter portrait fullscreen")
        for orientation: UIInterfaceOrientationMask in [.landscapeRight, .portrait, .landscapeLeft, .portrait] {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(model.isFullscreen, "Manual fullscreen must survive rotation back to portrait")
            XCTAssertTrue(host.presentedViewController === fullscreen)
            XCTAssertTrue(model.player.currentItem === item)
        }
        host.exitFullscreen()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.isFullscreen)
        XCTAssertTrue(controller.parent === host)
    }
    @MainActor func testLandscapeFullscreenStillExitsOnReturningToPortrait() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, model = PlayerModel(), controller = AVPlayerViewController()
        controller.player = model.player
        let host = PlayerContainer(controller: controller, model: model), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.shutdown(); model.stop(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let appeared = Date().addingTimeInterval(3)
        while PlaybackOrientationDelegate.active !== host && Date() < appeared { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(PlaybackOrientationDelegate.active === host, "The root must finish appearing before presenting fullscreen")
        for automatic in [false, true] {
            host.enterFullscreen(automatic: automatic)
            let landscape = Date().addingTimeInterval(3)
            while (PlayerContainer.orientation(scene)?.isLandscape != true || host.presentedViewController?.viewIfLoaded?.window == nil || host.presentedViewController?.isBeingPresented == true) && Date() < landscape {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(PlayerContainer.orientation(scene)?.isLandscape == true, "The landscape transition must complete before requesting portrait")
            XCTAssertNotNil(host.presentedViewController?.viewIfLoaded?.window)
            XCTAssertTrue(model.isFullscreen)
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            let portrait = Date().addingTimeInterval(2)
            while model.isFullscreen && Date() < portrait { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(model.isFullscreen, "Existing landscape-video and automatic rotation behavior must remain intact")
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private final class PlaybackEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var pauses = 0, waits = 0
        func record(_ status: AVPlayer.TimeControlStatus) {
            lock.withLock {
                if status == .paused { pauses += 1 }
                if status == .waitingToPlayAtSpecifiedRate { waits += 1 }
            }
        }
        var counts: (Int, Int) { lock.withLock { (pauses, waits) } }
    }
    @MainActor func testPlayingMediaDoesNotPauseOrRebufferAcrossFullscreenRotations() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let model = PlayerModel()
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 3840, height: 2160))
        let item = AVPlayerItem(asset: asset)
        model.player.replaceCurrentItem(with: item)
        let controller = AVPlayerViewController()
        controller.player = model.player
        let host = PlayerContainer(controller: controller, model: model)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { host.shutdown(); window.isHidden = true; previousWindow?.makeKeyAndVisible(); model.stop() }
        model.setRate(1.25)
        model.player.play()
        let ready = Date().addingTimeInterval(5)
        while model.player.currentTime().seconds < 0.4 && Date() < ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.player.timeControlStatus, .playing)
        let events = PlaybackEvents()
        let observation = model.player.observe(\.timeControlStatus, options: [.new]) { player, _ in events.record(player.timeControlStatus) }
        var rateUpdates = 0
        let subscription = model.$rate.dropFirst().sink { _ in rateUpdates += 1 }
        defer { observation.invalidate(); subscription.cancel() }
        let position = model.player.currentTime().seconds
        let began = CACurrentMediaTime()
        for _ in 0..<3 {
            host.enterFullscreen()
            let landscape = Date().addingTimeInterval(2)
            while PlayerContainer.orientation(window.windowScene)?.isLandscape != true && Date() < landscape {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(model.isFullscreen)
            try await Task.sleep(for: .milliseconds(120))
            host.exitFullscreen()
            let portrait = Date().addingTimeInterval(2)
            while (model.isFullscreen || PlayerContainer.orientation(window.windowScene)?.isPortrait != true) && Date() < portrait {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(model.isFullscreen)
            XCTAssertTrue(model.player.currentItem === item)
            try await Task.sleep(for: .milliseconds(120))
        }
        let counts = events.counts
        print("[fullscreen continuity] pauses=\(counts.0) waits=\(counts.1) rateUpdates=\(rateUpdates) elapsedMs=\(Int((CACurrentMediaTime()-began)*1000))")
        XCTAssertEqual(counts.0, 0, "Rotation must not pause a playing item")
        XCTAssertEqual(counts.1, 0, "A buffered local item must not rebuffer solely because it rotates")
        XCTAssertEqual(rateUpdates, 0, "Fullscreen layout must not republish the same playback speed")
        XCTAssertGreaterThan(model.player.currentTime().seconds, position + 0.5)
        XCTAssertEqual(model.player.defaultRate, 1.25)
    }
    @MainActor private final class FullscreenPull: UIPanGestureRecognizer {
        var phase: UIGestureRecognizer.State = .ended
        var distance = CGPoint.zero, speed = CGPoint.zero
        override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
        override func translation(in view: UIView?) -> CGPoint { distance }
        override func setTranslation(_ translation: CGPoint, in view: UIView?) { distance = translation }
        override func velocity(in view: UIView?) -> CGPoint { speed }
    }
    @MainActor func testPortraitFullscreenPullDownExitsAndPreservesPlayer() async throws {
        try await assertFullscreenPull(flick: false)
    }
    @MainActor func testPortraitFullscreenQuickDownwardFlickExits() async throws {
        try await assertFullscreenPull(flick: true)
    }
    @MainActor private func assertFullscreenPull(flick: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let model = PlayerModel()
        model.setRate(1.5)
        let controller = AVPlayerViewController()
        controller.player = model.player
        let host = PlayerContainer(controller: controller, model: model)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { host.shutdown(); window.isHidden = true; previousWindow?.makeKeyAndVisible(); model.stop() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(host.view.gestureRecognizers?.contains { $0.name == "bilight-fullscreen-pull-down" } == true)
        host.enterFullscreen(rotate: false)
        try await Task.sleep(for: .milliseconds(200))
        let fullscreen = try XCTUnwrap(host.presentedViewController)
        XCTAssertTrue(PlayerContainer.orientation(fullscreen.view.window?.windowScene)?.isPortrait == true)
        let registered = try XCTUnwrap(fullscreen.view.gestureRecognizers?.first { $0.name == "bilight-fullscreen-pull-down" } as? UIPanGestureRecognizer)
        if ProcessInfo.processInfo.environment["BILIGHT_PULL_UI_SMOKE"] == "1" {
            // Optional CUA run drives the real registered recognizer instead of a simulated pan.
            let deadline = Date().addingTimeInterval(45)
            while model.isFullscreen && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        } else {
            let gesture = FullscreenPull()
            fullscreen.view.addGestureRecognizer(gesture)
            // Scrubbing horizontally, dragging up, nudging, or cancelling must keep the player open.
            for distance in [CGPoint(x: 150, y: 100), CGPoint(x: 0, y: -120), CGPoint(x: 0, y: 20)] {
                gesture.distance = distance
                host.fullscreenPulled(gesture)
                XCTAssertTrue(model.isFullscreen)
            }
            gesture.distance = CGPoint(x: 5, y: 120)
            gesture.phase = .cancelled
            host.fullscreenPulled(gesture)
            XCTAssertTrue(model.isFullscreen)
            XCTAssertFalse(host.beginFullscreenPull(CGPoint(x: 150, y: 10)))
            XCTAssertTrue(host.beginFullscreenPull(CGPoint(x: 5, y: flick ? 32 : 100)))
            gesture.phase = .began
            gesture.distance = .zero
            host.fullscreenPulled(gesture)
            XCTAssertEqual(gesture.distance.y, flick ? 32 : 100, "Recognition must not discard the initial drag")
            gesture.phase = .ended
            gesture.speed = CGPoint(x: 0, y: flick ? 900 : 100)
            host.fullscreenPulled(gesture)
        }
        let deadline = Date().addingTimeInterval(1)
        while model.isFullscreen && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isFullscreen)
        XCTAssertNil(host.presentedViewController)
        XCTAssertNil(registered.view, "The fullscreen gesture must be removed when returning inline")
        XCTAssertTrue(controller.parent === host)
        XCTAssertTrue(controller.player === model.player)
        XCTAssertEqual(model.player.defaultRate, 1.5)
        XCTAssertEqual(model.player.rate, 0)
    }
    @MainActor func testFullscreenExitButtonWorksInPortrait() async throws {
        try await assertFullscreenExit(settle: true)
    }
    @MainActor func testFullscreenExitButtonWorksDuringPresentation() async throws {
        try await assertFullscreenExit(settle: false)
    }
    @MainActor private func assertFullscreenExit(settle: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let model = PlayerModel()
        model.setRate(1.5)
        let controller = AVPlayerViewController()
        controller.player = model.player
        let host = PlayerContainer(controller: controller, model: model)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { host.shutdown(); window.isHidden = true; previousWindow?.makeKeyAndVisible(); model.stop() }
        try await Task.sleep(for: .milliseconds(150))
        host.enterFullscreen(rotate: false)
        let fullscreen = try XCTUnwrap(host.presentedViewController)
        let button = try XCTUnwrap(fullscreen.view.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "player-fullscreen-toggle" })
        if settle {
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(PlayerContainer.orientation(fullscreen.view.window?.windowScene)?.isPortrait == true)
        }
        XCTAssertTrue(button.isUserInteractionEnabled)
        button.sendActions(for: .touchUpInside)
        let deadline = Date().addingTimeInterval(1)
        while model.isFullscreen && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isFullscreen, "A visible exit button must leave fullscreen even before orientation/presentation settles")
        XCTAssertNil(host.presentedViewController)
        XCTAssertTrue(controller.parent === host)
        XCTAssertTrue(controller.player === model.player)
        XCTAssertEqual(model.player.defaultRate, 1.5)
        XCTAssertEqual(model.player.rate, 0)
    }
    @MainActor func testFullscreenToggleHidesAfterInactivityWithoutReplacingPlayer() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let model = PlayerModel()
        let controller = AVPlayerViewController()
        controller.player = model.player
        let host = PlayerContainer(controller: controller, model: model)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { host.shutdown(); window.isHidden = true; previousWindow?.makeKeyAndVisible(); model.stop() }
        try await Task.sleep(for: .milliseconds(150))
        host.enterFullscreen(rotate: false)
        let fullscreen = try XCTUnwrap(host.presentedViewController)
        let button = try XCTUnwrap(fullscreen.view.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "player-fullscreen-toggle" })
        XCTAssertEqual(button.alpha, 1)
        try await Task.sleep(for: .milliseconds(1900))
        XCTAssertLessThanOrEqual(button.alpha, 0.01, "The fullscreen toggle must not cover the video permanently")
        XCTAssertFalse(button.isUserInteractionEnabled)
        XCTAssertTrue(model.isFullscreen)
        XCTAssertTrue(controller.player === model.player)
        let gesture = try XCTUnwrap(fullscreen.view.gestureRecognizers?.first { $0.name == "bilight-fullscreen-controls" })
        XCTAssertFalse(gesture.cancelsTouchesInView, "Native playback controls must keep receiving touches")
        host.fullscreenSurfaceTapped()
        XCTAssertEqual(button.alpha, 1)
        XCTAssertTrue(button.isUserInteractionEnabled)
        host.fullscreenSurfaceTapped()
        XCTAssertEqual(button.alpha, 0)
    }
    @MainActor func testInlinePlayerLocksPagePortraitUntilFullscreenTakesOver() {
        let model = PlayerModel()
        let host = PlayerContainer(controller: AVPlayerViewController(), model: model)
        let delegate = PlaybackOrientationDelegate()
        defer { PlaybackOrientationDelegate.active = nil; model.stop() }
        PlaybackOrientationDelegate.active = host
        XCTAssertEqual(delegate.application(.shared, supportedInterfaceOrientationsFor: nil), .portrait)
        model.isFullscreen = true
        XCTAssertTrue(delegate.application(.shared, supportedInterfaceOrientationsFor: nil).contains(.landscapeLeft))
        XCTAssertTrue(delegate.application(.shared, supportedInterfaceOrientationsFor: nil).contains(.landscapeRight))
        model.isFullscreen = false
        XCTAssertEqual(delegate.application(.shared, supportedInterfaceOrientationsFor: nil), .portrait)
        PlaybackOrientationDelegate.active = nil
        XCTAssertEqual(delegate.application(.shared, supportedInterfaceOrientationsFor: nil), .allButUpsideDown)
    }
    func testSegmentIndexUsesSmallMetadataAndBuildsExactByteRanges() throws {
        func bytes(_ value: UInt64, _ size: Int) -> Data { Data((0..<size).reversed().map { UInt8((value >> ($0 * 8)) & 255) }) }
        var data = bytes(56, 4) + Data("sidx".utf8) + bytes(0, 4) + bytes(1, 4) + bytes(1000, 4)
        data += bytes(0, 4) + bytes(0, 4) + bytes(0, 2) + bytes(2, 2)
        data += bytes(100, 4) + bytes(6000, 4) + bytes(0x90000000, 4)
        data += bytes(80, 4) + bytes(4000, 4) + bytes(0x90000000, 4)
        let segments = try ByteSegment.parse(data, absoluteOffset: 100, total: 336)
        XCTAssertEqual(segments.map(\.range), [156...255, 256...335])
        XCTAssertEqual(segments.map(\.duration), [6, 4])
        let playlist = String(data: ByteSegment.playlist(segments, initialization: 0...99, path: "video.mp4"), encoding: .utf8)!
        XCTAssertTrue(playlist.contains("BYTERANGE=\"100@0\""))
        XCTAssertTrue(playlist.contains("#EXT-X-BYTERANGE:80@256"))
        XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"))
        XCTAssertThrowsError(try ByteSegment.parse(data, absoluteOffset: 100, total: 200))
        data[32] = 0x80
        XCTAssertThrowsError(try ByteSegment.parse(data, absoluteOffset: 100, total: 336))
    }
    func testDownloadRejectsErrorBodiesAndTruncatedOrForeignMedia() {
        let url = URL(string: "https://cdn.bilivideo.com/video.mp4")!
        let good = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp4", "Content-Length": "100"])!
        XCTAssertNoThrow(try DownloadValidation.response(good, size: 100))
        XCTAssertThrowsError(try DownloadValidation.response(good, size: 50))
        let error = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        XCTAssertThrowsError(try DownloadValidation.response(error, size: 100))
        let foreign = HTTPURLResponse(url: URL(string: "https://example.com/video.mp4")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp4"])!
        XCTAssertThrowsError(try DownloadValidation.response(foreign, size: 100))
    }
    @MainActor func testDownloadsPersistEncryptedAndIsolateAccountAndDuplicateTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = DownloadStore(client: BiliClient(), directory: directory, key: key, automaticallyStarts: false)
        store.account(3, remember: false)
        let video = Video(bvid: "BV0000000001", aid: 1, title: "Private Download Title", cover: nil, duration: 10, publishedAt: 1, owner: User(mid: 7, name: "UP", avatar: nil), views: 0)
        let part = VideoPart(cid: 1, page: 1, title: "Part", duration: 10)
        let id = try store.enqueue(video: video, part: part, quality: 120, label: "4K")
        store.pause(id)
        let duplicate = try store.enqueue(video: video, part: part, quality: 120, label: "4K")
        XCTAssertEqual(duplicate, id)
        let manifest = try Data(contentsOf: directory.appendingPathComponent("Downloads/3/manifest.sealed"))
        XCTAssertNil(manifest.range(of: Data(video.title.utf8)))
        let restored = DownloadStore(client: BiliClient(), directory: directory, key: key, automaticallyStarts: false)
        restored.account(4, remember: false)
        XCTAssertTrue(restored.items.isEmpty)
        restored.account(3, remember: false)
        XCTAssertEqual(restored.items.first?.id, id)
        XCTAssertEqual(restored.items.first?.state, .paused)
        restored.remove(id)
        XCTAssertTrue(restored.items.isEmpty)
        store.account(nil, remember: false)
        XCTAssertTrue(store.items.isEmpty)
    }
    func testFourKPlaybackDoesNotWaitForAnIneligibleLowerQualityMP4Probe() async throws {
        var nativeRequests = 0
        let (client, _, _) = fixture { request in
            if request.url!.path.hasSuffix("/nav") {
                return ["code": 0, "data": ["wbi_img": [
                    "img_url": "https://i0.hdslb.com/" + String(repeating: "a", count: 32) + ".png",
                    "sub_url": "https://i0.hdslb.com/" + String(repeating: "b", count: 32) + ".png",
                ]]]
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if query.first(where: { $0.name == "fnval" })?.value == "1" {
                nativeRequests += 1
                Thread.sleep(forTimeInterval: 0.35)
                return ["code": 0, "data": ["format": "mp4", "quality": 80, "durl": [["url": "https://cdn.bilivideo.com/lower.mp4"]]]]
            }
            return ["code": 0, "data": ["dash": ["duration": 300, "video": [
                ["id": 120, "codecs": "avc1.640033", "baseUrl": "https://cdn.bilivideo.com/4k.m4s", "bandwidth": 20_000_000]
            ], "audio": []], "accept_quality": [120], "accept_description": ["4K"]]]
        }
        let start = Date()
        let playback = try await client.playback("BV0000000001", cid: 1)
        XCTAssertEqual(playback.quality, 120)
        XCTAssertEqual(nativeRequests, 0, "A lower-quality native probe must not delay 4K preparation")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
    }
    func testAccountPeoplePreserveUpstreamAttentionOrderAndPagination() async throws {
        let (client, http, _) = fixture { request in
            if request.url!.path.hasSuffix("/nav") { return ["code": 0, "data": ["isLogin": true, "mid": 3, "uname": "Viewer"]] }
            XCTAssertEqual(request.url!.path, "/x/relation/followings")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "order_type" }?.value, "attention")
            XCTAssertEqual(query.first { $0.name == "vmid" }?.value, "3")
            return ["code": 0, "data": ["total": 21, "list": [
                ["mid": 8, "uname": "First from B站", "attribute": 6],
                ["mid": 7, "uname": "Second from B站", "attribute": 2],
            ]]]
        }
        _ = try await http.acceptLogin(testCookies)
        let page = try await client.followedPeople(mid: 3, page: 1, frequent: true)
        XCTAssertEqual(page.items.map(\.id), [8, 7])
        XCTAssertTrue(page.items[0].relation.mutual)
        XCTAssertTrue(page.hasMore)
        do {
            _ = try await client.followedPeople(mid: 4, page: 1)
            XCTFail("A different account must not receive personal data")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "-101") }
    }
    func testAccountNullListsAreEmptyOnlyWithAnExplicitZeroCount() async throws {
        var total = 0
        let (client, http, _) = fixture { request in
            if request.url!.path.hasSuffix("/nav") { return ["code": 0, "data": ["isLogin": true, "mid": 3, "uname": "Viewer"]] }
            return ["code": 0, "data": ["total": total, "list": NSNull()]]
        }
        _ = try await http.acceptLogin(testCookies)
        let empty = try await client.followedPeople(mid: 3, page: 1)
        XCTAssertTrue(empty.items.isEmpty)
        total = 2
        do {
            _ = try await client.followedPeople(mid: 3, page: 1)
            XCTFail("Missing data must not hide real follows")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "INVALID_RESPONSE") }
    }
    func testFavoriteFoldersValidateOwnershipAndContentsKeepUnavailableRows() async throws {
        var owner = 3
        let (client, http, _) = fixture { request in
            switch request.url!.path {
            case "/x/web-interface/nav": return ["code": 0, "data": ["isLogin": true, "mid": 3, "uname": "Viewer"]]
            case "/x/v3/fav/folder/created/list":
                return ["code": 0, "data": ["count": 1, "has_more": false, "list": [
                    ["id": 1003, "mid": owner, "title": "Private", "attr": 23, "media_count": 2],
                ]]]
            case "/x/v3/fav/resource/list":
                return ["code": 0, "data": [
                    "info": ["id": 1003, "mid": owner, "title": "Private", "attr": 23, "media_count": 2],
                    "has_more": false, "medias": [
                        ["id": 7, "type": 2, "title": "Playable", "bvid": NSNull(), "bv_id": "BV0000000001", "attr": 0, "upper": ["mid": 7, "name": "UP"]],
                        ["id": 8, "type": 2, "title": "已失效视频", "attr": 9],
                    ],
                ]]
            default: XCTFail("Unexpected endpoint"); return [:]
            }
        }
        _ = try await http.acceptLogin(testCookies)
        let folders = try await client.favoriteFolders(mid: 3, collected: false, page: 1)
        let folder = try XCTUnwrap(folders.items.first)
        XCTAssertTrue(folder.isPrivate)
        let content = try await client.favoriteContents(mid: 3, folder: folder, page: 1)
        XCTAssertEqual(content.items.count, 2)
        XCTAssertEqual(content.items[0].video?.owner.mid, 7)
        XCTAssertEqual(content.items[0].video?.bvid, "BV0000000001")
        XCTAssertNil(content.items[1].video)
        owner = 4
        do {
            _ = try await client.favoriteFolders(mid: 3, collected: false, page: 1)
            XCTFail("Created folders must belong to this account")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "INVALID_RESPONSE") }
        do {
            _ = try await client.favoriteContents(mid: 3, folder: folder, page: 1)
            XCTFail("Folder detail cannot silently change ownership")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "INVALID_RESPONSE") }
    }
    @MainActor func testAccountNavigationKeepsCreatorAndVideoInsideAccountStack() {
        let app = AppModel()
        app.showAccount = true
        app.navigate(.followedPeople(false))
        app.open(User(mid: 7, name: "UP", avatar: nil))
        XCTAssertEqual(app.accountPath, [.followedPeople(false), .creator(7)])
        XCTAssertTrue(app.path.isEmpty)
        app.showAccount = false
        app.navigate(.history)
        XCTAssertEqual(app.path, [.history])
    }
    func testFavoriteCreationChecksLimitsAndNeverRetriesAnUncertainWrite() async throws {
        var count = 100
        var writes = 0
        let (client, http, _) = fixture { request in
            switch request.url!.path {
            case "/x/web-interface/nav": return ["code": 0, "data": ["isLogin": true, "mid": 3, "uname": "Viewer"]]
            case "/x/v3/fav/folder/created/list-all": return ["code": 0, "data": ["count": count, "list": []]]
            case "/x/v3/fav/folder/add":
                writes += 1
                throw URLError(.timedOut)
            default: XCTFail("Unexpected endpoint"); return [:]
            }
        }
        _ = try await http.acceptLogin(testCookies)
        do {
            _ = try await client.createFavoriteFolder(mid: 3, title: " ", isPrivate: false)
            XCTFail("Empty names must not be sent")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "FOLDER_TITLE") }
        do {
            _ = try await client.createFavoriteFolder(mid: 3, title: "Folder", isPrivate: false)
            XCTFail("The account has reached its limit")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "FOLDER_LIMIT") }
        XCTAssertEqual(writes, 0)
        count = 99
        do {
            _ = try await client.createFavoriteFolder(mid: 3, title: "Folder", isPrivate: false)
            XCTFail("Timeout must not appear successful")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "WRITE_UNCERTAIN") }
        XCTAssertEqual(writes, 1)
    }
    func testCollectedFoldersKeepOwnerlessEntriesWithoutHidingTheWholePage() async throws {
        let (client, http, _) = fixture { request in
            if request.url!.path.hasSuffix("/nav") { return ["code": 0, "data": ["isLogin": true, "mid": 3, "uname": "Viewer"]] }
            XCTAssertEqual(request.url!.path, "/x/v3/fav/folder/collected/list")
            return ["code": 0, "data": ["count": 21, "has_more": true, "list": [
                ["id": 100, "mid": 0, "title": "Unavailable owner", "media_count": 5, "type": 21],
                ["id": 101, "mid": 7, "title": "Available", "media_count": 2, "type": 11],
            ]]]
        }
        _ = try await http.acceptLogin(testCookies)
        let result = try await client.favoriteFolders(mid: 3, collected: true, page: 1)
        XCTAssertEqual(result.items.map(\.id), [100, 101])
        XCTAssertTrue(result.items[0].unavailable)
        XCTAssertFalse(result.items[1].unavailable)
        XCTAssertTrue(result.hasMore)
    }
    private var testCookies: [HTTPCookie] {
        ["SESSDATA", "bili_jct"].map {
            HTTPCookie(properties: [.name: $0, .value: "test-only", .domain: ".bilibili.com", .path: "/", .secure: "TRUE"])!
        }
    }
    func testOriginalDynamicAcceptsNullOptionalOrigAndOwner() throws {
        let item: JSON = [
            "id_str": "1000000000000000001", "type": "DYNAMIC_TYPE_AV", "orig": NSNull(),
            "modules": [
                "module_author": ["mid": 7, "name": "Real UP", "pub_ts": 1],
                "module_dynamic": [
                    "major": [
                        "type": "MAJOR_TYPE_ARCHIVE",
                        "archive": ["bvid": "BV0000000001", "aid": 7, "title": "Actual", "owner": NSNull()],
                    ]
                ],
            ],
        ]
        let result = BiliClient.dynamicItems([item])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.author.mid, 7)
        XCTAssertEqual(result.first?.author.name, "Real UP")
    }
    func testFollowingRelationCacheCannotCarryBetweenAccountsAndRefreshInvalidatesIt() async throws {
        let lock = NSLock()
        var viewer = 3
        var reads = 0
        let item: JSON = [
            "id_str": "1000000000000000001", "type": "DYNAMIC_TYPE_AV",
            "modules": [
                "module_author": ["mid": 7, "name": "UP", "pub_ts": 1],
                "module_dynamic": [
                    "major": [
                        "type": "MAJOR_TYPE_ARCHIVE", "archive": ["bvid": "BV0000000001", "aid": 7, "title": "Actual"],
                    ]
                ],
            ],
        ]
        let (client, _, _) = fixture { request in
            switch request.url!.path {
            case "/x/web-interface/nav":
                return ["code": 0, "data": ["isLogin": true, "mid": lock.withLock { viewer }, "uname": "Viewer"]]
            case "/x/frontend/finger/spi": return ["code": 0, "data": ["b_3": "test-official-device-0001"]]
            case "/x/polymer/web-dynamic/v1/feed/all": return ["code": 0, "data": ["items": [item], "has_more": 0]]
            case "/x/relation/relations":
                let attribute = lock.withLock {
                    reads += 1
                    return viewer == 3 ? 2 : 0
                }
                return ["code": 0, "data": ["7": ["mid": 7, "attribute": attribute]]]
            default:
                XCTFail("Unexpected endpoint")
                return [:]
            }
        }
        let cookies = ["SESSDATA", "bili_jct"].map {
            HTTPCookie(properties: [
                .name: $0, .value: "test-only", .domain: ".bilibili.com", .path: "/", .secure: "TRUE",
            ])!
        }
        _ = try await client.acceptLogin(cookies)
        let first = try await client.following(mid: 3, cursor: nil)
        XCTAssertEqual(first.items.count, 1)
        lock.withLock { viewer = 4 }
        _ = try await client.acceptLogin(cookies)
        let second = try await client.following(mid: 4, cursor: nil)
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertEqual(lock.withLock { reads }, 2)
        await client.invalidateFollowing()
        _ = try await client.following(mid: 4, cursor: nil)
        XCTAssertEqual(lock.withLock { reads }, 3)
    }
    func testFollowingTimeoutCancelsAStalledRequestInsteadOfSpinningForever() async throws {
        let (_, http, _) = fixture { request in
            if request.url!.path.hasSuffix("/nav") {
                return ["code": 0, "data": ["isLogin": true, "mid": 3, "uname": "Viewer"]]
            }
            return ["code": 0, "data": ["b_3": "test-official-device-0001"]]
        }
        let cookies = ["SESSDATA", "bili_jct"].map {
            HTTPCookie(properties: [
                .name: $0, .value: "test-only", .domain: ".bilibili.com", .path: "/", .secure: "TRUE",
            ])!
        }
        _ = try await http.acceptLogin(cookies)
        MockProtocol.stalledPath = "/x/polymer/web-dynamic/v1/feed/all"
        let client = BiliClient(http: http, followingTimeout: .milliseconds(150))
        let start = Date()
        do {
            _ = try await client.following(mid: 3, cursor: nil)
            XCTFail("A stalled feed must time out")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "FOLLOW_TIMEOUT") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testNullGETDataIsAnErrorWhileAnEmptySuccessfulWriteIsAllowed() async throws {
        let (_, http, _) = fixture { _ in ["code": 0, "data": NSNull()] }
        do {
            _ = try await http.request("/x/test")
            XCTFail("A missing relation object must not become a false empty follow set")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "INVALID_RESPONSE") }
        let result = try await http.request("/x/test", form: ["test": "test-only"])
        XCTAssertTrue(result.isEmpty)
    }
    func testFollowingVerifiesOnlyFeedAuthorsInsteadOfWaitingForEntireFollowList() async throws {
        let lock = NSLock()
        var paths: [String] = []
        func post(_ mid: Int, _ bvid: String) -> JSON {
            [
                "id_str": "100000000000000000\(mid)", "type": "DYNAMIC_TYPE_AV",
                "modules": [
                    "module_author": ["mid": mid, "name": "UP", "pub_ts": mid],
                    "module_dynamic": [
                        "major": [
                            "type": "MAJOR_TYPE_ARCHIVE",
                            "archive": ["bvid": bvid, "aid": mid, "title": "Actual", "duration_text": "01:00"],
                        ]
                    ],
                ],
            ]
        }
        let (client, http, _) = fixture { request in
            let path = request.url!.path
            lock.withLock { paths.append(path) }
            switch path {
            case "/x/web-interface/nav": return ["code": 0, "data": ["isLogin": true, "mid": 3, "uname": "Viewer"]]
            case "/x/frontend/finger/spi": return ["code": 0, "data": ["b_3": "test-official-device-0001"]]
            case "/x/polymer/web-dynamic/v1/feed/all":
                return [
                    "code": 0,
                    "data": [
                        "items": [post(7, "BV0000000001"), post(8, "BV0000000002"), post(9, "BV0000000003")],
                        "has_more": 0,
                    ],
                ]
            case "/x/relation/relations":
                return ["code": 0, "data": ["7": ["attribute": 2], "8": ["attribute": 0], "9": ["attribute": 128]]]
            case "/x/relation/followings": throw URLError(.timedOut)
            default:
                XCTFail("Unexpected endpoint \(path)")
                return [:]
            }
        }
        let cookies = ["SESSDATA", "bili_jct"].map {
            HTTPCookie(properties: [
                .name: $0, .value: "test-only", .domain: ".bilibili.com", .path: "/", .secure: "TRUE",
            ])!
        }
        _ = try await http.acceptLogin(cookies)
        let page = try await client.following(mid: 3, cursor: nil)
        XCTAssertEqual(page.items.map(\.author.mid), [7])
        XCTAssertFalse(page.hasMore)
        _ = try await client.following(mid: 3, cursor: nil)
        let calls = lock.withLock { paths }
        XCTAssertFalse(calls.contains("/x/relation/followings"))
        XCTAssertEqual(
            calls.filter { $0 == "/x/relation/relations" }.count, 1,
            "Confirmed relationships may be reused within the same account")
    }
    func testNativeMP4SelectionUsesRealQualityAndNeverDowngradesHigherDASH() throws {
        func dash(_ quality: Int) -> JSON {
            [
                "dash": [
                    "duration": 60,
                    "video": [
                        ["id": quality, "codecs": "avc1.640028", "base_url": "https://edge.bilivideo.com/video.m4s"]
                    ],
                ], "accept_quality": [quality], "accept_description": ["实际画质"],
            ]
        }
        let mp4: JSON = [
            "format": "mp4720", "quality": 64, "timelength": 60000,
            "durl": [["url": "https://edge.bilivideo.com/video.mp4"]], "accept_quality": [64, 16],
            "accept_description": ["高清 720P", "流畅 360P"],
        ]
        let native = try BiliClient.mapPlayback(dash(32), native: mp4, quality: 127)
        XCTAssertNotNil(native.mp4)
        XCTAssertEqual(native.quality, 64)
        XCTAssertEqual(native.qualities.map(\.id), [64, 16])
        let highest = try BiliClient.mapPlayback(dash(112), native: mp4, quality: 127)
        XCTAssertNil(highest.mp4)
        XCTAssertEqual(highest.video?.id, 112)
        let requested = try BiliClient.mapPlayback(dash(16), native: mp4, quality: 16)
        XCTAssertNil(requested.mp4, "A response above the manually selected quality must not override the selection")
        XCTAssertEqual(requested.quality, 16)
    }
    func testFailedLoginDoesNotPersistIssuedCookies() async throws {
        let (_, http, vault) = fixture { _ in ["code": -101, "message": "Not logged in"] }
        MockProtocol.responseHeaders = ["Set-Cookie": "buvid3=test-issued-device; Domain=.bilibili.com; Path=/; Secure"]
        let cookies = ["SESSDATA", "bili_jct"].map {
            HTTPCookie(properties: [
                .name: $0, .value: "test-only", .domain: ".bilibili.com", .path: "/", .secure: "TRUE",
            ])!
        }
        do {
            _ = try await http.acceptLogin(cookies)
            XCTFail("Login must be verified before persistence")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "-101") }
        XCTAssertTrue(vault.cookies.isEmpty)
        do {
            _ = try await http.csrf()
            XCTFail("Failed candidate session must be removed")
        } catch let failure as BiliFailure { XCTAssertEqual(failure.code, "-101") }
    }
    func testPublicMetadataFallbackUsesOnlyRealSearchSummaryAndVerifiedParts() async throws {
        var paths: [String] = []
        let (client, _, _) = fixture { request in
            paths.append(request.url!.path)
            if request.url!.path.hasSuffix("/nav") {
                return ["code": 0, "data": ["wbi_img": ["img_url": "https://i0.hdslb.com/" + String(repeating: "a", count: 32) + ".png", "sub_url": "https://i0.hdslb.com/" + String(repeating: "b", count: 32) + ".png"]]]
            }
            if request.url!.path.hasSuffix("/view") { return ["code": 0, "data": ["v_voucher": "test-challenge"]] }
            return ["code": 0, "data": [["cid": 42, "page": 2, "part": "真实分 P", "duration": 60]]]
        }
        let known = Video(
            bvid: "BV0000000001", aid: 1, title: "真实搜索标题", cover: nil, duration: 60, publishedAt: 1,
            owner: User(mid: 7, name: "UP", avatar: nil), views: 1)
        let result = try await client.video(known.bvid, known: known)
        XCTAssertEqual(result.video.title, known.title)
        XCTAssertEqual(result.parts.first?.cid, 42)
        XCTAssertEqual(result.parts.first?.page, 2)
        XCTAssertNotNil(result.warning)
        XCTAssertNil(result.coinLimit)
        XCTAssertEqual(paths, ["/x/web-interface/nav", "/x/web-interface/wbi/view", "/x/player/pagelist"])
    }
    func testPermissionFailuresAreNotReplacedWithPublicMetadata() async throws {
        var requests = 0
        let (client, _, _) = fixture { request in
            if request.url!.path.hasSuffix("/nav") {
                return ["code": 0, "data": ["wbi_img": ["img_url": "https://i0.hdslb.com/" + String(repeating: "a", count: 32) + ".png", "sub_url": "https://i0.hdslb.com/" + String(repeating: "b", count: 32) + ".png"]]]
            }
            requests += 1
            return ["code": 62002, "message": "稿件不可见"]
        }
        let known = Video(
            bvid: "BV0000000001", aid: 1, title: "Known", cover: nil, duration: 60, publishedAt: 1,
            owner: User(mid: 7, name: "UP", avatar: nil), views: 1)
        do {
            _ = try await client.video(known.bvid, known: known)
            XCTFail("Permissions must remain enforced")
        } catch let error as BiliFailure { XCTAssertEqual(error.code, "62002") }
        XCTAssertEqual(requests, 1)
    }
    func testWBISignsTheExactSortedEncodedQuery() {
        XCTAssertEqual(
            BiliHTTP.signedQuery(
                ["foo": "hello world", "keyword": "合集!()*'"], key: "0123456789abcdef0123456789abcdef",
                timestamp: 1_700_000_000),
            "foo=hello%20world&keyword=%E5%90%88%E9%9B%86&wts=1700000000&w_rid=e914846d2e76419591c87396a962f167")
    }
    func testCookieScopeAndExpiryNeverLeaksToCDNOrLookalikes() {
        let cookie = StoredCookie(
            HTTPCookie(properties: [
                .name: "SESSDATA", .value: "test-only", .domain: ".bilibili.com", .path: "/account", .secure: "TRUE",
                .expires: Date().addingTimeInterval(100),
            ])!)
        XCTAssertTrue(cookie.matches(URL(string: "https://passport.bilibili.com/account/login")!))
        for value in [
            "http://passport.bilibili.com/account", "https://bilibili.com.evil.test/account",
            "https://evilbilibili.com/account", "https://i0.hdslb.com/account",
            "https://passport.bilibili.com/accountant",
        ] { XCTAssertFalse(cookie.matches(URL(string: value)!)) }
        XCTAssertFalse(
            cookie.matches(URL(string: "https://passport.bilibili.com/account")!, now: Date().addingTimeInterval(200)))
    }
    func testAllowedSourcesRejectHTTPAndArbitraryResources() {
        for value in ["https://upos.bilivideo.com/video.m4s", "https://i0.hdslb.com/face.jpg"] {
            XCTAssertTrue(MediaLoader.allowed(URL(string: value)!))
        }
        for value in [
            "http://upos.bilivideo.com/video", "https://bilivideo.com.evil.test/x", "https://127.0.0.1/x",
            "https://user:pass@upos.bilivideo.com/x", "https://upos.bilivideo.com:444/x",
        ] { XCTAssertFalse(MediaLoader.allowed(URL(string: value)!)) }
        XCTAssertFalse(BiliHTTP.trusted(URL(string: "https://evilbilibili.com/x")!))
    }
    func testCollectionsKeepKindsAndValidateCreatorOwnership() throws {
        let season: JSON = [
            "meta": ["season_id": 9, "mid": 7, "name": "<b>课程</b>", "total": 12, "cover": "//i0.hdslb.com/cover.jpg"]
        ]
        let value = try CreatorCollection.map(season, kind: .season, mid: 7)
        XCTAssertEqual(value.title, "课程")
        XCTAssertEqual(value.id, "season-9")
        XCTAssertEqual(value.count, 12)
        XCTAssertThrowsError(try CreatorCollection.map(season, kind: .season, mid: 8))
        XCTAssertThrowsError(try CreatorCollection.map(season, kind: .series, mid: 7))
    }
    func testRelationAttributesDistinguishFollowedMutualAndFollowers() throws {
        for value in [1, 2, 6] { XCTAssertTrue(try Relation.map(["attribute": value]).following) }
        for value in [0, 4, 128] { XCTAssertFalse(try Relation.map(["attribute": value]).following) }
        XCTAssertTrue(try Relation.map(["attribute": 6]).mutual)
        XCTAssertTrue(try Relation.map(["attribute": 128]).blocked)
        XCTAssertThrowsError(try Relation.map([:]))
    }
    func testDynamicParserRejectsDisguisedOriginalsAndWrongOwners() {
        func post(_ mid: Int, bvid: String, owner: Int? = nil, repost: Bool = false) -> JSON {
            var archive: JSON = [
                "bvid": bvid, "aid": 42, "title": "Actual", "cover": "//i0.hdslb.com/cover.jpg",
                "duration_text": "01:20",
            ]
            if let owner { archive["owner"] = ["mid": owner] }
            var result: JSON = [
                "id_str": "100000000000000000" + String(bvid.suffix(1)), "type": "DYNAMIC_TYPE_AV",
                "modules": [
                    "module_author": ["mid": mid, "name": "UP", "pub_ts": mid],
                    "module_dynamic": ["major": ["type": "MAJOR_TYPE_ARCHIVE", "archive": archive]],
                ],
            ]
            if repost { result["orig"] = [:] }
            return result
        }
        let values = [
            post(7, bvid: "BV0000000001"), post(8, bvid: "BV0000000002"), post(7, bvid: "BV0000000003", owner: 9),
            post(7, bvid: "BV0000000004", repost: true), post(7, bvid: "BV0000000001"),
        ]
        let result = BiliClient.dynamicItems(values).filter { $0.author.mid == 7 }
        XCTAssertEqual(result.count, 1)
        guard case .video(let video) = result.first?.content else { return XCTFail("Expected original video") }
        XCTAssertEqual(video.bvid, "BV0000000001")
        XCTAssertEqual(video.duration, 80)
    }
    func testMediaUpgradesKnownCDNAndSelectsSafeBackupWithoutDowngradingQuality() {
        let track: JSON = [
            "id": 112, "codecs": "avc1.640028", "bandwidth": 1000,
            "base_url": "https://edge.bilivideo.com:4483/video.m4s",
            "backup_url": ["http://backup.bilivideo.com/video.m4s"],
        ]
        let result = StreamTrack.map(track)
        XCTAssertEqual(result?.id, 112)
        XCTAssertEqual(result?.url.scheme, "https")
        XCTAssertEqual(result?.url.host, "backup.bilivideo.com")
        XCTAssertNil(StreamTrack.map(["id": 112, "base_url": "https://bilivideo.com.evil.test/video.m4s"]))
    }
    func testMalformedCookieAndHTMLAreNotCredentialShortcuts() {
        XCTAssertEqual(clean("<script>bad()</script><b>真实标题</b> &amp; A"), "真实标题 & A")
        XCTAssertNil(secureURL("http://127.0.0.1/private"))
        XCTAssertFalse(validBVID("BV0000"))
    }
    private func fixture(_ respond: @escaping (URLRequest) throws -> JSON) -> (BiliClient, BiliHTTP, MemoryVault) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        MockProtocol.handler = respond
        MockProtocol.responseHeaders = [:]
        MockProtocol.stalledPath = nil
        let vault = MemoryVault()
        let http = BiliHTTP(configuration: configuration, vault: vault)
        return (BiliClient(http: http), http, vault)
    }
    func testSearchDoesNotFetchSuggestionsOrRecommendations() async throws {
        var paths: [String] = []
        let (client, _, _) = fixture { request in
            let path = request.url!.path
            paths.append(path)
            if path.hasSuffix("/spi") { return ["code": 0, "data": ["b_3": "test-official-device-0001"]] }
            if path.hasSuffix("/nav") {
                return [
                    "code": -101,
                    "data": [
                        "wbi_img": [
                            "img_url": "https://i0.hdslb.com/\(String(repeating: "a", count: 32)).png",
                            "sub_url": "https://i0.hdslb.com/\(String(repeating: "b", count: 32)).png",
                        ]
                    ],
                ]
            }
            return [
                "code": 0,
                "data": ["result": [["mid": 7, "uname": "Teacher", "usign": "Learn", "fans": 123]], "numPages": 1],
            ]
        }
        let result = try await client.search("Teacher", users: true, page: 1)
        XCTAssertEqual(result.users.first?.mid, 7)
        XCTAssertEqual(result.users.first?.description, "Learn")
        XCTAssertEqual(
            Set(paths), ["/x/frontend/finger/spi", "/x/web-interface/nav", "/x/web-interface/wbi/search/type"])
    }
    func testFollowWritesOnceAndConfirmsRealStateWithoutTouchingDeviceKeychain() async throws {
        var following = false
        var writes = 0
        let (client, http, vault) = fixture { request in
            switch request.url!.path {
            case "/x/web-interface/nav": return ["code": 0, "data": ["isLogin": true, "mid": 3, "uname": "Viewer"]]
            case "/x/frontend/finger/spi": return ["code": 0, "data": ["b_3": "test-official-device-0001"]]
            case "/x/relation": return ["code": 0, "data": ["attribute": following ? 2 : 0]]
            case "/x/relation/modify":
                writes += 1
                following = true
                return ["code": 0, "data": NSNull()]
            default:
                XCTFail("Unexpected endpoint")
                return [:]
            }
        }
        let cookies = ["SESSDATA", "bili_jct"].map {
            HTTPCookie(properties: [
                .name: $0, .value: "test-only", .domain: ".bilibili.com", .path: "/", .secure: "TRUE",
            ])!
        }
        _ = try await http.acceptLogin(cookies)
        async let first = client.setFollowing(7, following: true)
        async let second = client.setFollowing(7, following: true)
        let values = try await [first, second]
        XCTAssertTrue(values.allSatisfy(\.following))
        XCTAssertEqual(writes, 1)
        _ = try await client.setFollowing(7, following: true)
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(vault.cookies.isEmpty)
        await client.logout()
        XCTAssertTrue(vault.cookies.isEmpty)
    }
    func testCollectionsFailureIsNotAnEmptyCatalog() async throws {
        let (client, _, _) = fixture { _ in
            ["code": 0, "data": ["items_lists": ["page": ["total": 0], "seasons_list": []]]]
        }
        do {
            _ = try await client.collections(7, page: 1)
            XCTFail("Malformed catalog must not become empty")
        } catch let error as BiliFailure { XCTAssertEqual(error.code, "COLLECTIONS_UNAVAILABLE") }
    }
}

final class QRLoginTransportTests: XCTestCase {
    @MainActor func testQRCodeAcceptsBothOfficialLoginHosts() throws {
        for host in ["account.bilibili.com", "passport.bilibili.com"] {
            let url = "https://\(host)/h5-app/passport/login/scan?key=isolated-test-key"
            let (value, key) = try DirectQRLogin.challenge(["url": url, "qrcode_key": "isolated-test-key"])
            XCTAssertEqual(value, url)
            XCTAssertEqual(key, "isolated-test-key")
        }
    }

    @MainActor func testQRCodeRejectsUnsafeURLsAndMissingKey() {
        for url in ["http://account.bilibili.com/scan", "https://account.bilibili.com.evil.example/scan",
                    "https://evil.example/scan", "https://user@account.bilibili.com/scan",
                    "https://account.bilibili.com:8443/scan"] {
            XCTAssertThrowsError(try DirectQRLogin.challenge(["url": url, "qrcode_key": "test"]))
        }
        XCTAssertThrowsError(try DirectQRLogin.challenge(["url": "https://account.bilibili.com/scan"]))
    }

    @MainActor func testWaitingStatusAndNoImportedCookies() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); MockProtocol.handler = nil }
        MockProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.url?.host, "passport.bilibili.com")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "qrcode_key" })?.value, "isolated-test-key")
            return ["code": 0, "data": ["code": 86101]]
        }
        let (data, cookies) = try await DirectQRLogin { _ in }.request("poll", key: "isolated-test-key", session: session)
        XCTAssertEqual(data["code"] as? Int, 86101)
        XCTAssertTrue(cookies.isEmpty)
    }

    @MainActor func testUpstreamErrorIsNotAnEmptyQRCode() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); MockProtocol.handler = nil }
        MockProtocol.handler = { _ in ["code": -412, "message": "请求被拦截"] }
        do {
            _ = try await DirectQRLogin { _ in }.request("generate", session: session)
            XCTFail("Expected upstream error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("-412")) }
    }
}
