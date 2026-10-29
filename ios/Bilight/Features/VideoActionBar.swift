import SwiftUI

struct VideoActionBar: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: PlayerModel
    var bvid: String
    var cid: Int
    var statistics: VideoStatistics?
    var onDownload: () -> Void
    @StateObject private var support = VideoSupportModel()
    @State private var panel: Panel?
    @State private var charging = false
    @State private var chargeProgress = 0.0
    @ScaledMetric(relativeTo: .caption) private var actionWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .caption) private var actionHeight: CGFloat = 58
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var countSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption) private var iconGap: CGFloat = 9
    @ScaledMetric(relativeTo: .caption) private var groupGap: CGFloat = 24
    private enum Panel: String, Identifiable { case coin, favorite; var id: String { rawValue } }
    private var enabled: Bool { !support.busy }
    var body: some View {
        VStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    HStack(spacing: groupGap) {
                        likeControl.frame(width: max(44, actionWidth))
                        coinControl.frame(width: max(44, actionWidth))
                        favoriteControl.frame(width: max(44, actionWidth))
                    }
                    Spacer(minLength: 8)
                    downloadControl.frame(width: max(44, actionWidth))
                }
                // Keep readable labels and 44pt targets when a larger font cannot fit a single row.
                LazyVGrid(columns: [GridItem(.flexible(minimum: 44), spacing: 12), GridItem(.flexible(minimum: 44), spacing: 12)], spacing: 12) {
                    likeControl
                    coinControl
                    favoriteControl
                    downloadControl
                }
            }.buttonStyle(.plain)
            if let error = support.error {
                HStack(alignment: .top) {
                    Text(error).font(.caption2)
                    Spacer(minLength: 6)
                    Button("刷新状态") { Task { await support.refresh(client: app.client, bvid: bvid, authenticated: app.user != nil, refreshCounts: true) } }.font(.caption2).disabled(support.busy)
                }.foregroundStyle(Color.biliPink).padding(.vertical, 4)
            }
            if let error = model.danmakuError {
                HStack {
                    Text(error).font(.caption2)
                    Spacer()
                    Button("重试") { model.setDanmakuEnabled(true, client: app.client, cid: cid) }.font(.caption2)
                }.foregroundStyle(Color.biliPink)
            }
        }.padding(.leading, 16).padding(.trailing, 20).padding(.bottom, 2)
            .task(id: "\(bvid)-\(app.accountGeneration)") {
                support.reset(statistics); setCharging(false)
                await refresh()
            }.onDisappear { setCharging(false) }
            .onChange(of: app.accountGeneration) { _, _ in panel = nil }
            .sheet(item: $panel) { value in
                if value == .coin { CoinActionSheet(bvid: bvid, support: support).environmentObject(app) }
                else { FavoriteActionSheet(bvid: bvid, support: support).environmentObject(app) }
            }
    }
    private var likeControl: some View {
        actionIcon(.like, count: support.statistics?.likes, title: "点赞", selected: support.state?.liked == true)
            .overlay {
                LikePressTarget(enabled: enabled, label: "点赞，\(support.statistics.map { countLabel($0.likes) } ?? "数量暂不可用")", onTap: like, onTriple: { write(.triple) }, onCharge: setCharging, canHold: canTriple)
            }
    }
    private var coinControl: some View {
        Button { open(.coin) } label: {
            actionIcon(.coin, count: support.statistics?.coins, title: "投币", selected: (support.state?.coins ?? 0) > 0)
        }.disabled(!enabled).accessibilityLabel("投币")
    }
    private var favoriteControl: some View {
        Button { open(.favorite) } label: {
            actionIcon(.favorite, count: support.statistics?.favorites, title: "收藏", selected: support.state?.favorited == true)
        }.disabled(!enabled).accessibilityLabel("收藏")
    }
    private var downloadControl: some View {
        Button(action: onDownload) {
            VStack(spacing: iconGap) {
                BiliActionIcon(kind: .download, size: iconSize)
                Text("缓存").font(.system(size: countSize)).lineLimit(1).minimumScaleFactor(0.5)
            }.foregroundStyle(Color.biliMuted).frame(minWidth: 44, maxWidth: .infinity, minHeight: max(44, actionHeight))
                .contentShape(Rectangle())
        }.accessibilityLabel("下载当前分 P")
    }
    private func actionIcon(_ icon: BiliActionIcon.Kind, count: Int?, title: String, selected: Bool) -> some View {
        VStack(spacing: iconGap) {
            BiliActionIcon(kind: icon, size: iconSize).foregroundStyle(selected ? Color.biliPink : Color(white: 0.46))
                .scaleEffect(charging ? 1.08 : 1)
                .overlay {
                    if charging {
                        Circle().trim(from: 0, to: chargeProgress).stroke(Color.biliPink, style: StrokeStyle(lineWidth: 2.5 * iconSize / 22, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 34 * iconSize / 22, height: 34 * iconSize / 22)
                    }
                }
            Text(count.map(countLabel) ?? "—").font(.system(size: countSize)).foregroundStyle(selected ? Color.biliPink : Color.biliMuted)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
        }.frame(minWidth: 44, maxWidth: .infinity, minHeight: max(44, actionHeight)).contentShape(Rectangle())
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title)，\(count.map(countLabel) ?? "数量暂不可用")")
    }
    private func like() {
        guard app.user != nil else { app.showLogin = true; return }
        guard let state = support.state else { Task { await refresh() }; return }
        write(.like(!state.liked))
    }
    private func canTriple() -> Bool {
        guard app.user != nil else { app.showLogin = true; return false }
        return enabled && support.state != nil && support.state?.complete != true
    }
    private func setCharging(_ value: Bool) {
        guard charging != value else { return }
        charging = value; chargeProgress = 0
        if value {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.linear(duration: 1.5)) { chargeProgress = 1 }
        }
    }
    private func open(_ value: Panel) {
        guard app.user != nil else { app.showLogin = true; return }
        panel = value
    }
    private func write(_ action: VideoWrite) {
        guard app.user != nil else { app.showLogin = true; return }
        Task {
            let generation = app.accountGeneration
            let ok = await support.write(client: app.client, bvid: bvid, action: action)
            if ok, app.accountGeneration == generation { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }
    private func refresh() async { await support.refresh(client: app.client, bvid: bvid, authenticated: app.user != nil) }
}

private struct CoinActionSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var bvid: String
    @ObservedObject var support: VideoSupportModel
    @State private var state: VideoEngagement?
    @State private var limit = 0
    @State private var coins = 1
    @State private var selectLike = true
    @State private var busy = true
    @State private var error: String?
    private var remaining: Int { max(0, limit - (state?.coins ?? 0)) }
    var body: some View {
        NavigationStack {
            Form {
                if busy { ProgressView("正在读取投币状态") }
                else if state != nil {
                    Section {
                        if remaining == 0 { Text("已投满") }
                        else {
                            Picker("投币数量", selection: $coins) { ForEach(1...remaining, id: \.self) { Text("\($0) 枚").tag($0) } }.pickerStyle(.segmented)
                            Toggle("同时点赞", isOn: $selectLike)
                        }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.biliPink) }
                if let error = support.error { Text(error).font(.footnote).foregroundStyle(Color.biliPink) }
            }.navigationTitle("投币").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确定") {
                            dismiss()
                            Task {
                                _ = await support.write(client: app.client, bvid: bvid, action: .coin(target: (state?.coins ?? 0) + coins, like: selectLike))
                            }
                        }.disabled(busy || support.busy || remaining == 0)
                    }
                }.task {
                    do {
                        let value = try await app.client.videoEngagement(bvid)
                        let video = try await app.client.video(bvid)
                        guard let maximum = video.coinLimit else { throw BiliFailure.invalid }
                        try Task.checkCancellation()
                        state = value; limit = maximum; coins = max(1, maximum - value.coins)
                    } catch { self.error = error.localizedDescription }
                    busy = false
                }
        }.tint(Color.biliPink).presentationDetents([.medium])
    }
}

