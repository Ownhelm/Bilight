import SwiftUI

@MainActor final class FollowingModel: ObservableObject {
    @Published var posts: [DynamicPost] = []
    @Published var busy = false
    @Published var error: String?
    @Published var hasMore = true
    @Published var loginExpired = false
    private var cursor: String?
    private var seen = Set<String>(), cursors = Set<String>()
    private var version = UUID()
    func load(client: BiliClient, mid: Int, reset: Bool = false) async {
        guard reset || (!busy && hasMore) else { return }
        let token = UUID()
        version = token
        if reset {
            posts = []
            seen = []
            cursors = []
            cursor = nil
            hasMore = true
        }
        busy = true
        error = nil
        loginExpired = false
        NativeTrace.mark(.followingStart, ["reset": reset ? 1 : 0])
        defer { if version == token { busy = false } }
        do {
            if reset { await client.invalidateFollowing() }
            for _ in 0..<3 {
                let page = try await client.following(mid: mid, cursor: cursor)
                try Task.checkCancellation()
                guard version == token else { return }
                if let next = page.cursor, cursors.contains(next) {
                    throw BiliFailure(code: "CURSOR_LOOP", message: "动态分页暂时异常，请刷新最新。")
                }
                let incoming = page.items.filter { seen.insert($0.id).inserted }
                posts += incoming
                hasMore = page.hasMore
                cursor = page.cursor
                if let next = page.cursor { cursors.insert(next) }
                // Publish each complete card immediately; no video-row fill or eager page prefetch.
                if !incoming.isEmpty || !hasMore { break }
            }
            NativeTrace.mark(.followingDisplayed, ["posts": posts.count, "hasMore": hasMore ? 1 : 0])
        } catch is CancellationError { NativeTrace.mark(.followingCancelled) } catch {
            if version == token {
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
    @StateObject private var model = FollowingModel()
    var body: some View {
        Group {
            if app.restoring {
                LoadingBlock(label: "正在连接账号")
            } else if let user = app.user {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("我的关注").font(.system(size: 26, weight: .bold))
                            }
                            Spacer()
                            Button {
                                Task { await model.load(client: app.client, mid: user.mid, reset: true) }
                            } label: {
                                Image(systemName: "arrow.clockwise").font(.system(size: 16)).padding(10)
                            }.disabled(model.busy).accessibilityLabel("刷新最新")
                        }.padding(16).background(.white)
                        ForEach(model.posts) { post in
                            DynamicCard(post: post)
                                .padding(16).background(.white)
                        }
                        if let error = model.error {
                            FailureBlock(error: error) { Task { await model.load(client: app.client, mid: user.mid) } }
                        } else if model.busy {
                            LoadingBlock(label: "正在获取关注更新")
                        } else if model.hasMore {
                            Button("加载更多") { Task { await model.load(client: app.client, mid: user.mid) } }.font(
                                .footnote
                            ).frame(maxWidth: .infinity).padding(.vertical, 12).onAppear {
                                if !model.posts.isEmpty {
                                    Task { await model.load(client: app.client, mid: user.mid) }
                                }
                            }
                        } else if model.posts.isEmpty {
                            EmptyBlock(symbol: "person.2", title: "暂无动态")
                        } else {
                            Text("已加载全部更新").font(.caption).foregroundStyle(Color.biliMuted).frame(maxWidth: .infinity)
                                .padding()
                        }
                    }
                }.background(Color.biliSoft).refreshable {
                    await model.load(client: app.client, mid: user.mid, reset: true)
                }.task(
                    id: "\(user.mid)-\(app.feedGeneration)"
                ) { await model.load(client: app.client, mid: user.mid, reset: true) }
            } else {
                VStack {
                    EmptyBlock(symbol: "person.2", title: "登录后查看关注动态")
                    Button("登录哔哩哔哩") { app.showLogin = true }.buttonStyle(.borderedProminent).tint(Color.biliPink)
                    Spacer()
                }.padding(.top, 35)
            }
        }.onChange(of: model.loginExpired) { _, expired in
            if expired { app.handle(BiliFailure(code: "-101", message: "登录已失效，请重新登录。")) }
        }
    }
}
