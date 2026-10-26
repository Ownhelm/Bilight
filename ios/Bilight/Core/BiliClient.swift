import Foundation

actor BiliClient {
    let http: BiliHTTP
    private var verifiedRelations: [Int: (Relation, Date)] = [:]
    private var verificationVersion: UUID?
    private var verificationEpoch = UUID()
    private var followWrites: [Int: (Bool, Task<Relation, Error>)] = [:]
    private var supportWrites: [String: (id: UUID, session: UUID, action: VideoWrite, task: Task<VideoEngagement, Error>)] = [:]
    private var uncertainSupport: [String: UUID] = [:]
    private let followingTimeout: Duration
    init(http: BiliHTTP = BiliHTTP(), followingTimeout: Duration = .seconds(20)) {
        self.http = http
        self.followingTimeout = followingTimeout
    }
    func restore() async throws -> User? {
        try await http.restore()
        return try await currentUser()
    }
    func currentUser() async throws -> User? {
        do {
            let data = try await http.request("/x/web-interface/nav")
            return data["isLogin"] as? Bool == true && int(data["mid"]) > 0 ? User.map(data) : nil
        } catch let error as BiliFailure where error.code == "-101" { return nil }
    }
    func logout() async {
        invalidateFollowing()
        cancelSupportWrites()
        for write in followWrites.values { write.1.cancel() }
        followWrites = [:]
        await http.logout()
    }
    func acceptLogin(_ cookies: [HTTPCookie]) async throws -> User {
        invalidateFollowing()
        cancelSupportWrites()
        return try await http.acceptLogin(cookies)
    }
    private func cancelSupportWrites() {
        for write in supportWrites.values { write.task.cancel() }
        supportWrites = [:]
        uncertainSupport = [:]
    }
    func videoEngagement(_ bvid: String) async throws -> VideoEngagement {
        let version = await http.version()
        let state = try await readEngagement(bvid, version: version)
        // A successful deliberate refresh is required after an uncertain write.
        uncertainSupport[bvid] = nil
        NativeTrace.mark(.supportReady, ["complete": state.complete ? 1 : 0])
        return state
    }
    private func readEngagement(_ bvid: String, version: UUID) async throws -> VideoEngagement {
        guard validBVID(bvid) else { throw BiliFailure.invalid }
        _ = try await http.csrf()
        let data = try await http.request(
            "/x/web-interface/archive/relation", query: ["bvid": bvid],
            referer: "https://www.bilibili.com/video/\(bvid)")
        try await http.check(version)
        return try VideoEngagement.map(data)
    }
    func triple(_ bvid: String) async throws -> VideoEngagement {
        try await writeVideo(bvid, action: .triple)
    }
    func writeVideo(_ bvid: String, action: VideoWrite) async throws -> VideoEngagement {
        guard validBVID(bvid) else { throw BiliFailure.invalid }
        let version = await http.version()
        if let pending = supportWrites[bvid], pending.session == version {
            guard pending.action == action else { throw BiliFailure(code: "INTERACTION_BUSY", message: "这个视频的互动正在处理中。") }
            return try await pending.task.value
        }
        guard uncertainSupport[bvid] != version else {
            throw BiliFailure(code: action == .triple ? "TRIPLE_UNCONFIRMED" : "INTERACTION_UNCONFIRMED", message: "请先刷新互动状态，再继续操作。")
        }
        let id = UUID()
        let task = Task<VideoEngagement, Error> {
            if action == .triple { return try await self.performTriple(bvid, version: version) }
            return try await self.performVideoWrite(bvid, action: action, version: version)
        }
        supportWrites[bvid] = (id, version, action, task)
        defer { if supportWrites[bvid]?.id == id { supportWrites[bvid] = nil } }
        return try await task.value
    }
    private func performVideoWrite(_ bvid: String, action: VideoWrite, version: UUID) async throws -> VideoEngagement {
        let before = try await readEngagement(bvid, version: version)
        let csrf = try await http.csrf()
        let path: String
        var form = ["bvid": bvid, "csrf": csrf]
        switch action {
        case .like(let liked):
            if before.liked == liked { return before }
            path = "/x/web-interface/archive/like"; form["like"] = liked ? "1" : "2"
        case .coin(let target, let like):
            let detail = try await video(bvid)
            guard let limit = detail.coinLimit, (1...limit).contains(target) else { throw BiliFailure(code: "COIN_LIMIT", message: "超过本视频可投的硬币数量。") }
            if before.coins >= target { return before }
            path = "/x/web-interface/coin/add"
            form["multiply"] = "\(target - before.coins)"; form["select_like"] = like ? "1" : "0"
        case .favorite(let selected):
            let folders = try await videoFavoriteFolders(bvid)
            let ids = Set(selected)
            guard ids.count <= 100, ids.isSubset(of: Set(folders.map(\.id))) else { throw BiliFailure(code: "FOLDERS_CHANGED", message: "收藏夹已变化，请重新选择。") }
            let add = folders.filter { ids.contains($0.id) && !$0.selected }
            let remove = folders.filter { !ids.contains($0.id) && $0.selected }
            guard !add.contains(where: { $0.count >= $0.capacity }) else { throw BiliFailure(code: "FOLDER_FULL", message: "所选收藏夹已满。") }
            if add.isEmpty && remove.isEmpty { return before }
            let detail = try await video(bvid)
            path = "/x/v3/fav/resource/deal"
            form = ["rid": "\(detail.video.aid)", "type": "2", "add_media_ids": add.map { "\($0.id)" }.joined(separator: ","), "del_media_ids": remove.map { "\($0.id)" }.joined(separator: ","), "csrf": csrf]
        case .triple: return try await performTriple(bvid, version: version)
        }
        try await http.ensureDevice(); try await http.check(version); try Task.checkCancellation()
        do {
            _ = try await http.request(path, form: form, referer: "https://www.bilibili.com/video/\(bvid)")
            for delay in [0, 150, 350] {
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                try await http.check(version)
                let state = try await readEngagement(bvid, version: version)
                switch action {
                case .like(let liked): if state.liked == liked { return state }
                case .coin(let target, let like): if state.coins >= target && (!like || state.liked) { return state }
                case .favorite(let selected):
                    let folders = try await videoFavoriteFolders(bvid)
                    if state.favorited == !selected.isEmpty && folders.allSatisfy({ $0.selected == selected.contains($0.id) }) { return state }
                case .triple: break
                }
            }
            throw BiliFailure(code: "INTERACTION_UNCONFIRMED", message: "结果暂未确认，请先刷新状态，避免重复操作。")
        } catch {
            try await http.check(version)
            if (error as? BiliFailure)?.code == "-101" { throw error }
            uncertainSupport[bvid] = version
            throw BiliFailure(code: "INTERACTION_UNCONFIRMED", message: error.localizedDescription + " 请先刷新状态。")
        }
    }
    func videoFavoriteFolders(_ bvid: String) async throws -> [VideoFavoriteFolder] {
        let version = await http.version()
        _ = try await http.csrf()
        guard let user = try await currentUser() else { throw BiliFailure(code: "-101", message: "请先登录。") }
        let detail = try await video(bvid)
        let data = try await http.request("/x/v3/fav/folder/created/list-all", query: ["up_mid": "\(user.mid)", "rid": "\(detail.video.aid)", "type": "2"])
        try await http.check(version)
        guard let count = data["count"] as? NSNumber, (data["list"] is [JSON] || (count.intValue == 0 && data["list"] is NSNull)), count.intValue == list(data["list"]).count else { throw BiliFailure.invalid }
        return try list(data["list"]).map { folder in
            guard int(folder["id"]) > 0, int(folder["mid"]) == user.mid, [0, 1].contains(int(folder["fav_state"])), folder["fav_state"] is NSNumber, folder["media_count"] is NSNumber else { throw BiliFailure.invalid }
            let attr = int(folder["attr"]), isDefault = attr & 2 == 0
            return VideoFavoriteFolder(id: int(folder["id"]), title: clean(folder["title"]), count: int(folder["media_count"]), selected: int(folder["fav_state"]) == 1, isPrivate: attr & 1 == 1, capacity: int(folder["max_count"]) > 0 ? int(folder["max_count"]) : isDefault ? 50000 : 1000)
        }.sorted { $0.selected && !$1.selected }
    }
    func videoStatistics(_ bvid: String) async throws -> VideoStatistics {
        guard validBVID(bvid) else { throw BiliFailure.invalid }
        let data = try await http.request("/x/web-interface/wbi/view", query: ["bvid": bvid], wbi: true)
        guard data["bvid"] as? String == bvid else { throw BiliFailure.invalid }
        return try VideoStatistics.map(obj(data["stat"]))
    }
    private func performTriple(_ bvid: String, version: UUID) async throws -> VideoEngagement {
        let before = try await readEngagement(bvid, version: version)
        if before.complete { return before }
        try await http.ensureDevice()
        try Task.checkCancellation()
        try await http.check(version)
        let csrf = try await http.csrf()
        let response: JSON
        do {
            // One official three-in-one request. Never retry a write or synthesize device identifiers.
            response = try await http.request(
                "/x/web-interface/archive/like/triple",
                form: ["bvid": bvid, "csrf": csrf], referer: "https://www.bilibili.com/video/\(bvid)")
            guard response["like"] is Bool, response["coin"] is Bool, response["fav"] is Bool else {
                throw BiliFailure.invalid
            }
        } catch {
            try await http.check(version)
            if (error as? BiliFailure)?.code == "-101" { throw error }
            uncertainSupport[bvid] = version
            throw BiliFailure(code: "TRIPLE_UNCONFIRMED", message: error.localizedDescription + " 请刷新三连状态确认结果。")
        }
        let reportedComplete =
            response["like"] as? Bool == true && response["coin"] as? Bool == true && response["fav"] as? Bool == true
        for delay in [0, 200, 500] {
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            try await http.check(version)
            do {
                let state = try await readEngagement(bvid, version: version)
                if state.complete || !reportedComplete { return state }
            } catch {
                try await http.check(version)
                if (error as? BiliFailure)?.code == "-101" { throw error }
            }
        }
        uncertainSupport[bvid] = version
        throw BiliFailure(code: "TRIPLE_UNCONFIRMED", message: "三连已提交，请刷新状态确认结果。")
    }
    func search(_ keyword: String, users: Bool, page: Int) async throws -> SearchResult {
        try await http.ensureDevice()
        let data = try await http.request(
            "/x/web-interface/wbi/search/type",
            query: [
                "keyword": keyword, "search_type": users ? "bili_user" : "video", "page": "\(page)", "page_size": "30",
                "order": users ? "0" : "totalrank",
            ], wbi: true)
        guard data["result"] is [Any] else { throw BiliFailure.invalid }
        let values = list(data["result"])
        let videos = users ? [] : values.compactMap { Video.map($0) }
        let creators =
            users
            ? values.filter { int($0["mid"]) > 0 }.map {
                User.map([
                    "mid": $0["mid"] ?? 0, "uname": $0["uname"] ?? "", "upic": $0["upic"] ?? "",
                    "usign": $0["usign"] ?? "", "fans": $0["fans"] ?? 0,
                ])
            } : []
        return SearchResult(
            videos: unique(videos), users: creators,
            hasMore: int(data["numPages"]) > 0 ? page < int(data["numPages"]) : page * 30 < int(data["numResults"]))
    }
    func creator(_ mid: Int) async throws -> User {
        try await http.ensureDevice()
        let data = try await http.request(
            "/x/space/wbi/acc/info", query: ["mid": "\(mid)"], wbi: true, referer: "https://space.bilibili.com/\(mid)")
        guard int(data["mid"]) == mid else { throw BiliFailure.invalid }
        return User.map(data)
    }
    func creatorVideos(_ mid: Int, page: Int, owner: User) async throws -> Page<Video> {
        let data = try await http.request(
            "/x/space/wbi/arc/search",
            query: [
                "mid": "\(mid)", "pn": "\(page)", "ps": "30", "order": "pubdate", "tid": "0", "keyword": "",
                "platform": "web", "web_location": "1550101", "order_avoided": "true",
            ], wbi: true, referer: "https://space.bilibili.com/\(mid)/upload/video")
        guard obj(data["list"])["vlist"] is [Any] else { throw BiliFailure.invalid }
        return Page(
            items: unique(list(obj(data["list"])["vlist"]).compactMap { Video.map($0, owner: owner) }),
            hasMore: page * 30 < int(obj(data["page"])["count"]))
    }
    func collections(_ mid: Int, page: Int) async throws -> Page<CreatorCollection> {
        let data = try await http.request(
            "/x/polymer/web-space/seasons_series_list",
            query: ["mid": "\(mid)", "page_num": "\(page)", "page_size": "12"],
            referer: "https://space.bilibili.com/\(mid)/lists")
        let lists = obj(data["items_lists"])
        let paging = obj(lists["page"])
        guard lists["seasons_list"] is [Any], lists["series_list"] is [Any], paging["total"] is NSNumber else {
            throw BiliFailure(code: "COLLECTIONS_UNAVAILABLE", message: "合集和列表暂时无法完整读取，请重试。")
        }
        let seasons = try list(lists["seasons_list"]).map { try CreatorCollection.map($0, kind: .season, mid: mid) }
        let series = try list(lists["series_list"]).map { try CreatorCollection.map($0, kind: .series, mid: mid) }
        return Page(items: seasons + series, hasMore: page * max(1, int(paging["page_size"])) < int(paging["total"]))
    }
    func collection(_ collection: CreatorCollection, page: Int, owner: User) async throws -> Page<Video> {
        let ref = "https://space.bilibili.com/\(collection.mid)/lists"
        let data: JSON
        let meta: JSON
        if collection.kind == .season {
            data = try await http.request(
                "/x/polymer/web-space/seasons_archives_list",
                query: [
                    "mid": "\(collection.mid)", "season_id": "\(collection.number)", "sort_reverse": "false",
                    "page_num": "\(page)", "page_size": "30",
                ], referer: ref)
            meta = data
        } else {
            async let info = http.request(
                "/x/series/series", query: ["series_id": "\(collection.number)"], referer: ref)
            async let videos = http.request(
                "/x/series/archives",
                query: [
                    "mid": "\(collection.mid)", "series_id": "\(collection.number)", "only_normal": "true",
                    "sort": "desc", "pn": "\(page)", "ps": "30",
                ], referer: ref)
            (meta, data) = try await (info, videos)
        }
        let verified = try CreatorCollection.map(meta, kind: collection.kind, mid: collection.mid)
        guard verified.number == collection.number, data["archives"] is [Any] else { throw BiliFailure.invalid }
        let paging = obj(data["page"])
        let size = max(1, int(paging["page_size"] ?? paging["size"] ?? 30))
        let total = int(paging["total"] ?? collection.count)
        return Page(
            items: unique(list(data["archives"]).compactMap { Video.map($0, owner: owner) }),
            hasMore: page * size < total)
    }
    func relation(_ mid: Int) async throws -> Relation {
        _ = try await http.csrf()
        return try Relation.map(await http.request("/x/relation", query: ["fid": "\(mid)"]))
    }
    func setFollowing(_ mid: Int, following: Bool) async throws -> Relation {
        if let pending = followWrites[mid] {
            guard pending.0 == following else { throw BiliFailure(code: "BUSY", message: "关注操作正在处理中。") }
            return try await pending.1.value
        }
        let task = Task<Relation, Error> {
            let version = await self.http.version()
            let csrf = try await self.http.csrf()
            guard let user = try await self.currentUser(), user.mid != mid else {
                throw BiliFailure(code: "SELF_FOLLOW", message: "不能关注自己。")
            }
            let before = try await self.relation(mid)
            try await self.http.check(version)
            if before.following == following { return before }
            guard !before.blocked else { throw BiliFailure(code: "BLOCKED", message: "该用户在黑名单中，请先在 B 站解除拉黑。") }
            try await self.http.ensureDevice()
            try await self.http.check(version)
            _ = try await self.http.request(
                "/x/relation/modify",
                form: ["fid": "\(mid)", "act": following ? "1" : "2", "re_src": "11", "csrf": csrf])
            self.invalidateFollowing()
            for delay in [0, 150, 350] {
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                try await self.http.check(version)
                let after = try await self.relation(mid)
                try await self.http.check(version)
                if after.following == following { return after }
            }
            throw BiliFailure(code: "FOLLOW_UNCONFIRMED", message: "关注请求已提交，请刷新确认结果，避免重复操作。")
        }
        followWrites[mid] = (following, task)
        defer { followWrites[mid] = nil }
        return try await task.value
    }
    func invalidateFollowing() {
        verifiedRelations = [:]
        verificationVersion = nil
        verificationEpoch = UUID()
    }
    private func verifiedAuthors(_ authors: Set<Int>, version: UUID) async throws -> Set<Int> {
        if verificationVersion != version {
            verifiedRelations = [:]
            verificationVersion = version
        }
        verifiedRelations = verifiedRelations.filter { $0.value.1 > Date() }
        let epoch = verificationEpoch
        let missing = authors.filter { verifiedRelations[$0] == nil }.sorted()
        for start in stride(from: 0, to: missing.count, by: 20) {
            let batch = Array(missing[start..<min(start + 20, missing.count)])
            var values: [Int: Relation] = [:]
            do {
                let data = try await http.request(
                    "/x/relation/relations", query: ["fids": batch.map(String.init).joined(separator: ",")])
                NativeTrace.mark(.relationsRead, ["requested": batch.count, "returned": data.count])
                for (key, value) in data {
                    guard let mid = Int(key), batch.contains(mid), value is JSON else { throw BiliFailure.invalid }
                    let item = obj(value)
                    guard item["mid"] == nil || int(item["mid"]) == mid else { throw BiliFailure.invalid }
                    values[mid] = try Relation.map(item)
                }
                // This API returns followed users; absent requested UIDs are not followed.
                for mid in batch where values[mid] == nil {
                    values[mid] = Relation(following: false, mutual: false, blocked: false)
                }
            } catch let failure as BiliFailure where ["404", "-400"].contains(failure.code) {
                // Compatibility fallback uses the same real relationship API, with bounded concurrency.
                for index in stride(from: 0, to: batch.count, by: 3) {
                    let next = Array(batch[index..<min(index + 3, batch.count)])
                    let results = try await withThrowingTaskGroup(of: (Int, Relation).self) { group in
                        for mid in next { group.addTask { (mid, try await self.relation(mid)) } }
                        var results: [(Int, Relation)] = []
                        for try await result in group { results.append(result) }
                        return results
                    }
                    for (mid, relation) in results { values[mid] = relation }
                }
            }
            try Task.checkCancellation()
            try await http.check(version)
            guard verificationEpoch == epoch else { throw CancellationError() }
            for (mid, relation) in values { verifiedRelations[mid] = (relation, Date().addingTimeInterval(60)) }
        }
        return Set(authors.filter { verifiedRelations[$0]?.0.following == true })
    }
    func following(mid: Int, cursor: String?) async throws -> Page<DynamicPost> {
        let timeout = followingTimeout
        return try await withThrowingTaskGroup(of: Page<DynamicPost>.self) { group in
            group.addTask { try await self.loadFollowing(mid: mid, cursor: cursor) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BiliFailure(code: "FOLLOW_TIMEOUT", message: "关注动态读取超时，请重试。")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
    private func loadFollowing(mid: Int, cursor: String?) async throws -> Page<DynamicPost> {
        let version = await http.version()
        let epoch = verificationEpoch
        guard let identity = try await currentUser(), identity.mid == mid else {
            throw BiliFailure(code: "-101", message: "请登录后查看关注动态。")
        }
        _ = try await http.csrf()
        try await http.ensureDevice()
        let data = try await http.request(
            "/x/polymer/web-dynamic/v1/feed/all",
            query: ["type": "all", "platform": "web", "features": "itemOpusStyle,opusBigCover,ugcDelete"]
                .merging(cursor.map { ["offset": $0] } ?? [:], uniquingKeysWith: { $1 }))
        try Task.checkCancellation()
        try await http.check(version)
        guard verificationEpoch == epoch else { throw CancellationError() }
        guard data["has_more"] is NSNumber else { throw BiliFailure.invalid }
        let items: [JSON]
        if let values = data["items"] as? [JSON] {
            items = values
        } else if (data["items"] == nil || data["items"] is NSNull) && int(data["has_more"]) == 0 {
            items = []
        } else {
            throw BiliFailure.invalid
        }
        let candidates = Self.dynamicItems(items)
        NativeTrace.mark(.followingReceived, ["items": items.count])
        NativeTrace.mark(
            .followingParsed, ["eligible": candidates.count, "authors": Set(candidates.map { $0.author.mid }).count])
        // Verify outer authors only. Originals inside their deliberate reposts retain attribution.
        let confirmed = try await verifiedAuthors(Set(candidates.map { $0.author.mid }), version: version)
        try Task.checkCancellation()
        try await http.check(version)
        guard verificationEpoch == epoch else { throw CancellationError() }
        let posts = candidates.filter { confirmed.contains($0.author.mid) }
        let more = int(data["has_more"]) == 1
        let next = clean(data["offset"])
        if more && (next.isEmpty || next == cursor) {
            throw BiliFailure(code: "CURSOR_LOOP", message: "动态分页暂时异常，请刷新最新。")
        }
        var counts = ["confirmed": confirmed.count, "posts": posts.count]
        for post in posts {
            let key: String
            switch post.content {
            case .video: key = "videos"
            case .pictures: key = "pictures"
            case .repost: key = "reposts"
            case .text: key = "text"
            case .link: key = "links"
            case .unavailable: key = "unavailable"
            }
            counts[key, default: 0] += 1
        }
        NativeTrace.mark(.followingVerified, counts)
        return Page(items: posts, hasMore: more, cursor: more ? next : nil)
    }
    nonisolated static func dynamicItems(_ items: [JSON]) -> [DynamicPost] {
        var seen = Set<String>()
        return items.compactMap { DynamicPost.map($0) }.filter { seen.insert($0.id).inserted }
    }
    func dynamic(_ id: String) async throws -> DynamicPost {
        guard DynamicPost.validID(id) else { throw BiliFailure.invalid }
        let version = await http.version()
        try await http.ensureDevice()
        let data = try await http.request(
            "/x/polymer/web-dynamic/v1/detail",
            query: ["id": id, "platform": "web", "features": "itemOpusStyle,opusBigCover,ugcDelete"])
        try await http.check(version)
        guard let post = DynamicPost.map(obj(data["item"])), post.id == id else { throw BiliFailure.invalid }
        return post
    }
    func video(_ bvid: String, known: Video? = nil) async throws -> VideoDetail {
        guard validBVID(bvid) else { throw BiliFailure(code: "INVALID_VIDEO", message: "视频 BV 号不正确。") }
        let data: JSON
        do { data = try await http.request("/x/web-interface/wbi/view", query: ["bvid": bvid], wbi: true) } catch let error
            as BiliFailure where ["412", "-352", "-412"].contains(error.code)
        {
            let summary: Video?
            if let known, known.bvid == bvid {
                summary = known
            } else {
                summary = try await search(bvid, users: false, page: 1).videos.first(where: { $0.bvid == bvid })
            }
            guard let summary else { throw error }
            let pages = try await http.requestArray("/x/player/pagelist", query: ["bvid": bvid])
            let parts = pages.map {
                VideoPart(
                    cid: int($0["cid"]), page: int($0["page"]), title: clean($0["part"]), duration: num($0["duration"]))
            }.filter { $0.cid > 0 }
            guard !parts.isEmpty else { throw BiliFailure.invalid }
            return VideoDetail(
                video: summary, parts: parts, description: "", coinLimit: nil,
                warning: "详细资料暂不可读（\(error.code)），当前使用真实搜索或合集记录及公开分 P 数据打开。")
        }
        guard let video = Video.map(data), video.bvid == bvid, data["pages"] is [Any] else { throw BiliFailure.invalid }
        let parts = list(data["pages"]).map {
            VideoPart(
                cid: int($0["cid"]), page: int($0["page"]), title: clean($0["part"]), duration: num($0["duration"]))
        }.filter { $0.cid > 0 }
        guard !parts.isEmpty else { throw BiliFailure.invalid }
        return VideoDetail(
            video: video, parts: parts, description: clean(data["desc"], limit: 10000),
            coinLimit: [1, 3].contains(int(data["copyright"])) ? 2 : 1, statistics: try? VideoStatistics.map(obj(data["stat"])))
    }
    func playback(_ bvid: String, cid: Int, quality: Int = 127, allowNative: Bool = true) async throws -> Playback {
        let data = try await http.request(
            "/x/player/wbi/playurl",
            query: ["bvid": bvid, "cid": "\(cid)", "qn": "\(quality)", "fnval": "4048", "fnver": "0", "fourk": "1"],
            wbi: true, referer: "https://www.bilibili.com/video/\(bvid)")
        // Prefer a complete native MP4 only when its actual quality meets the best returned DASH track.
        let dashQuality = (try? Self.mapPlayback(data, native: nil, quality: quality))?.quality ?? 0
        let native =
            !allowNative || dashQuality >= 112
            ? nil
            : try? await http.request(
                "/x/player/wbi/playurl",
                query: ["bvid": bvid, "cid": "\(cid)", "qn": "\(quality)", "fnval": "1", "fnver": "0", "fourk": "1"],
                wbi: true, referer: "https://www.bilibili.com/video/\(bvid)")
        try Task.checkCancellation()
        return try Self.mapPlayback(data, native: native, quality: quality)
    }
    static func mapPlayback(_ data: JSON, native: JSON?, quality: Int) throws -> Playback {
        let dash = obj(data["dash"])
        let videos = list(dash["video"]).filter { ($0["codecs"] as? String ?? "").hasPrefix("avc") }
        let audios = list(dash["audio"]).filter { ($0["codecs"] as? String ?? "").hasPrefix("mp4a") }
        let sorted = videos.sorted {
            int($0["id"]) == int($1["id"]) ? int($0["bandwidth"]) > int($1["bandwidth"]) : int($0["id"]) > int($1["id"])
        }
        let lowest = sorted.last.map { int($0["id"]) }
        let selected = sorted.first { int($0["id"]) <= quality } ?? sorted.first { int($0["id"]) == lowest }
        let accepted = data["accept_quality"] as? [Int] ?? []
        let labels = data["accept_description"] as? [String] ?? []
        var qualities = Set(videos.map { int($0["id"]) }).sorted(by: >).map { id -> Quality in
            let index = accepted.firstIndex(of: id)
            return Quality(id: id, label: index.flatMap { $0 < labels.count ? clean(labels[$0]) : nil } ?? "\(id)")
        }
        if let native, (native["format"] as? String ?? "").hasPrefix("mp4") {
            let entries = list(native["durl"])
            let actual = int(native["quality"])
            let candidates = [entries.first?["url"]] + (entries.first?["backup_url"] as? [Any] ?? []).map(Optional.some)
            if entries.count == 1, actual > 0, actual <= quality, actual >= int(selected?["id"]),
                let url = candidates.compactMap({ secureURL($0) }).first(where: MediaLoader.allowed)
            {
                let ids = native["accept_quality"] as? [Int] ?? []
                let descriptions = native["accept_description"] as? [String] ?? []
                let nativeIDs = Set(ids.filter { $0 > 0 } + [actual])
                // MP4 has its own quality ladder; avoid an intermediate DASH-only rung in native playback.
                let higher = qualities.filter { $0.id > (nativeIDs.max() ?? actual) }
                qualities =
                    nativeIDs.map { id in
                        let label =
                            ids.firstIndex(of: id).flatMap { $0 < descriptions.count ? clean(descriptions[$0]) : nil }
                            ?? "\(id)"
                        return Quality(id: id, label: label)
                    } + higher
                qualities.sort { $0.id > $1.id }
                return Playback(
                    quality: actual, qualities: qualities, duration: num(native["timelength"]) / 1000, mp4: url)
            }
        }
        if let video = StreamTrack.map(selected) {
            let audio = StreamTrack.map(audios.sorted { int($0["bandwidth"]) > int($1["bandwidth"]) }.first)
            if !audios.isEmpty && audio == nil { throw BiliFailure.invalid }
            return Playback(
                quality: video.id, qualities: qualities, duration: num(dash["duration"]), video: video, audio: audio)
        }
        let direct = list(data["durl"])
        guard direct.count == 1, let url = secureURL(direct.first?["url"]), MediaLoader.allowed(url) else {
            throw BiliFailure(code: "PLAYBACK_UNAVAILABLE", message: "账号暂时没有可用的 AVC 视频轨道，请检查权限或稍后重试。")
        }
        let actual = int(data["quality"])
        return Playback(
            quality: actual,
            qualities: [
                Quality(
                    id: actual,
                    label: accepted.firstIndex(of: actual).flatMap { $0 < labels.count ? labels[$0] : nil } ?? "当前画质")
            ], duration: num(data["timelength"]) / 1000, mp4: url)
    }
    func subtitles(_ bvid: String, cid: Int) async throws -> [SubtitleTrack] {
        let data = try await http.request("/x/player/wbi/v2", query: ["bvid": bvid, "cid": "\(cid)"], wbi: true)
        return list(obj(data["subtitle"])["subtitles"]).compactMap { data in
            guard let url = secureURL(data["subtitle_url"]), MediaLoader.allowed(url) else { return nil }
            return SubtitleTrack(
                id: int(data["id"]), language: data["lan"] as? String ?? "", label: clean(data["lan_doc"]), url: url)
        }
    }
    func comments(_ aid: Int, cursor: String? = nil) async throws -> Page<Comment> {
        try await comments(oid: "\(aid)", type: 1, cursor: cursor)
    }
    func comments(oid: String, type: Int, cursor: String? = nil) async throws -> Page<Comment> {
        guard DynamicPost.validID(oid), type > 0 else { throw BiliFailure.invalid }
        let pagination = String(
            data: try JSONSerialization.data(withJSONObject: ["offset": cursor ?? ""]), encoding: .utf8)!
        let data = try await http.request(
            "/x/v2/reply/wbi/main",
            query: [
                "type": "\(type)", "oid": oid, "mode": "2", "pagination_str": pagination, "plat": "1",
                "web_location": "1315875",
            ], wbi: true)
        let paging = obj(data["cursor"])
        let end = int(paging["is_end"]) == 1
        guard data["replies"] is [Any] || (end && int(paging["all_count"]) == 0) else {
            throw BiliFailure(
                code: "COMMENTS_UNAVAILABLE",
                message: clean(obj(data["control"])["show_text"]).isEmpty
                    ? "评论暂时无法读取。" : clean(obj(data["control"])["show_text"]))
        }
        let items = list(data["replies"]).map {
            Comment(
                id: String(describing: $0["rpid_str"] ?? $0["rpid"] ?? ""), user: User.map(obj($0["member"])),
                text: clean(obj($0["content"])["message"], limit: 6000), createdAt: num($0["ctime"]),
                likes: int($0["like"]))
        }
        let next = obj(paging["pagination_reply"])["next_offset"] as? String
        if !end && (items.isEmpty || next == nil || next == "") { throw BiliFailure.invalid }
        return Page(items: items, hasMore: !end, cursor: end ? nil : next)
    }
    private func unique(_ videos: [Video]) -> [Video] {
        var ids = Set<String>()
        return videos.filter { ids.insert($0.id).inserted }
    }
}
