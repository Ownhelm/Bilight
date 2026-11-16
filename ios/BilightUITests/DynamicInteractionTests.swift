import UIKit
import XCTest

final class DynamicInteractionTests: XCTestCase {
    func testDynamicCommentLikeUnlikeReplyAndRenderedEmote() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--regression-dynamic-comments"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.navigationBars["动态详情"].waitForExistence(timeout: 10))
        let like = app.buttons["video-comment-like-11"]
        XCTAssertTrue(like.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(like.value as? String, "5")
        XCTAssertTrue(hasRenderedCommentEmote(app), "The comment must render the fixture's green image inline")

        func assertLike(_ label: String, count: String) {
            let confirmed = NSPredicate(format: "enabled == true AND label == %@ AND value == %@", label, count)
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: confirmed, object: like)], timeout: 5)
            XCTAssertEqual(result, .completed, app.debugDescription)
        }
        like.tap()
        assertLike("取消点赞评论", count: "6")
        like.tap()
        assertLike("点赞评论", count: "5")

        app.buttons["video-comment-reply-11"].tap()
        let input = app.textViews["video-comment-input"], publish = app.buttons["video-comment-send"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertCompactComposer(app, title: "回复 动态评论者")
        XCTAssertTrue(publish.isEnabled)
        publish.tap()
        XCTAssertTrue(input.exists, "Tapping Publish on an empty reply must leave the composer open")
        input.tap()
        let message = "Isolated reply"
        input.typeText(message)
        publish.tap()
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(input.exists)
    }

    private func hasRenderedCommentEmote(_ app: XCUIApplication) -> Bool {
        for _ in 0..<8 {
            let screenshot = app.screenshot()
            guard let image = screenshot.image.cgImage else { return false }
            let width = image.width, height = image.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let rendered = rgba.withUnsafeMutableBytes { pixels -> Bool in
                guard let context = CGContext(data: pixels.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { return false }
            if stride(from: 0, to: rgba.count, by: 16).contains(where: { offset in
                rgba[offset] < 60 && rgba[offset + 1] > 210 && (20..<100).contains(rgba[offset + 2])
            }) {
                let evidence = XCTAttachment(screenshot: screenshot)
                evidence.name = "dynamic-inline-emote"
                evidence.lifetime = .keepAlways
                add(evidence)
                return true
            }
        }
        return false
    }

    func testVideoCommentComposerScrollsMentionCandidatesWithKeyboardVisible() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--regression-video-comment"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"; app.launch()
        defer { app.terminate() }

        let composer = app.buttons["video-comment-compose"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.tap()
        let input = app.textViews["video-comment-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertCompactComposer(app, title: "发表评论")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "ios-comment-small-window"
        evidence.lifetime = .keepAlways
        add(evidence)
        input.typeText("Hi ")
        XCTAssertFalse(app.buttons["video-comment-mention"].exists)
        XCTAssertFalse(app.buttons["video-comment-mention-101"].exists)
        input.typeText("@Ali")
        XCTAssertTrue(app.buttons["video-comment-mention-101"].waitForExistence(timeout: 5))
        let last = app.buttons["video-comment-mention-108"]
        let keyboard = app.keyboards.firstMatch
        let suggestions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-comment-mention-"))
        for _ in 0..<5 where !last.isHittable {
            let top = app.navigationBars["发表评论"].frame.maxY + 16
            // XCTest reports only the keyboard keys; the QuickType strip extends above that frame.
            let bottom = keyboard.frame.minY - 56
            guard let candidate = suggestions.allElementsBoundByIndex.reversed().first(where: {
                let y = $0.frame.midY
                return y > top + 36 && y < bottom && $0.isHittable
            }) else { break }
            let start = candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: 0, dy: top - candidate.frame.midY))
            start.press(forDuration: 0, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertTrue(last.isHittable, "The last mention suggestion must be reachable while composing on a narrow screen")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        last.tap()
        XCTAssertEqual(input.value as? String, "Hi @Alice 8 ")
        XCTAssertTrue(app.buttons["video-comment-send"].isEnabled)

        app.buttons["取消"].tap()
        let expand = app.buttons["comment-expand-11"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5)); expand.tap()
        let reply = app.buttons["video-comment-reply-12"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription); reply.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        XCTAssertFalse(app.buttons["video-comment-mention-32"].exists)
        input.typeText("＠")
        let participant = app.buttons["video-comment-mention-32"]
        XCTAssertTrue(participant.waitForExistence(timeout: 5)); participant.tap()
        XCTAssertEqual(input.value as? String, "@测试楼中楼 ")
    }

    private func assertCompactComposer(_ app: XCUIApplication, title: String) {
        let header = app.staticTexts[title].firstMatch
        XCTAssertTrue(header.exists, app.debugDescription)
        XCTAssertGreaterThan(header.frame.minY - app.frame.minY, app.frame.height * 0.27,
            "The keyboard must leave the top of the page visible above the compact composer")
        XCTAssertTrue(app.buttons["video-comment-send"].isHittable)
    }

    func testVideoCommentExpansionSurvivesChangingVideosAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--regression-video-comment"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"; app.launch()
        defer { app.terminate() }

        let header = app.buttons["评论"].firstMatch
        let composer = app.buttons["video-comment-compose"]
        let descriptionTitle = app.buttons["视频简介"].firstMatch
        let firstDescription = app.staticTexts["测试视频 42 简介"]
        let secondDescription = app.staticTexts["测试视频 43 简介"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
        if !composer.exists { header.tap() }
        if !firstDescription.exists { descriptionTitle.tap() }
        XCTAssertTrue(firstDescription.exists)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        header.tap()
        XCTAssertTrue(firstDescription.exists)
        XCTAssertFalse(composer.exists)
        app.buttons["切换测试视频"].tap()
        XCTAssertTrue(secondDescription.exists)
        XCTAssertTrue(header.exists); XCTAssertFalse(composer.exists)

        app.terminate(); app.launch()
        XCTAssertTrue(header.waitForExistence(timeout: 10)); XCTAssertFalse(composer.exists)
        XCTAssertTrue(firstDescription.exists)
        descriptionTitle.tap()
        XCTAssertFalse(firstDescription.exists)
        header.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        app.buttons["切换测试视频"].tap()
        XCTAssertFalse(secondDescription.exists)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
    }
    func testConnectedPhoneFollowedPeopleLoadsWithoutIncompleteDataError() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["我的账号"].waitForExistence(timeout: 15)); app.buttons["我的账号"].tap()
        let entry = app.buttons["我关注的UP主"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "本人已登录账号是此只读烟测的前提")
        entry.tap()
        let field = app.textFields["people-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("a\n")
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "返回的数据不完整")).firstMatch
        let loaded = app.staticTexts["people-search-complete"]
        let deadline = Date().addingTimeInterval(35)
        while !error.exists && !loaded.exists && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertFalse(error.exists, "真实关注名单不能因兼容性解析失败而不可用")
        XCTAssertTrue(loaded.exists, "真实关注名单应完成本地索引建立")
    }
    func testConnectedPhoneFollowedPeopleRestoresLocalSearchWithoutWaitingForRefresh() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["我的账号"].waitForExistence(timeout: 15)); app.buttons["我的账号"].tap()
        app.buttons["我关注的UP主"].tap()
        let field = app.textFields["people-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("a\n")
        XCTAssertTrue(app.staticTexts["people-search-complete"].waitForExistence(timeout: 3), "重新打开应直接检索已缓存名单，不等待完整网络刷新")
    }
    func testFollowedPeopleSearchUsesOnlyAvatarAndNameResults() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"; app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["我的账号"].waitForExistence(timeout: 10)); app.buttons["我的账号"].tap()
        app.buttons["我关注的UP主"].tap()
        XCTAssertTrue(app.navigationBars["我关注的UP主"].waitForExistence(timeout: 5))
        let field = app.textFields["people-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("a")
        XCTAssertTrue(app.staticTexts["找到 2 个用户关注用户"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["UP主名字补全"].exists)
        XCTAssertFalse(app.buttons["people-completion-37029661"].exists)
        let keyboard = XCTAttachment(screenshot: app.screenshot())
        keyboard.name = "ios-search-keyboard"; keyboard.lifetime = .keepAlways; add(keyboard)
        field.typeText("\n")
        XCTAssertTrue(app.staticTexts["小鹿Lawrence"].exists)
        XCTAssertTrue(app.staticTexts["超Carry的柴西"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ios-search-results"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "小鹿Lawrence")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["UP 主主页"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "a")
        XCTAssertTrue(app.staticTexts["找到 2 个用户关注用户"].exists)
        app.buttons["清空关注搜索"].tap()
        XCTAssertTrue(app.staticTexts["影视飓风"].waitForExistence(timeout: 5))
        field.tap(); field.typeText("NoSuchFollowedPerson")
        XCTAssertTrue(app.staticTexts["没有匹配的关注用户"].waitForExistence(timeout: 5))
    }
    func testSearchReturnsToTheSamePageAndPositionAfterVideo() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--browse-return-regression"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"; app.launch()
        defer { app.terminate() }
        let field = app.textFields["search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("浏览回归\n")
        try checkBrowseReturn(app)
    }
    func testSearchFiltersAppearOnlyInVideoResultsAndSurviveRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"
        app.launch()
        defer { app.terminate() }

        let field = app.textFields["search-field"]
        let filter = app.buttons["video-search-filter"]
        let world = app.buttons["去了一趟世界尽头。"]
        let london = app.buttons["去了一趟伦敦。"]
        let unrelated = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "人性、欲望与奇观")).firstMatch
        func submitSearch(captureHome: Bool = false) {
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            XCTAssertFalse(filter.exists)
            field.tap(); field.typeText("去了一趟")
            if captureHome {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.3)).tap()
                capture("search-filter-home")
            }
            app.buttons["submit-search"].tap()
            XCTAssertTrue(filter.waitForExistence(timeout: 5))
            XCTAssertEqual(field.value as? String, "去了一趟")
        }
        func choose(_ label: String) {
            filter.tap()
            let row = app.buttons[label]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }

        submitSearch(captureHome: true)
        choose("综合")
        if filter.value as? String != "综合" { choose("仅标题匹配") }
        XCTAssertTrue(unrelated.waitForExistence(timeout: 5))
        choose("仅标题匹配")
        XCTAssertEqual(filter.value as? String, "综合，仅标题匹配")
        XCTAssertTrue(world.waitForExistence(timeout: 5))
        XCTAssertFalse(unrelated.exists)
        XCTAssertTrue(london.isHittable)
        XCTAssertEqual(world.frame.minY, london.frame.minY, accuracy: 2)
        XCTAssertLessThan(world.frame.maxX, london.frame.minX)
        capture("search-filter-results")
        filter.tap()
        XCTAssertTrue(app.buttons["播放多"].waitForExistence(timeout: 5))
        capture("search-filter-open")
        app.buttons["最新"].tap()
        XCTAssertEqual(filter.value as? String, "最新，仅标题匹配")
        app.buttons["UP 主"].tap()
        XCTAssertFalse(filter.exists)
        app.buttons["视频"].tap()
        XCTAssertEqual(filter.value as? String, "最新，仅标题匹配")

        app.terminate(); app.launch()
        submitSearch()
        XCTAssertEqual(filter.value as? String, "最新，仅标题匹配")
        XCTAssertTrue(london.waitForExistence(timeout: 5))
        XCTAssertTrue(world.isHittable)
        XCTAssertFalse(unrelated.exists)
        XCTAssertLessThan(world.frame.minX, london.frame.minX)
        choose("仅标题匹配")
        choose("综合")
        XCTAssertEqual(filter.value as? String, "综合")
    }
    func testCreatorPostingSharesWatchLaterStateAndKeepsPlaybackSeparate() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["我的账号"].waitForExistence(timeout: 8))
        app.buttons["我的账号"].tap()
        let creator = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "柴西")).firstMatch
        XCTAssertTrue(creator.waitForExistence(timeout: 8))
        if !creator.isHittable { app.swipeUp() }
        creator.tap()
        let saved = app.buttons["watch-later-117489837016867"]
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        let savedState = NSPredicate(format: "label == %@", "移出稍后再看")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: savedState, object: saved)], timeout: 8), .completed)
        XCTAssertGreaterThanOrEqual(saved.frame.width, 44)
        XCTAssertGreaterThanOrEqual(saved.frame.height, 44)
        saved.tap()
        XCTAssertTrue(app.navigationBars["UP 主主页"].exists, "The overlay must act without opening the video")
        let title = app.buttons["人性、欲望与奇观，自驾拉斯维加斯，现实夜之城什么样？"]
        XCTAssertTrue(title.isHittable)
        title.tap()
        XCTAssertTrue(app.navigationBars["视频"].waitForExistence(timeout: 8))
    }

    func testCreatorReturnsToTheSamePageAndPositionAfterVideo() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--browse-return-regression"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"; app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["我的账号"].waitForExistence(timeout: 10)); app.buttons["我的账号"].tap()
        let creator = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "影视飓风")).firstMatch
        XCTAssertTrue(creator.waitForExistence(timeout: 10)); creator.tap()
        try checkBrowseReturn(app)
    }
    func testFavoriteReturnsToTheSamePageAndPositionAfterVideo() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--browse-return-regression"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"; app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["我的账号"].waitForExistence(timeout: 10)); app.buttons["我的账号"].tap()
        app.buttons["我的收藏"].tap(); app.buttons["我收藏的"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "浏览回归收藏夹")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10)); folder.tap()
        try checkBrowseReturn(app, targetTitle: "浏览回归 2-17")
    }
    private func checkBrowseReturn(_ app: XCUIApplication, targetTitle: String = "浏览回归 2-27") throws {
        let watchLater = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "watch-later-"))
        XCTAssertEqual(watchLater.count, 0, "Synthetic paging cards must not expose a write action")
        let next = app.buttons["下一页"]
        for _ in 0..<10 { if next.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(next.isHittable); next.tap()
        let target = app.buttons[targetTitle]
        for _ in 0..<10 { if target.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(target.isHittable)
        let before = target.frame
        target.tap(); XCTAssertTrue(app.navigationBars["视频"].waitForExistence(timeout: 10))
        app.navigationBars["视频"].buttons.firstMatch.tap()
        XCTAssertTrue(target.waitForExistence(timeout: 5)); XCTAssertTrue(target.isHittable, "Returning from video lost the visible item")
        XCTAssertEqual(target.frame.minY, before.minY, accuracy: 3, "Returning from video reset the scroll offset")
        XCTAssertTrue(app.staticTexts["第 2 页"].exists)
    }
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
        XCTAssertFalse(app.buttons["微信分享"].exists)
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

    func testDarkFollowingUsesTheSameBackgroundForTheHeadingAndEmptyOrFailedFeed() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        for (fixture, stateLabel) in [("--regression-following-empty", "暂无动态"), ("--regression-following-error", "重新加载")] {
            app.launchArguments = ["--demo", fixture]
            app.launch()
            XCTAssertTrue(app.buttons["我的账号"].waitForExistence(timeout: 8))
            if app.buttons["切换到深色模式"].exists { app.buttons["切换到深色模式"].tap() }
            XCTAssertTrue(app.buttons["切换到浅色模式"].exists)
            app.buttons["关注"].tap()
            let heading = app.staticTexts["我的关注"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5))
            let status = app.descendants(matching: .any).matching(identifier: stateLabel).firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5))

            let screenshot = app.screenshot()
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let crop = app.frame
            func color(y: CGFloat) throws -> [UInt8] {
                let xPixel = CGFloat(image.width) * 8 / crop.width
                let yPixel = CGFloat(image.height) * (y - crop.minY) / crop.height
                let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: xPixel.rounded(), y: yPixel.rounded(), width: 1, height: 1)))
                var bytes = [UInt8](repeating: 0, count: 4)
                let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return Array(bytes.prefix(3))
            }
            let background = try color(y: heading.frame.midY)
            XCTAssertEqual(try color(y: heading.frame.maxY + 16), background, "Empty or failed feeds do not have a secondary header strip")
            XCTAssertEqual(try color(y: app.frame.midY), background, "Empty or failed feeds keep the page background")
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = fixture == "--regression-following-empty" ? "following-dark-empty" : "following-dark-error"
            attachment.lifetime = .keepAlways
            add(attachment)
            if fixture == "--regression-following-error" { app.buttons["重新加载"].tap() }
            else { app.scrollViews.firstMatch.swipeDown() }
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testWatchLaterAccountEntryOpensCloudListInOfflineDemo() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let account = app.buttons["我的账号"]
        XCTAssertTrue(account.waitForExistence(timeout: 8))
        account.tap()
        let rows = app.collectionViews.firstMatch.buttons
        let watchLater = rows["稍后再看"]
        XCTAssertTrue(watchLater.waitForExistence(timeout: 8))
        XCTAssertLessThan(rows["我的收藏"].frame.minY, watchLater.frame.minY)
        XCTAssertLessThan(watchLater.frame.minY, rows["我的下载"].frame.minY)
        watchLater.tap()
        XCTAssertTrue(app.staticTexts["3 个视频"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["watch-later-remove-117489837016867"].exists)
        app.buttons["管理"].tap()
        XCTAssertTrue(app.staticTexts["已选 0 项"].exists)
        XCTAssertFalse(app.buttons["移出"].isEnabled)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "选择 ")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选 1 项"].exists)
        app.buttons["移出"].tap()
        XCTAssertTrue(app.alerts.buttons["确认移出"].exists)
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["3 个视频"].exists)
    }

    func testPlaybackSettingsKeepsSubpageAcrossFullscreenRotation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--regression-player"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCTAssertTrue(app.staticTexts["lifecycle-position"].waitForExistence(timeout: 12))

        let panel = app.descendants(matching: .any).matching(identifier: "player-settings-panel").firstMatch
        let options = app.scrollViews.matching(NSPredicate(
            format: "identifier IN %@", ["player-settings-options", "player-settings-panel"]
        )).firstMatch
        let fast = app.buttons["1.5×"]
        let toggle = app.switches["player-settings-danmaku"]
        let large = app.buttons["大"]
        let half = app.buttons["1/2"]
        let opacity = app.buttons["75%"]
        let heading = app.staticTexts["播放设置"]

        func assertPanelLayout(landscape: Bool) {
            let layout = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let viewport = app.frame
                let attached = panel.frame
                if landscape {
                    // The scroll view's accessibility frame may include clipped content below the panel.
                    return viewport.width > viewport.height && attached.minX > viewport.midX
                        && attached.width <= 362
                        && (10...100).contains(viewport.maxX - attached.maxX)
                        && attached.minY - viewport.minY >= 10
                        && abs(attached.midY - viewport.midY) <= 22
                }
                return viewport.height > viewport.width && attached.minY > viewport.minY
                    && abs(attached.minX - viewport.minX) <= 2 && abs(attached.maxX - viewport.maxX) <= 2
                    && abs(attached.maxY - viewport.maxY) <= 2
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [layout], timeout: 5), .completed,
                "Portrait uses a bottom sheet and landscape uses an inset right panel: app \(app.frame), panel \(panel.frame)")
        }

        func reveal(_ element: XCUIElement, towardTop: Bool = false) {
            XCTAssertTrue(options.waitForExistence(timeout: 3))
            for _ in 0..<5 {
                if element.exists, element.isHittable {
                    let frame = element.frame
                    if options.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
                }
                if towardTop { options.swipeDown() }
                else { options.swipeUp() }
            }
            XCTAssertTrue(element.exists && element.isHittable, "The option should be reachable in the settings scroll view")
        }

        func assertSpeeds() {
            for label in ["0.5×", "0.75×", "1.0×", "1.25×", "1.5×", "2.0×"] {
                XCTAssertTrue(app.buttons[label].isHittable, "The Android preset \(label) belongs to the settings body")
            }
        }

        func tapOutside(landscape: Bool) {
            let viewport = app.frame
            let y = landscape ? 0.5 : (panel.frame.minY - viewport.minY) / (2 * viewport.height)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: y)).tap()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        }

        openPlaybackSettings(app, fullscreen: false, controlsCapture: "内嵌：播放器图标")
        assertPanelLayout(landscape: false)
        XCTAssertTrue(app.buttons["1080P"].waitForExistence(timeout: 5))
        assertSpeeds()
        XCTAssertTrue(app.staticTexts["字幕"].exists)
        XCTAssertTrue(toggle.isHittable)
        fast.tap()
        XCTAssertTrue(fast.isSelected)
        XCTAssertTrue(heading.isHittable, "Selecting a speed keeps the options open in place")
        capture("内嵌：播放设置")
        tapOutside(landscape: false)

        openPlaybackSettings(app, fullscreen: false)
        let headingCenter = heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        headingCenter.press(forDuration: 0.05, thenDragTo: headingCenter.withOffset(CGVector(dx: 0, dy: 180)))
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3), "Dragging a portrait sheet down dismisses it")

        openPlaybackSettings(app, fullscreen: false)
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        let switchControl = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        XCTAssertEqual(toggle.value as? String, "0")
        let settingsHeight = panel.frame.height
        switchControl.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            panel.frame.height > settingsHeight + 20
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed,
            "The settings sheet grows to show the available danmaku options")
        reveal(large)
        large.tap()
        XCTAssertTrue(large.isSelected)
        reveal(half)
        half.tap()
        XCTAssertTrue(half.isSelected)
        reveal(opacity)
        opacity.tap()
        XCTAssertTrue(opacity.isSelected)
        capture("内嵌：弹幕样式")
        tapOutside(landscape: false)

        let fullscreenToggle = app.buttons["player-fullscreen-toggle"]
        if !fullscreenToggle.isHittable { playbackSurface(app, fullscreen: false).tap() }
        fullscreenToggle.tap()
        // The fullscreen button requests landscape itself. Avoid asking for the opposite
        // orientation while that transition is still moving the gear button.
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        // Device and interface use opposite landscape names. Match the device to the
        // active interface so assigning .portrait later generates a real rotation event.
        XCUIDevice.shared.orientation = .landscapeLeft
        openPlaybackSettings(app, fullscreen: true, controlsCapture: "横屏全屏：播放器图标")
        assertPanelLayout(landscape: true)
        assertSpeeds()
        XCTAssertTrue(fast.isSelected)
        capture("横屏全屏：播放设置")
        let slow = app.buttons["0.75×"]
        slow.tap()
        XCTAssertTrue(slow.isSelected, "Landscape choices remain interactive")
        fast.tap()

        reveal(opacity)
        XCTAssertTrue(opacity.isSelected, "The selected style carries from the portrait sheet to landscape")
        tapOutside(landscape: true)
        openPlaybackSettings(app, fullscreen: true)
        XCUIDevice.shared.orientation = .portrait
        assertPanelLayout(landscape: false)
        reveal(fast, towardTop: true)
        XCTAssertTrue(fast.isSelected, "Rotation preserves the selected playback speed")
        reveal(toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        reveal(large)
        XCTAssertTrue(large.isSelected)
        reveal(half)
        XCTAssertTrue(half.isSelected)
        reveal(opacity)
        XCTAssertTrue(opacity.isSelected, "Rotation preserves the selected danmaku styles")
        capture("竖屏全屏：弹幕样式")
        reveal(toggle, towardTop: true)
        switchControl.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(large.exists, "Turning off danmaku hides its style options")
        tapOutside(landscape: false)
    }

    func testPlaybackSettingsMatchesAndroidColorsInBothAppearances() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"
        XCUIDevice.shared.orientation = .portrait
        let palettes: [(Bool, [UInt8], [UInt8])] = [
            (false, [255, 255, 255], [251, 235, 240]),
            (true, [30, 32, 40], [60, 37, 50]),
        ]
        for (dark, background, selected) in palettes {
            app.launchArguments = ["--regression-player", "-bilight.darkAppearance", dark ? "YES" : "NO"]
            app.launch()
            XCTAssertTrue(app.staticTexts["lifecycle-position"].waitForExistence(timeout: 12))
            openPlaybackSettings(app, fullscreen: false)
            let heading = app.staticTexts["播放设置"]
            let quality = app.buttons["1080P"]
            XCTAssertTrue(quality.isSelected)
            let viewport = app.frame
            let screenshot = app.screenshot()
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            func color(at point: CGPoint) throws -> [UInt8] {
                let x = CGFloat(image.width) * (point.x - viewport.minX) / viewport.width
                let y = CGFloat(image.height) * (point.y - viewport.minY) / viewport.height
                let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: x.rounded(), y: y.rounded(), width: 1, height: 1)))
                var bytes = [UInt8](repeating: 0, count: 4)
                let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return Array(bytes.prefix(3))
            }
            XCTAssertEqual(try color(at: CGPoint(x: viewport.maxX - 40, y: heading.frame.midY)), background)
            XCTAssertEqual(try color(at: CGPoint(x: quality.frame.minX + 10, y: quality.frame.midY)), selected)
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = dark ? "播放设置：深色配色" : "播放设置：浅色配色"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    private func openPlaybackSettings(_ app: XCUIApplication, fullscreen: Bool, controlsCapture: String? = nil) {
        let settings = app.buttons["player-settings"]
        let panel = app.descendants(matching: .any).matching(identifier: "player-settings-panel").firstMatch
        for _ in 0..<3 {
            if !settings.exists || !settings.isHittable {
                playbackSurface(app, fullscreen: fullscreen).tap()
                // Wait for the newly shown controls to finish fading in.
                Thread.sleep(forTimeInterval: 0.22)
            }
            guard settings.exists && settings.isHittable else { continue }
            let frame = settings.frame
            let viewport = app.frame
            if let controlsCapture { capture(controlsCapture) }
            // The controls can fade during capture. Use the last visible location so the next attempt can reveal them.
            app.coordinate(withNormalizedOffset: CGVector(
                dx: (frame.midX - viewport.minX) / viewport.width,
                dy: (frame.midY - viewport.minY) / viewport.height
            )).tap()
            if panel.waitForExistence(timeout: 1) { break }
        }
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["播放设置"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRealScrubbingPreservesPositionAndPlaybackStateInlineAndFullscreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--regression-player"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let position = app.staticTexts["lifecycle-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 12))
        let ready = Date().addingTimeInterval(8)
        while (Double(position.label) ?? 0) < 0.5 && Date() < ready { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertGreaterThan(Double(position.label) ?? 0, 0.3)
        let progress = app.sliders["player-seek-slider"]
        let play = app.buttons["player-play-pause"]
        var fullscreen = false
        func revealControls() {
            if progress.exists && progress.isHittable { return }
            playbackSurface(app, fullscreen: fullscreen).tap()
            let deadline = Date().addingTimeInterval(1)
            repeat {
                if progress.exists && progress.isHittable { return }
                Thread.sleep(forTimeInterval: 0.05)
            } while Date() < deadline
            XCTFail("A tap must reveal the progress slider before it auto-hides")
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
            let start = seconds()
            point(start).press(forDuration: 0.1, thenDragTo: point(target))
            // XCUI can wait for idle longer than the controls' auto-hide delay.
            revealControls()
            let released = seconds()
            XCTAssertGreaterThan((released - start) * (target > start ? 1 : -1), 1, "The native thumb must move in the direction of the drag")
            // XCUI measures the entire control. The native track insets vary by SDK and orientation.
            XCTAssertEqual(released, target, accuracy: 8)
            Thread.sleep(forTimeInterval: 0.2)
            revealControls()
            XCTAssertEqual(seconds(), released, accuracy: playing ? 3 : 1,
                           "The released scrubber must stay at the new position rather than return to the old one")
            XCTAssertEqual(play.label, playing ? "暂停" : "播放")
            print("[real scrub] target=\(target) released=\(released) settled=\(seconds()) playing=\(playing)")
        }
        for enterFullscreen in [false, true] {
            if enterFullscreen {
                let fullscreenToggle = app.buttons["player-fullscreen-toggle"]
                XCTAssertTrue(fullscreenToggle.waitForNonExistence(timeout: 3))
                playbackSurface(app, fullscreen: false).tap()
                fullscreenToggle.tap()
                fullscreen = true
                Thread.sleep(forTimeInterval: 0.6)
            }
            revealControls()
            if play.label == "暂停" { play.tap() }
            XCTAssertEqual(play.label, "播放")
            drag(to: fullscreen ? 45 : 35, playing: false)
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
    func testRealPlaybackGesturesWorkInlineAndFullscreen() throws {
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
        for fullscreen in [false, true] {
            if fullscreen {
                let toggle = app.buttons["player-fullscreen-toggle"]
                if !toggle.isHittable { playbackSurface(app, fullscreen: false).tap() }
                toggle.tap(); sleep(1)
            }
            let play = app.buttons["player-play-pause"]
            playbackSurface(app, fullscreen: fullscreen, fraction: 0.2).doubleTap()
            XCTAssertEqual(play.label, "播放", "A double tap at the left pauses playback")
            let progress = app.sliders["player-seek-slider"]
            func seconds() -> Double {
                let clock = ((progress.value as? String) ?? "").split(separator: "/").first ?? ""
                return clock.split(separator: ":").reduce(0) { $0 * 60 + (Double($1.trimmingCharacters(in: .whitespaces)) ?? 0) }
            }
            let before = seconds()
            playbackSurface(app, fullscreen: fullscreen, fraction: 0.4).press(forDuration: 0.05,
                thenDragTo: playbackSurface(app, fullscreen: fullscreen, fraction: 0.65))
            XCTAssertEqual(seconds(), before + 15, accuracy: 4)
            XCTAssertEqual(play.label, "播放", "Scrubbing preserves a paused video")
            playbackSurface(app, fullscreen: fullscreen, fraction: 0.65).press(forDuration: 0.05,
                thenDragTo: playbackSurface(app, fullscreen: fullscreen, fraction: 0.4))
            XCTAssertEqual(seconds(), before, accuracy: 4)
            playbackSurface(app, fullscreen: fullscreen, fraction: 0.8).doubleTap()
            XCTAssertEqual(play.label, "暂停", "A double tap at the right resumes playback")
        }
        for (label, x, start, end) in [("亮度", 0.25, 0.65, 0.25), ("音量", 0.75, 0.25, 0.65)] {
            let startPoint = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: start))
            let endPoint = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: end))
            let feedback = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "\\s*\(label) [0-9]{1,3}%\\s*")).firstMatch
            startPoint.press(forDuration: 0.05, thenDragTo: endPoint)
            XCTAssertTrue(feedback.exists, "A fullscreen swipe must show the current \(label) percentage")
            XCTAssertTrue(feedback.waitForNonExistence(timeout: 3))
        }
    }
    private func playbackSurface(_ app: XCUIApplication, fullscreen: Bool, fraction: CGFloat = 0.5) -> XCUICoordinate {
        let y = fullscreen ? app.frame.midY : app.staticTexts["lifecycle-position"].frame.minY - 120
        return app.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: (y - app.frame.minY) / app.frame.height))
    }
    func testInlineVerticalSwipesAdjustVideoAndScrollOutsideIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--regression-player", "--regression-inline-scroll"]
        app.launchEnvironment["BILIGHT_ISOLATED_TESTS"] = "1"
        app.launch()
        defer { app.terminate() }
        let above = app.staticTexts["lifecycle-above-player"]
        let position = app.staticTexts["lifecycle-position"]
        let comments = app.staticTexts["lifecycle-comment-0"]
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        for (label, x, delta) in [("亮度", 0.25, -60.0), ("音量", 0.75, 45.0)] {
            let before = position.frame.minY
            let start = playbackSurface(app, fullscreen: false, fraction: x)
            let feedback = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "\\s*\(label) [0-9]{1,3}%\\s*")).firstMatch
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)))
            XCTAssertTrue(feedback.exists, "A swipe on the inline video must adjust \(label)")
            XCTAssertEqual(position.frame.minY, before, accuracy: 2, "Swiping the video must not scroll the page")
        }
        for outside in [above, comments] {
            let before = position.frame.minY
            let start = outside.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -60)))
            XCTAssertLessThan(position.frame.minY, before - 20, "A swipe outside the video must scroll the page")
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
                if !app.buttons["player-fullscreen-toggle"].isHittable { playbackSurface(app, fullscreen: false).tap() }
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
                if !exit.isHittable { playbackSurface(app, fullscreen: true).tap() }
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
