import SwiftUI

struct FavoriteFoldersView: View {
    @EnvironmentObject private var app: AppModel
    @State private var tab = 0
    @State private var page = 1
    @State private var refresh = 0
    @State private var result: Page<FavoriteFolder>?
    @State private var busy = true
    @State private var error: String?
    @State private var showCreate = false
    var body: some View {
        VStack(spacing: 0) {
            ContentTabs(titles: ["我创建的", "我收藏的"], selection: $tab).padding(.horizontal, 18)
                .onChange(of: tab) { _, _ in page = 1 }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if busy {
                        LoadingBlock(label: "正在读取收藏夹")
                    } else if let error {
                        FailureBlock(error: error) { refresh += 1 }
                    } else if let result {
                        if result.items.isEmpty {
                            EmptyBlock(
                                symbol: "star", title: tab == 0 ? "还没有收藏夹" : "还没有收藏他人的收藏夹或合集",
                                message: "收藏内容会按 B 站的文件夹顺序呈现。")
                        }
                        ForEach(result.items) { folder in
                            Button {
                                if folder.type == 21 {
                                    app.open(
                                        CreatorCollection(
                                            number: folder.id, mid: folder.mid, kind: .season, title: folder.title,
                                            description: folder.intro, cover: folder.cover, count: folder.count))
                                } else {
                                    app.navigate(.favoriteFolder(folder))
                                }
                            } label: {
                                HStack(spacing: 14) {
                                    RemoteImage(url: folder.cover).frame(width: 112, height: 72).clipShape(
                                        RoundedRectangle(cornerRadius: 7)
                                    )
                                    .overlay(alignment: .bottomTrailing) {
                                        if folder.isPrivate {
                                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.white)
                                                .padding(5).background(
                                                    .black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(folder.title).font(.system(size: 15, weight: .medium)).foregroundStyle(
                                            .primary
                                        ).lineLimit(2)
                                        Text(
                                            "\(folder.count) 个内容 · \(folder.type == 21 ? "合集" : folder.isPrivate ? "私密" : "公开")"
                                        ).font(.caption).foregroundStyle(Color.biliMuted)
                                        if !folder.creatorName.isEmpty, tab == 1 {
                                            Text(folder.creatorName).font(.caption2).foregroundStyle(Color.biliMuted)
                                                .lineLimit(1)
                                        }
                                    if folder.unavailable {
                                        Text(folder.mid <= 0 ? "创建者信息不可用" : "收藏夹已失效").font(.caption).foregroundStyle(Color.biliMuted)
                                    }
                                        if ![11, 21].contains(folder.type) {
                                            Text("此类收藏暂不支持打开").font(.caption).foregroundStyle(Color.biliMuted)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Color.biliMuted)
                                }.padding(.vertical, 14)
                            }.buttonStyle(.plain).disabled(folder.unavailable || ![11, 21].contains(folder.type))
                            Divider().opacity(0.4)
                        }
                        PageButtons(page: page, more: result.hasMore, busy: busy) { page = $0 }
                    }
                }.padding(.horizontal, 18)
            }
        }.navigationTitle("我的收藏").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 20) {
                        Button {
                            refresh += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }.accessibilityLabel("刷新收藏夹")
                        Button {
                            showCreate = true
                        } label: {
                            Image(systemName: "plus")
                        }.accessibilityLabel("新建收藏夹")
                    }
                }
            }.sheet(isPresented: $showCreate) {
                NewFavoriteFolderView { folder in
                    tab = 0
                    page = 1
                    refresh += 1
                    app.navigate(.favoriteFolder(folder))
                }.environmentObject(app)
            }
            .task(id: "\(tab)-\(page)-\(refresh)") {
                guard let mid = app.user?.mid else {
                    busy = false
                    return
                }
                busy = true
                error = nil
                do {
                    let value = try await app.client.favoriteFolders(mid: mid, collected: tab == 1, page: page)
                    try Task.checkCancellation()
                    guard app.user?.mid == mid else { return }
                    result = value
                } catch is CancellationError { return } catch {
                    if Task.isCancelled { return }
                    self.error = error.localizedDescription
                    NativeTrace.mark(
                        .libraryFailed,
                        ["kind": tab == 1 ? 3 : 2, "code": Int((error as? BiliFailure)?.code ?? "") ?? 0])
                    app.handle(error)
                }
                busy = false
            }
    }
}

