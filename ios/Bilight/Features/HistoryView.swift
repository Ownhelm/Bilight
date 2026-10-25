import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var history: WatchHistory
    @Environment(\.scenePhase) private var scene
    @State private var visible = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if app.user == nil {
                    EmptyBlock(symbol: "clock", title: "登录后查看历史")
                    Button("登录 B 站") { app.showLogin = true }.buttonStyle(.borderedProminent).tint(Color.biliPink)
                } else if history.busy && history.items.isEmpty {
                    LoadingBlock(label: "正在读取历史")
                } else if let error = history.error, history.items.isEmpty {
                    FailureBlock(error: error) { Task { await history.load(reset: true) } }
                } else if history.items.isEmpty && !history.hasMore {
                    EmptyBlock(symbol: "clock", title: "暂无观看记录")
                } else {
                    ForEach(history.items) { record in
                        Button {
                            app.navigate(
                                .video(record.video.bvid, record.page, record.completed ? 0 : record.progress))
                        } label: {
                            HStack(spacing: 12) {
                                RemoteImage(url: record.video.cover).frame(width: 125, height: 77).clipShape(
                                    RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.video.title).font(.system(size: 14, weight: .medium)).foregroundStyle(
                                        .primary
                                    ).lineLimit(2)
                                    Text("\(record.video.owner.name) · P\(record.page)").font(.caption2)
                                        .foregroundStyle(Color.biliMuted).lineLimit(1)
                                    HStack {
                                        Text(record.completed ? "已看完" : "观看至 \(timeLabel(record.progress))")
                                        Spacer()
                                        Text(record.viewedAt, format: .dateTime.month().day().hour().minute())
                                    }.font(.caption2).foregroundStyle(Color.biliMuted)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    if let error = history.error {
                        FailureBlock(error: error) { Task { await history.load() } }
                    } else if history.busy {
                        LoadingBlock()
                    } else if history.hasMore {
                        Button("加载更多") { Task { await history.load() } }.font(.footnote).frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                HistorySyncStatus(history: history)
            }.padding(18)
        }.navigationTitle("我的历史").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await history.load(reset: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(history.busy).accessibilityLabel("刷新历史")
                }
            }
            .task(id: app.user?.mid) { await history.load(reset: true) }
            .refreshable { await history.load(reset: true) }
            .onAppear { visible = true }.onDisappear { visible = false }
            .onChange(of: history.revision) { _, _ in
                if visible { Task { await history.load(reset: true) } }
            }
            .onChange(of: scene) { _, phase in
                if visible, phase == .active { Task { await history.load(reset: true) } }
            }
            .onChange(of: history.expired) { _, expired in
                if expired { app.handle(BiliFailure(code: "-101", message: "登录已失效，请重新登录。")) }
            }
    }
}
