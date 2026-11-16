import AVKit

/// A public-API transport bar, without AVKit's overlapping volume/fullscreen/speed buttons.
@MainActor final class PlaybackControls: UIView {
    private let player: AVPlayer
    private let play = UIButton(type: .system)
    private let progress = PlaybackProgressSlider()
    private let time = UILabel()
    private var observer: Any?
    private var status: NSKeyValueObservation?
    private var item: NSKeyValueObservation?
    private var itemStatus: NSKeyValueObservation?
    private var itemDuration: NSKeyValueObservation?
    private var scrubItem: AVPlayerItem?
    private var sliderTouchActive = false
    private var sliderOwnsScrub = false
    private var pendingSeek: (id: UUID, item: AVPlayerItem, target: Double)?
    var onActivity: (() -> Void)?
    var onScrubPreview: ((Double?, Double, Bool) -> Void)?
    var isInteracting: Bool { scrubItem != nil || progress.isTracking }

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        play.tintColor = .white
        play.accessibilityIdentifier = "player-play-pause"
        play.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        progress.accessibilityLabel = "播放进度"
        progress.accessibilityIdentifier = "player-seek-slider"
        progress.addTarget(self, action: #selector(beginScrubbing), for: .touchDown)
        progress.addTarget(self, action: #selector(moveScrubber), for: .valueChanged)
        progress.addTarget(self, action: #selector(endScrubbing), for: [.touchUpInside, .touchUpOutside])
        progress.addTarget(self, action: #selector(cancelScrubbing), for: .touchCancel)
        time.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), maximumPointSize: 18)
        time.adjustsFontForContentSizeCategory = true
        time.textColor = .white
        Self.addGlyphShadow(to: time)
        time.adjustsFontSizeToFitWidth = true
        time.minimumScaleFactor = 0.65
        time.isAccessibilityElement = false
        for control in [progress, play, time] {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
        }
        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            progress.topAnchor.constraint(equalTo: topAnchor),
            progress.heightAnchor.constraint(equalToConstant: 44),
            play.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            play.bottomAnchor.constraint(equalTo: bottomAnchor),
            play.widthAnchor.constraint(equalToConstant: 44),
            play.heightAnchor.constraint(equalToConstant: 44),
            time.leadingAnchor.constraint(equalTo: play.trailingAnchor, constant: 3),
            time.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -100),
            time.centerYAnchor.constraint(equalTo: play.centerYAnchor),
        ])
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        status = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        item = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.bindItem() }
        }
        bindItem()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        // Empty space in the control bar is still part of the player gesture surface.
        var ancestor = target
        while let view = ancestor, view !== self {
            if view is UIControl { return target }
            ancestor = view.superview
        }
        return nil
    }
    static func addGlyphShadow(to view: UIView?) {
        guard let view else { return }
        view.clipsToBounds = false
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.95
        view.layer.shadowRadius = 1.5
        view.layer.shadowOffset = CGSize(width: 0, height: 0.5)
    }
    private func bindItem() {
        itemStatus?.invalidate(); itemDuration?.invalidate()
        pendingSeek = nil
        cancelScrub()
        if let current = player.currentItem {
            itemStatus = current.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
            itemDuration = current.observe(\.duration, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }
    var duration: Double {
        let value = player.currentItem?.duration.seconds ?? 0
        return value.isFinite && value > 0 ? value : 0
    }
    func refresh() {
        let paused = player.timeControlStatus == .paused
        play.setImage(UIImage(systemName: paused ? "play.fill" : "pause.fill"), for: .normal)
        Self.addGlyphShadow(to: play.imageView)
        play.accessibilityLabel = paused ? "播放" : "暂停"
        play.isEnabled = player.currentItem != nil && player.currentItem?.status != .failed
        progress.isEnabled = duration > 0
        guard scrubItem == nil else { return }
        // AVPlayer may still report the old time until an asynchronous seek completes.
        displayProgress(currentPosition)
    }
    private var currentPosition: Double {
        pendingSeek.flatMap { $0.item === player.currentItem ? $0.target : nil }
            ?? player.currentTime().seconds
    }
    private func displayProgress(_ value: Double) {
        let position = value.isFinite ? min(duration, max(0, value)) : 0
        progress.maximumValue = Float(max(1, duration))
        progress.value = Float(position)
        time.text = "\(timeLabel(position)) / \(timeLabel(duration))"
        progress.accessibilityValue = time.text
    }
    @objc func togglePlayback() {
        guard play.isEnabled else { return }
        if player.timeControlStatus == .paused {
            if duration > 0, currentPosition >= duration - 0.1 { player.seek(to: .zero) }
            player.play()
        } else { player.pause() }
        refresh()
        onActivity?()
    }
    @discardableResult func beginScrub() -> Double? {
        guard scrubItem == nil, let item = player.currentItem, duration > 0, currentPosition.isFinite else { return nil }
        scrubItem = item
        onActivity?()
        previewScrub(at: currentPosition)
        return currentPosition
    }
    func previewScrub(at target: Double, cancelOnRelease: Bool = false) {
        guard let scrubItem, scrubItem === player.currentItem else { return }
        displayProgress(target)
        onScrubPreview?(min(duration, max(0, target)), duration, cancelOnRelease)
    }
    func finishScrub(at target: Double) {
        guard let scrubItem, scrubItem === player.currentItem else { cancelScrub(); return }
        self.scrubItem = nil
        seek(to: target)
        onScrubPreview?(nil, duration, false)
        onActivity?()
    }
    func cancelScrub() {
        guard scrubItem != nil else { return }
        scrubItem = nil
        sliderOwnsScrub = false
        refresh()
        onScrubPreview?(nil, duration, false)
        onActivity?()
    }
    @objc private func beginScrubbing() {
        sliderTouchActive = true
        sliderOwnsScrub = beginScrub() != nil
    }
    @objc private func moveScrubber() {
        let target = Double(progress.value)
        // VoiceOver/keyboard changes have no touch-down/up sequence.
        if sliderOwnsScrub { previewScrub(at: target) }
        else if !sliderTouchActive && scrubItem == nil { seek(to: target); onActivity?() }
    }
    @objc private func endScrubbing() {
        sliderTouchActive = false
        guard sliderOwnsScrub else { return }
        sliderOwnsScrub = false
        finishScrub(at: Double(progress.value))
    }
    @objc private func cancelScrubbing() {
        sliderTouchActive = false
        if sliderOwnsScrub { cancelScrub() }
    }
    private func seek(to value: Double) {
        guard duration > 0, let current = player.currentItem else { pendingSeek = nil; refresh(); return }
        let target = min(duration, max(0, value))
        let id = UUID()
        pendingSeek = (id, current, target)
        displayProgress(target)
        // AVPlayer preserves play/pause intent; no extra play or rate assignment is needed.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                // A newer seek, item replacement or shutdown invalidates this completion.
                guard let self, self.pendingSeek?.id == id else { return }
                self.pendingSeek = nil
                self.refresh()
            }
        }
    }
    func setVisible(_ visible: Bool, animated: Bool) {
        isUserInteractionEnabled = visible
        accessibilityElementsHidden = !visible
        UIView.animate(withDuration: animated ? 0.2 : 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = visible ? 1 : 0
        }
    }
    func stop() {
        pendingSeek = nil
        scrubItem = nil
        sliderTouchActive = false
        sliderOwnsScrub = false
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        status?.invalidate(); status = nil
        item?.invalidate(); item = nil
        itemStatus?.invalidate(); itemStatus = nil
        itemDuration?.invalidate(); itemDuration = nil
        onActivity = nil
        onScrubPreview = nil
    }
}

private final class PlaybackProgressSlider: UISlider {
    private static let thumb = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
        let bounds = context.format.bounds
        UIColor.black.withAlphaComponent(0.72).setFill()
        UIBezierPath(ovalIn: bounds).fill()
        UIColor.white.setFill()
        UIBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumTrackTintColor = UIColor(red: 0.84, green: 0.24, blue: 0.43, alpha: 1)
        maximumTrackTintColor = .black.withAlphaComponent(0.44)
        setThumbImage(Self.thumb, for: .normal)
        setThumbImage(Self.thumb, for: .highlighted)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let rect = super.trackRect(forBounds: bounds)
        return CGRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
    }
}
