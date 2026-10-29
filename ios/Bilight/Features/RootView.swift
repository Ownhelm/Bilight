import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @State private var tab = 0
    @State private var pendingAccountURL: URL?
    var body: some View {
        GeometryReader { window in
            let bounds = window.frame(in: .global)
            let center = CGPoint(
                x: bounds.midX + (window.safeAreaInsets.trailing - window.safeAreaInsets.leading) / 2,
                y: bounds.midY + (window.safeAreaInsets.bottom - window.safeAreaInsets.top) / 2)
            NavigationStack(path: $app.path) {
                VStack(spacing: 0) {
                    if let error = app.accountError {
                        HStack(spacing: 8) {
                            Text(error).font(.caption)
                            Spacer()
                            Button("登录") { app.showLogin = true }
                        }.foregroundStyle(Color.biliPink).padding(12).background(Color.biliPink.opacity(0.05))
                    }
                    Group { if tab == 0 { SearchView(windowCenter: center) } else { FollowingView(model: app.following) } }.id(
                        app.accountGeneration
                    ).frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 0) {
                        tabButton("搜索", symbol: "magnifyingglass", value: 0)
                        tabButton("关注", symbol: "play.rectangle", value: 1)
                    }.padding(.top, 12).padding(.bottom, 4).background(.white).overlay(alignment: .top) {
                        Rectangle().fill(Color.black.opacity(0.06)).frame(height: 0.5)
                    }
                }.background(.white)
                    .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                if app.user == nil {
                                    app.showLogin = true
                                } else {
                                    app.accountPath = []
                                    app.showAccount = true
                                }
                            } label: {
                                RemoteImage(url: app.user?.avatar, avatar: true).frame(width: 31, height: 31).clipShape(
                                    Circle()
                                ).overlay(Circle().stroke(Color.biliPink.opacity(0.25), lineWidth: 1))
                            }.accessibilityLabel(app.user == nil ? "登录 B 站" : "我的账号")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                app.navigate(.downloads)
                            } label: {
                                Image(systemName: "arrow.down.circle").foregroundStyle(Color.biliMuted)
                            }.accessibilityLabel("我的下载")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                app.path.append(.history)
                            } label: {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.biliMuted)
                            }.accessibilityLabel("我的历史")
                        }
                    }
                    .navigationDestination(for: Route.self) { route in
                        RouteDestination(route: route)
                    }
            }.tint(Color.biliPink).preferredColorScheme(.light).environment(\.locale, Locale(identifier: "zh_CN"))
                .sheet(isPresented: $app.showLogin) { LoginView().environmentObject(app) }
                .sheet(isPresented: $app.showAccount) { AccountView().id(app.accountGeneration).environmentObject(app) }
                .onChange(of: app.restoring) { _, restoring in
                    if !restoring, let url = pendingAccountURL {
                        pendingAccountURL = nil
                        openAccount(url)
                    }
                }
                .onOpenURL { url in
                    if url.scheme == "bilight", url.host == "account" {
                        if app.restoring { pendingAccountURL = url } else { openAccount(url) }
                    }
                    if url.scheme == "bilight", url.host == "following" {
                        app.showAccount = false
                        app.path = []
                        tab = 1
                    }
                    if url.scheme == "bilight", url.host == "video", let bvid = url.pathComponents.last, validBVID(bvid)
                    {
                        app.showAccount = false
                        app.path.append(.video(bvid, 1, 0))
                    }
                    if url.scheme == "bilight", url.host == "dynamic", let id = url.pathComponents.last,
                        DynamicPost.validID(id)
                    {
                        app.showAccount = false
                        app.path.append(.dynamic(id))
                    }
                }
        }
    }
    private func openAccount(_ url: URL) {
        guard app.user != nil else {
            app.showLogin = true
            return
        }
        switch url.pathComponents.last {
        case "following": app.accountPath = [.followedPeople(false)]
        case "frequent": app.accountPath = [.followedPeople(true)]
        case "favorites": app.accountPath = [.favoriteFolders]
        case "downloads": app.accountPath = [.downloads]
        default: app.accountPath = []
        }
        app.showAccount = true
    }
    private func tabButton(_ title: String, symbol: String, value: Int) -> some View {
        Button {
            if value == 1 { app.following.requestEntry() }
            tab = value
            app.path = []
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 22, weight: tab == value ? .semibold : .regular))
                Text(title).font(.system(size: 10))
            }.foregroundStyle(tab == value ? Color.biliPink : Color.biliMuted).frame(maxWidth: .infinity)
        }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? .isSelected : [])
    }
}
struct RouteDestination: View {
    @EnvironmentObject private var app: AppModel
    var route: Route
    var body: some View {
        switch route {
        case .video(let bvid, let page, let time): VideoView(bvid: bvid, requestedPage: page, startTime: time)
        case .creator(let mid): CreatorView(mid: mid)
        case .dynamic(let id): DynamicDetailView(id: id)
        case .collection(let mid, let kind, let number):
            if let collection = app.catalogs["\(kind.rawValue)-\(number)-\(mid)"] {
                CollectionView(collection: collection)
            } else {
                EmptyBlock(title: "请重新打开列表", message: "返回 UP 主主页后选择合集或列表。")
            }
        case .history: HistoryView(history: app.history)
        case .followedPeople(let frequent): FollowedPeopleView(frequent: frequent)
        case .favoriteFolders: FavoriteFoldersView()
        case .favoriteFolder(let folder): FavoriteContentsView(folder: folder)
        case .downloads: DownloadsView(store: app.downloads)
        case .offline(let id): OfflineVideoView(store: app.downloads, id: id)
        }
    }
}
