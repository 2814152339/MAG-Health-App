import Foundation
import CoreGraphics
import XCTest
@testable import Ruyuan

final class ScanFeatureGuideGeometryTests: XCTestCase {
    func testObservedPairProducesEightEnvelopeReferencesAndFourDimensionSpans() throws {
        let guides = try XCTUnwrap(make())
        XCTAssertEqual(guides.eyeID, "leftEye")
        XCTAssertEqual(guides.browID, "leftEyebrow")
        XCTAssertEqual(guides.referenceSegments.count, 8)
        XCTAssertEqual(guides.dimensionSegments.count, 4)
        XCTAssertEqual(Set(guides.referenceSegments.map(\.id)).count, 8)
        XCTAssertEqual(Set(guides.dimensionSegments.map(\.id)), Set(["brow-width", "brow-height", "eye-width", "eye-height"]))
        assertRect(guides.eyeBounds, CGRect(x: 100, y: 135, width: 100, height: 30))
        assertRect(guides.browBounds, CGRect(x: 95, y: 102, width: 110, height: 18))
        let width = try segment("brow-width", in: guides.dimensionSegments)
        assertPoint(width.start, CGPoint(x: 95, y: 90))
        assertPoint(width.end, CGPoint(x: 205, y: 90))
        let eye = try segment("eye-width", in: guides.dimensionSegments)
        assertPoint(eye.start, CGPoint(x: 100, y: 177))
        assertPoint(eye.end, CGPoint(x: 200, y: 177))
    }

    func testInputOrderAndBrowTraversalDirectionDoNotChangeGuides() throws {
        let paths = fixture()
        let expected = try XCTUnwrap(make(paths))
        XCTAssertEqual(make(Array(paths.reversed())), expected)
        var reversed = paths
        reversed[0].points.reverse()
        reversed[1].points.reverse()
        XCTAssertEqual(make(reversed), expected)
    }

    func testMirroredSameSidePairMirrorsBoundsAndDimensionPlacement() throws {
        let original = try XCTUnwrap(make())
        let mirrored = fixture().map { path -> LandmarkPath in
            var value = path
            value.id = path.id == "leftEye" ? "rightEye" : "rightEyebrow"
            value.points = path.points.map { point(1 - $0.x, $0.y) }
            return value
        }
        let result = try XCTUnwrap(make(mirrored))
        XCTAssertEqual(result.eyeID, "rightEye")
        XCTAssertEqual(result.browID, "rightEyebrow")
        assertRect(result.eyeBounds, CGRect(x: 500 - original.eyeBounds.maxX, y: original.eyeBounds.minY,
                                           width: original.eyeBounds.width, height: original.eyeBounds.height))
        assertRect(result.browBounds, CGRect(x: 500 - original.browBounds.maxX, y: original.browBounds.minY,
                                            width: original.browBounds.width, height: original.browBounds.height))
        for source in original.dimensionSegments {
            let target = try segment(source.id, in: result.dimensionSegments)
            let a = CGPoint(x: 500 - source.start.x, y: source.start.y)
            let b = CGPoint(x: 500 - source.end.x, y: source.end.y)
            if source.id.hasSuffix("width") {
                assertPoint(target.start, b); assertPoint(target.end, a)
            } else {
                assertPoint(target.start, a); assertPoint(target.end, b)
            }
        }
    }

