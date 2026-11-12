import CoreML
import CoreVideo
import Foundation
import UIKit
import Vision

/// Pinned author Pore-Net pixel probabilities, gated by actual semantic facial skin. This is not
/// a blackhead detector, physical pore count, dermatology diagnosis or skin-health score.
enum PoreNetService {
    static let revision = "6f851e0d911bd73f41dd905c685129b13d52e1bc"
    static let weightSHA256 = "a2d0f5f20eee45197612d55d2404ef988832dbcd50dc949bfcd16f5978711da7"
    static let convertedModelSHA256 = "30a8f1e7dc88ae540769c90d9527c3bd93b13f149b748652d0ff14ab390a129c"
    static let source = "Pore-Net author checkpoint; revision " + revision + "; original SHA256 " + weightSHA256 + "; Core ML CPU_ONLY float32; Apache-2.0"
    static let inputWidth = 1024, inputHeight = 1280
    static let threshold: Float = 0.25
    static let overlayID = "model-pore-net"

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
        /// Eight-neighbor connected components, not a physical/anatomical pore count.
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
        bundle.url(forResource: "PoreNet", withExtension: "mlmodelc", subdirectory: "Models")
            ?? bundle.url(forResource: "PoreNet", withExtension: "mlmodelc")
    }

    static func manifestURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "PoreNet-resource-manifest", withExtension: "json", subdirectory: "Models")
            ?? bundle.url(forResource: "PoreNet-resource-manifest", withExtension: "json")
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
        guard nativeWidth >= 512, nativeHeight >= 640 else { return unavailable(.lowResolution) }
        guard let segmentation else { return unavailable(.missingSegmentation) }
        let required = ["leftEye", "rightEye", "leftEyebrow", "rightEyebrow", "outerLips", "nose"]
        guard required.allSatisfy({ (landmarks[$0]?.count ?? 0) >= 2 }), validLandmarks(landmarks),
              let crop = image.cropping(to: plan.pixels) else { return unavailable(.invalidInput) }
        guard let url = modelURL(bundle: bundle), let manifest = manifestURL(bundle: bundle) else { return unavailable(.notBundled) }
        do {
            return try autoreleasepool {
                let manifestData = try Data(contentsOf: manifest)
                try validateManifest(manifestData)
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuOnly // Only this execution mode passed conversion parity.
                let model = try MLModel(contentsOf: url, configuration: configuration)
                let metadata = model.modelDescription.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String] ?? [:]
                try validateMetadata(metadata)
                guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
                      let output = model.modelDescription.outputDescriptionsByName["poreProbability"]?.multiArrayConstraint else { throw Failure.invalidModel }
                try validateConstraints(pixelsWide: constraint.pixelsWide, pixelsHigh: constraint.pixelsHigh,
                                        pixelFormat: constraint.pixelFormatType, outputDataType: output.dataType,
                                        declaredOutputShape: output.shape.map(\.intValue))
                try Task.checkCancellation()
                // The Core ML ImageType handles RGB 1/255; mean/std are already in the graph.
                // This fixed model resize does NOT change the native-resolution eligibility.
                let input = try MLFeatureValue(cgImage: crop, constraint: constraint,
                                              options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
                let provider = try MLDictionaryFeatureProvider(dictionary: ["image": input])
                let prediction = try model.prediction(from: provider)
                try Task.checkCancellation()
                guard let array = prediction.featureValue(for: "poreProbability")?.multiArrayValue else { throw Failure.invalidOutput }
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

    /// The approved .mlmodel (SHA 30a8f1e7...) serializes RGB1024x1280 + FLOAT32 output,
    /// but its neuralNetwork protobuf omits the output shape. An empty static constraint is not
    /// an empty prediction. Accept only that evidenced omission or the exact declared NCHW;
    /// copyProbabilityMap still requires the actual runtime tensor to be exact NCHW.
    static func validateConstraints(pixelsWide: Int, pixelsHigh: Int, pixelFormat: OSType,
                                    outputDataType: MLMultiArrayDataType, declaredOutputShape: [Int]) throws {
        guard pixelsWide == inputWidth, pixelsHigh == inputHeight,
              pixelFormat == kCVPixelFormatType_32BGRA, outputDataType == .float32,
              declaredOutputShape.isEmpty || declaredOutputShape == [1, 1, inputHeight, inputWidth] else { throw Failure.invalidModel }
    }

    /// Copy NCHW output by its actual strides, never transposing width/height or treating padding
    /// bytes as pixels. The common contiguous case avoids 1.3M NSNumber bridging operations.
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

    /// Full-resolution model-grid statistics. Display is capped separately to at most 300 actual
    /// candidate-component peak pixels in one points path; there is no sample-based area estimate.
    static func summarize(probabilities: [Float], width: Int, height: Int, crop: CGRect,
                          landmarks: [String: [NormalizedPoint]], segmentation: FaceSegmentationService.Mask)
        throws -> (statistics: Statistics, overlay: OverlayLayer) {
        guard width > 0, height > 0, width <= inputWidth, height <= inputHeight,
              probabilities.count == width * height, validRect(crop), validLandmarks(landmarks),
              probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalidInput }
        let exclusions = exclusionRects(landmarks)
        let x0 = Double(crop.minX), y0 = Double(crop.minY), dx = Double(crop.width) / Double(width), dy = Double(crop.height) / Double(height)
        let xs = (0..<width).map { x0 + (Double($0) + 0.5) * dx }
        let maskXs = xs.map { min(segmentation.width - 1, Int($0 * Double(segmentation.width))) }
        var candidates = [UInt8](repeating: 0, count: width * height)
        var validPixels = 0, candidatePixels = 0
        for y in 0..<height {
            if y % 32 == 0 { try Task.checkCancellation() }
            let py = y0 + (Double(y) + 0.5) * dy
            let maskRow = min(segmentation.height - 1, Int(py * Double(segmentation.height))) * segmentation.width
            for x in 0..<width {
                let sample = maskRow + maskXs[x], index = y * width + x
                guard segmentation.categories[sample] == FaceSegmentationService.Category.faceSkin.rawValue,
                      segmentation.confidence[3][sample] >= 0.65,
                      !exclusions.contains(where: { $0.contains(x: xs[x], y: py) }) else { continue }
                validPixels += 1
                if probabilities[index] > threshold { candidates[index] = 1; candidatePixels += 1 }
            }
        }
        guard validPixels >= max(1, width * height / 100) else { throw Failure.insufficientSkin }
        struct Component { let area: Int; let peak: Int }
        var components: [Component] = [], queue: [Int] = []
        // Queue storage is reused, so a single broad mask uses O(pixels) memory only once.
        for seed in candidates.indices {
            if seed % 16_384 == 0 { try Task.checkCancellation() }
            guard candidates[seed] == 1 else { continue }
            candidates[seed] = 0; queue.removeAll(keepingCapacity: true); queue.append(seed)
            var cursor = 0, peak = seed
            while cursor < queue.count {
                if cursor % 16_384 == 0 { try Task.checkCancellation() }
                let index = queue[cursor]; cursor += 1
                if probabilities[index] > probabilities[peak] || (probabilities[index] == probabilities[peak] && index < peak) { peak = index }
                let x = index % width, y = index / width
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) {
                        let neighbor = ny * width + nx
                        if candidates[neighbor] == 1 { candidates[neighbor] = 0; queue.append(neighbor) }
                    }
                }
            }
            components.append(Component(area: queue.count, peak: peak))
        }
        components.sort {
            if $0.area != $1.area { return $0.area > $1.area }
            if probabilities[$0.peak] != probabilities[$1.peak] { return probabilities[$0.peak] > probabilities[$1.peak] }
            return $0.peak < $1.peak
        }
        let points = components.prefix(300).map { item in
            NormalizedPoint(x: xs[item.peak % width], y: y0 + (Double(item.peak / width) + 0.5) * dy)
        }
        let stats = Statistics(validSkinPixels: validPixels, candidatePixels: candidatePixels,
                               connectedComponents: components.count, coveragePercent: Double(candidatePixels) / Double(validPixels) * 100)
        let note = "Pore-Net模型毛孔候选，概率>0.25；不是黑头分类。仅Google语义面部皮肤置信度≥0.65并排除Vision眼、眉、嘴唇和鼻孔后统计。全量1024×1280输出参与面积与8邻接连通片统计；连通片不等于真实毛孔个数。显示至多300个候选片区的真实峰值像素（先按片区面积排序），不代表完整掩膜或额外检出的点。原权重SHA256 " + weightSHA256 + "。"
        let overlay = OverlayLayer(id: overlayID, title: "专项模型 · 毛孔候选位置", colorHex: "9A81EE", kind: .points,
                                   paths: points.isEmpty ? [] : [points], note: note, source: source)
        return (stats, overlay)
    }

    /// Same closed-boundary exclusions as FaceSegmentationService.Mask.excludesFeature, prepared
    /// once rather than allocating landmark-map arrays for each of the 1.3M output pixels.
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
        guard metadata["ruyuan.repository"] == "ZombaSY/Pore-Net-release", metadata["ruyuan.revision"] == revision,
              metadata["ruyuan.source_sha256"] == weightSHA256, metadata["ruyuan.compute_precision"] == "float32",
              let thresholdText = metadata["ruyuan.threshold"], Double(thresholdText) == Double(threshold),
              let data = metadata["ruyuan.normalization"]?.data(using: .utf8),
              let normalization = try? JSONDecoder().decode(Normalization.self, from: data),
              normalization.mean == [0.512, 0.459, 0.353], normalization.std == [0.254, 0.226, 0.219] else { throw Failure.invalidModel }
    }

    /// The installer/CI pins original model bytes; Xcode compiles .mlmodel to .mlmodelc. At runtime
    /// require the matching CPU conversion receipt plus the compiled graph's source metadata.
    static func validateManifest(_ data: Data) throws {
        struct Receipt: Decodable {
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
            let resource: Resource; let input: Input; let output: Output; let threshold: Double; let validation: Validation
        }
        guard data.count <= 1_000_000, let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.schema == 1, receipt.id == "pore_net", receipt.state == "converted_and_coreml_cpu_verified",
              receipt.computePrecision == "float32", receipt.modelType == "neuralNetwork", receipt.threshold == 0.25,
              receipt.resource.fileName == "PoreNet.mlmodel", receipt.resource.bytes == 20_579,
              receipt.resource.sha256 == convertedModelSHA256,
              receipt.resource.revision == revision, receipt.resource.computePrecision == "float32", receipt.resource.threshold == 0.25,
              receipt.resource.inputName == "image", receipt.resource.outputName == "poreProbability", receipt.resource.outputShape == [1, 1, inputHeight, inputWidth],
              receipt.input.name == "image", receipt.input.width == inputWidth, receipt.input.height == inputHeight, receipt.input.colorLayout == "RGB",
              receipt.input.scale.isFinite, abs(receipt.input.scale - 1.0 / 255.0) < 1e-15, receipt.input.bias == [0, 0, 0],
              receipt.input.embeddedNormalization.mean == [0.512, 0.459, 0.353], receipt.input.embeddedNormalization.std == [0.254, 0.226, 0.219],
              receipt.output.name == "poreProbability", receipt.output.dtype == "float32", receipt.output.shape == [1, 1, inputHeight, inputWidth],
              receipt.validation.samples.count == 3,
              Set(receipt.validation.samples.map(\.name)) == Set(["author_public_example", "uniform_rgb", "seeded_rgb_noise"]),
              receipt.validation.samples.allSatisfy({ sample in
                  sample.shape == [1, 1, inputHeight, inputWidth]
                    && sample.maxAbsoluteProbabilityError.isFinite && (0...0.0001).contains(sample.maxAbsoluteProbabilityError)
                    && sample.meanAbsoluteProbabilityError.isFinite && (0...sample.maxAbsoluteProbabilityError).contains(sample.meanAbsoluteProbabilityError)
                    && sample.thresholds.count == 2 && Set(sample.thresholds.map(\.threshold)) == Set([0.25, 0.4])
                    && sample.thresholds.allSatisfy({ $0.maskDisagreementFraction.isFinite && (0...0.0001).contains($0.maskDisagreementFraction) })
              }) else { throw Failure.invalidModel }
    }

    static func applying(_ observation: Observation, to original: AnalysisReport) -> AnalysisReport {
        var report = original
        guard let index = report.skin.firstIndex(where: { $0.dimension == .smoothness }) else { return report }
        let id = "trained-pore-net"
        report.skin[index].items.removeAll { [id, id + "-pixels", id + "-components"].contains($0.id) }
        report.overlays.removeAll { $0.id == overlayID }
        report.quality.removeAll { $0.id == "trainedPoreNet" }
        let stats = observation.statistics
        let validStatistics = stats.map {
                $0.validSkinPixels > 0 && $0.candidatePixels >= 0 && $0.candidatePixels <= $0.validSkinPixels
                    && $0.connectedComponents >= 0 && $0.connectedComponents <= $0.candidatePixels
                    && ($0.candidatePixels == 0 ? $0.connectedComponents == 0 : $0.connectedComponents > 0)
                    && $0.coveragePercent.isFinite && abs($0.coveragePercent - Double($0.candidatePixels) / Double($0.validSkinPixels) * 100) < 1e-8
            } ?? false
        let ready = observation.state == .ready && observation.nativeCropWidth >= 512 && observation.nativeCropHeight >= 640
            && observation.elapsed.isFinite && observation.elapsed >= 0 && validStatistics
        let native = "原生面部裁剪\(observation.nativeCropWidth)×\(observation.nativeCropHeight)像素；最低512×640，模型固定RGB1024×1280。"
        let note = source + "。" + native + "模型候选阈值>0.25，不是黑头或真实毛孔计数；普通自拍上的独立临床/商业有效性尚未验证。"
        if ready, let stats {
            report.skin[index].items.append(SkinItem(id: id, title: "专项模型 · 毛孔候选覆盖",
                valueText: String(format: "%.2f%%", stats.coveragePercent),
                note: note + String(format: "本次CPU加载、推理及统计%.2f秒。", observation.elapsed), overlayID: overlayID))
            report.skin[index].items.append(SkinItem(id: id + "-pixels", title: "模型候选像素 / 有效皮肤像素",
                valueText: "\(stats.candidatePixels) / \(stats.validSkinPixels)", note: "只统计真实语义面皮≥0.65且排除五官后的全量模型像素。" + note, overlayID: overlayID))
            report.skin[index].items.append(SkinItem(id: id + "-components", title: "模型连通候选片区",
                valueText: "\(stats.connectedComponents)片", note: "按8邻接统计阈值掩膜连通片，不等于毛孔个数；仅显示至多300个片区峰值点。" + note, overlayID: overlayID))
            if let overlay = observation.overlay, overlay.id == overlayID,
               overlay.paths.count <= 300, overlay.paths.reduce(0, { $0 + $1.count }) <= 2000,
               overlay.paths.flatMap({ $0 }).allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) { report.overlays.append(overlay) }
            let version = "PoreNet@" + String(revision.prefix(12)) + "-coreml-cpu"
            if !report.modelVersion.contains(version) { report.modelVersion += "; " + version }
            if !report.summary.contains("另完成本机专项毛孔候选模型") { report.summary += "本次另完成本机专项毛孔候选模型；候选覆盖和连通片不等于黑头或真实毛孔计数。" }
        } else {
            let reason: String
            switch observation.state {
            case .lowResolution: reason = "原图面部像素不足，未运行；不靠插值生成毛孔结果"
            case .missingSegmentation: reason = "缺少真实语义面皮掩膜，未运行"
            case .notBundled: reason = "模型或转换校验资源缺失，未运行"
            case .insufficientSkin: reason = "可靠语义皮肤区域不足，未给出数值"
            default: reason = "无有效结果 · " + (observation.state == .ready ? "invalid_output" : observation.state.rawValue)
            }
            report.skin[index].items.append(SkinItem(id: id, title: "专项模型 · 毛孔候选覆盖", valueText: reason, note: note, overlayID: nil))
        }
        report.quality.append(QualityCheck(id: "trainedPoreNet", title: "本机专项毛孔像素模型", passed: ready,
            detail: ready ? "已在本照片可靠语义皮肤区运行CPU模型；未覆盖原有启发式细点项或分数。" : "本次没有可靠模型毛孔数值，不用零值或启发式结果冒充。"))
        return report
    }
}
