import XCTest

final class DynamicInteractionTests: XCTestCase {
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
