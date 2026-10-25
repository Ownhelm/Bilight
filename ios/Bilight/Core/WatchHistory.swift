import SwiftUI

/// Bilibili is the history source. Unsent progress is only a transient, per-video upload queue.
@MainActor final class WatchHistory: ObservableObject {
    @Published private(set) var items: [WatchRecord] = []
    @Published private(set) var busy = false
    @Published private(set) var hasMore = true
    @Published private(set) var revision = 0
    @Published private(set) var expired = false
    @Published var error: String?
    @Published var syncError: String?
    private let client: BiliClient
    private var mid: Int?
    private var version = UUID(), readVersion = UUID()
    private var cursor: String?
    private var seen = Set<String>(), cursors = Set<String>()
    private struct Report {
        let id = UUID()
        var video: Video
        var part: VideoPart
        var progress: Double
        var order: Int
    }
    private var pending: [String: Report] = [:]
    private var sequence = 0
    private var worker: Task<Void, Never>?
    init(client: BiliClient) { self.client = client }
    func account(_ value: Int?) {
        worker?.cancel()
        worker = nil
        pending = [:]
        sequence = 0
        version = UUID()
        readVersion = UUID()
        mid = value
        items = []
        seen = []
        cursors = []
        cursor = nil
        error = nil
        syncError = nil
        busy = false
        hasMore = true
        expired = false
    }
    func load(reset: Bool = false) async {
        guard let mid, reset || (!busy && hasMore) else { return }
        let token = UUID()
        let account = version
        readVersion = token
        if reset {
            items = []
            seen = []
            cursors = []
            cursor = nil
            hasMore = true
        }
        busy = true
        error = nil
        defer { if readVersion == token { busy = false } }
        do {
            let page = try await client.history(mid: mid, cursor: cursor)
            try Task.checkCancellation()
            guard version == account, readVersion == token else { return }
            if let next = page.cursor, !cursors.insert(next).inserted { throw BiliFailure.invalid }
            items += page.items.filter { seen.insert($0.id).inserted }
            hasMore = page.hasMore
            cursor = page.cursor
        } catch is CancellationError { return } catch {
            guard version == account, readVersion == token else { return }
            self.error = error.localizedDescription
            expired = (error as? BiliFailure)?.code == "-101"
        }
    }
    func record(_ video: Video, part: VideoPart, progress: Double, completed: Bool) throws {
        guard mid != nil else { return }
        guard video.aid > 0, part.cid > 0, progress.isFinite, progress >= 0 else { throw BiliFailure.invalid }
        sequence += 1
        pending[video.id] = Report(video: video, part: part, progress: progress, order: sequence)
        retry()
    }
    func retry() {
        guard worker == nil, !pending.isEmpty, let mid else { return }
        let account = version
        worker = Task {
            defer { if version == account { worker = nil } }
            var attempted = Set<UUID>()
            while version == account, !Task.isCancelled,
                let report = pending.values.filter({ !attempted.contains($0.id) }).min(by: { $0.order < $1.order })
            {
                attempted.insert(report.id)
                do {
                    try await client.reportHistory(
                        mid: mid, video: report.video, part: report.part, progress: report.progress)
                    guard version == account, !Task.isCancelled else { return }
                    if pending[report.video.id]?.id == report.id { pending[report.video.id] = nil }
                    if pending.isEmpty { syncError = nil }
                    revision += 1
                } catch is CancellationError { return } catch {
                    guard version == account, !Task.isCancelled else { return }
                    NativeTrace.mark(.historyFailed, ["code": Int((error as? BiliFailure)?.code ?? "") ?? 0])
                    // A newer actual watch can supersede a failed progress report; no failed local history is displayed.
                    if pending[report.video.id]?.id != report.id { continue }
                    syncError = "观看进度未同步：" + error.localizedDescription
                    expired = (error as? BiliFailure)?.code == "-101"
                    if expired { return }
                }
            }
        }
    }
}

struct HistorySyncStatus: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var history: WatchHistory
    var body: some View {
        Group {
            if let error = history.syncError {
                HStack {
                    Text(error).font(.caption2)
                    Button {
                        history.retry()
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("重试同步观看进度")
                }.foregroundStyle(Color.biliPink)
            }
        }.onChange(of: history.expired) { _, expired in
            if expired { app.handle(BiliFailure(code: "-101", message: "登录已失效，请重新登录。")) }
        }
    }
}
