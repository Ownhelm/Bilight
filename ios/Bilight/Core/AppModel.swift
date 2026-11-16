import SwiftUI
import UIKit

struct LikeState: Equatable { var liked: Bool; var likes: Int }

struct LikeIntent {
    let state: LikeState
    let deadline: ContinuousClock.Instant
}

@MainActor final class LikeSync<Key: Hashable> {
    private(set) var confirmed: [Key: LikeState] = [:]
    private(set) var pending: [Key: LikeIntent] = [:]
    private(set) var errors: [Key: String] = [:]
    private(set) var revision = 0
    private var versions: [Key: Int] = [:]
    private var tasks: [Key: Task<Void, Never>] = [:]
    private var uncertain = Set<Key>()
    private var generation = UUID()
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?

    func reset() {
        generation = UUID()
        for task in tasks.values { task.cancel() }
        onChange?()
        confirmed.removeAll(); pending.removeAll(); errors.removeAll()
        tasks.removeAll(); versions.removeAll(); uncertain.removeAll(); revision = 0
    }
    func state(_ key: Key, fallback: LikeState) -> LikeState {
        pending[key]?.state ?? confirmed[key] ?? fallback
    }
    func canRecord(_ key: Key, readVersion: Int) -> Bool {
        pending[key] == nil && (versions[key] ?? 0) <= readVersion
    }
    func record(_ key: Key, state: LikeState) {
        guard confirmed[key] != state else { return }
        onChange?()
        confirmed[key] = state
    }
    func setError(_ error: String?, for key: Key) {
        guard errors[key] != error else { return }
        onChange?()
        errors[key] = error
    }
    func toggle(_ key: Key, fallback: LikeState, sync: @escaping (Bool) async throws -> LikeState) {
        let visible = state(key, fallback: fallback)
        if confirmed[key] == nil { confirmed[key] = visible }
        let next = LikeState(liked: !visible.liked, likes: max(0, visible.likes + (visible.liked ? -1 : 1)))
        advanceVersion(of: key)
        onChange?()
        pending[key] = LikeIntent(state: next, deadline: .now.advanced(by: .milliseconds(800)))
        errors[key] = nil
        guard tasks[key] == nil else { return }
        let generation = generation
        tasks[key] = Task { [weak self] in
            await self?.flush(key, generation: generation, sync: sync)
        }
    }
    private func advanceVersion(of key: Key) {
        revision += 1
        versions[key] = revision
    }
    private func flush(_ key: Key, generation: UUID, sync: (Bool) async throws -> LikeState) async {
        defer {
            if self.generation == generation {
                onChange?()
                pending[key] = nil
                tasks[key] = nil
            }
        }
        while self.generation == generation, !Task.isCancelled, let intent = pending[key] {
            if .now < intent.deadline {
                do { try await ContinuousClock().sleep(until: intent.deadline) } catch { return }
                continue
            }
            let target = intent.state.liked
            guard target != confirmed[key]?.liked || uncertain.contains(key) else { return }
            do {
                let state = try await sync(target)
                guard self.generation == generation, !Task.isCancelled else { return }
                advanceVersion(of: key)
                uncertain.remove(key)
                record(key, state: state)
                if pending[key]?.state.liked == state.liked { return }
            } catch is CancellationError { return } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                uncertain.insert(key)
                if (error as? BiliFailure)?.code == "-101" || pending[key]?.state.liked == target {
                    setError(error.localizedDescription, for: key)
                    onError?(error)
                    return
                }
            }
        }
    }
}

struct CommentLikeKey: Hashable {
    let oid: String
    let type: Int
    let id: String
}

