import AVFoundation
import CryptoKit
import XCTest

@testable import Bilight

/// Opt-in, anonymous and read-only. Never borrows the Mac or iPhone account's cookies.
final class LiveSmokeTests: XCTestCase {
    @MainActor func testRealSegmentedDASHVideoAudioAndSeeking() async throws {
        guard ProcessInfo.processInfo.environment["BILIGHT_LIVE_SMOKE"] == "1" else { throw XCTSkip("Opt-in live media check") }
        let client = BiliClient(http: BiliHTTP(vault: MemoryVault()))
        let source = try await client.playback("BV1gVH56jEru", cid: 43_045_423_664, allowNative: false)
        let began = Date()
        let stream = try await SegmentedStream.make(source)
        defer { stream.stop() }
        let player = AVPlayer(url: stream.url)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let item = try XCTUnwrap(player.currentItem)
        let deadline = Date().addingTimeInterval(20)
        while item.status == .unknown && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(item.status, .readyToPlay)
        print("[iOS segmented smoke] ready ms: \(Int(Date().timeIntervalSince(began) * 1000)), quality: \(source.quality)")
        let audio = try await item.asset.loadMediaSelectionGroup(for: .audible)
        XCTAssertNotNil(source.audio)
        XCTAssertFalse(audio?.options.isEmpty ?? true)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        player.play()
        var colors = 0
        let frameDeadline = Date().addingTimeInterval(12)
        while colors <= 100 && Date() < frameDeadline {
            if let buffer = output.copyPixelBuffer(forItemTime: output.itemTime(forHostTime: CACurrentMediaTime()), itemTimeForDisplay: nil) { colors = uniqueColors(buffer) }
            if colors <= 100 { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertGreaterThan(colors, 100, "Segmented playback must decode real colored frames")
        player.pause()
        await player.seek(to: CMTime(seconds: 15, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertEqual(player.currentTime().seconds, 15, accuracy: 0.5)
        XCTAssertEqual(player.rate, 0)
    }
    @MainActor func testRealDASHDownloadMergeAndOfflinePlayback() async throws {
        guard ProcessInfo.processInfo.environment["BILIGHT_LIVE_SMOKE"] == "1" else { throw XCTSkip("Opt-in live download check") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = BiliClient(http: BiliHTTP(vault: MemoryVault()))
        let store = DownloadStore(client: client, directory: directory, key: SymmetricKey(size: .bits256), preferNative: false)
        store.account(3, remember: false)
        let part = VideoPart(cid: 43_045_423_664, page: 1, title: "Public smoke", duration: 87)
        let video = Video(bvid: "BV1gVH56jEru", aid: 0, title: "Public media smoke", cover: nil, duration: 87, publishedAt: 0, owner: User(mid: 1, name: "Public", avatar: nil), views: 0)
        let id = try store.enqueue(video: video, part: part, quality: 127, label: "Highest available")
        let deadline = Date().addingTimeInterval(100)
        while ![DownloadState.completed, .failed].contains(store.items.first?.state ?? .failed), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let record = try XCTUnwrap(store.items.first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.state, .completed, record.message ?? "Download did not finish")
        guard record.state == .completed else { store.account(nil, remember: false); return }
        XCTAssertEqual(record.files.count, 2, "DASH must download video and audio separately before combining")
        let url = store.fileURL(record)
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let model = PlayerModel()
        defer { model.stop(); store.account(nil, remember: false) }
        model.loadLocal(url, record: record)
        let item = try XCTUnwrap(model.player.currentItem)
        let readyDeadline = Date().addingTimeInterval(8)
        while item.status == .unknown && Date() < readyDeadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertTrue((item.asset as? AVURLAsset)?.url.isFileURL == true)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        model.player.play()
        var colors = 0
        let frameDeadline = Date().addingTimeInterval(10)
        while colors <= 100, Date() < frameDeadline {
            if let buffer = output.copyPixelBuffer(forItemTime: output.itemTime(forHostTime: CACurrentMediaTime()), itemTimeForDisplay: nil) { colors = uniqueColors(buffer) }
            if colors <= 100 { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertGreaterThan(colors, 100, "The exported local MP4 must contain real decodable video")
        print("[iOS download smoke] local MP4 bytes: \(record.bytes), video/audio: \(videoTracks.count)/\(audioTracks.count)")
    }
    @MainActor func testRealNativeAVCAACPlaybackAndSeeking() async throws {
        guard ProcessInfo.processInfo.environment["BILIGHT_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Run the BilightLiveSmoke scheme for real read-only media verification.")
        }
        let client = BiliClient(http: BiliHTTP(vault: MemoryVault()))
        let model = PlayerModel()
        defer { model.stop() }
        model.load(
            client: client, bvid: "BV1gVH56jEru", part: VideoPart(cid: 43_045_423_664, page: 1, title: "", duration: 87)
        )
        let deadline = Date().addingTimeInterval(50)
        while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(model.busy, "Native media preparation timed out")
        print("[iOS media smoke] preparation: \(model.error ?? "ready")")
        XCTAssertNil(model.error)
        print(
            "[iOS media smoke] stream: \(model.playback?.mp4 != nil ? "MP4" : "DASH"), quality: \(model.playback?.quality ?? 0)"
        )
        guard let item = model.player.currentItem else {
            XCTFail("No native player item")
            return
        }
        while item.status == .unknown && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(item.status, .readyToPlay)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let audioTracks = try await item.asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        model.player.play()
        let playingDeadline = Date().addingTimeInterval(15)
        while model.player.currentTime().seconds < 1 && Date() < playingDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(model.player.currentTime().seconds, 1)
        var frame: CVPixelBuffer?
        var colors = 0
        let frameDeadline = Date().addingTimeInterval(8)
        while colors <= 100 && Date() < frameDeadline {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            if let frame { colors = uniqueColors(frame) }
            if colors <= 100 { try await Task.sleep(for: .milliseconds(100)) }
        }
        print("[iOS media smoke] decoded video frame: \(frame != nil)")
        XCTAssertNotNil(frame, "The native player must produce real video frames, not only advance an audio timeline")
        XCTAssertGreaterThan(colors, 100, "Decoded frames must contain real image detail")
        model.player.pause()
        let before = model.player.currentTime().seconds
        model.seek(5)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(model.player.rate, 0)
        XCTAssertEqual(model.player.currentTime().seconds, before + 5, accuracy: 0.3)
        var pausedColors = 0
        let pausedDeadline = Date().addingTimeInterval(5)
        while pausedColors <= 100 && Date() < pausedDeadline {
            if let pausedFrame = output.copyPixelBuffer(
                forItemTime: model.player.currentTime(), itemTimeForDisplay: nil)
            {
                pausedColors = uniqueColors(pausedFrame)
            }
            if pausedColors <= 100 { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertGreaterThan(pausedColors, 100, "Seeking while paused must display the target video frame")
        if let quality = model.playback?.qualities.last, quality.id != model.playback?.quality {
            model.load(
                client: client, bvid: "BV1gVH56jEru",
                part: VideoPart(cid: 43_045_423_664, page: 1, title: "", duration: 87), quality: quality.id,
                preserve: true)
            let switchDeadline = Date().addingTimeInterval(30)
            while model.busy && Date() < switchDeadline { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertNil(model.error)
            XCTAssertEqual(model.player.rate, 0)
            guard let changed = model.player.currentItem else {
                XCTFail("Missing replacement item")
                return
            }
            let nextOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            changed.add(nextOutput)
            var nextFrame: CVPixelBuffer?
            var changedColors = 0
            let decodeDeadline = Date().addingTimeInterval(8)
            while changedColors <= 100 && Date() < decodeDeadline {
                nextFrame = nextOutput.copyPixelBuffer(
                    forItemTime: model.player.currentTime(), itemTimeForDisplay: nil)
                if let nextFrame { changedColors = uniqueColors(nextFrame) }
                if changedColors <= 100 { try await Task.sleep(for: .milliseconds(100)) }
            }
            if let nextFrame {
                let colors = uniqueColors(nextFrame)
                print("[iOS media smoke] switched quality \(quality.id), colors: \(colors)")
                XCTAssertGreaterThan(colors, 100)
            } else {
                XCTFail("Changing quality must still decode real video frames")
            }
            let position = model.player.currentTime().seconds
            model.setRate(1.25)
            model.player.play()
            if let highest = model.playback?.qualities.first, highest.id != model.playback?.quality {
                model.load(
                    client: client, bvid: "BV1gVH56jEru",
                    part: VideoPart(cid: 43_045_423_664, page: 1, title: "", duration: 87), quality: highest.id,
                    preserve: true)
                let resumeDeadline = Date().addingTimeInterval(30)
                while model.busy && Date() < resumeDeadline { try await Task.sleep(for: .milliseconds(100)) }
                XCTAssertNil(model.error)
                XCTAssertGreaterThanOrEqual(model.player.currentTime().seconds, position - 0.3)
                XCTAssertEqual(model.player.defaultRate, 1.25)
                XCTAssertGreaterThan(model.player.rate, 0, "A quality change while playing must resume playback")
            }
        }
        model.stop()
        XCTAssertNil(model.player.currentItem)
    }
    private func uniqueColors(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var colors = Set<UInt32>()
        var red = 0
        var blue = 0
        var samples = 0
        for y in Swift.stride(from: 0, to: height, by: max(1, height / 25)) {
            for x in Swift.stride(from: 0, to: width, by: max(1, width / 25)) {
                let pixel = base.advanced(by: y * stride + x * 4).load(as: UInt32.self)
                colors.insert(pixel)
                red += Int((pixel >> 16) & 255)
                blue += Int(pixel & 255)
                samples += 1
            }
        }
        // The public test clip contains a real room; a green decoder surface must not pass as a noisy image.
        guard samples > 0, red / samples > 10, blue / samples > 10 else { return 0 }
        return colors.count
    }
}
