import AVKit
import MediaPlayer
import SwiftUI
import XCTest

@testable import Bilight

final class PlayerChromeTests: XCTestCase {
    @MainActor func testScrubberKeepsSelectedProgressWhileSeekIsPending() async throws {
        let (player, controls, progress) = try await deferredScrubber()
        defer { controls.stop() }
        progress.sendActions(for: .touchDown)
        progress.value = 8
        progress.sendActions(for: .valueChanged)
        progress.sendActions(for: .touchUpInside)
        for position in [1.0, 1.2, 1.5] {
            player.reportedPosition = position
            controls.refresh()
            XCTAssertEqual(progress.value, 8, "An unfinished seek must not flash the old player position")
            XCTAssertEqual(progress.accessibilityValue, "0:08 / 0:12")
        }
        player.completeSeek(0, at: 8)
        try await Task.sleep(for: .milliseconds(20))
        player.reportedPosition = 8.5
        controls.refresh()
        XCTAssertEqual(progress.value, 8.5, accuracy: 0.01, "The slider must follow playback again after completion")
        XCTAssertEqual(player.timeControlStatus, .paused)
    }

    @MainActor func testScrubberIgnoresOldCompletionDuringAnotherDragOrSeek() async throws {
        let (player, controls, progress) = try await deferredScrubber()
        defer { controls.stop() }
        for target: Float in [8, 4] {
            progress.sendActions(for: .touchDown)
            progress.value = target
            progress.sendActions(for: .valueChanged)
            progress.sendActions(for: .touchUpInside)
        }
        player.completeSeek(0, at: 1, finished: false)
        try await Task.sleep(for: .milliseconds(20))
        controls.refresh()
        XCTAssertEqual(progress.value, 4, "An interrupted older seek cannot clear the latest target")
        progress.sendActions(for: .touchDown)
        progress.value = 9
        progress.sendActions(for: .valueChanged)
        player.completeSeek(1, at: 4)
        try await Task.sleep(for: .milliseconds(20))
        controls.refresh()
        XCTAssertEqual(progress.value, 9, "A previous completion cannot move an active drag")
        progress.sendActions(for: .touchCancel)
        XCTAssertEqual(progress.value, 4)
        XCTAssertEqual(player.seekRequests.count, 2, "Cancelling a drag must not submit its target")
    }

    @MainActor func testScrubberAccessibilitySeekRecoversWhenInterrupted() async throws {
        let (player, controls, progress) = try await deferredScrubber()
        defer { controls.stop() }
        progress.value = 6
        progress.sendActions(for: .valueChanged)
        controls.refresh()
        XCTAssertEqual(progress.value, 6, "VoiceOver changes also need to retain their pending target")
        player.completeSeek(0, at: 1.5, finished: false)
        try await Task.sleep(for: .milliseconds(20))
        controls.refresh()
        XCTAssertEqual(progress.value, 1.5)
        XCTAssertEqual(player.timeControlStatus, .paused)
    }

    @MainActor func testScrubberCancellingAnotherDragKeepsThePendingSeek() async throws {
        let (player, controls, progress) = try await deferredScrubber()
        defer { controls.stop() }
        progress.sendActions(for: .touchDown)
        progress.value = 6
        progress.sendActions(for: .valueChanged)
        progress.sendActions(for: .touchUpInside)
        progress.sendActions(for: .touchDown)
        progress.value = 9
        progress.sendActions(for: .valueChanged)
        progress.sendActions(for: .touchCancel)
        controls.refresh()
        XCTAssertEqual(progress.value, 6, "Cancelling a new drag must retain the previously submitted target")
        XCTAssertEqual(player.seekRequests.count, 1)
        player.completeSeek(0, at: 6)
        try await Task.sleep(for: .milliseconds(20))
        player.reportedPosition = 6.5
        controls.refresh()
        XCTAssertEqual(progress.value, 6.5)
    }

    @MainActor func testScrubberDiscardsPendingTargetWhenItemChanges() async throws {
        let (player, controls, progress) = try await deferredScrubber()
        defer { controls.stop() }
        progress.sendActions(for: .touchDown)
        progress.value = 8
        progress.sendActions(for: .valueChanged)
        progress.sendActions(for: .touchUpInside)
        let asset = try XCTUnwrap(player.currentItem?.asset)
        player.reportedPosition = 2
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        let deadline = Date().addingTimeInterval(4)
        repeat { try await Task.sleep(for: .milliseconds(20)) }
        while player.currentItem?.status != .readyToPlay && Date() < deadline
        controls.refresh()
        XCTAssertEqual(progress.value, 2, "A new item cannot inherit the previous item's pending target")
        player.completeSeek(0, at: 2, finished: false)
        try await Task.sleep(for: .milliseconds(20))
        player.reportedPosition = 2.5
        controls.refresh()
        XCTAssertEqual(progress.value, 2.5)
    }

    @MainActor private func deferredScrubber() async throws -> (DeferredSeekPlayer, PlaybackControls, UISlider) {
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        let player = DeferredSeekPlayer(url: media)
        let controls = PlaybackControls(player: player)
        let deadline = Date().addingTimeInterval(4)
        while player.currentItem?.status != .readyToPlay && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        controls.refresh()
        let progress = try XCTUnwrap(descendants(controls).first { $0.accessibilityIdentifier == "player-seek-slider" } as? UISlider)
        XCTAssertTrue(progress.isEnabled)
        XCTAssertEqual(progress.maximumValue, 12, accuracy: 0.1)
        return (player, controls, progress)
    }

