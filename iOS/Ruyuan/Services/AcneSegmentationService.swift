import CoreML
import CoreVideo
import Foundation
import UIKit
import Vision

/// Pinned author binary acne-related pixel probabilities, gated by actual semantic facial skin.
/// Candidate pixels/components are not diagnoses, acne subtypes, lesion counts or health scores.
/// The author has not disclosed a complete training-image/label/consent provenance manifest.
enum AcneSegmentationService {
    static let revision = "79182ede8d14cb44de63b4f6ace1fa2a5a7a3d83"
    static let weightSHA256 = "c58a6af6fb622d916e4aa788d9f620d59df4a42209f655ce4a9db49686c05697"
    struct ArtifactPin: Sendable { let sha256: String; let bytes: Int }
    // Actual macOS CPU parity: run 43139668138 / artifact 13909590548, five fixtures.
    // This pins converted bytes, NOT the different original Torch checkpoint digest.
    static let approvedArtifact: ArtifactPin? = ArtifactPin(
        sha256: "0d022cbf4e3f266128ff23525a683452a43f05079d88eba4fd6f4124f40daf7a", bytes: 48_862_307)
    static let computePrecision = "float32_activations_float16_weights"
    static let source = "RihemXX/Acnes; revision " + revision + "; original SHA256 " + weightSHA256
        + "; Core ML CPU_ONLY " + computePrecision + "; Apache-2.0; author training-image provenance not fully disclosed; input: Core ML scaleFill resampling, not OpenCV pixel equivalence"
    static let inputWidth = 256, inputHeight = 256
    static let threshold: Float = 0.20
    static let overlayID = "model-acne-segmentation"

    enum State: String, Sendable {
        case ready
        case notBundled = "not_bundled"
        case lowResolution = "low_resolution"
        case missingSegmentation = "missing_segmentation"
        case insufficientSkin = "insufficient_skin"
        case invalidInput = "invalid_input"
        case invalidModel = "invalid_model"
        case inferenceFailed = "inference_failed"
    }

    enum Failure: Error, Equatable { case invalidInput, invalidModel, invalidOutput, insufficientSkin }

    struct Statistics: Sendable {
        let validSkinPixels: Int
        let candidatePixels: Int
        /// Eight-neighbor connected components, not a clinical lesion count.
        let connectedComponents: Int
        let coveragePercent: Double
    }

    struct Observation: Sendable {
        let state: State
        let nativeCropWidth: Int
        let nativeCropHeight: Int
        let elapsed: Double
        let statistics: Statistics?
        let overlay: OverlayLayer?
        let source: String
    }

    struct CropPlan {
        let pixels: CGRect
        /// Full-photo normalized, top-left coordinates; exactly the actual native crop bounds.
        let normalized: CGRect
    }

