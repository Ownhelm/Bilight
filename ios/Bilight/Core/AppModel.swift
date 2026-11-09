import SwiftUI
import UIKit

@MainActor final class AppModel: ObservableObject {
    let client: BiliClient
    let downloads: DownloadStore
    let history: WatchHistory
    let followedPeople: FollowedPeopleSearch
    let following = FollowingModel()
    @Published var user: User?
    @Published var restoring = true
    @Published var accountError: String?
    @Published var showLogin = false
    @Published var showAccount = false
    @Published var shareVideo: VideoShareInfo?
    @Published var path: [Route] = []
    @Published var accountPath: [Route] = []
    @Published var relations: [Int: Relation] = [:]
    @Published var followBusy = Set<Int>()
    @Published var accountGeneration = UUID()
    @Published var dynamicLikeErrors: [String: String] = [:]
    @Published var dynamicLikeStates: [String: DynamicLikeState] = [:]
    @Published var dynamicLikePending: [String: Bool] = [:]
    private(set) var dynamicLikeRevision = 0
    private var dynamicLikeVersions: [String: Int] = [:]
    private var dynamicLikeTasks: [String: Task<Void, Never>] = [:]
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
        downloads = DownloadStore(client: client)
        #if DEBUG
            let localPeopleCache = suppliedClient == nil && !DemoFixtures.enabled && !InteractionRegression.enabled
                && ProcessInfo.processInfo.environment["BILIGHT_ISOLATED_TESTS"] != "1"
        #else
            let localPeopleCache = suppliedClient == nil
        #endif
        followedPeople = FollowedPeopleSearch(cache: localPeopleCache ? FollowedPeopleCache() : nil)
        following.likeReadVersion = { [weak self] in self?.dynamicLikeRevision ?? 0 }
        following.didRead = { [weak self] posts, version in for post in posts { self?.recordDynamic(post, readVersion: version) } }
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
            downloads.account(value?.mid)
            relations = [:]
            dynamics = [:]
            for task in dynamicLikeTasks.values { task.cancel() }
            dynamicLikeTasks = [:]; dynamicLikeErrors = [:]; dynamicLikeStates = [:]; dynamicLikePending = [:]; dynamicLikeVersions = [:]; dynamicLikeRevision = 0
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
        await client.logout()
        downloads.account(nil)
        update(nil)
        accountError = nil
        showAccount = false
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
    func open(_ collection: CreatorCollection) {
        catalogs[collection.id + "-\(collection.mid)"] = collection
        navigate(.collection(collection.mid, collection.kind, collection.number))
    }
    func open(_ post: DynamicPost) {
        dynamics[post.id] = post
        navigate(.dynamic(post.id))
    }
    func dynamicLikeState(_ post: DynamicPost) -> DynamicLikeState {
        dynamicLikeStates[post.id] ?? DynamicLikeState(liked: post.liked, likes: post.likes)
    }
    func recordDynamic(_ post: DynamicPost, readVersion: Int) {
        dynamics[post.id] = post
        guard dynamicLikePending[post.id] == nil, (dynamicLikeVersions[post.id] ?? 0) <= readVersion else { return }
        dynamicLikeStates[post.id] = DynamicLikeState(liked: post.liked, likes: post.likes)
    }
    func toggleDynamicLike(_ post: DynamicPost) {
        guard user != nil else { showLogin = true; return }
        guard dynamicLikePending[post.id] == nil else { return }
        let generation = accountGeneration, target = !dynamicLikeState(post).liked
        dynamicLikeRevision += 1; dynamicLikeVersions[post.id] = dynamicLikeRevision
        dynamicLikePending[post.id] = target; dynamicLikeErrors[post.id] = nil
        dynamicLikeTasks[post.id] = Task { [weak self] in
            guard let self else { return }
            defer { if accountGeneration == generation { dynamicLikePending[post.id] = nil; dynamicLikeTasks[post.id] = nil } }
            do {
                let after = try await client.setDynamicLike(post.id, liked: target)
                try Task.checkCancellation()
                guard accountGeneration == generation else { return }
                dynamicLikeRevision += 1; dynamicLikeVersions[post.id] = dynamicLikeRevision
                let state = DynamicLikeState(liked: after.liked, likes: after.likes)
                dynamicLikeStates[post.id] = state; dynamics[post.id] = after; following.updateLike(post.id, state: state)
            } catch is CancellationError { return } catch {
                if accountGeneration == generation { dynamicLikeErrors[post.id] = error.localizedDescription; handle(error) }
            }
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
    case creator(Int)
    case dynamic(String)
    case collection(Int, CollectionKind, Int)
    case history
    case followedPeople(Bool)
    case favoriteFolders
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
