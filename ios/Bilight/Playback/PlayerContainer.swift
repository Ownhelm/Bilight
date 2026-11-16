import AVKit
import Combine
import SwiftUI

/// Move the same AVKit controller between containers; orientation changes never replace its player or item.
@MainActor final class PlayerContainer: UIViewController, UIGestureRecognizerDelegate {
    private static let fullscreenBackSize: CGFloat = 44
    let controller: AVPlayerViewController
    private let model: PlayerModel
    private let fullscreenButton = UIButton(type: .system)
    private let fullscreenBackButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let watchLaterButton = UIButton(type: .system)
    private let watchLaterSpinner = UIActivityIndicatorView(style: .medium)
    private var watchLater: PlaybackWatchLater?
    private var watchLaterUpdates: AnyCancellable?
    private var fullscreenNotice: UIHostingController<WatchLaterNotification>?
    private var afterFullscreen: (() -> Void)?
    var settingsContent: ((@escaping () -> Void) -> AnyView)?
    var settingsInterfaceStyle: UIUserInterfaceStyle = .unspecified
    var captionBottom: NSLayoutConstraint?
    private var settingsController: UIHostingController<AnyView>?
    private let lockButton = UIButton(type: .system)
    private var fullscreenLocked = false
    private var fullscreen: FullscreenContainer?
    private var orientationObserver: NSObjectProtocol?
    private var exitingFullscreen = false
    private var lifecycleInactive = false
    private var backgroundPlayback: (AVPlayerItem?, Bool)?
    private var foregroundRecovery: Task<Void, Never>?
    private var deviceWasLandscape = false
    private var suppressUntilPortrait = false
    private var playbackIntent: (AVPlayerItem?, Bool)?
    private var controlsAutoHide: Task<Void, Never>?
    private var settingsMenuVisible = false
    private var playbackControls: PlaybackControls?
    private let loadingView = UIView()
    private let loadingSpinner = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = UILabel()
    private var loadingObservations: [NSKeyValueObservation] = []
    private var loadingItemObservation: NSKeyValueObservation?
    private var loadingDelay: Task<Void, Never>?
    private var loadingStopped = false
    private let seekFeedback = UILabel()
    private var seekFeedbackTask: Task<Void, Never>?
    private var isPreviewingSeek = false
    private var fullscreenPullStart = CGPoint.zero
    private var panStart = CGPoint.zero
    private enum PanDirection { case seek, brightness, volume }
    private enum SurfacePan { case seek(start: Double), brightness(start: CGFloat), volume(start: Float) }
    private var surfacePanAction: SurfacePan?
    private var brightnessAdjustment: (screen: UIScreen, original: CGFloat, applied: CGFloat)?
    var onToggleDanmaku: (() -> Void)?
    private lazy var speedHold: UILongPressGestureRecognizer = {
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(temporarySpeedHeld(_:)))
        hold.minimumPressDuration = 0.5
        hold.allowableMovement = 12
        hold.name = "bilight-hold-double-speed"
        hold.delegate = self
        return hold
    }()
    private lazy var playbackTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTapPlayback))
        tap.numberOfTapsRequired = 2
        tap.name = "bilight-double-tap-playback"
        tap.delegate = self
        return tap
    }()
    private lazy var fullscreenTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(fullscreenSurfaceTapped))
        tap.name = "bilight-fullscreen-controls"
        tap.cancelsTouchesInView = false
        tap.require(toFail: playbackTap)
        tap.delegate = self
        return tap
    }()
    private lazy var surfacePan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(surfacePanned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        return pan
    }()
    private lazy var danmakuTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleDanmaku))
        tap.numberOfTouchesRequired = 2
        tap.delegate = self
        return tap
    }()
    private lazy var zoomPinch: UIPinchGestureRecognizer = {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        pinch.delegate = self
        return pinch
    }()
    private lazy var fullscreenPull: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(fullscreenPulled(_:)))
        pan.name = "bilight-fullscreen-pull-down"
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        return pan
    }()
    private var isPortraitFullscreen: Bool {
        guard let fullscreen, !exitingFullscreen else { return false }
        return Self.orientation(fullscreen.view.window?.windowScene)?.isPortrait == true
    }
    var nativeFullscreen = false
    var orientationMask: UIInterfaceOrientationMask {
        model.isFullscreen && !exitingFullscreen ? .allButUpsideDown : .portrait
    }
    init(controller: AVPlayerViewController, model: PlayerModel) {
        self.controller = controller
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func installPlaybackControls(_ controls: PlaybackControls) {
        playbackControls = controls
        controls.onActivity = { [weak self] in
            guard let self else { return }
            self.controlsAutoHide?.cancel()
            self.setFullscreenButtonVisible(true, animated: true)
            self.scheduleControlsAutoHide()
        }
        controls.onScrubPreview = { [weak self] target, duration, cancelOnRelease in
            self?.showScrubPreview(target, duration: duration, cancelOnRelease: cancelOnRelease)
        }
        loadViewIfNeeded()
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Self.attach(controller, to: self)
        controller.view.addGestureRecognizer(playbackTap)
        controller.view.addGestureRecognizer(speedHold)
        controller.view.addGestureRecognizer(surfacePan)
        controller.view.addGestureRecognizer(danmakuTap)
        controller.view.addGestureRecognizer(zoomPinch)
        playbackTap.require(toFail: speedHold)
        fullscreenTap.require(toFail: speedHold)
        fullscreenTap.require(toFail: danmakuTap)
        danmakuTap.require(toFail: zoomPinch)
        if let overlay = controller.contentOverlayView {
            loadingView.accessibilityIdentifier = "player-buffering-indicator"
            loadingView.isAccessibilityElement = true
            loadingView.isUserInteractionEnabled = false
            loadingView.backgroundColor = .black.withAlphaComponent(0.65)
            loadingView.layer.cornerRadius = 12
            loadingView.isHidden = true
            loadingView.translatesAutoresizingMaskIntoConstraints = false
            loadingSpinner.color = UIColor(red: 233.0 / 255, green: 82.0 / 255, blue: 131.0 / 255, alpha: 1)
            loadingLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 14, weight: .medium), maximumPointSize: 22)
            loadingLabel.adjustsFontForContentSizeCategory = true
            loadingLabel.textColor = .white
            let row = UIStackView(arrangedSubviews: [loadingSpinner, loadingLabel])
            row.spacing = 10; row.alignment = .center; row.translatesAutoresizingMaskIntoConstraints = false
            loadingView.addSubview(row); overlay.addSubview(loadingView)
            NSLayoutConstraint.activate([
                loadingView.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), loadingView.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                loadingView.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, constant: -32),
                row.leadingAnchor.constraint(equalTo: loadingView.leadingAnchor, constant: 16), row.trailingAnchor.constraint(equalTo: loadingView.trailingAnchor, constant: -16),
                row.topAnchor.constraint(equalTo: loadingView.topAnchor, constant: 12), row.bottomAnchor.constraint(equalTo: loadingView.bottomAnchor, constant: -12),
            ])
            loadingObservations = [
                model.player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in self?.updateLoadingIndicator() }
                },
                model.player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in
                        self?.cancelSurfacePan()
                        self?.controller.videoGravity = .resizeAspect
                        self?.observeLoadingItem()
                    }
                },
            ]
            seekFeedback.textAlignment = .center
            seekFeedback.numberOfLines = 2
            seekFeedback.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
            seekFeedback.textColor = .white
            seekFeedback.backgroundColor = .black.withAlphaComponent(0.65)
            seekFeedback.layer.cornerRadius = 8
            seekFeedback.clipsToBounds = true
            seekFeedback.isUserInteractionEnabled = false
            seekFeedback.accessibilityIdentifier = "player-gesture-feedback"
            seekFeedback.isHidden = true
            seekFeedback.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(seekFeedback)
            NSLayoutConstraint.activate([seekFeedback.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), seekFeedback.centerYAnchor.constraint(equalTo: overlay.centerYAnchor), seekFeedback.heightAnchor.constraint(equalToConstant: 46)])
        }
        fullscreenButton.tintColor = .white
        fullscreenButton.addTarget(self, action: #selector(toggleFullscreen), for: .touchUpInside)
        fullscreenBackButton.tintColor = .white
        fullscreenBackButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
        fullscreenBackButton.accessibilityLabel = "退出全屏"
        fullscreenBackButton.accessibilityIdentifier = "player-fullscreen-back"
        fullscreenBackButton.backgroundColor = .black.withAlphaComponent(0.45)
        fullscreenBackButton.layer.cornerRadius = Self.fullscreenBackSize / 2
        fullscreenBackButton.addTarget(self, action: #selector(toggleFullscreen), for: .touchUpInside)
        settingsButton.tag = 1743
        settingsButton.tintColor = .white
        settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
        PlaybackControls.addGlyphShadow(to: settingsButton.imageView)
        settingsButton.accessibilityLabel = "播放设置"
        settingsButton.accessibilityIdentifier = "player-settings"
        settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        watchLaterButton.tintColor = .white
        watchLaterButton.accessibilityIdentifier = "player-watch-later"
        watchLaterButton.addTarget(self, action: #selector(toggleWatchLater), for: .touchUpInside)
        watchLaterSpinner.color = .white
        watchLaterSpinner.isUserInteractionEnabled = false
        watchLaterSpinner.hidesWhenStopped = true
        watchLaterSpinner.translatesAutoresizingMaskIntoConstraints = false
        watchLaterButton.addSubview(watchLaterSpinner)
        NSLayoutConstraint.activate([
            watchLaterSpinner.centerXAnchor.constraint(equalTo: watchLaterButton.centerXAnchor),
            watchLaterSpinner.centerYAnchor.constraint(equalTo: watchLaterButton.centerYAnchor)
        ])
        updateWatchLater()
        lockButton.tintColor = .white
        lockButton.backgroundColor = .black.withAlphaComponent(0.45)
        lockButton.layer.cornerRadius = 9
        lockButton.accessibilityIdentifier = "player-fullscreen-lock"
        lockButton.addTarget(self, action: #selector(toggleFullscreenLock), for: .touchUpInside)
        placeButton(in: view, expanded: false)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if playbackControls != nil { scheduleControlsAutoHide() }
        PlaybackOrientationDelegate.active = self
        if orientationObserver == nil {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.deviceOrientationChanged() }
            }
        }
        if fullscreen == nil, !nativeFullscreen, Self.orientation(view.window?.windowScene)?.isLandscape == true {
            enterFullscreen(rotate: false, automatic: true)
        } else {
            refreshOrientationPolicy()
            if fullscreen == nil { deviceOrientationChanged() }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !model.isFullscreen && !lifecycleInactive && !settingsMenuVisible { releaseOrientation() }
    }
    private func deviceOrientationChanged() {
        guard PlaybackOrientationDelegate.active === self, !lifecycleInactive, !settingsMenuVisible else { return }
        let orientation = UIDevice.current.orientation
        if orientation.isPortrait { suppressUntilPortrait = false }
        if orientation.isLandscape {
            deviceWasLandscape = true
            if fullscreen == nil, !nativeFullscreen, !suppressUntilPortrait { enterFullscreen(automatic: true) }
        } else if orientation.isPortrait, deviceWasLandscape, fullscreen?.exitsOnPortrait == true {
            exitFullscreen()
        }
    }
    @objc private func toggleFullscreen() {
        if fullscreen != nil { exitFullscreen() } else { enterFullscreen() }
    }
    func enterFullscreen(rotate: Bool = true, animated: Bool = false, automatic: Bool = false) {
        guard !lifecycleInactive, fullscreen == nil, !nativeFullscreen, view.window != nil, presentedViewController == nil,
            !isBeingDismissed
        else { return }
        let target = FullscreenContainer()
        let currentOrientation = Self.orientation(view.window?.windowScene) ?? .portrait
        let size = model.player.currentItem?.presentationSize ?? .zero
        let portraitVideo = size.width > 0 ? size.height > size.width : (model.playback?.video.map { $0.height > $0.width } ?? false)
        target.preferredOrientation = rotate
            ? (portraitVideo && !automatic ? .portrait : (currentOrientation.isLandscape ? currentOrientation : .landscapeRight))
            : currentOrientation
        target.exitsOnPortrait = automatic || (rotate && !portraitVideo)
        target.modalPresentationStyle = .fullScreen
        target.modalPresentationCapturesStatusBarAppearance = true
        target.onOrientation = { [weak self, weak target] landscape in
            guard let self, let target, !self.lifecycleInactive else { return }
            if landscape {
                target.hasBeenLandscape = true
            } else if target.hasBeenLandscape && target.exitsOnPortrait && !self.settingsMenuVisible {
                self.exitFullscreen()
            }
        }
        target.onDismiss = { [weak self, weak target] in
            guard let self, let target else { return }
            // A disappearing view during a Home gesture is not a completed modal dismissal.
            guard !self.lifecycleInactive, !target.isBeingDismissed, target.presentingViewController == nil else { return }
            self.restoreInline(from: target)
        }
        fullscreen = target
        rememberPlayback()
        model.isFullscreen = true
        exitingFullscreen = false
        deviceWasLandscape = UIDevice.current.orientation.isLandscape
        suppressUntilPortrait = false
        refreshOrientationPolicy()
        Self.detach(controller)
        target.loadViewIfNeeded()
        Self.attach(controller, to: target)
        placeButton(in: target.view, expanded: true)
        present(target, animated: animated) { [weak self] in
            guard let self else { return }
            if self.exitingFullscreen {
                self.finishExit(from: target)
                return
            }
            self.restorePlayback()
            self.traceFullscreen(active: true)
            self.scheduleControlsAutoHide()
            if rotate { self.requestOrientation(target.preferredOrientation.isPortrait ? .portrait : .landscape, from: target) }
        }
    }
    func exitFullscreen() {
        guard let target = fullscreen, !target.isBeingDismissed, !exitingFullscreen else { return }
        removeFullscreenNotice()
        cancelSurfacePan()
        restoreScreenBrightness()
        if playbackIntent == nil { rememberPlayback() }
        exitingFullscreen = true
        controlsAutoHide?.cancel()
        refreshOrientationPolicy()
        // Presentation may not have a window yet. Its completion will honor this exit request.
        // Dismiss first: a portrait geometry request need not produce a rotation callback.
        closeSettings { [weak self] in self?.finishExit(from: target) }
    }
    private func finishExit(from target: FullscreenContainer) {
        guard !lifecycleInactive, fullscreen === target, !target.isBeingPresented, !target.isBeingDismissed else { return }
        if playbackIntent == nil { rememberPlayback() }
        target.dismiss(animated: false) { [weak self, weak target] in
            guard let self, let target else { return }
            self.restoreInline(from: target)
        }
    }
    private func restoreInline(from target: FullscreenContainer) {
        guard fullscreen === target else { return }
        restoreScreenBrightness()
        suppressUntilPortrait = !UIDevice.current.orientation.isPortrait
        Self.detach(controller)
        Self.attach(controller, to: self)
        cancelSurfacePan()
        fullscreenLocked = false
        controller.videoGravity = .resizeAspect
        placeButton(in: view, expanded: false)
        fullscreen = nil
        target.onOrientation = nil
        target.onDismiss = nil
        model.isFullscreen = nativeFullscreen
        exitingFullscreen = false
        refreshOrientationPolicy()
        requestOrientation(.portrait, scene: view.window?.windowScene)
        restorePlayback()
        traceFullscreen(active: false)
        let callback = afterFullscreen
        afterFullscreen = nil
        callback?()
    }
    private func rememberPlayback() {
        model.endTemporarySpeed()
        playbackIntent = (model.player.currentItem, model.player.timeControlStatus != .paused)
    }
    private func traceFullscreen(active: Bool) {
        let position = model.player.currentTime().seconds
        NativeTrace.mark(
            .fullscreenChanged,
            [
                "active": active ? 1 : 0, "playing": model.player.timeControlStatus == .paused ? 0 : 1,
                "positionMs": position.isFinite ? Int(max(0, position) * 1000) : 0,
            ])
    }
    private func restorePlayback() {
        guard !lifecycleInactive, let intent = playbackIntent else { return }
        playbackIntent = nil
        guard model.player.currentItem === intent.0 else { return }
        model.restorePlaybackSpeed()
        if intent.1 {
            if model.player.timeControlStatus == .paused { model.player.play() }
        } else if model.player.timeControlStatus != .paused { model.player.pause() }
    }
    func nativeFullscreenEnded(cancelled: Bool) {
        nativeFullscreen = cancelled
        model.isFullscreen = fullscreen != nil || cancelled
        if !cancelled, fullscreen == nil {
            suppressUntilPortrait = true
            requestOrientation(.portrait, scene: view.window?.windowScene)
        }
        refreshOrientationPolicy()
    }
    func refreshOrientationPolicy() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        let scene = fullscreen?.viewIfLoaded?.window?.windowScene ?? viewIfLoaded?.window?.windowScene
        scene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        fullscreen?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
    private func releaseOrientation() {
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
            self.orientationObserver = nil
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        if PlaybackOrientationDelegate.active === self {
            PlaybackOrientationDelegate.active = nil
            refreshOrientationPolicy()
        }
    }
    private func requestOrientation(_ mask: UIInterfaceOrientationMask, from target: UIViewController) {
        target.setNeedsUpdateOfSupportedInterfaceOrientations()
        requestOrientation(mask, scene: target.view.window?.windowScene)
    }
    private func requestOrientation(_ mask: UIInterfaceOrientationMask, scene: UIWindowScene?) {
        guard !lifecycleInactive else { return }
        setNeedsUpdateOfSupportedInterfaceOrientations()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
    private func placeButton(in container: UIView, expanded: Bool) {
        controlsAutoHide?.cancel()
        fullscreenTap.view?.removeGestureRecognizer(fullscreenTap)
        fullscreenPull.view?.removeGestureRecognizer(fullscreenPull)
        if expanded || playbackControls != nil { container.addGestureRecognizer(fullscreenTap) }
        if expanded {
            container.addGestureRecognizer(fullscreenPull)
        }
        lockButton.removeFromSuperview()
        if expanded {
            lockButton.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(lockButton)
            NSLayoutConstraint.activate([
                lockButton.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 10),
                lockButton.centerYAnchor.constraint(equalTo: container.safeAreaLayoutGuide.centerYAnchor),
                lockButton.widthAnchor.constraint(equalToConstant: 44),
                lockButton.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
        updateLockButton()
        fullscreenBackButton.removeFromSuperview()
        if expanded {
            fullscreenBackButton.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(fullscreenBackButton)
            NSLayoutConstraint.activate([
                fullscreenBackButton.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 10),
                fullscreenBackButton.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
                fullscreenBackButton.widthAnchor.constraint(equalToConstant: Self.fullscreenBackSize),
                fullscreenBackButton.heightAnchor.constraint(equalToConstant: Self.fullscreenBackSize),
            ])
        }
        watchLaterButton.removeFromSuperview()
        watchLaterButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(watchLaterButton)
        NSLayoutConstraint.activate([
            watchLaterButton.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            watchLaterButton.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            watchLaterButton.widthAnchor.constraint(equalToConstant: 44),
            watchLaterButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        setFullscreenButtonVisible(true, animated: false)
        fullscreenButton.removeFromSuperview()
        fullscreenButton.setImage(
            UIImage(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"),
            for: .normal)
        PlaybackControls.addGlyphShadow(to: fullscreenButton.imageView)
        fullscreenButton.accessibilityLabel = expanded ? "退出全屏" : "全屏播放"
        fullscreenButton.accessibilityIdentifier = "player-fullscreen-toggle"
        fullscreenButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fullscreenButton)
        NSLayoutConstraint.activate([
            fullscreenButton.trailingAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            fullscreenButton.bottomAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            fullscreenButton.widthAnchor.constraint(equalToConstant: 44),
            fullscreenButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        if let controls = playbackControls {
            controls.removeFromSuperview()
            controls.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(controls)
            NSLayoutConstraint.activate([
                controls.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 8),
                controls.trailingAnchor.constraint(equalTo: fullscreenButton.trailingAnchor),
                controls.bottomAnchor.constraint(equalTo: fullscreenButton.bottomAnchor),
                controls.heightAnchor.constraint(equalToConstant: 88),
            ])
            container.bringSubviewToFront(fullscreenButton)
        }
        settingsButton.removeFromSuperview()
        if playbackControls != nil {
            settingsButton.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(settingsButton)
            NSLayoutConstraint.activate([
                settingsButton.trailingAnchor.constraint(equalTo: fullscreenButton.leadingAnchor, constant: -3),
                settingsButton.bottomAnchor.constraint(equalTo: fullscreenButton.bottomAnchor),
                settingsButton.widthAnchor.constraint(equalToConstant: 44),
                settingsButton.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
    }

    func configureWatchLater(_ config: PlaybackWatchLater?) {
        let changed = watchLater?.store !== config?.store || watchLater?.video.aid != config?.video.aid
        watchLater = config
        if changed {
            watchLaterUpdates = config?.store.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.updateWatchLater() }
            }
            config?.store.prepare()
        }
        updateWatchLater()
    }

    private func updateWatchLater() {
        watchLaterButton.isHidden = watchLater == nil
        guard let watchLater else { removeFullscreenNotice(); return }
        let aid = watchLater.video.aid
        let saved = watchLater.store.contains(aid)
        let pending = watchLater.store.pending.contains(aid)
        watchLaterButton.setImage(pending ? nil : saved ? Self.watchLaterSaved : Self.watchLaterAvailable, for: .normal)
        if let image = watchLaterButton.imageView {
            image.layer.shadowColor = UIColor.black.cgColor
            image.layer.shadowOpacity = 0.7
            image.layer.shadowRadius = 2
            image.layer.shadowOffset = CGSize(width: 0, height: 1)
            image.clipsToBounds = false
        }
        if pending { watchLaterSpinner.startAnimating() } else { watchLaterSpinner.stopAnimating() }
        watchLaterButton.isEnabled = !pending
        watchLaterButton.accessibilityLabel = saved ? "移出稍后再看" : "加入稍后再看"
        watchLaterButton.accessibilityValue = pending ? "正在同步" : saved ? "已加入" : nil
        if let fullscreen, watchLater.store.notice != nil, !settingsMenuVisible {
            if fullscreenNotice == nil {
                let host = UIHostingController(rootView: WatchLaterNotification(store: watchLater.store))
                host.view.backgroundColor = .clear
                host.sizingOptions = .intrinsicContentSize
                fullscreen.addChild(host)
                fullscreen.view.addSubview(host.view)
                host.view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    host.view.centerXAnchor.constraint(equalTo: fullscreen.view.safeAreaLayoutGuide.centerXAnchor),
                    host.view.bottomAnchor.constraint(equalTo: fullscreen.view.safeAreaLayoutGuide.bottomAnchor, constant: -104),
                    host.view.widthAnchor.constraint(lessThanOrEqualTo: fullscreen.view.safeAreaLayoutGuide.widthAnchor, constant: -28),
                ])
                host.didMove(toParent: fullscreen)
                fullscreenNotice = host
            }
        } else { removeFullscreenNotice() }
    }

    private static let watchLaterAvailable = watchLaterImage("WatchLater")
    private static let watchLaterSaved = watchLaterImage("WatchLaterSaved")

    private static func watchLaterImage(_ name: String) -> UIImage? {
        guard let source = UIImage(named: name)?.withRenderingMode(.alwaysOriginal) else { return nil }
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
            .withRenderingMode(.alwaysTemplate)
    }

    private func removeFullscreenNotice() {
        guard let current = fullscreenNotice else { return }
        Self.detach(current)
        fullscreenNotice = nil
    }

    @objc private func toggleWatchLater() {
        guard let watchLater else { return }
        if let signIn = watchLater.onLogin {
            if fullscreen != nil { afterFullscreen = signIn; exitFullscreen() }
            else { signIn() }
        } else { watchLater.store.toggle(watchLater.video) }
        scheduleControlsAutoHide()
    }

    @objc private func openSettings() {
        let presenter: UIViewController = fullscreen.map { $0 as UIViewController } ?? self
        guard let settingsContent, !settingsMenuVisible, !fullscreenLocked, !exitingFullscreen,
            !lifecycleInactive, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil,
            !presenter.isBeingPresented, !presenter.isBeingDismissed
        else { return }
        let host = UIHostingController(rootView: settingsContent { [weak self] in self?.closeSettings() })
        settingsController = host
        settingsMenuVisible = true
        controlsAutoHide?.cancel()
        removeFullscreenNotice()
        host.modalPresentationStyle = .overFullScreen
        host.overrideUserInterfaceStyle = settingsInterfaceStyle
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        presenter.present(host, animated: false)
    }

    private func closeSettings(completion: (() -> Void)? = nil) {
        guard let host = settingsController else { completion?(); return }
        host.dismiss(animated: false) { [weak self] in
            self?.settingsDidDismiss(host)
            completion?()
        }
    }

    private func settingsDidDismiss(_ host: UIViewController) {
        guard host === settingsController else { return }
        settingsController = nil
        settingsMenuVisible = false
        updateWatchLater()
        scheduleControlsAutoHide()
    }

    @objc func fullscreenSurfaceTapped() {
        guard fullscreen != nil || playbackControls != nil, !exitingFullscreen else { return }
        controlsAutoHide?.cancel()
        let visible = fullscreenButton.alpha < 0.01 || UIAccessibility.isVoiceOverRunning
        setFullscreenButtonVisible(visible, animated: true)
        if visible { scheduleControlsAutoHide() }
    }
    @objc private func toggleFullscreenLock() {
        guard fullscreen != nil else { return }
        fullscreenLocked.toggle()
        if fullscreenLocked {
            model.endTemporarySpeed()
            cancelSurfacePan()
        }
        updateLockButton()
        setFullscreenButtonVisible(!fullscreenLocked, animated: true)
        scheduleControlsAutoHide()
    }
    private func updateLockButton() {
        lockButton.setImage(UIImage(systemName: fullscreenLocked ? "lock.fill" : "lock.open"), for: .normal)
        lockButton.accessibilityLabel = fullscreenLocked ? "解锁播放控件" : "锁定播放控件"
    }
    @objc func fullscreenPulled(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            // UIKit resets translation at recognition; retain the movement that began a quick pull.
            gesture.setTranslation(fullscreenPullStart, in: gesture.view)
            fullscreenPullStart = .zero
            return
        }
        guard gesture.state == .ended, isPortraitFullscreen else { return }
        let distance = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        guard distance.y > abs(distance.x) * 1.3,
            distance.y >= 80 || (distance.y >= 28 && velocity.y >= 700)
        else { return }
        exitFullscreen()
    }
    @objc func doubleTapPlayback() { playbackControls?.togglePlayback() }
    @objc private func toggleDanmaku() { onToggleDanmaku?() }
    @objc private func toggleZoom(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .ended else { return }
        if gesture.scale > 1.12 { controller.videoGravity = .resizeAspectFill }
        else if gesture.scale < 0.88 { controller.videoGravity = .resizeAspect }
    }
    @objc private func surfacePanned(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            let point = gesture.location(in: controller.view)
            let origin = CGPoint(x: point.x - panStart.x, y: point.y - panStart.y)
            gesture.setTranslation(panStart, in: gesture.view)
            switch panDirection(panStart, origin: origin) {
            case .seek:
                if let start = playbackControls?.beginScrub() { surfacePanAction = .seek(start: start) }
            case .brightness:
                if let brightness = controller.view.window?.windowScene?.screen.brightness {
                    surfacePanAction = .brightness(start: brightness)
                }
            case .volume: surfacePanAction = .volume(start: model.player.volume)
            case nil: break
            }
        }
        guard let surfacePanAction else { return }
        if gesture.state == .cancelled || gesture.state == .failed { cancelSurfacePan(); return }
        let translation = gesture.translation(in: gesture.view)
        let released = gesture.state == .ended
        switch surfacePanAction {
        case .seek(let start):
            let bounds = controller.view.bounds
            let point = gesture.location(in: controller.view)
            let cornerWidth = min(60, bounds.width * 0.15)
            let inCancelCorner = point.y <= min(60, bounds.height * 0.2)
                && (point.x <= cornerWidth || point.x >= bounds.width - cornerWidth)
            let secondsPerWidth = min(playbackControls?.duration ?? 0, 60)
            let target = start + Double(translation.x / max(1, bounds.width)) * secondsPerWidth
            if released {
                if inCancelCorner { playbackControls?.cancelScrub() }
                else { playbackControls?.finishScrub(at: target) }
            } else {
                playbackControls?.previewScrub(at: target, cancelOnRelease: inCancelCorner)
            }
        case .brightness(let start):
            let value = min(1, max(0, start - translation.y / max(1, controller.view.bounds.height)))
            guard let screen = controller.view.window?.windowScene?.screen else { cancelSurfacePan(); return }
            if brightnessAdjustment?.screen !== screen { restoreScreenBrightness() }
            let original = brightnessAdjustment?.original ?? screen.brightness
            screen.brightness = value
            let applied = screen.brightness
            brightnessAdjustment = (screen, original, applied)
            showGestureFeedback("亮度 \(Int((applied * 100).rounded()))%", briefly: released)
        case .volume(let start):
            let value = min(1, max(0, start - Float(translation.y / max(1, controller.view.bounds.height))))
            model.player.volume = value
            showGestureFeedback("音量 \(Int((model.player.volume * 100).rounded()))%", briefly: released)
        }
        if released { self.surfacePanAction = nil }
    }
    private func cancelSurfacePan() {
        if case .seek = surfacePanAction { playbackControls?.cancelScrub() }
        surfacePanAction = nil
        if !isPreviewingSeek {
            seekFeedbackTask?.cancel()
            seekFeedback.isHidden = true
            updateLoadingIndicator()
        }
    }
    private func restoreScreenBrightness() {
        defer { brightnessAdjustment = nil }
        guard let brightnessAdjustment,
              abs(brightnessAdjustment.screen.brightness - brightnessAdjustment.applied) < 0.01 else { return }
        brightnessAdjustment.screen.brightness = brightnessAdjustment.original
    }
    @objc private func temporarySpeedHeld(_ gesture: UILongPressGestureRecognizer) { handleSpeedHold(gesture.state) }
    func handleSpeedHold(_ state: UIGestureRecognizer.State) {
        if state == .began {
            guard model.player.currentItem != nil, model.player.timeControlStatus != .paused else { return }
            model.beginTemporarySpeed()
        } else if state == .ended || state == .cancelled || state == .failed {
            model.endTemporarySpeed()
        }
    }
    func handleDoubleTap(at point: CGPoint) {
        let width = controller.view.bounds.width
        guard width > 0 else { return }
        // Use proportions of the current player viewport, including after fullscreen rotation.
        if point.x >= width * 0.4 && point.x < width * 0.6 {
            playbackControls?.togglePlayback()
            return
        }
        let delta = point.x < width * 0.4 ? -10.0 : 10.0
        let before = model.player.currentTime().seconds
        guard let target = model.seek(delta) else { return }
        showSeekFeedback(before: before, target: target)
    }
    func showSeekFeedback(before: Double, target: Double) {
        let seconds = Int(abs(target - before).rounded())
        let direction = target > before ? "前进" : "后退"
        showGestureFeedback(seconds == 0 ? "已到视频边界" : "\(direction) \(seconds) 秒 · \(timeLabel(target))", briefly: true)
    }
    private func showScrubPreview(_ target: Double?, duration: Double, cancelOnRelease: Bool) {
        isPreviewingSeek = target != nil
        if let target {
            let format = duration >= 3600 ? "%02d:%02d:%02d" : "%02d:%02d"
            func clock(_ value: Double) -> String {
                let seconds = Int(value)
                return duration >= 3600
                    ? String(format: format, seconds / 3600, seconds / 60 % 60, seconds % 60)
                    : String(format: format, seconds / 60, seconds % 60)
            }
            let time = "\(clock(target)) / \(clock(duration))"
            showGestureFeedback(cancelOnRelease ? "\(time)\n松手取消" : time)
        } else {
            seekFeedback.isHidden = true
        }
        updateLoadingIndicator()
    }
    private func showGestureFeedback(_ text: String, briefly: Bool = false) {
        let wasHidden = seekFeedback.isHidden
        seekFeedback.text = "   \(text)   "
        seekFeedback.isHidden = false
        if wasHidden { updateLoadingIndicator() }
        seekFeedbackTask?.cancel()
        guard briefly else { return }
        seekFeedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            self?.seekFeedback.isHidden = true
            self?.updateLoadingIndicator()
        }
    }
    private func scheduleControlsAutoHide() {
        controlsAutoHide?.cancel()
        guard !lifecycleInactive, !settingsMenuVisible, fullscreen != nil || playbackControls != nil,
              !UIAccessibility.isVoiceOverRunning else { return }
        controlsAutoHide = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, self.fullscreen != nil || self.playbackControls != nil, !UIAccessibility.isVoiceOverRunning else { return }
            if self.playbackControls?.isInteracting == true { self.scheduleControlsAutoHide(); return }
            self.setFullscreenButtonVisible(false, animated: true)
        }
    }
    private func setFullscreenButtonVisible(_ visible: Bool, animated: Bool) {
        let showTransport = visible && !fullscreenLocked
        playbackControls?.setVisible(showTransport, animated: animated)
        fullscreenButton.isUserInteractionEnabled = showTransport
        fullscreenButton.accessibilityElementsHidden = !showTransport
        for button in [settingsButton, fullscreenBackButton, watchLaterButton] {
            button.isUserInteractionEnabled = showTransport
            button.accessibilityElementsHidden = !showTransport
        }
        lockButton.isUserInteractionEnabled = visible || fullscreenLocked
        lockButton.accessibilityElementsHidden = !lockButton.isUserInteractionEnabled
        captionBottom?.constant = showTransport ? -102 : -38
        UIView.animate(withDuration: animated ? 0.2 : 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.fullscreenButton.alpha = showTransport ? 1 : 0
            self.lockButton.alpha = self.lockButton.isUserInteractionEnabled ? 1 : 0
            self.settingsButton.alpha = showTransport ? 1 : 0
            self.fullscreenBackButton.alpha = showTransport ? 1 : 0
            self.watchLaterButton.alpha = showTransport ? 1 : 0
            self.controller.contentOverlayView?.layoutIfNeeded()
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !fullscreenLocked, !exitingFullscreen, !lifecycleInactive, !settingsMenuVisible else { return false }
        if gestureRecognizer === danmakuTap { guard fullscreen != nil, onToggleDanmaku != nil else { return false } }
        if gestureRecognizer === zoomPinch && fullscreen == nil { return false }
        var target = touch.view
        while let view = target {
            if view is UIControl { return false }
            target = view.superview
        }
        return true
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === fullscreenPull {
            let distance = fullscreenPull.translation(in: fullscreenPull.view)
            let x = fullscreenPull.location(in: controller.view).x - distance.x
            return abs(x / max(1, controller.view.bounds.width) - 0.5) <= 0.1 && beginFullscreenPull(distance)
        }
        if gestureRecognizer === surfacePan {
            panStart = surfacePan.translation(in: surfacePan.view)
            let point = surfacePan.location(in: controller.view)
            return panDirection(panStart, origin: CGPoint(x: point.x - panStart.x, y: point.y - panStart.y)) != nil
        }
        return true
    }
    private func panDirection(_ travel: CGPoint, origin: CGPoint) -> PanDirection? {
        if abs(travel.x) > abs(travel.y) * 1.3 { return .seek }
        guard abs(travel.y) > abs(travel.x) * 1.3 else { return nil }
        let fraction = origin.x / max(1, controller.view.bounds.width)
        if isPortraitFullscreen && (0.4...0.6).contains(fraction) { return nil }
        return fraction < 0.5 ? .brightness : .volume
    }
    func beginFullscreenPull(_ distance: CGPoint) -> Bool {
        let accepted = isPortraitFullscreen && distance.y > 0 && distance.y > abs(distance.x) * 1.3
        fullscreenPullStart = accepted ? distance : .zero
        return accepted
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === surfacePan, let scrollView = otherGestureRecognizer.view as? UIScrollView,
           otherGestureRecognizer === scrollView.panGestureRecognizer, controller.view.isDescendant(of: scrollView) {
            // The page pan waits for a swipe that starts over the video. Outside it, only the page pan sees the touch.
            return true
        }
        return gestureRecognizer === playbackTap && otherGestureRecognizer is UITapGestureRecognizer
            && otherGestureRecognizer !== fullscreenTap && otherGestureRecognizer !== danmakuTap
    }
    static func orientation(_ scene: UIWindowScene?) -> UIInterfaceOrientation? {
        guard let scene else { return nil }
        if #available(iOS 26, *) { return scene.effectiveGeometry.interfaceOrientation }
        return scene.interfaceOrientation
    }
    private static func attach(_ child: UIViewController, to parent: UIViewController) {
        parent.addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        parent.view.insertSubview(child.view, at: 0)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
        ])
        child.didMove(toParent: parent)
    }
    private static func detach(_ child: UIViewController) {
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
    }
    private var loadingText: String? {
        guard !lifecycleInactive, !isPreviewingSeek, seekFeedback.isHidden, model.error == nil else { return nil }
        if model.busy { return "正在加载…" }
        guard let item = model.player.currentItem, item.status != .failed else { return nil }
        if model.player.timeControlStatus == .waitingToPlayAtSpecifiedRate { return "正在缓冲…" }
        return nil
    }
    private func observeLoadingItem() {
        loadingItemObservation?.invalidate()
        loadingItemObservation = model.player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateLoadingIndicator() }
        }
        updateLoadingIndicator()
    }
    func updateLoadingIndicator() {
        guard isViewLoaded, !loadingStopped else { return }
        guard let text = loadingText else {
            loadingDelay?.cancel(); loadingDelay = nil
            loadingView.isHidden = true; loadingSpinner.stopAnimating()
            return
        }
        loadingLabel.text = text; loadingView.accessibilityLabel = text
        // Ignore very short prerolls to avoid flashing the indicator during healthy playback.
        guard loadingView.isHidden, loadingDelay == nil else { return }
        loadingDelay = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !self.loadingStopped else { return }
            self.loadingDelay = nil
            guard let text = self.loadingText else { return }
            self.loadingLabel.text = text; self.loadingView.accessibilityLabel = text
            self.loadingSpinner.startAnimating(); self.loadingView.isHidden = false
        }
    }
    func resignPlaybackActivity() {
        model.endTemporarySpeed()
        cancelSurfacePan()
        restoreScreenBrightness()
        lifecycleInactive = true
        updateLoadingIndicator()
        foregroundRecovery?.cancel()
        controlsAutoHide?.cancel()
    }
    func backgroundPlaybackActivity() {
        resignPlaybackActivity()
        guard backgroundPlayback == nil else { return }
        backgroundPlayback = playbackIntent ?? (model.player.currentItem, model.player.timeControlStatus != .paused)
        model.flush()
        // AVPlayer's background policy and audio session keep audio running on this same item.
    }
    func activatePlaybackActivity() {
        lifecycleInactive = false
        foregroundRecovery?.cancel()
        foregroundRecovery = Task { @MainActor [weak self] in
            // Give UIKit's interrupted presentation/rotation a chance to settle first.
            await Task.yield()
            guard let self, !Task.isCancelled, !self.lifecycleInactive else { return }
            for _ in 0..<20 {
                if self.fullscreen?.isBeingPresented != true && self.fullscreen?.isBeingDismissed != true { break }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard !self.lifecycleInactive else { return }
            }
            guard !Task.isCancelled, !self.lifecycleInactive else { return }
            if let target = self.fullscreen {
                if target.presentingViewController === self || self.presentedViewController === target {
                    if self.controller.parent !== target {
                        Self.detach(self.controller); Self.attach(self.controller, to: target)
                    }
                    self.model.isFullscreen = true
                    if self.exitingFullscreen { self.finishExit(from: target) }
                } else if !target.isBeingPresented && !target.isBeingDismissed {
                    self.restoreInline(from: target)
                }
            }
            if self.controller.player !== self.model.player { self.controller.player = self.model.player }
            if self.backgroundPlayback != nil {
                self.backgroundPlayback = nil
                self.playbackIntent = nil
            } else { self.restorePlayback() }
            self.updateLoadingIndicator()
            self.refreshOrientationPolicy()
            self.setFullscreenButtonVisible(true, animated: false)
            self.scheduleControlsAutoHide()
            self.deviceOrientationChanged()
        }
    }
    func recordLifecycle(_ stage: NativeStage) {
        let time = model.player.currentTime().seconds
        NativeTrace.mark(stage, [
            "fullscreen": fullscreen == nil ? 0 : 1,
            "exiting": exitingFullscreen ? 1 : 0,
            "presented": presentedViewController === fullscreen && fullscreen != nil ? 1 : 0,
            "presenting": fullscreen?.isBeingPresented == true ? 1 : 0,
            "dismissing": fullscreen?.isBeingDismissed == true ? 1 : 0,
            "fullscreenWindow": fullscreen?.viewIfLoaded?.window == nil ? 0 : 1,
            "inlineWindow": viewIfLoaded?.window == nil ? 0 : 1,
            "parentFullscreen": fullscreen != nil && controller.parent === fullscreen ? 1 : 0,
            "parentInline": controller.parent === self ? 1 : 0,
            "rendererBound": controller.player === model.player ? 1 : 0,
            "ready": controller.isReadyForDisplay ? 1 : 0,
            "itemStatus": model.player.currentItem?.status.rawValue ?? -1,
            "playStatus": model.player.timeControlStatus.rawValue,
            "positionMs": time.isFinite ? Int(max(0, time) * 1000) : 0,
        ])
    }
    func shutdown() {
        closeSettings()
        removeFullscreenNotice()
        watchLaterUpdates = nil
        afterFullscreen = nil
        restoreScreenBrightness()
        loadingStopped = true
        loadingDelay?.cancel(); loadingDelay = nil
        loadingObservations.forEach { $0.invalidate() }; loadingObservations = []
        loadingItemObservation?.invalidate(); loadingItemObservation = nil
        loadingView.isHidden = true; loadingSpinner.stopAnimating()
        foregroundRecovery?.cancel()
        backgroundPlayback = nil
        playbackControls?.stop()
        controlsAutoHide?.cancel()
        seekFeedbackTask?.cancel()
        playbackTap.view?.removeGestureRecognizer(playbackTap)
        surfacePan.view?.removeGestureRecognizer(surfacePan)
        danmakuTap.view?.removeGestureRecognizer(danmakuTap)
        zoomPinch.view?.removeGestureRecognizer(zoomPinch)
        speedHold.view?.removeGestureRecognizer(speedHold)
        fullscreenTap.view?.removeGestureRecognizer(fullscreenTap)
        fullscreenPull.view?.removeGestureRecognizer(fullscreenPull)
        releaseOrientation()
        controller.delegate = nil
        if let fullscreen {
            fullscreen.onDismiss = nil
            fullscreen.onOrientation = nil
            fullscreen.dismiss(animated: false)
            self.fullscreen = nil
            model.isFullscreen = false
            model.stop()
        }
    }
}

/// The inline video page remains portrait. Only the player participates in the landscape transition.
@MainActor final class PlaybackOrientationDelegate: NSObject, UIApplicationDelegate {
    static weak var active: PlayerContainer?
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask
    {
        Self.active?.orientationMask ?? .allButUpsideDown
    }
}

@MainActor private final class FullscreenContainer: UIViewController {
    var onOrientation: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?
    var hasBeenLandscape = false
    var exitsOnPortrait = false
    var preferredOrientation: UIInterfaceOrientation = .portrait
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { preferredOrientation }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reportOrientation()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.reportOrientation() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onDismiss?() }
    }
    private func reportOrientation() {
        guard let orientation = PlayerContainer.orientation(view.window?.windowScene) else { return }
        onOrientation?(orientation.isLandscape)
    }
}
