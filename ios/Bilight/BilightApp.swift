import AVFoundation
import SwiftUI

@main struct BilightApp: App {
    @UIApplicationDelegateAdaptor(PlaybackOrientationDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()
    @State private var started = false
    @Environment(\.scenePhase) private var scene
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                    if InteractionRegression.player { PlaybackLifecycleRegressionView() }
                    else if InteractionRegression.enabled { InteractionRegressionView() } else { RootView() }
                #else
                    RootView()
                #endif
            }.environmentObject(app).onChange(of: scene) { old, phase in
                let stage: NativeStage = phase == .active ? .playbackActivated : (phase == .background ? .playbackBackgrounded : (old == .background ? .playbackForegrounding : .playbackResigned))
                if let player = PlaybackOrientationDelegate.active {
                    player.recordLifecycle(stage)
                    switch phase {
                    case .inactive: player.resignPlaybackActivity()
                    case .background: player.backgroundPlaybackActivity()
                    case .active: player.activatePlaybackActivity()
                    @unknown default: break
                    }
                } else { NativeTrace.mark(stage, ["container": 0]) }
                if phase == .background { app.downloads.requestBackgroundTime() }
                if phase == .active, app.user != nil { app.downloads.resumeInterrupted() }
            }.task {
                guard !started else { return }
                started = true
                #if DEBUG
                    if InteractionRegression.enabled { app.restoring = false; return }
                    if DemoFixtures.enabled {
                        await DemoFixtures.prepare(app)
                        return
                    }
                #endif
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
                if ProcessInfo.processInfo.environment["BILIGHT_ISOLATED_TESTS"] == "1"
                    || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                {
                    app.restoring = false
                    return
                }
                NativeTrace.mark(.boot)
                await app.restore()
                NativeTrace.mark(.accountRestored, ["authenticated": app.user == nil ? 0 : 1])
                #if DEBUG
                    let arguments = ProcessInfo.processInfo.arguments
                    if let index = arguments.firstIndex(of: "--smoke-download"), arguments.count > index + 1,
                        validBVID(arguments[index + 1]), app.user != nil
                    {
                        do {
                            let detail = try await app.client.video(arguments[index + 1])
                            guard let part = detail.parts.first else { throw BiliFailure.invalid }
                            let began = Date()
                            let id = try app.downloads.enqueue(video: detail.video, part: part, quality: 127, label: "最高可用")
                            app.path = [.downloads]
                            let deadline = Date().addingTimeInterval(150)
                            while let item = app.downloads.items.first(where: { $0.id == id }), ![DownloadState.completed, .failed].contains(item.state), Date() < deadline {
                                try await Task.sleep(for: .milliseconds(200))
                            }
                            if let item = app.downloads.items.first(where: { $0.id == id }), item.state == .completed {
                                NativeTrace.mark(.downloadFinished, ["quality": item.quality, "bytes": Int(item.bytes), "ms": Int(Date().timeIntervalSince(began) * 1000)])
                                app.path = [.downloads, .offline(id)]
                            } else { app.downloads.pause(id); NativeTrace.mark(.downloadFailed) }
                        } catch { NativeTrace.mark(.downloadFailed, ["code": Int((error as? BiliFailure)?.code ?? "") ?? (error as NSError).code]) }
                    }
                    if arguments.contains("--smoke-account"), let user = app.user {
                        for kind in 0...4 {
                            do {
                                switch kind {
                                case 0: _ = try await app.client.followedPeople(mid: user.mid, page: 1)
                                case 1: _ = try await app.client.followedPeople(mid: user.mid, page: 1, frequent: true)
                                case 2: _ = try await app.client.favoriteFolders(mid: user.mid, collected: false, page: 1)
                                case 3: _ = try await app.client.favoriteFolders(mid: user.mid, collected: true, page: 1)
                                default:
                                    let folders = try await app.client.favoriteFolders(mid: user.mid, collected: false, page: 1)
                                    if let folder = folders.items.first(where: { !$0.unavailable && $0.type == 11 }) {
                                        _ = try await app.client.favoriteContents(mid: user.mid, folder: folder, page: 1)
                                    }
                                }
                            } catch {
                                NativeTrace.mark(.libraryFailed, ["kind": kind, "code": Int((error as? BiliFailure)?.code ?? "") ?? 0])
                            }
                        }
                    }
                    if let index = arguments.firstIndex(of: "--smoke-video"), arguments.count > index + 1,
                        validBVID(arguments[index + 1])
                    {
                        app.path.append(.video(arguments[index + 1], 1, 0))
                    }
                #endif
            }
        }
    }
}
