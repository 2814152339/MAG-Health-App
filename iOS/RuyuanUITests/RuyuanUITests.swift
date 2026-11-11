import XCTest

final class RuyuanUITests: XCTestCase {
    func testHomeAndSampleReportFlow() {
        let app = XCUIApplication()
        app.launch()
        let sample = app.buttons["sampleReportButton"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        for _ in 0..<4 where !sample.isHittable { app.swipeUp() }
        XCTAssertTrue(sample.isHittable)
        sample.tap()
        XCTAssertTrue(app.navigationBars["演示报告"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["这是一份演示报告。分数、比例与图层均为示例，不代表你或任何真实人物的检测结果。"].exists)
        XCTAssertTrue(app.buttons["完成"].firstMatch.exists)
        app.buttons["完成"].firstMatch.tap()
        app.tabBars.buttons["报告"].tap()
        XCTAssertTrue(app.navigationBars["我的报告"].waitForExistence(timeout: 5))
    }
}
