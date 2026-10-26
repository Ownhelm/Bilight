import SwiftUI

@MainActor final class FollowingModel: ObservableObject {
    @Published var posts: [DynamicPost] = []
    @Published var busy = false
    @Published var error: String?
    @Published var hasMore = true
    @Published var loginExpired = false
    @Published var visiblePostID: String?
    private(set) var initialized = false
    private var mid: Int?
    private var cursor: String?
    private var seen = Set<String>(), cursors = Set<String>()
    private var version = UUID()
    private var request: Task<Void, Never>?
    private var lastReset = true
    func account(_ value: Int?) {
        guard mid != value else { return }
        request?.cancel(); request = nil; version = UUID(); mid = value
        posts = []; seen = []; cursors = []; cursor = nil; visiblePostID = nil
        busy = false; error = nil; hasMore = true; initialized = false; loginExpired = false
    }
    func enter(client: BiliClient, mid: Int) async {
        account(mid)
        if let request { await request.value; return }
        if !initialized { await load(client: client, mid: mid, reset: true) }
    }
    func removeAuthor(_ mid: Int) { posts.removeAll { $0.author.mid == mid } }
    func retry(client: BiliClient, mid: Int) async { await load(client: client, mid: mid, reset: lastReset) }
    func load(client: BiliClient, mid: Int, reset: Bool = false) async {
        account(mid)
        guard reset || (!busy && hasMore) else { return }
        request?.cancel()
        let token = UUID()
        version = token
        lastReset = reset
        busy = true
        error = nil
        loginExpired = false
        // This request belongs to the session cache, not the transient navigation task.
        let task = Task { await fetch(client: client, mid: mid, reset: reset, token: token) }
        request = task
        await task.value
    }
    private func fetch(client: BiliClient, mid: Int, reset: Bool, token: UUID) async {
        NativeTrace.mark(.followingStart, ["reset": reset ? 1 : 0])
        defer { if version == token { busy = false; request = nil } }
        do {
            if reset { await client.invalidateFollowing() }
            for index in 0..<3 {
                let page = try await client.following(mid: mid, cursor: reset && index == 0 ? nil : cursor)
                try Task.checkCancellation()
                guard version == token else { return }
                if reset && index == 0 {
                    posts = []; seen = []; cursors = []; cursor = nil; hasMore = true; visiblePostID = nil
                }
                if let next = page.cursor, cursors.contains(next) {
                    throw BiliFailure(code: "CURSOR_LOOP", message: "动态分页暂时异常，请下拉刷新。")
                }
                let incoming = page.items.filter { seen.insert($0.id).inserted }
                posts += incoming
                hasMore = page.hasMore
                cursor = page.cursor
                if let next = page.cursor { cursors.insert(next) }
                // Publish each complete card immediately; no video-row fill or eager page prefetch.
                if !incoming.isEmpty || !hasMore { break }
            }
            initialized = true
            NativeTrace.mark(.followingDisplayed, ["posts": posts.count, "hasMore": hasMore ? 1 : 0])
        } catch is CancellationError { NativeTrace.mark(.followingCancelled) } catch {
            if version == token {
                initialized = true
                self.error = error.localizedDescription
                loginExpired = (error as? BiliFailure)?.code == "-101"
                NativeTrace.mark(
                    .followingFailed, ["code": Int((error as? BiliFailure)?.code ?? "") ?? (error as NSError).code])
            }
        }
    }
}
struct FollowingView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: FollowingModel
    @State private var moreVisible = false
    @State private var didScroll = false
    var body: some View {
        Group {
            if app.restoring {
                LoadingBlock(label: "正在连接账号")
            } else if let user = app.user {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text("我的关注").font(.system(size: 26, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                            .background(.white).padding(.bottom, 8)
                        ForEach(model.posts) { post in
                            DynamicCard(post: post)
                                .padding(16).background(.white).padding(.bottom, 8)
                        }
                        if let error = model.error {
                            FailureBlock(error: error) { Task { await model.retry(client: app.client, mid: user.mid) } }
                        } else if model.busy {
                            LoadingBlock(label: "正在获取关注更新")
                        } else if model.hasMore {
                            Button("加载更多") { Task { await model.load(client: app.client, mid: user.mid) } }.font(
                                .footnote
                            ).frame(maxWidth: .infinity).padding(.vertical, 12).onAppear {
                                moreVisible = true
                                if didScroll && !model.posts.isEmpty {
                                    Task { await model.load(client: app.client, mid: user.mid) }
                                }
                            }.onDisappear { moreVisible = false }
                        } else if model.posts.isEmpty {
                            EmptyBlock(symbol: "person.2", title: "暂无动态")
                        } else {
                            Text("已加载全部更新").font(.caption).foregroundStyle(Color.biliMuted).frame(maxWidth: .infinity)
                                .padding()
                        }
                    }.scrollTargetLayout()
                }.scrollPosition(id: $model.visiblePostID, anchor: .top)
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { value in
                        guard value.translation.height < -8, abs(value.translation.height) > abs(value.translation.width) else { return }
                        didScroll = true
                        if moreVisible && model.error == nil { Task { await model.load(client: app.client, mid: user.mid) } }
                    })
                    .onDisappear { didScroll = false; moreVisible = false }
                    .background(Color.biliSoft).refreshable {
                    await model.load(client: app.client, mid: user.mid, reset: true)
                }.task(id: user.mid) { await model.enter(client: app.client, mid: user.mid) }
            } else {
                VStack {
                    EmptyBlock(symbol: "person.2", title: "登录后查看关注动态")
                    Button("登录哔哩哔哩") { app.showLogin = true }.buttonStyle(.borderedProminent).tint(Color.biliPink)
                    Spacer()
                }.padding(.top, 35)
            }
        }.onChange(of: model.loginExpired, initial: true) { _, expired in
            if expired { app.handle(BiliFailure(code: "-101", message: "登录已失效，请重新登录。")) }
        }
    }
}
