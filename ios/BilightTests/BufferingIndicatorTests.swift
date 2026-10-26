import AVKit
import SwiftUI
import XCTest

@testable import Bilight

final class BufferingIndicatorTests: XCTestCase {
    @MainActor func testPreparingAndFailedSourcesHaveClearLoadingFeedback() async throws {
        let fixture = try await makePlayer()
        defer { fixture.close() }
        let indicator = try indicator(in: fixture.container)
        XCTAssertTrue(indicator.isHidden)
        fixture.model.busy = true
        fixture.container.updateLoadingIndicator()
        try await waitUntil("Preparing a source must not leave a silent frozen frame") { !indicator.isHidden }
        XCTAssertFalse(indicator.isUserInteractionEnabled, "The loading presentation must not consume controls or video gestures")
        fixture.model.busy = false
        fixture.model.error = "测试加载失败"
        fixture.container.updateLoadingIndicator()
        XCTAssertTrue(indicator.isHidden, "An actual failure is shown by the error UI rather than an endless loading animation")
        fixture.model.error = nil
        fixture.model.stop()
        fixture.container.updateLoadingIndicator()
        XCTAssertTrue(indicator.isHidden)
    }

    @MainActor func testRealWaitingPausingPlaybackAndFullscreenUpdateSameIndicator() async throws {
        let fixture = try await makePlayer()
        defer { fixture.close() }
        let indicator = try indicator(in: fixture.container)
        let held = HeldMediaResource()
        let asset = AVURLAsset(url: URL(string: "bilight-buffering-test://media/held.mp4")!)
        asset.resourceLoader.setDelegate(held, queue: .main)
        defer { held.cancel() }
        fixture.model.player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        fixture.model.player.play()
        try await waitUntil("A real unresolved AVPlayer resource must enter waiting and display loading") {
            held.receivedRequest && fixture.model.player.timeControlStatus == .waitingToPlayAtSpecifiedRate && !indicator.isHidden
        }
        fixture.window.layoutIfNeeded()
        let preview = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
            fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: preview)
        attachment.name = "buffering-local-window"; attachment.lifetime = .keepAlways; add(attachment)
        fixture.model.player.pause()
        try await waitUntil("An intentional pause must immediately stop the loading presentation") {
            fixture.model.player.timeControlStatus == .paused && indicator.isHidden
        }
        fixture.model.player.play()
        try await waitUntil("Resuming an unresolved stream shows loading again") { !indicator.isHidden }
        fixture.container.enterFullscreen(rotate: false)
        try await waitUntil("The actual player hierarchy must reach fullscreen") {
            fixture.model.isFullscreen && fixture.container.presentedViewController?.viewIfLoaded?.window != nil
        }
        XCTAssertTrue(try self.indicator(in: fixture.container) === indicator, "Fullscreen reuses the same loading presentation")
        XCTAssertFalse(indicator.isHidden)
        XCTAssertTrue(indicator.window === fixture.window)
        XCTAssertFalse(indicator.isUserInteractionEnabled)
        let settings = try XCTUnwrap(fixture.container.controller.contentOverlayView?.viewWithTag(1743) as? UIButton)
        let point = settings.convert(CGPoint(x: settings.bounds.midX, y: settings.bounds.midY), to: fixture.window)
        let hit = fixture.window.hitTest(point, with: nil)
        XCTAssertTrue(hit === settings || hit?.isDescendant(of: settings) == true, "Loading must leave settings directly tappable")
        fixture.container.exitFullscreen()
        try await waitUntil("Loading and the player return to the inline hierarchy") {
            !fixture.model.isFullscreen && fixture.container.controller.parent === fixture.container
        }
        XCTAssertTrue(try self.indicator(in: fixture.container) === indicator)
        // Complete the deliberately held test resource before switching, mirroring the
        // production loader's cancellation rather than leaving an infinite preroll alive.
        fixture.model.player.pause(); held.cancel(); asset.cancelLoading()
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fullscreen-motion", withExtension: "mp4"))
        fixture.model.player.replaceCurrentItem(with: AVPlayerItem(url: media))
        fixture.model.player.play()
        try await waitUntil("Replacing the stalled source with real local playback clears loading") {
            fixture.model.player.timeControlStatus == .playing && fixture.model.player.currentTime().seconds > 0.2 && indicator.isHidden
        }
        fixture.model.stop()
        try await waitUntil("Stopping clears the current source and its loading UI") {
            fixture.model.player.currentItem == nil && indicator.isHidden
        }
    }

    @MainActor private func indicator(in container: PlayerContainer) throws -> UIView {
        try XCTUnwrap(descendants(container.controller.view).first { $0.accessibilityIdentifier == "player-buffering-indicator" })
    }
    @MainActor private func descendants(_ root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap(descendants)
    }
    @MainActor private func waitUntil(_ message: String, timeout: TimeInterval = 5, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), message)
    }
    @MainActor private func makePlayer() async throws -> PlayerFixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
        let model = PlayerModel()
        let host = UIHostingController(rootView: NativePlayer(model: model, onQuality: { _ in }))
        window.rootViewController = root
        root.view.backgroundColor = .systemBackground
        root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
        host.view.frame = CGRect(x: 0, y: 100, width: window.bounds.width, height: 240)
        window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        func containers(_ parent: UIViewController) -> [PlayerContainer] {
            (parent as? PlayerContainer).map { [$0] } ?? parent.children.flatMap(containers)
        }
        let deadline = Date().addingTimeInterval(3)
        while containers(root).isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let container = try XCTUnwrap(containers(root).first)
        return PlayerFixture(model: model, container: container, window: window, previousWindow: previousWindow)
    }
    @MainActor private struct PlayerFixture {
        let model: PlayerModel
        let container: PlayerContainer
        let window: UIWindow
        let previousWindow: UIWindow?
        func close() {
            container.shutdown(); model.stop(); window.isHidden = true; previousWindow?.makeKeyAndVisible()
        }
    }
}

/// Keeps the real AVFoundation load pending without sockets, credentials or external requests.
private final class HeldMediaResource: NSObject, AVAssetResourceLoaderDelegate {
    private var requests: [AVAssetResourceLoadingRequest] = []
    private(set) var receivedRequest = false
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        receivedRequest = true; requests.append(loadingRequest)
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        requests.removeAll { $0 === loadingRequest }
    }
    func cancel() {
        let pending = requests; requests = []
        for request in pending where !request.isFinished && !request.isCancelled { request.finishLoading(with: URLError(.cancelled)) }
    }
}
