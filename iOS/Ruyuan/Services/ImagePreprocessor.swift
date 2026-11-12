import UIKit

enum ImagePreprocessor {
    struct Prepared: @unchecked Sendable { let image: UIImage; let data: Data }

    private final class ImageInput: @unchecked Sendable {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
    }

    static func prepare(_ image: UIImage) async throws -> Prepared {
        try Task.checkCancellation()
        // UIImage is immutable for this operation, as in LocalAnalyzer's detached worker.
        let input = ImageInput(image)
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try Task.checkCancellation()
                let image = input.image
                guard image.size.width > 0, image.size.height > 0,
                      image.size.width * image.scale * image.size.height * image.scale <= 60_000_000 else {
                    throw AnalysisError.invalidImage
                }
                let pixelWidth = image.size.width * image.scale
                let pixelHeight = image.size.height * image.scale
                let longSide = max(pixelWidth, pixelHeight)
                let factor = min(1, 2560 / longSide)
                let size = CGSize(width: max(1, (pixelWidth * factor).rounded()),
                                  height: max(1, (pixelHeight * factor).rounded()))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let upright = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                    UIColor.white.setFill()
                    ctx.fill(CGRect(origin: .zero, size: size))
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                try Task.checkCancellation()
                guard let jpeg = upright.jpegData(compressionQuality: 0.94) else { throw AnalysisError.invalidImage }
                try Task.checkCancellation()
                guard let canonical = UIImage(data: jpeg) else { throw AnalysisError.invalidImage }
                try Task.checkCancellation()
                // Analyze exactly the same decoded pixels that are persisted/uploaded. Geometry
                // remains upright, uncropped and isotropically resized, including EXIF mirrors.
                return Prepared(image: canonical, data: jpeg)
            }
        }
        return try await withTaskCancellationHandler {
            let prepared = try await worker.value
            try Task.checkCancellation()
            return prepared
        } onCancel: {
            // Detached tasks do not inherit cancellation. Still await/drain this worker; do not
            // return while native rendering/encoding is running and start another photo on top.
            worker.cancel()
        }
    }
}
