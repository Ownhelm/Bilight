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
        }.tint(Color.biliPink).modifier(VideoSharePresentation())
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
        Group {
            if frequent { frequentPeople }
            else { FollowedPeopleDirectoryView(search: app.followedPeople) }
        }
    }
    private var frequentPeople: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if busy { LoadingBlock(label: "正在读取常访问") }
                else if let error { FailureBlock(error: error) { refresh += 1 } }
                else if let result {
                    if result.items.isEmpty {
                        EmptyBlock(symbol: "person.2", title: "暂无常访问记录", message: "可以通过搜索找到你想看的 UP 主。")
                    }
                    ForEach(result.items) { item in UserRow(user: item.user); Divider().opacity(0.4) }
                    PageButtons(page: page, more: result.hasMore, busy: busy) { page = $0 }
                }
            }.padding(.horizontal, 18)
        }.navigationTitle("常访问的 UP 主").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新列表")
                }
            }
            .task(id: "\(app.user?.mid ?? 0)-\(page)-\(refresh)") {
                guard let mid = app.user?.mid else { busy = false; return }
                busy = true; error = nil
                do {
                    let value = try await app.client.followedPeople(mid: mid, page: page, frequent: true)
                    try Task.checkCancellation()
                    guard app.user?.mid == mid else { return }
                    for item in value.items { app.relations[item.id] = item.relation; app.register(item.user) }
                    result = value
                } catch is CancellationError { return } catch {
                    if Task.isCancelled { return }
                    self.error = error.localizedDescription
                    NativeTrace.mark(.libraryFailed, ["kind": 1, "code": Int((error as? BiliFailure)?.code ?? "") ?? 0])
                    app.handle(error)
                }
                busy = false
            }
    }
}

private struct FollowedPeopleDirectoryView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var search: FollowedPeopleSearch
    @State private var keyword = ""
    @State private var page = 1
    @FocusState private var searchFocused: Bool
    private var searching: Bool { !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var matches: [FollowedPerson] {
        let people = searching ? search.matches(keyword) : search.items ?? []
        return people.filter { app.relations[$0.id]?.following != false }
    }
    private var visible: [FollowedPerson] {
        if searching { return matches }
        return Array(matches.dropFirst((page - 1) * 20).prefix(20))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.biliMuted)
                TextField("搜索名字、拼音或首字母", text: $keyword,
                          prompt: Text("搜索名字、拼音或首字母").foregroundStyle(Color.biliPlaceholder))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .focused($searchFocused).onSubmit { searchFocused = false }
                    .accessibilityIdentifier("people-search-field")
                if !keyword.isEmpty {
                    Button { keyword = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(Color.biliMuted).frame(minWidth: 44, minHeight: 44).accessibilityLabel("清空关注搜索")
                }
            }.padding(.horizontal, 16).frame(minHeight: 48).background(Color.biliSoft, in: Capsule())
                .padding(.horizontal, 18).padding(.vertical, 10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = search.error {
                        HStack(alignment: .top, spacing: 8) {
                            Text("关注名单更新失败：" + error).font(.caption).foregroundStyle(Color.biliMuted)
                            Spacer(minLength: 0)
                            Button("重试", action: update).font(.caption).frame(minWidth: 44, minHeight: 44)
                        }.padding(.vertical, 8)
                    }
                    if search.busy && !search.hasSnapshot {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在更新关注名单，已读取 \(search.items?.count ?? 0) 位").font(.caption).foregroundStyle(Color.biliMuted)
                        }.padding(.vertical, 12)
                    }
                    if search.items != nil {
                        if matches.isEmpty && !search.busy {
                            EmptyBlock(symbol: searching ? "magnifyingglass" : "person.2",
                                       title: searching ? "没有匹配的关注用户" : "还没有关注 UP 主",
                                       message: searching ? "试试名字、拼音或首字母。" : "可以通过搜索找到你想看的 UP 主。")
                        } else {
                            if searching {
                                Text("找到 \(matches.count) 个用户关注用户").font(.caption).foregroundStyle(Color.biliMuted)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                                    .accessibilityIdentifier(search.hasSnapshot ? "people-search-complete" : "people-search-partial")
                            }
                            ForEach(visible) { item in UserRow(user: item.user); Divider().opacity(0.4) }
                            if !searching { PageButtons(page: page, more: page * 20 < matches.count, busy: false) { page = $0 } }
                        }
                    }
                }.padding(.horizontal, 18)
            }.scrollDismissesKeyboard(.interactively)
        }.navigationTitle("我的关注的人").navigationBarTitleDisplayMode(.inline)
            .task(id: app.accountGeneration) { search.account(app.user?.mid); update() }
            .onChange(of: matches.count) { _, count in page = min(page, max(1, (count + 19) / 20)) }
            .onChange(of: search.busy) { _, busy in
                if !busy, search.hasSnapshot, search.error == nil {
                    for item in search.items ?? [] { app.relations[item.id] = item.relation }
                }
            }
    }
    private func update() {
        guard let mid = app.user?.mid else { return }
        let generation = app.accountGeneration
        search.enter { page in
            let value: Page<FollowedPerson>
            do { value = try await app.client.followedPeople(mid: mid, page: page) }
            catch {
                if app.accountGeneration == generation { app.handle(error) }
                throw error
            }
            try Task.checkCancellation()
            guard app.accountGeneration == generation else { throw CancellationError() }
            for item in value.items where app.relations[item.id] == nil { app.relations[item.id] = item.relation }
            for item in value.items { app.register(item.user) }
            return value
        }
    }
}
