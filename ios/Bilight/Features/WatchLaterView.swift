import SwiftUI

struct WatchLaterGlyph: View {
    var saved = false
    var size: CGFloat = 22
    var body: some View {
        Image(saved ? "WatchLaterSaved" : "WatchLater")
            .resizable().renderingMode(.template).interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct WatchLaterButton: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var store: WatchLaterStore
    let video: Video

    var body: some View {
        let saved = store.contains(video.aid)
        let pending = store.pending.contains(video.aid)
        Button {
            if app.user == nil { app.showLogin = true }
            else { store.toggle(video) }
        } label: {
            Group {
                if pending { ProgressView().tint(.white).scaleEffect(0.65) }
                else { WatchLaterGlyph(saved: saved).shadow(color: .black.opacity(0.7), radius: 2, y: 1) }
            }.foregroundStyle(.white).frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(pending)
            .accessibilityLabel(saved ? "移出稍后再看" : "加入稍后再看")
            .accessibilityValue(pending ? "正在同步" : saved ? "已加入" : "")
            .accessibilityIdentifier("watch-later-\(video.aid)")
            .onAppear { store.prepare() }
    }
}

struct WatchLaterNotification: View {
    @ObservedObject var store: WatchLaterStore
    var body: some View {
        if let notice = store.notice {
            HStack(spacing: 12) {
                Text(notice.text).font(.subheadline).multilineTextAlignment(.leading)
                if !notice.removed.isEmpty {
                    Button("撤销") { store.undo(notice) }.buttonStyle(.plain).font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.biliPink).frame(minWidth: 44, minHeight: 44)
                }
            }.padding(.horizontal, 14).padding(.vertical, notice.removed.isEmpty ? 9 : 0)
                .background(Color.biliPanel, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)) }
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                .transition(.opacity)
                .accessibilityIdentifier("watch-later-notification")
        }
    }
}

struct WatchLaterView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.dynamicTypeSize) private var textSize
    @ObservedObject var store: WatchLaterStore
    @State private var visibleCount = WatchLaterPage.size
    @State private var didOpen = false
    @State private var managing = false
    @State private var confirm = false
    @State private var selected = Set<Int>()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if app.user == nil {
                    EmptyBlock(symbol: "clock", title: "登录后查看稍后再看")
                    Button("登录 B 站") { app.showLogin = true }.buttonStyle(.borderedProminent)
                } else if store.items.isEmpty, let error = store.readError {
                    VStack(spacing: 12) {
                        EmptyBlock(symbol: "arrow.clockwise", title: "稍后再看读取失败", message: error)
                        Button("重试") { Task { await store.read(reset: true) } }
                    }.frame(maxWidth: .infinity)
                } else if store.items.isEmpty && store.loaded && !store.hasMore {
                    VStack(spacing: 12) {
                        WatchLaterGlyph(size: 34).foregroundStyle(Color.biliMuted)
                        Text("还没有稍后再看").font(.headline)
                        Button("去搜索") { app.openSearchHome() }
                    }.frame(maxWidth: .infinity).padding(.vertical, 65)
                } else if store.items.isEmpty {
                    LoadingBlock(label: "正在读取稍后再看")
                } else {
                    HStack {
                        if let count = store.count { Text("\(count) 个视频") }
                        Spacer()
                        Text("最近添加")
                    }.font(.footnote).foregroundStyle(Color.biliMuted).padding(.bottom, 14)
                    ForEach(Array(store.items.prefix(visibleCount))) { item in
                        row(item)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        Divider()
                    }
                    if let error = store.readError {
                        FailureBlock(error: error) { Task { await store.readVisible(visibleCount, reset: true) } }
                    } else if store.loading && visibleCount >= store.items.count {
                        LoadingBlock()
                    } else if visibleCount < store.items.count || store.hasMore {
                        Button("加载更多") {
                            visibleCount += WatchLaterPage.size
                            if store.items.count < visibleCount && store.hasMore { Task { await store.readVisible(visibleCount) } }
                        }.font(.footnote).frame(maxWidth: .infinity, minHeight: 44).padding(.top, 10)
                    }
                }
            }.padding(16).padding(.bottom, 52)
        }.background(Color.biliBackground)
            .navigationTitle("稍后再看").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.items.isEmpty || managing {
                        Button(managing ? "取消" : "管理") {
                            managing.toggle()
                            selected.removeAll()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if managing {
                    HStack {
                        Text("已选 \(selected.count) 项").font(.subheadline).foregroundStyle(Color.biliMuted)
                        Spacer()
                        Button("移出") { confirm = true }.buttonStyle(.borderedProminent)
                            .tint(Color.biliPink).disabled(selected.isEmpty || !store.pending.isDisjoint(with: selected))
                    }.padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial)
                }
            }
            .alert("移出 \(selected.count) 个视频？", isPresented: $confirm) {
                Button("取消", role: .cancel) {}
                Button("确认移出", role: .destructive) { store.remove(store.items.filter { selected.contains($0.id) }) }
            }
            .refreshable { visibleCount = WatchLaterPage.size; await store.read(reset: true) }
            .task(id: app.accountGeneration) {
                if !didOpen { didOpen = true; await store.read(reset: true) }
            }
            .onChange(of: scene) { _, value in
                if value == .active, !managing { Task { await store.readVisible(visibleCount, reset: true) } }
            }
            .onChange(of: store.items.map(\.id)) { _, ids in
                selected.formIntersection(ids)
                if ids.isEmpty { managing = false }
            }
    }

    private func row(_ item: WatchLaterItem) -> some View {
        let pending = store.pending.contains(item.id)
        return HStack(alignment: .center, spacing: 6) {
            if managing {
                Button {
                    if !selected.insert(item.id).inserted { selected.remove(item.id) }
                } label: {
                    Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(item.id) ? Color.biliPink : Color.biliMuted)
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).disabled(pending)
                    .accessibilityLabel("选择 \(item.title)")
                    .accessibilityAddTraits(selected.contains(item.id) ? .isSelected : [])
            }
            Button {
                if managing {
                    if !selected.insert(item.id).inserted { selected.remove(item.id) }
                } else { app.open(item) }
            } label: {
                let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                layout {
                    Group {
                        if let video = item.video {
                            RemoteImage(url: video.cover).overlay(alignment: .bottomTrailing) {
                                if video.duration > 0 {
                                    Text(timeLabel(video.duration)).font(.caption2.monospacedDigit())
                                        .foregroundStyle(.white).padding(3).background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 3)).padding(4)
                                }
                            }
                        } else {
                            Color.biliSoft.overlay { WatchLaterGlyph().foregroundStyle(Color.biliMuted) }
                        }
                    }.frame(width: 112, height: 63).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).foregroundStyle(.primary).font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.leading).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                        if let video = item.video { Text(video.owner.name).foregroundStyle(Color.biliMuted).font(.caption) }
                        else { Text("视频已不可用").foregroundStyle(Color.biliMuted).font(.caption) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(pending || item.video == nil && !managing)
            if !managing {
                Button { store.remove([item]) } label: {
                    Group {
                        if pending { ProgressView().scaleEffect(0.7) }
                        else { Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(Color.biliMuted) }
                    }.frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(pending)
                    .accessibilityLabel("移出 \(item.title)").accessibilityIdentifier("watch-later-remove-\(item.id)")
            }
        }.padding(.vertical, 10)
    }
}
