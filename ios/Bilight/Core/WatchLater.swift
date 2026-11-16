import SwiftUI

struct WatchLaterItem: Identifiable {
    let id: Int
    let video: Video?
    let title: String
    let cid: Int
    let progress: Double

    init?(row: JSON) {
        let aid = int(row["aid"])
        guard aid > 0 else { return nil }
        id = aid
        let name = clean(row["title"])
        title = name.isEmpty ? "视频不可用" : name
        video = int(row["state"]) < 0 || !obj(row["bangumi"]).isEmpty ? nil : Video.map(row)
        cid = int(row["cid"])
        progress = max(0, num(row["progress"]))
    }
    init(video: Video) {
        id = video.aid
        self.video = video
        title = video.title
        cid = 0
        progress = 0
    }
}

struct WatchLaterPage {
    static let size = 20
    let items: [WatchLaterItem]
    let count: Int
    let hasMore: Bool

    init(data: JSON, page: Int) throws {
        guard let count = data["count"] as? NSNumber, count.intValue >= 0,
            let rows = data["list"] as? [JSON] ?? (count.intValue == 0 && data["list"] is NSNull ? [] : nil)
        else { throw BiliFailure.invalid }
        self.count = count.intValue
        items = rows.compactMap(WatchLaterItem.init(row:))
        // The official web request interleaves a divider at aid -1. It is not a video.
        guard !items.isEmpty || (page - 1) * Self.size >= self.count else { throw BiliFailure.invalid }
        hasMore = page * Self.size < self.count
    }
}

extension BiliClient {
    func watchLaterPage(_ page: Int) async throws -> WatchLaterPage {
        let version = await http.version()
        _ = try await http.csrf()
        let data = try await http.request("/x/v2/history/toview/web",
            query: ["pn": "\(page)", "ps": "\(WatchLaterPage.size)", "asc": "0", "viewed": "0", "need_split": "1"],
            referer: "https://www.bilibili.com/list/watchlater", expectedVersion: version)
        return try WatchLaterPage(data: data, page: page)
    }

    func writeWatchLater(_ aids: [Int], add: Bool) async throws {
        let aids = Array(Set(aids)).sorted()
        guard !aids.isEmpty, aids.allSatisfy({ $0 > 0 }), !add || aids.count == 1 else { throw BiliFailure.invalid }
        let version = await http.version()
        let csrf = try await http.csrf()
        let route = add ? "add" : aids.count > 1 ? "v2/dels" : "del"
        let form = aids.count == 1 ? ["aid": "\(aids[0])", "csrf": csrf]
            : ["resources": aids.map(String.init).joined(separator: ","), "csrf": csrf]
        _ = try await http.request("/x/v2/history/toview/\(route)", form: form,
            referer: "https://www.bilibili.com/list/watchlater", expectedVersion: version, multipart: aids.count > 1)
    }
}

@MainActor final class WatchLaterStore: ObservableObject {
    struct Notice: Identifiable {
        let id = UUID()
        let text: String
        var removed: [WatchLaterItem] = []
    }

    private let client: BiliClient
    private var mid: Int?
    private var generation = UUID()
    private var readTask: Task<Void, Never>?
    private var membershipTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var queuedWrites: [UUID: Task<Void, Never>] = [:]
    private var noticeTask: Task<Void, Never>?
    private var page = 0
    private var needsRefresh = false
    private var nextPageAvailable = true

    @Published private(set) var items: [WatchLaterItem] = []
    @Published private(set) var count: Int? = nil
    @Published private(set) var loading = false
    @Published private(set) var readError: String?
    @Published private(set) var pending = Set<Int>()
    @Published private(set) var notice: Notice?
    var onError: ((Error) -> Void)?
    var hasMore: Bool { nextPageAvailable }
    var loaded: Bool { page > 0 }

    init(client: BiliClient) { self.client = client }

    func account(_ value: Int?) {
        guard mid != value else { return }
        mid = value
        generation = UUID()
        readTask?.cancel(); readTask = nil
        membershipTask?.cancel(); membershipTask = nil
        queuedWrites.values.forEach { $0.cancel() }; queuedWrites = [:]; writeTask = nil
        noticeTask?.cancel(); noticeTask = nil
        items = []; pending = []; notice = nil; count = nil; readError = nil; loading = false
        page = 0; needsRefresh = false; nextPageAvailable = true
    }

    func contains(_ aid: Int) -> Bool { items.contains { $0.id == aid } }

