import SwiftUI
import XCTest

@testable import Bilight

final class ResponsiveLayoutTests: XCTestCase {
    @MainActor func testLongVideoInformationWrapsOnSmallAndLargePhones() async throws {
        let app = AppModel()
        let model = PlayerModel()
        defer { model.stop() }
        let owner = User(mid: 7, name: "一个较长的UP主名字用于检查屏幕适配", avatar: nil)
        let video = Video(bvid: "BV0000000001", aid: 1,
            title: "这是一段较长的视频标题，用来检查小屏、大屏和辅助大字体下能否完整换行，并保持关注、三连与下载操作都在屏幕范围内。",
            cover: nil, duration: 60, publishedAt: 0, owner: owner, views: 99_999_999)
        let part = VideoPart(cid: 1, page: 1, title: "P1", duration: 60)
        let detail = VideoDetail(video: video, parts: [part], description: "", coinLimit: 2,
            statistics: VideoStatistics(likes: 30_070_000, coins: 3_390_000, favorites: 3_700_000))
        var normal: [CGFloat: CGFloat] = [:]
        for type in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
            for width: CGFloat in [320, 375, 390, 402, 430, 440] {
                let view = VideoInformationSection(detail: detail, part: part, model: model, onDownload: {})
                    .environmentObject(app).environment(\.dynamicTypeSize, type)
                let host = UIHostingController(rootView: view)
                host.safeAreaRegions = []
                let size = host.sizeThatFits(in: CGSize(width: width, height: 10000))
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
                XCTAssertTrue(size.height.isFinite && size.height > 0)
                if type == .large { normal[width] = size.height }
                if type == .accessibility5 {
                    XCTAssertGreaterThan(size.height, (normal[width] ?? 0) * 1.5, "Long information must grow vertically with the text size")
                }
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(normal[320]), try XCTUnwrap(normal[440]), "A narrow phone must wrap the long title instead of cutting its width")
    }
    @MainActor func testActionBarFitsNarrowToWidePhonesAndLargerText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let app = AppModel()
        let model = PlayerModel()
        defer { model.stop() }
        let counts = VideoStatistics(likes: 30_070_000, coins: 3_390_000, favorites: 3_700_000)
        var normalHeight: [CGFloat: CGFloat] = [:]
        for type in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
            for width: CGFloat in [320, 375, 390, 393, 402, 414, 428, 430, 440] {
                let view = VideoActionBar(model: model, bvid: "BV0000000001", cid: 1, statistics: counts, onDownload: {})
                    .environmentObject(app).environment(\.dynamicTypeSize, type)
                let host = UIHostingController(rootView: view)
                host.safeAreaRegions = []
                root.addChild(host); root.view.addSubview(host.view); host.didMove(toParent: root)
                let size = host.sizeThatFits(in: CGSize(width: width, height: 5000))
                host.view.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(25))
                host.view.layoutIfNeeded()
                let controls = descendants(host.view).compactMap { $0 as? LikePressTarget.Control }
                    .filter { !$0.isHidden && $0.alpha > 0 && $0.bounds.width > 0 }
                XCTAssertEqual(controls.count, 1, "\(width)pt / \(type) must expose a single active like control")
                for control in controls {
                    let frame = control.convert(control.bounds, to: host.view)
                    XCTAssertGreaterThanOrEqual(frame.width, 44)
                    XCTAssertGreaterThanOrEqual(frame.height, 44)
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
                    XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
                    XCTAssertLessThanOrEqual(frame.maxY, host.view.bounds.height + 0.5)
                    if type == .large {
                        XCTAssertEqual(frame.minX, 16, accuracy: 0.5, "Default left alignment must remain consistent across phones")
                        XCTAssertEqual(frame.width, 52, accuracy: 0.5)
                        XCTAssertEqual(frame.height, 58, accuracy: 0.5)
                    }
                }
                XCTAssertTrue(size.height.isFinite && size.height > 0)
                if type == .large { normalHeight[width] = size.height }
                if type == .accessibility5 {
                    XCTAssertGreaterThan(size.height, (normalHeight[width] ?? 0) * 1.5, "Large text must grow/wrap instead of being clipped into a fixed row")
                }
                host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
            }
        }
    }
    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
