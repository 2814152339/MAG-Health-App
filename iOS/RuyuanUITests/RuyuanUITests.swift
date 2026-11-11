import XCTest
import CoreGraphics

/// Uses only the bundled vector illustration and explicitly synthetic sample data.
/// Never imports a photo, opens the camera, or sends personal data to a server.
final class RuyuanUITests: XCTestCase {
    private var recordingFailure = false
    override func setUpWithError() throws { continueAfterFailure = false }

    override func record(_ issue: XCTIssue) {
        if !recordingFailure {
            recordingFailure = true
            let app = XCUIApplication()
            capture("failure-screen", app: app)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "failure-accessibility-tree"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            recordingFailure = false
        }
        super.record(issue)
    }

    func testHomeAndSampleReportFlow() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["sampleReportButton"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["startCaptureButton"].isHittable, "Start detection must be visible on the initial small-screen viewport.")
        XCTAssertTrue(app.buttons["importPhotoButton"].isHittable)
        capture("home", app: app)
        openSample(in: app)
        XCTAssertTrue(app.staticTexts["这是一份演示报告。分数、比例与图层均为示例，不代表你或任何真实人物的检测结果。"].exists)
        capture("report", app: app)
        let photo = identified("reportOriginalPhoto", in: app)
        XCTAssertTrue(reveal(photo, in: app))
        photo.tap()
        let photoNav = app.navigationBars["原图"]
        XCTAssertTrue(photoNav.waitForExistence(timeout: 5))
        XCTAssertTrue(identified("overlayViewer", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["原图"].firstMatch.isSelected)
        capture("original-photo", app: app)
        photoNav.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["演示报告"].waitForExistence(timeout: 5))
        let done = app.navigationBars["演示报告"].buttons["完成"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        let history = app.tabBars.buttons["报告"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        XCTAssertTrue(app.navigationBars["我的报告"].waitForExistence(timeout: 5))
    }

    func testSampleDetailDimensionsOverlayAndLocalFeedback() {
        let app = XCUIApplication()
        app.launch()
        openSample(in: app)

        let detailsButton = identified("openReportDetails", in: app)
        XCTAssertTrue(reveal(detailsButton, in: app), "The report detail entry must be reachable by scrolling.")
        detailsButton.tap()
        let detail = identified("reportDetailSheet", in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 5))

        for dimension in ["waterOil", "tone", "sensitivity", "smoothness", "aging"] {
            tapDetailTab(dimension, app: app)
            if dimension == "tone" {
                let tone = app.staticTexts["1. 肤色均匀度"].firstMatch
                XCTAssertTrue(reveal(tone, in: app))
                capture("detail-tone", app: app)
            }
        }

        let chart = app.staticTexts["分区域纹理响应"].firstMatch
        XCTAssertTrue(reveal(chart, in: app), "Aging must include the synthetic regional coverage chart.")
        for region in ["额头", "眉间", "鼻唇", "眼周"] {
            XCTAssertTrue(app.staticTexts[region].firstMatch.exists, "Missing coverage region: \(region)")
        }
        let chartValues = app.staticTexts.allElementsBoundByIndex.filter {
            $0.label.range(of: #"^[0-9]+(?:\.[0-9]+)?%$"#, options: .regularExpression) != nil
        }
        XCTAssertGreaterThanOrEqual(chartValues.count, 4, "The four chart bars must use actual bundled synthetic percentages, not missing-value placeholders.")
        let chartNote = app.staticTexts["仅为照片中纹理响应的区域覆盖率，不是皱纹根数或临床严重程度。缺失项不补值。"].firstMatch
        XCTAssertTrue(reveal(chartNote, in: app))
        capture("detail-aging", app: app)

        tapDetailTab("tone", app: app)
        // The detail card and the all-layer gallery intentionally share a spoken
        // label. Target the particular card, not the first duplicate label.
        let preview = identified("detail-overlay-sample-tone", in: app)
        XCTAssertTrue(reveal(preview, in: app))
        XCTAssertEqual(preview.label, "放大肤色 · 演示图层")
        XCTAssertGreaterThan(preview.frame.width, 40, "The actual thumbnail must have a visible hit region.")
        XCTAssertLessThanOrEqual(preview.frame.width, 80,
                                 "The 62-point detail thumbnail must not expand across blank row space.")
        XCTAssertEqual(preview.frame.height, 78, accuracy: 2)
        capture("before-overlay", app: app)
        preview.tap()
        let overlayNav = app.navigationBars["肤色 · 演示"]
        XCTAssertTrue(overlayNav.waitForExistence(timeout: 5), "The layer tap must actually present the full-screen viewer.")
        XCTAssertTrue(app.staticTexts["演示图层 · 非真实检测结果"].waitForExistence(timeout: 3))
        XCTAssertTrue(identified("overlayViewer", in: app).waitForExistence(timeout: 5),
                      "The viewer must expose its stable accessibility group as well as its navigation bar.")
        capture("overlay", app: app)

        let original = app.segmentedControls.buttons["原图"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.tap()
        XCTAssertTrue(waitUntil { original.isSelected }, "Original-photo comparison should become selected.")
        let annotated = app.segmentedControls.buttons["演示标注"].firstMatch
        annotated.tap()
        XCTAssertTrue(waitUntil { annotated.isSelected })
        overlayNav.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))

        let closeDetails = app.buttons["关闭报告详情"].firstMatch
        XCTAssertTrue(closeDetails.waitForExistence(timeout: 5))
        closeDetails.tap()
        XCTAssertTrue(identified("reportOverview", in: app).waitForExistence(timeout: 5))
        let like = identified("reportFeedbackLike", in: app)
        XCTAssertTrue(reveal(like, in: app))
        like.tap()
        XCTAssertTrue(app.staticTexts["反馈已保存在本机，不会自动上传。"].waitForExistence(timeout: 5))

        // The same sample report ID reloads its saved local feedback after relaunch.
        app.terminate()
        app.launch()
        openSample(in: app)
        let saved = app.staticTexts["反馈已保存在本机，不会自动上传。"].firstMatch
        XCTAssertTrue(reveal(saved, in: app), "Local feedback must survive an app relaunch.")
    }

