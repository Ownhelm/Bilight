import AVKit
import SwiftUI
import XCTest

@testable import Bilight

final class PlayerChromeTests: XCTestCase {
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
