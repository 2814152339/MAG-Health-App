import Foundation
import CoreGraphics
import XCTest
@testable import Ruyuan

final class ScanFocusPresentationTests: XCTestCase {
    func testImageLeftmostEyeBindsOnlyItsSameSideBrowAndPreservesExistingROI() throws {
        let paths = fixture()
        let focus = try XCTUnwrap(ScanFocusPresentation.eyeFocus(landmarks: paths))
        XCTAssertEqual(focus.eyeID, "leftEye")
        XCTAssertEqual(focus.browID, "leftEyebrow")
        XCTAssertEqual(focus.landmarkIDs, ["leftEye", "leftEyebrow"])
        let observed = paths.filter { focus.landmarkIDs.contains($0.id) }.flatMap(\.points)
        let original = try XCTUnwrap(ReportPhotoTransform.region(points: observed,
            padding: CGSize(width: 0.13, height: 0.19), minimum: CGSize(width: 0.56, height: 0.66)))
        XCTAssertEqual(focus.region, original, "The selected view must preserve the established camera framing.")
    }

    func testInputOrderAndUnrelatedPathsCannotChangeSelection() {
        let paths = fixture()
        let expected = ScanFocusPresentation.eyeFocus(landmarks: paths)
        let unrelated = LandmarkPath(id: "nose", points: [point(.nan, .infinity)], closed: false)
        XCTAssertNotNil(expected)
        XCTAssertEqual(expected, ScanFocusPresentation.eyeFocus(landmarks: Array(paths.reversed())))
        XCTAssertEqual(expected, ScanFocusPresentation.eyeFocus(landmarks: [unrelated] + paths))
    }

    func testMirroringChoosesActualImageLeftEyeAndMatchingBrowNotAnatomicalName() throws {
        let paths = fixture()
        let mirrored = paths.map { path -> LandmarkPath in
            var copy = path
            copy.points = path.points.map { point(1 - $0.x, $0.y) }
            return copy
        }
        let focus = try XCTUnwrap(ScanFocusPresentation.eyeFocus(landmarks: mirrored))
        XCTAssertEqual(focus.eyeID, "rightEye")
        XCTAssertEqual(focus.browID, "rightEyebrow")
        let sourceRight = paths.filter { ["rightEye", "rightEyebrow"].contains($0.id) }.flatMap(\.points)
        let originalRight = try XCTUnwrap(ReportPhotoTransform.region(points: sourceRight,
            padding: CGSize(width: 0.13, height: 0.19), minimum: CGSize(width: 0.56, height: 0.66)))
        XCTAssertEqual(focus.region.minX, 1 - originalRight.maxX, accuracy: 0.000000001)
        XCTAssertEqual(focus.region.minY, originalRight.minY, accuracy: 0.000000001)
        XCTAssertEqual(focus.region.width, originalRight.width, accuracy: 0.000000001)
        XCTAssertEqual(focus.region.height, originalRight.height, accuracy: 0.000000001)
    }

    func testSwappingBothSideNamesRetainsSpatialROIAndConsistentBrowPair() throws {
        let original = try XCTUnwrap(ScanFocusPresentation.eyeFocus(landmarks: fixture()))
        let swaps = ["leftEye": "rightEye", "rightEye": "leftEye",
                     "leftEyebrow": "rightEyebrow", "rightEyebrow": "leftEyebrow"]
        let swapped = fixture().map { path -> LandmarkPath in
            var copy = path
            copy.id = swaps[path.id] ?? path.id
            return copy
        }
        let focus = try XCTUnwrap(ScanFocusPresentation.eyeFocus(landmarks: swapped))
        XCTAssertEqual(focus.eyeID, "rightEye")
        XCTAssertEqual(focus.browID, "rightEyebrow")
        XCTAssertEqual(focus.region, original.region)
    }

    func testMissingOrDuplicatedRequiredSideNeverFallsBackToAnotherSide() {
        let paths = fixture()
        for missing in ["leftEye", "rightEye", "leftEyebrow"] {
            XCTAssertNil(ScanFocusPresentation.eyeFocus(landmarks: paths.filter { $0.id != missing }))
        }
        for duplicate in ["leftEye", "rightEye", "leftEyebrow"] {
            let repeated = paths.first { $0.id == duplicate }!
            XCTAssertNil(ScanFocusPresentation.eyeFocus(landmarks: paths + [repeated]))
        }
        let noUnselectedBrow = paths.filter { $0.id != "rightEyebrow" }
        XCTAssertEqual(ScanFocusPresentation.eyeFocus(landmarks: paths),
                       ScanFocusPresentation.eyeFocus(landmarks: noUnselectedBrow))
        XCTAssertNil(ScanFocusPresentation.eyeFocus(landmarks: []))
    }

