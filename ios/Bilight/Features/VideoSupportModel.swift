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
        guard !busy, !refreshRequired else { return false }
        let token = UUID(); operation = token; busy = true; error = nil
        defer { if operation == token { busy = false } }
        do {
            let value = try await client.writeVideo(bvid, action: action)
            guard operation == token, !Task.isCancelled else { return false }
            state = value
            if action == .triple && !value.complete {
                refreshRequired = true; error = "三连未全部完成，请刷新状态。"
            }
            if let counts = try? await client.videoStatistics(bvid), operation == token { statistics = counts }
            return !refreshRequired
        } catch {
            guard operation == token, !Task.isCancelled else { return false }
            self.error = error.localizedDescription; refreshRequired = true
            return false
        }
    }
}