@MainActor final class AppModel: ObservableObject {
    let client: BiliClient
    let downloads: DownloadStore
    let history: WatchHistory
    let watchLater: WatchLaterStore
    let followedPeople: FollowedPeopleSearch
    let following = FollowingModel()
    @Published var user: User?
    @Published var restoring = true
    @Published private(set) var searchHomeRequest = UUID()
    @Published var accountError: String?
    @Published var showLogin = false
    @Published var showAccount = false
    @Published var shareVideo: VideoShareInfo?
    @Published var path: [Route] = []
    @Published var accountPath: [Route] = []
    @Published var relations: [Int: Relation] = [:]
    @Published var followBusy = Set<Int>()
    @Published var accountGeneration = UUID()
    let dynamicLikes = LikeSync<String>()
    let commentLikes = LikeSync<CommentLikeKey>()
    private var dynamicLikeRechecks: [String: Task<Void, Never>] = [:]
    private var confirmedDynamicLikes = Set<String>()
    var people: [Int: User] = [:]
    var videos: [String: Video] = [:]
    var catalogs: [String: CreatorCollection] = [:]
    var dynamics: [String: DynamicPost] = [:]
    init(client suppliedClient: BiliClient? = nil) {
        #if DEBUG
            let client = suppliedClient ?? (DemoFixtures.enabled || InteractionRegression.enabled ? DemoFixtures.client() : BiliClient())
        #else
            let client = suppliedClient ?? BiliClient()
        #endif
        self.client = client
        history = WatchHistory(client: client)
        watchLater = WatchLaterStore(client: client)
        downloads = DownloadStore(client: client)
        #if DEBUG
            let localPeopleCache = suppliedClient == nil && !DemoFixtures.enabled && !InteractionRegression.enabled
                && ProcessInfo.processInfo.environment["BILIGHT_ISOLATED_TESTS"] != "1"
        #else
            let localPeopleCache = suppliedClient == nil
        #endif
        followedPeople = FollowedPeopleSearch(cache: localPeopleCache ? FollowedPeopleCache() : nil)
        watchLater.onError = { [weak self] in self?.handle($0) }
        dynamicLikes.onChange = { [weak self] in self?.objectWillChange.send() }
        commentLikes.onChange = { [weak self] in self?.objectWillChange.send() }
        dynamicLikes.onError = { [weak self] in self?.handle($0) }
        commentLikes.onError = { [weak self] in self?.handle($0) }
        following.likeReadVersion = { [weak self] in self?.dynamicLikes.revision ?? 0 }
        following.didRead = { [weak self] posts, version in
            for post in posts { self?.recordDynamic(post, readVersion: version, fromFeed: true) }
        }
    }
    func restore() async {
        downloads.restoreLocalAccount()
        do {
            let value = try await client.restore()
            if value == nil { downloads.account(nil) }
            update(value)
            if value != nil { downloads.resumeInterrupted() }
            accountError = nil
        } catch { accountError = error.localizedDescription }
        restoring = false
    }
    func update(_ value: User?) {
        let changed = user?.mid != value?.mid
        user = value
        followedPeople.account(value?.mid)
        if changed {
            shareVideo = nil
            following.account(value?.mid)
            history.account(value?.mid)
            watchLater.account(value?.mid)
            downloads.account(value?.mid)
            relations = [:]
            dynamics = [:]
            for task in dynamicLikeRechecks.values { task.cancel() }
            dynamicLikeRechecks.removeAll(); confirmedDynamicLikes.removeAll()
            dynamicLikes.reset(); commentLikes.reset()
            path = []
            accountPath = []
            if value == nil { showAccount = false }
            accountGeneration = UUID()
        }
        if let value { people[value.mid] = value }
    }
    func login(_ cookies: [HTTPCookie]) async throws {
        let value = try await client.acceptLogin(cookies)
        try Task.checkCancellation()
        update(value)
        showLogin = false
        accountError = nil
    }
    func logout() async {
        watchLater.account(nil)
        await client.logout()
        downloads.account(nil)
        update(nil)
        accountError = nil
        showAccount = false
    }
    func openSearchHome() {
        showAccount = false
        path = []
        searchHomeRequest = UUID()
    }
    func register(_ user: User) { people[user.mid] = user }
    func navigate(_ route: Route) {
        if showAccount { accountPath.append(route) } else { path.append(route) }
    }
    func open(_ user: User) {
        register(user)
        navigate(.creator(user.mid))
    }
    func open(_ video: Video) {
        videos[video.bvid] = video
        people[video.owner.mid] = video.owner
        navigate(.video(video.bvid, 1, 0))
    }
    func open(_ item: WatchLaterItem) {
        guard let video = item.video else { return }
        videos[video.bvid] = video
        register(video.owner)
        navigate(.watchLaterVideo(video.bvid, item.cid, item.progress))
    }
    func open(_ collection: CreatorCollection) {
        catalogs[collection.id + "-\(collection.mid)"] = collection
        navigate(.collection(collection.mid, collection.kind, collection.number))
    }
    func open(_ post: DynamicPost) {
        dynamics[post.id] = post
        navigate(.dynamic(post.id))
    }
    func dynamicLikeState(_ post: DynamicPost) -> LikeState {
        dynamicLikes.state(post.id, fallback: LikeState(liked: post.liked, likes: post.likes))
    }
    func recordDynamic(_ post: DynamicPost, readVersion: Int, fromFeed: Bool = false) {
        guard dynamicLikes.canRecord(post.id, readVersion: readVersion) else { return }
        let state = LikeState(liked: post.liked, likes: post.likes)
        if fromFeed, confirmedDynamicLikes.contains(post.id), dynamicLikes.confirmed[post.id] != state {
            recheckDynamicLike(post.id, readVersion: readVersion)
            return
        }
        dynamics[post.id] = post
        dynamicLikes.record(post.id, state: state)
    }
    private func recheckDynamicLike(_ id: String, readVersion: Int) {
        guard dynamicLikeRechecks[id] == nil else { return }
        let generation = accountGeneration
        dynamicLikeRechecks[id] = Task { [weak self] in
            guard let self else { return }
            defer { if accountGeneration == generation { dynamicLikeRechecks[id] = nil } }
            do {
                let post = try await client.dynamic(id, strictLikes: true)
                guard accountGeneration == generation, !Task.isCancelled, dynamicLikes.canRecord(id, readVersion: readVersion) else { return }
                recordDynamic(post, readVersion: readVersion)
                following.updateLike(id, state: dynamicLikeState(post))
                dynamicLikes.setError(nil, for: id)
            } catch is CancellationError { return } catch {
                guard accountGeneration == generation, !Task.isCancelled, dynamicLikes.canRecord(id, readVersion: readVersion) else { return }
                dynamicLikes.setError(error.localizedDescription, for: id)
                handle(error)
            }
        }
    }
    func toggleDynamicLike(_ post: DynamicPost) {
        guard user != nil else { showLogin = true; return }
        let id = post.id
        let generation = accountGeneration
        dynamicLikes.toggle(id, fallback: LikeState(liked: post.liked, likes: post.likes)) { [weak self] target in
            guard let self, accountGeneration == generation else { throw CancellationError() }
            let after = try await client.setDynamicLike(id, liked: target)
            try Task.checkCancellation()
            guard accountGeneration == generation else { throw CancellationError() }
            confirmedDynamicLikes.insert(id)
            let state = LikeState(liked: after.liked, likes: after.likes)
            dynamics[id] = after; following.updateLike(id, state: state)
            return state
        }
    }
    func recordCommentLikes(_ comments: [Comment], oid: String, type: Int, readVersion: Int) {
        for comment in comments {
            let key = CommentLikeKey(oid: oid, type: type, id: comment.id)
            guard commentLikes.confirmed[key] != nil, commentLikes.canRecord(key, readVersion: readVersion) else { continue }
            commentLikes.record(key, state: LikeState(liked: comment.liked, likes: comment.likes))
        }
    }
    func toggleCommentLike(_ comment: Comment, channel: CommentChannel) {
        guard let user else { showLogin = true; return }
        let key = CommentLikeKey(oid: channel.oid, type: channel.type, id: comment.id)
        commentLikes.toggle(key, fallback: LikeState(liked: comment.liked, likes: comment.likes)) { [client] target in
            let after = try await client.setCommentLike(channel: channel, actorMid: user.mid, rpid: comment.id, liked: target)
            return LikeState(liked: after.liked, likes: after.likes)
        }
    }
    func readRelation(_ mid: Int) async {
        guard user != nil, user?.mid != mid else { return }
        let generation = accountGeneration
        do {
            let relation = try await client.relation(mid)
            guard user != nil, accountGeneration == generation else { return }
            relations[mid] = relation
        } catch { /* Follow button performs a fresh, visible check before any write. */  }
    }
    func follow(_ mid: Int, following: Bool) async throws {
        guard user != nil else {
            showLogin = true
            return
        }
        guard !followBusy.contains(mid) else { return }
        followBusy.insert(mid)
        let generation = accountGeneration
        defer { if accountGeneration == generation { followBusy.remove(mid) } }
        let after = try await client.setFollowing(mid, following: following)
        guard accountGeneration == generation else { throw CancellationError() }
        relations[mid] = after
        if !after.following { self.following.removeAuthor(mid); followedPeople.remove(mid) }
    }
    func handle(_ error: Error) {
        if (error as? BiliFailure)?.code == "-101" {
            update(nil)
            accountError = "登录已失效，请重新验证。"
        }
    }
}
enum Route: Hashable {
    case video(String, Int, Double)
    case watchLaterVideo(String, Int, Double)
    case creator(Int)
    case dynamic(String)
    case collection(Int, CollectionKind, Int)
    case history
    case followedPeople(Bool)
    case favoriteFolders
    case watchLater
    case favoriteFolder(FavoriteFolder)
    case downloads
    case offline(UUID)
}
extension Color {
    static let biliBackground = Color(uiColor: .systemBackground)
    static let biliPink = biliAdaptive(UIColor(red: 0.84, green: 0.24, blue: 0.43, alpha: 1),
                                      UIColor(red: 0.96, green: 0.55, blue: 0.67, alpha: 1))
    static let biliBlue = biliAdaptive(UIColor(red: 0.08, green: 0.60, blue: 0.77, alpha: 1),
                                      UIColor(red: 0.49, green: 0.78, blue: 0.90, alpha: 1))
    static let biliSoft = biliAdaptive(UIColor(red: 0.97, green: 0.975, blue: 0.985, alpha: 1),
                                      .secondarySystemBackground)
    static let biliMuted = biliAdaptive(UIColor(red: 0.48, green: 0.51, blue: 0.57, alpha: 1),
                                       UIColor(red: 0.67, green: 0.68, blue: 0.73, alpha: 1))
    static let biliPlaceholder = biliAdaptive(.placeholderText,
                                             UIColor(red: 0.63, green: 0.65, blue: 0.70, alpha: 1))
    static let biliPanel = biliAdaptive(.white, UIColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1))
    static let biliProminent = biliAdaptive(UIColor(red: 0.84, green: 0.24, blue: 0.43, alpha: 1),
                                           UIColor(red: 0.64, green: 0.16, blue: 0.34, alpha: 1))
    static let biliReply = biliAdaptive(UIColor(red: 77 / 255, green: 131 / 255, blue: 161 / 255, alpha: 1),
                                       UIColor(red: 0.49, green: 0.78, blue: 0.90, alpha: 1))

    private static func biliAdaptive(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
    }
}
