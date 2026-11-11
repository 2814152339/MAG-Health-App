import XCTest
@testable import Ruyuan

final class FaceGeometryAnalyzerTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> NormalizedPoint { NormalizedPoint(x: x, y: y) }
    private func rectangle(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [NormalizedPoint] {
        [p(x0, y0), p(x1, y0), p(x1, y1), p(x0, y1)]
    }
    private func value(_ suffix: String, _ paths: [String: [NormalizedPoint]], width: Int = 1000, height: Int = 1000) throws -> Double {
        try XCTUnwrap(FaceGeometryAnalyzer.metrics(landmarks: paths, width: width, height: height).first { $0.id == "v2-" + suffix }?.value)
    }
    private var completePaths: [String: [NormalizedPoint]] {
        ["faceContour": [p(0.1, 0.2), p(0.1, 0.8), p(0.5, 0.8), p(0.9, 0.8), p(0.9, 0.2)],
         "leftEye": rectangle(0.2, 0.25, 0.4, 0.35),
         "rightEye": rectangle(0.6, 0.25, 0.8, 0.35),
         "leftEyebrow": [p(0.2, 0.2), p(0.3, 0.1), p(0.4, 0.2)],
         "rightEyebrow": [p(0.6, 0.2), p(0.7, 0.1), p(0.8, 0.2)],
         "nose": rectangle(0.43, 0.35, 0.57, 0.5),
         "outerLips": rectangle(0.3, 0.55, 0.7, 0.65),
         "innerLips": rectangle(0.34, 0.58, 0.66, 0.62)]
    }
    func testEmptyAndInvalidSizesNeverInventMeasurements() {
        XCTAssertTrue(FaceGeometryAnalyzer.metrics(landmarks: [:], width: 1000, height: 1000).allSatisfy { $0.value == nil })
        XCTAssertTrue(FaceGeometryAnalyzer.overlays(landmarks: [:], width: 1000, height: 1000).isEmpty)
        XCTAssertTrue(FaceGeometryAnalyzer.metrics(landmarks: completePaths, width: 0, height: 1000).allSatisfy { $0.value == nil })
        XCTAssertTrue(FaceGeometryAnalyzer.overlays(landmarks: completePaths, width: 1000, height: -1).isEmpty)
    }
    func testEyeRatiosUsePixelAspectNotNormalizedDistances() throws {
        let paths = ["leftEye": rectangle(0.2, 0.3, 0.4, 0.4)]
        XCTAssertEqual(try value("leftEye-aspect", paths), 0.5, accuracy: 0.000001)
        XCTAssertEqual(try value("leftEye-aspect", paths, height: 2000), 1, accuracy: 0.000001)
    }
    func testFiveEyeSegmentsUseTrueExtremaAndImageLeftRight() throws {
        var paths = completePaths
        // Reverse and rotate each ring; names intentionally do not determine image left/right.
        paths["leftEye"] = [p(0.8, 0.35), p(0.6, 0.35), p(0.6, 0.25), p(0.8, 0.25)]
        paths["rightEye"] = [p(0.4, 0.35), p(0.2, 0.35), p(0.2, 0.25), p(0.4, 0.25)]
        XCTAssertEqual(try value("five-left-margin", paths), 0.5, accuracy: 0.000001)
        XCTAssertEqual(try value("five-left-eye", paths), 1, accuracy: 0.000001)
        XCTAssertEqual(try value("five-gap", paths), 1, accuracy: 0.000001)
        XCTAssertEqual(try value("five-right-eye", paths), 1, accuracy: 0.000001)
        XCTAssertEqual(try value("five-right-margin", paths), 0.5, accuracy: 0.000001)
    }
    func testJawAnglesAndChinRegionAreDefinedByObservedContour() throws {
        XCTAssertEqual(try value("jaw-left-angle", completePaths), 90, accuracy: 0.000001)
        XCTAssertEqual(try value("jaw-right-angle", completePaths), 90, accuracy: 0.000001)
        XCTAssertEqual(try value("chin-height-face-width", completePaths), 150.0 / 800, accuracy: 0.000001)
        XCTAssertEqual(try value("chin-width-face-width", completePaths), 1, accuracy: 0.000001)
        var reversed = completePaths
        reversed["faceContour"] = Array(completePaths["faceContour"]!.reversed())
        XCTAssertEqual(try value("jaw-left-angle", reversed), 90, accuracy: 0.000001)
        XCTAssertEqual(try value("jaw-right-angle", reversed), 90, accuracy: 0.000001)
    }
    func testGoldenTriangleUsesThreeMeasuredCenters() throws {
        var paths = completePaths
        paths["outerLips"] = rectangle(0.45, 0.45, 0.55, 0.55)
        XCTAssertEqual(try value("triangle-mouth-angle", paths), 90, accuracy: 0.000001)
        XCTAssertEqual(try value("triangle-left-eye-angle", paths), 45, accuracy: 0.000001)
        XCTAssertEqual(try value("triangle-right-eye-angle", paths), 45, accuracy: 0.000001)
        XCTAssertEqual(try value("triangle-mouth-angle", paths, height: 2000), 2 * atan(0.5) * 180 / .pi, accuracy: 0.000001)
    }
    func testBrowAnglesAndCurvatureDoNotMeasureHairThickness() throws {
        XCTAssertEqual(try value("leftEyebrow-arch-angle", completePaths), 90, accuracy: 0.000001)
        XCTAssertEqual(try value("leftEyebrow-curvature", completePaths), 0.5, accuracy: 0.000001)
        var paths = completePaths
        paths["leftEyebrow"] = [p(0.4, 0.2), p(0.3, 0.2), p(0.2, 0.2)]
        XCTAssertEqual(try value("leftEyebrow-arch-angle", paths), 180, accuracy: 0.000001)
        XCTAssertEqual(try value("leftEyebrow-curvature", paths), 0, accuracy: 0.000001)
    }
    func testInnerEyeAnglesSurviveRingOrderReversalAndDuplicateClosure() throws {
        XCTAssertEqual(try value("leftEye-inner-angle", completePaths), 90, accuracy: 0.000001)
        var paths = completePaths
        let reversed = Array(paths["leftEye"]!.reversed())
        paths["leftEye"] = reversed + [reversed[0]]
        XCTAssertEqual(try value("leftEye-inner-angle", paths), 90, accuracy: 0.000001)
        XCTAssertEqual(try value("rightEye-inner-angle", paths), 90, accuracy: 0.000001)
    }
    func testUpperAndLowerLipBandsUsePolygonIntersections() throws {
        var paths = completePaths
        paths["outerLips"] = rectangle(0.3, 0.6, 0.7, 0.8)
        paths["innerLips"] = rectangle(0.34, 0.66, 0.66, 0.73)
        XCTAssertEqual(try value("upper-lip-width", paths), 0.15, accuracy: 0.000001)
        XCTAssertEqual(try value("lower-lip-width", paths), 0.175, accuracy: 0.000001)
        XCTAssertEqual(try value("upper-lower-lip", paths), 6.0 / 7, accuracy: 0.000001)
        paths["innerLips"] = Array(paths["innerLips"]!.reversed())
        XCTAssertEqual(try value("upper-lower-lip", paths), 6.0 / 7, accuracy: 0.000001)
    }
    func testInvalidPointRejectsItsRegionInsteadOfClampingEvidence() {
        let paths = ["leftEye": [p(0.2, 0.2), p(0.4, 0.2), p(2, 0.3), p(0.2, 0.3)]]
        XCTAssertTrue(FaceGeometryAnalyzer.metrics(landmarks: paths, width: 1000, height: 1000).allSatisfy { $0.value == nil })
        XCTAssertTrue(FaceGeometryAnalyzer.overlays(landmarks: paths, width: 1000, height: 1000).isEmpty)
    }
    func testAllLayersHaveGeometryIDsAndFiniteNormalizedCoordinates() {
        let layers = FaceGeometryAnalyzer.overlays(landmarks: completePaths, width: 1000, height: 2000)
        XCTAssertFalse(layers.isEmpty)
        XCTAssertEqual(Set(layers.map(\.id)).count, layers.count)
        XCTAssertTrue(layers.allSatisfy { $0.id.hasPrefix("geometry-") })
        XCTAssertTrue(layers.flatMap(\.paths).flatMap { $0 }.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
        })
        XCTAssertTrue(layers.contains { $0.kind == .points })
        XCTAssertTrue(layers.contains { $0.kind == .lines })
    }
    func testStraightJawAndCollinearTriangleDoNotProduceAngles() {
        var paths = completePaths
        paths["faceContour"] = [p(0.1, 0.2), p(0.3, 0.5), p(0.5, 0.8)]
        paths["outerLips"] = rectangle(0.45, 0.25, 0.55, 0.35)
        let values = FaceGeometryAnalyzer.metrics(landmarks: paths, width: 1000, height: 1000)
        XCTAssertNil(values.first { $0.id == "v2-jaw-left-angle" }?.value)
        XCTAssertNil(values.first { $0.id == "v2-triangle-mouth-angle" }?.value)
    }
}
