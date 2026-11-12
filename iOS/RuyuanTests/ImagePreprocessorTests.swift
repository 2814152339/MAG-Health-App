import CoreGraphics
import Foundation
import UIKit
import XCTest
@testable import Ruyuan

final class ImagePreprocessorTests: XCTestCase {
    private func fixture(width: Int = 80, height: Int = 40, orientation: UIImage.Orientation = .up) throws -> UIImage {
        let colors: [[UInt8]] = [[240, 15, 15], [15, 240, 15], [15, 15, 240], [240, 240, 15]]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let color = colors[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]
            let index = (y * width + x) * 4
            pixels[index] = color[0]; pixels[index + 1] = color[1]; pixels[index + 2] = color[2]
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return UIImage(cgImage: cg, scale: 1, orientation: orientation)
    }

    func testAlreadyCancelledAnalysisDoesNotStartDetachedPhotoPreparation() async throws {
        let input = try fixture()
        let task = Task {
            // Sleep throws both when cancelled before it starts and when cancelled while asleep.
            // Ignoring that error leaves a deterministically cancelled parent BEFORE prepare.
            do { try await Task.sleep(for: .seconds(60)) } catch { }
            return try await ImagePreprocessor.prepare(input)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled preparation must throw, not encode and return a fresh image")
        } catch is CancellationError { } catch { XCTFail("Expected cancellation, got \(error)") }
    }

    func testAllEXIFDirectionsPreserveUncroppedUprightQuadrantsAndJPEGIdentity() async throws {
        // Source rows: red/green, blue/yellow. Expected rows are literal EXIF transforms, not
        // guessed Vision coordinates. Each returned UIImage must be the redecoded saved JPEG.
        let cases: [(UIImage.Orientation, [Int], Bool)] = [
            (.up, [0, 1, 2, 3], false), (.upMirrored, [1, 0, 3, 2], false),
            (.down, [3, 2, 1, 0], false), (.downMirrored, [2, 3, 0, 1], false),
            (.leftMirrored, [0, 2, 1, 3], true), (.right, [2, 0, 3, 1], true),
            (.rightMirrored, [3, 1, 2, 0], true), (.left, [1, 3, 0, 2], true)
        ]
        for (orientation, colors, swapped) in cases {
            let prepared = try await ImagePreprocessor.prepare(fixture(orientation: orientation))
            let cg = try XCTUnwrap(prepared.image.cgImage)
            XCTAssertEqual(prepared.image.imageOrientation, .up)
            XCTAssertEqual(cg.width, swapped ? 40 : 80)
            XCTAssertEqual(cg.height, swapped ? 80 : 40)
            let raster = try XCTUnwrap(LocalAnalyzer.makeRaster(cg))
            let positions = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
            for (position, color) in zip(positions, colors) {
                let rgb = raster.rgb(x: Int(position.0 * Double(raster.width)), y: Int(position.1 * Double(raster.height)))
                assertColor(rgb, color, message: "orientation=\(orientation.rawValue)")
            }
            let decoded = try XCTUnwrap(UIImage(data: prepared.data))
            XCTAssertEqual(try XCTUnwrap(DepthSnapshot.imageFingerprint(prepared.image)), try XCTUnwrap(DepthSnapshot.imageFingerprint(decoded)),
                           "Inference and persisted/uploaded JPEG must be exactly the same decoded pixels")
        }
    }

    func testLargePhotoIsScaledWithoutCroppingOrUpsamplingSmallPhoto() async throws {
        let large = try await ImagePreprocessor.prepare(fixture(width: 3000, height: 1500))
        let cg = try XCTUnwrap(large.image.cgImage)
        XCTAssertEqual(cg.width, 2560)
        XCTAssertEqual(cg.height, 1280)
        let raster = try XCTUnwrap(LocalAnalyzer.makeRaster(cg))
        assertColor(raster.rgb(x: raster.width / 10, y: raster.height / 10), 0, message: "top left survives")
        assertColor(raster.rgb(x: raster.width * 9 / 10, y: raster.height * 9 / 10), 3, message: "bottom right survives")
        let small = try await ImagePreprocessor.prepare(fixture())
        XCTAssertEqual(small.image.cgImage?.width, 80)
        XCTAssertEqual(small.image.cgImage?.height, 40)
    }

    private func assertColor(_ rgb: (Double, Double, Double), _ color: Int, message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let expected = [(true, false, false), (false, true, false), (false, false, true), (true, true, false)][color]
        for (value, high) in [(rgb.0, expected.0), (rgb.1, expected.1), (rgb.2, expected.2)] {
            if high { XCTAssertGreaterThan(value, 0.7, message, file: file, line: line) }
            else { XCTAssertLessThan(value, 0.3, message, file: file, line: line) }
        }
    }
}
