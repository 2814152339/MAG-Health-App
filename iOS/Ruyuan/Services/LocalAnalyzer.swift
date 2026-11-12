import Foundation
import UIKit
import Vision

/// Single-photo, on-device appearance baseline. This is not a diagnostic skin model.
/// The image persisted by the caller must be the same upright image passed here.
struct LocalAnalyzer {
    static func analyze(
        image: UIImage,
        reportID: String,
        imageFileName: String,
        progress: @escaping @Sendable (AnalysisStage) -> Void
    ) async throws -> AnalysisReport {
        // UIImage is immutable here; neither the caller nor this worker mutates it.
        let input = ImageInput(image: image)
        let worker = Task.detached(priority: .userInitiated) {
            try autoreleasepool {
                try run(image: input.image, reportID: reportID,
                        imageFileName: imageFileName, progress: progress)
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private final class ImageInput: @unchecked Sendable {
        let image: UIImage
        init(image: UIImage) { self.image = image }
    }

    private static func run(
        image: UIImage, reportID: String, imageFileName: String,
        progress: @escaping @Sendable (AnalysisStage) -> Void
    ) throws -> AnalysisReport {
        progress(.preparing)
        try Task.checkCancellation()
        guard let cgImage = uprightCGImage(image) else { throw AnalysisError.invalidImage }
        let width = cgImage.width
        let height = cgImage.height
        guard min(width, height) >= 320 else {
            throw AnalysisError.poorQuality("照片分辨率过低，请使用清晰原图（短边至少 320 像素）。")
        }

        progress(.quality)
        let request = VNDetectFaceLandmarksRequest()
        // The OS selects a supported revision; record the actual revision below.
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AnalysisError.poorQuality("本机人脸定位失败，请换一张光线均匀的正面照片重试。")
        }
        try Task.checkCancellation()
        let faces = request.results ?? []
        guard !faces.isEmpty else { throw AnalysisError.noFace }
        guard faces.count == 1 else { throw AnalysisError.multipleFaces }
        let face = faces[0]
        let box = face.boundingBox
        guard box.width >= 0.18,
              Double(box.width) * Double(width) >= 140,
              Double(box.height) * Double(height) >= 180 else {
            throw AnalysisError.poorQuality("人脸在照片中太小，请靠近镜头，保留完整面部。")
        }
        guard box.minX > 0.005, box.maxX < 0.995,
              box.minY > 0.005, box.maxY < 0.995 else {
            throw AnalysisError.poorQuality("面部贴近照片边缘，可能被裁切，请保留完整面部后重拍。")
        }
        let yaw = face.yaw?.doubleValue
        let roll = face.roll?.doubleValue
        let pitch = face.pitch?.doubleValue
        if let yaw, abs(yaw) > 20 * .pi / 180 {
            throw AnalysisError.poorQuality("面部侧转较多，请正对镜头后重拍。")
        }
        if let roll, abs(roll) > 18 * .pi / 180 {
            throw AnalysisError.poorQuality("头部倾斜较多，请保持水平后重拍。")
        }
        if let pitch, abs(pitch) > 20 * .pi / 180 {
            throw AnalysisError.poorQuality("抬头或低头幅度较大，请让镜头与双眼平齐。")
        }

        progress(.geometry)
        guard let features = face.landmarks else {
            throw AnalysisError.poorQuality("五官定位不足，请露出眉眼、鼻部和嘴唇，避免遮挡。")
        }
        var landmarkPaths = makeLandmarks(features, box: box)
        let lookup = Dictionary(uniqueKeysWithValues: landmarkPaths.map { ($0.id, $0.points) })
        guard (lookup["leftEye"]?.count ?? 0) >= 4,
              (lookup["rightEye"]?.count ?? 0) >= 4,
              (lookup["outerLips"]?.count ?? 0) >= 4,
              (lookup["faceContour"]?.count ?? 0) >= 8 else {
            throw AnalysisError.poorQuality("关键五官未完整定位，请移开遮挡、关闭美颜后重拍。")
        }
        var geometry = geometryMetrics(lookup, width: width, height: height) + FaceGeometryAnalyzer.metrics(landmarks: lookup, width: width, height: height)
        try Task.checkCancellation()

        progress(.skin)
        guard let raster = makeRaster(cgImage) else { throw AnalysisError.invalidImage }
        let appearance = sampleAppearance(raster, faceBox: box, landmarks: lookup)
        guard appearance.sampleCount >= 120 else {
            throw AnalysisError.poorQuality("可用面颊采样区域不足，请使用无遮挡的清晰正面照片。")
        }
        guard appearance.meanBrightness >= 0.14, appearance.meanBrightness <= 0.93 else {
            throw AnalysisError.poorQuality("面部过暗或过曝，请在均匀自然光下关闭滤镜后重拍。")
        }
        var quality = [
            QualityCheck(id: "oneFace", title: "单人面部", passed: true,
                         detail: "Apple Vision 检出 1 张人脸；未进行身份识别。"),
            QualityCheck(id: "resolution", title: "分辨率与面部大小", passed: true,
                         detail: "原图 \(width) × \(height)；人脸宽约 \(Int(Double(box.width) * Double(width))) 像素。"),
            QualityCheck(id: "framing", title: "画面边界", passed: true,
                         detail: "人脸检测框位于照片内；不代表发际线已被识别。"),
            QualityCheck(id: "pose", title: "正面姿态", passed: yaw != nil && roll != nil && pitch != nil,
                         detail: "Vision 弧度转角度：侧转 \(angleText(yaw))、倾斜 \(angleText(roll))、俯仰 \(angleText(pitch))。只筛查明显偏转，不做三维校正。"),
            QualityCheck(id: "exposure", title: "面颊亮度代理", passed: true,
                         detail: "采样 RGB 加权亮度 \(percent(appearance.meanBrightness))；是照片编码值，不是照度或肤色分级。"),
            QualityCheck(id: "sharpness", title: "清晰度参考", passed: appearance.laplacianVariance >= 12,
                         detail: String(format: "768像素长边工作图面部灰度拉普拉斯方差 %.1f；低于 12 仅提示可能模糊/低纹理，阈值未经临床或跨设备验证。", appearance.laplacianVariance))
        ]
        if appearance.clippedFraction > 0.10 {
            quality.append(QualityCheck(id: "clipping", title: "高光/暗部截断", passed: false,
                detail: "面颊采样中约 \(percent(appearance.clippedFraction)) 接近黑白截断，可能影响外观比较。"))
        }
        let featureSource = "Apple Vision VNDetectFaceLandmarksRequest revision \(request.revision)，系统 \(ProcessInfo.processInfo.operatingSystemVersionString)"
        var overlays = [OverlayLayer(
            id: "face-landmarks", title: "五官定位线", colorHex: "B29270", kind: .lines,
            paths: landmarkPaths.map { path in
                path.closed && !path.points.isEmpty ? path.points + [path.points[0]] : path.points
            },
            note: "由真实二维特征点形成；轮廓不包含发际线。坐标为原图左上角归一化坐标。", source: featureSource
        )]
        var segmentation: FaceSegmentationService.Mask?
        var segmentationNote = ""
        do {
            segmentation = try FaceSegmentationService.segment(raster: raster)
            quality.append(QualityCheck(id: "semanticSegmentation", title: "本机语义分割", passed: true,
                detail: FaceSegmentationService.source + "；真实输出背景/毛发/身体皮肤/面部皮肤/衣物/配饰六类。皮肤病变检测仍为照片外观公式，不冒充专项模型。"))
        } catch {
            try Task.checkCancellation()
            segmentationNote = (error as? FaceSegmentationService.Failure)?.localizedDescription ?? "本机语义分割运行失败；本次使用明确标注的几何ROI降级分析，未生成模型皮肤或毛发掩膜。"
            quality.append(QualityCheck(id: "semanticSegmentation", title: "本机语义分割未完成", passed: false, detail: segmentationNote))
        }
        try Task.checkCancellation()
        if let segmentation {
            overlays += segmentation.overlays(landmarks: lookup, faceBox: box)
            let boundary = segmentation.boundaryGeometry(landmarks: lookup, faceBox: box)
            geometry += boundary.metrics
            if let overlay = boundary.overlay { overlays.append(overlay) }
            if let path = boundary.path { landmarkPaths.append(path) }
            quality.append(QualityCheck(id: "visibleHairBoundary", title: "可见发肤边界", passed: boundary.path != nil,
                detail: boundary.path != nil ? "模型检出多列一致的毛发→额部皮肤边界；仅作可见三段比例，刘海可能遮住真实发际线，可手动复核。" : "没有足够稳定的毛发→额部皮肤边界；未猜测发际线或三庭，仍可手动标定。"))
        }
        let detailed = AppearanceAnalyzer.analyze(raster: raster, landmarks: lookup, faceBox: box, segmentation: segmentation)
        overlays += detailed.overlays
        overlays += FaceGeometryAnalyzer.overlays(landmarks: lookup, width: width, height: height)

        progress(.report)
        try Task.checkCancellation()
        let caution = quality.contains { !$0.passed }
        return AnalysisReport(
            id: reportID, createdAt: Date(), origin: .local,
            status: caution ? "已完成 · 有拍摄质量提示" : "已完成 · 照片外观参考",
            imageFileName: imageFileName, imageWidth: width, imageHeight: height,
            geometry: geometry, skin: detailed.metrics, landmarks: landmarkPaths,
            overlays: overlays, quality: quality,
            modelVersion: featureSource + "; " + AppearanceAnalyzer.version + "; FaceGeometry-v2; " + (segmentation != nil ? FaceSegmentationService.source : "semantic segmentation unavailable; geometric ROI fallback"),
            summary: segmentationNote + detailed.summary + (caution ? "本次有拍摄质量提示，建议在相同均匀光线下复拍比较。" : "")
        )
    }

    static func uprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let image = image.cgImage { return image }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    /// Vision points are relative to a bottom-left-origin face box.
    static func normalizedFacePoint(_ point: CGPoint, box: CGRect) -> NormalizedPoint {
        NormalizedPoint(x: clamp(Double(box.minX + point.x * box.width)),
                        y: clamp(Double(1 - (box.minY + point.y * box.height))))
    }

    private static func makeLandmarks(_ landmarks: VNFaceLandmarks2D, box: CGRect) -> [LandmarkPath] {
        let regions: [(String, VNFaceLandmarkRegion2D?, Bool)] = [
            ("faceContour", landmarks.faceContour, false),
            ("leftEye", landmarks.leftEye, true), ("rightEye", landmarks.rightEye, true),
            ("leftEyebrow", landmarks.leftEyebrow, false),
            ("rightEyebrow", landmarks.rightEyebrow, false),
            ("nose", landmarks.nose, true), ("noseCrest", landmarks.noseCrest, false),
            ("leftPupil", landmarks.leftPupil, false), ("rightPupil", landmarks.rightPupil, false),
            ("outerLips", landmarks.outerLips, true), ("innerLips", landmarks.innerLips, true)
        ]
        return regions.compactMap { id, region, closed in
            guard let region, region.pointCount > 0 else { return nil }
            let normalized = region.normalizedPoints
            return LandmarkPath(id: id, points: (0..<region.pointCount).map { index in
                let point = normalized[index]
                return normalizedFacePoint(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)), box: box)
            }, closed: closed)
        }
    }

