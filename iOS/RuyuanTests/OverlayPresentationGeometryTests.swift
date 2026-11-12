import Foundation
import CoreGraphics
import XCTest
@testable import Ruyuan

final class OverlayPresentationGeometryTests: XCTestCase {
    func testExistingRowsBecomeTwoExactSamplingEnvelopesIndependentOfPathOrder() {
        let layer = makeLayer([
            row(0.66, 0.36, 0.74, 0.37), row(0.25, 0.35, 0.32, 0.36),
            row(0.65, 0.35, 0.72, 0.36), row(0.27, 0.36, 0.35, 0.37)
        ])
        let result = regions(layer)
        XCTAssertEqual(result.count, 2)
        if result.count == 2 {
            assertRect(result[0], CGRect(x: 0.25, y: 0.35, width: 0.10, height: 0.02))
            assertRect(result[1], CGRect(x: 0.65, y: 0.35, width: 0.09, height: 0.02))
        }
    }

    func testBothEyesMayBeEntirelyOnEitherSideOfImageCenter() {
        for (a, b) in [(0.1, 0.3), (0.65, 0.85)] {
            let layer = makeLayer([row(a - 0.03, 0.36, a + 0.03, 0.37),
                                   row(b - 0.03, 0.36, b + 0.03, 0.37)])
            let result = regions(layer, landmarks: eyes(firstX: a, secondX: b))
            XCTAssertEqual(result.count, 2)
            if result.count == 2 {
                XCTAssertEqual(result[0].midX, a, accuracy: 0.000000001)
                XCTAssertEqual(result[1].midX, b, accuracy: 0.000000001)
            }
        }
    }

    func testSwappedVisionEyeNamesDoNotSwapSpatialEnvelopeOrder() {
        let layer = makeLayer([row(0.27, 0.36, 0.33, 0.37), row(0.67, 0.36, 0.73, 0.37)])
        var swapped = eyes()
        swapped[0].id = "rightEye"
        swapped[1].id = "leftEye"
        XCTAssertEqual(regions(layer), regions(layer, landmarks: swapped))
    }

    func testMirroredLandmarksAndRowsProduceMirroredEnvelopes() {
        let layer = makeLayer([row(0.24, 0.35, 0.32, 0.37), row(0.68, 0.36, 0.75, 0.38)])
        var mirror = layer
        mirror.paths = layer.paths.map { $0.map { point(1 - $0.x, $0.y) } }
        let mirroredEyes = eyes().map { path -> LandmarkPath in
            var result = path
            result.points = path.points.map { point(1 - $0.x, $0.y) }
            return result
        }
        let original = regions(layer)
        let result = regions(mirror, landmarks: mirroredEyes)
        XCTAssertEqual(original.count, 2)
        XCTAssertEqual(result.count, 2)
        for (actual, expected) in zip(result, original.reversed()) {
            assertRect(actual, CGRect(x: 1 - expected.maxX, y: expected.minY, width: expected.width, height: expected.height))
        }
    }

    func testNearestEyeGroupingUsesPixelAspectForNonSquareImages() {
        let landmarks = [eye("leftEye", x: 0.2, y: 0.2), eye("rightEye", x: 0.6, y: 0.4)]
        let layer = makeLayer([row(0.18, 0.24, 0.22, 0.25), row(0.20, 0.45, 0.22, 0.46)])
        let square = regions(layer, landmarks: landmarks, size: CGSize(width: 100, height: 100))
        let portrait = regions(layer, landmarks: landmarks, size: CGSize(width: 100, height: 1000))
        XCTAssertEqual(square.count, 1, "In normalized square distance both rows are closest to the first eye.")
        XCTAssertEqual(portrait.count, 2, "Pixel-space vertical distance makes the lower row closest to the second eye.")
        if portrait.count == 2 {
            assertRect(portrait[0], CGRect(x: 0.18, y: 0.24, width: 0.04, height: 0.01))
            assertRect(portrait[1], CGRect(x: 0.20, y: 0.45, width: 0.02, height: 0.01))
        }
        XCTAssertEqual(portrait, regions(layer, landmarks: landmarks, size: CGSize(width: 1000, height: 10000)))
    }

    func testOnlyExplicitUnderEyePolygonLayerIsEligible() {
        let original = makeLayer([row(0.27, 0.36, 0.33, 0.37)])
        for id in ["appearance-redness", "appearance-lines-eye", "sample-eyes", "Appearance-under-eye", ""] {
            var layer = original
            layer.id = id
            XCTAssertTrue(regions(layer).isEmpty)
        }
        for kind in [OverlayKind.lines, .points] {
            var layer = original
            layer.kind = kind
            XCTAssertTrue(regions(layer).isEmpty)
        }
    }