    private func openSample(in app: XCUIApplication) {
        let sample = app.buttons["sampleReportButton"]
        XCTAssertTrue(sample.waitForExistence(timeout: 8))
        XCTAssertTrue(reveal(sample, in: app))
        sample.tap()
        XCTAssertTrue(app.navigationBars["演示报告"].waitForExistence(timeout: 5))
        // Do not assume SwiftUI maps an identifier to otherElements rather than scrollViews.
        XCTAssertTrue(identified("reportOverview", in: app).waitForExistence(timeout: 5))
    }

    private func tapDetailTab(_ dimension: String, app: XCUIApplication) {
        let tab = identified("detail-tab-\(dimension)", in: app)
        if !reveal(tab, in: app, maximumSwipes: 10) {
            // Also handles a horizontally scrolling tab strip on narrower devices.
            for _ in 0..<3 where !isReachable(tab, in: app) { visibleScroll(in: app).swipeLeft() }
            for _ in 0..<3 where !isReachable(tab, in: app) { visibleScroll(in: app).swipeRight() }
        }
        XCTAssertTrue(isReachable(tab, in: app), "Cannot reach detail tab \(dimension).")
        tab.tap()
        XCTAssertTrue(waitUntil { tab.isSelected }, "The selected dimension must be exposed to accessibility.")
    }

    private func identified(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func visibleScroll(in app: XCUIApplication) -> XCUIElement {
        // SwiftUI can propagate a container ID to its header children. Select
        // the scroll view itself rather than the first text with the same ID.
        for identifier in ["reportDetailSheet", "reportOverview"] {
            let scroll = app.scrollViews.matching(identifier: identifier).firstMatch
            if scroll.exists && scroll.isHittable { return scroll }
        }
        if let scroll = app.scrollViews.allElementsBoundByIndex.first(where: { $0.isHittable }) { return scroll }
        return app
    }

    private func homeDockIsActive(in app: XCUIApplication) -> Bool {
        // Underlying home elements may remain in the AX tree behind a sheet.
        guard !identified("reportOverview", in: app).exists,
              !identified("reportDetailSheet", in: app).exists else { return false }
        return identified("captureActionDock", in: app).exists
    }

    private func unobscuredViewport(in app: XCUIApplication) -> CGRect {
        var viewport = visibleScroll(in: app).frame.intersection(app.frame)
        if homeDockIsActive(in: app) {
            let dock = identified("captureActionDock", in: app)
            let blockers = [dock] + app.tabBars.allElementsBoundByIndex
            for blocker in blockers where blocker.exists {
                let frame = blocker.frame
                if frame.intersects(viewport) && frame.minY > viewport.minY {
                    viewport.size.height = max(0, min(viewport.maxY, frame.minY) - viewport.minY)
                }
            }
        }
        return viewport
    }

    private func isReachable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists && element.isHittable else { return false }
        let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        // isHittable alone incorrectly reported true for the offscreen sample
        // row whose center was underneath the fixed CTA dock / system tab bar.
        return unobscuredViewport(in: app).contains(center)
    }

    private func scrollVertically(in app: XCUIApplication, up: Bool) {
        let scroll = visibleScroll(in: app)
        guard homeDockIsActive(in: app) else {
            if up { scroll.swipeUp() } else { scroll.swipeDown() }
            return
        }
        let viewport = unobscuredViewport(in: app)
        guard !viewport.isEmpty && !viewport.isNull else { return }
        // Perform an ordinary scroll gesture within the visible scroll content;
        // starting a stock full-frame swipe inside the dock hits its buttons.
        // The subsequent button action remains the normal element.tap().
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let x = viewport.midX - app.frame.minX
        let startY = viewport.minY + viewport.height * (up ? 0.8 : 0.2) - app.frame.minY
        let endY = viewport.minY + viewport.height * (up ? 0.2 : 0.8) - app.frame.minY
        origin.withOffset(CGVector(dx: x, dy: startY)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: x, dy: endY)))
    }

    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, maximumSwipes: Int = 12) -> Bool {
        if isReachable(element, in: app) { return true }
        for _ in 0..<maximumSwipes {
            scrollVertically(in: app, up: true)
            if isReachable(element, in: app) { return true }
        }
        for _ in 0..<maximumSwipes {
            scrollVertically(in: app, up: false)
            if isReachable(element, in: app) { return true }
        }
        return isReachable(element, in: app)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
