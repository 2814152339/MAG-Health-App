import CoreML
import Foundation
import UIKit
import Vision

/// Pinned, trained classifiers. All image processing stays inside this process.
/// The image input embeds RGB 2/255 - 1; do not normalize twice.
enum SkinClassifierService {
    struct Spec: Sendable {
        let id: String
        let dimension: SkinDimension
        let title: String
        let revision: String
        let digest: String
        let classes: [String]
    }
    static let specs: [Spec] = [
        Spec(id: "acne", dimension: .smoothness, title: "训练模型 · 痘外观分类",
             revision: "f6ac6218b590f518d0a831472c7528b12bd53ae2",
             digest: "973ff1be5f2142c7daa6de784f39bf5838fdbaa73e816c107a1b8dafdc35571a",
             classes: ["level -1", "level 0", "level 1", "level 2", "level 3"]),
        Spec(id: "wrinkles", dimension: .aging, title: "训练模型 · 皱纹外观分类",
             revision: "32ddddd41a7e035bbe3abbe4510e0a0ca4b6fb12",
             digest: "b779f987998b90193cd855eed27243fd5ebf8aa8fce7e178d7570372b50dae1c",
             classes: ["non-wrinkle", "wrinkle"]),
        Spec(id: "skin_type", dimension: .waterOil, title: "训练模型 · 照片肤质分类",
             revision: "5aace4f4df0ba3265a07fbddab12a4ad38e0f6a6",
             digest: "572185743c6be523efcc72b71f12c089cb81baf54525a1831b333544ba47224a",
             classes: ["dry", "normal", "oily"])
    ]

    enum Failure: Error { case missingModel, metadataMismatch, invalidInput, invalidOutput }

    struct Observation: Sendable {
        let spec: Spec
        let probabilities: [Double]?
        let state: String
        let elapsed: Double
    }

    static func probabilities(logits: [Double]) throws -> [Double] {
        guard !logits.isEmpty, logits.allSatisfy(\.isFinite), let maximum = logits.max() else {
            throw Failure.invalidOutput
        }
        let exponentials = logits.map { exp($0 - maximum) }
        let denominator = exponentials.reduce(0, +)
        guard denominator.isFinite, denominator > 0 else { throw Failure.invalidOutput }
        return exponentials.map { $0 / denominator }
    }

    static func validateMetadata(_ metadata: [String: String], spec: Spec) throws {
        guard metadata["ruyuan.revision"] == spec.revision,
              metadata["ruyuan.source_sha256"] == spec.digest,
              let encoded = metadata["ruyuan.class_names"]?.data(using: .utf8),
              let classes = try? JSONDecoder().decode([String].self, from: encoded),
              classes == spec.classes else { throw Failure.metadataMismatch }
    }

