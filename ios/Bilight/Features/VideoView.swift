import AVKit
import SwiftUI

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
            controls.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(controls)
            NSLayoutConstraint.activate([
                controls.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 8),
                controls.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -64),
                controls.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -10),
                controls.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
        let container = PlayerContainer(controller: controller, model: model)
        container.installPlaybackControls(controls)
        context.coordinator.container = container
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
    @State private var detail: VideoDetail?
    @State private var selected = 0
    @State private var refresh = 0
    @State private var error: String?
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
                            Color.biliPink
                        ).frame(maxWidth: .infinity)
                    }
                } else if let detail,
                    let part = detail.parts.first(where: { $0.page == selected }) ?? detail.parts.first
                {
                    if let warning = detail.warning {
                        Text(warning).font(.caption2).foregroundStyle(Color.biliMuted).padding(.horizontal, 16)
                    }
                    PlaybackView(detail: detail, part: part, start: part.page == requestedPage ? startTime : 0).id(
                        part.cid)
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
                    CommentsView(aid: detail.video.aid).padding(.horizontal, 16)
                }
            }.padding(.bottom, 20)
        }.navigationTitle("视频").navigationBarTitleDisplayMode(.inline).task(id: "\(bvid)-\(refresh)") {
            // Returning from native full screen must not refetch metadata and replace the live player view.
            if detail?.video.bvid == bvid && error == nil { return }
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
    @StateObject private var model = PlayerModel()
    @State private var historyError: String?
    @State private var showDownload = false
    @State private var resumePosition: Double?
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                NativePlayer(model: model, onDanmaku: { model.setDanmakuEnabled($0, client: app.client, cid: part.cid) }) { quality in
                    model.selectQuality(quality, client: app.client, bvid: detail.video.bvid, part: part)
                }
            }.aspectRatio(16 / 9, contentMode: .fit)
            if let error = model.error {
                FailureBlock(error: error) {
                    model.load(
                        client: app.client, bvid: detail.video.bvid, part: part, preserve: true)
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
                model.load(client: app.client, bvid: detail.video.bvid, part: part, start: resumePosition ?? start)
            }
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
    @State private var expanded = true
    @State private var busy = false
    @State private var result: Page<Comment>?
    @State private var cursor: String?
    @State private var error: String?
    @State private var cursors: [String?] = [nil]
    @State private var page = 0
    @State private var refresh = 0
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 22) {
                if busy {
                    LoadingBlock(label: "正在读取评论")
                } else if let error {
                    FailureBlock(error: error) { refresh += 1 }
                } else if let result {
                    if result.items.isEmpty { Text("暂时没有评论。").font(.footnote).foregroundStyle(Color.biliMuted) }
                    ForEach(result.items) { comment in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                app.open(comment.user)
                            } label: {
                                RemoteImage(url: comment.user.avatar, avatar: true).frame(width: 29, height: 29)
                                    .clipShape(Circle())
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                Text(comment.user.name).font(.caption).foregroundStyle(Color.biliMuted)
                                Text(comment.text).font(.system(size: 13)).lineSpacing(4)
                                Text(Date(timeIntervalSince1970: comment.createdAt), style: .date).font(.caption2)
                                    .foregroundStyle(Color.biliMuted)
                            }
                        }
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
        }.task(id: "\(expanded)-\(page)-\(refresh)") {
            guard expanded else { return }
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
