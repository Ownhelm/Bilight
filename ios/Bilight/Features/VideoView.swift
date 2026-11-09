import AVKit
import SwiftUI
import Network

@MainActor final class PlaybackNetwork: ObservableObject {
    static let shared = PlaybackNetwork()
    @Published private(set) var available = true
    private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.available = available }
        }
        monitor.start(queue: DispatchQueue(label: "app.bilight.playback-network"))
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    @ObservedObject var model: PlayerModel
    var onDanmaku: ((Bool) -> Void)? = nil
    var onQuality: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeUIViewController(context: Context) -> PlayerContainer {
        let controller = AVPlayerViewController()
        controller.player = model.player
        controller.delegate = context.coordinator
        controller.showsPlaybackControls = false
        // AVKit's paused-frame Live Text layer otherwise covers our scrubber and fullscreen button.
        controller.allowsVideoFrameAnalysis = false
        controller.allowsPictureInPicturePlayback = false
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.updatesNowPlayingInfoCenter = false
        controller.speeds = [Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2].map {
            AVPlaybackSpeed(rate: $0, localizedName: $0 == 1 ? "正常" : "\($0)×")
        }
        controller.loadViewIfNeeded()
        let label = UILabel()
        label.tag = 1742
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .black.withAlphaComponent(0.55)
        label.numberOfLines = 3
        label.layer.cornerRadius = 4
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        let controls = PlaybackControls(player: model.player)
        if let overlay = controller.contentOverlayView {
            overlay.isUserInteractionEnabled = true
            let danmaku = DanmakuOverlay()
            danmaku.tag = 1744
            danmaku.isUserInteractionEnabled = false
            danmaku.clipsToBounds = true
            danmaku.translatesAutoresizingMaskIntoConstraints = false
            overlay.insertSubview(danmaku, at: 0)
            // AVKit's contentOverlayView reports zero insets; use the actual player root's safe area.
            danmaku.constrainToSafeArea(of: controller.view)
            overlay.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -55),
                label.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.9),
            ])
            let settings = UIButton(type: .system)
            settings.tag = 1743
            settings.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
            settings.tintColor = .white
            settings.backgroundColor = .black.withAlphaComponent(0.35)
            settings.layer.cornerRadius = 18
            settings.accessibilityLabel = "播放设置"
            settings.showsMenuAsPrimaryAction = true
            settings.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(settings)
            NSLayoutConstraint.activate([
                settings.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 10),
                settings.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                settings.widthAnchor.constraint(equalToConstant: 38),
                settings.heightAnchor.constraint(equalToConstant: 38),
            ])
        }
        let container = PlayerContainer(controller: controller, model: model)
        container.installPlaybackControls(controls)
        context.coordinator.container = container
        model.restorePlaybackSpeed()
        return container
    }
    @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        weak var model: PlayerModel?
        weak var container: PlayerContainer?
        init(_ model: PlayerModel) { self.model = model }
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            model?.isFullscreen = true
            container?.nativeFullscreen = true
            container?.refreshOrientationPolicy()
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                if context.isCancelled { self?.container?.nativeFullscreenEnded(cancelled: false) }
            }
        }
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                self?.container?.nativeFullscreenEnded(cancelled: context.isCancelled)
            }
        }
    }
    func updateUIViewController(_ container: PlayerContainer, context: Context) {
        let controller = container.controller
        container.updateLoadingIndicator()
        (controller.contentOverlayView?.viewWithTag(1744) as? DanmakuOverlay)?.update(player: model.player, items: model.danmakuItems, enabled: model.danmakuEnabled, revision: model.danmakuRevision, fontSize: model.danmakuFontSize, area: model.danmakuArea)
        let label = controller.contentOverlayView?.viewWithTag(1742) as? UILabel
        label?.text = model.subtitleText
        label?.isHidden = model.subtitleText.isEmpty
        if let button = controller.contentOverlayView?.viewWithTag(1743) as? UIButton {
            button.menu = settingsMenu()
        }
    }
    func settingsMenu() -> UIMenu {
        let qualities = model.qualityChoices.map { quality in
            UIAction(title: quality.label, state: model.playback?.quality == quality.id ? .on : .off) { _ in
                onQuality(quality.id)
            }
        }
        let rates = [Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2].map { rate in
            UIAction(title: rate == 1 ? "正常" : "\(rate)×", state: model.rate == rate ? .on : .off) { _ in
                model.setRate(rate)
            }
        }
        var sections = [UIMenu(title: "清晰度", children: qualities), UIMenu(title: "播放速度", children: rates)]
        if model.subtitleTracks.isEmpty {
            sections.append(UIMenu(title: "字幕", children: [UIAction(title: "暂无可用字幕", attributes: .disabled) { _ in }]))
        } else {
            let off = UIAction(title: "关闭字幕", state: model.selectedSubtitle == nil ? .on : .off) { _ in
                model.selectSubtitle(nil)
            }
            let tracks = model.subtitleTracks.map { track in
                UIAction(title: track.label, state: model.selectedSubtitle == track.id ? .on : .off) { _ in
                    model.selectSubtitle(track)
                }
            }
            sections.append(UIMenu(title: "字幕", children: [off] + tracks))
        }
        if let onDanmaku {
            let toggle = UIAction(title: "开启弹幕", state: model.danmakuEnabled ? .on : .off) { _ in
                onDanmaku(!model.danmakuEnabled)
            }
            var controls: [UIMenuElement] = [toggle]
            if model.danmakuEnabled {
                let sizes: [(String, CGFloat)] = [("小", 16), ("标准", 20), ("大", 24)]
                controls.append(UIMenu(title: "字号", children: sizes.map { label, size in
                    UIAction(title: label, state: model.danmakuFontSize == size ? .on : .off) { _ in
                        model.danmakuFontSize = size
                    }
                }))
                // Inline choices keep area selection beside the size controls, with no extra menu level.
                controls.append(UIMenu(title: "显示区域", options: [.displayInline, .singleSelection], children: DanmakuArea.allCases.map { area in
                    UIAction(title: area.title, state: model.danmakuArea == area ? .on : .off) { _ in
                        model.danmakuArea = area
                    }
                }))
            }
            sections.append(UIMenu(title: "弹幕", children: controls))
        }
        return UIMenu(children: sections)
    }
    static func dismantleUIViewController(_ controller: PlayerContainer, coordinator: Coordinator) { controller.shutdown() }
}
struct VideoView: View {
    @EnvironmentObject private var app: AppModel
    var bvid: String
    var requestedPage = 1
    var startTime = 0.0
    var localRecord: DownloadRecord? = nil
    @ObservedObject private var network = PlaybackNetwork.shared
    @State private var detail: VideoDetail?
    @State private var selected = 0
    @State private var refresh = 0
    @State private var error: String?
    @State private var metadataError: String?
    @State private var busy = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if busy {
                    LoadingBlock(label: "正在打开视频")
                } else if let error {
                    FailureBlock(error: error) { refresh += 1 }
                    if app.user == nil {
                        Button("登录 B 站后重试") { app.showLogin = true }.buttonStyle(.borderedProminent).tint(
                            Color.biliProminent
                        ).frame(maxWidth: .infinity)
                    }
                } else if let detail,
                    let part = detail.parts.first(where: { $0.page == selected }) ?? detail.parts.first
                {
                    if let warning = detail.warning {
                        Text(warning).font(.caption2).foregroundStyle(Color.biliMuted).padding(.horizontal, 16)
                    }
                    PlaybackView(detail: detail, part: part, start: part.page == requestedPage ? startTime : 0, localRecord: localRecord).id(
                        part.cid)
                    if let metadataError, network.available {
                        FailureBlock(error: metadataError) { refresh += 1 }.padding(.horizontal, 16)
                    }
                    if detail.parts.count > 1 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("分 P · \(part.page)/\(detail.parts.count)").font(.subheadline.weight(.semibold))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(detail.parts) { item in
                                        Button {
                                            selected = item.page
                                        } label: {
                                            Text("P\(item.page)  \(item.title)").font(.caption).lineLimit(1).padding(12)
                                                .frame(maxWidth: 220).foregroundStyle(
                                                    item.cid == part.cid ? Color.biliPink : Color.biliMuted
                                                ).background(
                                                    item.cid == part.cid
                                                        ? Color.biliPink.opacity(0.08) : Color.biliSoft,
                                                    in: RoundedRectangle(cornerRadius: 7))
                                        }
                                    }
                                }
                            }
                        }.padding(.horizontal, 16)
                    }
                    if !detail.description.isEmpty {
                        DisclosureGroup("视频简介") {
                            Text(detail.description).font(.footnote).foregroundStyle(Color.biliMuted).frame(
                                maxWidth: .infinity, alignment: .leading
                            ).padding(.vertical, 10)
                        }.font(.footnote).padding(.horizontal, 16)
                    }
                    CommentsView(aid: detail.video.aid, cachedPlayback: localRecord != nil).padding(.horizontal, 16)
                }
            }.padding(.bottom, 20)
        }.navigationTitle("视频").navigationBarTitleDisplayMode(.inline).task(id: "\(bvid)-\(refresh)-\(network.available)") {
            // Returning from native full screen must not refetch metadata and replace the live player view.
            if detail?.video.bvid == bvid && error == nil && (localRecord == nil || detail?.statistics != nil) { return }
            if let localRecord {
                if detail == nil {
                    detail = VideoDetail(video: localRecord.video, parts: [localRecord.part], description: "", coinLimit: nil)
                    selected = requestedPage
                }
                busy = false
                guard network.available else { return }
                metadataError = nil
                do {
                    var value = try await app.client.video(bvid, known: localRecord.video)
                    try Task.checkCancellation()
                    guard value.parts.contains(where: { $0.cid == localRecord.part.cid }) else { throw BiliFailure.invalid }
                    value.parts = [localRecord.part]
                    detail = value
                    app.register(value.video.owner)
                } catch is CancellationError {} catch {
                    if !Task.isCancelled { metadataError = "视频信息暂未更新：\(error.localizedDescription)" }
                }
                return
            }
            busy = true
            error = nil
            do {
                let value = try await app.client.video(bvid, known: app.videos[bvid])
                try Task.checkCancellation()
                detail = value
                selected = requestedPage
                app.register(value.video.owner)
            } catch is CancellationError { return } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
                app.handle(error)
            }
            if !Task.isCancelled { busy = false }
        }
    }
}
struct PlaybackView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scene
    var detail: VideoDetail
    var part: VideoPart
    var start: Double
    var localRecord: DownloadRecord? = nil
    @ObservedObject private var network = PlaybackNetwork.shared
    @StateObject private var model = PlayerModel()
    @State private var historyError: String?
    @State private var showDownload = false
    @State private var resumePosition: Double?
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                NativePlayer(model: model, onDanmaku: { model.setDanmakuEnabled($0, client: app.client, cid: part.cid) }) { quality in
                    guard localRecord == nil else { return }
                    model.selectQuality(quality, client: app.client, bvid: detail.video.bvid, part: part)
                }
            }.aspectRatio(16 / 9, contentMode: .fit)
            if let error = model.error {
                FailureBlock(error: error) {
                    if let localRecord { model.loadLocal(app.downloads.fileURL(localRecord), record: localRecord) }
                    else { model.load(
                        client: app.client, bvid: detail.video.bvid, part: part, preserve: true)
                    }
                }
            }
            if let error = model.subtitleError {
                Text("字幕：\(error)").font(.caption2).foregroundStyle(Color.biliMuted).padding(.horizontal, 16)
            }
            if let error = model.danmakuError {
                HStack {
                    Text("弹幕：\(error)")
                    Button("重试") { model.setDanmakuEnabled(true, client: app.client, cid: part.cid) }
                }.font(.caption2).foregroundStyle(Color.biliMuted).padding(.horizontal, 16)
            }
            if let historyError {
                Text("观看进度未同步：\(historyError)").font(.caption2).foregroundStyle(Color.biliPink).padding(.horizontal, 16)
            }
            HistorySyncStatus(history: app.history).padding(.horizontal, 16)
            VideoInformationSection(detail: detail, part: part, model: model) {
                if app.user == nil { app.showLogin = true } else { showDownload = true }
            }
        }.sheet(isPresented: $showDownload) {
            DownloadOptionsView(video: detail.video, part: part, playback: model.playback).environmentObject(app)
        }.task {
            let mid = app.user?.mid
            model.onWatch = { progress, completed in
                guard mid != nil, app.user?.mid == mid else { return }
                do {
                    try app.history.record(detail.video, part: part, progress: progress, completed: completed)
                    historyError = nil
                } catch { historyError = error.localizedDescription }
            }
            if model.player.currentItem == nil {
                if let localRecord {
                    model.loadLocal(app.downloads.fileURL(localRecord), record: localRecord)
                    if network.available { model.loadLocalSupport(client: app.client, bvid: detail.video.bvid, cid: part.cid) }
                } else { model.load(client: app.client, bvid: detail.video.bvid, part: part, start: resumePosition ?? start, video: detail.video) }
            }
        }.onChange(of: network.available) { _, available in
            if available && localRecord != nil { model.loadLocalSupport(client: app.client, bvid: detail.video.bvid, cid: part.cid) }
        }.onChange(of: scene) { _, phase in if phase != .active { model.flush() } }.onDisappear {
            let time = model.player.currentTime().seconds
            if time.isFinite { resumePosition = max(0, time) }
            model.flush()
            if !model.isFullscreen { model.stop() }
        }
    }
}
struct CommentsView: View {
    @EnvironmentObject private var app: AppModel
    var aid: Int = 0
    var oid: String? = nil
    var commentType = 1
    var cachedPlayback = false
    var parentLoading = false
    @ObservedObject private var network = PlaybackNetwork.shared
    @State private var expanded = true
    @State private var busy = false
    @State private var result: Page<Comment>?
    @State private var cursor: String?
    @State private var error: String?
    @State private var cursors: [String?] = [nil]
    @State private var page = 0
    @State private var refresh = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 22) {
                    if !network.available {
                        OfflineCommentsNotice(cachedPlayback: cachedPlayback) { refresh += 1 }
                    } else if busy {
                        LoadingBlock(label: "正在读取评论")
                    } else if let error {
                        FailureBlock(error: error) { refresh += 1 }
                    } else if let result {
                        if result.items.isEmpty { Text("暂时没有评论。").font(.footnote).foregroundStyle(Color.biliMuted) }
                        ForEach(result.items) { comment in
                            CommentThreadView(oid: oid ?? "\(aid)", commentType: commentType, comment: comment)
                                .id("\(app.accountGeneration):\(comment.id)")
                        }
                        PageButtons(page: page + 1, more: result.hasMore, busy: busy) { next in
                            if next > page + 1 { cursors = Array(cursors.prefix(page + 1)) + [result.cursor] }
                            page = next - 1
                            cursor = cursors[page]
                        }
                    }
                }
            } label: {
                Text("评论").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
            }
            // Comments own the shared spinner while reading; retain one if only the parent is pending.
            if parentLoading && (!expanded || !network.available || !busy) { LoadingBlock(label: "正在读取动态") }
        }.task(id: "\(expanded)-\(page)-\(refresh)-\(network.available)-\(app.accountGeneration)") {
            guard expanded && network.available else { busy = false; return }
            busy = true
            error = nil
            do {
                let value = try await app.client.comments(oid: oid ?? "\(aid)", type: commentType, cursor: cursor)
                try Task.checkCancellation()
                result = value
            } catch is CancellationError { return } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            if !Task.isCancelled { busy = false }
        }
    }
}

