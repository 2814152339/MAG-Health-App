import UIKit
import XCTest
@testable import Ruyuan

final class DepthMeasurementServiceTests: XCTestCase {
    private func snapshot(depth: [Float]? = nil, matrix: [Float]? = nil,
                          direct: [Float] = [0, 0], inverse: [Float] = [0, 0],
                          image: UIImage? = nil, width: Int = 64, height: Int = 64,
                          referenceWidth: Double = 640, referenceHeight: Double = 640) -> DepthSnapshot {
        DepthSnapshot(captureID: "math-fixture", originalJPEGSHA256: String(repeating: "a", count: 64),
            sourceImageFingerprint: image.flatMap { DepthSnapshot.imageFingerprint($0) } ?? "fixture-not-a-photo",
            imageWidth: Int(referenceWidth), imageHeight: Int(referenceHeight), width: width, height: height,
            depthMeters: depth ?? [Float](repeating: 0.5, count: width * height),
            intrinsicMatrix: matrix ?? [640, 0, 0, 0, 640, 0, Float(referenceWidth / 2), Float(referenceHeight / 2), 1],
            referenceWidth: referenceWidth, referenceHeight: referenceHeight,
            distortionCenterX: referenceWidth / 2, distortionCenterY: referenceHeight / 2,
            lensDistortion: direct, inverseLensDistortion: inverse, originalExifOrientation: 1,
            source: "Synthetic mathematical fixture, NOT device evidence")
    }
    private var nose: [String: [NormalizedPoint]] {
        ["nose": [.init(x: 0.4, y: 0.5), .init(x: 0.5, y: 0.45), .init(x: 0.6, y: 0.5)]]
    }

    func testKnownHalfMeterPlaneProduces100mmChordAndIsotropicScalingDoesNotChangeIt() throws {
        let input = snapshot()
        let first = try XCTUnwrap(DepthMeasurementService.metrics(snapshot: input, landmarks: nose, imageWidth: 640, imageHeight: 640).first)
        let resized = try XCTUnwrap(DepthMeasurementService.metrics(snapshot: input, landmarks: nose, imageWidth: 2560, imageHeight: 2560).first)
        XCTAssertEqual(try XCTUnwrap(first.value), 100, accuracy: 0.0001)
        XCTAssertEqual(first.value, resized.value)
        XCTAssertEqual(first.unit, "mm")
        XCTAssertTrue(first.note.contains("不是沿皮肤曲线长度、骨性尺寸或临床测量"))
    }

    func testVaryingRealDepthUses3DDistanceNotFlatImagePixels() throws {
        var values = [Float](repeating: 0.5, count: 64 * 64)
        for y in 0..<64 { for x in 32..<64 { values[y * 64 + x] = 0.6 } }
        let result = DepthMeasurementService.metrics(snapshot: snapshot(depth: values), landmarks: nose, imageWidth: 640, imageHeight: 640)
        let mm = try XCTUnwrap(result.first?.value)
        XCTAssertEqual(mm, sqrt(0.11 * 0.11 + 0.1 * 0.1) * 1000, accuracy: 0.001)
        XCTAssertGreaterThan(mm, 100)
    }

    func testNonSquareReferenceUsesIndependentImageDimensions() throws {
        let input = snapshot(width: 64, height: 32, referenceWidth: 640, referenceHeight: 320)
        let a = try XCTUnwrap(DepthMeasurementService.surfacePoint(snapshot: input, point: .init(x: 0.5, y: 0.4)))
        let b = try XCTUnwrap(DepthMeasurementService.surfacePoint(snapshot: input, point: .init(x: 0.5, y: 0.6)))
        XCTAssertEqual(abs(b.y - a.y) * 1000, 50, accuracy: 0.0001)
        XCTAssertEqual(a.z, 0.5, accuracy: 0.0001)
    }

    func testRotatedIntrinsicMatrixIsInvertedAsFullMatrix() throws {
        // 90° pixel-plane transform of K, as a transformed calibration may encode it.
        let matrix: [Float] = [0, 640, 0, -640, 0, 0, 320, 320, 1]
        let metrics = DepthMeasurementService.metrics(snapshot: snapshot(matrix: matrix), landmarks: nose, imageWidth: 640, imageHeight: 640)
        XCTAssertEqual(try XCTUnwrap(metrics.first?.value), 100, accuracy: 0.0001)
    }

