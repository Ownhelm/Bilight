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

struct PlaybackWatchLater {
    let video: Video
    let store: WatchLaterStore
    var onLogin: (() -> Void)?
}

struct NativePlayer: UIViewControllerRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: PlayerModel
    var onDanmaku: ((Bool) -> Void)? = nil
    var watchLater: PlaybackWatchLater? = nil
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
        controller.speeds = PlaybackSettingsPanel.rates.map {
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
        var captionBottom: NSLayoutConstraint?
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
            let bottom = label.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -96)
            captionBottom = bottom
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                bottom,
                label.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.9),
            ])
        }
        let container = PlayerContainer(controller: controller, model: model)
        container.captionBottom = captionBottom
        configureControls(container)
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
        configureControls(container)
        container.updateLoadingIndicator()
        (controller.contentOverlayView?.viewWithTag(1744) as? DanmakuOverlay)?.update(
            player: model.player, items: model.danmakuItems, enabled: model.danmakuEnabled,
            revision: model.danmakuRevision, fontSize: model.danmakuFontSize, area: model.danmakuArea,
            opacity: model.danmakuOpacity)
        let label = controller.contentOverlayView?.viewWithTag(1742) as? UILabel
        label?.text = model.subtitleText
        label?.isHidden = model.subtitleText.isEmpty
    }
    @MainActor private func configureControls(_ container: PlayerContainer) {
        container.configureWatchLater(watchLater)
        container.settingsInterfaceStyle = colorScheme == .dark ? .dark : .light
        container.onToggleDanmaku = onDanmaku.map { toggle in { [weak model] in
            if let model { toggle(!model.danmakuEnabled) }
        } }
        container.settingsContent = { [weak model] close in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(PlaybackSettingsPanel(model: model, onQuality: onQuality, onDanmaku: onDanmaku,
                onClose: close))
        }
    }
    static func dismantleUIViewController(_ controller: PlayerContainer, coordinator: Coordinator) { controller.shutdown() }
}
struct VideoView: View {
    @EnvironmentObject private var app: AppModel
    var bvid: String
    var requestedPage = 1
    var startTime = 0.0
    var requestedCID: Int? = nil
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
                    let shouldResume = requestedCID.map { $0 == part.cid } ?? (part.page == requestedPage)
                    PlaybackView(detail: detail, part: part, start: shouldResume ? startTime : 0, localRecord: localRecord).id(part.cid)
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
                        VideoDescriptionSection(description: detail.description).padding(.horizontal, 16)
                    }
                    CommentsView(oid: "\(detail.video.aid)", cachedPlayback: localRecord != nil,
                        channel: .video(aid: detail.video.aid, bvid: detail.video.bvid), remembersExpansion: true)
                        .id("\(detail.video.bvid):\(app.accountGeneration)").padding(.horizontal, 16)
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
                selected = requestedCID.flatMap { cid in value.parts.first { $0.cid == cid }?.page } ?? requestedPage
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

private let videoSectionTitleFont: Font = .system(size: 15, weight: .semibold)