private struct FavoriteActionSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var bvid: String
    @ObservedObject var support: VideoSupportModel
    @State private var folders: [VideoFavoriteFolder] = []
    @State private var selected = Set<Int>()
    @State private var busy = true
    @State private var error: String?
    @State private var creating = false
    @State private var creationNeedsRefresh = false
    @State private var title = ""
    private var changed: Bool { selected != Set(folders.filter(\.selected).map(\.id)) }
    var body: some View {
        NavigationStack {
            List {
                if busy { ProgressView("正在读取收藏夹") }
                ForEach(folders) { folder in
                    Button {
                        if selected.contains(folder.id) { selected.remove(folder.id) } else { selected.insert(folder.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(folder.title); if folder.isPrivate { Image(systemName: "lock.fill").font(.caption2) } }
                                Text("\(folder.count) / \(folder.capacity)").font(.caption).foregroundStyle(Color.biliMuted)
                            }
                            Spacer()
                            Image(systemName: selected.contains(folder.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(folder.id) ? Color.biliPink : Color.biliMuted)
                        }.foregroundStyle(.primary).padding(.vertical, 4)
                    }.buttonStyle(.plain).disabled(!folder.selected && folder.count >= folder.capacity && !selected.contains(folder.id))
                }
                Button { title = ""; creating = true } label: { Label("新建收藏夹", systemImage: "plus") }.disabled(busy || folders.count >= 100 || support.busy || creationNeedsRefresh)
                if creationNeedsRefresh { Button("刷新收藏夹") { Task { await load() } }.disabled(busy) }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.biliPink) }
                if let error = support.error { Text(error).font(.footnote).foregroundStyle(Color.biliPink) }
            }.navigationTitle("收藏到（\(selected.count)）").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确定") { Task { if await support.write(client: app.client, bvid: bvid, action: .favorite(selected.sorted())) { dismiss() } } }
                            .disabled(busy || !changed || support.busy)
                    }
                }.task { await load() }
                .alert("新建收藏夹", isPresented: $creating) {
                    TextField("1–20 个字", text: $title)
                    Button("取消", role: .cancel) {}
                    Button("创建") {
                        Task {
                            guard let mid = app.user?.mid else { return }
                            busy = true
                            do {
                                let previous = selected
                                let folder = try await app.client.createFavoriteFolder(mid: mid, title: title, isPrivate: false)
                                await load()
                                selected.formUnion(previous.intersection(Set(folders.map(\.id))))
                                if folders.contains(where: { $0.id == folder.id }) { selected.insert(folder.id) }
                            } catch { self.error = error.localizedDescription; creationNeedsRefresh = true }
                            busy = false
                        }
                    }
                }
        }.tint(Color.biliPink).presentationDetents([.medium, .large])
    }
    private func load() async {
        busy = true; error = nil
        do {
            let value = try await app.client.videoFavoriteFolders(bvid)
            try Task.checkCancellation()
            folders = value
            selected = Set(value.filter(\.selected).map(\.id))
            creationNeedsRefresh = false
        } catch { self.error = error.localizedDescription }
        busy = false
    }
}
