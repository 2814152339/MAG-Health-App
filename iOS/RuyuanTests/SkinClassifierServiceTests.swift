import XCTest
import UIKit
@testable import Ruyuan

final class SkinClassifierServiceTests: XCTestCase {
    func testStableSoftmaxAndNonfiniteRejection() throws {
        let values = try SkinClassifierService.probabilities(logits: [10000, 10001, 10002])
        XCTAssertEqual(values.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(values[2], 0.6652409557748218, accuracy: 1e-12)
        XCTAssertThrowsError(try SkinClassifierService.probabilities(logits: [.nan]))
        XCTAssertThrowsError(try SkinClassifierService.probabilities(logits: []))
    }
    func testPinnedMetadataRejectsWrongClassOrderOrRevision() throws {
        let spec = SkinClassifierService.specs[0]
        let classes = String(data: try JSONEncoder().encode(spec.classes), encoding: .utf8)!
        var metadata = ["ruyuan.revision": spec.revision, "ruyuan.source_sha256": spec.digest, "ruyuan.class_names": classes]
        XCTAssertNoThrow(try SkinClassifierService.validateMetadata(metadata, spec: spec))
        metadata["ruyuan.revision"] = "different"
        XCTAssertThrowsError(try SkinClassifierService.validateMetadata(metadata, spec: spec))
        metadata["ruyuan.revision"] = spec.revision
        metadata["ruyuan.class_names"] = "[]"
        XCTAssertThrowsError(try SkinClassifierService.validateMetadata(metadata, spec: spec))
    }
    func testClassificationDoesNotReplaceScoresOrInventMasks() throws {
        let original = SampleData.report
        let observation = SkinClassifierService.Observation(spec: SkinClassifierService.specs[0],
            probabilities: [0.7, 0.1, 0.1, 0.05, 0.05], state: "ready", elapsed: 1)
        let report = SkinClassifierService.applying([observation], to: original)
        XCTAssertEqual(report.skin.compactMap(\.score), original.skin.compactMap(\.score))
        XCTAssertEqual(report.overlays.count, original.overlays.count)
        XCTAssertTrue(report.skin.flatMap(\.items).contains { $0.id == "trained-acne" && $0.overlayID == nil })
        XCTAssertNoThrow(try ReportValidator.validate(report))
    }
    func testModelFailureNeverProducesClassification() {
        let observation = SkinClassifierService.Observation(spec: SkinClassifierService.specs[0], probabilities: nil, state: "metadata_mismatch", elapsed: 0)
        let report = SkinClassifierService.applying([observation], to: SampleData.report)
        let item = report.skin.flatMap(\.items).first { $0.id == "trained-acne" }
        XCTAssertEqual(item?.valueText, "未运行 · metadata_mismatch")
        XCTAssertFalse(report.quality.first { $0.id == "trainedSkinModels" }!.passed)
    }
}
