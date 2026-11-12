import XCTest
import UIKit
@testable import Ruyuan

final class SkinClassifierServiceTests: XCTestCase {
    func testBundledTrainedModelsActuallyPredictFP32ReferenceFixture() throws {
        guard let manifestURL = Bundle.main.url(forResource: "coreml-model-manifest", withExtension: "json") else {
            #if RUYUAN_COREML_BUNDLED
            XCTFail("Approved model resources were required but are missing from the built app")
            return
            #else
            throw XCTSkip("No approved Core ML artifact packages in this pre-conversion build")
            #endif
        }
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let records = try XCTUnwrap(manifest["models"] as? [[String: Any]])
        XCTAssertEqual(Set(records.compactMap { $0["id"] as? String }), Set(SkinClassifierService.specs.map(\.id)))
        let pixels = (0..<(224*224)).flatMap { _ -> [UInt8] in [182, 137, 111, 255] }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(width: 224, height: 224, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 224*4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        for spec in SkinClassifierService.specs {
            let record = try XCTUnwrap(records.first { $0["id"] as? String == spec.id })
            let validation = try XCTUnwrap(record["validation"] as? [String: Any])
            let samples = try XCTUnwrap(validation["samples"] as? [[String: Any]])
            let fixture = try XCTUnwrap(samples.first { $0["name"] as? String == "uniform_rgb" })
            let logits = try XCTUnwrap(fixture["torchLogits"] as? [Double])
            let expected = try SkinClassifierService.probabilities(logits: logits)
            let actual = try autoreleasepool { try SkinClassifierService.predict(image: image, spec: spec) }
            XCTAssertEqual(actual.count, expected.count)
            for (a, b) in zip(actual, expected) { XCTAssertEqual(a, b, accuracy: 0.01, spec.id) }
            XCTAssertEqual(actual.indices.max(by: { actual[$0] < actual[$1] }),
                           expected.indices.max(by: { expected[$0] < expected[$1] }), spec.id)
        }
    }

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
