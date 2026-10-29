import SwiftUI

@MainActor final class FollowingModel: ObservableObject {
    @Published var posts: [DynamicPost] = []
    @Published var busy = false
    @Published var error: String?
    @Published var hasMore = true
    @Published var loginExpired = false
    @Published var visiblePostID: String?
    @Published private(set) var entryRevision = 0
    private var handledEntry = 0
    private(set) var initialized = false
    private var mid: Int?
    private var cursor: String?
    private var seen = Set<String>(), cursors = Set<String>()
    private var version = UUID()
    private var request: Task<Void, Never>?
    private var lastReset = true
    var refreshing: Bool { busy && lastReset }
    func account(_ value: Int?) {
        guard mid != value else { return }
        request?.cancel(); request = nil; version = UUID(); mid = value
        posts = []; seen = []; cursors = []; cursor = nil; visiblePostID = nil
        busy = false; error = nil; hasMore = true; initialized = false; loginExpired = false
    }
    func requestEntry() { entryRevision += 1 }
    func consumeEntry() -> Bool {
        guard handledEntry != entryRevision else { return false }
        handledEntry = entryRevision
        return true
    }
    func refreshLatest(client: BiliClient, mid: Int) async {
        if busy && lastReset, let request { await request.value; return }
        await load(client: client, mid: mid, reset: true)
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
        let task = Task {
            let began = ContinuousClock.now
            await fetch(client: client, mid: mid, reset: reset, token: token)
            // Let even a fast response show one visible native refresh cycle.
            let elapsed = began.duration(to: .now)
            if reset && elapsed < .milliseconds(400) { try? await Task.sleep(for: .milliseconds(400) - elapsed) }
            if version == token { busy = false; request = nil }
        }
        request = task
        await task.value
    }
    private func fetch(client: BiliClient, mid: Int, reset: Bool, token: UUID) async {
        NativeTrace.mark(.followingStart, ["reset": reset ? 1 : 0])
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
    @State private var revealRefresh = false
    var body: some View {
        Group {
            if app.restoring {
                LoadingBlock(label: "正在连接账号")
            } else if let user = app.user {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text("我的关注").font(.system(size: 26, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                            .background(.white).padding(.bottom, 8)
                            .id("following-top")
                        ForEach(model.posts) { post in
                            DynamicCard(post: post)
                                .padding(16).background(.white).padding(.bottom, 8)
                        }
                        if let error = model.error {
                            FailureBlock(error: error) { Task { await model.retry(client: app.client, mid: user.mid) } }
                        } else if model.refreshing {
                            EmptyView()
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
                    }.scrollTargetLayout().background(FollowingRefreshControl(
                        refreshing: model.refreshing, reveal: revealRefresh, entryRevision: model.entryRevision,
                        onRefresh: { Task { await model.refreshLatest(client: app.client, mid: user.mid) } }))
                }.scrollPosition(id: $model.visiblePostID, anchor: .top)
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { value in
                        guard value.translation.height < -8, abs(value.translation.height) > abs(value.translation.width) else { return }
                        didScroll = true
                        if moreVisible && model.error == nil { Task { await model.load(client: app.client, mid: user.mid) } }
                    })
                    .onDisappear { didScroll = false; moreVisible = false; revealRefresh = false }
                    .background(Color.biliSoft).task(id: "\(user.mid):\(model.entryRevision)") {
                    let entry = model.entryRevision
                    if model.consumeEntry() {
                        revealRefresh = true
                        didScroll = false; moreVisible = false
                        model.visiblePostID = "following-top"
                        proxy.scrollTo("following-top", anchor: .top)
                        await model.refreshLatest(client: app.client, mid: user.mid)
                    } else {
                        if !model.initialized { revealRefresh = true }
                        await model.enter(client: app.client, mid: user.mid)
                    }
                    if app.user?.mid == user.mid && model.entryRevision == entry { revealRefresh = false }
                }
                }
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

/// The same native control handles both a finger pull and an explicit tab refresh.
struct FollowingRefreshControl: UIViewRepresentable {
    var refreshing: Bool
    var reveal: Bool
    var entryRevision: Int
    var onRefresh: () -> Void
    func makeUIView(context: Context) -> FollowingRefreshAnchor { FollowingRefreshAnchor(frame: .zero) }
    func updateUIView(_ view: FollowingRefreshAnchor, context: Context) {
        view.refreshing = refreshing; view.reveal = reveal; view.entryRevision = entryRevision; view.onRefresh = onRefresh
        view.attachAndUpdate()
    }
    static func dismantleUIView(_ view: FollowingRefreshAnchor, coordinator: ()) { view.detach() }
}
final class FollowingRefreshAnchor: UIView {
    let control = UIRefreshControl()
    var refreshing = false
    var reveal = false
    var entryRevision = 0
    var onRefresh: (() -> Void)?
    private weak var scroll: UIScrollView?
    private var revealedEntry: Int?
    private var invalidated = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        control.tintColor = UIColor(Color.biliPink)
        control.attributedTitle = NSAttributedString(string: "正在刷新关注动态", attributes: [.foregroundColor: UIColor.secondaryLabel])
        control.accessibilityLabel = "正在刷新关注动态"
        control.accessibilityIdentifier = "following-refresh"
        control.addTarget(self, action: #selector(pulled), for: .valueChanged)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.attachAndUpdate() } }
    }
    func attachAndUpdate() {
        guard !invalidated, window != nil else { return }
        if scroll == nil {
            var parent = superview
            while let view = parent {
                if let view = view as? UIScrollView { scroll = view; break }
                parent = view.superview
            }
        }
        guard let scroll else { return }
        if scroll.refreshControl !== control { scroll.refreshControl = control; scroll.alwaysBounceVertical = true }
        if refreshing {
            let began = !control.isRefreshing
            if began { control.beginRefreshing() }
            if reveal && (began || revealedEntry != entryRevision) {
                revealedEntry = entryRevision
                DispatchQueue.main.async { [weak self, weak scroll] in
                    guard let self, let scroll, self.refreshing, self.reveal, !self.invalidated else { return }
                    scroll.layoutIfNeeded(); self.control.sizeToFit()
                    let height = max(60, self.control.bounds.height)
                    let top = max(scroll.adjustedContentInset.top, scroll.safeAreaInsets.top + height)
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: -top), animated: !UIAccessibility.isReduceMotionEnabled)
                }
            }
        } else if control.isRefreshing { control.endRefreshing() }
    }
    @objc private func pulled() { onRefresh?() }
    func detach() {
        invalidated = true; onRefresh = nil; control.endRefreshing()
        if scroll?.refreshControl === control { scroll?.refreshControl = nil }
        scroll = nil
    }
}
