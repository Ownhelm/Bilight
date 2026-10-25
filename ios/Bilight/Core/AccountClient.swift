import Foundation

extension BiliClient {
    func history(mid: Int, cursor: String? = nil) async throws -> Page<WatchRecord> {
        let version = try await accountVersion(mid)
        var query = ["type": "archive", "ps": "20"]
        if let cursor {
            guard cursor.count <= 600, cursor.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                let bytes = Data(
                    base64Encoded: cursor.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
                        of: "_", with: "/")
                        + String(repeating: "=", count: (4 - cursor.count % 4) % 4)),
                let position = try JSONSerialization.jsonObject(with: bytes) as? JSON,
                int(position["max"]) > 0, int(position["view_at"]) > 0,
                clean(position["business"]).range(of: "^[a-z_]{1,32}$", options: .regularExpression) != nil
            else { throw BiliFailure(code: "INVALID_CURSOR", message: "历史分页已失效，请刷新。") }
            query["max"] = "\(int(position["max"]))"
            query["view_at"] = "\(int(position["view_at"]))"
            query["business"] = clean(position["business"])
        }
        let data = try await http.request("/x/web-interface/history/cursor", query: query)
        try await http.check(version)
        guard data["list"] is [JSON], data["cursor"] is JSON else { throw BiliFailure.invalid }
        var seen = Set<String>()
        let items = list(data["list"]).compactMap { raw -> WatchRecord? in
            let record = obj(raw["history"])
            guard clean(record["business"]) == "archive",
                let video = Video.map(
                    [
                        "bvid": record["bvid"] ?? "", "aid": record["oid"] ?? 0, "title": raw["title"] ?? "",
                        "cover": raw["cover"] ?? "", "duration": raw["duration"] ?? 0,
                    ],
                    owner: User(
                        mid: int(raw["author_mid"]), name: clean(raw["author_name"]),
                        avatar: secureURL(raw["author_face"]))),
                seen.insert(video.id).inserted
            else { return nil }
            let progress = max(0, num(raw["progress"]))
            return WatchRecord(
                video: video, cid: int(record["cid"]), page: max(1, int(record["page"])),
                part: clean(record["part"]), progress: video.duration > 0 ? min(progress, video.duration) : progress,
                viewedAt: Date(timeIntervalSince1970: num(raw["view_at"])),
                completed: num(raw["progress"]) == -1 || (video.duration > 0 && progress >= video.duration))
        }
        let raw = obj(data["cursor"])
        var next: String?
        if !list(data["list"]).isEmpty, int(raw["max"]) > 0, int(raw["view_at"]) > 0,
            clean(raw["business"]).range(of: "^[a-z_]{1,32}$", options: .regularExpression) != nil
        {
            let bytes = try JSONSerialization.data(
                withJSONObject: [
                    "max": int(raw["max"]), "view_at": int(raw["view_at"]), "business": clean(raw["business"]),
                ], options: .sortedKeys)
            let value = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
                of: "/", with: "_"
            ).replacingOccurrences(of: "=", with: "")
            if value != cursor { next = value }
        }
        NativeTrace.mark(.historyReceived, ["count": items.count])
        return Page(items: items, hasMore: next != nil, cursor: next)
    }
    func reportHistory(mid: Int, video: Video, part: VideoPart, progress: Double) async throws {
        guard validBVID(video.bvid), video.aid > 0, part.cid > 0, part.page > 0,
            progress.isFinite, progress >= 0, progress <= 7 * 86400
        else { throw BiliFailure.invalid }
        let version = try await accountVersion(mid)
        try await http.ensureDevice()
        try await http.check(version)
        let csrf = try await http.csrf()
        _ = try await http.request(
            "/x/v2/history/report",
            form: [
                "aid": "\(video.aid)", "cid": "\(part.cid)",
                "progress": "\(Int((part.duration > 0 ? min(progress, part.duration) : progress).rounded(.down)))",
                "csrf": csrf,
            ],
            referer: "https://www.bilibili.com/video/\(video.bvid)")
        try await http.check(version)
        NativeTrace.mark(.historyReported)
    }
    // Verify the account before personal reads, and reject results after a session change.
    private func accountVersion(_ mid: Int) async throws -> UUID {
        let version = await http.version()
        _ = try await http.csrf()
        guard try await currentUser()?.mid == mid else {
            throw BiliFailure(code: "-101", message: "当前账号已变化，请重新登录。")
        }
        try await http.check(version)
        return version
    }
    func followedPeople(mid: Int, page: Int, frequent: Bool = false) async throws -> Page<FollowedPerson> {
        guard page > 0 else { throw BiliFailure.invalid }
        let version = try await accountVersion(mid)
        let data = try await http.request(
            "/x/relation/followings",
            query: [
                "vmid": "\(mid)", "pn": "\(page)", "ps": "20", "order_type": frequent ? "attention" : "",
            ], referer: "https://space.bilibili.com/\(mid)/relation/follow")
        guard data["total"] is NSNumber else { throw BiliFailure.invalid }
        let total = int(data["total"])
        guard data["list"] is [JSON] || (data["list"] is NSNull && total == 0) else { throw BiliFailure.invalid }
        let items = try list(data["list"]).map(FollowedPerson.map)
        guard !items.isEmpty || (page - 1) * 20 >= total else { throw BiliFailure.invalid }
        try await http.check(version)
        NativeTrace.mark(.libraryReceived, ["kind": frequent ? 1 : 0, "count": items.count, "page": page])
        return Page(items: items, hasMore: page * 20 < total)
    }
    func favoriteFolders(mid: Int, collected: Bool, page: Int) async throws -> Page<FavoriteFolder> {
        guard page > 0 else { throw BiliFailure.invalid }
        let version = try await accountVersion(mid)
        let data = try await http.request(
            "/x/v3/fav/folder/\(collected ? "collected" : "created")/list",
            query: ["up_mid": "\(mid)", "pn": "\(page)", "ps": "20", "platform": "web"],
            referer: "https://space.bilibili.com/\(mid)/favlist")
        if collected {
            let rows = list(data["list"])
            NativeTrace.mark(
                .libraryShape,
                [
                    "countPresent": data["count"] is NSNumber ? 1 : 0,
                    "listArray": data["list"] is [JSON] ? 1 : 0, "listNull": data["list"] is NSNull ? 1 : 0,
                    "items": rows.count, "reportedCount": int(data["count"]),
                    "missingId": rows.filter { int($0["id"]) <= 0 }.count,
                    "missingMid": rows.filter { int($0["mid"]) <= 0 && int(obj($0["upper"])["mid"]) <= 0 }.count,
                    "missingTitle": rows.filter { !($0["title"] is String) }.count,
                    "missingCount": rows.filter { !($0["media_count"] is NSNumber) }.count,
                ])
        }
        guard data["count"] is NSNumber,
            data["list"] is [JSON] || (data["list"] is NSNull && int(data["count"]) == 0)
        else { throw BiliFailure.invalid }
        let items = try list(data["list"]).map(FavoriteFolder.map)
        guard !items.isEmpty || (page - 1) * 20 >= int(data["count"]) else { throw BiliFailure.invalid }
        guard collected || items.allSatisfy({ $0.mid == mid }) else { throw BiliFailure.invalid }
        try await http.check(version)
        NativeTrace.mark(.libraryReceived, ["kind": collected ? 3 : 2, "count": items.count, "page": page])
        return Page(items: items, hasMore: (data["has_more"] as? Bool) ?? (page * 20 < int(data["count"])))
    }
    func favoriteContents(mid: Int, folder: FavoriteFolder, page: Int, keyword: String = "", order: String = "mtime")
        async throws -> Page<FavoriteItem>
    {
        guard page > 0, ["mtime", "view", "pubtime"].contains(order), folder.type == 11 else {
            throw BiliFailure.invalid
        }
        let version = try await accountVersion(mid)
        let data = try await http.request(
            "/x/v3/fav/resource/list",
            query: [
                "media_id": "\(folder.id)", "pn": "\(page)", "ps": "20", "order": order,
                "keyword": keyword, "type": "0", "platform": "web",
            ], referer: "https://space.bilibili.com/\(mid)/favlist")
        let info = try FavoriteFolder.map(obj(data["info"]))
        guard info.id == folder.id, info.mid == folder.mid, let more = data["has_more"] as? Bool,
            data["medias"] is [JSON] || (data["medias"] is NSNull && !more)
        else { throw BiliFailure.invalid }
        let items = try list(data["medias"]).map(FavoriteItem.map)
        try await http.check(version)
        NativeTrace.mark(.libraryReceived, ["kind": 4, "count": items.count, "page": page])
        return Page(items: items, hasMore: more)
    }
    func createFavoriteFolder(mid: Int, title: String, isPrivate: Bool) async throws -> FavoriteFolder {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 20 else {
            throw BiliFailure(code: "FOLDER_TITLE", message: "收藏夹名称需要 1–20 个字。")
        }
        let version = try await accountVersion(mid)
        let all = try await http.request("/x/v3/fav/folder/created/list-all", query: ["up_mid": "\(mid)"])
        guard all["count"] is NSNumber else { throw BiliFailure.invalid }
        guard int(all["count"]) < 100 else {
            throw BiliFailure(code: "FOLDER_LIMIT", message: "已达到 100 个收藏夹上限。")
        }
        let csrf = try await http.csrf()
        try await http.check(version)
        // Writes are sent once. On an uncertain result, refresh the list before trying again.
        let data: JSON
        do {
            data = try await http.request(
                "/x/v3/fav/folder/add",
                form: [
                    "title": title, "privacy": isPrivate ? "1" : "0", "csrf": csrf,
                ])
        } catch let failure as BiliFailure { throw failure } catch {
            throw BiliFailure(code: "WRITE_UNCERTAIN", message: "创建结果尚未确认，请先刷新收藏夹，避免重复创建。")
        }
        let folder = try FavoriteFolder.map(data)
        guard folder.mid == mid else { throw BiliFailure.invalid }
        try await http.check(version)
        return folder
    }
}
