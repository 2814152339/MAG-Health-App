import Foundation
import CoreGraphics
import XCTest
@testable import Ruyuan

final class ScanMeasurementLabelGeometryTests: XCTestCase {
    func testSafeAnchorStaysExactAndDistantObstaclesDoNotMoveIt() {
        let anchor = CGPoint(x: 70, y: 60)
        let size = CGSize(width: 30, height: 20)
        let viewport = CGRect(x: 0, y: 0, width: 200, height: 150)
        XCTAssertEqual(center(anchor, size, viewport, []), anchor)
        XCTAssertEqual(center(anchor, size, viewport, [CGRect(x: 500, y: 500, width: 40, height: 40)]), anchor)
    }

    func testNearestEqualDistancePlacementPrefersAboveAndKeepsSixPointGap() throws {
        let anchor = CGPoint(x: 50, y: 50), size = CGSize(width: 10, height: 10)
        let obstacle = CGRect(x: 40, y: 40, width: 20, height: 20)
        let result = try XCTUnwrap(center(anchor, size, square, [obstacle]))
        XCTAssertEqual(result, CGPoint(x: 50, y: 29))
        XCTAssertEqual(obstacle.minY - rect(result, size).maxY, 6)
        assertSafe(result, size, square, [obstacle])
    }

    func testHorizontalEscapeChoosesClosestSideAndMirrorsWithSourceGeometry() throws {
        let obstacle = CGRect(x: 40, y: 10, width: 20, height: 80), size = CGSize(width: 10, height: 10)
        let original = try XCTUnwrap(center(CGPoint(x: 48, y: 50), size, square, [obstacle]))
        let mirrored = try XCTUnwrap(center(CGPoint(x: 52, y: 50), size, square, [obstacle]))
        XCTAssertEqual(original, CGPoint(x: 29, y: 50))
        XCTAssertEqual(mirrored, CGPoint(x: 71, y: 50))
        XCTAssertEqual(mirrored.x, 100 - original.x)
        assertSafe(original, size, square, [obstacle])
        assertSafe(mirrored, size, square, [obstacle])
    }

    func testIntersectingBarriersFindNearestCornerInsteadOfFalseNoSpace() throws {
        let obstacles = [CGRect(x: 0, y: 45, width: 100, height: 10), CGRect(x: 45, y: 0, width: 10, height: 100)]
        let size = CGSize(width: 10, height: 10)
        let result = try XCTUnwrap(center(CGPoint(x: 50, y: 50), size, square, obstacles))
        XCTAssertEqual(result, CGPoint(x: 34, y: 34))
        assertSafe(result, size, square, obstacles)
    }

    func testActualEyeGuideWidthLineNoLongerRunsThroughMeasuredAngleText() throws {
        let paths = [
            LandmarkPath(id: "leftEye", points: [p(0.2, 0.5), p(0.3, 0.45), p(0.4, 0.5), p(0.3, 0.55)], closed: true),
            LandmarkPath(id: "leftEyebrow", points: [p(0.19, 0.4), p(0.3, 0.34), p(0.41, 0.4)], closed: false),
        ]
        let transform = ReportPhotoTransform(imageSize: CGSize(width: 1000, height: 600), viewport: CGSize(width: 500, height: 300))
        let guides = try XCTUnwrap(ScanFeatureGuideGeometry.guides(landmarks: paths, transform: transform))
        let widthLine = try XCTUnwrap(guides.dimensionSegments.first { $0.id == "eye-width" })
        let desired = CGPoint(x: guides.eyeBounds.midX, y: widthLine.start.y)
        let obstacles = (guides.referenceSegments + guides.dimensionSegments).map(strokeBounds)
        let size = CGSize(width: 100, height: 24), viewport = CGRect(origin: .zero, size: transform.viewport)
        let result = try XCTUnwrap(center(desired, size, viewport, obstacles))
        XCTAssertGreaterThan(result.y, desired.y, "The nearest free space is below the actual eye-width ruler, not another fixed source-anchor dy.")
        assertSafe(result, size, viewport, obstacles)
        XCTAssertEqual(desired, CGPoint(x: 150, y: 177))
        XCTAssertEqual(widthLine.start.y, 177)
    }

