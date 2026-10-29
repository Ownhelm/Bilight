import SwiftUI

@MainActor final class AppModel: ObservableObject {
    let client: BiliClient
    let downloads: DownloadStore
    let history: WatchHistory
    let following = FollowingModel()
    @Published var user: User?
    @Published var restoring = true
    @Published var accountError: String?
    @Published var showLogin = false
    @Published var showAccount = false
    @Published var path: [Route] = []
    @Published var accountPath: [Route] = []
    @Published var relations: [Int: Relation] = [:]
    @Published var followBusy = Set<Int>()
    @Published var accountGeneration = UUID()
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
        if changed {
            following.account(value?.mid)
            history.account(value?.mid)
            downloads.account(value?.mid)
            relations = [:]
            dynamics = [:]
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
        defer { followBusy.remove(mid) }
        let after = try await client.setFollowing(mid, following: following)
        relations[mid] = after
        if !after.following { self.following.removeAuthor(mid) }
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
    static let biliPink = Color(red: 0.84, green: 0.24, blue: 0.43)
    static let biliBlue = Color(red: 0.08, green: 0.60, blue: 0.77)
    static let biliSoft = Color(red: 0.97, green: 0.975, blue: 0.985)
    static let biliMuted = Color(red: 0.48, green: 0.51, blue: 0.57)
}
