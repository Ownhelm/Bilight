import SwiftUI

struct VideoActionBar: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: PlayerModel
    var bvid: String
    var onQuality: (Int) -> Void
    var onDownload: () -> Void
    @State private var engagement: VideoEngagement?
    @State private var supportBusy = false
    @State private var supportError: String?
    @State private var refreshRequired = false
    @State private var operation = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 3) {
                    supportButton
                    downloadButton
                    seekButtons
                    settings
                    captions
                }.fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity)
                VStack(spacing: 0) {
                    HStack(spacing: 3) {
                        supportButton
                        downloadButton
                        Spacer()
                        captions
                    }
                    HStack(spacing: 3) {
                        seekButtons
                        Spacer()
                        settings
                    }
                }
            }
            if let supportError {
                Text(supportError).font(.caption2).foregroundStyle(Color.biliPink)
            }
        }.buttonStyle(.plain).foregroundStyle(Color.biliMuted).padding(.horizontal, 12).padding(.vertical, 3)
            .task(id: "\(bvid)-\(app.accountGeneration)") {
                operation = UUID()
                supportBusy = false
                engagement = nil
                supportError = nil
                refreshRequired = false
                if app.user != nil { await support(write: false) }
            }
    }
    private var supportButton: some View {
        Button {
            guard app.user != nil else {
                app.showLogin = true
                return
            }
            Task { await support(write: !refreshRequired && engagement != nil) }
        } label: {
            Group {
                if supportBusy {
                    ProgressView().tint(Color.biliPink)
                } else if refreshRequired {
                    Image(systemName: "arrow.clockwise").font(.system(size: 19))
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: engagement?.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .foregroundStyle(engagement?.liked == true ? Color.biliPink : Color.biliMuted)
                        Image(systemName: (engagement?.coins ?? 0) > 0 ? "circle.circle.fill" : "circle.circle")
                            .foregroundStyle((engagement?.coins ?? 0) > 0 ? Color.biliPink : Color.biliMuted)
                        Image(systemName: engagement?.favorited == true ? "star.fill" : "star")
                            .foregroundStyle(engagement?.favorited == true ? Color.biliPink : Color.biliMuted)
                    }.font(.system(size: 17, weight: .medium))
                        .frame(width: 72, height: 32)
                        .background(
                            Color.biliPink.opacity(engagement?.complete == true ? 0.1 : 0.035),
                            in: RoundedRectangle(cornerRadius: 7))
                }
            }.frame(width: 76, height: 44).contentShape(Rectangle())
        }.disabled(supportBusy || (engagement?.complete == true && !refreshRequired))
            .accessibilityLabel(refreshRequired ? "刷新三连状态" : engagement?.complete == true ? "已三连" : "一键三连")
            .accessibilityValue(supportBusy ? "正在处理" : "")
            .accessibilityHint("点赞、投币并收藏到默认收藏夹")
    }
    private var downloadButton: some View {
        Button(action: onDownload) { icon("arrow.down.circle") }.accessibilityLabel("下载当前分 P")
    }
    private var seekButtons: some View {
        Group {
            Button {
                model.seek(-5)
            } label: {
                icon("gobackward.5")
            }.accessibilityLabel("后退5秒")
            Button {
                model.seek(5)
            } label: {
                icon("goforward.5")
            }.accessibilityLabel("前进5秒")
        }
    }
    private var settings: some View {
        Menu {
            Section("清晰度") {
                ForEach(model.qualityChoices) { quality in
                    Button {
                        onQuality(quality.id)
                    } label: {
                        if model.playback?.quality == quality.id {
                            Label(quality.label, systemImage: "checkmark")
                        } else {
                            Text(quality.label)
                        }
                    }
                }
            }
            Section("播放速度") {
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                    Button {
                        model.setRate(rate)
                    } label: {
                        if model.rate == rate {
                            Label(rate == 1 ? "正常" : "\(rate.formatted())×", systemImage: "checkmark")
                        } else {
                            Text(rate == 1 ? "正常" : "\(rate.formatted())×")
                        }
                    }
                }
            }
            if !model.subtitleTracks.isEmpty {
                Section("字幕语言") {
                    ForEach(model.subtitleTracks) { track in
                        Button {
                            model.selectSubtitle(track)
                        } label: {
                            if model.selectedSubtitle == track.id {
                                Label(track.label, systemImage: "checkmark")
                            } else {
                                Text(track.label)
                            }
                        }
                    }
                }
            }
        } label: {
            icon("gearshape")
        }.accessibilityLabel("清晰度、倍速与字幕语言")
    }
    private var captions: some View {
        HStack(spacing: 3) {
            Image(systemName: model.selectedSubtitle == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 15)).foregroundStyle(
                    model.selectedSubtitle == nil ? Color.biliMuted : Color.biliPink
                )
                .accessibilityHidden(true)
            Toggle("字幕", isOn: Binding(get: { model.selectedSubtitle != nil }, set: { model.setSubtitlesEnabled($0) }))
                .labelsHidden().tint(Color.biliPink).fixedSize().accessibilityLabel("字幕")
                .accessibilityHint(model.subtitleTracks.isEmpty ? "暂无可用字幕" : "")
        }.frame(minHeight: 44).disabled(model.subtitleTracks.isEmpty)
    }
    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 19)).frame(width: 44, height: 44).contentShape(Rectangle())
    }
    @MainActor private func support(write: Bool) async {
        guard !supportBusy, app.user != nil else { return }
        let token = UUID()
        let generation = app.accountGeneration
        operation = token
        supportBusy = true
        supportError = nil
        defer { if operation == token { supportBusy = false } }
        do {
            let state = try await (write ? app.client.triple(bvid) : app.client.videoEngagement(bvid))
            try Task.checkCancellation()
            guard app.accountGeneration == generation, operation == token else { return }
            engagement = state
            refreshRequired = write && !state.complete
            if refreshRequired { supportError = "三连未全部完成，请刷新状态。" }
        } catch is CancellationError { return } catch {
            guard !Task.isCancelled, app.accountGeneration == generation, operation == token else { return }
            supportError = error.localizedDescription
            refreshRequired = true
            app.handle(error)
        }
    }
}
