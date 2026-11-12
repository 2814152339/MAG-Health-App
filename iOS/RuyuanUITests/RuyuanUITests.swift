import XCTest
import CoreGraphics
import UIKit

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

    func testSyntheticCameraPhotoReviewLayoutAndActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-camera-review"]
        app.launch()
        let photo = identified("cameraReviewPhoto", in: app)
        XCTAssertTrue(photo.waitForExistence(timeout: 8))
        let retake = app.buttons["cameraRetakePhoto"]
        let use = app.buttons["cameraUsePhoto"]
        let close = app.buttons["cameraClose"]
        XCTAssertTrue(retake.isHittable)
        XCTAssertTrue(use.isHittable)
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(retake.frame.width, 44)
        XCTAssertGreaterThanOrEqual(use.frame.width, 44)
        XCTAssertFalse(retake.frame.intersects(use.frame))
        XCTAssertGreaterThanOrEqual(photo.frame.width, app.frame.width - 2,
                                    "Confirmation must retain the full-width photo viewport, not the old padded card.")
        XCTAssertGreaterThan(photo.frame.height, 180)
        XCTAssertLessThanOrEqual(photo.frame.maxY, min(retake.frame.minY, use.frame.minY) + 1,
                                 "Photo and confirmation controls must not overlap on the small-screen simulator.")
        XCTAssertTrue(app.staticTexts["UI自动测试合成插画 · 不调用摄像头或生成测肤结果"].exists)
        capture("camera-review-synthetic", app: app)
        retake.tap()
        let outcome = app.staticTexts["cameraReviewFixtureOutcome"]
        XCTAssertTrue(outcome.waitForExistence(timeout: 3))
        XCTAssertEqual(outcome.label, "测试已收到重拍操作")
        app.buttons["cameraReviewFixtureReturn"].tap()
        XCTAssertTrue(use.waitForExistence(timeout: 3))
        use.tap()
        XCTAssertTrue(outcome.waitForExistence(timeout: 3))
        XCTAssertEqual(outcome.label, "测试已收到使用照片操作")
        app.buttons["cameraReviewFixtureReturn"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(outcome.waitForExistence(timeout: 3))
        XCTAssertEqual(outcome.label, "测试已收到关闭操作")
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

    func testSyntheticViewerFaceFramingToolsComparisonAndFullPhotoReset() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-viewer-framing"]
        app.launch()
        let layerEntry = app.buttons["viewerFixtureLayerEntry"]
        XCTAssertTrue(layerEntry.waitForExistence(timeout: 8))
        layerEntry.tap()
        let nav = app.navigationBars["肤色 · 演示"]
        XCTAssertTrue(nav.waitForExistence(timeout: 5))
        let photo = identified("overlayPhotoViewport", in: app)
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let tools = app.buttons["overlayViewingTools"]
        XCTAssertEqual(tools.value as? String, "已收起")
        XCTAssertFalse(app.buttons["overlayZoomIn"].exists)
        XCTAssertTrue(waitUntil {
            guard let state = try? self.viewerState(photo) else { return false }
            return state.region.width < 1 && state.region.height < 1
        })
        let initial = try viewerState(photo)
        XCTAssertGreaterThan(initial.region.width, 0)
        XCTAssertGreaterThan(initial.region.height, 0)
        XCTAssertLessThan(initial.region.width, 1, "Hand-authored valid face points must drive actual initial framing.")
        XCTAssertLessThan(initial.region.height, 1)
        XCTAssertGreaterThanOrEqual(initial.region.minX, 0)
        XCTAssertLessThanOrEqual(initial.region.maxX, 1)
        XCTAssertGreaterThanOrEqual(initial.region.minY, 0)
        XCTAssertLessThanOrEqual(initial.region.maxY, 1)
        XCTAssertEqual(initial.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(app.staticTexts["overlayObservationValue"].label, "较均匀 · 演示")
        let compactPhotoHeight = photo.frame.height
        XCTAssertGreaterThan(compactPhotoHeight, 180)
        capture("viewer-initial-face-framing-tools-collapsed", app: app)

        tools.tap()
        XCTAssertTrue(waitUntil { tools.value as? String == "已展开" })
        let zoomIn = app.buttons["overlayZoomIn"]
        XCTAssertTrue(reveal(zoomIn, in: app), "The production tools drawer must retain reachable zoom controls.")
        XCTAssertTrue(waitUntil { photo.frame.height < compactPhotoHeight - 30 },
                      "Opening real tools must change the layout, not just an accessibility flag.")
        zoomIn.tap()
        XCTAssertTrue(waitUntil { (try? self.viewerState(photo).scale) == 1.5 })
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.05,
            thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        XCTAssertTrue(waitUntil { abs((try? self.viewerState(photo).offset.height) ?? 0) > 0.1 },
                      "A real photo drag must move the shared image/overlay transform within its bounds.")
        let beforeComparison = try viewerState(photo)
        let comparisonPhotoHeight = photo.frame.height
        capture("viewer-face-framing-tools-expanded-and-panned", app: app)

        let original = app.segmentedControls.buttons["原图"].firstMatch
        original.tap()
        XCTAssertTrue(waitUntil { original.isSelected })
        XCTAssertTrue(waitUntil { !app.staticTexts["overlayObservationValue"].exists })
        let originalState = try viewerState(photo)
        XCTAssertEqual(originalState.region, beforeComparison.region)
        XCTAssertEqual(originalState.scale, beforeComparison.scale, accuracy: 0.0001)
        XCTAssertEqual(originalState.offset, beforeComparison.offset,
                       "Comparing the same photo must not jump to a different crop or pan.")
        XCTAssertTrue(waitUntil { abs(photo.frame.height - comparisonPhotoHeight) < 1 },
                      "The original/annotation comparison must retain the actual photo viewport height.")
        app.segmentedControls.buttons["演示标注"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["overlayObservationValue"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["overlayObservationValue"].label, "较均匀 · 演示")

        tools.tap()
        XCTAssertTrue(waitUntil { tools.value as? String == "已收起" })
        XCTAssertTrue(waitUntil { photo.frame.height > compactPhotoHeight - 2 })
        XCTAssertTrue((try viewerState(photo)).offset.width.isFinite)
        XCTAssertTrue((try viewerState(photo)).offset.height.isFinite)
        app.buttons["overlayResetView"].tap()
        XCTAssertTrue(waitUntil {
            guard let value = try? self.viewerState(photo) else { return false }
            return value.region == CGRect(x: 0, y: 0, width: 1, height: 1)
                && value.scale == 1 && value.offset == .zero
        })
        capture("viewer-reset-complete-original-photo", app: app)
        nav.buttons["完成"].firstMatch.tap()
        let originalEntry = app.buttons["viewerFixtureOriginalEntry"]
        XCTAssertTrue(originalEntry.waitForExistence(timeout: 3))
        originalEntry.tap()
        XCTAssertTrue(app.navigationBars["原图"].waitForExistence(timeout: 5))
        XCTAssertTrue(photo.waitForExistence(timeout: 3))
        let fullOriginal = try viewerState(photo)
        XCTAssertEqual(fullOriginal.region, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(fullOriginal.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(fullOriginal.offset, .zero)
        XCTAssertFalse(app.staticTexts["overlayObservationValue"].exists)
        capture("viewer-original-entry-never-auto-crops", app: app)
        app.navigationBars["原图"].buttons["完成"].firstMatch.tap()
        XCTAssertTrue(layerEntry.waitForExistence(timeout: 3))
    }

    func testSyntheticLongSummaryExpandsWithoutChangingSource() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-long-summary"]
        app.launch()
        XCTAssertTrue(identified("reportOverview", in: app).waitForExistence(timeout: 8))
        let text = app.staticTexts["overviewSummaryText"]
        let toggle = app.buttons["overviewSummaryToggle"]
        XCTAssertTrue(reveal(toggle, in: app))
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Long source text must expose the real measured overflow control.")
        XCTAssertEqual(toggle.value as? String, "已收起，显示前6行")
        let source = text.label
        XCTAssertTrue(source.hasPrefix("仅用于自动测试的合成长结论"))
        XCTAssertTrue(source.hasSuffix("合成结论原文结束。"), "Collapsed AX text must retain the entire actual source.")
        let compactHeight = text.frame.height
        capture("summary-six-line-preview", app: app)
        toggle.tap()
        XCTAssertTrue(waitUntil { toggle.value as? String == "已展开完整原文" })
        XCTAssertTrue(waitUntil { text.frame.height > compactHeight + 30 },
                      "The real paragraph layout must expand, not only change a button label.")
        XCTAssertEqual(text.label, source)
        capture("summary-expanded-source", app: app)
        XCTAssertTrue(reveal(toggle, in: app))
        toggle.tap()
        XCTAssertTrue(waitUntil { toggle.value as? String == "已收起，显示前6行" })
        XCTAssertEqual(text.label, source)
        XCTAssertTrue(waitUntil { abs(text.frame.height - compactHeight) <= 2 })
        // Leave overview expanded while opening a separately collapsed card;
        // an accidentally shared expansion binding must fail this assertion.
        XCTAssertTrue(reveal(toggle, in: app))
        toggle.tap()
        XCTAssertTrue(waitUntil { toggle.value as? String == "已展开完整原文" })
        let detailsButton = identified("openReportDetails", in: app)
        XCTAssertTrue(reveal(detailsButton, in: app))
        detailsButton.tap()
        let detail = identified("reportDetailSheet", in: app)
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let detailText = app.staticTexts["detailSummaryText"]
        let detailToggle = app.buttons["detailSummaryToggle"]
        XCTAssertTrue(detailToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(detailToggle.value as? String, "已收起，显示前6行", "Each report card owns an independent expansion state.")
        XCTAssertEqual(detailText.label, source)
        capture("detail-long-summary-collapsed", app: app)
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
        let summary = identified("detailReportSummary", in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "The initial detail sheet must retain its report's actual conclusion card.")
        let summaryHeading = summary.staticTexts["总体结论"].firstMatch
        XCTAssertTrue(isReachable(summaryHeading, in: app), "The conclusion must be visible on first opening, not merely exist offscreen.")
        let initialTop = detail.frame.minY
        let initialTopFraction = (initialTop - app.frame.minY) / app.frame.height
        XCTAssertTrue((0.16...0.24).contains(initialTopFraction), "The initial sheet should cover about 80% of the screen, not open at the medium or full detent.")
        let originalSummaryLabels = Set(summary.staticTexts.allElementsBoundByIndex.map(\.label))
        XCTAssertTrue(originalSummaryLabels.contains("总体结论"))
        capture("detail-initial-summary", app: app)
        expandReportDetails(in: app)
        XCTAssertLessThan(detail.frame.minY, initialTop, "The real grabber gesture must expand the initial sheet.")
        XCTAssertEqual(Set(summary.staticTexts.allElementsBoundByIndex.map(\.label)), originalSummaryLabels,
                       "Changing detents must not lose or replace the report's actual summary.")
        capture("detail-expanded-summary", app: app)
        let radar = identified("reportRadarChart", in: app)
        XCTAssertTrue(revealFully(radar, in: app), "The initial report overview must retain its actual five-dimension radar.")
        capture("detail-overview", app: app)

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
        let chartContainer = identified("regionalLineChart", in: app)
        XCTAssertTrue(chartContainer.exists)
        for region in ["额头", "眉间", "鼻唇", "眼周"] {
            XCTAssertTrue(chartContainer.staticTexts[region].firstMatch.exists, "Missing coverage region: \(region)")
        }
        let chartValues = chartContainer.staticTexts.allElementsBoundByIndex.filter {
            $0.label.range(of: #"^[0-9]+(?:\.[0-9]+)?%$"#, options: .regularExpression) != nil
        }
        XCTAssertGreaterThanOrEqual(chartValues.count, 4, "The four chart bars must use actual bundled synthetic percentages, not missing-value placeholders.")
        let chartNote = app.staticTexts["仅为照片中纹理响应的区域覆盖率，不是皱纹根数或临床严重程度。缺失项不补值。"].firstMatch
        XCTAssertTrue(reveal(chartNote, in: app))
        XCTAssertTrue(revealFully(chartContainer, in: app), "The captured chart must not be hidden under the pinned tab strip.")
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
        let observationValue = app.staticTexts["overlayObservationValue"]
        XCTAssertTrue(observationValue.waitForExistence(timeout: 3))
        XCTAssertEqual(observationValue.label, "较均匀 · 演示",
                       "The enlarged layer must retain this exact tapped sample item's original value, not a score inferred from the mask.")
        XCTAssertEqual(app.staticTexts["overlayObservationTitle"].label, "肤色均匀度")
        let viewingTools = app.buttons["overlayViewingTools"]
        XCTAssertEqual(viewingTools.value as? String, "已收起")
        viewingTools.tap()
        XCTAssertTrue(waitUntil { viewingTools.value as? String == "已展开" })
        XCTAssertTrue(reveal(identified("overlayZoomIn", in: app), in: app))
        identified("overlayZoomIn", in: app).tap()
        XCTAssertTrue(app.staticTexts["150%"].waitForExistence(timeout: 3))
        identified("overlayZoomOut", in: app).tap()
        XCTAssertTrue(app.staticTexts["100%"].waitForExistence(timeout: 3))
        let focus = identified("overlayFocusToggle", in: app)
        focus.tap()
        XCTAssertTrue(waitUntil { focus.label.contains("全图") })
        focus.tap()
        XCTAssertTrue(waitUntil { focus.label.contains("局部") })
        capture("overlay", app: app)

        let original = app.segmentedControls.buttons["原图"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.tap()
        XCTAssertTrue(waitUntil { original.isSelected }, "Original-photo comparison should become selected.")
        XCTAssertTrue(waitUntil { !observationValue.exists }, "Original-only mode must not present an observation value.")
        let annotated = app.segmentedControls.buttons["演示标注"].firstMatch
        annotated.tap()
        XCTAssertTrue(waitUntil { annotated.isSelected })
        XCTAssertTrue(observationValue.waitForExistence(timeout: 3))
        XCTAssertEqual(observationValue.label, "较均匀 · 演示")
        let genericLayer = app.buttons["overlayLayer-sample-pigment"]
        XCTAssertTrue(reveal(genericLayer, in: app))
        genericLayer.tap()
        XCTAssertTrue(waitUntil { !observationValue.exists },
                      "A generic layer-strip selection must clear the card reference, including when selecting the same mask.")
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

    func testSampleDetailScrollsContinuouslyAndTracksVisibleDimension() {
        let app = XCUIApplication()
        app.launch()
        openSample(in: app)
        let detailsButton = identified("openReportDetails", in: app)
        XCTAssertTrue(reveal(detailsButton, in: app))
        detailsButton.tap()
        XCTAssertTrue(identified("reportDetailSheet", in: app).waitForExistence(timeout: 5))
        expandReportDetails(in: app)
        tapDetailTab("waterOil", app: app)
        let tabs = identified("reportDimensionTabs", in: app)
        let waterHeading = identified("detailDimensionHeading-waterOil", in: app)
        XCTAssertTrue(waitUntil {
            waterHeading.exists && waterHeading.frame.minY >= tabs.frame.maxY - 2 &&
                waterHeading.frame.minY <= tabs.frame.maxY + 12
        }, "A tab jump must position the actual heading below the measured sticky strip.")
        let toneHeading = identified("detailDimensionHeading-tone", in: app)
        let lastWaterItem = app.staticTexts["2. 水分"].firstMatch
        let toneTab = identified("detail-tab-tone", in: app)
        var witnessedAdjacentDimensions = false
        // Ordinary short drags, not tab clicks, move across the real boundary.
        // A small distance avoids skipping the single-card tone section.
        for _ in 0..<18 {
            if isReachable(lastWaterItem, in: app) && isReachable(toneHeading, in: app) {
                if !witnessedAdjacentDimensions { capture("detail-adjacent-dimensions", app: app) }
                witnessedAdjacentDimensions = true
            }
            if toneTab.isSelected { break }
            let viewport = unobscuredViewport(in: app)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = viewport.midX - app.frame.minX
            let y = viewport.minY - app.frame.minY
            origin.withOffset(CGVector(dx: x, dy: y + viewport.height * 0.72)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: y + viewport.height * 0.60)))
            XCTAssertTrue(identified("reportDetailSheet", in: app).exists)
        }
        XCTAssertTrue(witnessedAdjacentDimensions,
                      "Neighboring dimension content must coexist in one real scrolling flow, not replace each other.")
        XCTAssertTrue(waitUntil { toneTab.isSelected }, "Real scrolling must update the selected tab from actual section geometry.")
        capture("detail-scroll-selected-tone", app: app)
        tapDetailTab("waterOil", app: app)
        XCTAssertTrue(waitUntil {
            waterHeading.exists && waterHeading.frame.minY >= tabs.frame.maxY - 2 &&
                waterHeading.frame.minY <= tabs.frame.maxY + 12
        }, "Returning by tab must restore the heading without retaining the previous offset or hiding it under tabs.")
        capture("detail-tab-return-water-oil", app: app)
    }

    func testReportCalibrationFeedbackEditorAndPDFShare() {
        let app = XCUIApplication()
        app.launch()
        openSample(in: app)
        let details = identified("openReportDetails", in: app)
        XCTAssertTrue(reveal(details, in: app)); details.tap()
        XCTAssertTrue(identified("reportDetailSheet", in: app).waitForExistence(timeout: 5))
        expandReportDetails(in: app)
        let geometry = identified("reportGeometryTools", in: app)
        XCTAssertTrue(reveal(geometry, in: app)); geometry.tap()
        let calibration = identified("openCalibrationTools", in: app)
        capture("geometry-tools-expanded", app: app)
        XCTAssertTrue(calibration.waitForExistence(timeout: 5), "Expanding the real geometry section must expose its calibration link without replacing its identifier.")
        XCTAssertTrue(reveal(calibration, in: app)); calibration.tap()
        let calibrationBar = app.navigationBars["手动标定"]
        XCTAssertTrue(calibrationBar.waitForExistence(timeout: 5))
        let saveCalibration = app.buttons["保存标定"].firstMatch
        XCTAssertTrue(saveCalibration.exists)
        XCTAssertFalse(saveCalibration.isEnabled, "Synthetic demonstration calibration must never overwrite a real report.")
        capture("calibration-read-only", app: app)
        calibrationBar.buttons.firstMatch.tap()
        XCTAssertTrue(identified("reportDetailSheet", in: app).waitForExistence(timeout: 5))
        app.buttons["关闭报告详情"].firstMatch.tap()

        let feedback = identified("reportFeedbackNote", in: app)
        XCTAssertTrue(reveal(feedback, in: app)); feedback.tap()
        let feedbackBar = app.navigationBars["本次报告反馈"]
        XCTAssertTrue(feedbackBar.waitForExistence(timeout: 5))
        let editor = app.textViews["reportFeedbackEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let existing = editor.value as? String ?? ""
        let note = "Synthetic UI feedback only."
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + note)
        feedbackBar.buttons["保存"].tap()
        XCTAssertTrue(identified("reportOverview", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(feedback, in: app)); feedback.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, note)
        feedbackBar.buttons["取消"].tap()

        let share = identified("shareReportPDF", in: app)
        XCTAssertTrue(reveal(share, in: app)); share.tap()
        // UIActivityViewController is backed by a system remote container on
        // iOS 18. Its view's custom identifier is not preserved in that tree.
        // Assert the actual native sheet and its PDF metadata, not an app flag.
        let sharePanel = app.navigationBars["UIActivityContentView"].firstMatch
        XCTAssertTrue(sharePanel.waitForExistence(timeout: 8), "PDF export must actually open the native system share controller.")
        let pdfMetadata = sharePanel.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "PDF")).firstMatch
        XCTAssertTrue(pdfMetadata.exists, "The shared activity must identify a real PDF document.")
        let reportFileName = sharePanel.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "ruyuan-demo-v1")).firstMatch
        XCTAssertTrue(reportFileName.exists, "The exported file must belong to the actual sample report.")
        capture("share-pdf", app: app)
        // The remote share controller exposes an actual header button. A
        // global label-IN query missed it on iOS 18, and dragging the header
        // was not a dismissal. Exercise the normal, observed Close control.
        let close = sharePanel.buttons["header.closeButton"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The native PDF share controller must expose its Close button.")
        XCTAssertTrue(waitUntil { close.isHittable })
        close.tap()
        XCTAssertTrue(waitUntil { !sharePanel.exists }, "The system share sheet must dismiss back to the report.")
        XCTAssertTrue(identified("reportOverview", in: app).exists)
        XCTAssertTrue(waitUntil { share.isHittable }, "Dismissing the system controller must also remove its modal host and restore the actual report controls.")
        capture("share-dismissed", app: app)
    }

    func testSyntheticScannerScenesPlaybackAndSkip() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-scan"]
        app.launch()
        XCTAssertTrue(identified("analysisScanner", in: app).waitForExistence(timeout: 8))
        let pause = identified("scanPausePlayback", in: app)
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        XCTAssertTrue(waitUntil { pause.label.contains("继续") }, "Pausing must expose the resume action.")
        XCTAssertTrue(identified("sampleScanNotice", in: app).exists)
        let previous = identified("scanPreviousScene", in: app)
        let next = identified("scanNextScene", in: app)
        // App launch / AX synchronization can exceed the first short scene.
        // Pause first, then use the real previous control to reach scene one.
        for _ in 0..<10 where previous.isEnabled { previous.tap() }
        XCTAssertFalse(previous.isEnabled)
        let sceneTitle = identified("scanSceneTitle", in: app)
        let titles = ["定位面部关键点", "脸型与下颌轮廓", "面部纵向比例", "五眼与眼间距", "面部三角与下巴",
                      "眉眼精细分析", "鼻唇比例", "面部纹路与肌理", "肤色与点状外观", "眼周外观"]
        // A paused return to the three-second first scene must not seek beyond
        // its exit window and hide the actual panel while AX still says complete.
        next.tap()
        XCTAssertTrue(waitUntil { sceneTitle.label.contains(titles[1]) })
        previous.tap()
        XCTAssertTrue(waitUntil { sceneTitle.label.contains(titles[0]) })
        let panel = identified("scanMeasurementPanel", in: app)
        let scanner = identified("analysisScanner", in: app)
        XCTAssertTrue(waitUntil {
            let frame = panel.frame
            return frame.width > 100 && frame.height > 40
                && frame.minX >= scanner.frame.minX && frame.maxX <= scanner.frame.maxX
                && frame.minY >= scanner.frame.minY && frame.maxY <= pause.frame.minY
        }, "Returning to the first scene must leave its real result panel onscreen above playback.")
        let panelPixels = try captureMotionPixels(app.screenshot(), name: "scanner-first-scene-paused-return-panel",
                                                 region: panel.frame.insetBy(dx: 12, dy: 12), appFrame: app.frame)
        XCTAssertGreaterThan(darkMotionPixelFraction(panelPixels), 0.25,
                             "The returned first-scene panel must actually paint its dark backing, not only exist in AX.")
        for (index, title) in titles.enumerated() {
            XCTAssertTrue(waitUntil { sceneTitle.label.contains(title) }, "Missing scanner scene: \(title)")
            XCTAssertTrue(identified("scanMeasurementPanel", in: app).exists)
            if index == 5 || index == 9 {
                let photo = identified("scanOriginalPhoto", in: app)
                XCTAssertTrue(waitUntil { (photo.value as? String)?.contains("局部") == true },
                              "Brow and eye scenes must focus on this synthetic report's real ROI points.")
            }
            if index == 5 {
                let photo = identified("scanOriginalPhoto", in: app)
                for id in ["v2-leftEyebrow-arch-angle", "v2-leftEye-inner-angle"] {
                    let label = identified("scanMeasurement-\(id)", in: app)
                    XCTAssertTrue(label.exists, "The focused side must retain its actual angle label.")
                    XCTAssertTrue(photo.frame.contains(label.frame), "A local angle label must not be cut off by the photo viewport.")
                }
                XCTAssertFalse(identified("scanMeasurement-v2-rightEyebrow-arch-angle", in: app).exists)
                XCTAssertFalse(identified("scanMeasurement-v2-rightEye-inner-angle", in: app).exists,
                               "The offscreen nonfocused side must not leak clipped labels into a single-eye closeup.")
            }
            if index == 9 {
                let rangeNotice = identified("scanEyeSamplingRangeNotice", in: app)
                XCTAssertTrue(rangeNotice.exists,
                              "Existing synthetic sampling rows must render as labelled thin ranges, not opaque false lesion masks.")
                XCTAssertFalse(rangeNotice.frame.intersects(identified("scanMeasurementPanel", in: app).frame),
                               "The sampling explanation must not be hidden underneath the result panel.")
            }
            capture(String(format: "scanner-%02d", index + 1), app: app)
            if index < titles.count - 1 { next.tap() }
        }
        previous.tap()
        XCTAssertTrue(waitUntil { sceneTitle.label.contains(titles[8]) })
        next.tap()
        XCTAssertTrue(waitUntil { sceneTitle.label.contains(titles[9]) })
        // Resume then pause again; explicit navigation is tested while paused,
        // without waiting for a fabricated timer or racing scene auto-advance.
        pause.tap()
        XCTAssertTrue(waitUntil { pause.label.contains("暂停") })
        pause.tap()
        XCTAssertTrue(waitUntil { pause.label.contains("继续") })
        identified("skipScanButton", in: app).tap()
        XCTAssertTrue(app.navigationBars["演示报告"].waitForExistence(timeout: 8))
        XCTAssertTrue(identified("reportOverview", in: app).waitForExistence(timeout: 5))
        capture("scanner-report", app: app)
    }

    func testSyntheticScannerMotionUsesPhotoPixelsAndPauses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-scan"]
        app.launch()
        XCTAssertTrue(identified("analysisScanner", in: app).waitForExistence(timeout: 8))
        let pause = identified("scanPausePlayback", in: app)
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        XCTAssertTrue(waitUntil { pause.label.contains("继续") })
        XCTAssertTrue(identified("sampleScanNotice", in: app).exists)
        let previous = identified("scanPreviousScene", in: app)
        for _ in 0..<10 where previous.isEnabled { previous.tap() }
        XCTAssertFalse(previous.isEnabled)
        identified("scanNextScene", in: app).tap()
        let title = identified("scanSceneTitle", in: app)
        XCTAssertTrue(waitUntil { title.label.contains("脸型与下颌轮廓") })
        let photo = identified("scanOriginalPhoto", in: app)
        XCTAssertTrue(waitUntil { (photo.value as? String)?.contains("标注展开完成") == true },
                      "Manual stepping while paused must still expose the complete static result.")
        XCTAssertTrue((photo.value as? String)?.contains("完整照片") == true)

        // This scene and its predecessor both use the full, stationary photo.
        // Restrict evidence to the lower face/jaw, excluding the status bar,
        // Skip, scene title, playback, elapsed text and sliding result panel.
        let photoFrame = photo.frame
        let jaw = CGRect(x: photoFrame.minX + photoFrame.width * 0.18,
                         y: photoFrame.minY + photoFrame.height * 0.40,
                         width: photoFrame.width * 0.64, height: photoFrame.height * 0.44)
        pause.tap() // The real Continue action replays this manually inspected scene.
        let unfolding = try captureMotionPixels(app.screenshot(), name: "motion-unfolding",
                                               region: jaw, appFrame: app.frame)
        XCTAssertTrue((photo.value as? String)?.contains("动画展开中") == true,
                      "The early screenshot must precede the actual annotation completion, not a scene change.")
        pause.tap()
        XCTAssertTrue(waitUntil { pause.label.contains("继续") })
        XCTAssertTrue(title.label.contains("脸型与下颌轮廓"), "Evidence must remain in the same face-angle scene.")
        XCTAssertEqual(photo.frame, photoFrame, "A moved/resized image must not stand in for drawn annotation motion.")
        XCTAssertTrue((photo.value as? String)?.contains("动画展开中") == true,
                      "Pause must be tested during unfinished drawing, not against an already static final frame.")
        let freezeStart = try captureMotionPixels(app.screenshot(), name: "motion-freeze-start",
                                                 region: jaw, appFrame: app.frame)

        // Give the real clock enough time to advance if Pause were broken.
        // No timer/status pixels are in this comparison and there is no app
        // phase override, injected progress, private photo or polling sleep.
        let frozenAt = Date()
        XCTAssertTrue(waitUntil(timeout: 2) { Date().timeIntervalSince(frozenAt) >= 0.8 })
        let frozen = try captureMotionPixels(app.screenshot(), name: "motion-frozen",
                                            region: jaw, appFrame: app.frame)
        XCTAssertEqual(freezeStart.width, frozen.width)
        XCTAssertEqual(freezeStart.height, frozen.height)
        XCTAssertEqual(freezeStart.rgba, frozen.rgba, "Pause must freeze the actual unfinished photo-region annotation pixels.")
        pause.tap()
        XCTAssertTrue(waitUntil(timeout: 6) { (photo.value as? String)?.contains("标注展开完成") == true })
        pause.tap()
        XCTAssertTrue(waitUntil { pause.label.contains("继续") })
        XCTAssertTrue(title.label.contains("脸型与下颌轮廓"))
        XCTAssertEqual(photo.frame, photoFrame)
        let complete = try captureMotionPixels(app.screenshot(), name: "motion-complete",
                                              region: jaw, appFrame: app.frame)
        let changedFraction = changedMotionPixelFraction(unfolding, complete)
        XCTAssertGreaterThan(changedFraction, 0.001,
                             "Actual lower-face annotation pixels must change; accessibility text or navigation alone is not animation evidence.")
        XCTAssertGreaterThan(changedMotionPixelFraction(freezeStart, complete), 0.001,
                             "The paused crop must really be unfinished and advance after Continue; pausing an already static final crop is not evidence.")
        let evidence = XCTAttachment(string: String(format: "Synthetic jaw crop: %dx%d; changed RGB pixels above 24/765 difference: %.4f%%; paused crop exact match: %@.",
                                                     complete.width, complete.height, changedFraction * 100,
                                                     freezeStart.rgba == frozen.rgba ? "true" : "false"))
        evidence.name = "motion-pixel-evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testSyntheticProductionAngleRendererUsesProgressAndRestoresZeroPixels() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-angle-renderer"]
        app.launch()
        let canvas = identified("angleRendererCanvas", in: app)
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil { canvas.value as? String == "0.0" })
        let frame = canvas.frame
        XCTAssertGreaterThan(frame.width, 200)
        XCTAssertEqual(frame.width, frame.height, accuracy: 1)
        for id in ["angleRendererZero", "angleRendererHalf", "angleRendererFull"] {
            XCTAssertFalse(frame.intersects(app.buttons[id].frame), "Controls must remain outside the sampled Canvas.")
        }
        let zero = try captureMotionPixels(app.screenshot(), name: "angle-renderer-zero",
                                          region: frame, appFrame: app.frame)
        app.buttons["angleRendererHalf"].tap()
        XCTAssertTrue(waitUntil { canvas.value as? String == "0.5" })
        XCTAssertEqual(canvas.frame, frame)
        let half = try captureMotionPixels(app.screenshot(), name: "angle-renderer-half",
                                          region: frame, appFrame: app.frame)
        XCTAssertGreaterThan(brightMotionPixelCount(half) - brightMotionPixelCount(zero), Int(Double(half.width) * 0.3),
                             "Half progress must add actual white angle arms; the three static violet points are insufficient.")

        app.buttons["angleRendererFull"].tap()
        XCTAssertTrue(waitUntil { canvas.value as? String == "1.0" })
        XCTAssertEqual(canvas.frame, frame)
        let full = try captureMotionPixels(app.screenshot(), name: "angle-renderer-full",
                                          region: frame, appFrame: app.frame)
        // The first arm stays horizontal to image-left. The second must rotate
        // from an upper-left diagonal at half to the x=.55 vertical at full.
        // Column counts are deliberately independent of CG bitmap row direction.
        XCTAssertGreaterThan(brightMotionPixelCount(half, columns: 0.26...0.48)
                             - brightMotionPixelCount(full, columns: 0.26...0.48), Int(Double(full.width) * 0.08),
                             "The half-angle diagonal must occupy real pixels left of the final vertical ray.")
        XCTAssertGreaterThan(brightMotionPixelCount(full, columns: 0.525...0.575)
                             - brightMotionPixelCount(half, columns: 0.525...0.575), Int(Double(full.height) * 0.2),
                             "The full-angle second ray must really reach its vertical direction, not only change a label.")
        XCTAssertGreaterThan(changedMotionPixelFraction(half, full), 0.0005)

        app.buttons["angleRendererZero"].tap()
        XCTAssertTrue(waitUntil { canvas.value as? String == "0.0" })
        XCTAssertEqual(canvas.frame, frame)
        let restored = try captureMotionPixels(app.screenshot(), name: "angle-renderer-restored-zero",
                                              region: frame, appFrame: app.frame)
        XCTAssertEqual(restored.rgba, zero.rgba, "Resetting real renderer progress must restore identical Canvas pixels.")
    }

    private struct MotionPixelSample {
        let width: Int
        let height: Int
        let rgba: [UInt8]
    }

    private func captureMotionPixels(_ screenshot: XCUIScreenshot, name: String,
                                     region: CGRect, appFrame: CGRect) throws -> MotionPixelSample {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scaleX = CGFloat(image.width) / appFrame.width
        let scaleY = CGFloat(image.height) / appFrame.height
        let pixels = CGRect(x: (region.minX - appFrame.minX) * scaleX,
                            y: (region.minY - appFrame.minY) * scaleY,
                            width: region.width * scaleX, height: region.height * scaleY).integral
        let crop = try XCTUnwrap(image.cropping(to: pixels.intersection(CGRect(x: 0, y: 0,
                                                                             width: CGFloat(image.width), height: CGFloat(image.height)))))
        let cropAttachment = XCTAttachment(image: UIImage(cgImage: crop))
        cropAttachment.name = name + "-photo-crop"
        cropAttachment.lifetime = .keepAlways
        add(cropAttachment)
        var rgba = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                                                 bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(crop.width), height: CGFloat(crop.height)))
        }
        return MotionPixelSample(width: crop.width, height: crop.height, rgba: rgba)
    }

    private func changedMotionPixelFraction(_ first: MotionPixelSample, _ second: MotionPixelSample) -> Double {
        guard first.width == second.width, first.height == second.height,
              first.rgba.count == second.rgba.count, !first.rgba.isEmpty else { return 0 }
        var changed = 0
        for offset in stride(from: 0, to: first.rgba.count, by: 4) {
            let difference = abs(Int(first.rgba[offset]) - Int(second.rgba[offset]))
                + abs(Int(first.rgba[offset + 1]) - Int(second.rgba[offset + 1]))
                + abs(Int(first.rgba[offset + 2]) - Int(second.rgba[offset + 2]))
            if difference > 24 { changed += 1 }
        }
        return Double(changed) / Double(first.width * first.height)
    }

    private func brightMotionPixelCount(_ sample: MotionPixelSample, columns: ClosedRange<Double> = 0...1) -> Int {
        let start = max(0, min(sample.width, Int(Double(sample.width) * columns.lowerBound)))
        let end = max(start, min(sample.width, Int(ceil(Double(sample.width) * columns.upperBound))))
        var count = 0
        for y in 0..<sample.height {
            for x in start..<end {
                let offset = (y * sample.width + x) * 4
                if sample.rgba[offset] >= 200 && sample.rgba[offset + 1] >= 200 && sample.rgba[offset + 2] >= 200 { count += 1 }
            }
        }
        return count
    }

    private func darkMotionPixelFraction(_ sample: MotionPixelSample) -> Double {
        guard sample.width > 0, sample.height > 0 else { return 0 }
        var count = 0
        for offset in stride(from: 0, to: sample.rgba.count, by: 4) {
            if sample.rgba[offset] < 45 && sample.rgba[offset + 1] < 45 && sample.rgba[offset + 2] < 45 { count += 1 }
        }
        return Double(count) / Double(sample.width * sample.height)
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

    private func expandReportDetails(in app: XCUIApplication) {
        let detail = identified("reportDetailSheet", in: app)
        let scroll = app.scrollViews["reportDetailScrollView"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        // Do not rely on incidental content swipes to expand the initial
        // report detent: drag its visible native grabber at the measured top.
        // This is a sheet-resize gesture, not a coordinate tap on a control.
        if scroll.frame.height < app.frame.height * 0.75 {
            let grabber = detail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 7))
            let expandedTop = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            grabber.press(forDuration: 0.05, thenDragTo: expandedTop)
        }
        XCTAssertTrue(waitUntil { scroll.frame.height >= app.frame.height * 0.75 },
                      "Dragging the actual report sheet grabber must expand its scroll viewport.")
    }

    private func visibleScroll(in app: XCUIApplication) -> XCUIElement {
        // SwiftUI can propagate a container ID to its header children. Select
        // the scroll view itself rather than the first text with the same ID.
        for identifier in ["overlayToolsScrollView", "reportDetailScrollView", "reportDetailSheet", "reportOverview"] {
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
        guard unobscuredViewport(in: app).contains(center) else { return false }
        let tabs = identified("reportDimensionTabs", in: app)
        if !element.identifier.hasPrefix("detail-tab-"), tabs.exists, tabs.isHittable, tabs.frame.contains(center) { return false }
        return true
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
        let beganInDetails = identified("reportDetailSheet", in: app).exists
        if isReachable(element, in: app) { return true }
        var previousFrame: CGRect?
        var stationaryAttempts = 0
        // Retain the old overall bound, but never blindly sweep up and then
        // down. An existing target under the pinned tabs needs a short DOWN
        // drag, not another upward swipe and eventual native sheet dismissal.
        for _ in 0..<max(0, maximumSwipes * 2) {
            if beganInDetails && !identified("reportDetailSheet", in: app).exists { return false }
            if isReachable(element, in: app) { return true }
            var viewport = unobscuredViewport(in: app).insetBy(dx: 3, dy: 3)
            let targetExists = element.exists
            let tabs = identified("reportDimensionTabs", in: app)
            if !(targetExists && element.identifier.hasPrefix("detail-tab-")), tabs.exists, tabs.isHittable {
                let frame = tabs.frame
                if frame.minY <= viewport.minY + 4 && frame.maxY > viewport.minY {
                    let bottom = viewport.maxY
                    viewport.origin.y = frame.maxY + 4
                    viewport.size.height = max(0, bottom - viewport.minY)
                }
            }
            guard !viewport.isNull, !viewport.isEmpty, viewport.height > 40 else { return false }
            var delta = viewport.height * 0.32 // Only absent lazy targets are searched progressively upward.
            if targetExists {
                let frame = element.frame
                guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
                      !frame.isEmpty, !frame.isNull else { return false }
                if previousFrame == frame { stationaryAttempts += 1 } else { stationaryAttempts = 0 }
                guard stationaryAttempts < 2 else { return false }
                previousFrame = frame
                guard (viewport.minX...viewport.maxX).contains(frame.midX) else { return false }
                if frame.midY < viewport.minY {
                    delta = frame.minY - viewport.minY - 8
                } else if frame.midY > viewport.maxY {
                    delta = frame.maxY - viewport.maxY + 8
                } else {
                    // The center is already clear of all measured blockers.
                    // Do not scroll a covered/disabled element into another page.
                    return isReachable(element, in: app)
                }
                delta = min(max(delta, -viewport.height * 0.32), viewport.height * 0.32)
            } else {
                previousFrame = nil
                stationaryAttempts = 0
            }
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let x = viewport.midX - app.frame.minX
            let y = viewport.midY - app.frame.minY
            origin.withOffset(CGVector(dx: x, dy: y + delta / 2)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: y - delta / 2)))
        }
        return isReachable(element, in: app)
    }

    private func revealFully(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard reveal(element, in: app) else { return false }
        for _ in 0..<8 {
            var viewport = unobscuredViewport(in: app).insetBy(dx: 3, dy: 3)
            let tabs = identified("reportDimensionTabs", in: app)
            if tabs.exists, tabs.isHittable, tabs.frame.minY <= viewport.minY + 4, tabs.frame.maxY > viewport.minY {
                let bottom = viewport.maxY
                viewport.origin.y = tabs.frame.maxY + 4
                viewport.size.height = max(0, bottom - viewport.minY)
            }
            let frame = element.frame
            if frame.minY >= viewport.minY && frame.maxY <= viewport.maxY { return true }
            guard frame.height <= viewport.height, viewport.height > 40 else { return false }
            let needed = frame.maxY > viewport.maxY ? frame.maxY - viewport.maxY + 6 : frame.minY - viewport.minY - 6
            let delta = min(max(needed, -viewport.height * 0.35), viewport.height * 0.35)
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let x = viewport.midX - app.frame.minX
            let y = viewport.midY - app.frame.minY
            origin.withOffset(CGVector(dx: x, dy: y + delta / 2)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: y - delta / 2)))
        }
        return false
    }

    private struct ViewerState {
        let region: CGRect
        let scale: Double
        let offset: CGSize
    }

    /// Reads the real production viewport's presentation state; this is not
    /// image correctness evidence. Actual screenshots remain separate evidence.
    private func viewerState(_ element: XCUIElement, file: StaticString = #filePath,
                             line: UInt = #line) throws -> ViewerState {
        guard let raw = element.value as? String else {
            XCTFail("Missing viewer presentation state.", file: file, line: line)
            throw NSError(domain: "ViewerStateTests", code: 1)
        }
        var fields: [String: [Double]] = [:]
        for component in raw.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, fields[String(pair[0])] == nil else {
                XCTFail("Malformed or duplicate viewer field: \(raw)", file: file, line: line)
                throw NSError(domain: "ViewerStateTests", code: 2)
            }
            let pieces = pair[1].split(separator: ",", omittingEmptySubsequences: false)
            let values = pieces.compactMap { Double($0) }
            guard pieces.count == values.count, values.allSatisfy(\.isFinite) else {
                XCTFail("Invalid viewer presentation numbers: \(raw)", file: file, line: line)
                throw NSError(domain: "ViewerStateTests", code: 3)
            }
            fields[String(pair[0])] = values
        }
        guard fields.count == 3, let region = fields["region"], region.count == 4,
              let scale = fields["scale"], scale.count == 1,
              let offset = fields["offset"], offset.count == 2 else {
            XCTFail("Incomplete viewer presentation state: \(raw)", file: file, line: line)
            throw NSError(domain: "ViewerStateTests", code: 4)
        }
        return ViewerState(region: CGRect(x: CGFloat(region[0]), y: CGFloat(region[1]),
                                          width: CGFloat(region[2]), height: CGFloat(region[3])),
                           scale: scale[0], offset: CGSize(width: CGFloat(offset[0]), height: CGFloat(offset[1])))
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
