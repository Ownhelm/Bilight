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
                let video = Video(bvid: "BV12qnt6VEM1", aid: 42, title: "锁屏控制测试", cover: nil, duration: 60,
                    publishedAt: 0, owner: User(mid: 42, name: "Bilight", avatar: nil), views: 0)
                let record = DownloadRecord(id: UUID(), video: video,
                    part: VideoPart(cid: 43, page: 1, title: "离线测试", duration: 60), quality: 80, qualityLabel: "1080P")
                model.loadLocal(url, record: record)
            } catch { self.error = error.localizedDescription }
        }.onDisappear { if !model.isFullscreen { model.stop() } }
    }
    private static func movie() async throws -> URL {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bilight-lifecycle.mp4")
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100, AVEncoderBitRateKey: 64000])
            var pcm = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            var audioFormat: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &pcm, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat) == noErr, let audioFormat else { throw BiliFailure.invalid }
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
            writer.add(input)
            writer.add(audio)
            guard writer.startWriting() else { throw writer.error ?? BiliFailure.invalid }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<300 {
                while !input.isReadyForMoreMediaData || !audio.isReadyForMoreMediaData {
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
                // A real AAC track lets the system background-audio test exercise the audio pipeline.
                let silence = Data(count: 8820 * 2)
                var block: CMBlockBuffer?, sample: CMSampleBuffer?, sampleSize = 2
                guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: silence.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: silence.count, flags: 0, blockBufferOut: &block) == noErr, let block else { throw BiliFailure.invalid }
                let copied = silence.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: silence.count) }
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: CMTime(value: Int64(frame * 8820), timescale: 44100), decodeTimeStamp: .invalid)
                guard copied == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat, sampleCount: 8820, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr, let sample, audio.append(sample) else { throw writer.error ?? BiliFailure.invalid }
            }
            input.markAsFinished()
            audio.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? BiliFailure.invalid }
            return url
        }.value
    }
}
#endif
