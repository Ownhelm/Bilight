import AVFoundation
import Combine
import MediaPlayer

/// Device preferences contain no account or viewing-history data.
final class PlaybackPreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var danmakuEnabled: Bool {
        get { defaults.bool(forKey: "bilight.playback.danmaku") }
        set { defaults.set(newValue, forKey: "bilight.playback.danmaku") }
    }
    var danmakuArea: DanmakuArea {
        get { DanmakuArea(rawValue: defaults.double(forKey: "bilight.playback.danmakuArea")) ?? .full }
        set { defaults.set(newValue.rawValue, forKey: "bilight.playback.danmakuArea") }
    }
    var quality: Int {
        get {
            let value = defaults.integer(forKey: "bilight.playback.quality")
            return (1...127).contains(value) ? value : 127
        }
        set { if (1...127).contains(newValue) { defaults.set(newValue, forKey: "bilight.playback.quality") } }
    }
}

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
    @Published var danmakuEnabled = false
    @Published var danmakuFontSize: CGFloat = 20
    @Published var danmakuArea: DanmakuArea = .full {
        didSet { preferences.danmakuArea = danmakuArea }
    }
    @Published var danmakuItems: [Danmaku] = []
    @Published var danmakuRevision = UUID()
    @Published var danmakuError: String?
    private var danmakuRequest: Task<Void, Never>?
    private let preferences: PlaybackPreferences
    private let bufferingTimeout: Duration
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
    private var failure: NSObjectProtocol?
    private var bufferingWatch: Task<Void, Never>?
    private var retryIntent: Bool?
    private var temporaryRate: Float?
    private static weak var nowPlayingOwner: PlayerModel?
    private var nowPlaying: [String: Any]?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var artworkRequest: Task<Void, Never>?
    private var artworkRevision = UUID()
    private var rateStatus: NSKeyValueObservation?
    private var cues: [SubtitleCue] = []
    private var version = UUID()
    private var previous = 0.0, progress = 0.0, watched = false, dirty = false, lastSaved = Date.distantPast
    var onWatch: ((Double, Bool) -> Void)?
    var isFullscreen = false
    init(preferences: PlaybackPreferences = PlaybackPreferences(), bufferingTimeout: Duration = .seconds(30)) {
        self.preferences = preferences
        self.bufferingTimeout = bufferingTimeout
        danmakuEnabled = preferences.danmakuEnabled
        danmakuArea = preferences.danmakuArea
        player.actionAtItemEnd = .pause
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in Task { @MainActor in self?.tick(time.seconds) } }
        playStatus = player.observe(\.timeControlStatus) { [weak self] player, _ in
            if player.timeControlStatus != .paused {
                let time = player.currentTime().seconds
                NativeTrace.mark(player.timeControlStatus == .playing ? .playbackRunning : .playbackWaiting,
                    ["positionMs": time.isFinite ? Int(max(0, time) * 1000) : 0])
            }
            Task { @MainActor in
                self?.updateBufferingWatch()
                self?.publishNowPlaying()
                if player.timeControlStatus == .paused { self?.flush() }
            }
        }
        rateStatus = player.observe(\.rate) { [weak self] _, _ in
            Task { @MainActor in self?.publishNowPlaying() }
        }
        defaultRateStatus = player.observe(\.defaultRate) { [weak self] player, _ in
            Task { @MainActor in
                if self?.temporaryRate == nil, self?.rate != player.defaultRate { self?.rate = player.defaultRate }
            }
        }
        jump = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                self.previous = self.player.currentTime().seconds
                self.publishNowPlaying()
            }
        }
        failure = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor in
                guard let self, let item, !self.busy else { return }
                self.failPlayback(item, message: "视频播放中断：\(error?.localizedDescription ?? "媒体流无法继续读取，请重试。")")
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
        client: BiliClient, bvid: String, part: VideoPart, start: Double = 0, quality: Int? = nil, preserve: Bool = false,
        video: Video? = nil
    ) {
        endTemporarySpeed()
        if !preserve {
            clearDanmaku()
            updateDanmaku(preferences.danmakuEnabled, client: client, cid: part.cid)
        }
        let quality = quality ?? preferences.quality
        request?.cancel()
        bufferingWatch?.cancel(); bufferingWatch = nil
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
                let playing = !preserve || (retryIntent ?? (player.timeControlStatus != .paused))
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
                            model.failPlayback(item, message: "视频暂时无法播放，请重新获取地址或切换清晰度。")
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
                if let video { setNowPlaying(video, part: part) }
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
                    try await activateAudioSession()
                    try Task.checkCancellation()
                    guard version == token else { throw CancellationError() }
                    player.defaultRate = rate
                    player.play()
                }
                busy = false
                retryIntent = nil
                updateBufferingWatch()
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
    func selectQuality(_ quality: Int, client: BiliClient, bvid: String, part: VideoPart) {
        guard qualityChoices.contains(where: { $0.id == quality }) else { return }
        preferences.quality = quality
        if !busy && playback?.quality == quality { return }
        load(client: client, bvid: bvid, part: part, quality: quality, preserve: true)
    }
    @discardableResult func seek(_ delta: Double) -> Double? {
        let current = player.currentTime().seconds
        guard current.isFinite, let duration = playback?.duration else { return nil }
        previous = min(duration, max(0, current + delta))
        player.seek(
            to: CMTime(seconds: previous, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        return previous
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
        setNowPlaying(record.video, part: record.part)
        itemStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .readyToPlay { NativeTrace.mark(.offlineReady, ["quality": record.quality]) }
            if item.status == .failed { Task { @MainActor in self?.error = "本地视频暂时无法播放，请重新下载。" } }
        }
        player.defaultRate = rate
        let token = version
        busy = true
        request = Task {
            defer { if version == token { busy = false } }
            do {
                try await activateAudioSession()
                try Task.checkCancellation()
                guard version == token, player.currentItem === item else { return }
                player.play()
            } catch is CancellationError {} catch {
                if version == token { self.error = error.localizedDescription }
            }
        }
    }
    private func activateAudioSession() async throws {
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        }.value
    }
    func setNowPlaying(_ video: Video, part: VideoPart) {
        let identifier = "\(video.bvid):\(part.cid)"
        if nowPlaying?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String == identifier {
            publishNowPlaying()
            return
        }
        artworkRequest?.cancel()
        let token = UUID(); artworkRevision = token
        nowPlaying = [MPMediaItemPropertyTitle: video.title, MPMediaItemPropertyArtist: video.owner.name,
            MPMediaItemPropertyAlbumTitle: "P\(part.page) · \(part.title)",
            MPNowPlayingInfoPropertyExternalContentIdentifier: identifier,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPMediaItemPropertyPlaybackDuration: part.duration, MPNowPlayingInfoPropertyIsLiveStream: false]
        publishNowPlaying()
        if let cover = video.cover {
            artworkRequest = Task { [weak self] in
                guard let image = try? await ImageRepository.shared.image(cover), !Task.isCancelled,
                    let self, self.artworkRevision == token else { return }
                self.nowPlaying?[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.publishNowPlaying()
            }
        }
    }
    private func publishNowPlaying() {
        guard var info = nowPlaying, let item = player.currentItem else { return }
        if Self.nowPlayingOwner !== self {
            Self.nowPlayingOwner?.clearNowPlaying()
            Self.nowPlayingOwner = self
            installRemoteCommands()
        }
        let position = player.currentTime().seconds
        let duration = item.duration.seconds
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position.isFinite ? max(0, position) : 0
        if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(player.timeControlStatus == .playing ? player.rate : 0)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(rate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    enum RemotePlaybackAction { case play, pause, toggle, seek(Double), skip(Double) }
    @discardableResult func handleRemotePlayback(_ action: RemotePlaybackAction) -> MPRemoteCommandHandlerStatus {
        guard Self.nowPlayingOwner === self, let item = player.currentItem else { return .noSuchContent }
        switch action {
        case .pause:
            endTemporarySpeed(); player.pause(); flush()
        case .toggle:
            return handleRemotePlayback(player.timeControlStatus == .paused ? .play : .pause)
        case .play:
            guard error == nil, !busy else { return .commandFailed }
            endTemporarySpeed()
            if item.duration.seconds.isFinite, player.currentTime().seconds >= item.duration.seconds - 0.1 {
                previous = 0; player.seek(to: .zero)
            }
            player.defaultRate = rate; player.play()
        case .seek(let position):
            let duration = item.duration.seconds.isFinite ? item.duration.seconds : (playback?.duration ?? 0)
            guard position.isFinite, duration > 0 else { return .commandFailed }
            previous = min(duration, max(0, position))
            player.seek(to: CMTime(seconds: previous, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        case .skip(let delta):
            return handleRemotePlayback(.seek(player.currentTime().seconds + delta))
        }
        publishNowPlaying()
        return .success
    }
    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping (MPRemoteCommandEvent) -> RemotePlaybackAction?) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                let perform = { @MainActor in
                    guard let self, let action = action(event) else { return MPRemoteCommandHandlerStatus.commandFailed }
                    return self.handleRemotePlayback(action)
                }
                if Thread.isMainThread { return MainActor.assumeIsolated { perform() } }
                return DispatchQueue.main.sync { MainActor.assumeIsolated { perform() } }
            }
            remoteTargets.append((command, target))
        }
        bind(center.playCommand) { _ in .play }; bind(center.pauseCommand) { _ in .pause }
        bind(center.togglePlayPauseCommand) { _ in .toggle }
        bind(center.changePlaybackPositionCommand) { ($0 as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) } }
        center.skipBackwardCommand.preferredIntervals = [10]; center.skipForwardCommand.preferredIntervals = [10]
        bind(center.skipBackwardCommand) { _ in .skip(-10) }; bind(center.skipForwardCommand) { _ in .skip(10) }
        center.nextTrackCommand.isEnabled = false; center.previousTrackCommand.isEnabled = false
    }
    private func clearNowPlaying() {
        artworkRequest?.cancel(); artworkRevision = UUID(); nowPlaying = nil
        for (command, target) in remoteTargets { command.removeTarget(target) }
        if Self.nowPlayingOwner === self {
            for (command, _) in remoteTargets { command.isEnabled = false }
            Self.nowPlayingOwner = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        remoteTargets = []
    }
    func setRate(_ value: Float) {
        if temporaryRate != nil { temporaryRate = value; rate = value; publishNowPlaying(); return }
        if rate != value { rate = value }
        if player.defaultRate != value { player.defaultRate = value }
        if player.rate > 0, player.rate != value { player.rate = value }
        publishNowPlaying()
    }
    func beginTemporarySpeed() {
        guard temporaryRate == nil, player.currentItem != nil, player.timeControlStatus != .paused else { return }
        temporaryRate = rate
        player.defaultRate = 2
        if player.rate > 0 { player.rate = 2 }
    }
    func endTemporarySpeed() {
        guard let value = temporaryRate else { return }
        temporaryRate = nil
        setRate(value)
    }
    private func updateBufferingWatch() {
        bufferingWatch?.cancel(); bufferingWatch = nil
        guard error == nil, player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            let item = player.currentItem else { return }
        let token = version, timeout = bufferingTimeout
        let start = player.currentTime().seconds
        bufferingWatch = Task { [weak self, weak item] in
            var position = start
            while !Task.isCancelled {
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, let item, self.version == token, self.player.currentItem === item,
                    self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate, self.error == nil else { return }
                let current = self.player.currentTime().seconds
                if self.busy || (current.isFinite && (!position.isFinite || abs(current - position) > 0.05)) {
                    position = current
                    continue
                }
                self.failPlayback(item, message: "视频缓冲超时，请重试或切换清晰度。")
                return
            }
        }
    }
    private func failPlayback(_ item: AVPlayerItem, message: String) {
        guard player.currentItem === item, error == nil else { return }
        retryIntent = player.timeControlStatus != .paused
        error = message
        busy = false
        bufferingWatch?.cancel(); bufferingWatch = nil
        player.pause()
        flush()
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
        clearNowPlaying()
        endTemporarySpeed()
        clearDanmaku()
        flush()
        request?.cancel()
        subtitleRequest?.cancel()
        bufferingWatch?.cancel(); bufferingWatch = nil
        retryIntent = nil
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
    private func clearDanmaku() {
        danmakuRequest?.cancel(); danmakuRequest = nil
        danmakuEnabled = false; danmakuItems = []; danmakuError = nil; danmakuRevision = UUID()
    }
    func setDanmakuEnabled(_ enabled: Bool, client: BiliClient, cid: Int) {
        preferences.danmakuEnabled = enabled
        updateDanmaku(enabled, client: client, cid: cid)
    }
    private func updateDanmaku(_ enabled: Bool, client: BiliClient, cid: Int) {
        danmakuRequest?.cancel(); danmakuRequest = nil
        danmakuEnabled = enabled; danmakuError = nil
        guard enabled else { danmakuItems = []; danmakuRevision = UUID(); return }
        danmakuRequest = Task {
            do {
                let data = try await client.http.danmakuData(cid)
                let items = try await Task.detached(priority: .utility) { try Danmaku.parse(data) }.value
                try Task.checkCancellation()
                if danmakuEnabled { danmakuItems = items; danmakuRevision = UUID() }
            } catch is CancellationError {} catch {
                if !Task.isCancelled { danmakuError = error.localizedDescription }
            }
        }
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
        artworkRequest?.cancel()
        let targets = remoteTargets
        Task { @MainActor in
            for (command, target) in targets { command.removeTarget(target) }
            if Self.nowPlayingOwner == nil { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        }
        if let observer { player.removeTimeObserver(observer) }
        if let end { NotificationCenter.default.removeObserver(end) }
        if let jump { NotificationCenter.default.removeObserver(jump) }
        if let failure { NotificationCenter.default.removeObserver(failure) }
        bufferingWatch?.cancel()
        request?.cancel()
        subtitleRequest?.cancel()
        danmakuRequest?.cancel()
    }
}
