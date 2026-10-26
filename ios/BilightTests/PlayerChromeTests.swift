import AVKit
import SwiftUI
import XCTest

@testable import Bilight

final class PlayerChromeTests: XCTestCase {
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
            XCTAssertEqual(text.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .white)
            XCTAssertEqual(text.attributedText?.attribute(.strokeColor, at: 0, effectiveRange: nil) as? UIColor, .black)
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
        let play = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "player-play-pause" })
        XCTAssertTrue(progress.isEnabled)
        play.sendActions(for: .touchUpInside)
        XCTAssertEqual(model.player.timeControlStatus, .paused)
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
        let container = try XCTUnwrap(containers(root).first)
        let currentItem = model.player.currentItem
        container.enterFullscreen(rotate: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(model.isFullscreen)
        XCTAssertTrue(model.player.currentItem === currentItem)
        let fullscreenSettings = settings.convert(settings.bounds, to: window)
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