    func testMissingEmptyUnclosedOrDegenerateEyeEvidenceDoesNotCreateFrames() {
        let layer = makeLayer([row(0.27, 0.36, 0.33, 0.37)])
        XCTAssertTrue(regions(layer, landmarks: []).isEmpty)
        XCTAssertTrue(regions(layer, landmarks: [eyes()[0]]).isEmpty)
        var empty = eyes()
        empty[1].points = []
        XCTAssertTrue(regions(layer, landmarks: empty).isEmpty)
        var unclosed = eyes()
        unclosed[1].closed = false
        XCTAssertTrue(regions(layer, landmarks: unclosed).isEmpty)
        var collinear = eyes()
        collinear[1].points = [point(0.6, 0.3), point(0.65, 0.3), point(0.7, 0.3), point(0.75, 0.3)]
        XCTAssertTrue(regions(layer, landmarks: collinear).isEmpty)
        let onlyMeshNames = eyes().map { path -> LandmarkPath in
            var copy = path; copy.id = "mp-" + copy.id; return copy
        }
        XCTAssertTrue(regions(layer, landmarks: onlyMeshNames).isEmpty)
    }

    func testDuplicateOverlappingOrIdenticalEyesAreRejectedWithoutDictionaryTraps() {
        let layer = makeLayer([row(0.27, 0.36, 0.33, 0.37)])
        XCTAssertTrue(regions(layer, landmarks: eyes() + [eyes()[0]]).isEmpty)
        let identical = [eye("leftEye", x: 0.3, y: 0.3), eye("rightEye", x: 0.3, y: 0.3)]
        XCTAssertTrue(regions(layer, landmarks: identical).isEmpty)
        let overlapping = [eye("leftEye", x: 0.3, y: 0.3), eye("rightEye", x: 0.32, y: 0.3)]
        XCTAssertTrue(regions(layer, landmarks: overlapping).isEmpty)
    }

    func testEmptyOrNonRectangularPathsDoNotBecomeGuessedBoundingBoxes() {
        XCTAssertTrue(regions(makeLayer([])).isEmpty)
        let invalid: [[Ruyuan.NormalizedPoint]] = [
            [], [point(0.25, 0.35)],
            [point(0.25, 0.35), point(0.35, 0.35), point(0.30, 0.37)],
            [point(0.25, 0.35), point(0.35, 0.35), point(0.34, 0.37), point(0.26, 0.37)],
            [point(0.25, 0.35), point(0.35, 0.37), point(0.35, 0.35), point(0.25, 0.37)],
            row(0.25, 0.35, 0.35, 0.35)
        ]
        for path in invalid { XCTAssertTrue(regions(makeLayer([path])).isEmpty) }
    }

    func testNonfiniteOrOutOfBoundsCoordinatesRejectWholePresentation() {
        let original = makeLayer([row(0.27, 0.36, 0.33, 0.37)])
        for bad in [Double.nan, .infinity, -.infinity, -0.001, 1.001] {
            var layer = original
            layer.paths[0][0].x = bad
            XCTAssertTrue(regions(layer).isEmpty)
            var landmarks = eyes()
            landmarks[0].points[0].y = bad
            XCTAssertTrue(regions(original, landmarks: landmarks).isEmpty)
        }
        var mixed = original
        mixed.paths.append([point(0.7, .nan)])
        XCTAssertTrue(regions(mixed).isEmpty, "Do not silently turn a partially invalid layer into apparently complete frames.")
    }

