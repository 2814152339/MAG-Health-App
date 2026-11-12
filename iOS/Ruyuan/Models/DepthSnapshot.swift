import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UIKit

/// Same-photo payload. Depth is optional and local-only; never reuse it with an imported/cropped
/// image, upload it to a backend, or infer it when resuming an image-only pending analysis.
struct CameraCapture {
    let image: UIImage
    let depth: DepthSnapshot?
    let depthNotice: String

    func validatedDepth() -> DepthSnapshot? {
        guard let depth, depth.matches(image: image) else { return nil }
        return depth
    }
}

/// A copied, upright, calibrated absolute-depth sample. Zero represents invalid/missing depth.
/// Only a TrueDepth photo with absolute, high-quality, unfiltered depth is admitted by capture().
/// Codable permits local data handling, not permission to persist/upload these sensitive pixels.
struct DepthSnapshot: Codable, Sendable {
    let captureID: String
    let originalJPEGSHA256: String
    let sourceImageFingerprint: String
    let imageWidth: Int
    let imageHeight: Int
    let width: Int
    let height: Int
    let depthMeters: [Float]
    /// Column-major 3x3 intrinsic matrix after the exact photo EXIF transform.
    let intrinsicMatrix: [Float]
    let referenceWidth: Double
    let referenceHeight: Double
    let distortionCenterX: Double
    let distortionCenterY: Double
    /// Both tables retained to validate a rectification round trip. Apple's camera-header point
    /// mapping convention uses inverse for distorted→rectilinear, direct for the reverse mapping.
    let lensDistortion: [Float]
    let inverseLensDistortion: [Float]
    let originalExifOrientation: UInt32
    let source: String

    var isUsable: Bool {
        width >= 8 && height >= 8 && width <= 2048 && height <= 2048 && width * height <= 1_048_576
            && imageWidth > 0 && imageHeight > 0 && imageWidth <= 16384 && imageHeight <= 16384
            && depthMeters.count == width * height && depthMeters.allSatisfy { $0.isFinite && ($0 == 0 || (0.15...1.2).contains($0)) }
            && intrinsicMatrix.count == 9 && intrinsicMatrix.allSatisfy(\.isFinite)
            && referenceWidth.isFinite && referenceHeight.isFinite && referenceWidth > 0 && referenceHeight > 0
            && distortionCenterX.isFinite && distortionCenterY.isFinite
            && (0...referenceWidth).contains(distortionCenterX) && (0...referenceHeight).contains(distortionCenterY)
            && (2...4096).contains(lensDistortion.count) && (2...4096).contains(inverseLensDistortion.count)
            && lensDistortion.allSatisfy { $0.isFinite && abs($0) < 1 }
            && inverseLensDistortion.allSatisfy { $0.isFinite && abs($0) < 1 }
            && (1...8).contains(originalExifOrientation)
            && abs(Double(width) / Double(height) / (Double(imageWidth) / Double(imageHeight)) - 1) <= 0.015
            && abs(referenceWidth / referenceHeight / (Double(width) / Double(height)) - 1) <= 0.015
    }

    /// Validate against the unmodified CameraCapture.image BEFORE resizing/reencoding it.
    /// Subsequent upright isotropic scaling preserves normalized coordinates; a crop does not.
    func matches(image: UIImage) -> Bool {
        guard isUsable, let cg = image.cgImage, let orientation = Self.exifOrientation(image.imageOrientation) else { return false }
        let swapped = (5...8).contains(orientation.rawValue)
        return imageWidth == (swapped ? cg.height : cg.width) && imageHeight == (swapped ? cg.width : cg.height)
            && Self.imageFingerprint(image) == sourceImageFingerprint
    }