    @MainActor func testLocalPlaybackPublishesLockScreenInformationAndClearsItOnStop() async throws {
        let model = PlayerModel()
        defer { model.stop() }
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        let video = Video(bvid: "BV12qnt6VEM1", aid: 42, title: "锁屏控制测试", cover: nil, duration: 12,
            publishedAt: 0, owner: User(mid: 42, name: "隔离测试", avatar: nil), views: 0)
        let record = DownloadRecord(id: UUID(), video: video, part: VideoPart(cid: 43, page: 1, title: "第一段", duration: 12), quality: 80, qualityLabel: "1080P")
        model.loadLocal(media, record: record)
        let deadline = Date().addingTimeInterval(4)
        while model.player.currentTime().seconds < 0.1 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo, "Background playback must publish a system lock-screen media item")
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, video.title)
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, video.owner.name)
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0, 12, accuracy: 0.2)
        XCTAssertTrue(MPRemoteCommandCenter.shared().pauseCommand.isEnabled)
        XCTAssertTrue(MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled)
        let player = model.player
        model.setRate(1.5)
        XCTAssertEqual(model.handleRemotePlayback(.pause), .success)
        model.player.pause()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(model.handleRemotePlayback(.seek(5)), .success)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.currentTime().seconds, 5, accuracy: 0.15)
        XCTAssertEqual(player.timeControlStatus, .paused)
        XCTAssertEqual(model.handleRemotePlayback(.play), .success)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.rate, 1.5)
        XCTAssertTrue(player === model.player)
        XCTAssertEqual(model.handleRemotePlayback(.pause), .success)
        XCTAssertEqual(model.handleRemotePlayback(.seek(-100)), .success)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.1)
        model.stop()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(model.handleRemotePlayback(.play), .noSuchContent)
    }

    @MainActor func testOldPlayerCannotClearOrControlTheNewSystemMediaItem() async throws {
        let old = PlayerModel(), next = PlayerModel()
        defer { old.stop(); next.stop() }
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        var video = Video(bvid: "BV12qnt6VEM1", aid: 42, title: "旧视频", cover: nil, duration: 12,
            publishedAt: 0, owner: User(mid: 42, name: "隔离测试", avatar: nil), views: 0)
        let part = VideoPart(cid: 43, page: 1, title: "第一段", duration: 12)
        old.loadLocal(media, record: DownloadRecord(id: UUID(), video: video, part: part, quality: 80, qualityLabel: "1080P"))
        video.title = "新视频"
        next.loadLocal(media, record: DownloadRecord(id: UUID(), video: video, part: part, quality: 80, qualityLabel: "1080P"))
        old.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "新视频")
        XCTAssertEqual(old.handleRemotePlayback(.pause), .noSuchContent)
        XCTAssertNotNil(next.player.currentItem)
    }

    @MainActor func testSavedSpeedSurvivesMountingAndReplacingNativeVideoPlayers() async throws {
        let suite = "Bilight.NativeSpeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, window = UIWindow(windowScene: scene)
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        let video = Video(bvid: "BV12qnt6VEM1", aid: 42, title: "Speed continuity", cover: nil, duration: 12,
            publishedAt: 0, owner: User(mid: 42, name: "Test", avatar: nil), views: 0)
        let record = DownloadRecord(id: UUID(), video: video, part: VideoPart(cid: 43, page: 1, title: "P1", duration: 12), quality: 80, qualityLabel: "1080P")
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        for index in 0..<3 {
            let model = PlayerModel(preferences: PlaybackPreferences(defaults: defaults))
            if index > 0 { XCTAssertEqual(model.rate, 1.5, "The next player must start with the explicit preference") }
            let root = UIViewController()
            let host = UIHostingController(rootView: NativePlayer(model: model, onQuality: { _ in }))
            window.rootViewController = root; root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
            host.view.frame = CGRect(x: 0, y: 100, width: window.bounds.width, height: 240); window.makeKeyAndVisible()
            model.loadLocal(media, record: record)
            let deadline = Date().addingTimeInterval(4)
            while (model.player.currentTime().seconds < 0.15 || containers(root).isEmpty), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(model.player.timeControlStatus, .playing)
            if index == 0 { model.setRate(1.5) }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(model.rate, 1.5, "Mounting a new native player must not reset the selected speed")
            XCTAssertEqual(model.player.defaultRate, 1.5)
            XCTAssertEqual(model.player.rate, 1.5, "Check actual playback, not just stored state or menu selection")
            XCTAssertEqual(PlaybackPreferences(defaults: defaults).rate, 1.5)
            if index == 1 {
                let container = try XCTUnwrap(containers(root).first)
                container.enterFullscreen(rotate: false)
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertEqual(model.player.rate, 1.5)
                container.exitFullscreen()
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertEqual(model.player.rate, 1.5)
            }
            model.player.pause()
            model.player.defaultRate = 1 // A late native reset must neither replace the preference nor resume playback.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.player.defaultRate, 1.5); XCTAssertEqual(model.player.rate, 0)
            XCTAssertEqual(model.rate, 1.5); XCTAssertEqual(PlaybackPreferences(defaults: defaults).rate, 1.5)
            containers(root).forEach { $0.shutdown() }
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent(); model.stop()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(PlaybackPreferences(defaults: defaults).rate, 1.5, "Tearing down the previous native player cannot overwrite the next video's preference")
        }
    }

    @MainActor func testHoldingTemporarilyUsesTwoTimesSpeedInBothContainersAndRestoresOnCancel() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
        let suite = "Bilight.SpeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        let model = PlayerModel(preferences: preferences)
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        model.player.replaceCurrentItem(with: AVPlayerItem(url: media))
        let host = UIHostingController(rootView: NativePlayer(model: model, onQuality: { _ in }))
        window.rootViewController = root; root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
        host.view.frame = CGRect(x: 0, y: 100, width: window.bounds.width, height: 240); window.makeKeyAndVisible()
        defer { containers(root).forEach { $0.shutdown() }; model.stop(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        model.player.play()
        let deadline = Date().addingTimeInterval(3)
        while (containers(root).isEmpty || model.player.currentTime().seconds < 0.1), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let container = try XCTUnwrap(containers(root).first)
        for fullscreen in [false, true] {
            if fullscreen { container.enterFullscreen(rotate: false); try await Task.sleep(for: .milliseconds(100)) }
            for rate: Float in [1, 1.5, 2.5] {
                model.setRate(rate)
                container.handleSpeedHold(.began)
                XCTAssertEqual(model.player.rate, 2)
                XCTAssertEqual(preferences.rate, rate, "A temporary hold must not persist its 2× speed")
                XCTAssertEqual(model.rate, rate, "Temporary acceleration cannot overwrite the selected rate")
                container.handleSpeedHold(.cancelled)
                XCTAssertEqual(model.player.rate, rate)
                container.handleSpeedHold(.began); container.handleSpeedHold(.ended)
                XCTAssertEqual(model.player.defaultRate, rate)
            }
        }
        model.player.pause(); container.handleSpeedHold(.began)
        XCTAssertEqual(model.player.rate, 0, "Holding a paused video cannot silently start playback")
        container.handleSpeedHold(.ended)
        XCTAssertEqual(model.player.audiovisualBackgroundPlaybackPolicy, .continuesIfPossible)
        XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("audio") == true)
    }
    @MainActor func testOccupiedDanmakuLaneDoesNotRevealAnOldCommentMidScreen() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
        let overlay = DanmakuOverlay(frame: CGRect(x: 0, y: 60, width: 400, height: 240))
        window.rootViewController = root; root.view.addSubview(overlay); window.makeKeyAndVisible()
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        let player = AVPlayer(url: media)
        defer { overlay.removeFromSuperview(); player.pause(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        overlay.update(player: player, items: [
            Danmaku(id: 0, time: 0, text: "占用轨道", mode: 5, color: 0xffffff),
            Danmaku(id: 7, time: 1, text: "不应从中间突然出现", mode: 1, color: 0xffffff),
            Danmaku(id: 14, time: 4.2, text: "新的正常入场", mode: 1, color: 0xffffff),
        ], enabled: true, revision: UUID())
        try await Task.sleep(for: .milliseconds(100))
        await player.seek(to: CMTime(seconds: 1.1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(overlay.subviews.contains { ($0 as? UILabel)?.text == "不应从中间突然出现" })
        await player.seek(to: CMTime(seconds: 4.1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(overlay.subviews.contains { ($0 as? UILabel)?.text == "不应从中间突然出现" }, "A comment skipped for density must stay skipped when the preceding comment expires")
        await player.seek(to: CMTime(seconds: 4.2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(for: .milliseconds(80))
        let fresh = try XCTUnwrap(overlay.subviews.first { ($0 as? UILabel)?.text == "新的正常入场" })
        XCTAssertGreaterThanOrEqual(fresh.frame.minX, overlay.bounds.width - 1, "A new scrolling comment starts outside the right edge")
    }
    @MainActor func testLateDanmakuStartsAtTheEdgeAndSurvivesStyleAndContainerChanges() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
        let overlay = DanmakuOverlay(frame: CGRect(x: 0, y: 60, width: 400, height: 240))
        window.rootViewController = root; root.view.addSubview(overlay); window.makeKeyAndVisible()
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        let player = AVPlayer(url: media), revision = UUID()
        defer { overlay.removeFromSuperview(); player.pause(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        await player.seek(to: CMTime(seconds: 5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        let items = [Danmaku(id: 0, time: 1, text: "迟到的旧弹幕", mode: 1, color: 0xffffff),
            Danmaku(id: 1, time: 4.9, text: "边界入场", mode: 1, color: 0xffffff)]
        overlay.update(player: player, items: items, enabled: true, revision: revision)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(overlay.subviews.contains { ($0 as? UILabel)?.text == "迟到的旧弹幕" })
        let label = try XCTUnwrap(overlay.subviews.first { ($0 as? UILabel)?.text == "边界入场" } as? UILabel)
        XCTAssertEqual(label.frame.minX, 400, accuracy: 0.5)
        overlay.removeFromSuperview(); root.view.addSubview(overlay)
        overlay.frame.size = CGSize(width: 800, height: 320)
        overlay.update(player: player, items: items, enabled: true, revision: revision, fontSize: 24)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(overlay.subviews.contains { $0 === label }, "Fullscreen moves and font changes keep the admitted comment")
        XCTAssertEqual(label.font.pointSize, 24)
        XCTAssertEqual(label.frame.minX, 800, accuracy: 0.5)
        await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(for: .milliseconds(80))
        let replayed = try XCTUnwrap(overlay.subviews.first { ($0 as? UILabel)?.text == "迟到的旧弹幕" })
        XCTAssertEqual(replayed.frame.minX, 800, accuracy: 0.5, "Seeking backwards allows a new pass starting at the boundary")
    }

    @MainActor func testDoubleTapUsesFortyTwentyFortyZonesAtEveryPlayerWidth() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
        let model = PlayerModel()
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        model.playback = Playback(quality: 80, qualities: [], duration: 12, mp4: media)
        model.player.replaceCurrentItem(with: AVPlayerItem(url: media))
        let host = UIHostingController(rootView: NativePlayer(model: model, onQuality: { _ in }))
        window.rootViewController = root; root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root); window.makeKeyAndVisible()
        defer { containers(root).forEach { $0.shutdown() }; model.stop(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(100))
        let container = try XCTUnwrap(containers(root).first)
        for width: CGFloat in [320, 440, 874] {
            host.view.frame = CGRect(x: 0, y: 100, width: width, height: 240); host.view.layoutIfNeeded(); container.view.layoutIfNeeded()
            for (fraction, expected): (CGFloat, Double) in [(0.0, 0), (0.399, 0), (0.4, 5), (0.599, 5), (0.6, 12), (0.999, 12)] {
                model.player.pause()
                await model.player.seek(to: CMTime(seconds: 5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                container.handleDoubleTap(at: CGPoint(x: container.controller.view.bounds.width * fraction, y: 80))
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertEqual(model.player.currentTime().seconds, expected, accuracy: 0.15)
                if fraction >= 0.4 && fraction < 0.6 {
                    XCTAssertNotEqual(model.player.timeControlStatus, .paused)
                    container.handleDoubleTap(at: CGPoint(x: container.controller.view.bounds.midX, y: 80))
                }
                XCTAssertEqual(model.player.timeControlStatus, .paused, "Seeking preserves pause; the center toggles playback without seeking")
            }
        }
    }
    @MainActor func testBackgroundForegroundRebindsSameFullscreenPlayerAndPreservesPausedIntent() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
        let model = PlayerModel()
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        model.player.replaceCurrentItem(with: AVPlayerItem(url: media))
        let host = UIHostingController(rootView: NativePlayer(model: model, onQuality: { _ in }))
        window.rootViewController = root; root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
        host.view.frame = CGRect(x: 0, y: 100, width: window.bounds.width, height: 240); window.makeKeyAndVisible()
        defer { containers(root).forEach { $0.shutdown() }; model.stop(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(100))
        let container = try XCTUnwrap(containers(root).first), item = try XCTUnwrap(model.player.currentItem)
        for playing in [true, false, true] {
            if playing { model.player.play() } else { model.player.pause() }
            try await Task.sleep(for: .milliseconds(150))
            container.enterFullscreen(rotate: false)
            try await Task.sleep(for: .milliseconds(120))
            let position = model.player.currentTime().seconds
            container.resignPlaybackActivity()
            container.backgroundPlaybackActivity()
            XCTAssertTrue(container.controller.player === model.player, "Paused background playback retains the last render surface instead of clearing it")
            XCTAssertTrue(model.player.currentItem === item)
            if playing { XCTAssertNotEqual(model.player.timeControlStatus, .paused, "Background audio keeps playing") }
            else { XCTAssertEqual(model.player.timeControlStatus, .paused) }
            container.exitFullscreen()
            XCTAssertNotNil(container.presentedViewController, "Fullscreen dismissal is deferred while inactive")
            container.activatePlaybackActivity()
            let deadline = Date().addingTimeInterval(2.5)
            while Date() < deadline && container.presentedViewController != nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(container.controller.player === model.player)
            XCTAssertTrue(model.player.currentItem === item)
            XCTAssertNil(container.presentedViewController)
            XCTAssertFalse(model.isFullscreen)
            XCTAssertTrue(container.controller.parent === container)
            XCTAssertGreaterThanOrEqual(model.player.currentTime().seconds, position - 0.05)
            if playing { XCTAssertNotEqual(model.player.timeControlStatus, .paused) }
            else { XCTAssertEqual(model.player.timeControlStatus, .paused) }
        }
        // Home can interrupt presentation itself, before UIKit calls its completion.
        container.enterFullscreen(rotate: false, animated: true)
        container.resignPlaybackActivity(); container.backgroundPlaybackActivity()
        container.activatePlaybackActivity()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(container.controller.player === model.player)
        XCTAssertTrue(model.player.currentItem === item)
        XCTAssertNotNil(container.controller.view.window)
        container.exitFullscreen()
    }
    @MainActor func testDanmakuAreaConstrainsAllModesAndUpdatesWhilePausedWithoutReloading() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
        let overlay = DanmakuOverlay(frame: CGRect(x: 0, y: 60, width: 400, height: 240))
        window.rootViewController = root; root.view.addSubview(overlay); window.makeKeyAndVisible()
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        let player = AVPlayer(url: media), revision = UUID()
        let items = (0..<28).map { Danmaku(id: $0, time: 0, text: "区域边界 \($0)", mode: [1, 4, 5, 6][$0 % 4], color: 0xffffff) }
        defer { overlay.removeFromSuperview(); player.pause(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        for size in [CGSize(width: 320, height: 180), CGSize(width: 440, height: 240), CGSize(width: 700, height: 320)] {
            overlay.frame.size = size
            for fontSize: CGFloat in [16, 20, 24] {
                for area in DanmakuArea.allCases {
                    overlay.update(player: player, items: items, enabled: true, revision: revision, fontSize: fontSize, area: area)
                    try await Task.sleep(for: .milliseconds(40))
                    let labels = overlay.subviews.compactMap { $0 as? UILabel }
                    XCTAssertFalse(labels.isEmpty)
                    for label in labels {
                        XCTAssertGreaterThanOrEqual(label.frame.minY, 0)
                        XCTAssertLessThanOrEqual(label.frame.maxY, size.height * area.rawValue + 0.5, "Every mode stays inside the selected upper area")
                    }
                    XCTAssertEqual(player.timeControlStatus, .paused)
                }
            }
        }
        overlay.frame.size = CGSize(width: 400, height: 240)
        overlay.update(player: player, items: items, enabled: true, revision: revision, area: .full)
        try await Task.sleep(for: .milliseconds(40))
        let original = try XCTUnwrap(overlay.subviews.first { ($0 as? UILabel)?.text == "区域边界 0" })
        overlay.update(player: player, items: items, enabled: true, revision: revision, area: .half)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(overlay.subviews.contains { $0 === original }, "Changing area repositions cached glyphs, without rebuilding or refetching them")
    }
    @MainActor func testDanmakuHasSolidGlyphInteriorsWithoutOverlappingStrokeBoxes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
        let overlay = DanmakuOverlay(frame: CGRect(x: 0, y: 0, width: 900, height: 280))
        window.rootViewController = root; root.view.addSubview(overlay); window.makeKeyAndVisible()
        defer { overlay.removeFromSuperview(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        let player = AVPlayer(url: media)
        overlay.update(player: player, items: [Danmaku(id: 0, time: 0, text: "所以我现在交的算啥 没事，再给公务员涨点 遥遥领先", mode: 5, color: 0xff0000)], enabled: true, revision: UUID())
        // Drive the same display-link path as live playback without a network or account.
        try await Task.sleep(for: .milliseconds(100))
        let label = try XCTUnwrap(overlay.subviews.first as? UILabel)
        let reference = UILabel(frame: label.bounds)
        reference.font = label.font; reference.text = label.text; reference.textColor = .white
        func pixels(_ view: UIView) -> (UIImage, [UInt8]) {
            let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
            let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in view.layer.render(in: context.cgContext) }
            let cg = image.cgImage!, width = cg.width, height = cg.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return (image, bytes)
        }
        let (actualImage, actual) = pixels(label), (referenceImage, expected) = pixels(reference)
        var interiors = 0, damaged = 0
        for i in stride(from: 0, to: expected.count, by: 4) where expected[i + 3] >= 250 {
            interiors += 1
            if actual[i] < 230 || actual[i + 1] < 230 || actual[i + 2] < 230 { damaged += 1 }
        }
        for (name, image) in [("danmaku-actual", actualImage), ("danmaku-reference", referenceImage)] {
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let damage = Double(damaged) / Double(max(1, interiors))
        print("[danmaku glyph coverage] interiorPixels=\(interiors) darkOrMissing=\(damaged) fraction=\(damage)")
        XCTAssertGreaterThan(interiors, 1000)
        XCTAssertLessThan(damage, 0.02, "A black outline must not cut boxes through the solid white glyph interiors")
    }
    @MainActor func testDanmakuAvoidsCameraAndHomeSafeAreasAcrossFullscreenRotationWhilePaused() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
        let model = PlayerModel()
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        model.player.replaceCurrentItem(with: AVPlayerItem(url: media))
        model.danmakuItems = [Danmaku(id: 0, time: 0, text: "顶部弹幕避开灵动岛", mode: 5, color: 0xffffff), Danmaku(id: 1, time: 0, text: "底部弹幕避开指示条", mode: 4, color: 0xffffff)]
        model.danmakuEnabled = true; model.danmakuRevision = UUID()
        let host = UIHostingController(rootView: NativePlayer(model: model, onQuality: { _ in }))
        window.rootViewController = root
        root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
        host.view.frame = CGRect(x: 0, y: 100, width: window.bounds.width, height: 240)
        window.makeKeyAndVisible()
        defer { containers(root).forEach { $0.shutdown() }; model.stop(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(150))
        let container = try XCTUnwrap(containers(root).first)
        container.enterFullscreen(rotate: false)
        try await Task.sleep(for: .milliseconds(200))
        let fullscreen = try XCTUnwrap(container.presentedViewController)
        let overlay = try XCTUnwrap(container.controller.contentOverlayView?.viewWithTag(1744) as? DanmakuOverlay)
        func assertSafe(file: StaticString = #filePath, line: UInt = #line) {
            fullscreen.view.layoutIfNeeded()
            let safe = fullscreen.view.convert(fullscreen.view.safeAreaLayoutGuide.layoutFrame, to: window)
            let frame = overlay.convert(overlay.bounds, to: window)
            print("[danmaku safe area] root=\(safe) playerInsets=\(container.controller.view.safeAreaInsets) contentInsets=\(container.controller.contentOverlayView?.safeAreaInsets ?? .zero) viewport=\(frame)")
            XCTAssertGreaterThanOrEqual(frame.minY, safe.minY - 0.5, "The danmaku viewport must stay below the camera cutout", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, safe.minX - 0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, safe.maxX + 0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, safe.maxY + 0.5, file: file, line: line)
            if let label = overlay.subviews.first(where: { ($0 as? UILabel)?.text == "顶部弹幕避开灵动岛" }) {
                XCTAssertGreaterThanOrEqual(label.convert(label.bounds, to: window).minY, safe.minY + 10, file: file, line: line)
            } else { XCTFail("A visible top-fixed danmaku is required", file: file, line: line) }
            XCTAssertTrue(model.isFullscreen, file: file, line: line)
            XCTAssertEqual(model.player.timeControlStatus, .paused, file: file, line: line)
        }
        assertSafe()
        fullscreen.additionalSafeAreaInsets = UIEdgeInsets(top: 32, left: 24, bottom: 16, right: 24)
        try await Task.sleep(for: .milliseconds(100))
        assertSafe()
        for orientation: UIInterfaceOrientation in [.landscapeRight, .landscapeLeft, .portrait] {
            let mask: UIInterfaceOrientationMask = orientation == .portrait ? .portrait : (orientation == .landscapeRight ? .landscapeRight : .landscapeLeft)
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            let deadline = Date().addingTimeInterval(2)
            while PlayerContainer.orientation(scene) != orientation && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(PlayerContainer.orientation(scene), orientation, "Each rotation must actually complete before checking its safe area")
            try await Task.sleep(for: .milliseconds(60))
            assertSafe()
        }
        container.exitFullscreen()
        try await Task.sleep(for: .milliseconds(150))
        let parent = try XCTUnwrap(container.controller.contentOverlayView)
        XCTAssertEqual(overlay.frame.minY, parent.safeAreaLayoutGuide.layoutFrame.minY, accuracy: 0.5, "Inline playback must not acquire a permanent fullscreen top margin")
    }
    @MainActor func testDanmakuMovesOnEveryDisplayFrameDuring4KPlayback() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        let overlay = DanmakuOverlay(frame: CGRect(x: 0, y: 100, width: window.bounds.width, height: 240))
        root.view.addSubview(overlay)
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        let player = AVPlayer(url: media)
        window.makeKeyAndVisible()
        overlay.update(player: player, items: [Danmaku(id: 0, time: 0, text: "持续平滑滚动的弹幕", mode: 1, color: 0xffffff)], enabled: true, revision: UUID())
        defer { overlay.removeFromSuperview(); player.pause(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        player.play()
        let deadline = Date().addingTimeInterval(5)
        while (player.currentTime().seconds < 0.2 || overlay.subviews.isEmpty) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let label = try XCTUnwrap(overlay.subviews.first as? UILabel)
        try await assertSmoothMotion(label, milliseconds: 1600)
        let scale = window.windowScene?.screen.scale ?? 1
        print("[danmaku text] screenScale=\(scale) contentScale=\(label.contentScaleFactor) layerScale=\(label.layer.contentsScale) pixelX=\(label.frame.minX * scale)")
        XCTAssertEqual(label.contentScaleFactor, scale)
        XCTAssertEqual(label.layer.contentsScale, scale)
        XCTAssertEqual(label.frame.minX * scale, (label.frame.minX * scale).rounded(), accuracy: 0.001, "Scrolling text must stay on physical pixel boundaries instead of resampling its edges")
    }
    @MainActor func testDenseDanmakuStaysSmoothInNativePlayerAndFullscreen() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        let model = PlayerModel()
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        model.player.replaceCurrentItem(with: AVPlayerItem(url: media))
        model.danmakuItems = (0..<10000).map {
            Danmaku(id: $0, time: Double($0) / 1500, text: "密集弹幕 \($0)", mode: [1, 6, 5][$0 % 3], color: [0xff0000, 0x00ff00, 0x0000ff][$0 % 3])
        }
        model.danmakuEnabled = true
        model.danmakuRevision = UUID()
        let host = UIHostingController(rootView: NativePlayer(model: model, onQuality: { _ in }))
        window.rootViewController = root
        root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
        host.view.frame = CGRect(x: 0, y: 100, width: window.bounds.width, height: window.bounds.width * 9 / 16)
        window.makeKeyAndVisible()
        defer { containers(root).forEach { $0.shutdown() }; model.stop(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        model.player.play()
        let deadline = Date().addingTimeInterval(5)
        while (model.player.currentTime().seconds < 0.2 || containers(root).first?.controller.contentOverlayView?.viewWithTag(1744)?.subviews.isEmpty != false) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let overlay = try XCTUnwrap(containers(root).first?.controller.contentOverlayView?.viewWithTag(1744) as? DanmakuOverlay)
        let label = try XCTUnwrap(overlay.subviews.first { ($0 as? UILabel)?.text == "密集弹幕 0" } as? UILabel)
        XCTAssertEqual(overlay.alpha, 1, "Danmaku stays opaque over all video backgrounds")
        for text in overlay.subviews.compactMap({ $0 as? UILabel }) {
            XCTAssertEqual(text.textColor, .white)
            XCTAssertNil(text.attributedText?.attribute(.strokeWidth, at: 0, effectiveRange: nil))
            XCTAssertEqual(text.layer.shadowColor, UIColor.black.cgColor)
        }
        XCTAssertLessThanOrEqual(overlay.subviews.count, 7, "Dense input must keep the bounded number of rendered labels")
        try await assertSmoothMotion(label, milliseconds: 1000)
        model.player.pause()
        try await Task.sleep(for: .milliseconds(80))
        let paused = label.frame.minX
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(label.frame.minX, paused, accuracy: 0.05, "Paused video must freeze danmaku")
        await model.player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await Task.sleep(for: .milliseconds(100))
        let expected = overlay.bounds.width - (overlay.bounds.width + label.bounds.width) * 2 / 8
        XCTAssertEqual(label.frame.minX, expected, accuracy: 1, "Seeking while paused must immediately align danmaku")
        let resumedAt = model.player.currentTime().seconds
        model.player.playImmediately(atRate: 2)
        let resumedDeadline = Date().addingTimeInterval(5)
        while (model.player.timeControlStatus != .playing || model.player.currentTime().seconds < resumedAt + 0.2) && Date() < resumedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.player.timeControlStatus, .playing)
        try await assertSmoothMotion(label, milliseconds: 700)
        let container = try XCTUnwrap(containers(root).first)
        let currentItem = model.player.currentItem
        container.enterFullscreen(rotate: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.isFullscreen)
        XCTAssertTrue(model.player.currentItem === currentItem)
        XCTAssertTrue(container.controller.contentOverlayView?.viewWithTag(1744) === overlay)
        let fullscreenLabel = try XCTUnwrap(overlay.subviews.first { ($0 as? UILabel)?.text == "密集弹幕 0" } as? UILabel)
        try await assertSmoothMotion(fullscreenLabel, milliseconds: 700)
        // The standalone hosting controller is covered by the presented fullscreen controller;
        // exercise shutdown directly on the same overlay, independent of SwiftUI visibility updates.
        overlay.update(player: model.player, items: model.danmakuItems, enabled: false, revision: model.danmakuRevision)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertTrue(overlay.subviews.isEmpty, "Disabling danmaku must stop and clear its rendering loop")
        XCTAssertTrue(Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool == true)
    }
    @MainActor private func assertSmoothMotion(_ label: UILabel, milliseconds: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let probe = DanmakuFrameProbe(label: label)
        probe.start()
        defer { probe.stop() }
        try await Task.sleep(for: .milliseconds(milliseconds))
        let movements = zip(probe.positions, probe.positions.dropFirst()).map { abs($1 - $0) }
        let moving = movements.filter { $0 > 0.05 }.count
        let ratio = Double(moving) / Double(max(1, movements.count))
        let duration = (probe.timestamps.last ?? 0) - (probe.timestamps.first ?? 0)
        let fps = Double(max(0, probe.positions.count - 1)) / max(0.001, duration)
        print("[danmaku frames] samples=\(probe.positions.count) moving=\(moving) ratio=\(ratio) displayHz=\(fps)")
        XCTAssertGreaterThan(probe.positions.count, milliseconds / 30, "The probe must observe actual display frames", file: file, line: line)
        XCTAssertGreaterThan(ratio, 0.85, "Scrolling danmaku must not hold its position on alternate display frames", file: file, line: line)
    }
    @MainActor func testSettingsDoesNotOverlapSystemVolumeControl() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let model = PlayerModel()
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        model.player.replaceCurrentItem(with: AVPlayerItem(url: media))
        let root = UIViewController()
        let host = UIHostingController(rootView: NativePlayer(model: model, onQuality: { _ in }))
        window.rootViewController = root
        root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
        host.view.frame = CGRect(x: 0, y: 100, width: window.bounds.width, height: window.bounds.width * 9 / 16)
        window.makeKeyAndVisible()
        defer { containers(root).forEach { $0.shutdown() }; model.stop(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        model.player.play()
        let ready = Date().addingTimeInterval(5)
        var slider: UISlider?
        while slider == nil && Date() < ready {
            host.view.layoutIfNeeded()
            slider = descendants(host.view).first { $0.accessibilityIdentifier == "player-seek-slider" } as? UISlider
            if slider == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let progress = try XCTUnwrap(slider)
        while (!progress.isEnabled || model.player.currentTime().seconds < 0.1) && Date() < ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        if !visible(progress) { containers(root).first?.fullscreenSurfaceTapped() }
        host.view.layoutIfNeeded()
        let settings = try XCTUnwrap(host.view.viewWithTag(1743) as? UIButton)
        let settingsFrame = settings.convert(settings.bounds, to: host.view)
        let buttons = descendants(host.view).compactMap { $0 as? UIControl }.filter(visible)
        for button in buttons where button !== settings {
            let frame = button.convert(button.bounds, to: host.view)
            print("[player chrome] \(button.accessibilityLabel ?? button.accessibilityIdentifier ?? "unnamed") \(frame)")
            XCTAssertFalse(frame.intersects(settingsFrame), "System control \(button.accessibilityLabel ?? "unnamed") overlaps playback settings")
        }
        XCTAssertEqual(model.player.volume, 1)
        XCTAssertFalse(model.player.isMuted)
        XCTAssertTrue(model.player.preventsDisplaySleepDuringVideoPlayback)
        let play = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "player-play-pause" })
        XCTAssertTrue(progress.isEnabled)
        play.sendActions(for: .touchUpInside)
        XCTAssertEqual(model.player.timeControlStatus, .paused)
        let container = try XCTUnwrap(containers(root).first)
        XCTAssertFalse(container.controller.allowsVideoFrameAnalysis, "Paused-frame Live Text must not intercept custom playback controls")
        for control in [progress, play, settings] {
            let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: window)
            let hit = window.hitTest(center, with: nil)
            XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true, "A paused player must deliver touches to \(control.accessibilityIdentifier ?? control.accessibilityLabel ?? "playback control")")
        }
        progress.sendActions(for: .touchDown)
        progress.value = 3
        progress.sendActions(for: .valueChanged)
        progress.sendActions(for: .touchUpInside)
        let deadline = Date().addingTimeInterval(2)
        while abs(model.player.currentTime().seconds - 3) > 0.1 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.player.currentTime().seconds, 3, accuracy: 0.1)
        XCTAssertEqual(model.player.timeControlStatus, .paused, "Seeking must keep a paused video paused")
        play.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.player.timeControlStatus, .playing)
        let currentItem = model.player.currentItem
        container.enterFullscreen(rotate: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(model.isFullscreen)
        XCTAssertTrue(model.player.currentItem === currentItem)
        let transport = try XCTUnwrap(descendants(container.controller.view).first { $0 is PlaybackControls } as? PlaybackControls)
        progress.sendActions(for: .touchDown)
        progress.value = 5
        progress.sendActions(for: .valueChanged)
        progress.sendActions(for: .touchUpInside)
        for _ in 0..<10 {
            transport.refresh()
            XCTAssertGreaterThanOrEqual(progress.value, 4.99, "A playing fullscreen slider must not flash back while seeking")
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.isFullscreen)
        XCTAssertTrue(model.player.currentItem === currentItem)
        XCTAssertEqual(model.player.timeControlStatus, .playing)
        let fullscreenSettings = settings.convert(settings.bounds, to: window)
        XCTAssertTrue(model.player.preventsDisplaySleepDuringVideoPlayback, "The same fullscreen player must retain video sleep prevention")
        for control in descendants(container.controller.view).compactMap({ $0 as? UIControl }).filter(visible) where control !== settings {
            XCTAssertFalse(control.convert(control.bounds, to: window).intersects(fullscreenSettings), "Fullscreen controls must not overlap settings")
        }
        if ProcessInfo.processInfo.environment["BILIGHT_CHROME_UI_SMOKE"] == "1" {
            print("[player chrome] waiting for visible control inspection")
            try await Task.sleep(for: .seconds(60))
        }
    }
    @MainActor private func containers(_ controller: UIViewController) -> [PlayerContainer] {
        if let player = controller as? PlayerContainer { return [player] }
        return controller.children.flatMap { containers($0) }
    }
    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    @MainActor private func visible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let item = current {
            if item.isHidden || item.alpha < 0.01 { return false }
            current = item.superview
        }
        return view.bounds.width > 0 && view.bounds.height > 0
    }
}

/// Keep AVPlayer's real item/duration, but deliberately delay seek completion to expose UI races.
private final class DeferredSeekPlayer: AVPlayer, @unchecked Sendable {
    var reportedPosition = 1.0
    var seekRequests: [(time: CMTime, completion: (@Sendable (Bool) -> Void)?)] = []
    override func currentTime() -> CMTime { CMTime(seconds: reportedPosition, preferredTimescale: 600) }
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) {
        seekRequests.append((time, nil))
    }
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                       completionHandler: @escaping @Sendable (Bool) -> Void) {
        seekRequests.append((time, completionHandler))
    }
    func completeSeek(_ index: Int, at position: Double, finished: Bool = true) {
        reportedPosition = position
        seekRequests[index].completion?(finished)
    }
}

@MainActor private final class DanmakuFrameProbe: NSObject {
    let label: UILabel
    var positions: [CGFloat] = []
    var timestamps: [CFTimeInterval] = []
    private var link: CADisplayLink?
    init(label: UILabel) { self.label = label }
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(sample))
        let maximum = Float(max(60, label.window?.windowScene?.screen.maximumFramesPerSecond ?? 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func sample(_ link: CADisplayLink) {
        positions.append(label.layer.presentation()?.position.x ?? label.layer.position.x)
        timestamps.append(link.timestamp)
    }
}
