import CoreGraphics
import XCTest
@testable import Ruyuan

/// Hand-authored normalized geometry only; not a model or private-photo fixture.
final class OverlayViewerGeometryTests: XCTestCase {
    private let size = CGSize(width: 600, height: 800)
    private var landmarks: [LandmarkPath] {
        func p(_ x: Double, _ y: Double) -> Ruyuan.NormalizedPoint { .init(x: x, y: y) }
        return [
            .init(id: "faceContour", points: [p(0.25,0.30),p(0.20,0.42),p(0.26,0.65),p(0.40,0.78),
                p(0.50,0.82),p(0.65,0.76),p(0.77,0.60),p(0.80,0.40),p(0.75,0.30)], closed: false),
            .init(id: "leftEye", points: [p(0.30,0.40),p(0.42,0.40),p(0.42,0.46),p(0.30,0.46)], closed: true),
            .init(id: "rightEye", points: [p(0.58,0.40),p(0.70,0.40),p(0.70,0.46),p(0.58,0.46)], closed: true),
            .init(id: "leftEyebrow", points: [p(0.29,0.35),p(0.36,0.32),p(0.44,0.35)], closed: false),
            .init(id: "rightEyebrow", points: [p(0.56,0.35),p(0.64,0.32),p(0.71,0.35)], closed: false)
        ]
    }
    private func layer(_ paths: [[Ruyuan.NormalizedPoint]] = []) -> OverlayLayer {
        .init(id: "synthetic-layer", title: "Geometry test only", colorHex: "FFFFFF", kind: .lines,
              paths: paths, note: "Synthetic geometry, NOT detection evidence", source: "unit-test")
    }
    private func region(_ paths: [LandmarkPath]? = nil, selected: OverlayLayer? = nil,
                        imageSize: CGSize? = nil) -> CGRect? {
        OverlayViewerGeometry.initialFaceRegion(landmarks: paths ?? landmarks,
            selectedLayer: selected ?? layer(), imageSize: imageSize ?? size)
    }
    private func assertContains(_ rect: CGRect, _ points: [Ruyuan.NormalizedPoint],
                                file: StaticString = #filePath, line: UInt = #line) {
        for point in points {
            XCTAssertLessThanOrEqual(Double(rect.minX) - 1e-12, point.x, file: file, line: line)
            XCTAssertGreaterThanOrEqual(Double(rect.maxX) + 1e-12, point.x, file: file, line: line)
            XCTAssertLessThanOrEqual(Double(rect.minY) - 1e-12, point.y, file: file, line: line)
            XCTAssertGreaterThanOrEqual(Double(rect.maxY) + 1e-12, point.y, file: file, line: line)
        }
    }
    private func assertOffset(_ actual: CGSize, _ x: CGFloat, _ y: CGFloat,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.height, y, accuracy: 1e-9, file: file, line: line)
    }

    func testValidCanonicalGeometryCreatesAdaptiveDisplayMarginOnly() throws {
        let crop = try XCTUnwrap(region())
        XCTAssertEqual(crop.minX, 0.152, accuracy: 1e-9)
        XCTAssertEqual(crop.minY, 0.17, accuracy: 1e-9)
        XCTAssertEqual(crop.width, 0.696, accuracy: 1e-9)
        XCTAssertEqual(crop.height, 0.702, accuracy: 1e-9)
        assertContains(crop, landmarks.flatMap { $0.points })
        let translated = landmarks.map { path -> LandmarkPath in
            var next = path
            next.points = path.points.map { .init(x: 0.1 + $0.x * 0.6, y: 0.15 + $0.y * 0.6) }
            return next
        }
        let moved = try XCTUnwrap(region(translated))
        XCTAssertEqual(moved.minX, 0.1 + crop.minX * 0.6, accuracy: 1e-9)
        XCTAssertEqual(moved.width, crop.width * 0.6, accuracy: 1e-9)
        XCTAssertEqual(moved.minY, 0.15 + crop.minY * 0.6, accuracy: 1e-9)
    }

    func testOriginalEntryAndMissingEvidenceKeepCompleteImage() {
        XCTAssertNil(OverlayViewerGeometry.initialFaceRegion(landmarks: landmarks,
            selectedLayer: nil, imageSize: size))
        XCTAssertNil(region([]))
    }

    func testEveryRequiredCanonicalPathMustExist() {
        for id in ["faceContour", "leftEye", "rightEye", "leftEyebrow", "rightEyebrow"] {
            XCTAssertNil(region(landmarks.filter { $0.id != id }), id)
        }
    }

    func testDuplicateCanonicalIdentityAbstainsEvenWhenOneCopyLooksValid() {
        for path in landmarks { XCTAssertNil(region(landmarks + [path]), path.id) }
    }

    func testNonfiniteAndOutOfRangeCanonicalCoordinatesAbstain() {
        for bad in [Double.nan, .infinity, -.infinity, -0.001, 1.001] {
            var paths = landmarks
            paths[0].points[0].x = bad
            XCTAssertNil(region(paths))
        }
        var paths = landmarks
        paths[2].points[0].y = .nan
        XCTAssertNil(region(paths))
    }

    func testRepeatedInteriorCoordinatesAbstainButExplicitEyeClosureIsEquivalent() {
        var repeated = landmarks
        repeated[3].points.append(repeated[3].points[0])
        XCTAssertNil(region(repeated))
        var closed = landmarks
        closed[1].points.append(closed[1].points[0])
        XCTAssertEqual(region(closed), region())
        closed[1].points.append(closed[1].points[1])
        XCTAssertNil(region(closed))
    }

    func testCollinearContourOrEyeAndCollapsedBrowAbstain() {
        var paths = landmarks
        paths[0].points = (0..<9).map { .init(x: 0.1 + Double($0) * 0.08, y: 0.1 + Double($0) * 0.08) }
        XCTAssertNil(region(paths))
        paths = landmarks
        paths[1].points = (0..<4).map { .init(x: 0.30 + Double($0) * 0.03, y: 0.40) }
        XCTAssertNil(region(paths))
        paths = landmarks
        paths[3].points = Array(repeating: .init(x: 0.3, y: 0.3), count: 3)
        XCTAssertNil(region(paths))
    }

    func testOverlappingEyesOrIdenticalBrowsAbstain() {
        var paths = landmarks
        paths[2].points = paths[1].points
        XCTAssertNil(region(paths))
        paths = landmarks
        paths[4].points = paths[3].points
        XCTAssertNil(region(paths))
    }

    func testOpenJawAndBrowsAndClosedEyesContractIsRequired() {
        for index in landmarks.indices {
            var paths = landmarks
            paths[index].closed.toggle()
            XCTAssertNil(region(paths))
        }
    }

    func testEverySelectedPathPointIsRetainedIncludingFarOutsideFace() throws {
        let points: [Ruyuan.NormalizedPoint] = [.init(x: 0.01, y: 0.92), .init(x: 0.98, y: 0.95)]
        let selected = layer([points])
        let crop = try XCTUnwrap(region(selected: selected))
        assertContains(crop, points + landmarks.flatMap { $0.points })
        XCTAssertGreaterThanOrEqual(crop.minX, 0)
        XCTAssertLessThanOrEqual(crop.maxX, 1)
        XCTAssertEqual(selected.paths, [points], "Display framing cannot mutate actual model paths.")
    }

    func testImageSpanningLayerReturnsFullImageInsteadOfCroppingAnnotations() {
        let corners: [Ruyuan.NormalizedPoint] = [.init(x: 0, y: 0), .init(x: 1, y: 0),
                                                .init(x: 1, y: 1), .init(x: 0, y: 1)]
        XCTAssertNil(region(selected: layer([corners])))
    }

    func testEmptyCandidatePathsAreAllowedAndMalformedPathAbstains() {
        XCTAssertEqual(region(selected: layer([[]])), region())
        for point in [Ruyuan.NormalizedPoint(x: .nan, y: 0.5), .init(x: 0.5, y: 1.01)] {
            XCTAssertNil(region(selected: layer([[.init(x: 0.5, y: 0.5), point]])))
        }
    }

    func testInvalidImageSizesAbstainAndIsotropicResizingDoesNotInventNewFraming() {
        for invalid in [CGSize.zero, CGSize(width: -1, height: 800), CGSize(width: CGFloat.nan, height: 800),
                        CGSize(width: 600, height: CGFloat.infinity), CGSize(width: 16385, height: 800)] {
            XCTAssertNil(region(imageSize: invalid))
        }
        XCTAssertEqual(region(imageSize: CGSize(width: 1200, height: 1600)), region())
        XCTAssertEqual(region(imageSize: CGSize(width: 600, height: 600)), region())
    }

    func testExactCanonicalNamesNotAliasesAndEdgeCoordinatesStayInImage() throws {
        let unrelated = LandmarkPath(id: "mp-faceOval", points: [.init(x: .nan, y: 0)], closed: true)
        XCTAssertEqual(region(landmarks + [unrelated]), region())
        var aliases = landmarks
        aliases[0].id = "legacy-faceContour"
        XCTAssertNil(region(aliases))
        let edge = landmarks.map { path -> LandmarkPath in
            var value = path
            value.points = path.points.map {
                .init(x: min(1, max(0, ($0.x - 0.20) / 0.60 * 0.30)),
                      y: min(1, max(0, ($0.y - 0.30) / 0.52 * 0.40)))
            }
            return value
        }
        let crop = try XCTUnwrap(region(edge))
        XCTAssertEqual(crop.minX, 0, accuracy: 1e-12)
        XCTAssertEqual(crop.minY, 0, accuracy: 1e-12)
        assertContains(crop, edge.flatMap { $0.points })
    }

    func testOffCenterROIPanUsesActualImageOriginAtOneAndSixTimes() {
        let view = CGSize(width: 400, height: 400)
        let image = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        assertOffset(OverlayViewerGeometry.boundedOffset(.init(width: 300, height: -700), scale: 1,
            imageBounds: image, viewport: view), 0, -600)
        assertOffset(OverlayViewerGeometry.boundedOffset(.init(width: 2000, height: -8000), scale: 6,
            imageBounds: image, viewport: view), 1000, -4600)
        assertOffset(OverlayViewerGeometry.boundedOffset(.init(width: -100, height: 1000), scale: 1,
            imageBounds: CGRect(x: -600, y: -600, width: 1000, height: 1000), viewport: view), 0, 600)
    }

    func testCenteredImageRetainsSymmetricLimitsAndSmallAxisCannotBeDragged() {
        let view = CGSize(width: 400, height: 400)
        assertOffset(OverlayViewerGeometry.boundedOffset(.init(width: 500, height: -500), scale: 1,
            imageBounds: CGRect(x: -300, y: -300, width: 1000, height: 1000), viewport: view), 300, -300)
        assertOffset(OverlayViewerGeometry.boundedOffset(.init(width: 99, height: 99), scale: 1,
            imageBounds: CGRect(x: 50, y: -100, width: 100, height: 600), viewport: view), 0, 99)
    }

    func testInvalidPanInputReturnsZeroRatherThanNonfiniteOffsets() {
        let image = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let view = CGSize(width: 400, height: 400)
        for badScale in [CGFloat.nan, .infinity, 0, 7] {
            XCTAssertEqual(OverlayViewerGeometry.boundedOffset(.init(width: 1, height: 2), scale: badScale,
                imageBounds: image, viewport: view), .zero)
        }
        XCTAssertEqual(OverlayViewerGeometry.boundedOffset(.init(width: CGFloat.nan, height: 2), scale: 1,
            imageBounds: image, viewport: view), .zero)
        XCTAssertEqual(OverlayViewerGeometry.boundedOffset(.zero, scale: 1, imageBounds: .null, viewport: view), .zero)
        XCTAssertEqual(OverlayViewerGeometry.boundedOffset(.zero, scale: 1, imageBounds: image, viewport: .zero), .zero)
        XCTAssertEqual(OverlayViewerGeometry.boundedOffset(.zero, scale: 1, imageBounds: image,
            viewport: CGSize(width: CGFloat.infinity, height: 400)), .zero)
    }

    func testPositiveImageOriginClampsZeroAndReclampsExistingPanAfterButtonZoom() {
        let image = CGRect(x: 150, y: 0, width: 500, height: 500)
        let viewport = CGSize(width: 400, height: 400)
        let reset = OverlayViewerGeometry.boundedOffset(.zero, scale: 1, imageBounds: image, viewport: viewport)
        assertOffset(reset, -150, 0)
        assertOffset(OverlayViewerGeometry.boundedOffset(.zero, scale: 1.5,
            imageBounds: image, viewport: viewport), -125, 0)
        let zoomed = OverlayViewerGeometry.boundedOffset(.init(width: -400, height: -200), scale: 1.5,
            imageBounds: image, viewport: viewport)
        assertOffset(zoomed, -400, -200)
        let zoomedOut = OverlayViewerGeometry.boundedOffset(zoomed, scale: 1,
            imageBounds: image, viewport: viewport)
        assertOffset(zoomedOut, -250, -100)
        let before = OverlayViewerGeometry.PanInput(imageBounds: image, viewport: viewport, scale: 1)
        let after = OverlayViewerGeometry.PanInput(imageBounds: image, viewport: viewport, scale: 1.5)
        XCTAssertNotEqual(before, after, "The production onChange input must observe zoom, not only viewport size.")
    }

    func testViewportResizeReclampsAnOffsetUsingTheNewImageRectangle() {
        let old = OverlayViewerGeometry.boundedOffset(.init(width: -500, height: -500), scale: 1,
            imageBounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), viewport: CGSize(width: 400, height: 400))
        assertOffset(old, -500, -500)
        let resized = OverlayViewerGeometry.boundedOffset(old, scale: 1,
            imageBounds: CGRect(x: 0, y: 0, width: 500, height: 500), viewport: CGSize(width: 200, height: 200))
        assertOffset(resized, -300, -300)
        let wider = OverlayViewerGeometry.boundedOffset(resized, scale: 1,
            imageBounds: CGRect(x: 0, y: 0, width: 1500, height: 1500), viewport: CGSize(width: 600, height: 600))
        assertOffset(wider, -300, -300)
    }
}