    func testNonSquarePixelsAndFocusedRegionUseActualReportPhotoTransform() throws {
        let transform = ReportPhotoTransform(imageSize: CGSize(width: 1200, height: 600),
            viewport: CGSize(width: 360, height: 400), region: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
        let result = try XCTUnwrap(make(transform: transform))
        assertRect(result.eyeBounds, CGRect(x: 72, y: 200, width: 144, height: 36))
        assertRect(result.browBounds, CGRect(x: 64.8, y: 160.4, width: 158.4, height: 21.6))
        let eyeWidth = try segment("eye-width", in: result.dimensionSegments)
        XCTAssertEqual(eyeWidth.end.x - eyeWidth.start.x, result.eyeBounds.width, accuracy: 0.00000001)
        let eyeHeight = try segment("eye-height", in: result.dimensionSegments)
        XCTAssertEqual(eyeHeight.end.y - eyeHeight.start.y, result.eyeBounds.height, accuracy: 0.00000001)
    }

    func testMissingDuplicatedUnknownOrCrossSidePathsAbstain() {
        let paths = fixture()
        XCTAssertNil(make([]))
        XCTAssertNil(make([paths[0]]))
        XCTAssertNil(make(paths + [paths[0]]))
        XCTAssertNil(make([paths[0], paths[0]]))
        var wrongSide = paths
        wrongSide[1].id = "rightEyebrow"
        XCTAssertNil(make(wrongSide))
        var unknown = paths
        unknown[1].id = "mp-leftEyebrow"
        XCTAssertNil(make(unknown))
    }

    func testNonfiniteAndOutOfRangeSourcePointsRejectEntirePresentation() {
        for invalid in [point(.nan, 0.4), point(.infinity, 0.4), point(0.3, -.infinity),
                        point(-0.001, 0.4), point(0.3, 1.001)] {
            for index in 0..<2 {
                var paths = fixture()
                paths[index].points.append(invalid)
                XCTAssertNil(make(paths))
            }
        }
    }

    func testEyeMustBeClosedWithFourDistinctVerticesAndNonzeroPolygonArea() {
        var open = fixture()
        open[0].closed = false
        XCTAssertNil(make(open))
        var triangle = fixture()
        triangle[0].points = [point(0.2, 0.5), point(0.3, 0.4), point(0.4, 0.5)]
        XCTAssertNil(make(triangle))
        var degenerate = fixture()
        degenerate[0].points = [point(0.2, 0.4), point(0.3, 0.4), point(0.4, 0.4), point(0.5, 0.4)]
        XCTAssertNil(make(degenerate))
        var crossing = fixture()
        crossing[0].points = [point(0.2, 0.4), point(0.4, 0.6), point(0.2, 0.6), point(0.4, 0.4)]
        XCTAssertNil(make(crossing), "A zero-signed-area crossing contour cannot supply a trustworthy display envelope.")
    }

    func testFlatClosedOrRepeatedBrowAbstainsRatherThanInventingHeight() {
        var flat = fixture()
        flat[1].points = [point(0.2, 0.35), point(0.3, 0.35), point(0.4, 0.35)]
        XCTAssertNil(make(flat))
        var closed = fixture()
        closed[1].closed = true
        XCTAssertNil(make(closed))
        var repeated = fixture()
        repeated[1].points = [point(0.2, 0.35), point(0.2, 0.35), point(0.4, 0.32)]
        XCTAssertNil(make(repeated))
    }

    func testEdgeExtensionAndDimensionOffsetsClampWithoutChangingTrueBounds() throws {
        let paths = [
            LandmarkPath(id: "leftEye", points: [point(0.96, 0.8), point(1, 0.8), point(1, 0.99), point(0.96, 0.99)], closed: true),
            LandmarkPath(id: "leftEyebrow", points: [point(0.95, 0), point(0.98, 0.02), point(1, 0.01)], closed: false),
        ]
        let transform = ReportPhotoTransform(imageSize: CGSize(width: 100, height: 100), viewport: CGSize(width: 100, height: 100))
        let result = try XCTUnwrap(make(paths, transform: transform))
        assertRect(result.browBounds, CGRect(x: 95, y: 0, width: 5, height: 2))
        assertRect(result.eyeBounds, CGRect(x: 96, y: 80, width: 4, height: 19))
        let top = try segment("brow-top", in: result.referenceSegments)
        XCTAssertEqual(top.end.x, 100)
        let browWidth = try segment("brow-width", in: result.dimensionSegments)
        XCTAssertEqual(browWidth.start.y, 0)
        let eyeWidth = try segment("eye-width", in: result.dimensionSegments)
        XCTAssertEqual(eyeWidth.start.y, 100)
        assertFiniteAndInside(result, viewport: transform.viewport)
    }

    func testOffscreenTrueFeatureBoundsAbstainInsteadOfShorteningDimensions() {
        let transform = ReportPhotoTransform(imageSize: CGSize(width: 1000, height: 600),
            viewport: CGSize(width: 300, height: 300), region: CGRect(x: 0.3, y: 0.2, width: 0.2, height: 0.5))
        XCTAssertNil(make(transform: transform), "The real left edge is outside the focused viewport, so no truncated width is presented.")
    }

    func testInvalidImageViewportAndRegionTransformsAbstain() {
        let validImage = CGSize(width: 1000, height: 600), validViewport = CGSize(width: 500, height: 300)
        for size in [CGSize(width: 0, height: 600), CGSize(width: -1, height: 600),
                     CGSize(width: CGFloat.infinity, height: 600), CGSize(width: 1000, height: CGFloat.nan)] {
            XCTAssertNil(make(transform: ReportPhotoTransform(imageSize: size, viewport: validViewport)))
        }
        for size in [CGSize.zero, CGSize(width: -1, height: 300), CGSize(width: CGFloat.nan, height: 300),
                     CGSize(width: 500, height: CGFloat.infinity)] {
            XCTAssertNil(make(transform: ReportPhotoTransform(imageSize: validImage, viewport: size)))
        }
        for region in [CGRect(x: 0, y: 0, width: 0, height: 1), CGRect(x: -0.01, y: 0, width: 1, height: 1),
                       CGRect(x: 0.2, y: 0, width: 0.9, height: 1), CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)] {
            XCTAssertNil(make(transform: ReportPhotoTransform(imageSize: validImage, viewport: validViewport, region: region)))
        }
    }