    func testActualChinGuideBottomFrameDoesNotTouchOrCutProportionText() throws {
        let points = [p(0.4, 0.825), p(0.6, 0.825), p(0.49, 0.75), p(0.49, 0.9)]
        let transform = ReportPhotoTransform(imageSize: CGSize(width: 1000, height: 600), viewport: CGSize(width: 500, height: 300))
        let guides = try XCTUnwrap(ScanFeatureGuideGeometry.chinGuides(points: points, transform: transform))
        let desired = CGPoint(x: guides.bounds.midX, y: guides.bounds.maxY - 2)
        let obstacles = (guides.referenceSegments + guides.dimensionSegments).map(strokeBounds)
        let size = CGSize(width: 120, height: 28), viewport = CGRect(origin: .zero, size: transform.viewport)
        let result = try XCTUnwrap(center(desired, size, viewport, obstacles))
        XCTAssertLessThan(rect(result, size).maxY, guides.bounds.minY,
                          "The actual measured label needs to clear the crowded chin frame, not remain glued to its bottom edge.")
        assertSafe(result, size, viewport, obstacles)
        XCTAssertEqual(points, [p(0.4, 0.825), p(0.6, 0.825), p(0.49, 0.75), p(0.49, 0.9)])
    }

    func testViewportOriginAndMeasuredSizeClampAllFourEdgesWithoutChangingAnchor() throws {
        let viewport = CGRect(x: 20, y: 30, width: 100, height: 80), size = CGSize(width: 30, height: 20)
        let desired = CGPoint(x: -100, y: -50)
        XCTAssertEqual(center(desired, size, viewport, []), CGPoint(x: 35, y: 40))
        let bottomRight = try XCTUnwrap(center(CGPoint(x: 900, y: 800), size, viewport, []))
        XCTAssertEqual(bottomRight, CGPoint(x: 105, y: 100))
        assertSafe(bottomRight, size, viewport, [])
        XCTAssertEqual(desired, CGPoint(x: -100, y: -50))
    }

    func testExactlyFittingLabelIsAllowedButOversizedMeasuredLabelAbstains() {
        let viewport = CGRect(x: 20, y: 30, width: 100, height: 80)
        XCTAssertEqual(center(.zero, viewport.size, viewport, []), CGPoint(x: 70, y: 70))
        XCTAssertNil(center(.zero, CGSize(width: 100.1, height: 80), viewport, []))
        XCTAssertNil(center(.zero, CGSize(width: 100, height: 80.1), viewport, []))
    }

    func testZeroThicknessRulerStillReservesSixPointClearance() throws {
        let ruler = CGRect(x: 0, y: 50, width: 100, height: 0), size = CGSize(width: 10, height: 10)
        let result = try XCTUnwrap(center(CGPoint(x: 50, y: 50), size, square, [ruler]))
        XCTAssertEqual(result, CGPoint(x: 50, y: 39))
        XCTAssertEqual(ruler.minY - rect(result, size).maxY, 6)
        assertSafe(result, size, square, [ruler])
    }

