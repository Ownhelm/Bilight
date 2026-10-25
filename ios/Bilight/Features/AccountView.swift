import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var app: AppModel
    @State private var confirm = false
    @State private var frequent: [User] = []
    @State private var busy = true
    @State private var error: String?
    @State private var refresh = 0
    var body: some View {
        NavigationStack(path: $app.accountPath) {
            List {
                if let user = app.user {
                    Section {
                        Button {
                            app.open(user)
                        } label: {
                            HStack(spacing: 14) {
                                RemoteImage(url: user.avatar, avatar: true).frame(width: 64, height: 64).clipShape(
                                    Circle())
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(user.name).font(.system(size: 21, weight: .semibold)).foregroundStyle(.primary)
                                    Text("个人主页").font(.caption).foregroundStyle(Color.biliMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.biliMuted)
                            }.padding(.vertical, 12)
                        }.buttonStyle(.plain)
                    }
                }
                Section {
                    accountLink("我的关注的人", symbol: "person.2", route: .followedPeople(false))
                    accountLink("我的收藏", symbol: "star", route: .favoriteFolders)
                    accountLink("我的下载", symbol: "arrow.down.circle", route: .downloads)
                    accountLink("我的最近访问", symbol: "clock.arrow.circlepath", route: .recentCreators)
                }
                Section {
                    accountLink("常访问的 UP 主", symbol: "person.crop.circle", route: .followedPeople(true))
                    if busy {
                        HStack {
                            ProgressView()
                            Text("正在读取常访问").font(.caption).foregroundStyle(Color.biliMuted)
                        }
                        .padding(.vertical, 15)
                    } else if let error {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(error).font(.caption).foregroundStyle(Color.biliMuted)
                            Button("重试") { refresh += 1 }.font(.caption)
                        }.padding(.vertical, 8)
                    } else if frequent.isEmpty {
                        Text("B 站暂无常访问记录").font(.caption).foregroundStyle(Color.biliMuted).padding(.vertical, 14)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 19) {
                                ForEach(Array(frequent.prefix(8))) { user in
                                    Button {
                                        app.open(user)
                                    } label: {
                                        VStack(spacing: 9) {
                                            RemoteImage(url: user.avatar, avatar: true).frame(width: 54, height: 54)
                                                .clipShape(Circle())
                                            Text(user.name).font(.system(size: 11)).foregroundStyle(.primary).lineLimit(
                                                1
                                            ).frame(width: 62)
                                        }.padding(.vertical, 10)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                Section { Button("退出当前账号", role: .destructive) { confirm = true } }
            }.listStyle(.insetGrouped).navigationTitle("我的账号").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { app.showAccount = false } } }
                .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                .confirmationDialog("退出后将清除这台 iPhone 的登录凭据。", isPresented: $confirm, titleVisibility: .visible) {
                    Button("退出登录", role: .destructive) { Task { await app.logout() } }
                }
                .task(id: "\(app.user?.mid ?? 0)-\(refresh)") {
                    guard let mid = app.user?.mid else {
                        busy = false
                        return
                    }
                    busy = true
                    error = nil
                    do {
                        let result = try await app.client.followedPeople(mid: mid, page: 1, frequent: true)
                        try Task.checkCancellation()
                        guard app.user?.mid == mid else { return }
                        frequent = result.items.map(\.user)
                        for item in result.items { app.relations[item.id] = item.relation }
                    } catch is CancellationError { return } catch {
                        if Task.isCancelled { return }
                        self.error = error.localizedDescription
                        app.handle(error)
                    }
                    busy = false
                }
        }.tint(Color.biliPink)
    }
    private func accountLink(_ title: String, symbol: String, route: Route) -> some View {
        Button {
            app.navigate(route)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Color.biliPink).frame(width: 27)
                Text(title).font(.system(size: 15)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Color.biliMuted)
            }.padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct FollowedPeopleView: View {
    @EnvironmentObject private var app: AppModel
    var frequent: Bool
    @State private var result: Page<FollowedPerson>?
    @State private var page = 1
    @State private var refresh = 0
    @State private var busy = true
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if busy {
                    LoadingBlock(label: frequent ? "正在读取常访问" : "正在读取关注列表")
                } else if let error {
                    FailureBlock(error: error) { refresh += 1 }
                } else if let result {
                    if result.items.isEmpty {
                        EmptyBlock(
                            symbol: "person.2", title: frequent ? "暂无常访问记录" : "还没有关注 UP 主",
                            message: "可以通过搜索找到你想看的 UP 主。")
                    }
                    ForEach(result.items) { item in
                        UserRow(user: item.user)
                        Divider().opacity(0.4)
                    }
                    PageButtons(page: page, more: result.hasMore, busy: busy) { page = $0 }
                }
            }.padding(.horizontal, 18)
        }.navigationTitle(frequent ? "常访问的 UP 主" : "我的关注的人").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refresh += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }.accessibilityLabel("刷新列表")
                }
            }
            .task(id: "\(page)-\(refresh)") {
                guard let mid = app.user?.mid else {
                    busy = false
                    return
                }
                busy = true
                error = nil
                do {
                    let value = try await app.client.followedPeople(mid: mid, page: page, frequent: frequent)
                    try Task.checkCancellation()
                    guard app.user?.mid == mid else { return }
                    for item in value.items {
                        app.relations[item.id] = item.relation
                        app.register(item.user)
                    }
                    result = value
                } catch is CancellationError { return } catch {
                    if Task.isCancelled { return }
                    self.error = error.localizedDescription
                    NativeTrace.mark(
                        .libraryFailed,
                        ["kind": frequent ? 1 : 0, "code": Int((error as? BiliFailure)?.code ?? "") ?? 0])
                    app.handle(error)
                }
                busy = false
            }
    }
}