    func testSourcePathsRemainUnchangedAndEveryReturnedEndpointIsFiniteAndBounded() throws {
        let paths = fixture()
        let beforeIDs = paths.map(\.id), beforePoints = paths.map(\.points), beforeClosed = paths.map(\.closed)
        for width in [CGFloat(120), 375, 1024] {
            let viewport = CGSize(width: width, height: width * 0.6)
            let transform = ReportPhotoTransform(imageSize: CGSize(width: 1000, height: 600), viewport: viewport)
            let result = try XCTUnwrap(make(paths, transform: transform))
            assertFiniteAndInside(result, viewport: viewport)
            for (prefix, bounds) in [("brow", result.browBounds), ("eye", result.eyeBounds)] {
                let widthLine = try segment(prefix + "-width", in: result.dimensionSegments)
                let heightLine = try segment(prefix + "-height", in: result.dimensionSegments)
                XCTAssertEqual(widthLine.end.x - widthLine.start.x, bounds.width, accuracy: 0.00000001)
                XCTAssertEqual(heightLine.end.y - heightLine.start.y, bounds.height, accuracy: 0.00000001)
            }
        }
        XCTAssertEqual(paths.map(\.id), beforeIDs)
        XCTAssertEqual(paths.map(\.points), beforePoints)
        XCTAssertEqual(paths.map(\.closed), beforeClosed)
    }

    func testChinReferencesUseTrueBoundsAndKeepWidthOnObservedMiddleLine() throws {
        let points = chinFixture()
        let transform = ReportPhotoTransform(imageSize: CGSize(width: 1000, height: 600),
            viewport: CGSize(width: 500, height: 300))
        let result = try XCTUnwrap(ScanFeatureGuideGeometry.chinGuides(points: points, transform: transform))
        assertRect(result.bounds, CGRect(x: 200, y: 225, width: 100, height: 45))
        XCTAssertEqual(result.referenceSegments.count, 4)
        XCTAssertEqual(Set(result.referenceSegments.map(\.id)), Set(["chin-top", "chin-bottom", "chin-left", "chin-right"]))
        XCTAssertEqual(result.dimensionSegments.count, 2)
        let width = try segment("chin-width", in: result.dimensionSegments)
        assertPoint(width.start, transform.position(points[0]))
        assertPoint(width.end, transform.position(points[1]))
        XCTAssertEqual(width.start.y, 247.5, accuracy: 0.00000001)
        let height = try segment("chin-height", in: result.dimensionSegments)
        XCTAssertEqual(height.start.x, 188)
        XCTAssertEqual(height.start.x, height.end.x)
        XCTAssertEqual(height.start.y, 225, accuracy: 0.00000001)
        XCTAssertEqual(height.end.y, 270, accuracy: 0.00000001)
    }

    func testChinRejectsWrongOrderInvalidPointsAndInconsistentProducerEndpoints() {
        let transform = ReportPhotoTransform(imageSize: CGSize(width: 1000, height: 600),
            viewport: CGSize(width: 500, height: 300))
        var badInputs: [[NormalizedPoint]] = [[], Array(chinFixture().prefix(3)), chinFixture() + [point(0.5, 0.8)]]
        var swapped = chinFixture(); swapped.swapAt(0, 1); badInputs.append(swapped)
        var upsideDown = chinFixture(); upsideDown.swapAt(2, 3); badInputs.append(upsideDown)
        var tiltedWidth = chinFixture(); tiltedWidth[1].y += 0.01; badInputs.append(tiltedWidth)
        var tiltedHeight = chinFixture(); tiltedHeight[2].x += 0.01; badInputs.append(tiltedHeight)
        var outsideX = chinFixture(); outsideX[2].x = 0.7; outsideX[3].x = 0.7; badInputs.append(outsideX)
        var outsideY = chinFixture(); outsideY[0].y = 0.7; outsideY[1].y = 0.7; badInputs.append(outsideY)
        for invalid in [point(.nan, 0.8), point(0.5, .infinity), point(1.01, 0.8)] {
            var points = chinFixture(); points[0] = invalid; badInputs.append(points)
        }
        for points in badInputs {
            XCTAssertNil(ScanFeatureGuideGeometry.chinGuides(points: points, transform: transform))
        }
    }

