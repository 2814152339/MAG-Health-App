import Foundation
import UIKit
import CryptoKit
import MediaPipeTasksVision

/// Actual, bundled Google Selfie Multiclass inference. No network, image cache or training data.
/// The model classifies visible surfaces, not skin conditions or an anatomical hairline.
enum FaceSegmentationService {
    static let modelName = "selfie_multiclass_256x256"
    static let modelSHA256 = "c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0"
    static let version = "Google-SelfieMulticlass256-float32-v1"
    static let source = version + "; SHA256 " + modelSHA256 + "; MediaPipe Tasks 1.2.2 CPU; Apache-2.0"

    enum Category: UInt8, CaseIterable, Sendable {
        case background = 0, hair = 1, bodySkin = 2, faceSkin = 3, clothes = 4, accessories = 5
    }

    enum Failure: Error, LocalizedError {
        case missingModel, invalidModel, invalidImage, invalidOutput
        var errorDescription: String? {
            switch self {
            case .missingModel: return "未找到本机语义分割模型；本次只能使用明确标注的几何采样区域。"
            case .invalidModel: return "本机分割模型校验失败；未使用该模型生成结果。"
            case .invalidImage: return "分割输入图像无效；未生成语义掩膜。"
            case .invalidOutput: return "本机分割输出无效；未生成语义掩膜。"
            }
        }
    }

    struct Mask: Sendable {
        let width: Int
        let height: Int
        let categories: [UInt8]
        /// Six planar confidence maps in official model order, copied before the task is released.
        let confidence: [[Float]]

