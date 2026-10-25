import SwiftUI

struct CreatorView: View {
    @EnvironmentObject private var app: AppModel
    var mid: Int
    @State private var user: User?
    @State private var profileError: String?
    @State private var tab = 0
    @State private var videoPage = 1
    @State private var catalogPage = 1
    @State private var refresh = 0
    @State private var videos: Page<Video>?
    @State private var catalog: Page<CreatorCollection>?
    @State private var error: String?
    @State private var busy = true
    private var owner: User { user ?? app.people[mid] ?? User(mid: mid, name: "UP 主", avatar: nil) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(alignment: .center, spacing: 15) {
                    RemoteImage(url: owner.avatar, avatar: true).frame(width: 70, height: 70).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 7) {
                        Text(owner.name).font(.system(size: 21, weight: .semibold))
                        if let fans = owner.fans {
                            Text("\(countLabel(fans)) 粉丝").font(.caption).foregroundStyle(Color.biliMuted)
                        }
                        Text(verbatim: "UID \(mid)").font(.caption2).foregroundStyle(Color.biliMuted)
                    }
                    Spacer(minLength: 0)
                    FollowButton(mid: mid)
                }.padding(.top, 10)
                if !owner.description.isEmpty {
                    Text(owner.description).font(.footnote).foregroundStyle(Color.biliMuted).lineSpacing(4)
                }
                if let profileError { Text("资料读取未完成：\(profileError)").font(.caption).foregroundStyle(Color.biliMuted) }
                ContentTabs(titles: ["投稿", "合集", "列表"], selection: $tab)
                if busy {
                    LoadingBlock()
                } else if let error {
                    FailureBlock(error: error) { refresh += 1 }
                } else if tab == 0, let videos {
                    if videos.items.isEmpty {
                        EmptyBlock(title: "暂时没有公开投稿", message: "仅展示 B 站实际返回的内容。")
                    } else {
                        VideoGrid(videos: videos.items)
                    }
                    PageButtons(page: videoPage, more: videos.hasMore, busy: busy) { videoPage = $0 }
                } else if let catalog {
                    let kind: CollectionKind = tab == 1 ? .season : .series
                    let groups = catalog.items.filter { $0.kind == kind }
                    if groups.isEmpty {
                        EmptyBlock(
                            symbol: "rectangle.stack", title: "这一页暂无\(kind.title)",
                            message: catalog.hasMore ? "可以继续翻页查看。" : "该 UP 主没有在这一页公开\(kind.title)。")
                    }
                    ForEach(groups) { collection in
                        Button {
                            app.open(collection)
                        } label: {
                            HStack(spacing: 13) {
                                RemoteImage(url: collection.cover).frame(width: 115, height: 72).clipShape(
                                    RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(collection.title).font(.system(size: 15, weight: .medium)).foregroundStyle(
                                        .primary
                                    ).lineLimit(2)
                                    Text("\(collection.count) 个视频 · \(kind.title)").font(.caption).foregroundStyle(
                                        Color.biliMuted)
                                    if !collection.description.isEmpty {
                                        Text(collection.description).font(.caption2).foregroundStyle(Color.biliMuted)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.biliMuted)
                            }
                        }.buttonStyle(.plain)
                    }
                    PageButtons(page: catalogPage, more: catalog.hasMore, busy: busy) { catalogPage = $0 }
                }
            }.padding(18).padding(.bottom, 20)
        }.navigationTitle("UP 主主页").navigationBarTitleDisplayMode(.inline)
            .task {
                let generation = app.accountGeneration
                do {
                    let value = try await app.client.creator(mid)
                    try Task.checkCancellation()
                    guard app.accountGeneration == generation else { return }
                    user = value
                    app.register(value)
                } catch is CancellationError {} catch { profileError = error.localizedDescription }
            }
            .task(id: "\(tab == 0 ? "videos-\(videoPage)" : "catalog-\(catalogPage)")-\(refresh)") {
                busy = true
                error = nil
                do {
                    if tab == 0 {
                        let value = try await app.client.creatorVideos(mid, page: videoPage, owner: owner)
                        try Task.checkCancellation()
                        videos = value
                    } else {
                        let value = try await app.client.collections(mid, page: catalogPage)
                        try Task.checkCancellation()
                        catalog = value
                    }
                } catch is CancellationError { return } catch {
                    if Task.isCancelled { return }
                    self.error = error.localizedDescription
                    app.handle(error)
                }
                if !Task.isCancelled { busy = false }
            }
    }
}
struct CollectionView: View {
    @EnvironmentObject private var app: AppModel
    var collection: CreatorCollection
    @State private var result: Page<Video>?
    @State private var page = 1
    @State private var refresh = 0
    @State private var error: String?
    @State private var busy = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(collection.title).font(.title2.bold())
                Text("\(collection.kind.title) · \(collection.count) 个视频").font(.caption).foregroundStyle(
                    Color.biliMuted)
                if !collection.description.isEmpty {
                    Text(collection.description).font(.footnote).foregroundStyle(Color.biliMuted)
                }
                if busy {
                    LoadingBlock()
                } else if let error {
                    FailureBlock(error: error) { refresh += 1 }
                } else if let result {
                    if result.items.isEmpty {
                        EmptyBlock(title: "没有公开的视频", message: "列表顺序与 B 站保持一致。")
                    } else {
                        VideoGrid(videos: result.items)
                    }
                    PageButtons(page: page, more: result.hasMore, busy: busy) { page = $0 }
                }
            }.padding(18)
        }.navigationTitle(collection.kind.title).navigationBarTitleDisplayMode(.inline).task(id: "\(page)-\(refresh)") {
            busy = true
            error = nil
            do {
                let value = try await app.client.collection(
                    collection, page: page,
                    owner: app.people[collection.mid] ?? User(mid: collection.mid, name: "UP 主", avatar: nil))
                try Task.checkCancellation()
                result = value
            } catch is CancellationError { return } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
            if !Task.isCancelled { busy = false }
        }
    }
}
