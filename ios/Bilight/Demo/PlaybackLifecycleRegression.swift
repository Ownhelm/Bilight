#if DEBUG
import AVFoundation
import Combine
import SwiftUI

/// Offline, opt-in lifecycle fixture: exercises the real player and fullscreen hierarchy.
struct PlaybackLifecycleRegressionView: View {
    @StateObject private var model = PlayerModel()
    @State private var position = 0.0
    @State private var taps = 0
    @State private var error: String?
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack {
            Text("播放恢复测试").accessibilityIdentifier("lifecycle-title")
            NativePlayer(model: model, onQuality: { _ in }).frame(height: 240)
            Text(String(format: "%.1f", position)).accessibilityIdentifier("lifecycle-position")
            Button("响应测试 \(taps)") { taps += 1 }.accessibilityIdentifier("lifecycle-response")
            if let error { Text(error) }
        }.onReceive(timer) { _ in
            let time = model.player.currentTime().seconds
            if time.isFinite { position = time }
        }.task {
            do {
                let url = try await Self.movie()
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                model.playback = Playback(quality: 80, qualities: [], duration: 60, mp4: url)
                model.player.replaceCurrentItem(with: AVPlayerItem(url: url))
                model.player.play()
            } catch { self.error = error.localizedDescription }
        }.onDisappear { if !model.isFullscreen { model.stop() } }
    }
    private static func movie() async throws -> URL {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bilight-lifecycle.mp4")
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? BiliFailure.invalid }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<300 {
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error ?? BiliFailure.invalid }
                    try await Task.sleep(for: .milliseconds(2))
                }
                var buffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw BiliFailure.invalid }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let address = CVPixelBufferGetBaseAddress(buffer), let context = CGContext(data: address, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
                    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: frame % 280, y: 70, width: 40, height: 40))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 5)) else { throw writer.error ?? BiliFailure.invalid }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? BiliFailure.invalid }
            return url
        }.value
    }
}
#endif