    static func geometryMetrics(_ paths: [String: [NormalizedPoint]], width: Int, height: Int) -> [GeometryMetric] {
        func span(_ key: String) -> Double? {
            guard let points = paths[key], points.count >= 2,
                  let low = points.map(\.x).min(), let high = points.map(\.x).max() else { return nil }
            return (high - low) * Double(width)
        }
        func center(_ key: String) -> NormalizedPoint? {
            guard let points = paths[key], !points.isEmpty else { return nil }
            return NormalizedPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                                   y: points.map(\.y).reduce(0, +) / Double(points.count))
        }
        func verticalSpan(_ key: String) -> Double? {
            guard let points = paths[key], points.count >= 2,
                  let low = points.map(\.y).min(), let high = points.map(\.y).max() else { return nil }
            return (high - low) * Double(height)
        }
        func browTilt(_ key: String) -> Double? {
            guard let points = paths[key], points.count >= 2,
                  let left = points.min(by: { $0.x < $1.x }),
                  let right = points.max(by: { $0.x < $1.x }), right.x - left.x > 0.001 else { return nil }
            return atan2((left.y - right.y) * Double(height), (right.x - left.x) * Double(width)) * 180 / .pi
        }
        func verticalIntersections(_ key: String, x: Double) -> [Double] {
            guard let points = paths[key], points.count >= 3 else { return [] }
            var intersections: [Double] = []
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                guard x >= min(a.x, b.x), x <= max(a.x, b.x) else { continue }
                if abs(a.x - b.x) < 0.000001 {
                    if abs(x - a.x) < 0.000001 { intersections += [a.y, b.y] }
                } else {
                    let t = (x - a.x) / (b.x - a.x)
                    intersections.append(a.y + t * (b.y - a.y))
                }
            }
            return intersections
        }
        let lipBands: (upper: Double, lower: Double)? = {
            guard let outer = paths["outerLips"],
                  let minX = outer.map(\.x).min(), let maxX = outer.map(\.x).max() else { return nil }
            let x = (minX + maxX) / 2
            let outside = verticalIntersections("outerLips", x: x)
            let inside = verticalIntersections("innerLips", x: x)
            guard let upperOuter = outside.min(), let lowerOuter = outside.max(),
                  let upperInner = inside.min(), let lowerInner = inside.max(),
                  upperInner >= upperOuter, lowerInner <= lowerOuter else { return nil }
            return ((upperInner - upperOuter) * Double(height), (lowerOuter - lowerInner) * Double(height))
        }()
        let faceWidth = span("faceContour")
        let mouthWidth = span("outerLips")
        let eyeWidth = span("leftEye").flatMap { left in span("rightEye").map { (left + $0) / 2 } }
        let eyeDistance: Double? = center("leftEye").flatMap { left in
            center("rightEye").map { right in
                hypot((left.x - right.x) * Double(width), (left.y - right.y) * Double(height))
            }
        }
        let innerEyeDistance: Double? = {
            guard let a = paths["leftEye"], let b = paths["rightEye"],
                  let centerA = center("leftEye"), let centerB = center("rightEye"),
                  a.count >= 4, b.count >= 4 else { return nil }
            let imageLeft = centerA.x < centerB.x ? a : b
            let imageRight = centerA.x < centerB.x ? b : a
            guard let leftInner = imageLeft.max(by: { $0.x < $1.x }),
                  let rightInner = imageRight.min(by: { $0.x < $1.x }), rightInner.x > leftInner.x else { return nil }
            return hypot((rightInner.x - leftInner.x) * Double(width), (rightInner.y - leftInner.y) * Double(height))
        }()
        func ratio(_ id: String, _ title: String, _ numerator: Double?, _ denominator: Double?, _ definition: String) -> GeometryMetric {
            let value = numerator.flatMap { a in denominator.flatMap { b in b > 0.1 ? a / b : nil } }
            return GeometryMetric(id: id, title: title, value: value, unit: "",
                note: definition + (value == nil ? "相关特征点不足或边界不可靠，未计算。" : "均按原图宽高换算像素后求比，非毫米或审美标准；受表情与角度影响。"))
        }
        let contourDefinition = "轮廓横宽 = Vision faceContour 最大与最小 X 的像素差（不含发际线）；"
        let eyeNaming = "左/右沿用 Vision leftEye/rightEye 命名；"
        let browDefinition = "取该眉点集中图像 X 最小与最大点的连线，相对图像水平的 atan2 角度，向右上为正；不是眉峰角或医学左右判定。"
        let lipDefinition = "在外唇横向包络中线，与内外唇闭合折线做垂直相交；上段 = 内上界减外上界，下段 = 外下界减内下界；是二维轮廓厚度代理，不是组织厚度。"
        return [
            ratio("jaw-eye", "面部轮廓横宽 / 双眼中心距", faceWidth, eyeDistance,
                  contourDefinition + "双眼中心为各眼轮廓点均值，中心距为二维欧氏距离；"),
            ratio("eye-jaw", "平均眼裂横宽 / 面部轮廓横宽", eyeWidth, faceWidth,
                  contourDefinition + "眼裂横宽取眼轮廓 X 跨度，双眼求均值；"),
            ratio("eye-mouth", "双眼中心距 / 嘴宽", eyeDistance, mouthWidth,
                  "双眼轮廓点均值的二维欧氏距离 / outerLips X 跨度；"),
            ratio("nose-mouth", "鼻部轮廓横宽 / 嘴宽", span("nose"), mouthWidth,
                  "Vision nose X 跨度 / outerLips X 跨度；不等同于临床鼻翼宽；"),
            ratio("mouth-jaw", "嘴宽 / 面部轮廓横宽", mouthWidth, faceWidth,
                  contourDefinition + "嘴宽为 outerLips X 跨度；"),
            ratio("nose-jaw", "鼻部轮廓横宽 / 面部轮廓横宽", span("nose"), faceWidth,
                  contourDefinition + "鼻宽为 nose X 跨度，不等同于临床鼻翼宽；"),
            ratio("left-eye-aspect", "左眼轮廓高宽比", verticalSpan("leftEye"), span("leftEye"),
                  eyeNaming + "眼高为轮廓 Y 跨度 × 图高，眼宽为 X 跨度 × 图宽；"),
            ratio("right-eye-aspect", "右眼轮廓高宽比", verticalSpan("rightEye"), span("rightEye"),
                  eyeNaming + "眼高为轮廓 Y 跨度 × 图高，眼宽为 X 跨度 × 图宽；"),
            ratio("left-eye-width", "左眼横宽 / 面部轮廓横宽", span("leftEye"), faceWidth,
                  eyeNaming + contourDefinition + "眼宽取该眼轮廓 X 跨度；"),
            ratio("right-eye-width", "右眼横宽 / 面部轮廓横宽", span("rightEye"), faceWidth,
                  eyeNaming + contourDefinition + "眼宽取该眼轮廓 X 跨度；"),
            GeometryMetric(id: "left-brow-tilt", title: "左眉端点连线倾角", value: browTilt("leftEyebrow"), unit: "°",
                note: "左/右沿用 Vision 眉区命名；" + browDefinition),
            GeometryMetric(id: "right-brow-tilt", title: "右眉端点连线倾角", value: browTilt("rightEyebrow"), unit: "°",
                note: "左/右沿用 Vision 眉区命名；" + browDefinition),
            ratio("eye-inner-jaw", "双眼内侧极点距 / 面部轮廓横宽", innerEyeDistance, faceWidth,
                  contourDefinition + "先按图像左右排列眼区，取左区最右点与右区最左点的二维距离；不是经过人工标注的临床内眦距，眼区重叠时不计算；"),
            ratio("lip-height-width", "外唇轮廓高宽比", verticalSpan("outerLips"), mouthWidth,
                  "outerLips Y 像素跨度 / X 像素跨度；张嘴时包含唇间开口，非唇组织厚度；"),
            ratio("upper-lip-width", "中线上唇轮廓厚 / 嘴宽", lipBands?.upper, mouthWidth,
                  lipDefinition + "上段 / outerLips X 像素跨度；"),
            ratio("lower-lip-width", "中线下唇轮廓厚 / 嘴宽", lipBands?.lower, mouthWidth,
                  lipDefinition + "下段 / outerLips X 像素跨度；"),
            ratio("lip-upper-lower", "中线上下唇轮廓厚度比", lipBands?.upper, lipBands?.lower,
                  lipDefinition + "上段 / 下段；"),
            GeometryMetric(id: "thirds", title: "含发际线的三庭比例", value: nil, unit: "",
                note: "本机 Vision 不提供发际线定位，未测量，不用人脸框代替。"),
            GeometryMetric(id: "millimeters", title: "毫米尺寸", value: nil, unit: "",
                note: "没有标定尺、可靠深度与相机标定，无法由单张照片换算毫米。")
        ]
    }

    struct Raster {
        let width: Int
        let height: Int
        let pixels: [UInt8] // RGBA, row zero is the top of the upright CGImage.
        func rgb(x: Int, y: Int) -> (Double, Double, Double) {
            let index = (y * width + x) * 4
            return (Double(pixels[index]) / 255, Double(pixels[index + 1]) / 255, Double(pixels[index + 2]) / 255)
        }
    }

    static func makeRaster(_ image: CGImage) -> Raster? {
        let scale = min(1, 768 / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        return rendered ? Raster(width: width, height: height, pixels: pixels) : nil
    }

    private struct Appearance {
        var sampleCount = 0
        var meanBrightness = 0.0
        var brightnessDeviation = 0.0
        var highlightFraction = 0.0
        var rednessFraction = 0.0
        var clippedFraction = 0.0
        var redBaseline = 0.0
        var laplacianVariance = 0.0
        var regionPaths: [[NormalizedPoint]] = []
        var highlightPaths: [[NormalizedPoint]] = []
        var rednessPaths: [[NormalizedPoint]] = []
    }

    private struct Sample {
        let x: Int
        let y: Int
        let red: Double
        let green: Double
        let blue: Double
        var brightness: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
        var redShare: Double { red / max(0.001, red + green + blue) }
        var highlighted: Bool {
            let high = max(red, max(green, blue))
            let low = min(red, min(green, blue))
            return brightness >= 0.80 && high >= 0.92 && (high - low) / max(high, 0.001) <= 0.25
        }
    }

    private static func sampleAppearance(_ raster: Raster, faceBox: CGRect,
        landmarks: [String: [NormalizedPoint]]) -> Appearance {
        var result = Appearance()
        let eyePoints = (landmarks["leftEye"] ?? []) + (landmarks["rightEye"] ?? [])
        guard let eyeBottom = eyePoints.map(\.y).max(),
              let lipTop = landmarks["outerLips"]?.map(\.y).min() else { return result }
        let boxTop = Double(1 - faceBox.maxY)
        let faceHeight = Double(faceBox.height), faceWidth = Double(faceBox.width)
        let top = max(boxTop + faceHeight * 0.38, eyeBottom + faceHeight * 0.025)
        let bottom = min(boxTop + faceHeight * 0.78, lipTop + faceHeight * 0.035)
        guard bottom - top > 0.02 else { return result }
        let centerY = (top + bottom) / 2
        let radiusY = (bottom - top) / 2
        let radiusX = faceWidth * 0.115
        let centersX = [Double(faceBox.minX) + faceWidth * 0.255, Double(faceBox.minX) + faceWidth * 0.745]
        result.regionPaths = centersX.map { centerX in
            (0..<40).map { index in
                let angle = Double(index) * 2 * .pi / 40
                return NormalizedPoint(x: centerX + cos(angle) * radiusX, y: centerY + sin(angle) * radiusY)
            }
        }
        let step = 2
        var samples: [Sample] = []
        for y in stride(from: 0, to: raster.height, by: step) {
            for x in stride(from: 0, to: raster.width, by: step) {
                let nx = (Double(x) + 0.5) / Double(raster.width)
                let ny = (Double(y) + 0.5) / Double(raster.height)
                let inside = centersX.contains { cx in
                    pow((nx - cx) / radiusX, 2) + pow((ny - centerY) / radiusY, 2) <= 1
                }
                guard inside else { continue }
                let rgb = raster.rgb(x: x, y: y)
                samples.append(Sample(x: x, y: y, red: rgb.0, green: rgb.1, blue: rgb.2))
            }
        }
        guard !samples.isEmpty else { return result }
        result.sampleCount = samples.count
        let count = Double(samples.count)
        result.meanBrightness = samples.map(\.brightness).reduce(0, +) / count
        result.brightnessDeviation = sqrt(samples.reduce(0) { $0 + pow($1.brightness - result.meanBrightness, 2) } / count)
        let redShares = samples.map(\.redShare).sorted()
        result.redBaseline = redShares[redShares.count / 2]
        let highlighted = samples.filter(\.highlighted)
        let red = samples.filter { $0.redShare > result.redBaseline + 0.035 && $0.red > $0.green * 1.08 && $0.red > $0.blue * 1.08 && $0.brightness > 0.10 }
        result.highlightFraction = Double(highlighted.count) / count
        result.rednessFraction = Double(red.count) / count
        result.clippedFraction = Double(samples.filter { $0.brightness < 0.03 || min($0.red, min($0.green, $0.blue)) > 0.97 }.count) / count
        result.highlightPaths = sampleRuns(highlighted, raster: raster, step: step)
        result.rednessPaths = sampleRuns(red, raster: raster, step: step)
        // Numeric focus proxy at a fixed working resolution; it is not a pore/wrinkle model.
        func gray(_ x: Int, _ y: Int) -> Double {
            let rgb = raster.rgb(x: x, y: y)
            return (0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2) * 255
        }
        var laplacians: [Double] = []
        for sample in samples where sample.x > 0 && sample.y > 0 && sample.x < raster.width - 1 && sample.y < raster.height - 1 {
            let x = sample.x, y = sample.y
            laplacians.append(gray(x - 1, y) + gray(x + 1, y) + gray(x, y - 1) + gray(x, y + 1) - 4 * gray(x, y))
        }
        if !laplacians.isEmpty {
            let mean = laplacians.reduce(0, +) / Double(laplacians.count)
            result.laplacianVariance = laplacians.reduce(0) { $0 + pow($1 - mean, 2) } / Double(laplacians.count)
        }
        return result
    }

    private static func sampleRuns(_ samples: [Sample], raster: Raster, step: Int) -> [[NormalizedPoint]] {
        let rows = Dictionary(grouping: samples, by: \.y)
        var paths: [[NormalizedPoint]] = []
        for y in rows.keys.sorted() {
            let columns = rows[y]!.map(\.x).sorted()
            guard let first = columns.first else { continue }
            var start = first, end = first
            func appendRun() {
                let x0 = Double(start) / Double(raster.width)
                let x1 = Double(min(end + step, raster.width)) / Double(raster.width)
                let y0 = Double(y) / Double(raster.height)
                let y1 = Double(min(y + step, raster.height)) / Double(raster.height)
                paths.append([NormalizedPoint(x: x0, y: y0), NormalizedPoint(x: x1, y: y0),
                              NormalizedPoint(x: x1, y: y1), NormalizedPoint(x: x0, y: y1)])
            }
            for x in columns.dropFirst() {
                if x == end + step { end = x } else { appendRun(); start = x; end = x }
            }
            appendRun()
        }
        return paths
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
    private static func angleText(_ radians: Double?) -> String {
        radians.map { String(format: "%.1f°", $0 * 180 / .pi) } ?? "未提供"
    }
}
