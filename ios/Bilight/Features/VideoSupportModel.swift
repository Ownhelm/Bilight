import SwiftUI

@MainActor final class VideoSupportModel: ObservableObject {
    @Published var state: VideoEngagement?
    @Published var statistics: VideoStatistics?
    @Published var busy = false
    @Published var error: String?
    @Published var refreshRequired = false
    private var operation = UUID()
    func reset(_ statistics: VideoStatistics?) {
        operation = UUID(); state = nil; self.statistics = statistics
        busy = false; error = nil; refreshRequired = false
    }
    func refresh(client: BiliClient, bvid: String, authenticated: Bool, refreshCounts: Bool = false) async {
        guard !busy else { return }
        let token = UUID(); operation = token; busy = true; error = nil
        defer { if operation == token { busy = false } }
        do {
            if authenticated {
                let value = try await client.videoEngagement(bvid)
                guard operation == token, !Task.isCancelled else { return }
                state = value; refreshRequired = false
            }
            if statistics == nil || refreshCounts {
                if let counts = try? await client.videoStatistics(bvid), operation == token { statistics = counts }
            }
        } catch {
            guard operation == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription; refreshRequired = true
        }
    }
    func write(client: BiliClient, bvid: String, action: VideoWrite) async -> Bool {
        guard !busy else { return false }
        let token = UUID(); operation = token; busy = true; error = nil
        let before = state
        var pending = state ?? VideoEngagement(liked: false, coins: 0, favorited: false)
        let silent: Bool
        switch action {
        case .like(let liked): pending.liked = liked; silent = true
        case .coin(let target, let like): pending.coins = max(pending.coins, target); pending.liked = pending.liked || like; silent = true
        case .triple: pending.liked = true; pending.coins = max(1, pending.coins); pending.favorited = true; silent = true
        case .favorite: silent = false
        }
        if silent { state = pending }
        defer { if operation == token { busy = false } }
        do {
            // A new user action may refresh an uncertain result, but never repeats the old write automatically.
            if refreshRequired { _ = try await client.videoEngagement(bvid) }
            guard operation == token, !Task.isCancelled else { return false }
            let value = try await client.writeVideo(bvid, action: action)
            guard operation == token, !Task.isCancelled else { return false }
            state = value
            if action == .triple && !value.complete {
                state = before; refreshRequired = true
                return false
            }
            refreshRequired = false
            if let counts = try? await client.videoStatistics(bvid), operation == token { statistics = counts }
            return !refreshRequired
        } catch {
            guard operation == token, !Task.isCancelled else { return false }
            state = before
            self.error = silent ? nil : error.localizedDescription; refreshRequired = true
            return false
        }
    }
}