    func testInvalidImageDimensionsCannotFallBackToSquareDistance() {
        let layer = makeLayer([row(0.27, 0.36, 0.33, 0.37)])
        for size in [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: 10, height: 0),
                     CGSize(width: CGFloat.nan, height: 10), CGSize(width: 10, height: CGFloat.infinity)] {
            XCTAssertTrue(regions(layer, size: size).isEmpty)
        }
    }

    func testOneEyeWithActualRowsDoesNotCreateAnUnobservedCounterpart() {
        let layer = makeLayer([row(0.27, 0.36, 0.33, 0.37), row(0.28, 0.38, 0.32, 0.39)])
        let result = regions(layer)
        XCTAssertEqual(result.count, 1)
        if let rectangle = result.first {
            assertRect(rectangle, CGRect(x: 0.27, y: 0.36, width: 0.06, height: 0.03))
        }
    }

    func testAmbiguousOrCrossEyeRowsAndAboveEyeRowsAreRejected() {
        XCTAssertTrue(regions(makeLayer([row(0.45, 0.36, 0.55, 0.37)])).isEmpty)
        XCTAssertTrue(regions(makeLayer([row(0.48, 0.36, 0.65, 0.37)])).isEmpty,
                      "A row spanning both nearest-eye cells must not be assigned by its midpoint alone.")
        XCTAssertTrue(regions(makeLayer([row(0.27, 0.10, 0.33, 0.11)])).isEmpty)
    }

    func testRowsAtImageEdgesRemainInsideNormalizedBoundsWithoutPadding() {
        let landmarks = [eye("leftEye", x: 0.08, y: 0.94), eye("rightEye", x: 0.92, y: 0.94)]
        let layer = makeLayer([row(0, 0.99, 0.10, 1), row(0.90, 0.99, 1, 1)])
        let result = regions(layer, landmarks: landmarks)
        XCTAssertEqual(result.count, 2)
        for rectangle in result {
            XCTAssertGreaterThanOrEqual(rectangle.minX, 0)
            XCTAssertGreaterThanOrEqual(rectangle.minY, 0)
            XCTAssertLessThanOrEqual(rectangle.maxX, 1)
            XCTAssertLessThanOrEqual(rectangle.maxY, 1)
            XCTAssertEqual(rectangle.minY, 0.99, accuracy: 0.000000001)
            XCTAssertEqual(rectangle.maxY, 1)
        }
    }

    func testNativeRowFractionsClosedCornersAndReversedWindingStayValid() {
        let paths = (300..<305).map { y in
            row(180.0 / 768, Double(y) / 768, 290.0 / 768, Double(y + 1) / 768)
        }
        let layer = makeLayer(paths)
        let original = regions(layer)
        XCTAssertEqual(original.count, 1)
        var closed = layer
        closed.paths = paths.map { path in path + [path[0]] }
        XCTAssertEqual(regions(closed), original)
        var reversed = layer
        reversed.paths = paths.map { Array($0.reversed()) }
        XCTAssertEqual(regions(reversed), original)
        var repeatedEyeClosure = eyes()
        for index in repeatedEyeClosure.indices {
            let first = repeatedEyeClosure[index].points[0]
            repeatedEyeClosure[index].points.append(first)
        }
        XCTAssertEqual(regions(layer, landmarks: repeatedEyeClosure), original)
    }

    func testPresentationDoesNotModifySerializedEvidenceOrLandmarks() throws {
        let layer = makeLayer([row(0.27, 0.36, 0.33, 0.37), row(0.67, 0.36, 0.73, 0.37)])
        let landmarks = eyes()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalLayer = try encoder.encode(layer)
        let originalLandmarks = try encoder.encode(landmarks)
        XCTAssertEqual(regions(layer, landmarks: landmarks).count, 2)
        XCTAssertEqual(try encoder.encode(layer), originalLayer)
        XCTAssertEqual(try encoder.encode(landmarks), originalLandmarks)
    }

    private func regions(_ layer: OverlayLayer, landmarks: [LandmarkPath]? = nil,
                         size: CGSize = CGSize(width: 1080, height: 1440)) -> [CGRect] {
        OverlayPresentationGeometry.eyeSamplingRegions(for: layer, landmarks: landmarks ?? eyes(), imageSize: size)
    }

    private func eyes(firstX: Double = 0.3, secondX: Double = 0.7) -> [LandmarkPath] {
        [eye("leftEye", x: firstX, y: 0.3), eye("rightEye", x: secondX, y: 0.3)]
    }

    private func eye(_ id: String, x: Double, y: Double) -> LandmarkPath {
        LandmarkPath(id: id, points: row(x - 0.04, y - 0.02, x + 0.04, y + 0.02), closed: true)
    }

    private func row(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [Ruyuan.NormalizedPoint] {
        [point(x0, y0), point(x1, y0), point(x1, y1), point(x0, y1)]
    }

    private func point(_ x: Double, _ y: Double) -> Ruyuan.NormalizedPoint { .init(x: x, y: y) }

    private func makeLayer(_ paths: [[Ruyuan.NormalizedPoint]]) -> OverlayLayer {
        OverlayLayer(id: "appearance-under-eye", title: "合成眼下采样范围", colorHex: "8677B9", kind: .polygons,
                     paths: paths, note: "合成ROI几何回归；不是真实病灶分割。", source: "synthetic row-run evidence")
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.000000001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.000000001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.000000001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.000000001, file: file, line: line)
    }
}
