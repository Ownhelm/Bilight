import XCTest

final class DynamicInteractionTests: XCTestCase {
    func testConnectedPhoneOpensVideoDynamicWithoutChangingLikes() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        defer { app.terminate() }
        let following = app.buttons["关注"]
        XCTAssertTrue(following.waitForExistence(timeout: 15)); following.tap()
        let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "dynamic-video-title-")).firstMatch
        let deadline = Date().addingTimeInterval(35)
        while !title.exists && Date() < deadline {
            if app.buttons["重新登录"].exists { XCTFail("Real account login is required"); return }
            Thread.sleep(forTimeInterval: 0.5)
            if !title.exists && app.scrollViews.firstMatch.exists { app.swipeUp() }
        }
        XCTAssertTrue(title.exists, "A real followed video dynamic must expose its title entry")
        if !title.isHittable { app.swipeUp() }
        let id = title.identifier.replacingOccurrences(of: "dynamic-video-title-", with: "")
        title.tap()
        XCTAssertTrue(app.navigationBars["动态详情"].waitForExistence(timeout: 15))
        let like = app.buttons["dynamic-like-" + id]
        let end = Date().addingTimeInterval(10)
        while !like.isHittable && Date() < end { app.swipeUp() }
        XCTAssertTrue(like.exists); XCTAssertTrue(like.isEnabled)
        XCTAssertGreaterThanOrEqual(like.frame.height, 44)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "dynamic-real-iphone-detail"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["dynamic-video-title-" + id].waitForExistence(timeout: 5))
        let comments = app.buttons["dynamic-open-" + id]
        for _ in 0..<3 { if comments.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(comments.isHittable); comments.tap()
        XCTAssertTrue(app.navigationBars["动态详情"].waitForExistence(timeout: 15))
        XCTAssertLessThanOrEqual(app.activityIndicators.count, 1, "The comment entry shares the dynamic detail loading indicator")
        app.navigationBars.buttons.firstMatch.tap()
    }

    func testLikeDoesNotDisableCoinAndFavoriteEntryPoints() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"; app.launch()
        defer { app.terminate() }
        let search = app.textFields["search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("BV12qnt6VEM1\n")
        let like = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "点赞，")).firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 10)); like.tap()
        let coin = app.buttons["投币"], favorite = app.buttons["收藏"]
        XCTAssertTrue(coin.isEnabled); XCTAssertTrue(favorite.isEnabled)
        coin.tap(); XCTAssertTrue(app.navigationBars["投币"].waitForExistence(timeout: 5)); app.buttons["取消"].tap()
        XCTAssertTrue(favorite.isEnabled); favorite.tap()
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "收藏到")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(coin.isEnabled); XCTAssertTrue(favorite.isEnabled)
    }

    func testShareFromAccountVideoAppearsAboveTheAccountSheet() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"
        app.launch()
        defer { app.terminate() }
        let account = app.buttons["我的账号"]
        XCTAssertTrue(account.waitForExistence(timeout: 10)); account.tap()
        let creator = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "影视飓风")).firstMatch
        XCTAssertTrue(creator.waitForExistence(timeout: 10)); creator.tap()
        let video = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "去了一趟世界尽头")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 10)); video.tap()
        let transfer = app.buttons["转发"]
        XCTAssertTrue(transfer.waitForExistence(timeout: 10)); transfer.tap()
        let copy = app.buttons["复制链接"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3), "Share must be presented above videos opened within the account sheet")
        XCTAssertTrue(copy.isHittable)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "share-from-account-visible"; capture.lifetime = .keepAlways; add(capture)
        copy.tap()
        XCTAssertTrue(app.staticTexts["链接已复制"].waitForExistence(timeout: 2))
        transfer.tap(); app.buttons["取消"].tap()
        XCTAssertFalse(app.buttons["复制链接"].exists)
        transfer.tap(); app.buttons["系统分享"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5) || app.buttons["Copy"].exists || app.buttons["拷贝"].exists)
    }

    func testShareSheetCopiesAndDismissesBeforeSystemHandoff() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"
        app.launch()
        defer { app.terminate() }
        let search = app.textFields["search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("BV12qnt6VEM1\n")
        let transfer = app.buttons["转发"]
        XCTAssertTrue(transfer.waitForExistence(timeout: 10)); transfer.tap()
        let copy = app.buttons["复制链接"], system = app.buttons["系统分享"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3)); XCTAssertTrue(system.isHittable)
        XCTAssertFalse(app.buttons["二维码"].exists)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        XCTAssertGreaterThan(copy.frame.minY, app.frame.maxY - 240, "Share controls belong in a shallow bottom panel")
        XCTAssertLessThan(copy.frame.minY, app.buttons["取消"].frame.minY)
        let capture = XCTAttachment(screenshot: app.descendants(matching: .any).matching(identifier: "video-share-sheet").firstMatch.screenshot()); capture.name = "share-compact-ios"; capture.lifetime = .keepAlways; add(capture)
        copy.tap()
        XCTAssertTrue(app.staticTexts["链接已复制"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["取消"].exists)
        transfer.tap(); app.buttons["取消"].tap()
        XCTAssertFalse(app.buttons["复制链接"].exists)
        transfer.tap(); app.buttons["系统分享"].tap()
        XCTAssertFalse(app.buttons["取消"].waitForExistence(timeout: 1), "Custom chooser must close before the native share sheet")
    }

    func testRealScrubbingPreservesPositionAndPlaybackStateInlineAndFullscreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--regression-player"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let position = app.staticTexts["lifecycle-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 12))
        let ready = Date().addingTimeInterval(8)
        while (Double(position.label) ?? 0) < 0.5 && Date() < ready { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThan(Double(position.label) ?? 0, 0.3)
        let progress = app.sliders["player-seek-slider"]
        let play = app.buttons["player-play-pause"]
        func revealControls() {
            if !progress.isHittable {
                app.buttons["播放设置"].coordinate(withNormalizedOffset: CGVector(dx: -3, dy: 2)).tap()
            }
            XCTAssertTrue(progress.waitForExistence(timeout: 3))
            XCTAssertTrue(progress.isHittable)
        }
        func seconds() -> Double {
            let raw = (progress.value as? String ?? "").components(separatedBy: "/")[0]
                .trimmingCharacters(in: .whitespaces)
            let pieces = raw.split(separator: ":").compactMap { Double($0) }
            XCTAssertEqual(pieces.count, 2, "The actual scrubber must expose elapsed time")
            return pieces.count == 2 ? pieces[0] * 60 + pieces[1] : 0
        }
        func drag(to target: Double, playing: Bool) {
            revealControls()
            let thumbInset = min(0.2, 15 / progress.frame.width)
            func point(_ time: Double) -> XCUICoordinate {
                progress.coordinate(withNormalizedOffset: CGVector(
                    dx: thumbInset + (1 - thumbInset * 2) * min(1, max(0, time / 60)), dy: 0.5))
            }
            point(seconds()).press(forDuration: 0.1, thenDragTo: point(target))
            let released = seconds()
            XCTAssertEqual(released, target, accuracy: 3, "Releasing a real drag must retain its selected position")
            Thread.sleep(forTimeInterval: 0.2)
            revealControls()
            XCTAssertEqual(seconds(), released, accuracy: playing ? 3 : 1,
                           "The released scrubber must stay at the new position rather than return to the old one")
            XCTAssertEqual(play.label, playing ? "暂停" : "播放")
            print("[real scrub] target=\(target) released=\(released) settled=\(seconds()) playing=\(playing)")
        }
        for fullscreen in [false, true] {
            revealControls()
            if fullscreen {
                app.buttons["player-fullscreen-toggle"].tap()
                Thread.sleep(forTimeInterval: 0.6)
                revealControls()
            }
            if play.label == "暂停" { play.tap() }
            XCTAssertEqual(play.label, "播放")
            drag(to: 35, playing: false)
            drag(to: 12, playing: false)
            revealControls(); play.tap()
            XCTAssertEqual(play.label, "暂停")
            drag(to: 25, playing: true)
        }
    }

    func testSystemMediaControlsPauseAndResumeTheBackgroundPlayer() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--regression-player"]; app.launch()
        defer { app.activate() }
        let position = app.staticTexts["lifecycle-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 12))
        let deadline = Date().addingTimeInterval(8)
        while (Double(position.label) ?? 0) < 0.5 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func openControls() {
            XCUIDevice.shared.press(.home)
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.005))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.6)))
        }
        openControls()
        let title = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "锁屏控制测试")).firstMatch
        if !title.waitForExistence(timeout: 5) {
            let attachment = XCTAttachment(string: springboard.debugDescription); attachment.lifetime = .keepAlways; add(attachment)
            let folder = springboard.otherElements["cc-root-folder-view"]
            if folder.exists && folder.descendants(matching: .button).count == 0 {
                throw XCTSkip("This simulator has an empty Control Center layout; system media controls require a configured tile or a real device")
            }
        }
        XCTAssertTrue(title.exists, "The system media card must show the current video")
        let pause = springboard.buttons.matching(NSPredicate(format: "identifier == 'PauseButton' OR label == 'Pause' OR label == '暂停'")).firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 3)); pause.tap()
        app.activate(); XCTAssertTrue(position.waitForExistence(timeout: 5))
        let paused = Double(position.label) ?? 0
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(Double(position.label) ?? 0, paused, accuracy: 0.2, "Returning must preserve the system pause")
        openControls()
        let play = springboard.buttons.matching(NSPredicate(format: "identifier == 'PlayButton' OR label == 'Play' OR label == '播放'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 3)); play.tap()
        app.activate(); Thread.sleep(forTimeInterval: 0.8)
        XCTAssertGreaterThan(Double(position.label) ?? 0, paused + 0.4, "System play must resume the same video")
    }
    func testAudioPlaybackActuallyAdvancesWhileTheAppIsOnHome() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--regression-player"]; app.launch()
        let position = app.staticTexts["lifecycle-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 12))
        let deadline = Date().addingTimeInterval(8)
        while (Double(position.label) ?? 0) < 0.5 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let before = Double(position.label) ?? 0
        XCTAssertGreaterThan(before, 0.3)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertGreaterThan(Double(position.label) ?? 0, before + 2.5, "Audio must advance during Home, rather than only restart after returning")
    }
    func testRealDoubleTapZonesWorkInlineAndFullscreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--regression-player"]; app.launch()
        XCTAssertTrue(app.staticTexts["lifecycle-position"].waitForExistence(timeout: 10))
        sleep(2)
        for fullscreen in [false, true] {
            if fullscreen {
                let toggle = app.buttons["player-fullscreen-toggle"]
                if !toggle.exists { app.buttons["播放设置"].coordinate(withNormalizedOffset: CGVector(dx: -3, dy: 2)).tap() }
                toggle.tap(); sleep(1)
            }
            func doubleTap(_ fraction: CGFloat) {
                let settings = app.buttons["播放设置"]
                XCTAssertTrue(settings.waitForExistence(timeout: 3))
                let y = (settings.frame.midY + 76 - app.frame.minY) / app.frame.height
                app.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: y)).doubleTap()
            }
            doubleTap(0.5)
            let play = app.buttons["player-play-pause"]
            XCTAssertEqual(play.label, "播放", "The middle fifth pauses playback")
            doubleTap(0.2)
            doubleTap(0.8)
            doubleTap(0.5)
            XCTAssertEqual(play.label, "暂停", "A second center double tap resumes playback")
        }
    }
    func testPlaybackReturnsFromHomeInInlineAndFullscreenWithoutBlackScreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--regression-player"]
        app.launch()
        let position = app.staticTexts["lifecycle-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        sleep(2)
        for fullscreen in [false, true] {
            if fullscreen {
                app.buttons["播放设置"].coordinate(withNormalizedOffset: CGVector(dx: -3, dy: 2)).tap()
                app.buttons["player-fullscreen-toggle"].tap()
                sleep(1)
            }
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
            XCUIDevice.shared.orientation = .portrait
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
            sleep(1)
            if fullscreen && !app.buttons["lifecycle-response"].exists {
                let exit = app.buttons["player-fullscreen-toggle"]
                if !exit.exists { app.buttons["播放设置"].coordinate(withNormalizedOffset: CGVector(dx: -3, dy: 2)).tap() }
                XCTAssertTrue(exit.waitForExistence(timeout: 3), "Fullscreen controls must recover after foregrounding")
                exit.tap()
            }
            let response = app.buttons["lifecycle-response"]
            XCTAssertTrue(response.waitForExistence(timeout: 3), "A stale black fullscreen container must not cover the page")
            let before = response.label
            response.tap()
            XCTAssertNotEqual(response.label, before, "The app must respond to taps after returning from Home")
            let start = Double(position.label) ?? 0
            let play = app.buttons["player-play-pause"]
            if play.exists && play.label == "播放" { play.tap() }
            sleep(1)
            XCTAssertGreaterThan(Double(position.label) ?? 0, start + 0.3, "Playback must advance after foregrounding")
        }
    }
    func testGalleryPagesFollowSlowDragsAndKeepTheSelectedPage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--interaction-regression", "--regression-gallery"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"
        app.launch()
        defer { app.terminate() }
        let first = app.buttons["查看第1张图片，共8张"]
        XCTAssertTrue(first.waitForExistence(timeout: 10)); first.tap()
        XCTAssertTrue(app.staticTexts["1 / 8"].waitForExistence(timeout: 3))
        func drag(_ from: CGFloat, _ to: CGFloat) {
            app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        // A short, slow drag returns to the same page; a deliberate drag advances just one.
        drag(0.7, 0.55)
        XCTAssertTrue(app.staticTexts["1 / 8"].exists)
        for page in 2...8 {
            drag(0.85, 0.15)
            XCTAssertTrue(app.staticTexts["\(page) / 8"].waitForExistence(timeout: 2))
        }
        for page in stride(from: 7, through: 1, by: -1) {
            drag(0.15, 0.85)
            XCTAssertTrue(app.staticTexts["\(page) / 8"].waitForExistence(timeout: 2))
        }
        app.buttons["关闭图片"].tap()
        app.buttons["查看第6张图片，共8张"].tap()
        XCTAssertTrue(app.staticTexts["6 / 8"].waitForExistence(timeout: 3), "Opening any thumbnail must retain its initial page")
    }

    func testExpandDoesNotOpenPictureAndShowsFullText() throws {
        try assertExpand(grid: false)
    }
    func testExpandBesidePictureGridDoesNotOpenGallery() throws {
        try assertExpand(grid: true)
    }
    private func assertExpand(grid: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--interaction-regression"] + (grid ? ["--regression-grid"] : [])
        app.launch()
        let expand = app.buttons["展开"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        let body = app.staticTexts["dynamic-body-123456789"]
        let collapsedHeight = body.frame.height
        XCTAssertGreaterThanOrEqual(expand.frame.height, 44)
        // Hit the lower edge next to the picture, where its clipped content used to steal taps.
        expand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(app.buttons["收起"].waitForExistence(timeout: 2), "Expand must change text state rather than open the gallery")
        XCTAssertFalse(app.buttons["关闭图片"].exists)
        XCTAssertGreaterThan(body.frame.height, collapsedHeight + 60)
        app.buttons["收起"].tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 2))
        XCTAssertEqual(body.frame.height, collapsedHeight, accuracy: 2)
        app.buttons[grid ? "查看第1张图片，共4张" : "查看图片"].tap()
        XCTAssertTrue(app.buttons["关闭图片"].waitForExistence(timeout: 2), "Picture taps must still open the gallery")
        app.buttons["关闭图片"].tap()
    }
}