struct FavoriteContentsView: View {
    @EnvironmentObject private var app: AppModel
    var folder: FavoriteFolder
    @State private var page = 1
    @State private var refresh = 0
    @State private var order = "mtime"
    @State private var text = ""
    @State private var keyword = ""
    @State private var result: Page<FavoriteItem>?
    @State private var busy = true
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.biliMuted)
                TextField("搜索这个收藏夹", text: $text).font(.system(size: 14)).submitLabel(.search)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).onSubmit(search)
                if !text.isEmpty {
                    Button {
                        text = ""
                        search()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.biliMuted)
                    }.accessibilityLabel("清空搜索")
                }
                Button("搜索", action: search).font(.footnote)
            }.padding(12).background(Color.biliSoft, in: RoundedRectangle(cornerRadius: 10)).padding(18)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if busy {
                        LoadingBlock(label: "正在读取收藏内容")
                    } else if let error {
                        FailureBlock(error: error) { refresh += 1 }
                    } else if let result {
                        if result.items.isEmpty {
                            EmptyBlock(
                                symbol: "star", title: keyword.isEmpty ? "收藏夹还是空的" : "没有找到相关内容",
                                message: keyword.isEmpty ? "你在 B 站收藏到这个文件夹的视频会显示在这里。" : "可以换个关键词再试试。")
                        }
                        ForEach(result.items) { item in
                            HStack(alignment: .center, spacing: 13) {
                                Button {
                                    if let video = item.video { app.open(video) }
                                } label: {
                                    RemoteImage(url: item.cover).frame(width: 130, height: 81).clipShape(
                                        RoundedRectangle(cornerRadius: 6))
                                }.disabled(item.video == nil)
                                VStack(alignment: .leading, spacing: 7) {
                                    Button {
                                        if let video = item.video { app.open(video) }
                                    } label: {
                                        Text(item.title).font(.system(size: 14, weight: .medium)).foregroundStyle(
                                            .primary
                                        ).lineLimit(2).multilineTextAlignment(.leading)
                                    }.disabled(item.video == nil)
                                    if item.owner.mid > 0 {
                                        Button {
                                            app.open(item.owner)
                                        } label: {
                                            Text(item.owner.name).font(.caption).foregroundStyle(Color.biliMuted)
                                                .lineLimit(1)
                                        }
                                    }
                                    if let video = item.video {
                                        Text(timeLabel(video.duration)).font(.caption2).foregroundStyle(Color.biliMuted)
                                    } else {
                                        Text(item.type == 2 ? "视频已失效或不可播放" : "此类内容暂不支持播放").font(.caption2)
                                            .foregroundStyle(Color.biliMuted)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).padding(.vertical, 12)
                            Divider().opacity(0.4)
                        }
                        PageButtons(page: page, more: result.hasMore, busy: busy) { page = $0 }
                    }
                }.padding(.horizontal, 18)
            }.scrollDismissesKeyboard(.interactively)
        }.navigationTitle(folder.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $order) {
                            Text("最近收藏").tag("mtime")
                            Text("最多播放").tag("view")
                            Text("最新投稿").tag("pubtime")
                        }
                        Button("刷新", systemImage: "arrow.clockwise") { refresh += 1 }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }.accessibilityLabel("收藏夹排序")
                }
            }.onChange(of: order) { _, _ in page = 1 }
            .task(id: "\(page)-\(order)-\(keyword)-\(refresh)") {
                guard let mid = app.user?.mid else {
                    busy = false
                    return
                }
                busy = true
                error = nil
                do {
                    let value = try await app.client.favoriteContents(
                        mid: mid, folder: folder, page: page, keyword: keyword, order: order)
                    try Task.checkCancellation()
                    guard app.user?.mid == mid else { return }
                    result = value
                } catch is CancellationError { return } catch {
                    if Task.isCancelled { return }
                    self.error = error.localizedDescription
                    NativeTrace.mark(
                        .libraryFailed, ["kind": 4, "code": Int((error as? BiliFailure)?.code ?? "") ?? 0])
                    app.handle(error)
                }
                busy = false
            }
    }
    private func search() {
        keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        page = 1
    }
}

struct NewFavoriteFolderView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var created: (FavoriteFolder) -> Void
    @State private var title = ""
    @State private var isPrivate = false
    @State private var busy = false
    @State private var submitted = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("收藏夹名称", text: $title).onChange(of: title) { _, value in title = String(value.prefix(20))
                    }
                    HStack {
                        Spacer()
                        Text("\(title.count)/20").font(.caption).foregroundStyle(Color.biliMuted)
                    }
                    Toggle("公开收藏夹", isOn: Binding(get: { !isPrivate }, set: { isPrivate = !$0 })).tint(Color.biliPink)
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(Color.biliPink) } }
            }.disabled(busy).navigationTitle("新建收藏夹").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            guard !submitted, let mid = app.user?.mid else { return }
                            busy = true
                            submitted = true
                            Task {
                                defer { busy = false }
                                do {
                                    let folder = try await app.client.createFavoriteFolder(
                                        mid: mid, title: title, isPrivate: isPrivate)
                                    guard app.user?.mid == mid else { return }
                                    dismiss()
                                    created(folder)
                                } catch {
                                    self.error = "\(error.localizedDescription) 请关闭此页并刷新列表，确认结果后再操作。"
                                    app.handle(error)
                                }
                            }
                        } label: {
                            if busy { ProgressView() } else { Text("创建") }
                        }
                        .disabled(submitted || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.interactiveDismissDisabled(busy)
        }.tint(Color.biliPink)
    }
}