    func testInvalidAnchorSizeViewportOrAnyObstacleAbstainsRatherThanDroppingEvidence() {
        let valid = CGPoint(x: 50, y: 50), size = CGSize(width: 10, height: 10)
        for anchor in [CGPoint(x: CGFloat.nan, y: 50), CGPoint(x: 50, y: CGFloat.infinity)] {
            XCTAssertNil(center(anchor, size, square, []))
        }
        for invalid in [CGSize.zero, CGSize(width: -1, height: 20), CGSize(width: 10, height: 0),
                        CGSize(width: CGFloat.infinity, height: 10), CGSize(width: 10, height: CGFloat.nan)] {
            XCTAssertNil(center(valid, invalid, square, []))
        }
        for invalid in [CGRect.zero, CGRect(x: 0, y: 0, width: -100, height: 100),
                        CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)] {
            XCTAssertNil(center(valid, size, invalid, []))
        }
        for invalid in [CGRect.null, CGRect(x: 20, y: 20, width: -1, height: 10),
                        CGRect(x: 20, y: CGFloat.nan, width: 10, height: 10)] {
            XCTAssertNil(center(valid, size, square, [CGRect(x: 500, y: 500, width: 1, height: 1), invalid]))
        }
    }

    func testNoSafeSpaceReturnsNilInsteadOfOverlappingOrInventingSmallerText() {
        XCTAssertNil(center(CGPoint(x: 50, y: 50), CGSize(width: 20, height: 20), square, [square]))
        let fourCorners = [CGRect(x: 0, y: 0, width: 49, height: 49), CGRect(x: 51, y: 0, width: 49, height: 49),
                           CGRect(x: 0, y: 51, width: 49, height: 49), CGRect(x: 51, y: 51, width: 49, height: 49)]
        XCTAssertNil(center(CGPoint(x: 50, y: 50), CGSize(width: 10, height: 10), square, fourCorners))
    }

    func testObstacleOrderDuplicatesAndRepeatedCallsKeepDeterministicImmutableResults() throws {
        let desired = CGPoint(x: 50, y: 50), size = CGSize(width: 10, height: 10)
        let obstacles = [CGRect(x: 40, y: 40, width: 20, height: 20), CGRect(x: 0, y: 0, width: 20, height: 20)]
        let before = obstacles
        let result = try XCTUnwrap(center(desired, size, square, obstacles))
        XCTAssertEqual(center(desired, size, square, Array(obstacles.reversed())), result)
        XCTAssertEqual(center(desired, size, square, obstacles + obstacles), result)
        XCTAssertEqual(center(desired, size, square, obstacles), result)
        XCTAssertEqual(obstacles, before)
        XCTAssertEqual(desired, CGPoint(x: 50, y: 50))
        XCTAssertEqual(size, CGSize(width: 10, height: 10))
        assertSafe(result, size, square, obstacles)
    }

    private var square: CGRect { CGRect(x: 0, y: 0, width: 100, height: 100) }

    private func center(_ anchor: CGPoint, _ size: CGSize, _ viewport: CGRect, _ obstacles: [CGRect]) -> CGPoint? {
        ScanMeasurementLabelGeometry.safeCenter(desiredAnchor: anchor, labelSize: size, viewport: viewport, obstacles: obstacles)
    }

    private func rect(_ center: CGPoint, _ size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private func p(_ x: Double, _ y: Double) -> NormalizedPoint { NormalizedPoint(x: x, y: y) }

    private func strokeBounds(_ segment: ScanFeatureGuideGeometry.Segment) -> CGRect {
        CGRect(x: min(segment.start.x, segment.end.x) - 0.5, y: min(segment.start.y, segment.end.y) - 0.5,
               width: abs(segment.end.x - segment.start.x) + 1, height: abs(segment.end.y - segment.start.y) + 1)
    }

    private func assertSafe(_ result: CGPoint, _ size: CGSize, _ viewport: CGRect, _ obstacles: [CGRect],
                            file: StaticString = #filePath, line: UInt = #line) {
        let label = rect(result, size)
        XCTAssertTrue(result.x.isFinite && result.y.isFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(label.minX, viewport.minX - 0.00000001, file: file, line: line)
        XCTAssertLessThanOrEqual(label.maxX, viewport.maxX + 0.00000001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(label.minY, viewport.minY - 0.00000001, file: file, line: line)
        XCTAssertLessThanOrEqual(label.maxY, viewport.maxY + 0.00000001, file: file, line: line)
        for obstacle in obstacles {
            let separated = label.maxX <= obstacle.minX - 6 + 0.00000001
                || label.minX >= obstacle.maxX + 6 - 0.00000001
                || label.maxY <= obstacle.minY - 6 + 0.00000001
                || label.minY >= obstacle.maxY + 6 - 0.00000001
            XCTAssertTrue(separated, "The complete measured label must retain at least 6pt clearance.", file: file, line: line)
        }
    }
}
