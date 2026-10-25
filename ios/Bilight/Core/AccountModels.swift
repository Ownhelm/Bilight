import Foundation

struct FollowedPerson: Identifiable {
    var user: User
    var relation: Relation
    var followedAt: Double
    var id: Int { user.mid }
    static func map(_ raw: JSON) throws -> FollowedPerson {
        let user = User.map(raw)
        let relation = try Relation.map(raw)
        guard user.mid > 0, !user.name.isEmpty, relation.following else { throw BiliFailure.invalid }
        return FollowedPerson(user: user, relation: relation, followedAt: num(raw["mtime"]))
    }
}
struct FavoriteFolder: Hashable, Identifiable {
    var id: Int
    var mid: Int
    var title: String
    var cover: URL?
    var count: Int
    var isPrivate: Bool
    var intro: String
    var type: Int
    var unavailable: Bool
    var creatorName: String
    static func map(_ raw: JSON) throws -> FavoriteFolder {
        let upper = obj(raw["upper"])
        let id = int(raw["id"])
        let mid = int(raw["mid"]) > 0 ? int(raw["mid"]) : int(upper["mid"])
        guard id > 0, raw["title"] is String, raw["media_count"] is NSNumber else {
            throw BiliFailure.invalid
        }
        return FavoriteFolder(
            id: id, mid: mid, title: clean(raw["title"]), cover: secureURL(raw["cover"]),
            count: int(raw["media_count"]), isPrivate: int(raw["attr"]) & 1 == 1,
            intro: clean(raw["intro"], limit: 3000), type: int(raw["type"]) == 0 ? 11 : int(raw["type"]),
            unavailable: int(raw["state"]) == 1 || mid <= 0, creatorName: clean(upper["name"]))
    }
}
struct FavoriteItem: Identifiable {
    var aid: Int
    var type: Int
    var title: String
    var cover: URL?
    var owner: User
    var video: Video?
    var addedAt: Double
    var id: String { "\(aid):\(type)" }
    static func map(_ raw: JSON) throws -> FavoriteItem {
        let aid = int(raw["id"])
        let type = int(raw["type"])
        guard aid > 0, type > 0, raw["title"] is String else { throw BiliFailure.invalid }
        let owner = User.map(obj(raw["upper"]))
        var source = raw
        source["bvid"] = [raw["bvid"], raw["bv_id"]].compactMap { $0 as? String }.first(where: validBVID)
        source["pubdate"] = raw["pubtime"]
        source["play"] = obj(raw["cnt_info"])["play"]
        let video = type == 2 && int(raw["attr"]) == 0 ? Video.map(source, owner: owner) : nil
        return FavoriteItem(
            aid: aid, type: type, title: clean(raw["title"]), cover: secureURL(raw["cover"]), owner: owner,
            video: video, addedAt: num(raw["fav_time"]))
    }
}
