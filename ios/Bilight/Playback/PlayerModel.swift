import AVFoundation
import Combine

@MainActor final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var playback: Playback?
    @Published var qualityChoices: [Quality] = []
    @Published var busy = false
    @Published var error: String?
    @Published var subtitleError: String?
    @Published var subtitleTracks: [SubtitleTrack] = []
    @Published var selectedSubtitle: Int?
    @Published var subtitleText = ""
    @Published var rate: Float = 1
    private var loaders: [MediaLoader] = []
    private var sourceAssets: [AVURLAsset] = []
    private var stream: SegmentedStream?
    private var request: Task<Void, Never>?
    private var subtitleRequest: Task<Void, Never>?
    private var preferredSubtitle: Int?
    private var itemStatus: NSKeyValueObservation?
    private var playStatus: NSKeyValueObservation?
    private var defaultRateStatus: NSKeyValueObservation?
    private var observer: Any?
    private var end: NSObjectProtocol?
    private var jump: NSObjectProtocol?
    private var cues: [SubtitleCue] = []
    private var version = UUID()
    private var previous = 0.0, progress = 0.0, watched = false, dirty = false, lastSaved = Date.distantPast
    var onWatch: ((Double, Bool) -> Void)?
    var isFullscreen = false
    init() {
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in Task { @MainActor in self?.tick(time.seconds) } }
        playStatus = player.observe(\.timeControlStatus) { [weak self] player, _ in
            if player.timeControlStatus == .paused { Task { @MainActor in self?.flush() } }
        }
        defaultRateStatus = player.observe(\.defaultRate) { [weak self] player, _ in
            Task { @MainActor in
                if self?.rate != player.defaultRate { self?.rate = player.defaultRate }
            }
        }
        jump = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                self.previous = self.player.currentTime().seconds
            }
        }
        end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main)
        { [weak self] notification in
            Task { @MainActor in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem, self.watched else {
                    return
                }
                self.player.pause()
                self.onWatch?(self.playback?.duration ?? self.progress, true)
                self.dirty = false
            }
        }
    }
    func load(
        client: BiliClient, bvid: String, part: VideoPart, start: Double = 0, quality: Int = 127, preserve: Bool = false
    ) {
        request?.cancel()
        let token = UUID()
        version = token
        busy = true
        error = nil
        request = Task {
            let began = Date()
            NativeTrace.mark(.prepareStart)
            var nextLoaders: [MediaLoader] = []
            var nextAssets: [AVURLAsset] = []
            var nextStream: SegmentedStream?
            do {
                let next = try await client.playback(bvid, cid: part.cid, quality: quality)
                NativeTrace.mark(.playURLReady, ["ms": Int(Date().timeIntervalSince(began) * 1000), "quality": next.quality])
                try Task.checkCancellation()
                qualityChoices = next.qualities
                let asset: AVAsset
                if let direct = next.mp4 {
                    let loader = MediaLoader(direct)
                    nextLoaders.append(loader)
                    let direct = loader.asset()
                    nextAssets.append(direct)
                    asset = direct
                } else if let video = next.video, video.index != nil, video.initialization != nil,
                    next.audio == nil || (next.audio?.index != nil && next.audio?.initialization != nil)
                {
                    let segmented = try await SegmentedStream.make(next)
                    nextStream = segmented
                    let source = AVURLAsset(url: segmented.url)
                    nextAssets.append(source)
                    asset = source
                } else if let video = next.video {
                    let videoLoader = MediaLoader(video.url)
                    nextLoaders.append(videoLoader)
                    let videoAsset = videoLoader.asset()
                    nextAssets.append(videoAsset)
                    let audioAsset: AVURLAsset?
                    if let audio = next.audio {
                        let audioLoader = MediaLoader(audio.url)
                        nextLoaders.append(audioLoader)
                        let source = audioLoader.asset()
                        nextAssets.append(source)
                        audioAsset = source
                    } else { audioAsset = nil }
                    async let videoRead = videoAsset.loadTracks(withMediaType: .video)
                    async let audioRead = audioAsset?.loadTracks(withMediaType: .audio)
                    let composition = AVMutableComposition()
                    let videoTracks = try await videoRead
                    NativeTrace.mark(.videoTrackReady, ["ms": Int(Date().timeIntervalSince(began) * 1000)])
                    guard let source = videoTracks.first,
                        let target = composition.addMutableTrack(
                            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    else { throw BiliFailure.invalid }
                    let duration = CMTime(seconds: next.duration, preferredTimescale: 600)
                    try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
                    let transform = try await source.load(.preferredTransform)
                    if !transform.isIdentity { target.preferredTransform = transform }
                    if let audioTracks = try await audioRead {
                        NativeTrace.mark(.audioTrackReady, ["ms": Int(Date().timeIntervalSince(began) * 1000)])
                        guard let source = audioTracks.first,
                            let target = composition.addMutableTrack(
                                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        else { throw BiliFailure.invalid }
                        try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
                    }
                    asset = composition
                } else {
                    throw BiliFailure.invalid
                }
                try Task.checkCancellation()
                guard version == token else { throw CancellationError() }
                let playing = preserve && player.rate > 0
                let position = preserve ? player.currentTime().seconds : start
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 0
                itemStatus = item.observe(\.status, options: [.new]) { [weak model = self] item, _ in
                    if item.status == .readyToPlay {
                        NativeTrace.mark(.playerReady, ["ms": Int(Date().timeIntervalSince(began) * 1000), "quality": next.quality])
                    }
                    if item.status == .failed {
                        NativeTrace.mark(.playerFailure, ["code": (item.error as NSError?)?.code ?? 0])
                        Task { @MainActor [weak model] in
                            guard let model, model.version == token, model.player.currentItem === item else { return }
                            model.error = "视频暂时无法播放，请重新获取地址或切换清晰度。"
                        }
                    }
                }
                flush()
                player.pause()
                player.replaceCurrentItem(with: item)
                let previousLoaders = loaders
                loaders = nextLoaders
                sourceAssets = nextAssets
                let previousStream = stream
                stream = nextStream
                previousStream?.stop()
                previousLoaders.forEach { $0.invalidate() }
                playback = next
                let time = max(0, min(position.isFinite ? position : 0, next.duration))
                previous = time
                progress = time
                if !preserve {
                    watched = false
                    dirty = false
                    lastSaved = .distantPast
                }
                if time > 0 {
                    await player.seek(
                        to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero,
                        toleranceAfter: .zero)
                }
                try Task.checkCancellation()
                guard version == token else { throw CancellationError() }
                // Let AVFoundation preroll both DASH tracks before resuming; forcing immediate playback can show undecoded frames.
                if playing {
                    player.defaultRate = rate
                    player.play()
                }
                busy = false
            } catch is CancellationError {
                if stream !== nextStream { nextStream?.stop() }
                nextLoaders.forEach { $0.invalidate() }
                if version == token { busy = false }
            } catch {
                NativeTrace.mark(.prepareFailure, ["code": Int((error as? BiliFailure)?.code ?? "") ?? (error as NSError).code])
                if stream !== nextStream { nextStream?.stop() }
                nextLoaders.forEach { $0.invalidate() }
                if version == token {
                    self.error = error.localizedDescription
                    busy = false
                }
            }
        }
        if !preserve { loadSubtitles(client: client, bvid: bvid, cid: part.cid) }
    }
    func seek(_ delta: Double) {
        let current = player.currentTime().seconds
        guard current.isFinite, let duration = playback?.duration else { return }
        previous = min(duration, max(0, current + delta))
        player.seek(
            to: CMTime(seconds: previous, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func loadLocal(_ url: URL, record: DownloadRecord) {
        stop()
        error = nil
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            error = "本地视频文件不存在，请重新下载。"
            return
        }
        let item = AVPlayerItem(url: url)
        playback = Playback(quality: record.quality, qualities: [Quality(id: record.quality, label: record.qualityLabel)], duration: record.part.duration, mp4: url)
        qualityChoices = playback?.qualities ?? []
        player.replaceCurrentItem(with: item)
        itemStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .readyToPlay { NativeTrace.mark(.offlineReady, ["quality": record.quality]) }
            if item.status == .failed { Task { @MainActor in self?.error = "本地视频暂时无法播放，请重新下载。" } }
        }
    }
    func setRate(_ value: Float) {
        rate = value
        player.defaultRate = value
        if player.rate > 0 { player.rate = value }
    }
    private func tick(_ current: Double) {
        guard current.isFinite else { return }
        let advance = current - previous
        previous = current
        let text =
            selectedSubtitle == nil ? "" : cues.first(where: { current >= $0.from && current < $0.to })?.text ?? ""
        if text != subtitleText { subtitleText = text }
        guard !busy, player.timeControlStatus == .playing, advance > 0, advance < 5 * Double(max(1, rate)) else {
            return
        }
        watched = true
        dirty = true
        progress = current
        if Date().timeIntervalSince(lastSaved) >= 15 { flush() }
    }
    func flush() {
        guard watched, dirty else { return }
        onWatch?(progress, false)
        dirty = false
        lastSaved = Date()
    }
    func stop() {
        flush()
        request?.cancel()
        subtitleRequest?.cancel()
        version = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
        loaders.forEach { $0.invalidate() }
        loaders = []
        sourceAssets = []
        stream?.stop()
        stream = nil
        itemStatus = nil
        playback = nil
        qualityChoices = []
        busy = false
    }
    private func loadSubtitles(client: BiliClient, bvid: String, cid: Int) {
        subtitleRequest?.cancel()
        subtitleTracks = []
        selectedSubtitle = nil
        preferredSubtitle = nil
        cues = []
        subtitleText = ""
        subtitleError = nil
        subtitleRequest = Task {
            do {
                let tracks = try await client.subtitles(bvid, cid: cid)
                try Task.checkCancellation()
                subtitleTracks = tracks
                if let track = tracks.first(where: { $0.language.contains("zh") }) ?? tracks.first {
                    selectSubtitle(track)
                }
                NativeTrace.mark(.subtitleReady, ["tracks": tracks.count, "enabled": selectedSubtitle == nil ? 0 : 1])
            } catch is CancellationError {} catch { subtitleError = error.localizedDescription }
        }
    }
    func selectSubtitle(_ track: SubtitleTrack?) {
        subtitleRequest?.cancel()
        selectedSubtitle = track?.id
        cues = []
        subtitleText = ""
        subtitleError = nil
        guard let track else { return }
        preferredSubtitle = track.id
        subtitleRequest = Task {
            do {
                guard MediaLoader.allowed(track.url) else { throw BiliFailure.invalid }
                let config = URLSessionConfiguration.ephemeral
                config.httpShouldSetCookies = false
                config.httpCookieStorage = nil
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                var input = URLRequest(url: track.url)
                input.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
                let (data, response) = try await session.data(for: input)
                try Task.checkCancellation()
                guard data.count <= 4_000_000, (response as? HTTPURLResponse)?.statusCode == 200,
                    let json = try JSONSerialization.jsonObject(with: data) as? JSON, json["body"] is [Any]
                else { throw BiliFailure.invalid }
                cues = list(json["body"]).filter { num($0["to"]) > num($0["from"]) }.map {
                    SubtitleCue(from: num($0["from"]), to: num($0["to"]), text: clean($0["content"]))
                }
                subtitleError = nil
            } catch is CancellationError {} catch { subtitleError = error.localizedDescription }
        }
    }
    func setSubtitlesEnabled(_ enabled: Bool) {
        guard enabled else { selectSubtitle(nil); return }
        let track = subtitleTracks.first { $0.id == preferredSubtitle }
            ?? subtitleTracks.first { $0.language.contains("zh") } ?? subtitleTracks.first
        selectSubtitle(track)
    }
    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let end { NotificationCenter.default.removeObserver(end) }
        if let jump { NotificationCenter.default.removeObserver(jump) }
        request?.cancel()
        subtitleRequest?.cancel()
    }
}
