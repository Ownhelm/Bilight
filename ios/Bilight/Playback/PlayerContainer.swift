import AVKit

/// Move the same AVKit controller between containers; orientation changes never replace its player or item.
@MainActor final class PlayerContainer: UIViewController, UIGestureRecognizerDelegate {
    let controller: AVPlayerViewController
    private let model: PlayerModel
    private let fullscreenButton = UIButton(type: .system)
    private var fullscreen: FullscreenContainer?
    private var orientationObserver: NSObjectProtocol?
    private var exitingFullscreen = false
    private var lifecycleInactive = false
    private var backgroundPlayback: (AVPlayerItem?, Bool, Float)?
    private var foregroundRecovery: Task<Void, Never>?
    private var deviceWasLandscape = false
    private var suppressUntilPortrait = false
    private var playbackIntent: (AVPlayerItem?, Bool, Float)?
    private var controlsAutoHide: Task<Void, Never>?
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
    private var fullscreenPullStart = CGPoint.zero
    private lazy var speedHold: UILongPressGestureRecognizer = {
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(temporarySpeedHeld(_:)))
        hold.minimumPressDuration = 0.5
        hold.allowableMovement = 12
        hold.name = "bilight-hold-double-speed"
        hold.delegate = self
        return hold
    }()
    private lazy var seekTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTapSeek(_:)))
        tap.numberOfTapsRequired = 2
        tap.name = "bilight-double-tap-seek"
        tap.delegate = self
        return tap
    }()
    private lazy var fullscreenTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(fullscreenSurfaceTapped))
        tap.name = "bilight-fullscreen-controls"
        tap.cancelsTouchesInView = false
        tap.require(toFail: seekTap)
        tap.delegate = self
        return tap
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
            self?.controlsAutoHide?.cancel()
            self?.setFullscreenButtonVisible(true, animated: true)
            self?.scheduleControlsAutoHide()
        }
        loadViewIfNeeded()
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Self.attach(controller, to: self)
        controller.view.addGestureRecognizer(seekTap)
        controller.view.addGestureRecognizer(speedHold)
        seekTap.require(toFail: speedHold)
        fullscreenTap.require(toFail: speedHold)
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
                    Task { @MainActor in self?.observeLoadingItem() }
                },
            ]
            seekFeedback.textAlignment = .center
            seekFeedback.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
            seekFeedback.textColor = .white
            seekFeedback.backgroundColor = .black.withAlphaComponent(0.65)
            seekFeedback.layer.cornerRadius = 8
            seekFeedback.clipsToBounds = true
            seekFeedback.isUserInteractionEnabled = false
            seekFeedback.isHidden = true
            seekFeedback.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(seekFeedback)
            NSLayoutConstraint.activate([seekFeedback.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), seekFeedback.centerYAnchor.constraint(equalTo: overlay.centerYAnchor), seekFeedback.heightAnchor.constraint(equalToConstant: 46)])
        }
        fullscreenButton.tintColor = .white
        fullscreenButton.backgroundColor = .black.withAlphaComponent(0.45)
        fullscreenButton.layer.cornerRadius = 9
        fullscreenButton.addTarget(self, action: #selector(toggleFullscreen), for: .touchUpInside)
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
        if !model.isFullscreen && !lifecycleInactive { releaseOrientation() }
    }
    private func deviceOrientationChanged() {
        guard PlaybackOrientationDelegate.active === self, !lifecycleInactive else { return }
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
            } else if target.hasBeenLandscape && target.exitsOnPortrait {
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
        if playbackIntent == nil { rememberPlayback() }
        exitingFullscreen = true
        controlsAutoHide?.cancel()
        refreshOrientationPolicy()
        // Presentation may not have a window yet. Its completion will honor this exit request.
        // Dismiss first: a portrait geometry request need not produce a rotation callback.
        finishExit(from: target)
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
        suppressUntilPortrait = !UIDevice.current.orientation.isPortrait
        Self.detach(controller)
        Self.attach(controller, to: self)
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
    }
    private func rememberPlayback() {
        model.endTemporarySpeed()
        playbackIntent = (model.player.currentItem, model.player.timeControlStatus != .paused, model.player.defaultRate)
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
        model.setRate(intent.2)
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
        setFullscreenButtonVisible(true, animated: false)
        fullscreenButton.removeFromSuperview()
        fullscreenButton.setImage(
            UIImage(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"),
            for: .normal)
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
    }
    @objc func fullscreenSurfaceTapped() {
        guard fullscreen != nil || playbackControls != nil, !exitingFullscreen else { return }
        controlsAutoHide?.cancel()
        let visible = fullscreenButton.alpha < 0.01 || UIAccessibility.isVoiceOverRunning
        setFullscreenButtonVisible(visible, animated: true)
        if visible { scheduleControlsAutoHide() }
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
    @objc private func doubleTapSeek(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        handleDoubleTap(at: gesture.location(in: controller.view))
    }
    @objc private func temporarySpeedHeld(_ gesture: UILongPressGestureRecognizer) { handleSpeedHold(gesture.state) }
    func handleSpeedHold(_ state: UIGestureRecognizer.State) {
        if state == .began { model.beginTemporarySpeed() }
        else if state == .ended || state == .cancelled || state == .failed { model.endTemporarySpeed() }
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
        seekFeedback.text = seconds == 0 ? "   已到视频边界   " : "   \(direction) \(seconds) 秒 · \(timeLabel(target))   "
        seekFeedback.isHidden = false
        seekFeedbackTask?.cancel()
        seekFeedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            self?.seekFeedback.isHidden = true
        }
    }
    private func scheduleControlsAutoHide() {
        controlsAutoHide?.cancel()
        guard !lifecycleInactive, fullscreen != nil || playbackControls != nil, !UIAccessibility.isVoiceOverRunning else { return }
        controlsAutoHide = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, self.fullscreen != nil || self.playbackControls != nil, !UIAccessibility.isVoiceOverRunning else { return }
            if self.playbackControls?.isInteracting == true { self.scheduleControlsAutoHide(); return }
            self.setFullscreenButtonVisible(false, animated: true)
        }
    }
    private func setFullscreenButtonVisible(_ visible: Bool, animated: Bool) {
        playbackControls?.setVisible(visible, animated: animated)
        fullscreenButton.isUserInteractionEnabled = visible
        fullscreenButton.accessibilityElementsHidden = !visible
        UIView.animate(withDuration: animated ? 0.2 : 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.fullscreenButton.alpha = visible ? 1 : 0
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let view = target {
            if view is UIControl { return false }
            target = view.superview
        }
        return true
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === fullscreenPull else { return true }
        return beginFullscreenPull(fullscreenPull.translation(in: fullscreenPull.view))
    }
    func beginFullscreenPull(_ distance: CGPoint) -> Bool {
        let accepted = isPortraitFullscreen && distance.y > 0 && distance.y > abs(distance.x) * 1.3
        fullscreenPullStart = accepted ? distance : .zero
        return accepted
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer !== seekTap && otherGestureRecognizer !== seekTap
            && gestureRecognizer !== speedHold && otherGestureRecognizer !== speedHold
            && gestureRecognizer !== fullscreenPull && otherGestureRecognizer !== fullscreenPull
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === seekTap && otherGestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer !== fullscreenTap
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
        guard !lifecycleInactive, model.error == nil else { return nil }
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
        lifecycleInactive = true
        updateLoadingIndicator()
        foregroundRecovery?.cancel()
        controlsAutoHide?.cancel()
    }
    func backgroundPlaybackActivity() {
        resignPlaybackActivity()
        guard backgroundPlayback == nil else { return }
        backgroundPlayback = playbackIntent ?? (model.player.currentItem, model.player.timeControlStatus != .paused, model.player.defaultRate)
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
        seekTap.view?.removeGestureRecognizer(seekTap)
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
