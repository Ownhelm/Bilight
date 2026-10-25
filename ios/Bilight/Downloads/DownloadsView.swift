import AVKit
import SwiftUI

struct DownloadOptionsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var video: Video
    var part: VideoPart
    var playback: Playback?
    @State private var quality = 127
    @State private var options: [Quality] = []
    @State private var busy = false
    @State private var enqueueing = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(video.title).font(.headline)
                    Text("P\(part.page) · \(part.title)").font(.footnote).foregroundStyle(Color.biliMuted)
                }
                Section {
                    if busy {
                        ProgressView("正在读取可用画质")
                    } else {
                        Picker("清晰度", selection: $quality) { ForEach(options) { Text($0.label).tag($0.id) } }
                    }
                } header: {
                    Text("下载当前分 P")
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.biliPink) } }
            }.navigationTitle("下载视频").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("取消下载")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: beginDownload) { Image(systemName: "arrow.down.circle.fill").font(.title3) }
                            .disabled(busy || enqueueing || options.isEmpty).accessibilityLabel("开始下载")
                    }
                }
                .task {
                    busy = true
                    do {
                        let value: Playback
                        if let playback {
                            value = playback
                        } else {
                            value = try await app.client.playback(video.bvid, cid: part.cid)
                        }
                        try Task.checkCancellation()
                        options = value.qualities
                        quality = value.quality
                    } catch is CancellationError { return } catch { self.error = error.localizedDescription }
                    busy = false
                }
        }.tint(Color.biliPink)
    }
    private func beginDownload() {
        guard !enqueueing, !busy, !options.isEmpty else { return }
        enqueueing = true
        do {
            guard app.user?.mid == app.downloads.mid, app.user != nil else {
                enqueueing = false
                app.showLogin = true
                return
            }
            try app.downloads.enqueue(video: video, part: part, quality: quality,
                label: options.first(where: { $0.id == quality })?.label ?? "最高可用")
            dismiss()
            app.navigate(.downloads)
        } catch { enqueueing = false; self.error = error.localizedDescription }
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var store: DownloadStore
    @State private var tab = 0
    @State private var deleting: DownloadRecord?
    @State private var confirmDelete = false
    private var visible: [DownloadRecord] {
        store.items.filter { tab == 0 ? $0.state != .completed : $0.state == .completed }
    }
    var body: some View {
        VStack(spacing: 0) {
            ContentTabs(titles: ["下载中", "已下载"], selection: $tab).padding(.horizontal, 18)
            List {
                if let error = store.error { Text(error).font(.footnote).foregroundStyle(Color.biliPink) }
                if visible.isEmpty {
                    EmptyBlock(
                        symbol: "arrow.down.circle", title: tab == 0 ? "没有正在下载的视频" : "还没有下载的视频",
                        message: "在视频播放页点下载，选择画质后保存当前分 P。"
                    )
                    .listRowSeparator(.hidden)
                }
                ForEach(visible) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            if item.state == .completed { app.navigate(.offline(item.id)) }
                        } label: {
                            HStack(spacing: 12) {
                                RemoteImage(url: item.video.cover).frame(width: 105, height: 65).clipShape(
                                    RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.video.title).font(.system(size: 14, weight: .medium)).foregroundStyle(
                                        .primary
                                    ).lineLimit(2).multilineTextAlignment(.leading)
                                    Text("P\(item.part.page) · \(item.qualityLabel)").font(.caption).foregroundStyle(
                                        Color.biliMuted)
                                }
                            }
                        }.buttonStyle(.plain).disabled(item.state != .completed)
                        if item.state == .downloading {
                            ProgressView(value: item.progress).tint(Color.biliPink)
                        }
                        HStack {
                            if [.resolving, .merging].contains(item.state) { ProgressView().scaleEffect(0.7) }
                            Text(item.state.title).font(.caption).foregroundStyle(Color.biliMuted)
                            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(
                                .caption2
                            ).foregroundStyle(Color.biliMuted)
                            Spacer()
                            if [.queued, .resolving, .downloading, .merging].contains(item.state) {
                                Button("暂停") { store.pause(item.id) }.font(.caption)
                            } else if [.paused, .failed].contains(item.state) {
                                Button("继续") { store.resume(item.id) }.font(.caption)
                                if item.state == .failed {
                                    Button("重新下载") { store.resume(item.id, restart: true) }.font(.caption)
                                }
                            } else if item.state == .completed {
                                ShareLink(item: store.fileURL(item)) { Image(systemName: "square.and.arrow.up") }
                                    .accessibilityLabel("导出视频")
                            }
                        }
                        if let message = item.message { Text(message).font(.caption2).foregroundStyle(Color.biliMuted) }
                    }.padding(.vertical, 10).swipeActions {
                        Button("删除", role: .destructive) {
                            deleting = item
                            confirmDelete = true
                        }
                    }.contextMenu {
                        if item.state == .completed { ShareLink("导出视频", item: store.fileURL(item)) }
                        Button("删除下载", role: .destructive) {
                            deleting = item
                            confirmDelete = true
                        }
                    }
                }
            }.listStyle(.plain)
        }.navigationTitle("我的下载").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("删除这个分 P 的本地下载和任务？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除下载", role: .destructive) {
                    if let item = deleting { store.remove(item.id) }
                    deleting = nil
                }
            }
    }
}

struct OfflineVideoView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var store: DownloadStore
    var id: UUID
    @StateObject private var model = PlayerModel()
    private var record: DownloadRecord? { store.items.first { $0.id == id && $0.state == .completed } }
    var body: some View {
        ScrollView {
            if let record {
                VStack(alignment: .leading, spacing: 18) {
                    NativePlayer(model: model) { _ in }.aspectRatio(16 / 9, contentMode: .fit).background(.black)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(record.video.title).font(.title3.bold())
                        Text("P\(record.part.page) · \(record.qualityLabel) · 离线观看").font(.caption).foregroundStyle(
                            Color.biliMuted)
                        HStack(spacing: 30) {
                            Button {
                                model.seek(-5)
                            } label: {
                                Image(systemName: "gobackward.5")
                            }.accessibilityLabel("后退5秒")
                            Button {
                                model.seek(5)
                            } label: {
                                Image(systemName: "goforward.5")
                            }.accessibilityLabel("前进5秒")
                            ShareLink("导出 MP4", item: store.fileURL(record))
                        }.padding(.vertical, 10)
                        if let error = model.error { Text(error).font(.footnote).foregroundStyle(Color.biliPink) }
                        HistorySyncStatus(history: app.history)
                    }.padding(.horizontal, 18)
                }.task {
                    if model.player.currentItem == nil {
                        model.loadLocal(store.fileURL(record), record: record)
                        let mid = app.user?.mid
                        model.onWatch = { progress, completed in
                            guard mid != nil, app.user?.mid == mid else { return }
                            try? app.history.record(
                                record.video, part: record.part, progress: progress, completed: completed)
                        }
                    }
                }
            } else {
                EmptyBlock(title: "本地视频不可用", message: "请返回下载列表检查文件状态。")
            }
        }.navigationTitle("离线观看").navigationBarTitleDisplayMode(.inline).onDisappear {
            model.flush()
            if !model.isFullscreen { model.stop() }
        }
    }
}
