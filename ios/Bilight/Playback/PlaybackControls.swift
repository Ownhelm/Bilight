import AVKit

/// A public-API transport bar, without AVKit's overlapping volume/fullscreen/speed buttons.
@MainActor final class PlaybackControls: UIView {
    private let player: AVPlayer
    private let play = UIButton(type: .system)
    private let progress = UISlider()
    private let elapsed = UILabel()
    private let remaining = UILabel()
    private var observer: Any?
    private var status: NSKeyValueObservation?
    private var item: NSKeyValueObservation?
    private var itemStatus: NSKeyValueObservation?
    private var itemDuration: NSKeyValueObservation?
    private var scrubbing = false
    var onActivity: (() -> Void)?
    var isInteracting: Bool { scrubbing || progress.isTracking }

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black.withAlphaComponent(0.35)
        layer.cornerRadius = 12
        play.tintColor = .white
        play.accessibilityIdentifier = "player-play-pause"
        play.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        progress.tintColor = .white
        progress.maximumTrackTintColor = .white.withAlphaComponent(0.3)
        progress.accessibilityLabel = "播放进度"
        progress.accessibilityIdentifier = "player-seek-slider"
        progress.addTarget(self, action: #selector(beginScrubbing), for: .touchDown)
        progress.addTarget(self, action: #selector(moveScrubber), for: .valueChanged)
        progress.addTarget(self, action: #selector(endScrubbing), for: [.touchUpInside, .touchUpOutside])
        progress.addTarget(self, action: #selector(cancelScrubbing), for: .touchCancel)
        for label in [elapsed, remaining] {
            label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
                for: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), maximumPointSize: 18)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .white
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let row = UIStackView(arrangedSubviews: [play, elapsed, progress, remaining])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            play.widthAnchor.constraint(equalToConstant: 44), play.heightAnchor.constraint(equalToConstant: 44),
            progress.heightAnchor.constraint(equalToConstant: 44),
        ])
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        status = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        item = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.bindItem() }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func bindItem() {
        itemStatus?.invalidate(); itemDuration?.invalidate()
        scrubbing = false
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
    private var duration: Double {
        let value = player.currentItem?.duration.seconds ?? 0
        return value.isFinite && value > 0 ? value : 0
    }
    func refresh() {
        let paused = player.timeControlStatus == .paused
        play.setImage(UIImage(systemName: paused ? "play.fill" : "pause.fill"), for: .normal)
        play.accessibilityLabel = paused ? "播放" : "暂停"
        play.isEnabled = player.currentItem != nil && player.currentItem?.status != .failed
        progress.isEnabled = duration > 0
        guard !scrubbing else { return }
        let value = player.currentTime().seconds
        let position = value.isFinite ? min(duration, max(0, value)) : 0
        progress.maximumValue = Float(max(1, duration))
        progress.value = Float(position)
        elapsed.text = timeLabel(position)
        remaining.text = timeLabel(duration)
        progress.accessibilityValue = "\(timeLabel(position)) / \(timeLabel(duration))"
    }
    @objc private func togglePlayback() {
        if player.timeControlStatus == .paused {
            if duration > 0, player.currentTime().seconds >= duration - 0.1 { player.seek(to: .zero) }
            player.play()
        } else { player.pause() }
        refresh()
        onActivity?()
    }
    @objc private func beginScrubbing() { scrubbing = true; onActivity?() }
    @objc private func moveScrubber() {
        elapsed.text = timeLabel(Double(progress.value))
        // VoiceOver/keyboard changes have no touch-down/up sequence.
        if !scrubbing { seek(); onActivity?() }
    }
    @objc private func endScrubbing() { scrubbing = false; seek(); onActivity?() }
    @objc private func cancelScrubbing() { scrubbing = false; refresh(); onActivity?() }
    private func seek() {
        guard duration > 0 else { return }
        let target = min(duration, max(0, Double(progress.value)))
        // AVPlayer preserves play/pause intent; no extra play or rate assignment is needed.
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func setVisible(_ visible: Bool, animated: Bool) {
        isUserInteractionEnabled = visible
        accessibilityElementsHidden = !visible
        UIView.animate(withDuration: animated ? 0.2 : 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = visible ? 1 : 0
        }
    }
    func stop() {
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        status?.invalidate(); status = nil
        item?.invalidate(); item = nil
        itemStatus?.invalidate(); itemStatus = nil
        itemDuration?.invalidate(); itemDuration = nil
        onActivity = nil
    }
}