    func testMalformedParticipatingCoordinatesAreRejectedRatherThanFiltered() {
        for id in ["leftEye", "rightEye", "leftEyebrow"] {
            for bad in [Double.nan, .infinity, -.infinity, -0.001, 1.001] {
                for axis in ["x", "y"] {
                    var paths = fixture()
                    let index = paths.firstIndex { $0.id == id }!
                    if axis == "x" { paths[index].points[0].x = bad }
                    else { paths[index].points[0].y = bad }
                    XCTAssertNil(ScanFocusPresentation.eyeFocus(landmarks: paths), "Bad \(axis) coordinate in \(id).")
                }
            }
        }
        for replacement in [[], [point(0.2, 0.3)], [point(0.2, 0.3), point(0.2, 0.3)]] {
            var paths = fixture()
            paths[2].points = replacement
            XCTAssertNil(ScanFocusPresentation.eyeFocus(landmarks: paths))
        }
    }

    func testDegenerateUnclosedOrMinXTiedEyesDoNotChooseByInputOrder() {
        var unclosed = fixture()
        unclosed[0].closed = false
        XCTAssertNil(ScanFocusPresentation.eyeFocus(landmarks: unclosed))
        var line = fixture()
        line[0].points = [point(0.1, 0.4), point(0.2, 0.4), point(0.3, 0.4)]
        XCTAssertNil(ScanFocusPresentation.eyeFocus(landmarks: line))
        var tied = fixture()
        tied[1].points = tied[0].points.map { point($0.x, $0.y + 0.2) }
        XCTAssertNil(ScanFocusPresentation.eyeFocus(landmarks: tied))
        XCTAssertNil(ScanFocusPresentation.eyeFocus(landmarks: Array(tied.reversed())))
    }

    func testClampedEdgeRegionsAreFiniteWithinImageAndDoNotMutateEvidence() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for shift in [-0.16, 0.15] {
            var paths = fixture()
            paths = paths.map { path -> LandmarkPath in
                var copy = path
                copy.points = path.points.map { point($0.x + shift, $0.y + shift) }
                return copy
            }
            let before = try encoder.encode(paths)
            let focus = try XCTUnwrap(ScanFocusPresentation.eyeFocus(landmarks: paths))
            XCTAssertTrue(focus.region.minX.isFinite && focus.region.minY.isFinite)
            XCTAssertTrue(focus.region.width.isFinite && focus.region.height.isFinite)
            XCTAssertGreaterThanOrEqual(focus.region.minX, 0)
            XCTAssertGreaterThanOrEqual(focus.region.minY, 0)
            XCTAssertLessThanOrEqual(focus.region.maxX, 1)
            XCTAssertLessThanOrEqual(focus.region.maxY, 1)
            XCTAssertGreaterThanOrEqual(focus.region.width, 0.56)
            XCTAssertGreaterThanOrEqual(focus.region.height, 0.66)
            XCTAssertEqual(try encoder.encode(paths), before)
        }
        let bottomRight = fixture().map { path -> LandmarkPath in
            var copy = path
            copy.points = path.points.map { point($0.x * 0.35 + 0.65, $0.y * 0.35 + 0.65) }
            return copy
        }
        let focus = try XCTUnwrap(ScanFocusPresentation.eyeFocus(landmarks: bottomRight))
        XCTAssertEqual(focus.region.maxX, 1, accuracy: 0.000000001)
        XCTAssertEqual(focus.region.maxY, 1, accuracy: 0.000000001)
    }

    func testGeometryLayerSelectionUsesOnlyFourExactIDsWithoutSubstringPollution() throws {
        let focus = try XCTUnwrap(ScanFocusPresentation.eyeFocus(landmarks: fixture()))
        for id in ["geometry-brow-leftEyebrow", "geometry-brow-leftEyebrow-points",
                   "geometry-eye-leftEye", "geometry-eye-leftEye-points"] {
            XCTAssertTrue(focus.allowsGeometryLayer(id: id), id)
        }
        for id in ["geometry-brow-rightEyebrow", "geometry-brow-rightEyebrow-points",
                   "geometry-eye-rightEye", "geometry-eye-rightEye-points",
                   "geometry-eye-leftEye-extra", "geometry-eye-leftEye-points-extra",
                   "xgeometry-eye-leftEye", "Geometry-eye-leftEye", "geometry-eye-leftEyebrow",
                   "geometry-jaw-left", "appearance-under-eye", "leftEye", ""] {
            XCTAssertFalse(focus.allowsGeometryLayer(id: id), id)
        }
    }

    private func point(_ x: Double, _ y: Double) -> Ruyuan.NormalizedPoint { .init(x: x, y: y) }

    private func fixture() -> [LandmarkPath] {
        [
            LandmarkPath(id: "leftEye", points: [point(0.18, 0.40), point(0.25, 0.37),
                point(0.32, 0.40), point(0.25, 0.43)], closed: true),
            LandmarkPath(id: "rightEye", points: [point(0.64, 0.40), point(0.71, 0.37),
                point(0.78, 0.40), point(0.71, 0.43)], closed: true),
            LandmarkPath(id: "leftEyebrow", points: [point(0.16, 0.32), point(0.25, 0.29),
                point(0.34, 0.32)], closed: false),
            LandmarkPath(id: "rightEyebrow", points: [point(0.62, 0.32), point(0.71, 0.29),
                point(0.80, 0.32)], closed: false)
        ]
    }
}
