import AVKit

/// Move the same AVKit controller between containers; orientation changes never replace its player or item.
@MainActor final class PlayerContainer: UIViewController {
    let controller: AVPlayerViewController
    private let model: PlayerModel
    private let fullscreenButton = UIButton(type: .system)
    private var fullscreen: FullscreenContainer?
    private var orientationObserver: NSObjectProtocol?
    private var exitingFullscreen = false
    private var deviceWasLandscape = false
    private var suppressUntilPortrait = false
    private var playbackIntent: (AVPlayerItem?, Bool, Float)?
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
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        Self.attach(controller, to: self)
        fullscreenButton.tintColor = .white
        fullscreenButton.backgroundColor = .black.withAlphaComponent(0.45)
        fullscreenButton.layer.cornerRadius = 9
        fullscreenButton.addTarget(self, action: #selector(toggleFullscreen), for: .touchUpInside)
        placeButton(in: view, expanded: false)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
            enterFullscreen(rotate: false)
        } else {
            refreshOrientationPolicy()
            if fullscreen == nil { deviceOrientationChanged() }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !model.isFullscreen { releaseOrientation() }
    }
    private func deviceOrientationChanged() {
        guard PlaybackOrientationDelegate.active === self else { return }
        let orientation = UIDevice.current.orientation
        if orientation.isPortrait { suppressUntilPortrait = false }
        if orientation.isLandscape {
            deviceWasLandscape = true
            if fullscreen == nil, !nativeFullscreen, !suppressUntilPortrait { enterFullscreen() }
        } else if orientation.isPortrait, deviceWasLandscape, fullscreen != nil {
            exitFullscreen()
        }
    }
    @objc private func toggleFullscreen() {
        if fullscreen != nil { exitFullscreen() } else { enterFullscreen() }
    }
    func enterFullscreen(rotate: Bool = true, animated: Bool = false) {
        guard fullscreen == nil, !nativeFullscreen, view.window != nil, presentedViewController == nil,
            !isBeingDismissed
        else { return }
        let target = FullscreenContainer()
        target.modalPresentationStyle = .fullScreen
        target.modalPresentationCapturesStatusBarAppearance = true
        target.onOrientation = { [weak self, weak target] landscape in
            guard let self, let target else { return }
            if landscape {
                target.hasBeenLandscape = true
            } else if target.hasBeenLandscape {
                self.finishExit(from: target)
            }
        }
        target.onDismiss = { [weak self, weak target] in
            guard let self, let target else { return }
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
            self.restorePlayback()
            self.traceFullscreen(active: true)
            if rotate { self.requestOrientation(.landscape, from: target) }
        }
    }
    func exitFullscreen() {
        guard let target = fullscreen, !target.isBeingDismissed, !exitingFullscreen else { return }
        rememberPlayback()
        exitingFullscreen = true
        refreshOrientationPolicy()
        let scene = target.view.window?.windowScene
        if Self.orientation(scene)?.isPortrait == true {
            finishExit(from: target)
            return
        }
        target.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { [weak self, weak target] _ in
            guard let self, let target else { return }
            self.finishExit(from: target)
        }
    }
    private func finishExit(from target: FullscreenContainer) {
        guard fullscreen === target, !target.isBeingDismissed else { return }
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
        restorePlayback()
        traceFullscreen(active: false)
    }
    private func rememberPlayback() {
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
        guard let intent = playbackIntent else { return }
        playbackIntent = nil
        guard model.player.currentItem === intent.0 else { return }
        model.setRate(intent.2)
        if intent.1 { model.player.play() } else { model.player.pause() }
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
        setNeedsUpdateOfSupportedInterfaceOrientations()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
    private func placeButton(in container: UIView, expanded: Bool) {
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
    func shutdown() {
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
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
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