    func testRelativeRadialLUTCorrectionAndRoundTripAreNotIgnored() throws {
        let inverse = -Float(1) / 11
        let input = snapshot(direct: [0.1, 0.1], inverse: [inverse, inverse])
        let mapped = try XCTUnwrap(DepthMeasurementService.radialMap(x: 384, y: 320, snapshot: input, table: input.inverseLensDistortion))
        XCTAssertEqual(mapped.x, 320 + 64 / 1.1, accuracy: 0.0001)
        let metrics = DepthMeasurementService.metrics(snapshot: input, landmarks: nose, imageWidth: 640, imageHeight: 640)
        XCTAssertEqual(try XCTUnwrap(metrics.first?.value), 100 / 1.1, accuracy: 0.0001)
        let inconsistent = snapshot(direct: [0, 0], inverse: [0.1, 0.1])
        XCTAssertNil(DepthMeasurementService.surfacePoint(snapshot: inconsistent, point: .init(x: 0.6, y: 0.5)))
    }

    func testMissingDepthMixedEdgesInvalidCalibrationAndAspectMismatchAbstain() {
        var holes = [Float](repeating: 0.5, count: 64 * 64)
        for y in 31...33 { for x in 24...26 { holes[y * 64 + x] = 0 } }
        XCTAssertNil(DepthMeasurementService.surfacePoint(snapshot: snapshot(depth: holes), point: .init(x: 0.4, y: 0.5)))
        holes = [Float](repeating: 0.5, count: 64 * 64)
        holes[32 * 64 + 25] = 0.55
        XCTAssertNil(DepthMeasurementService.surfacePoint(snapshot: snapshot(depth: holes), point: .init(x: 0.4, y: 0.5)))
        XCTAssertNil(DepthMeasurementService.surfacePoint(snapshot: snapshot(matrix: [Float](repeating: 0, count: 9)), point: .init(x: 0.4, y: 0.5)))
        XCTAssertNil(DepthMeasurementService.surfacePoint(snapshot: snapshot(inverse: []), point: .init(x: 0.4, y: 0.5)))
        XCTAssertNil(DepthMeasurementService.surfacePoint(snapshot: snapshot(), point: .init(x: .nan, y: 0.5)))
        XCTAssertTrue(DepthMeasurementService.metrics(snapshot: snapshot(), landmarks: nose, imageWidth: 640, imageHeight: 480).isEmpty)
        XCTAssertTrue(DepthMeasurementService.metrics(snapshot: snapshot(), landmarks: [:], imageWidth: 640, imageHeight: 640).isEmpty)
    }

    func testSamePhotoFingerprintRejectsChangedPixelsOrExifOrientation() throws {
        func image(_ color: UIColor) -> UIImage {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
            }
        }
        let original = image(.red), input = snapshot(image: original)
        XCTAssertTrue(input.matches(image: original))
        XCTAssertFalse(input.matches(image: image(.blue)))
        let rotated = UIImage(cgImage: try XCTUnwrap(original.cgImage), scale: 1, orientation: .right)
        XCTAssertFalse(input.matches(image: rotated))
        XCTAssertNotNil(CameraCapture(image: original, depth: input, depthNotice: "fixture").validatedDepth())
        XCTAssertNil(CameraCapture(image: image(.blue), depth: input, depthNotice: "fixture").validatedDepth())
    }

    func testOverlaysOnlyContainMeasuredEndpointsAndInvalidHolesEncodeWithoutNaN() throws {
        let input = snapshot()
        let overlays = DepthMeasurementService.overlays(snapshot: input, landmarks: nose, imageWidth: 640, imageHeight: 640)
        XCTAssertEqual(overlays.count, 1)
        XCTAssertEqual(overlays[0].paths, [[nose["nose"]![0], nose["nose"]![2]]])
        XCTAssertTrue(overlays[0].source.contains("originalJPEG-SHA256="))
        var zeros = [Float](repeating: 0.5, count: 64 * 64); zeros[0] = 0
        let encoded = try JSONEncoder().encode(snapshot(depth: zeros))
        let decoded = try JSONDecoder().decode(DepthSnapshot.self, from: encoded)
        XCTAssertTrue(decoded.isUsable)
        XCTAssertEqual(decoded.depthMeters[0], 0)
    }
}