struct RecentCreatorsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var result: Page<FollowedPerson>?
    @State private var page = 1
    @State private var refresh = 0
    @State private var busy = true
    @State private var error: String?
    var body: some View {
        List {
            if busy {
                LoadingBlock(label: "正在读取 B 站常访问")
            } else if let error {
                FailureBlock(error: error) { refresh += 1 }
            } else if let result {
                if result.items.isEmpty {
                    EmptyBlock(symbol: "clock", title: "B 站暂无常访问记录", message: "登录账号的最常访问 UP 主会显示在这里。")
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(result.items) { item in
                            Button {
                                app.open(item.user)
                            } label: {
                                HStack(spacing: 13) {
                                    RemoteImage(url: item.user.avatar, avatar: true).frame(width: 52, height: 52)
                                        .clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.user.name).font(.system(size: 15, weight: .medium)).foregroundStyle(
                                            .primary)
                                        if !item.user.description.isEmpty {
                                            Text(item.user.description).font(.caption).foregroundStyle(Color.biliMuted)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.biliMuted)
                                }.padding(.vertical, 6)
                            }.buttonStyle(.plain)
                        }
                    } footer: {
                        Text("按 B 站最常访问顺序展示。B 站未提供每次主页访问的时间。")
                    }
                }
                PageButtons(page: page, more: result.hasMore, busy: busy) { page = $0 }.listRowSeparator(.hidden)
            }
        }.listStyle(.plain).navigationTitle("我的最近访问").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refresh += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }.accessibilityLabel("刷新最近访问")
                }
            }.task(id: "\(page)-\(refresh)") {
                guard let mid = app.user?.mid else {
                    busy = false
                    return
                }
                busy = true
                error = nil
                do {
                    let value = try await app.client.followedPeople(mid: mid, page: page, frequent: true)
                    try Task.checkCancellation()
                    guard app.user?.mid == mid else { return }
                    result = value
                    for item in value.items { app.register(item.user) }
                } catch is CancellationError { return } catch {
                    if Task.isCancelled { return }
                    self.error = error.localizedDescription
                    NativeTrace.mark(
                        .libraryFailed, ["kind": 1, "code": Int((error as? BiliFailure)?.code ?? "") ?? 0])
                    app.handle(error)
                }
                busy = false
            }
    }
}