        init(width: Int, height: Int, categories: [UInt8], confidence: [[Float]]) throws {
            guard width > 0, height > 0, width <= 2048, height <= 2048,
                  categories.count == width * height, confidence.count == 6,
                  categories.allSatisfy({ $0 < 6 }),
                  confidence.allSatisfy({ $0.count == width * height && $0.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1.001 }) }) else {
                throw Failure.invalidOutput
            }
            self.width = width; self.height = height
            self.categories = categories; self.confidence = confidence
        }

        func index(x: Double, y: Double) -> Int? {
            guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
            return min(height - 1, Int(y * Double(height))) * width + min(width - 1, Int(x * Double(width)))
        }

        func accepts(_ category: Category, x: Double, y: Double, threshold: Float = 0.65) -> Bool {
            guard let i = index(x: x, y: y) else { return false }
            return categories[i] == category.rawValue && confidence[Int(category.rawValue)][i] >= threshold
        }

        /// A semantic face-skin label never authorizes sampling eyes, eyebrows, lips or nostrils.
        /// Vision regions are inflated slightly to reject edges and model interpolation bleed.
        func isFaceSkin(x: Double, y: Double, landmarks: [String: [NormalizedPoint]]) -> Bool {
            accepts(.faceSkin, x: x, y: y) && !Self.excludesFeature(x: x, y: y, landmarks: landmarks)
        }

        static func excludesFeature(x: Double, y: Double, landmarks: [String: [NormalizedPoint]]) -> Bool {
            for key in ["leftEye", "rightEye", "leftEyebrow", "rightEyebrow", "outerLips", "innerLips"] {
                guard let points = landmarks[key], let left = points.map(\.x).min(), let right = points.map(\.x).max(),
                      let top = points.map(\.y).min(), let bottom = points.map(\.y).max() else { continue }
                let dx = max(0.004, (right - left) * 0.08), dy = max(0.004, (bottom - top) * 0.15)
                if x >= left - dx && x <= right + dx && y >= top - dy && y <= bottom + dy { return true }
            }
            // The lower 22% of the nose outline includes nostrils and their high-contrast edges.
            if let nose = landmarks["nose"], let left = nose.map(\.x).min(), let right = nose.map(\.x).max(),
               let top = nose.map(\.y).min(), let bottom = nose.map(\.y).max(),
               x >= left - 0.003, x <= right + 0.003, y >= bottom - (bottom - top) * 0.22, y <= bottom + 0.005 { return true }
            return false
        }

        func overlays(landmarks: [String: [NormalizedPoint]], faceBox: CGRect) -> [OverlayLayer] {
            let face = CGRect(x: faceBox.minX, y: 1 - faceBox.maxY, width: faceBox.width, height: faceBox.height)
            let definitions: [(Category, String, String, String)] = [
                (.faceSkin, "semantic-face-skin", "模型有效面部皮肤区", "78BFA5"),
                (.hair, "semantic-hair", "模型毛发区域", "8A81D9"),
                (.accessories, "semantic-accessories", "模型配饰/其他区域", "E5AF67")
            ]
            return definitions.map { category, id, title, color in
                var paths: [[NormalizedPoint]] = []
                var truncated = false
                // Sample the actual mask into a bounded display grid; statistics use the full map.
                let step = max(1, Int(ceil(Double(max(width, height)) / 192)))
                for y in stride(from: 0, to: height, by: step) {
                    var x = 0
                    while x < width {
                        func allowed(_ pixelX: Int) -> Bool {
                            let px = (Double(pixelX) + 0.5) / Double(width), py = (Double(y) + 0.5) / Double(height)
                            if category == .faceSkin {
                                return face.contains(CGPoint(x: px, y: py)) && isFaceSkin(x: px, y: py, landmarks: landmarks)
                            }
                            return accepts(category, x: px, y: py)
                        }
                        guard allowed(x) else { x += step; continue }
                        let start = x
                        while x < width && allowed(x) { x += step }
                        if paths.count >= 900 { truncated = true; break }
                        let x0 = Double(start) / Double(width), x1 = Double(min(x, width)) / Double(width)
                        let y0 = Double(y) / Double(height), y1 = Double(min(y + step, height)) / Double(height)
                        paths.append([.init(x: x0, y: y0), .init(x: x1, y: y0), .init(x: x1, y: y1), .init(x: x0, y: y1)])
                    }
                    if truncated { break }
                }
                let note = "官方六分类模型类别\(category.rawValue)，置信度≥0.65；面部皮肤另限定本人人脸框并排除眼眉唇鼻孔。未将身体皮肤混作面部皮肤。" + (truncated ? " 显示最多900段；分析使用完整掩膜。" : " 图层来自本照片真实模型输出。")
                return OverlayLayer(id: id, title: title, colorHex: color, kind: .polygons, paths: paths, note: note, source: FaceSegmentationService.source)
            }
        }

        /// Only a stable, visible hair-to-forehead boundary can be estimated. Bangs/occlusion may
        /// differ from an anatomical hairline, so ratios are explicitly named visible-boundary ratios.
        func visibleHairBoundary(landmarks: [String: [NormalizedPoint]], faceBox: CGRect) -> [NormalizedPoint]? {
            let brows = (landmarks["leftEyebrow"] ?? []) + (landmarks["rightEyebrow"] ?? [])
            guard brows.count >= 4, let left = brows.map(\.x).min(), let right = brows.map(\.x).max() else { return nil }
            let browY = brows.map(\.y).reduce(0, +) / Double(brows.count)
            let faceHeight = Double(faceBox.height)
            let lowY = max(0, browY - faceHeight * 0.75), highY = browY - faceHeight * 0.08
            guard highY > lowY, right > left else { return nil }
            let start = max(2, Int(lowY * Double(height))), end = min(height - 5, Int(highY * Double(height)))
            guard end > start else { return nil }
            var candidates: [NormalizedPoint] = []
            for column in 0..<11 {
                let x = left + (right - left) * (0.25 + Double(column) * 0.05)
                var boundary: Double?
                for y in start..<end {
                    let py = (Double(y) + 0.5) / Double(height)
                    let hairAbove = (1...2).allSatisfy { accepts(.hair, x: x, y: py - Double($0) / Double(height)) }
                    let skinBelow = (0...4).allSatisfy { accepts(.faceSkin, x: x, y: py + Double($0) / Double(height)) }
                    if hairAbove && skinBelow { boundary = py }
                }
                if let boundary { candidates.append(.init(x: x, y: boundary)) }
            }
            guard candidates.count >= 7 else { return nil }
            let ys = candidates.map(\.y).sorted(), median = ys[ys.count / 2]
            let stable = candidates.filter { abs($0.y - median) <= faceHeight * 0.045 }
            guard stable.count >= 7, let minX = stable.map(\.x).min(), let maxX = stable.map(\.x).max(),
                  maxX - minX >= (right - left) * 0.25 else { return nil }
            return stable.sorted { $0.x < $1.x }
        }

        func boundaryGeometry(landmarks: [String: [NormalizedPoint]], faceBox: CGRect) -> (metrics: [GeometryMetric], overlay: OverlayLayer?, path: LandmarkPath?) {
            guard let boundary = visibleHairBoundary(landmarks: landmarks, faceBox: faceBox),
                  let nose = landmarks["nose"]?.map(\.y).max(), let chin = landmarks["faceContour"]?.map(\.y).max() else {
                return ([], nil, nil)
            }
            let brows = (landmarks["leftEyebrow"] ?? []) + (landmarks["rightEyebrow"] ?? [])
            guard !brows.isEmpty else { return ([], nil, nil) }
            let brow = brows.map(\.y).reduce(0, +) / Double(brows.count)
            let ys = boundary.map(\.y).sorted(), hair = ys[ys.count / 2]
            guard hair < brow, brow < nose, nose < chin else { return ([], nil, nil) }
            let total = chin - hair
            let definitions = [("upper", "上段", brow - hair), ("middle", "中段", nose - brow), ("lower", "下段", chin - nose)]
            let note = "上界为真实模型多列一致的可见发肤边界（置信度≥0.65），不是已确认的解剖发际线；刘海、发套、妆容可能改变边界。眉线为双眉均值，鼻底/颏底为Vision最大Y；三段和100%，无美丑评分。可用手动标定复核。"
            let metrics = definitions.map { id, title, distance in
                GeometryMetric(id: "model-third-" + id, title: "可见边界" + title + "占比", value: distance / total * 100, unit: "%", note: note)
            }
            let left = Double(faceBox.minX), right = Double(faceBox.maxX)
            let lines = [boundary] + [hair, brow, nose, chin].map { y in [NormalizedPoint(x: left, y: y), NormalizedPoint(x: right, y: y)] }
            let overlay = OverlayLayer(id: "geometry-model-hairline", title: "模型可见发肤边界与三段", colorHex: "FFE45E", kind: .lines, paths: lines, note: note, source: FaceSegmentationService.source)
            return (metrics, overlay, LandmarkPath(id: "modelVisibleHairBoundary", points: boundary, closed: false))
        }
    }

    static func modelURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: modelName, withExtension: "tflite", subdirectory: "Models")
            ?? bundle.url(forResource: modelName, withExtension: "tflite")
    }

    /// Called on LocalAnalyzer's detached worker. A per-call CPU task avoids shared mutable graph
    /// state and retains no private pixels after return. Copy all native buffers before release.
    static func segment(raster: LocalAnalyzer.Raster, modelURL suppliedURL: URL? = nil) throws -> Mask {
        try Task.checkCancellation()
        guard let url = suppliedURL ?? modelURL() else { throw Failure.missingModel }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == 16_371_837, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == modelSHA256 else { throw Failure.invalidModel }
        guard raster.width > 0, raster.height > 0, raster.width <= 2048, raster.height <= 2048,
              raster.pixels.count == raster.width * raster.height * 4,
              let provider = CGDataProvider(data: Data(raster.pixels) as CFData),
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: raster.width * 4, space: color,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw Failure.invalidImage }
        let options = ImageSegmenterOptions()
        options.baseOptions.modelAssetPath = url.path
        options.runningMode = .image
        options.outputCategoryMask = true
        options.outputConfidenceMasks = true
        let segmenter = try ImageSegmenter(options: options)
        guard segmenter.labels == ["background", "hair", "body-skin", "face-skin", "clothes", "others"] else { throw Failure.invalidModel }
        let result = try segmenter.segment(image: MPImage(uiImage: UIImage(cgImage: image, scale: 1, orientation: .up)))
        try Task.checkCancellation()
        guard let category = result.categoryMask, let confidence = result.confidenceMasks, confidence.count == 6,
              category.width > 0, category.height > 0, category.width <= 2048, category.height <= 2048,
              confidence.allSatisfy({ $0.width == category.width && $0.height == category.height }) else { throw Failure.invalidOutput }
        let count = category.width * category.height
        let classes = Array(UnsafeBufferPointer(start: category.uint8Data, count: count))
        let probabilities = confidence.map { Array(UnsafeBufferPointer(start: $0.float32Data, count: count)) }
        return try Mask(width: category.width, height: category.height, categories: classes, confidence: probabilities)
    }
}