    func testChinOffscreenAndInvalidTransformAbstainRatherThanClipTrueSpan() {
        let focused = ReportPhotoTransform(imageSize: CGSize(width: 1000, height: 600),
            viewport: CGSize(width: 300, height: 300), region: CGRect(x: 0.45, y: 0.2, width: 0.2, height: 0.5))
        XCTAssertNil(ScanFeatureGuideGeometry.chinGuides(points: chinFixture(), transform: focused))
        let invalid = ReportPhotoTransform(imageSize: .zero, viewport: CGSize(width: 300, height: 300))
        XCTAssertNil(ScanFeatureGuideGeometry.chinGuides(points: chinFixture(), transform: invalid))
    }

    func testChinEdgeReferencesStayFiniteBoundedAndLeaveSourceEndpointsUnchanged() throws {
        let points = [point(0, 0.5), point(1, 0.5), point(0.45, 0), point(0.45, 1)]
        let before = points
        let transform = ReportPhotoTransform(imageSize: CGSize(width: 300, height: 600),
            viewport: CGSize(width: 150, height: 300))
        let result = try XCTUnwrap(ScanFeatureGuideGeometry.chinGuides(points: points, transform: transform))
        assertRect(result.bounds, CGRect(origin: .zero, size: transform.viewport))
        XCTAssertEqual(points, before)
        let width = try segment("chin-width", in: result.dimensionSegments)
        assertPoint(width.start, CGPoint(x: 0, y: 150))
        assertPoint(width.end, CGPoint(x: 150, y: 150))
        let height = try segment("chin-height", in: result.dimensionSegments)
        assertPoint(height.start, CGPoint(x: 0, y: 0))
        assertPoint(height.end, CGPoint(x: 0, y: 300))
        for line in result.referenceSegments + result.dimensionSegments {
            for point in [line.start, line.end] {
                XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                XCTAssertTrue((0...150).contains(point.x))
                XCTAssertTrue((0...300).contains(point.y))
            }
        }
    }

    private func make(_ paths: [LandmarkPath]? = nil, transform: ReportPhotoTransform? = nil) -> ScanFeatureGuideGeometry.Guides? {
        ScanFeatureGuideGeometry.guides(landmarks: paths ?? fixture(), transform: transform ?? ReportPhotoTransform(
            imageSize: CGSize(width: 1000, height: 600), viewport: CGSize(width: 500, height: 300)))
    }

    private func fixture() -> [LandmarkPath] {
        [LandmarkPath(id: "leftEye", points: [point(0.2, 0.5), point(0.3, 0.45), point(0.4, 0.5), point(0.3, 0.55)], closed: true),
         LandmarkPath(id: "leftEyebrow", points: [point(0.19, 0.4), point(0.30, 0.34), point(0.41, 0.4)], closed: false)]
    }

    private func chinFixture() -> [NormalizedPoint] {
        [point(0.4, 0.825), point(0.6, 0.825), point(0.49, 0.75), point(0.49, 0.9)]
    }

    private func point(_ x: Double, _ y: Double) -> NormalizedPoint { NormalizedPoint(x: x, y: y) }

    private func segment(_ id: String, in segments: [ScanFeatureGuideGeometry.Segment]) throws -> ScanFeatureGuideGeometry.Segment {
        try XCTUnwrap(segments.first { $0.id == id })
    }

    private func assertFiniteAndInside(_ guides: ScanFeatureGuideGeometry.Guides, viewport: CGSize,
                                       file: StaticString = #filePath, line: UInt = #line) {
        for segment in guides.referenceSegments + guides.dimensionSegments {
            for point in [segment.start, segment.end] {
                XCTAssertTrue(point.x.isFinite && point.y.isFinite, file: file, line: line)
                XCTAssertTrue((0...viewport.width).contains(point.x), file: file, line: line)
                XCTAssertTrue((0...viewport.height).contains(point.y), file: file, line: line)
            }
        }
    }

    private func assertRect(_ actual: CGRect, _ expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.00000001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.00000001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.00000001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.00000001, file: file, line: line)
    }

    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.00000001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.00000001, file: file, line: line)
    }
}
