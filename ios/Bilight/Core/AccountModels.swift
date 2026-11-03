import Foundation
import Combine
import CryptoKit

actor FollowedPeopleCache {
    private struct Snapshot: Codable {
        var schema = 1
        var mid: Int
        var items: [FollowedPerson]
    }
    private let directory: URL
    private let suppliedKey: SymmetricKey?
    private var activeMID: Int?
    private var version = UUID()
    private var revision = 0
    init(directory: URL? = nil, key: SymmetricKey? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = root.appendingPathComponent("FollowedPeople", isDirectory: true)
        suppliedKey = key
    }
    func activate(_ mid: Int?, version: UUID) throws {
        guard !Task.isCancelled else { throw CancellationError() }
        let previous = activeMID
        activeMID = mid
        self.version = version
        revision = 0
        if let previous, previous != mid, suppliedKey == nil { KeychainVault.delete("followed-people-key-\(previous)") }
        if FileManager.default.fileExists(atPath: directory.path) {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard file.pathExtension == "sealed", let old = Int(file.deletingPathExtension().lastPathComponent), old != mid else { continue }
                try FileManager.default.removeItem(at: file)
                if suppliedKey == nil { KeychainVault.delete("followed-people-key-\(old)") }
            }
        }
    }
    func load(mid: Int, version: UUID) throws -> [FollowedPerson]? {
        guard activeMID == mid, self.version == version, !Task.isCancelled else { throw CancellationError() }
        let file = directory.appendingPathComponent("\(mid).sealed")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
        let data = try AES.GCM.open(box, using: key(mid), authenticating: Data("followed-people:\(mid)".utf8))
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.schema == 1, snapshot.mid == mid else { throw BiliFailure.invalid }
        return snapshot.items
    }
    func save(_ items: [FollowedPerson], mid: Int, version: UUID, revision: Int) throws {
        guard activeMID == mid, self.version == version, revision >= self.revision, !Task.isCancelled else { throw CancellationError() }
        let data = try JSONEncoder().encode(Snapshot(mid: mid, items: items))
        let box = try AES.GCM.seal(data, using: key(mid), authenticating: Data("followed-people:\(mid)".utf8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var folder = directory; try folder.setResourceValues(excluded)
        try box.combined!.write(to: directory.appendingPathComponent("\(mid).sealed"), options: [.atomic, .completeFileProtection])
        self.revision = revision
    }
    private func key(_ mid: Int) throws -> SymmetricKey {
        if let suppliedKey { return suppliedKey }
        let name = "followed-people-key-\(mid)"
        if let data: Data = try KeychainVault.load(name) { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try KeychainVault.save(key.withUnsafeBytes { Data($0) }, name: name)
        return key
    }
}

private struct FollowedNameIndex {
    var name: String
    var keys: [String]
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }
    static func make(_ name: String) -> FollowedNameIndex {
        let plain = normalized(name)
        let spaced = plain.replacingOccurrences(
            of: "(?<=\\p{Han})(?=[\\p{Latin}\\p{N}])|(?<=[\\p{Latin}\\p{N}])(?=\\p{Han})", with: " ", options: .regularExpression)
        let rawLatin = spaced.applyingTransform(.toLatin, reverse: false) ?? spaced
        let latin = normalized(rawLatin)
        let words = latin.split { !$0.isLetter && !$0.isNumber }
        let withV = normalized(rawLatin.decomposedStringWithCanonicalMapping.replacingOccurrences(of: "u\u{308}", with: "v", options: .literal))
            .filter { $0.isLetter || $0.isNumber }
        return FollowedNameIndex(name: name, keys: [plain, plain.filter { !$0.isWhitespace }, words.joined(), String(words.compactMap(\.first)), withV])
    }
}

@MainActor final class FollowedPeopleSearch: ObservableObject {
    @Published private(set) var items: [FollowedPerson]?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var hasSnapshot = false
    private let cache: FollowedPeopleCache?
    private var mid: Int?
    private var activated = false
    private var generation = UUID()
    private var revision = 0
    private var worker: Task<Void, Never>?
    private var activation: Task<Void, Error>?
    private var removed = Set<Int>()
    private var index: [Int: FollowedNameIndex] = [:]
    init(cache: FollowedPeopleCache? = nil) { self.cache = cache }
    func account(_ mid: Int?) {
        guard !activated || self.mid != mid else { return }
        activated = true
        worker?.cancel(); worker = nil
        self.mid = mid; generation = UUID(); revision = 0
        items = nil; busy = false; error = nil; hasSnapshot = false; removed = []; index = [:]
        if let cache {
            let previous = activation, generation = generation
            activation = Task {
                _ = try? await previous?.value
                try await cache.activate(mid, version: generation)
            }
        }
    }
    func enter(read: @escaping (Int) async throws -> Page<FollowedPerson>) {
        guard let mid, !busy else { return }
        let generation = generation
        busy = true; error = nil; removed = []
        worker = Task {
            defer { if self.generation == generation { busy = false; worker = nil } }
            do {
                do { try await activation?.value } catch {
                    try Task.checkCancellation()
                    guard self.generation == generation, let cache else { throw error }
                    try await cache.activate(mid, version: generation)
                    guard self.generation == generation else { throw CancellationError() }
                    activation = nil
                }
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                if items == nil, let cache {
                    do {
                        if let saved = try await cache.load(mid: mid, version: generation) {
                            try await publish(saved, generation: generation)
                            hasSnapshot = true
                        }
                    } catch is CancellationError { throw CancellationError() } catch { /* A fresh upstream read can replace an unreadable snapshot. */ }
                }
                var people: [FollowedPerson] = []
                var seen = Set<Int>()
                for page in 1...500 {
                    let value = try await read(page)
                    try Task.checkCancellation()
                    guard self.generation == generation else { return }
                    let fresh = value.items.filter { seen.insert($0.id).inserted }
                    people.append(contentsOf: fresh)
                    if !hasSnapshot { try await publish(people, generation: generation) }
                    if !value.hasMore {
                        try await publish(people, generation: generation)
                        hasSnapshot = true
                        revision += 1
                        if let cache, let items { try await cache.save(items, mid: mid, version: generation, revision: revision) }
                        return
                    }
                    guard !fresh.isEmpty else { throw BiliFailure(code: "FOLLOW_LIST_INCOMPLETE", message: "关注名单未能完整读取，请重试。") }
                }
                throw BiliFailure(code: "FOLLOW_LIST_INCOMPLETE", message: "关注名单未能完整读取，请重试。")
            } catch is CancellationError { return } catch {
                if !Task.isCancelled, self.generation == generation { self.error = error.localizedDescription }
            }
        }
    }
    func remove(_ mid: Int) {
        removed.insert(mid)
        items?.removeAll { $0.id == mid }; index[mid] = nil
        guard hasSnapshot, let owner = self.mid, let items, let cache else { return }
        revision += 1
        let revision = revision, generation = generation, activation = activation
        Task {
            do {
                try await activation?.value
                try await cache.save(items, mid: owner, version: generation, revision: revision)
            } catch is CancellationError { return } catch {
                if self.generation == generation { self.error = error.localizedDescription }
            }
        }
    }
    private func publish(_ value: [FollowedPerson], generation: UUID) async throws {
        let previous = index
        let built = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: value.map { item in
                (item.id, previous[item.id].flatMap { $0.name == item.user.name ? $0 : nil } ?? FollowedNameIndex.make(item.user.name))
            })
        }.value
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        items = value.filter { !removed.contains($0.id) }
        index = built.filter { !removed.contains($0.key) }
    }
    func matches(_ keyword: String) -> [FollowedPerson] {
        let query = FollowedNameIndex.normalized(keyword).filter { !$0.isWhitespace }
        guard !query.isEmpty else { return [] }
        return (items ?? []).filter { index[$0.id]?.keys.contains(where: { $0.contains(query) }) == true }
    }
}

struct FollowedPerson: Identifiable, Codable {
    var user: User
    var relation: Relation
    var followedAt: Double
    var id: Int { user.mid }
    static func map(_ raw: JSON) throws -> FollowedPerson {
        var user = User.map(raw)
        let relation = try Relation.map(raw)
        guard user.mid > 0, relation.following else { throw BiliFailure.invalid }
        if user.name.isEmpty { user.name = "UP主 \(user.mid)" }
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
