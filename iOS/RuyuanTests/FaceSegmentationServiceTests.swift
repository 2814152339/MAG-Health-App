import CoreGraphics
import XCTest
@testable import Ruyuan

final class FaceSegmentationServiceTests: XCTestCase {
    private var landmarks: [String: [NormalizedPoint]] {
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [NormalizedPoint] {
            [.init(x: x, y: y), .init(x: x + w, y: y), .init(x: x + w, y: y + h), .init(x: x, y: y + h)]
        }
        return ["leftEye": rect(0.25, 0.40, 0.14, 0.04), "rightEye": rect(0.61, 0.40, 0.14, 0.04),
                "leftEyebrow": rect(0.23, 0.35, 0.18, 0.02), "rightEyebrow": rect(0.59, 0.35, 0.18, 0.02),
                "outerLips": rect(0.39, 0.72, 0.22, 0.07), "nose": rect(0.43, 0.44, 0.14, 0.21),
                "faceContour": [.init(x: 0.12, y: 0.40), .init(x: 0.50, y: 0.90), .init(x: 0.88, y: 0.40)]]
    }

    private func mask(width: Int = 100, height: Int = 100,
                      category: (Int, Int) -> FaceSegmentationService.Category) throws -> FaceSegmentationService.Mask {
        var labels = [UInt8](repeating: 0, count: width * height)
        var probabilities = (0..<6).map { _ in [Float](repeating: 0, count: width * height) }
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x, value = category(x, y)
            labels[i] = value.rawValue; probabilities[Int(value.rawValue)][i] = 1
        } }
        return try .init(width: width, height: height, categories: labels, confidence: probabilities)
    }

    /// This is an actual CPU graph invocation using the shipped, checksum-verified pretrained
    /// weight. Missing model/dependency/kernel is a test FAILURE, never a skipped fake inference.
    func testBundledOfficialModelActuallyRunsAndReturnsSixClasses() throws {
        let url = try XCTUnwrap(FaceSegmentationService.modelURL(), "Production bundle MUST include the real .tflite resource")
        let width = 240, height = 160
        var pixels = [UInt8](repeating: 127, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let result = try FaceSegmentationService.segment(raster: .init(width: width, height: height, pixels: pixels), modelURL: url)
        XCTAssertEqual(result.width, width)
        XCTAssertEqual(result.height, height)
        XCTAssertEqual(result.confidence.count, 6)
        XCTAssertEqual(FaceSegmentationService.Category.faceSkin.rawValue, 3)
        XCTAssertEqual(FaceSegmentationService.Category.hair.rawValue, 1)
        XCTAssertEqual(FaceSegmentationService.Category.accessories.rawValue, 5)
        XCTAssertGreaterThan(Double(result.categories.filter { $0 == 0 }.count) / Double(width * height), 0.8)
        XCTAssertFalse(result.accepts(.faceSkin, x: 0.5, y: 0.5), "A blank frame must not invent a face")
        XCTAssertNil(result.visibleHairBoundary(landmarks: landmarks, faceBox: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9)))
    }

    func testFaceSkinDoesNotAdmitBodyHairAccessoriesOrLandmarkEyes() throws {
        let face = try mask { _, _ in .faceSkin }
        XCTAssertTrue(face.isFaceSkin(x: 0.32, y: 0.56, landmarks: landmarks))
        for point in [NormalizedPoint(x: 0.32, y: 0.42), .init(x: 0.68, y: 0.42), .init(x: 0.32, y: 0.36),
                      .init(x: 0.5, y: 0.75), .init(x: 0.5, y: 0.63)] {
            XCTAssertFalse(face.isFaceSkin(x: point.x, y: point.y, landmarks: landmarks))
        }
        for category in [FaceSegmentationService.Category.bodySkin, .hair, .accessories, .background, .clothes] {
            XCTAssertFalse(try mask { _, _ in category }.isFaceSkin(x: 0.32, y: 0.56, landmarks: landmarks))
        }
        XCTAssertFalse(face.accepts(.faceSkin, x: .nan, y: 0.5))
        XCTAssertFalse(face.accepts(.faceSkin, x: -0.01, y: 0.5))
    }

    func testOnlyActualStableHairToSkinBoundaryYieldsThreeRatios() throws {
        let input = try mask { _, y in y < 20 ? .hair : .faceSkin }
        let box = CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9)
        let result = input.boundaryGeometry(landmarks: landmarks, faceBox: box)
        XCTAssertEqual(result.metrics.count, 3)
        XCTAssertEqual(result.metrics.compactMap(\.value).reduce(0, +), 100, accuracy: 0.0001)
        let points = try XCTUnwrap(result.path).points
        XCTAssertGreaterThanOrEqual(points.count, 7)
        XCTAssertEqual(points[0].y, 0.205, accuracy: 0.0001)
        XCTAssertTrue(points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        XCTAssertTrue(result.metrics.allSatisfy { $0.note.contains("不是已确认的解剖发际线") })
        XCTAssertTrue(try mask { _, _ in .faceSkin }.boundaryGeometry(landmarks: landmarks, faceBox: box).metrics.isEmpty)
        XCTAssertTrue(try mask { _, _ in .hair }.boundaryGeometry(landmarks: landmarks, faceBox: box).metrics.isEmpty)
        XCTAssertTrue(input.boundaryGeometry(landmarks: [:], faceBox: box).metrics.isEmpty)
    }

    func testUncertainProbabilitiesAndInvalidOutputDoNotBecomeSkin() throws {
        var probabilities = (0..<6).map { _ in [Float](repeating: 0.1, count: 4) }
        probabilities[3] = [0.64, 0.65, 0.90, 0.90]
        let input = try FaceSegmentationService.Mask(width: 2, height: 2, categories: [3, 3, 5, 3], confidence: probabilities)
        XCTAssertFalse(input.accepts(.faceSkin, x: 0.1, y: 0.1))
        XCTAssertTrue(input.accepts(.faceSkin, x: 0.9, y: 0.1))
        XCTAssertFalse(input.accepts(.faceSkin, x: 0.1, y: 0.9))
        XCTAssertThrowsError(try FaceSegmentationService.Mask(width: 2, height: 2, categories: [7, 0, 0, 0], confidence: probabilities))
        probabilities[0][0] = .nan
        XCTAssertThrowsError(try FaceSegmentationService.Mask(width: 2, height: 2, categories: [0, 0, 0, 0], confidence: probabilities))
    }

    func testAppearanceUsesSemanticMaskInsteadOfAcceptingAnAccessoryHighlight() throws {
        let width = 640, height = 640
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let accessory = x >= 190 && x < 210 && y >= 330 && y < 350
            pixels[i] = accessory ? 245 : 182; pixels[i + 1] = accessory ? 241 : 137; pixels[i + 2] = accessory ? 237 : 111
        } }
        let input = try mask(width: width, height: height) { x, y in
            x >= 190 && x < 210 && y >= 330 && y < 350 ? .accessories : .faceSkin
        }
        let result = AppearanceAnalyzer.analyze(raster: .init(width: width, height: height, pixels: pixels), landmarks: landmarks,
            faceBox: CGRect(x: 0.12, y: 0.08, width: 0.76, height: 0.84), segmentation: input)
        let highlight = try XCTUnwrap(result.overlays.first { $0.id == "appearance-highlight" })
        XCTAssertTrue(highlight.paths.isEmpty)
        XCTAssertTrue(highlight.source.contains("Google-SelfieMulticlass256"))
        XCTAssertTrue(result.summary.contains("本机Google六分类"))
    }
}