    func prepare(force: Bool = false) {
        guard mid != nil, membershipTask == nil, writeTask == nil, force || readError == nil else { return }
        if !force, !needsRefresh, loaded, !hasMore { return }
        let version = generation
        membershipTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == version { membershipTask = nil } }
            if force || needsRefresh { await read(reset: true) }
            while current(version), hasMore, readError == nil, writeTask == nil {
                let before = page
                await read()
                if before == page { break }
            }
        }
    }

    func read(reset: Bool = false) async { await read(reset: reset, duringWrite: false) }

    func readVisible(_ target: Int, reset: Bool = false) async {
        if reset { await read(reset: true) }
        while items.count < target, hasMore, readError == nil, mid != nil, !Task.isCancelled {
            let previousPage = page
            await read()
            if page == previousPage { break }
        }
    }

    private func read(reset: Bool = false, duringWrite: Bool) async {
        guard mid != nil, duringWrite || writeTask == nil else { return }
        let requestedGeneration = generation
        while let task = readTask {
            await task.value
            guard current(requestedGeneration), duringWrite || writeTask == nil else { return }
            if !reset || (page == 1 && !needsRefresh && readError == nil) { return }
        }
        let shouldReset = reset || needsRefresh
        if !shouldReset && !hasMore { return }
        let version = generation
        let requested = shouldReset ? 1 : page + 1
        loading = true
        readError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == version { readTask = nil; loading = false } }
            do {
                let result = try await client.watchLaterPage(requested)
                guard current(version) else { return }
                var known = Set(shouldReset ? [] : items.map(\.id))
                let distinct = result.items.filter { known.insert($0.id).inserted }
                if !shouldReset, distinct.isEmpty, !result.items.isEmpty { throw BiliFailure.invalid }
                items = (shouldReset ? [] : items) + distinct
                page = requested
                count = result.count
                nextPageAvailable = result.hasMore
                needsRefresh = false
            } catch is CancellationError {
                return
            } catch {
                guard current(version) else { return }
                readError = error.localizedDescription
                onError?(error)
            }
        }
        readTask = task
        await task.value
    }

    func toggle(_ video: Video) {
        guard video.aid > 0 else { return }
        let shouldAdd = !contains(video.aid)
        enqueue([video.aid]) { [self] version in
            try await resolveMembership(of: video.aid, version: version)
            let confirmed = items.first { $0.id == video.aid }
            if shouldAdd {
                if confirmed == nil { try await addConfirmed(WatchLaterItem(video: video), version: version) }
                display(Notice(text: "已加入稍后再看"))
            } else if let confirmed {
                try await removeConfirmed([confirmed], version: version)
            }
        }
    }

    func remove(_ rows: [WatchLaterItem]) {
        enqueue(rows.map(\.id)) { [self] version in
            if needsRefresh || readError != nil {
                for row in rows { try await resolveMembership(of: row.id, version: version) }
            }
            let confirmed = rows.filter { contains($0.id) }
            if !confirmed.isEmpty { try await removeConfirmed(confirmed, version: version) }
        }
    }

    func undo(_ value: Notice) {
        guard notice?.id == value.id else { return }
        enqueue(value.removed.map(\.id)) { [self] version in
            display(nil)
            for item in value.removed.reversed() {
                try await resolveMembership(of: item.id, version: version)
                if !contains(item.id) { try await addConfirmed(item, version: version) }
            }
        }
    }

    private func resolveMembership(of aid: Int, version: UUID) async throws {
        if needsRefresh || readError != nil { await read(reset: true, duringWrite: true) }
        while current(version), !contains(aid), hasMore, readError == nil {
            let before = page
            await read(duringWrite: true)
            if before == page && hasMore && readError == nil && !contains(aid) {
                throw BiliFailure(code: "WATCH_LATER_UNCONFIRMED", message: "无法确认稍后再看状态。")
            }
        }
        guard current(version) else { throw CancellationError() }
        if let readError { throw BiliFailure(code: "WATCH_LATER_READ", message: readError) }
    }

    private func enqueue(_ aids: [Int], action: @escaping @MainActor (UUID) async throws -> Void) {
        let ids = Set(aids)
        guard mid != nil, !ids.isEmpty, pending.isDisjoint(with: ids) else { return }
        let version = generation
        let preceding = writeTask
        let operation = UUID()
        pending.formUnion(ids)
        let task = Task { [weak self] in
            guard let self else { return }
            await preceding?.value
            guard current(version) else { return }
            defer {
                if generation == version {
                    pending.subtract(ids)
                    queuedWrites.removeValue(forKey: operation)
                    if pending.isEmpty { writeTask = nil }
                }
            }
            await readTask?.value
            guard current(version) else { return }
            do { try await action(version) }
            catch is CancellationError { return }
            catch {
                guard current(version) else { return }
                needsRefresh = true
                onError?(error)
                if current(version) { display(Notice(text: error.localizedDescription)) }
            }
        }
        writeTask = task
        queuedWrites[operation] = task
    }

    private func addConfirmed(_ item: WatchLaterItem, version: UUID) async throws {
        try await client.writeWatchLater([item.id], add: true)
        guard current(version) else { throw CancellationError() }
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        if let count { self.count = count + 1 }
        needsRefresh = hasMore
    }

    private func removeConfirmed(_ rows: [WatchLaterItem], version: UUID) async throws {
        let ids = Set(rows.map(\.id))
        try await client.writeWatchLater(Array(ids), add: false)
        guard current(version) else { throw CancellationError() }
        withAnimation(.easeInOut(duration: 0.18)) {
            items.removeAll { ids.contains($0.id) }
            if let count { self.count = max(0, count - ids.count) }
        }
        needsRefresh = hasMore
        display(Notice(text: rows.count == 1 ? "已移出稍后再看" : "已移出 \(rows.count) 个视频",
            removed: rows.filter { $0.video != nil }))
    }

    private func current(_ version: UUID) -> Bool { generation == version && !Task.isCancelled }

    private func display(_ value: Notice?) {
        noticeTask?.cancel()
        notice = value
        guard let value else { return }
        UIAccessibility.post(notification: .announcement, argument: value.text)
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(value.removed.isEmpty ? 2 : 6)) } catch { return }
            if self?.notice?.id == value.id { self?.notice = nil }
        }
    }
}
