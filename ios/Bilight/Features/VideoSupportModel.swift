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
                statistics = statistics?.applyingChange(from: state, to: value)
                state = value; refreshRequired = false
            }
            if statistics == nil || refreshCounts {
                if let counts = try? await client.videoStatistics(bvid), operation == token, !Task.isCancelled { statistics = counts }
            }
        } catch {
            guard operation == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription; refreshRequired = true
        }
    }
    func write(client: BiliClient, bvid: String, action: VideoWrite) async -> Bool {
        guard !busy else { return false }
        let token = UUID(); operation = token; busy = true; error = nil
        var before = state
        var countsBefore = statistics
        let silent: Bool
        switch action {
        case .favorite: silent = false
        default: silent = true
        }
        func preview(_ current: VideoEngagement) {
            var pending = current
            switch action {
            case .like(let liked): pending.liked = liked
            case .coin(let target, let like): pending.coins = max(pending.coins, target); pending.liked = pending.liked || like
            case .triple: pending.liked = true; pending.coins = max(1, pending.coins); pending.favorited = true
            case .favorite(let folders): pending.favorited = !folders.isEmpty
            }
            state = pending
            statistics = countsBefore?.applyingChange(from: current, to: pending)
        }
        if let before { preview(before) }
        var confirmed = false
        defer {
            if operation == token {
                if !confirmed { state = before; statistics = countsBefore }
                busy = false
            }
        }
        do {
            // A new user action may refresh an uncertain result, but never repeats the old write automatically.
            if refreshRequired || before == nil {
                let current = try await client.videoEngagement(bvid)
                guard operation == token, !Task.isCancelled else { return false }
                countsBefore = countsBefore?.applyingChange(from: before, to: current)
                before = current
                preview(current)
            }
            guard operation == token, !Task.isCancelled else { return false }
            let value = try await client.writeVideo(bvid, action: action)
            guard operation == token, !Task.isCancelled else { return false }
            if action == .triple && !value.complete {
                refreshRequired = true; return false
            }
            state = value
            statistics = countsBefore?.applyingChange(from: before, to: value)
            refreshRequired = false; confirmed = true
            return true
        } catch {
            guard operation == token, !Task.isCancelled else { return false }
            self.error = silent ? nil : error.localizedDescription; refreshRequired = true
            return false
        }
    }
}

private extension VideoStatistics {
    func applyingChange(from before: VideoEngagement?, to current: VideoEngagement) -> VideoStatistics {
        guard let before else { return self }
        return VideoStatistics(
            likes: max(0, likes + (current.liked ? 1 : 0) - (before.liked ? 1 : 0)),
            coins: max(0, coins + current.coins - before.coins),
            favorites: max(0, favorites + (current.favorited ? 1 : 0) - (before.favorited ? 1 : 0))
        )
    }
}