    static func modelURL(spec: Spec, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: spec.id, withExtension: "mlmodelc")
            ?? bundle.url(forResource: spec.id, withExtension: "mlmodelc", subdirectory: "CoreML")
    }

    /// One model at a time, released immediately, to avoid retaining three ViTs.
    static func predict(image: CGImage, spec: Spec, bundle: Bundle = .main) throws -> [Double] {
        guard let url = modelURL(spec: spec, bundle: bundle) else { throw Failure.missingModel }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let metadata = model.modelDescription.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String] ?? [:]
        try validateMetadata(metadata, spec: spec)
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              constraint.pixelsWide == 224, constraint.pixelsHigh == 224,
              model.modelDescription.outputDescriptionsByName["logits"] != nil else { throw Failure.invalidInput }
        let input = try MLFeatureValue(cgImage: image, constraint: constraint,
                                      options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": input])
        let output = try model.prediction(from: provider)
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
              logits.count == spec.classes.count else { throw Failure.invalidOutput }
        return try probabilities(logits: (0..<logits.count).map { logits[$0].doubleValue })
    }

    /// Vision box: normalized bottom-left. CGImage crop: upright top-left pixels.
    static func faceCrop(_ image: CGImage, faceBox: CGRect) -> CGImage? {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let normalized = CGRect(x: faceBox.minX, y: 1 - faceBox.maxY,
                                width: faceBox.width, height: faceBox.height)
        guard normalized.minX.isFinite, normalized.minY.isFinite,
              normalized.width.isFinite, normalized.height.isFinite,
              normalized.width > 0, normalized.height > 0 else { return nil }
        let rect = CGRect(x: normalized.minX * full.width, y: normalized.minY * full.height,
                          width: normalized.width * full.width, height: normalized.height * full.height)
            .insetBy(dx: -normalized.width * full.width * 0.025, dy: -normalized.height * full.height * 0.025)
            .integral.intersection(full)
        guard rect.width >= 32, rect.height >= 32 else { return nil }
        return image.cropping(to: rect)
    }

    static func classify(image: CGImage, faceBox: CGRect) throws -> [Observation] {
        let crop = faceCrop(image, faceBox: faceBox)
        return try specs.map { spec in
            try Task.checkCancellation()
            let started = Date()
            return autoreleasepool {
                guard let crop else { return Observation(spec: spec, probabilities: nil, state: "invalid_input", elapsed: 0) }
                do {
                    let values = try predict(image: crop, spec: spec)
                    return Observation(spec: spec, probabilities: values, state: "ready", elapsed: Date().timeIntervalSince(started))
                } catch Failure.missingModel {
                    return Observation(spec: spec, probabilities: nil, state: "not_bundled", elapsed: 0)
                } catch Failure.metadataMismatch {
                    return Observation(spec: spec, probabilities: nil, state: "metadata_mismatch", elapsed: 0)
                } catch {
                    return Observation(spec: spec, probabilities: nil, state: "inference_failed", elapsed: Date().timeIntervalSince(started))
                }
            }
        }
    }

    static func applying(_ observations: [Observation], to original: AnalysisReport) -> AnalysisReport {
        var report = original
        var completed = 0
        for observation in observations {
            let spec = observation.spec
            guard let index = report.skin.firstIndex(where: { $0.dimension == spec.dimension }) else { continue }
            let baseID = "trained-" + spec.id
            report.skin[index].items.removeAll { $0.id == baseID || $0.id == baseID + "-distribution" }
            let provenance = "Core ML 本机推理；固定版本 \(spec.revision)，原权重 SHA256 \(spec.digest)。"
            guard let values = observation.probabilities, values.count == spec.classes.count,
                  let best = values.indices.max(by: { values[$0] < values[$1] }) else {
                report.skin[index].items.append(SkinItem(id: baseID, title: spec.title,
                    valueText: "未运行 · " + observation.state,
                    note: provenance + "本次没有分类结果，不补造类别或置信度。", overlayID: nil))
                continue
            }
            completed += 1
            let uncertain = values[best] < 0.60 ? "不确定候选 · " : ""
            let value = uncertain + spec.classes[best] + String(format: " · 模型置信度 %.1f%%", values[best] * 100)
            let note = provenance + String(format: "本次加载及推理 %.2f 秒。", observation.elapsed)
                + "输入为 Vision 检出的面部裁剪，RGB 缩放至224×224；整脸分类输出没有逐像素位置或病变计数。置信度是 softmax 概率，不是准确率、生理测量或健康分；低于0.60标为候选。"
            report.skin[index].items.append(SkinItem(id: baseID, title: spec.title, valueText: value, note: note, overlayID: nil))
            let distribution = zip(spec.classes, values).map { String(format: "%@ %.1f%%", $0.0, $0.1 * 100) }.joined(separator: " · ")
            report.skin[index].items.append(SkinItem(id: baseID + "-distribution", title: "模型类别分布",
                valueText: distribution, note: "保留模型原始类别顺序。" + provenance, overlayID: nil))
            report.modelVersion += "; \(spec.id)@\(spec.revision.prefix(12))-coreml-fp16"
        }
        report.quality.removeAll { $0.id == "trainedSkinModels" }
        report.quality.append(QualityCheck(id: "trainedSkinModels", title: "本机训练分类模型", passed: completed == specs.count,
            detail: "实际完成 \(completed)/\(specs.count) 个训练分类器；不将照片类别换算成含水量、皮脂量、肤龄或仪器评分。"))
        if completed > 0 { report.summary += "本次另完成\(completed)个本机训练分类器，原始类别和置信度见对应分项。" }
        return report
    }
}
