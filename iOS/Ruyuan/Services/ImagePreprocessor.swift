import UIKit

enum ImagePreprocessor {
    struct Prepared: @unchecked Sendable { let image: UIImage; let data: Data }
    static func prepare(_ image: UIImage) async throws -> Prepared {
        try await Task.detached(priority: .userInitiated) {
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
            guard let jpeg = upright.jpegData(compressionQuality: 0.94), let canonical = UIImage(data: jpeg) else {
                throw AnalysisError.invalidImage
            }
            // Analyze exactly the same decoded pixels that are persisted/uploaded.
            return Prepared(image: canonical, data: jpeg)
        }.value
    }
}