struct CommentThreadView: View {
    @EnvironmentObject private var app: AppModel
    var oid: String
    var commentType: Int
    var comment: Comment
    @State private var expanded = false
    @State private var replies: [Comment] = []
    @State private var total: Int?
    @State private var requestedPage = 1
    @State private var loadedPage = 0
    @State private var more = false
    @State private var busy = false
    @State private var error: String?
    @State private var retry = 0
    @State private var requestToken = UUID()
    private let blue = Color.biliReply
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommentContentRow(comment: comment)
            if comment.replyCount > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("共\(total ?? comment.replyCount)条回复").font(.caption).foregroundStyle(Color.biliMuted)
                        Button(expanded ? "收起" : "展开") { expanded.toggle() }
                            .font(.caption).foregroundStyle(blue).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                            .accessibilityIdentifier("comment-expand-\(comment.id)").accessibilityValue(expanded ? "已展开" : "已收起")
                    }.buttonStyle(.plain)
                    if expanded {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(replies) { reply in CommentContentRow(comment: reply, reply: true) }
                            if busy { Text("正在读取回复…").font(.caption).foregroundStyle(Color.biliMuted).accessibilityIdentifier("comment-replies-loading-\(comment.id)") }
                            if let error {
                                Text(error).font(.caption).foregroundStyle(Color.biliPink)
                                Button("重试") { retry += 1 }.font(.caption).foregroundStyle(blue).frame(minWidth: 44, minHeight: 44)
                            } else if !busy, loadedPage > 0, replies.isEmpty {
                                Text("暂时没有可见回复。").font(.caption).foregroundStyle(Color.biliMuted)
                            } else if !busy, more {
                                Button("加载更多") { requestedPage = loadedPage + 1 }.font(.caption).foregroundStyle(blue)
                                    .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("comment-replies-more-\(comment.id)")
                            }
                        }.padding(.leading, 12).accessibilityIdentifier("comment-replies-\(comment.id)")
                    }
                }.padding(.leading, 42)
            }
            Divider().padding(.top, 14)
        }.frame(maxWidth: .infinity, alignment: .leading).buttonStyle(.plain)
            .task(id: "\(expanded):\(requestedPage):\(retry)") {
                let token = UUID(); requestToken = token
                guard expanded, loadedPage < requestedPage else { busy = false; return }
                let generation = app.accountGeneration, page = requestedPage
                busy = true; error = nil
                defer { if requestToken == token { busy = false } }
                do {
                    let result = try await app.client.commentReplies(oid: oid, type: commentType, root: comment.id, page: page)
                    try Task.checkCancellation()
                    guard generation == app.accountGeneration, requestToken == token else { return }
                    var ids = Set(replies.map(\.id))
                    let additions = result.items.filter { ids.insert($0.id).inserted }
                    if result.hasMore && additions.isEmpty { throw BiliFailure(code: "COMMENTS_UNAVAILABLE", message: "回复分页没有新增内容，请重试。") }
                    replies += additions; total = result.total; more = result.hasMore; loadedPage = page
                } catch is CancellationError { return } catch {
                    if !Task.isCancelled && generation == app.accountGeneration && requestToken == token { self.error = error.localizedDescription }
                }
            }
    }
}

