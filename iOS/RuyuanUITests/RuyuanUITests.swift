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

    func testReportCalibrationFeedbackEditorAndPDFShare() {
        let app = XCUIApplication()
        app.launch()
        openSample(in: app)
        let details = identified("openReportDetails", in: app)
        XCTAssertTrue(reveal(details, in: app)); details.tap()
        XCTAssertTrue(identified("reportDetailSheet", in: app).waitForExistence(timeout: 5))
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

    func testSyntheticScannerScenesPlaybackAndSkip() {
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
        for (index, title) in titles.enumerated() {
            XCTAssertTrue(waitUntil { sceneTitle.label.contains(title) }, "Missing scanner scene: \(title)")
            XCTAssertTrue(identified("scanMeasurementPanel", in: app).exists)
            if index == 5 || index == 9 {
                let photo = identified("scanOriginalPhoto", in: app)
                XCTAssertTrue(waitUntil { (photo.value as? String)?.contains("局部") == true },
                              "Brow and eye scenes must focus on this synthetic report's real ROI points.")
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
        for identifier in ["reportDetailScrollView", "reportDetailSheet", "reportOverview"] {
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
        if !element.identifier.hasPrefix("detail-tab-"), tabs.exists, tabs.frame.contains(center) { return false }
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
        for _ in 0..<maximumSwipes {
            if beganInDetails && !identified("reportDetailSheet", in: app).exists { return false }
            scrollVertically(in: app, up: true)
            if isReachable(element, in: app) { return true }
        }
        for _ in 0..<maximumSwipes {
            if beganInDetails && !identified("reportDetailSheet", in: app).exists { return false }
            scrollVertically(in: app, up: false)
            if isReachable(element, in: app) { return true }
        }
        return isReachable(element, in: app)
    }

    private func revealFully(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard reveal(element, in: app) else { return false }
        for _ in 0..<8 {
            var viewport = unobscuredViewport(in: app).insetBy(dx: 3, dy: 3)
            let tabs = identified("reportDimensionTabs", in: app)
            if tabs.exists, tabs.frame.minY <= viewport.minY + 4, tabs.frame.maxY > viewport.minY {
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
