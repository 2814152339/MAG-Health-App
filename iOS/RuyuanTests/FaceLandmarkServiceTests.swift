import CoreGraphics
import XCTest
@testable import Ruyuan

final class FaceLandmarkServiceTests: XCTestCase {
    private func fixture() -> [NormalizedPoint] {
        (0..<478).map { i in .init(x: 0.1 + Double(i % 23) / 30, y: 0.1 + Double(i / 23) / 30) }
    }

    /// Actual graph invocation: missing resources, model initialization and inference errors fail
    /// CI. An empty frame must not obtain synthetic landmarks from the output adapter.
    func testBundledOfficialModelReallyRunsAndRejectsBlankFrame() throws {
        let url = try XCTUnwrap(FaceLandmarkService.modelURL(), "The production bundle must contain the exact real model .bin")
        let width = 240, height = 160
        var pixels = [UInt8](repeating: 127, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        XCTAssertThrowsError(try FaceLandmarkService.detect(image: image, modelURL: url)) { error in
            XCTAssertEqual(error as? FaceLandmarkService.Failure, .noFace, "Only an actual no-face result is acceptable, not a broken graph or missing weight")
        }
    }

    func testOfficialTopologyProducesIndependentBounded478PointLayers() throws {
        let points = fixture(), z = (0..<478).map { Double($0 - 239) / 1_000 }
        let result = try FaceLandmarkService.makeResult(points: points, relativeZ: z)
        XCTAssertEqual(result.points, points)
        XCTAssertEqual(result.relativeZ, z)
        XCTAssertEqual(result.landmarks.first { $0.id == "mp-faceMesh478" }?.points, points)
        XCTAssertTrue(result.landmarks.allSatisfy { $0.id.hasPrefix("mp-") })
        XCTAssertTrue(result.overlays.allSatisfy { $0.id.hasPrefix("geometry-mp-") })
        XCTAssertEqual(result.landmarks.first { $0.id == "mp-faceOval" }?.points.count, 36)
        XCTAssertEqual(result.landmarks.first { $0.id == "mp-leftEye" }?.points.count, 16)
        XCTAssertEqual(result.landmarks.first { $0.id == "mp-rightEye" }?.points.count, 16)
        XCTAssertEqual(result.landmarks.filter { $0.id.hasPrefix("mp-leftEyebrow") }.count, 2)
        XCTAssertEqual(result.landmarks.filter { $0.id.hasPrefix("mp-rightEyebrow") }.count, 2)
        XCTAssertEqual(result.landmarks.first { $0.id == "mp-outerLips" }?.points.count, 20)
        XCTAssertEqual(result.landmarks.first { $0.id == "mp-innerLips" }?.points.count, 20)
        let paths = result.landmarks.map(\.points) + result.overlays.flatMap(\.paths)
        XCTAssertLessThanOrEqual(result.overlays.count, 3)
        XCTAssertLessThanOrEqual(paths.count, 500)
        XCTAssertLessThanOrEqual(paths.reduce(0) { $0 + $1.count }, 5_000)
        XCTAssertEqual(result.overlays.first { $0.kind == .points }?.paths.count, 1)
        XCTAssertTrue(result.overlays.allSatisfy { $0.note.contains("不是实测深度") })
    }

    func testRGBAInputAdapterPreservesTopLeftPhotoRowAndRedBlueChannels() throws {
        let width = 40, height = 80
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = y < height / 2 ? 230 : 20
            pixels[i + 1] = 30
            pixels[i + 2] = y < height / 2 ? 20 : 230
            pixels[i + 3] = 255
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let raster = try XCTUnwrap(LocalAnalyzer.makeRaster(image))
        XCTAssertEqual(raster.width, width)
        XCTAssertEqual(raster.height, height)
        let top = (5 * width + 5) * 4, bottom = (75 * width + 5) * 4
        XCTAssertGreaterThan(raster.pixels[top], raster.pixels[top + 2], "The full-image top must not be vertically flipped or red/blue swapped")
        XCTAssertGreaterThan(raster.pixels[bottom + 2], raster.pixels[bottom])
    }

    func testDenseOutputFitsNearFullExistingReportBudget() throws {
        let result = try FaceLandmarkService.makeResult(points: fixture(), relativeZ: .init(repeating: 0, count: 478))
        let existing = OverlayLayer(id: "existing", title: "Synthetic budget fixture", colorHex: "FFFFFF", kind: .lines,
            paths: .init(repeating: [.init(x: 0.1, y: 0.2), .init(x: 0.8, y: 0.9)], count: 9_000), note: "test", source: "test")
        let skin = SkinDimension.allCases.map { SkinMetric(dimension: $0, score: nil, status: "test", items: []) }
        let report = AnalysisReport(id: "dense-full-budget", createdAt: Date(), origin: .local, status: "test",
            imageFileName: "synthetic.jpg", imageWidth: 640, imageHeight: 960, geometry: [], skin: skin,
            landmarks: result.landmarks, overlays: [existing] + result.overlays, quality: [], modelVersion: result.source, summary: "test")
        XCTAssertNoThrow(try ReportValidator.validate(report))
        XCTAssertLessThanOrEqual(report.landmarks.count + report.overlays.flatMap(\.paths).count, 10_000)
    }

    func testInvalidOrIncompleteOutputIsRejectedWithoutClampingOrInventingPoints() throws {
        let points = fixture(), z = [Double](repeating: 0, count: 478)
        XCTAssertThrowsError(try FaceLandmarkService.makeResult(points: Array(points.dropLast()), relativeZ: z))
        XCTAssertThrowsError(try FaceLandmarkService.makeResult(points: points, relativeZ: Array(z.dropLast())))
        for value in [Double.nan, .infinity, -0.0001, 1.0001] {
            var invalid = points; invalid[45].x = value
            XCTAssertThrowsError(try FaceLandmarkService.makeResult(points: invalid, relativeZ: z))
        }
        var invalidZ = z; invalidZ[0] = .nan
        XCTAssertThrowsError(try FaceLandmarkService.makeResult(points: points, relativeZ: invalidZ))
    }

    func testTopologyUsesRealEdgesRegardlessOfDirectionAndOrder() throws {
        typealias Edge = FaceLandmarkService.Edge
        let result = try FaceLandmarkService.orderedPaths(edges: [Edge(2, 1), Edge(0, 2), Edge(1, 0), Edge(1, 2), Edge(5, 4)], pointCount: 6)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].indices, [0, 1, 2])
        XCTAssertTrue(result[0].closed)
        XCTAssertEqual(result[1].indices, [4, 5])
        XCTAssertFalse(result[1].closed)
        XCTAssertThrowsError(try FaceLandmarkService.orderedPaths(edges: [Edge(0, 1), Edge(0, 2), Edge(0, 3)], pointCount: 4))
        XCTAssertThrowsError(try FaceLandmarkService.orderedPaths(edges: [Edge(0, 4)], pointCount: 4))
        XCTAssertThrowsError(try FaceLandmarkService.orderedPaths(edges: [Edge(-1, 2)], pointCount: 4))
        XCTAssertThrowsError(try FaceLandmarkService.orderedPaths(edges: [Edge(1, 1)], pointCount: 4))
    }
}
