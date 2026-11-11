import CoreGraphics
import UIKit
import XCTest
@testable import Ruyuan

final class LocalAnalyzerTests: XCTestCase {
    func testVisionFaceCoordinatesBecomeTopLeftImageCoordinates() {
        let box = CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.6)
        let point = LocalAnalyzer.normalizedFacePoint(CGPoint(x: 0.2, y: 0.75), box: box)
        XCTAssertEqual(point.x, 0.3, accuracy: 0.000001)
        XCTAssertEqual(point.y, 0.45, accuracy: 0.000001)
        let bottom = LocalAnalyzer.normalizedFacePoint(.zero, box: box)
        XCTAssertEqual(bottom.y, 0.9, accuracy: 0.000001)
    }

    func testGeometryUsesPixelAspectRatioNotNormalizedDistance() throws {
        let points: [String: [NormalizedPoint]] = [
            "faceContour": [.init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)],
            "leftEye": [.init(x: 0.3, y: 0.4), .init(x: 0.4, y: 0.4)],
            "rightEye": [.init(x: 0.6, y: 0.5), .init(x: 0.7, y: 0.5)],
            "outerLips": [.init(x: 0.4, y: 0.7), .init(x: 0.6, y: 0.7)],
            "nose": [.init(x: 0.45, y: 0.6), .init(x: 0.55, y: 0.6)]
        ]
        let metrics = LocalAnalyzer.geometryMetrics(points, width: 1000, height: 2000)
        let jawEye = try XCTUnwrap(metrics.first { $0.id == "jaw-eye" }?.value)
        XCTAssertEqual(jawEye, 800 / hypot(300, 200), accuracy: 0.000001)
        let noseMouth = try XCTUnwrap(metrics.first { $0.id == "nose-mouth" }?.value)
        XCTAssertEqual(noseMouth, 0.5, accuracy: 0.000001)
        XCTAssertNil(metrics.first { $0.id == "millimeters" }?.value)
        XCTAssertNil(metrics.first { $0.id == "thirds" }?.value)
    }

    func testMissingLandmarksDoNotGenerateGeometry() {
        let metrics = LocalAnalyzer.geometryMetrics([:], width: 1000, height: 1000)
        XCTAssertTrue(metrics.allSatisfy { $0.value == nil })
    }

    func testEyeBrowAndLipMetricsUseDefinedPixelGeometry() throws {
        let points: [String: [NormalizedPoint]] = [
            "faceContour": [.init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)],
            "leftEye": [.init(x: 0.25, y: 0.38), .init(x: 0.35, y: 0.38), .init(x: 0.35, y: 0.40), .init(x: 0.25, y: 0.40)],
            "rightEye": [.init(x: 0.65, y: 0.38), .init(x: 0.75, y: 0.38), .init(x: 0.75, y: 0.40), .init(x: 0.65, y: 0.40)],
            "leftEyebrow": [.init(x: 0.2, y: 0.30), .init(x: 0.3, y: 0.25)],
            "outerLips": [.init(x: 0.4, y: 0.65), .init(x: 0.6, y: 0.65), .init(x: 0.6, y: 0.75), .init(x: 0.4, y: 0.75)],
            "innerLips": [.init(x: 0.42, y: 0.68), .init(x: 0.58, y: 0.68), .init(x: 0.58, y: 0.71), .init(x: 0.42, y: 0.71)]
        ]
        let metrics = LocalAnalyzer.geometryMetrics(points, width: 1000, height: 2000)
        func value(_ id: String) throws -> Double { try XCTUnwrap(metrics.first { $0.id == id }?.value) }
        XCTAssertEqual(try value("left-eye-aspect"), 0.4, accuracy: 0.000001)
        XCTAssertEqual(try value("left-brow-tilt"), 45, accuracy: 0.000001)
        XCTAssertEqual(try value("upper-lip-width"), 0.3, accuracy: 0.000001)
        XCTAssertEqual(try value("lower-lip-width"), 0.4, accuracy: 0.000001)
        XCTAssertEqual(try value("lip-upper-lower"), 0.75, accuracy: 0.000001)
    }

    func testRasterKeepsTopLeftPixelOrderAndRGBChannels() throws {
        // Explicit image rows: top = red/green, bottom = blue/white.
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                             0, 0, 255, 255, 255, 255, 255, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let raster = try XCTUnwrap(LocalAnalyzer.makeRaster(image))
        XCTAssertEqual(raster.rgb(x: 0, y: 0).0, 1, accuracy: 0.001)
        XCTAssertEqual(raster.rgb(x: 0, y: 0).2, 0, accuracy: 0.001)
        XCTAssertEqual(raster.rgb(x: 0, y: 1).0, 0, accuracy: 0.001)
        XCTAssertEqual(raster.rgb(x: 0, y: 1).2, 1, accuracy: 0.001)
    }

    func testBlankPhotoThrowsNoFaceInsteadOfFabricatingReport() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        }
        do {
            _ = try await LocalAnalyzer.analyze(image: image, reportID: "blank", imageFileName: "blank.jpg") { _ in }
            XCTFail("A blank image must not produce a face/skin report")
        } catch AnalysisError.noFace {
            // Expected real Vision result on an empty image.
        }
    }
}
