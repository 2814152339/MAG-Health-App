import CoreGraphics
import XCTest
@testable import Ruyuan

final class CameraFramingTests: XCTestCase {
    func testOrdinaryScreensUseFullWidthThreeByFourWhenThereIsRoom() {
        XCTAssertEqual(CameraFraming.topBarHeight, 44)
        let sizes = [CGSize(width: 320, height: 640), CGSize(width: 375, height: 700),
                     CGSize(width: 390, height: 844), CGSize(width: 430, height: 932)]
        for size in sizes {
            let height = CameraFraming.previewHeight(in: size)
            XCTAssertEqual(height, size.width * 4 / 3, accuracy: 0.000000001)
            XCTAssertGreaterThanOrEqual(size.height - CameraFraming.topBarHeight - height, 116)
        }
    }

    func testShortScreensReserve116PointControlsAnd44PointTopBar() {
        for size in [CGSize(width: 320, height: 300), CGSize(width: 375, height: 568),
                     CGSize(width: 430, height: 568)] {
            let height = CameraFraming.previewHeight(in: size)
            XCTAssertEqual(height, size.height - 44 - 116, accuracy: 0.000000001)
            XCTAssertLessThan(height, size.width * 4 / 3)
            XCTAssertEqual(height + 44 + 116, size.height, accuracy: 0.000000001)
        }
    }

    func testAccessibilityLayoutReserves220PointControlsAndSameTopBar() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
                     CGSize(width: 430, height: 700)] {
            let height = CameraFraming.previewHeight(in: size, accessibility: true)
            XCTAssertEqual(height, size.height - 44 - 220, accuracy: 0.000000001)
            XCTAssertGreaterThanOrEqual(size.height - CameraFraming.topBarHeight - height, 220)
            XCTAssertLessThan(height, CameraFraming.previewHeight(in: size))
        }
    }

    func testPortraitSizeMatrixRemainsFiniteNonnegativeAndWithinBothBudgets() {
        let widths: [CGFloat] = [320, 360, 375, 390, 393, 414, 430]
        let heights: [CGFloat] = [568, 667, 700, 736, 812, 844, 852, 896, 932]
        for width in widths {
            for height in heights {
                let size = CGSize(width: width, height: height)
                let ordinary = CameraFraming.previewHeight(in: size)
                for accessibility in [false, true] {
                    let controls: CGFloat = accessibility ? 220 : 116
                    let result = CameraFraming.previewHeight(in: size, accessibility: accessibility)
                    XCTAssertTrue(result.isFinite)
                    XCTAssertGreaterThanOrEqual(result, 0)
                    XCTAssertLessThanOrEqual(result, width * 4 / 3)
                    XCTAssertLessThanOrEqual(result + 44 + controls, height + 0.000000001)
                    XCTAssertLessThanOrEqual(result, height)
                    if accessibility { XCTAssertLessThanOrEqual(result, ordinary) }
                }
            }
        }
    }

    func testNoRemainingSpaceReturnsZeroInsteadOfNegativePreviewSize() {
        for height in [CGFloat(1), 44, 100, 160] {
            XCTAssertEqual(CameraFraming.previewHeight(in: CGSize(width: 375, height: height)), 0)
        }
        for height in [CGFloat(1), 44, 160, 264] {
            XCTAssertEqual(CameraFraming.previewHeight(in: CGSize(width: 375, height: height), accessibility: true), 0)
        }
    }

    func testZeroNegativeNaNAndInfiniteDimensionsReturnZero() {
        let invalid = [CGSize.zero, CGSize(width: 0, height: 568), CGSize(width: 375, height: 0),
                       CGSize(width: -1, height: 568), CGSize(width: 375, height: -1),
                       CGSize(width: CGFloat.nan, height: 568), CGSize(width: 375, height: CGFloat.nan),
                       CGSize(width: CGFloat.infinity, height: 568), CGSize(width: 375, height: CGFloat.infinity),
                       CGSize(width: -CGFloat.infinity, height: 568), CGSize(width: 375, height: -CGFloat.infinity)]
        for size in invalid {
            for accessibility in [false, true] {
                XCTAssertEqual(CameraFraming.previewHeight(in: size, accessibility: accessibility), 0)
            }
        }
    }
}