    static func modelURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "AcneSegmentation", withExtension: "mlmodelc", subdirectory: "Models")
            ?? bundle.url(forResource: "AcneSegmentation", withExtension: "mlmodelc")
    }

    static func manifestURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "AcneSegmentation-resource-manifest", withExtension: "json", subdirectory: "Models")
            ?? bundle.url(forResource: "AcneSegmentation-resource-manifest", withExtension: "json")
    }

    /// Vision faceBox is bottom-left normalized. No expansion, crop-and-pad or upscaled image is
    /// used to satisfy the native-resolution gate; the caller passes its original prepared photo.
    static func cropPlan(imageWidth: Int, imageHeight: Int, faceBox: CGRect) -> CropPlan? {
        guard imageWidth > 0, imageHeight > 0, imageWidth <= 8192, imageHeight <= 8192,
              validRect(faceBox) else { return nil }
        let width = Double(imageWidth), height = Double(imageHeight)
        // Inward integral bounds never gain a source pixel beyond the detected face rectangle.
        let x0 = ceil(Double(faceBox.minX) * width - 1e-9)
        let y0 = ceil((1 - Double(faceBox.maxY)) * height - 1e-9)
        let x1 = floor(Double(faceBox.maxX) * width + 1e-9)
        let y1 = floor((1 - Double(faceBox.minY)) * height + 1e-9)
        guard x1 > x0, y1 > y0 else { return nil }
        return CropPlan(pixels: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                        normalized: CGRect(x: x0 / width, y: y0 / height, width: (x1 - x0) / width, height: (y1 - y0) / height))
    }

    static func analyze(image: CGImage, faceBox: CGRect, landmarks: [String: [NormalizedPoint]],
                        segmentation: FaceSegmentationService.Mask?, bundle: Bundle = .main) throws -> Observation {
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        let plan = cropPlan(imageWidth: image.width, imageHeight: image.height, faceBox: faceBox)
        let nativeWidth = plan.map { Int($0.pixels.width) } ?? 0
        let nativeHeight = plan.map { Int($0.pixels.height) } ?? 0
        func unavailable(_ state: State) -> Observation {
            Observation(state: state, nativeCropWidth: nativeWidth, nativeCropHeight: nativeHeight,
                        elapsed: ProcessInfo.processInfo.systemUptime - started, statistics: nil, overlay: nil, source: source)
        }
        guard let plan else { return unavailable(.invalidInput) }
        guard nativeWidth >= inputWidth, nativeHeight >= inputHeight else { return unavailable(.lowResolution) }
        guard let segmentation else { return unavailable(.missingSegmentation) }
        let required = ["leftEye", "rightEye", "leftEyebrow", "rightEyebrow", "outerLips", "nose"]
        guard required.allSatisfy({ (landmarks[$0]?.count ?? 0) >= 2 }), validLandmarks(landmarks),
              let crop = image.cropping(to: plan.pixels) else { return unavailable(.invalidInput) }
        guard approvedArtifact != nil, let url = modelURL(bundle: bundle), let manifest = manifestURL(bundle: bundle) else { return unavailable(.notBundled) }
        do {
            return try autoreleasepool {
                let manifestData = try Data(contentsOf: manifest)
                try validateManifest(manifestData)
                try Task.checkCancellation()
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuOnly // This is the execution mode actually verified by the pinned receipt.
                let model = try MLModel(contentsOf: url, configuration: configuration)
                let metadata = model.modelDescription.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String] ?? [:]
                try validateMetadata(metadata)
                guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
                      let output = model.modelDescription.outputDescriptionsByName["acneProbability"]?.multiArrayConstraint else { throw Failure.invalidModel }
                try validateConstraints(pixelsWide: constraint.pixelsWide, pixelsHigh: constraint.pixelsHigh,
                                        pixelFormat: constraint.pixelFormatType, outputDataType: output.dataType,
                                        declaredOutputShape: output.shape.map(\.intValue))
                try Task.checkCancellation()
                // The Core ML ImageType handles RGB 1/255; mean/std are already in the graph.
                // Core ML scaleFill resampling is not claimed pixel-identical to author OpenCV.
                // This fixed resize does NOT change the native-resolution eligibility.
                let input = try MLFeatureValue(cgImage: crop, constraint: constraint,
                                              options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
                let provider = try MLDictionaryFeatureProvider(dictionary: ["image": input])
                let prediction = try model.prediction(from: provider)
                try Task.checkCancellation()
                guard let array = prediction.featureValue(for: "acneProbability")?.multiArrayValue else { throw Failure.invalidOutput }
                let probabilities = try copyProbabilityMap(array, width: inputWidth, height: inputHeight)
                let result = try summarize(probabilities: probabilities, width: inputWidth, height: inputHeight,
                                           crop: plan.normalized, landmarks: landmarks, segmentation: segmentation)
                return Observation(state: .ready, nativeCropWidth: nativeWidth, nativeCropHeight: nativeHeight,
                                   elapsed: ProcessInfo.processInfo.systemUptime - started, statistics: result.statistics,
                                   overlay: result.overlay, source: source)
            }
        } catch is CancellationError { throw CancellationError() }
        catch Failure.invalidModel { return unavailable(.invalidModel) }
        catch Failure.insufficientSkin { return unavailable(.insufficientSkin) }
        catch Failure.invalidInput { return unavailable(.invalidInput) }
        catch { if Task.isCancelled { throw CancellationError() }; return unavailable(.inferenceFailed) }
    }

    /// NeuralNetwork conversion can omit a static output shape. This is not an empty tensor:
    /// only an omitted declaration or exact NCHW is accepted; actual prediction must be 4D.
    static func validateConstraints(pixelsWide: Int, pixelsHigh: Int, pixelFormat: OSType,
                                    outputDataType: MLMultiArrayDataType, declaredOutputShape: [Int]) throws {
        guard pixelsWide == inputWidth, pixelsHigh == inputHeight,
              pixelFormat == kCVPixelFormatType_32BGRA, outputDataType == .float32,
              declaredOutputShape.isEmpty || declaredOutputShape == [1, 1, inputHeight, inputWidth] else { throw Failure.invalidModel }
    }

    /// Copy NCHW output by its actual strides, never transposing width/height or treating padding
    /// bytes as pixels. The common contiguous case avoids 65K NSNumber bridging operations.
    static func copyProbabilityMap(_ array: MLMultiArray, width: Int, height: Int) throws -> [Float] {
        guard width > 0, height > 0, width <= inputWidth, height <= inputHeight,
              array.dataType == .float32, array.shape.map(\.intValue) == [1, 1, height, width],
              array.count == width * height else { throw Failure.invalidOutput }
        let values: [Float]
        if array.strides[3].intValue == 1 && array.strides[2].intValue == width {
            values = Array(UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Float.self), count: width * height))
        } else {
            values = (0..<(width * height)).map { i in
                array[[0, 0, NSNumber(value: i / width), NSNumber(value: i % width)]].floatValue
            }
        }
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalidOutput }
        return values
    }

    /// All model pixels participate in statistics. Display is a separately capped, exact subset
    /// of threshold-mask rectangles, not circles placed at estimated acne/lesion locations.
    static func summarize(probabilities: [Float], width: Int, height: Int, crop: CGRect,
                          landmarks: [String: [NormalizedPoint]], segmentation: FaceSegmentationService.Mask)
        throws -> (statistics: Statistics, overlay: OverlayLayer) {
        guard width > 0, height > 0, width <= inputWidth, height <= inputHeight,
              probabilities.count == width * height, validRect(crop), validLandmarks(landmarks),
              probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalidInput }
        let exclusions = exclusionRects(landmarks)
        let x0 = Double(crop.minX), y0 = Double(crop.minY)
        let dx = Double(crop.width) / Double(width), dy = Double(crop.height) / Double(height)
        let xs = (0..<width).map { x0 + (Double($0) + 0.5) * dx }
        let maskXs = xs.map { min(segmentation.width - 1, Int($0 * Double(segmentation.width))) }
        var candidates = [UInt8](repeating: 0, count: width * height)
        var validPixels = 0, candidatePixels = 0
        for y in 0..<height {
            if y % 16 == 0 { try Task.checkCancellation() }
            let py = y0 + (Double(y) + 0.5) * dy
            let row = min(segmentation.height - 1, Int(py * Double(segmentation.height))) * segmentation.width
            for x in 0..<width {
                let sample = row + maskXs[x], index = y * width + x
                guard segmentation.categories[sample] == FaceSegmentationService.Category.faceSkin.rawValue,
                      segmentation.confidence[3][sample] >= 0.65,
                      !exclusions.contains(where: { $0.contains(x: xs[x], y: py) }) else { continue }
                validPixels += 1
                if probabilities[index] > threshold { candidates[index] = 1; candidatePixels += 1 }
            }
        }
        guard validPixels >= max(1, width * height / 100) else { throw Failure.insufficientSkin }
        struct Run: Hashable { let left: Int; let right: Int }
        struct Rectangle { let left: Int; let right: Int; let top: Int; var bottom: Int
            var area: Int { (right - left) * (bottom - top) }
        }
        var rectangles: [Rectangle] = [], previousRuns: [Run: Int] = [:]
        for y in 0..<height {
            if y % 16 == 0 { try Task.checkCancellation() }
            var nextRuns: [Run: Int] = [:], x = 0
            while x < width {
                guard candidates[y * width + x] == 1 else { x += 1; continue }
                let start = x
                while x < width && candidates[y * width + x] == 1 { x += 1 }
                let run = Run(left: start, right: x)
                if let index = previousRuns[run] {
                    rectangles[index].bottom = y + 1; nextRuns[run] = index
                } else {
                    nextRuns[run] = rectangles.count
                    rectangles.append(Rectangle(left: start, right: x, top: y, bottom: y + 1))
                }
            }
            previousRuns = nextRuns
        }
        // Rectangles preserve only real positive cells. Never merge across a negative/masked gap.
        rectangles.sort {
            if $0.area != $1.area { return $0.area > $1.area }
            if $0.top != $1.top { return $0.top < $1.top }
            if $0.left != $1.left { return $0.left < $1.left }
            return $0.bottom < $1.bottom
        }
        let displayed = Array(rectangles.prefix(300))
        let paths = displayed.map { rect -> [NormalizedPoint] in
            let left = x0 + Double(rect.left) * dx, right = x0 + Double(rect.right) * dx
            let top = y0 + Double(rect.top) * dy, bottom = y0 + Double(rect.bottom) * dy
            return [.init(x: left, y: top), .init(x: right, y: top),
                    .init(x: right, y: bottom), .init(x: left, y: bottom)]
        }
        var componentCount = 0, queue: [Int] = []
        for seed in candidates.indices {
            if seed % 4096 == 0 { try Task.checkCancellation() }
            guard candidates[seed] == 1 else { continue }
            componentCount += 1; candidates[seed] = 0
            queue.removeAll(keepingCapacity: true); queue.append(seed)
            var cursor = 0
            while cursor < queue.count {
                if cursor % 4096 == 0 { try Task.checkCancellation() }
                let index = queue[cursor]; cursor += 1
                let x = index % width, y = index / width
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) {
                        let neighbor = ny * width + nx
                        if candidates[neighbor] == 1 { candidates[neighbor] = 0; queue.append(neighbor) }
                    }
                }
            }
        }
        let stats = Statistics(validSkinPixels: validPixels, candidatePixels: candidatePixels,
                               connectedComponents: componentCount, coveragePercent: Double(candidatePixels) / Double(validPixels) * 100)
        let visiblePixels = displayed.reduce(0) { $0 + $1.area }
        let note = "二值痘相关模型候选概率>0.20；不是痘痘诊断、黑头分类或真实痘数。仅统计语义面皮置信度≥0.65并排除Vision眼、眉、嘴唇和鼻孔后的全量256×256输出。8邻接连通片不是病灶数量。显示来自实际候选掩膜的至多300块矩形（1200点）；本次展示\(visiblePixels)/\(candidatePixels)候选网格像素，省略的显示不影响全量统计。像素格边缘不是精确皮损边界。原权重SHA256 " + weightSHA256 + "。"
        let overlay = OverlayLayer(id: overlayID, title: "专项模型 · 痘相关候选掩膜", colorHex: "F093AA", kind: .polygons,
                                   paths: paths, note: note, source: source)
        return (stats, overlay)
    }

    /// Same closed-boundary exclusions as FaceSegmentationService.Mask.excludesFeature, prepared
    /// once rather than allocating landmark-map arrays for each model output pixel.
    struct ExclusionRect {
        let left: Double, right: Double, top: Double, bottom: Double
        func contains(x: Double, y: Double) -> Bool { x >= left && x <= right && y >= top && y <= bottom }
    }

    static func exclusionRects(_ landmarks: [String: [NormalizedPoint]]) -> [ExclusionRect] {
        var result: [ExclusionRect] = []
        for key in ["leftEye", "rightEye", "leftEyebrow", "rightEyebrow", "outerLips", "innerLips"] {
            guard let points = landmarks[key], let left = points.map(\.x).min(), let right = points.map(\.x).max(),
                  let top = points.map(\.y).min(), let bottom = points.map(\.y).max() else { continue }
            let dx = max(0.004, (right - left) * 0.08), dy = max(0.004, (bottom - top) * 0.15)
            result.append(ExclusionRect(left: left - dx, right: right + dx, top: top - dy, bottom: bottom + dy))
        }
        if let points = landmarks["nose"], let left = points.map(\.x).min(), let right = points.map(\.x).max(),
           let top = points.map(\.y).min(), let bottom = points.map(\.y).max() {
            result.append(ExclusionRect(left: left - 0.003, right: right + 0.003, top: bottom - (bottom - top) * 0.22, bottom: bottom + 0.005))
        }
        return result
    }

    private static func validLandmarks(_ landmarks: [String: [NormalizedPoint]]) -> Bool {
        landmarks.values.allSatisfy { $0.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) } }
    }

    private static func validRect(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0 && rect.minX >= 0 && rect.maxX <= 1 && rect.minY >= 0 && rect.maxY <= 1
    }

    static func validateMetadata(_ metadata: [String: String]) throws {
        struct Normalization: Decodable { let mean: [Double]; let std: [Double] }
        guard metadata["ruyuan.repository"] == "RihemXX/Acnes", metadata["ruyuan.revision"] == revision,
              metadata["ruyuan.source_sha256"] == weightSHA256, metadata["ruyuan.compute_precision"] == computePrecision,
              let thresholdText = metadata["ruyuan.threshold"], Double(thresholdText) == 0.2,
              let data = metadata["ruyuan.normalization"]?.data(using: .utf8),
              let normalization = try? JSONDecoder().decode(Normalization.self, from: data),
              normalization.mean == [0.485, 0.456, 0.406], normalization.std == [0.229, 0.224, 0.225] else { throw Failure.invalidModel }
    }

    /// Source/model-byte pins come from a reviewed actual CPU conversion receipt, never from the
    /// resource being validated. Xcode then compiles the pinned .mlmodel to its .mlmodelc form.
    static func validateManifest(_ data: Data, approvedArtifact pin: ArtifactPin? = approvedArtifact) throws {
        struct Receipt: Decodable {
            struct Source: Decodable {
                struct File: Decodable { let path: String; let bytes: Int; let sha256: String }
                let repository: String; let revision: String; let license: String; let files: [File]
            }
            struct Resource: Decodable {
                let fileName: String; let bytes: Int; let sha256: String; let revision: String
                let inputName: String; let outputName: String; let outputShape: [Int]; let computePrecision: String; let threshold: Double
            }
            struct Input: Decodable {
                struct Normalization: Decodable { let mean: [Double]; let std: [Double] }
                let name: String; let width: Int; let height: Int; let colorLayout: String; let scale: Double; let bias: [Double]
                let embeddedNormalization: Normalization
            }
            struct Output: Decodable { let name: String; let dtype: String; let shape: [Int] }
            struct Validation: Decodable {
                struct Sample: Decodable {
                    struct Gate: Decodable { let threshold: Double; let maskDisagreementFraction: Double }
                    let name: String; let shape: [Int]; let maxAbsoluteProbabilityError: Double; let meanAbsoluteProbabilityError: Double; let thresholds: [Gate]
                }
                let samples: [Sample]
            }
            let schema: Int; let id: String; let state: String; let computePrecision: String; let modelType: String
            let source: Source; let resource: Resource; let input: Input; let output: Output; let threshold: Double; let validation: Validation
        }
        guard let pin, pin.sha256.count == 64, pin.sha256.allSatisfy({ "0123456789abcdef".contains($0) }), pin.bytes > 0,
              data.count <= 1_000_000, let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.schema == 1, receipt.id == "acne_segmentation", receipt.state == "converted_and_coreml_cpu_verified",
              receipt.computePrecision == computePrecision, receipt.modelType == "neuralNetwork", receipt.threshold == 0.2,
              receipt.source.repository == "RihemXX/Acnes", receipt.source.revision == revision, receipt.source.license == "Apache-2.0",
              receipt.source.files.filter({ $0.path == "Acnes_model.pth" }).count == 1,
              receipt.source.files.contains(where: { $0.path == "Acnes_model.pth" && $0.bytes == 97_920_000 && $0.sha256 == weightSHA256 }),
              receipt.resource.fileName == "AcneSegmentation.mlmodel", receipt.resource.bytes == pin.bytes, receipt.resource.sha256 == pin.sha256,
              receipt.resource.revision == revision, receipt.resource.computePrecision == computePrecision, receipt.resource.threshold == 0.2,
              receipt.resource.inputName == "image", receipt.resource.outputName == "acneProbability", receipt.resource.outputShape == [1, 1, inputHeight, inputWidth],
              receipt.input.name == "image", receipt.input.width == inputWidth, receipt.input.height == inputHeight, receipt.input.colorLayout == "RGB",
              receipt.input.scale.isFinite, abs(receipt.input.scale - 1.0 / 255.0) < 1e-15, receipt.input.bias == [0, 0, 0],
              receipt.input.embeddedNormalization.mean == [0.485, 0.456, 0.406], receipt.input.embeddedNormalization.std == [0.229, 0.224, 0.225],
              receipt.output.name == "acneProbability", receipt.output.dtype == "float32", receipt.output.shape == [1, 1, inputHeight, inputWidth],
              receipt.validation.samples.count == 5,
              Set(receipt.validation.samples.map(\.name)) == Set(["author_public_example", "uniform_skin_rgb", "uniform_dark_rgb", "uniform_light_rgb", "seeded_rgb_noise"]),
              receipt.validation.samples.allSatisfy({ sample in
                  sample.shape == [1, 1, inputHeight, inputWidth]
                    && sample.maxAbsoluteProbabilityError.isFinite && (0...0.001).contains(sample.maxAbsoluteProbabilityError)
                    && sample.meanAbsoluteProbabilityError.isFinite && (0...sample.maxAbsoluteProbabilityError).contains(sample.meanAbsoluteProbabilityError)
                    && sample.thresholds.count == 2 && Set(sample.thresholds.map(\.threshold)) == Set([0.2, 0.5])
                    && sample.thresholds.allSatisfy({ $0.maskDisagreementFraction.isFinite && (0...0.001).contains($0.maskDisagreementFraction) })
              }) else { throw Failure.invalidModel }
    }

    static func applying(_ observation: Observation, to original: AnalysisReport) -> AnalysisReport {
        var report = original
        guard let index = report.skin.firstIndex(where: { $0.dimension == .smoothness }) else { return report }
        let id = "trained-acne-segmentation", version = "Acnes@" + String(revision.prefix(12)) + "-coreml-cpu"
        let summary = "本次另完成本机二值痘相关像素模型；候选掩膜与连通片不等于诊断、分型或痘数。"
        report.skin[index].items.removeAll { [id, id + "-pixels", id + "-components"].contains($0.id) }
        report.overlays.removeAll { $0.id == overlayID }
        report.quality.removeAll { $0.id == "trainedAcneSegmentation" }
        // A later abstention must not retain a success claim from an earlier application.
        report.summary = report.summary.replacingOccurrences(of: summary, with: "")
        report.modelVersion = report.modelVersion.components(separatedBy: "; ").filter { $0 != version }.joined(separator: "; ")
        let stats = observation.statistics
        let validStatistics = stats.map {
            $0.validSkinPixels > 0 && $0.validSkinPixels <= inputWidth * inputHeight
                && $0.candidatePixels >= 0 && $0.candidatePixels <= $0.validSkinPixels
                && $0.connectedComponents >= 0 && $0.connectedComponents <= $0.candidatePixels
                && ($0.candidatePixels == 0 ? $0.connectedComponents == 0 : $0.connectedComponents > 0)
                && $0.coveragePercent.isFinite && abs($0.coveragePercent - Double($0.candidatePixels) / Double($0.validSkinPixels) * 100) < 1e-8
        } ?? false
        let validOverlay = observation.overlay.map { layer in
            layer.id == overlayID && layer.kind == .polygons && layer.paths.count <= 300
                && layer.paths.allSatisfy { path in
                    path.count == 4 && path.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }
                }
                && ((stats?.candidatePixels == 0) ? layer.paths.isEmpty : !layer.paths.isEmpty)
        } ?? false
        let ready = observation.state == .ready && observation.nativeCropWidth >= inputWidth && observation.nativeCropHeight >= inputHeight
            && observation.nativeCropWidth <= 8192 && observation.nativeCropHeight <= 8192
            && observation.elapsed.isFinite && observation.elapsed >= 0 && validStatistics && validOverlay
        let native = "原生面部裁剪\(observation.nativeCropWidth)×\(observation.nativeCropHeight)像素；最低256×256，不以插值补足门槛。"
        let note = source + "。" + native + "概率>0.20仅为二值候选；作者未披露完整训练图像/标注/授权来源；未复现独立自拍准确率或临床IoU。Core ML缩放非逐像素复现作者OpenCV裁剪流程。"
        if ready, let stats, let overlay = observation.overlay {
            report.skin[index].items.append(SkinItem(id: id, title: "专项模型 · 痘相关候选覆盖",
                valueText: String(format: "%.2f%%", stats.coveragePercent),
                note: note + String(format: "本次CPU加载、推理及统计%.2f秒。", observation.elapsed), overlayID: overlayID))
            report.skin[index].items.append(SkinItem(id: id + "-pixels", title: "模型候选像素 / 有效皮肤像素",
                valueText: "\(stats.candidatePixels) / \(stats.validSkinPixels)", note: "全量模型网格与真实语义面皮≥0.65交集，排除五官。" + note, overlayID: overlayID))
            report.skin[index].items.append(SkinItem(id: id + "-components", title: "模型连通候选片区",
                valueText: "\(stats.connectedComponents)片", note: "8邻接连通片不是痘痘/病灶个数；掩膜展示单独封顶，不影响全量统计。" + note, overlayID: overlayID))
            report.overlays.append(overlay)
            report.modelVersion += (report.modelVersion.isEmpty ? "" : "; ") + version
            report.summary += summary
        } else {
            let reason: String
            switch observation.state {
            case .lowResolution: reason = "原图面部像素不足，未运行；不靠插值生成结果"
            case .missingSegmentation: reason = "缺少真实语义面皮掩膜，未运行"
            case .notBundled: reason = "无已审批模型制品或转换校验资源，未运行"
            case .insufficientSkin: reason = "可靠语义皮肤区域不足，未给出数值"
            default: reason = "无有效结果 · " + (observation.state == .ready ? "invalid_output" : observation.state.rawValue)
            }
            report.skin[index].items.append(SkinItem(id: id, title: "专项模型 · 痘相关候选覆盖", valueText: reason, note: note, overlayID: nil))
        }
        report.quality.append(QualityCheck(id: "trainedAcneSegmentation", title: "本机二值痘相关像素模型", passed: ready,
            detail: ready ? "已在本照片可靠语义皮肤区域运行CPU模型；未覆盖原启发式细点、分型或分数。" : "本次没有可靠二值痘相关模型数值，不以零值或其他启发式冒充。"))
        return report
    }
}