    static func imageFingerprint(_ image: UIImage) -> String? {
        guard let cg = image.cgImage, let bytes = cg.dataProvider?.data else { return nil }
        var hash = SHA256()
        let header = "\(cg.width),\(cg.height),\(cg.bytesPerRow),\(cg.bitsPerPixel),\(cg.bitmapInfo.rawValue),\(image.imageOrientation.rawValue);"
        hash.update(data: Data(header.utf8))
        hash.update(data: bytes as Data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum CaptureFailure: Error, LocalizedError {
        case unavailable, relativeOrFiltered, calibration, alignment, invalidData
        var errorDescription: String? {
            switch self {
            case .unavailable: return "本次没有同拍TrueDepth深度，继续二维照片分析。"
            case .relativeOrFiltered: return "深度未达到绝对、高质量、未滤波条件，本次不输出毫米。"
            case .calibration: return "同拍相机标定或畸变校正表不足，本次不输出毫米。"
            case .alignment: return "深度与照片方向或画幅无法可靠对应，本次不输出毫米。"
            case .invalidData: return "本次有效深度像素不足，继续二维照片分析。"
            }
        }
    }

    static func capture(photo: AVCapturePhoto, image: UIImage, jpeg: Data, isTrueDepth: Bool) throws -> DepthSnapshot {
        guard isTrueDepth, let original = photo.depthData else { throw CaptureFailure.unavailable }
        guard original.depthDataAccuracy == .absolute, original.depthDataQuality == .high, !original.isDepthDataFiltered else { throw CaptureFailure.relativeOrFiltered }
        guard let orientation = exifOrientation(image.imageOrientation) else { throw CaptureFailure.alignment }
        // Apple's API rotates BOTH the map and calibration metadata; do not rotate just one.
        let upright = original.applyingExifOrientation(orientation).converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        guard let calibration = upright.cameraCalibrationData,
              let direct = calibration.lensDistortionLookupTable,
              let inverse = calibration.inverseLensDistortionLookupTable,
              let directTable = floats(direct), let inverseTable = floats(inverse),
              let fingerprint = imageFingerprint(image), let cg = image.cgImage else { throw CaptureFailure.calibration }
        let buffer = upright.depthDataMap, width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width >= 8, height >= 8, width <= 2048, height <= 2048, width * height <= 1_048_576,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw CaptureFailure.invalidData }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CaptureFailure.invalidData }
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.stride
        guard stride >= width else { throw CaptureFailure.invalidData }
        let values = base.assumingMemoryBound(to: Float.self)
        var depth = [Float](repeating: 0, count: width * height), valid = 0
        for y in 0..<height { for x in 0..<width {
            let value = values[y * stride + x]
            if value.isFinite && (0.15...1.2).contains(value) { depth[y * width + x] = value; valid += 1 }
        } }
        guard valid >= 100 else { throw CaptureFailure.invalidData }
        let rotated: [UIImage.Orientation] = [.left, .leftMirrored, .right, .rightMirrored]
        let swapped = rotated.contains(image.imageOrientation)
        let matrix = calibration.intrinsicMatrix
        let snapshot = DepthSnapshot(captureID: UUID().uuidString,
            originalJPEGSHA256: SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined(),
            sourceImageFingerprint: fingerprint,
            imageWidth: swapped ? cg.height : cg.width, imageHeight: swapped ? cg.width : cg.height,
            width: width, height: height, depthMeters: depth,
            intrinsicMatrix: (0..<3).flatMap { column in (0..<3).map { row in matrix[column][row] } },
            referenceWidth: Double(calibration.intrinsicMatrixReferenceDimensions.width),
            referenceHeight: Double(calibration.intrinsicMatrixReferenceDimensions.height),
            distortionCenterX: Double(calibration.lensDistortionCenter.x), distortionCenterY: Double(calibration.lensDistortionCenter.y),
            lensDistortion: directTable, inverseLensDistortion: inverseTable, originalExifOrientation: orientation.rawValue,
            source: "AVCapturePhoto TrueDepth absolute/high/unfiltered DepthFloat32; EXIF map+calibration transformed; local-only")
        guard snapshot.isUsable else { throw CaptureFailure.alignment }
        return snapshot
    }

    private static func floats(_ data: Data) -> [Float]? {
        guard data.count % MemoryLayout<Float>.stride == 0, (2...4096).contains(data.count / MemoryLayout<Float>.stride) else { return nil }
        // NSData alignment is not promised. Copy bytes into aligned Float storage.
        var output = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.stride)
        _ = output.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return output
    }

    private static func exifOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation? {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return nil
        }
    }
}