private struct CommentContentRow: View {
    @EnvironmentObject private var app: AppModel
    var comment: Comment
    var reply = false
    var body: some View {
        HStack(alignment: .top, spacing: reply ? 8 : 10) {
            Button { app.open(comment.user) } label: {
                RemoteImage(url: comment.user.avatar, avatar: true).frame(width: reply ? 24 : 32, height: reply ? 24 : 32).clipShape(Circle())
            }.accessibilityLabel("查看UP主")
            VStack(alignment: .leading, spacing: 7) {
                Text(comment.user.name).font(.caption).foregroundStyle(Color.biliMuted)
                Text(comment.text).font(.system(size: reply ? 13 : 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if comment.createdAt > 0 { Text(Date(timeIntervalSince1970: comment.createdAt), style: .date).font(.caption2).foregroundStyle(Color.biliMuted) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OfflineCommentsNotice: View {
    var cachedPlayback = false
    var retry: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash").font(.system(size: 28)).foregroundStyle(Color.biliMuted).accessibilityHidden(true)
            Text("当前处于离线状态").font(.subheadline.weight(.medium))
            Text(cachedPlayback ? "缓存视频可继续播放，联网后即可查看评论。" : "连接网络后即可查看评论。")
                .font(.footnote).foregroundStyle(Color.biliMuted).multilineTextAlignment(.center)
            Button("重新加载", action: retry).font(.footnote).frame(minHeight: 44)
        }.padding(20).frame(maxWidth: .infinity).background(Color.biliSoft, in: RoundedRectangle(cornerRadius: 12))
    }
}