struct VideoDescriptionSection: View {
    let description: String
    @AppStorage("bilight.videoDescriptionExpanded") private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(description).font(.footnote).foregroundStyle(Color.biliMuted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
        } label: {
            Text("视频简介").font(videoSectionTitleFont).foregroundStyle(.primary)
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
                NativePlayer(model: model, onDanmaku: { model.setDanmakuEnabled($0, client: app.client, cid: part.cid) },
                    watchLater: localRecord == nil && detail.video.aid > 0
                        ? PlaybackWatchLater(video: detail.video, store: app.watchLater,
                            onLogin: app.user == nil ? { app.showLogin = true } : nil)
                        : nil) { quality in
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
    var oid: String
    var commentType = 1
    var cachedPlayback = false
    var parentLoading = false
    var channel: CommentChannel? = nil
    var remembersExpansion = false
    @ObservedObject private var network = PlaybackNetwork.shared
    @AppStorage("bilight.videoCommentsExpanded") private var videoCommentsExpanded = true
    @State private var expanded = true
    @State private var busy = false
    @State private var result: Page<Comment>?
    @State private var cursor: String?
    @State private var error: String?
    @State private var cursors: [String?] = [nil]
    @State private var page = 0
    @State private var refresh = 0
    @State private var composer: ComposerTarget?
    @State private var posted: [Comment] = []
    @State private var postedReplies: [String: [Comment]] = [:]
    @State private var publicationNotice: String?
    private struct ComposerTarget: Identifiable {
        let id = UUID()
        var channel: CommentChannel
        var reply: CommentReplyTarget?
        var participants: [User]
    }
    private var expansion: Binding<Bool> { remembersExpansion ? $videoCommentsExpanded : $expanded }
    private var writableChannel: CommentChannel? {
        #if DEBUG
            if DemoFixtures.enabled { return nil }
        #endif
        guard let channel, channel.valid, channel.oid == oid, channel.type == commentType, network.available else { return nil }
        return channel
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DisclosureGroup(isExpanded: expansion) {
                VStack(alignment: .leading, spacing: 22) {
                    if !network.available {
                        OfflineCommentsNotice(cachedPlayback: cachedPlayback) { refresh += 1 }
                    } else {
                        if writableChannel != nil { composeButton }
                        if let publicationNotice { Text(publicationNotice).font(.footnote).foregroundStyle(Color.biliMuted) }
                        let currentPage = busy || error != nil ? nil : result
                        let recent = page == 0 ? posted : []
                        let ids = Set(recent.map(\.id))
                        let comments = recent + (currentPage?.items.filter { !ids.contains($0.id) } ?? [])
                        if busy {
                            LoadingBlock(label: "正在读取评论")
                        } else if let error {
                            FailureBlock(error: error) { refresh += 1 }
                        } else if currentPage != nil && comments.isEmpty {
                            Text("暂时没有评论。").font(.footnote).foregroundStyle(Color.biliMuted)
                        }
                        ForEach(comments) { comment in
                            CommentThreadView(oid: oid, commentType: commentType, comment: comment,
                                channel: writableChannel, postedReplies: postedReplies[comment.id] ?? [],
                                onReply: { root, row, participants in
                                    openComposer(CommentReplyTarget(root: root, parent: row.id, user: row.user),
                                        participants: participants)
                                })
                                .id("\(app.accountGeneration):\(comment.id)")
                        }
                        if let currentPage {
                            PageButtons(page: page + 1, more: currentPage.hasMore, busy: busy) { next in
                                if next > page + 1 { cursors = Array(cursors.prefix(page + 1)) + [currentPage.cursor] }
                                page = next - 1
                                cursor = cursors[page]
                            }
                        }
                    }
                }
            } label: {
                Text("评论").font(videoSectionTitleFont).foregroundStyle(.primary)
            }
            // Comments own the shared spinner while reading; retain one if only the parent is pending.
            if parentLoading && (!expansion.wrappedValue || !network.available || !busy) { LoadingBlock(label: "正在读取动态") }
        }.task(id: "\(expansion.wrappedValue)-\(page)-\(refresh)-\(network.available)-\(app.accountGeneration)") {
            guard expansion.wrappedValue && network.available else { busy = false; return }
            let generation = app.accountGeneration, likeVersion = app.commentLikes.revision
            busy = true
            error = nil
            do {
                let value = try await app.client.comments(oid: oid, type: commentType, cursor: cursor)
                try Task.checkCancellation()
                guard generation == app.accountGeneration else { return }
                app.recordCommentLikes(value.items, oid: oid, type: commentType, readVersion: likeVersion)
                result = value
            } catch is CancellationError { return } catch {
                if Task.isCancelled || generation != app.accountGeneration { return }
                self.error = error.localizedDescription
            }
            if !Task.isCancelled { busy = false }
        }.sheet(item: $composer) { target in
            VideoCommentComposer(channel: target.channel, target: target.reply,
                participants: target.participants) { comment, notice in
                publicationNotice = notice
                if let reply = target.reply {
                    if postedReplies[reply.root]?.contains(where: { $0.id == comment.id }) != true {
                        postedReplies[reply.root, default: []].append(comment)
                    }
                } else {
                    posted.removeAll { $0.id == comment.id }
                    posted.insert(comment, at: 0)
                    page = 0; cursor = nil; cursors = [nil]
                }
            }.presentationDetents([.height(256)])
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
                .presentationCompactAdaptation(.sheet)
        }.onChange(of: channel) {
            if let composer, composer.channel != channel { self.composer = nil }
        }.onChange(of: app.accountGeneration) {
            composer = nil
            posted = []
            postedReplies = [:]
            publicationNotice = nil
            result = nil
            cursor = nil; cursors = [nil]; page = 0
        }
    }
    private var composeButton: some View {
        Button { openComposer(nil) } label: {
            HStack(spacing: 10) {
                RemoteImage(url: app.user?.avatar, avatar: true).frame(width: 32, height: 32).clipShape(Circle())
                Text("发一条友善的评论").font(.subheadline).foregroundStyle(Color.biliMuted)
                    .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Color.biliSoft, in: Capsule())
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("video-comment-compose")
    }
    private func openComposer(_ target: CommentReplyTarget?, participants: [User] = []) {
        guard let channel = writableChannel else { return }
        guard app.user != nil else { app.showLogin = true; return }
        publicationNotice = nil
        let replyUser = target.map { [$0.user] } ?? []
        let commentUsers = (posted + (result?.items ?? [])).map(\.user)
        composer = ComposerTarget(channel: channel, reply: target, participants: replyUser + participants + commentUsers)
    }
}

struct CommentThreadView: View {
    @EnvironmentObject private var app: AppModel
    var oid: String
    var commentType: Int
    var comment: Comment
    var channel: CommentChannel? = nil
    var postedReplies: [Comment] = []
    var onReply: ((String, Comment, [User]) -> Void)? = nil
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
    private var visibleReplies: [Comment] {
        let ids = Set(replies.map(\.id))
        return replies + postedReplies.filter { !ids.contains($0.id) }
    }
    private var participants: [User] { [comment.user] + visibleReplies.map(\.user) }
    private var replyCount: Int {
        guard !postedReplies.isEmpty else { return total ?? comment.replyCount }
        return max(total ?? 0, comment.replyCount + postedReplies.count)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommentContentRow(comment: comment, channel: channel,
                onReply: { onReply?(comment.id, comment, participants) })
            if comment.replyCount > 0 || !postedReplies.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("共\(replyCount)条回复").font(.caption).foregroundStyle(Color.biliMuted)
                        Button(expanded ? "收起" : "展开") { expanded.toggle() }
                            .font(.caption).foregroundStyle(blue).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                            .accessibilityIdentifier("comment-expand-\(comment.id)").accessibilityValue(expanded ? "已展开" : "已收起")
                    }.buttonStyle(.plain)
                    if expanded {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(visibleReplies) { reply in
                                CommentContentRow(comment: reply, reply: true, channel: channel,
                                    onReply: { onReply?(comment.id, reply, participants) })
                            }
                            if busy { Text("正在读取回复…").font(.caption).foregroundStyle(Color.biliMuted).accessibilityIdentifier("comment-replies-loading-\(comment.id)") }
                            if let error {
                                Text(error).font(.caption).foregroundStyle(Color.biliPink)
                                Button("重试") { retry += 1 }.font(.caption).foregroundStyle(blue).frame(minWidth: 44, minHeight: 44)
                            } else if !busy, loadedPage > 0, visibleReplies.isEmpty {
                                Text("暂时没有可见回复。").font(.caption).foregroundStyle(Color.biliMuted)
                            } else if !busy, more {
                                Button("加载更多") { requestedPage = loadedPage + 1 }.font(.caption).foregroundStyle(blue)
                                    .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("comment-replies-more-\(comment.id)")
                            }
                        }.padding(.leading, 12).accessibilityElement(children: .contain)
                            .accessibilityIdentifier("comment-replies-\(comment.id)")
                    }
                }.padding(.leading, 42)
            }
            Divider().padding(.top, 14)
        }.frame(maxWidth: .infinity, alignment: .leading).buttonStyle(.plain)
            .onChange(of: postedReplies.count) { previous, count in
                if count > previous { total = (total ?? comment.replyCount + previous) + count - previous; expanded = true }
            }
            .task(id: "\(expanded):\(requestedPage):\(retry)") {
                let token = UUID(); requestToken = token
                guard expanded, loadedPage < requestedPage else { busy = false; return }
                let generation = app.accountGeneration, page = requestedPage, likeVersion = app.commentLikes.revision
                busy = true; error = nil
                defer { if requestToken == token { busy = false } }
                do {
                    let result = try await app.client.commentReplies(oid: oid, type: commentType, root: comment.id, page: page)
                    try Task.checkCancellation()
                    guard generation == app.accountGeneration, requestToken == token else { return }
                    var ids = Set(replies.map(\.id))
                    let additions = result.items.filter { ids.insert($0.id).inserted }
                    if result.hasMore && additions.isEmpty { throw BiliFailure(code: "COMMENTS_UNAVAILABLE", message: "回复分页没有新增内容，请重试。") }
                    app.recordCommentLikes(result.items, oid: oid, type: commentType, readVersion: likeVersion)
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
    var channel: CommentChannel? = nil
    var onReply: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: reply ? 8 : 10) {
            Button { app.open(comment.user) } label: {
                RemoteImage(url: comment.user.avatar, avatar: true).frame(width: reply ? 24 : 32, height: reply ? 24 : 32).clipShape(Circle())
            }.accessibilityLabel("查看UP主")
            VStack(alignment: .leading, spacing: 7) {
                Text(comment.user.name).font(.caption).foregroundStyle(Color.biliMuted)
                CommentMessage(comment: comment, fontSize: reply ? 13 : 14)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        commentDate
                        commentActions
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        commentDate
                        commentActions
                    }
                }.font(.caption).foregroundStyle(Color.biliMuted)
                if let channel, let likeError = app.commentLikes.errors[likeKey(channel)] {
                    Text(likeError).font(.caption2).foregroundStyle(Color.biliPink)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var commentDate: some View {
        if comment.createdAt > 0 { Text(Date(timeIntervalSince1970: comment.createdAt), style: .date) }
    }
    @ViewBuilder private var commentActions: some View {
        if let channel, DynamicPost.validID(comment.id) {
            HStack(spacing: 4) {
                likeButton(channel: channel)
                Button("回复") { onReply?() }
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    .accessibilityIdentifier("video-comment-reply-\(comment.id)")
            }
        }
    }
    private func likeButton(channel: CommentChannel) -> some View {
        let state = app.commentLikes.state(likeKey(channel), fallback: LikeState(liked: comment.liked, likes: comment.likes))
        return Button { app.toggleCommentLike(comment, channel: channel) } label: {
            HStack(spacing: 4) {
                Image(systemName: state.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                Text(state.likes > 0 ? "\(state.likes)" : "赞")
            }.foregroundStyle(state.liked ? Color.biliPink : Color.biliMuted)
                .padding(.trailing, 14)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.accessibilityLabel(state.liked ? "取消点赞评论" : "点赞评论")
            .accessibilityValue("\(state.likes)")
            .accessibilityIdentifier("video-comment-like-\(comment.id)")
    }
    private func likeKey(_ channel: CommentChannel) -> CommentLikeKey {
        CommentLikeKey(oid: channel.oid, type: channel.type, id: comment.id)
    }
}

private struct CommentMessage: View {
    @EnvironmentObject private var app: AppModel
    var comment: Comment
    var fontSize: CGFloat
    @State private var images: [URL: UIImage] = [:]

    var body: some View {
        let parts = comment.textParts
        let urls = Set(parts.compactMap { part -> URL? in
            if case .emote(_, let url) = part { return url }
            return nil
        })
        parts.reduce(Text("")) { output, part in
            Text("\(output)\(render(part))")
        }
        .font(.system(size: fontSize)).lineSpacing(4).fixedSize(horizontal: false, vertical: true).tint(Color.biliReply)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "https", url.host == "space.bilibili.com",
                let mid = Int(url.path.dropFirst()), mid > 0, comment.mentions.values.contains(mid)
            else { return .discarded }
            app.navigate(.creator(mid))
            return .handled
        })
        .task(id: urls) {
            var loaded: [URL: UIImage] = [:]
            for url in urls {
                guard !Task.isCancelled else { return }
                guard let image = try? await ImageRepository.shared.image(url), let pixels = image.cgImage else { continue }
                let scale = CGFloat(max(pixels.width, pixels.height)) / (fontSize + 2)
                loaded[url] = UIImage(cgImage: pixels, scale: scale, orientation: image.imageOrientation)
            }
            if !Task.isCancelled { images = loaded }
        }
    }

    private func render(_ part: CommentTextPart) -> Text {
        switch part {
        case .text(let value): return Text(verbatim: value)
        case .mention(let value, let mid):
            var mention = AttributedString(value)
            mention.link = URL(string: "https://space.bilibili.com/\(mid)")
            return Text(mention)
        case .emote(let token, let url):
            if let image = images[url] {
                return Text(Image(uiImage: image).renderingMode(.original)).baselineOffset(-1)
            }
            return Text(verbatim: token)
        }
    }
}

struct CommentMentionQuery: Equatable {
    let range: NSRange
    let keyword: String
    init?(text: String, selection: NSRange) {
        guard selection.length == 0, let caret = Range(selection, in: text)?.lowerBound else { return nil }
        let prefix = text[..<caret]
        guard let at = prefix.lastIndex(where: { $0 == "@" || $0 == "＠" }) else { return nil }
        let query = prefix[prefix.index(after: at)...]
        guard query.count <= 30, !query.contains(where: \.isWhitespace) else { return nil }
        if at > prefix.startIndex {
            let previous = prefix[prefix.index(before: at)]
            if previous.isASCII && (previous.isLetter || previous.isNumber || previous == "_") { return nil }
        }
        range = NSRange(at..<caret, in: text)
        keyword = String(query)
    }
}

struct VideoCommentComposer: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var network = PlaybackNetwork.shared
    var channel: CommentChannel
    var target: CommentReplyTarget?
    var participants: [User]
    var onPost: (Comment, String?) -> Void
    @State private var draft = ""
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorFocused = true
    @State private var editorComposing = false
    @State private var mentions: [String: Int] = [:]
    @State private var suggestions: [User] = []
    @State private var suggestionError: String?
    @State private var suggestionKeyword: String?
    @State private var error: String?
    @State private var busy = false
    @State private var publishTask: Task<Void, Never>?
    private var query: CommentMentionQuery? {
        editorFocused && !editorComposing && !busy ? CommentMentionQuery(text: draft, selection: selection) : nil
    }
    private var valid: Bool {
        network.available && !busy && !editorComposing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.utf16.count <= Comment.maximumMessageLength
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        RemoteImage(url: app.user?.avatar, avatar: true).frame(width: 36, height: 36).clipShape(Circle())
                            .accessibilityHidden(true)
                        ZStack(alignment: .topLeading) {
                            if draft.isEmpty && !editorComposing {
                                Text("发一条友善的评论").foregroundStyle(Color.biliPlaceholder)
                                    .padding(.leading, 13).padding(.top, 9).allowsHitTesting(false).accessibilityHidden(true)
                            }
                            CommentDraftEditor(text: $draft, selection: $selection, focused: $editorFocused,
                                composing: $editorComposing, editable: !busy)
                        }.frame(minHeight: 96, maxHeight: 126)
                            .background(Color.biliSoft, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if draft.utf16.count > Comment.maximumMessageLength {
                        Text("评论最多 \(Comment.maximumMessageLength) 个字符。").font(.caption).foregroundStyle(Color.biliPink)
                    }
                    if let query, suggestionKeyword == query.keyword {
                        if let suggestionError { Text(suggestionError).font(.caption).foregroundStyle(Color.biliPink) }
                        ForEach(suggestions) { user in
                            Button { selectMention(user) } label: {
                                HStack(spacing: 10) {
                                    RemoteImage(url: user.avatar, avatar: true).frame(width: 28, height: 28).clipShape(Circle())
                                    Text(user.name).font(.subheadline).foregroundStyle(.primary)
                                    Spacer()
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("video-comment-mention-\(user.mid)")
                        }
                    }
                    if !network.available { Text("连接网络后可发布评论。").font(.footnote).foregroundStyle(Color.biliMuted) }
                    if let error { Text(error).font(.footnote).foregroundStyle(Color.biliPink).accessibilityIdentifier("video-comment-error") }
                }.padding(16)
            }.scrollDismissesKeyboard(.never).accessibilityIdentifier("video-comment-composer-scroll")
                .navigationTitle(target.map { "回复 \($0.user.name)" } ?? "发表评论").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(busy ? "发布中…" : "发布") { publish() }.buttonStyle(.borderedProminent)
                            .tint(Color.biliPink).accessibilityIdentifier("video-comment-send")
                    }
                }
        }.interactiveDismissDisabled(busy)
            .task(id: query?.keyword) { await searchMentions(query?.keyword) }
            .onDisappear { publishTask?.cancel() }
    }
    private func selectMention(_ user: User) {
        guard let query, suggestionKeyword == query.keyword else { return }
        mentions[user.name] = user.mid
        var range = query.range
        if let end = Range(range, in: draft)?.upperBound, end < draft.endIndex, draft[end] == " " { range.length += 1 }
        replace(range, with: "@\(user.name) ")
    }
    private func replace(_ range: NSRange, with text: String) {
        guard let resolved = Range(range, in: draft) else { return }
        draft.replaceSubrange(resolved, with: text)
        selection = NSRange(location: range.location + text.utf16.count, length: 0)
        editorFocused = true
    }
    private func searchMentions(_ keyword: String?) async {
        guard !Task.isCancelled else { return }
        suggestionKeyword = keyword
        guard let keyword else { suggestions = []; suggestionError = nil; return }
        let generation = app.accountGeneration
        var seen = Set<Int>()
        let local = participants.filter {
            $0.mid > 0 && !$0.name.isEmpty && (keyword.isEmpty || $0.name.localizedCaseInsensitiveContains(keyword))
                && seen.insert($0.mid).inserted
        }
        suggestions = Array(local.prefix(8)); suggestionError = nil
        guard network.available else { return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let users = try await app.client.commentMentionUsers(keyword)
            guard !Task.isCancelled, generation == app.accountGeneration, query?.keyword == keyword else { return }
            let replyUser = keyword.isEmpty ? local.filter { $0.mid == target?.user.mid } : []
            var seen = Set<Int>()
            suggestions = Array((replyUser + users + local).filter { seen.insert($0.mid).inserted }.prefix(8))
        } catch {
            guard !Task.isCancelled, generation == app.accountGeneration, query?.keyword == keyword else { return }
            suggestionError = error.localizedDescription
        }
    }
    private func publish() {
        guard valid, let author = app.user else { return }
        let generation = app.accountGeneration
        let message = draft, selected = mentions
        busy = true; error = nil
        publishTask = Task {
            defer { if generation == app.accountGeneration && !Task.isCancelled { busy = false } }
            do {
                guard generation == app.accountGeneration, !Task.isCancelled else { return }
                let publication = try await app.client.postComment(channel: channel, authorMid: author.mid,
                    message: message, mentions: selected, target: target)
                guard generation == app.accountGeneration, !Task.isCancelled else { return }
                onPost(publication.comment, publication.notice)
                dismiss()
            } catch {
                guard generation == app.accountGeneration, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                app.handle(error)
            }
        }
    }
}

