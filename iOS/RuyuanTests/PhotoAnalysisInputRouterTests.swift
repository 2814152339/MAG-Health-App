import UIKit
import SwiftUI
import XCTest
@testable import Ruyuan

/// Routing-only fixtures: no camera, AppStore, model inference, private image,
/// or application persistence. Synthetic depth is transported, not measured.
final class PhotoAnalysisInputRouterTests: XCTestCase {
    private func image(_ color: UIColor = .red) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }

    private func depth(for image: UIImage) throws -> DepthSnapshot {
        let fingerprint = try XCTUnwrap(DepthSnapshot.imageFingerprint(image))
        let snapshot = DepthSnapshot(captureID: "synthetic-routing-only",
            originalJPEGSHA256: String(repeating: "a", count: 64), sourceImageFingerprint: fingerprint,
            imageWidth: 16, imageHeight: 16, width: 8, height: 8,
            depthMeters: [Float](repeating: 0.5, count: 64),
            intrinsicMatrix: [16, 0, 0, 0, 16, 0, 8, 8, 1],
            referenceWidth: 16, referenceHeight: 16, distortionCenterX: 8, distortionCenterY: 8,
            lensDistortion: [0, 0], inverseLensDistortion: [0, 0], originalExifOrientation: 1,
            source: "Synthetic routing fixture, NOT camera or device depth evidence")
        XCTAssertTrue(snapshot.isUsable)
        XCTAssertTrue(snapshot.matches(image: image))
        return snapshot
    }

    private func analysis(_ decision: PhotoAnalysisInputRouter.Decision,
                          file: StaticString = #filePath, line: UInt = #line) throws -> PhotoAnalysisInput {
        guard case .analyze(let input) = decision else {
            XCTFail("Expected the production router to emit an analysis request.", file: file, line: line)
            throw NSError(domain: "PhotoInputRouterTests", code: 1)
        }
        return input
    }

    private func assertWaiting(_ decision: PhotoAnalysisInputRouter.Decision,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .wait = decision else {
            XCTFail("Expected no repeated presentation or analysis request.", file: file, line: line)
            return
        }
    }

    private func assertQuestionnaire(_ decision: PhotoAnalysisInputRouter.Decision,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard case .showAssessment = decision else {
            XCTFail("Expected an explicitly opted-in questionnaire.", file: file, line: line)
            return
        }
    }

    func testSharedQuestionnairePreferenceDefaultsOffAndPersistsExplicitOptIn() throws {
        let suite = "PhotoInputRouterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = PhotoAnalysisInputRouter.assessmentPreferenceKey
        XCTAssertNil(defaults.object(forKey: key))
        var setting = AppStorage(wrappedValue: false, key, store: defaults)
        XCTAssertFalse(setting.wrappedValue)
        setting.wrappedValue = true
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
        let reloaded = AppStorage(wrappedValue: false, key, store: defaults)
        XCTAssertTrue(reloaded.wrappedValue)
        setting.wrappedValue = false
        XCTAssertFalse(AppStorage(wrappedValue: false, key, store: defaults).wrappedValue)
    }

    func testDefaultPhotoRouteStartsWithoutQuestionnaireAndConsumesOnlyOnce() throws {
        var router = PhotoAnalysisInputRouter()
        let original = image()
        router.receive(image: original, depth: nil, depthNotice: "two-dimensional source")
        let request = try analysis(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false))
        XCTAssertTrue(request.image === original)
        XCTAssertNil(request.assessment)
        XCTAssertNil(request.depth)
        XCTAssertEqual(request.depthNotice, "two-dimensional source")
        XCTAssertFalse(router.hasPendingInput, "The photo must be cleared before the caller starts its Task.")
        assertWaiting(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false))
        XCTAssertNil(router.afterAssessmentDismissal())
    }

    func testPhotoIsNotConsumedWhileEitherCapturePresentationRemainsOpen() throws {
        for flags in [(true, false), (false, true), (true, true)] {
            var router = PhotoAnalysisInputRouter()
            let original = image()
            router.receive(image: original, depth: nil, depthNotice: nil)
            assertWaiting(router.afterPhotoDismissal(cameraPresented: flags.0, pickerPresented: flags.1))
            XCTAssertTrue(router.hasPendingInput)
            let request = try analysis(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false))
            XCTAssertTrue(request.image === original)
            XCTAssertFalse(router.hasPendingInput)
        }
    }

    func testOptInWaitsForExplicitAnswersAndDismissalThenConsumesOnlyOnce() throws {
        var router = PhotoAnalysisInputRouter()
        let original = image()
        let answer = SkinSelfAssessment(dryness: 1, oiliness: 2, reactivity: 3, age: 32)
        router.receive(image: original, depth: nil, depthNotice: "same photo")
        assertQuestionnaire(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false,
                                                       requestsAssessment: true))
        XCTAssertTrue(router.hasPendingInput)
        XCTAssertNil(router.afterAssessmentDismissal(), "A dismissal without a completed answer cannot analyze.")
        assertWaiting(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false,
                                                requestsAssessment: false))
        XCTAssertTrue(router.completeAssessment(answer))
        let request = try XCTUnwrap(router.afterAssessmentDismissal())
        XCTAssertTrue(request.image === original)
        XCTAssertEqual(request.assessment?.dryness, 1)
        XCTAssertEqual(request.assessment?.oiliness, 2)
        XCTAssertEqual(request.assessment?.reactivity, 3)
        XCTAssertEqual(request.assessment?.age, 32)
        XCTAssertFalse(router.hasPendingInput)
        XCTAssertNil(router.afterAssessmentDismissal())
        XCTAssertFalse(router.completeAssessment(answer))
    }

    func testOptInSkipUsesNilNotAnInventedQuestionnaire() throws {
        var router = PhotoAnalysisInputRouter()
        let original = image()
        router.receive(image: original, depth: nil, depthNotice: nil)
        assertQuestionnaire(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false,
                                                       requestsAssessment: true))
        XCTAssertTrue(router.completeAssessment(nil))
        let request = try XCTUnwrap(router.afterAssessmentDismissal())
        XCTAssertTrue(request.image === original)
        XCTAssertNil(request.assessment)
        XCTAssertFalse(router.hasPendingInput)
    }

    func testCancelRejectsLateDismissalAndLateCompletionWithoutRevivingPhoto() {
        var router = PhotoAnalysisInputRouter()
        router.receive(image: image(), depth: nil, depthNotice: "discard this request")
        assertQuestionnaire(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false,
                                                       requestsAssessment: true))
        router.cancel()
        XCTAssertFalse(router.hasPendingInput)
        XCTAssertNil(router.afterAssessmentDismissal())
        XCTAssertFalse(router.completeAssessment(SkinSelfAssessment(dryness: 1, oiliness: 1, reactivity: 1, age: nil)))
        assertWaiting(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false,
                                                requestsAssessment: true))
        XCTAssertNil(router.afterAssessmentDismissal())
    }

    func testCancelAlsoDiscardsAnAnsweredButNotYetDismissedQuestionnaire() {
        var router = PhotoAnalysisInputRouter()
        router.receive(image: image(), depth: nil, depthNotice: nil)
        assertQuestionnaire(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false,
                                                       requestsAssessment: true))
        XCTAssertTrue(router.completeAssessment(SkinSelfAssessment(dryness: 2, oiliness: 1, reactivity: 0, age: nil)))
        router.cancel()
        XCTAssertNil(router.afterAssessmentDismissal())
        XCTAssertFalse(router.hasPendingInput)
    }

    func testNewPhotoCannotInheritAnswersFromAnEarlierPhoto() throws {
        var router = PhotoAnalysisInputRouter()
        let first = image(.red), next = image(.blue)
        router.receive(image: first, depth: nil, depthNotice: "old")
        assertQuestionnaire(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false,
                                                       requestsAssessment: true))
        XCTAssertTrue(router.completeAssessment(SkinSelfAssessment(dryness: 3, oiliness: 3, reactivity: 3, age: 60)))
        router.receive(image: next, depth: nil, depthNotice: "new")
        XCTAssertNil(router.afterAssessmentDismissal(), "An old sheet dismissal must not consume the replacement photo.")
        let request = try analysis(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false))
        XCTAssertTrue(request.image === next)
        XCTAssertNil(request.assessment)
        XCTAssertEqual(request.depthNotice, "new")
        XCTAssertFalse(router.hasPendingInput)
    }

    func testSameCaptureDepthAndNoticeSurviveBothProductionRoutesUnmodified() throws {
        let original = image()
        let snapshot = try depth(for: original)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expected = try encoder.encode(snapshot)
        for wantsAssessment in [false, true] {
            var router = PhotoAnalysisInputRouter()
            router.receive(image: original, depth: snapshot, depthNotice: "synthetic same-capture transport")
            let decision = router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false,
                                                      requestsAssessment: wantsAssessment)
            let request: PhotoAnalysisInput
            if wantsAssessment {
                assertQuestionnaire(decision)
                XCTAssertTrue(router.completeAssessment(nil))
                request = try XCTUnwrap(router.afterAssessmentDismissal())
            } else { request = try analysis(decision) }
            XCTAssertTrue(request.image === original)
            XCTAssertEqual(try encoder.encode(XCTUnwrap(request.depth)), expected)
            XCTAssertTrue(try XCTUnwrap(request.depth).matches(image: request.image))
            XCTAssertEqual(request.depthNotice, "synthetic same-capture transport")
            XCTAssertFalse(router.hasPendingInput)
        }
    }

    func testNextLibraryInputDoesNotRetainPreviousCaptureDepthOrNotice() throws {
        var router = PhotoAnalysisInputRouter()
        let cameraImage = image(.red), libraryImage = image(.blue)
        router.receive(image: cameraImage, depth: try depth(for: cameraImage), depthNotice: "old camera notice")
        router.receiveImportedImage(libraryImage)
        let request = try analysis(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false))
        XCTAssertTrue(request.image === libraryImage)
        XCTAssertNil(request.depth)
        XCTAssertNil(request.assessment)
        XCTAssertEqual(request.depthNotice, "本次为相册照片，未携带受信同次 TrueDepth 深度；按二维照片分析。")
    }

    func testSuccessfulNilLibrarySelectionCancelsAndCannotAnalyzeOnDismissal() {
        var router = PhotoAnalysisInputRouter()
        router.receive(image: image(), depth: nil, depthNotice: "old pending image")
        // This is the actual Result<UIImage?, Error>.success(nil) picker contract.
        router.receiveImportedImage(nil)
        XCTAssertFalse(router.hasPendingInput)
        assertWaiting(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false))
        assertWaiting(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false,
                                                requestsAssessment: true))
        XCTAssertNil(router.afterAssessmentDismissal())
    }

    func testInvalidAnswersCannotCompleteOrConsumeTheQuestionnaire() throws {
        var router = PhotoAnalysisInputRouter()
        router.receive(image: image(), depth: nil, depthNotice: nil)
        assertQuestionnaire(router.afterPhotoDismissal(cameraPresented: false, pickerPresented: false,
                                                       requestsAssessment: true))
        XCTAssertFalse(router.completeAssessment(SkinSelfAssessment(dryness: -1, oiliness: 4, reactivity: 0, age: 5)))
        XCTAssertTrue(router.hasPendingInput)
        XCTAssertNil(router.afterAssessmentDismissal())
        XCTAssertTrue(router.completeAssessment(nil))
        XCTAssertNil(try XCTUnwrap(router.afterAssessmentDismissal()).assessment)
    }
}
