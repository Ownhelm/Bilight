import XCTest

final class DynamicInteractionTests: XCTestCase {
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