private struct CommentDraftEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var focused: Bool
    @Binding var composing: Bool
    var editable: Bool
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.accessibilityLabel = "评论内容"
        view.accessibilityIdentifier = "video-comment-input"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.isEditable = editable
        if view.markedTextRange == nil {
            coordinator.updating = true
            if view.text != text { view.text = text }
            if view.selectedRange != selection, Range(selection, in: text) != nil { view.selectedRange = selection }
            coordinator.updating = false
        }
        if focused && editable && !view.isFirstResponder {
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, let coordinator, view.window != nil, coordinator.parent.focused, coordinator.parent.editable else { return }
                view.becomeFirstResponder()
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CommentDraftEditor
        var updating = false
        init(_ parent: CommentDraftEditor) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) {
            update(textView)
            parent.focused = false
        }
        func textViewDidChange(_ textView: UITextView) { update(textView) }
        func textViewDidChangeSelection(_ textView: UITextView) { update(textView) }
        private func update(_ textView: UITextView) {
            guard !updating else { return }
            let composing = textView.markedTextRange != nil
            if parent.composing != composing { parent.composing = composing }
            guard !composing else { return }
            if parent.text != textView.text { parent.text = textView.text }
            if parent.selection != textView.selectedRange { parent.selection = textView.selectedRange }
        }
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
