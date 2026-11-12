import Foundation
import UIKit

/// Deterministic photo-appearance features. No trained disease, hydration or sensitivity model.
/// All masks and values are computed from the same upright RGB raster; coordinates are top-left.
struct AppearanceAnalyzer {
    struct Result {
        let metrics: [SkinMetric]
        let overlays: [OverlayLayer]
        let summary: String
    }

    static let version = "RY-PhotoAppearance-v3"

    static func analyze(raster: LocalAnalyzer.Raster,
                        landmarks: [String: [NormalizedPoint]], faceBox: CGRect,
                        segmentation: FaceSegmentationService.Mask? = nil) -> Result {
        let source = version + "; sRGB/D65 Lab + fixed-threshold appearance features; " +
            (segmentation == nil ? "geometric ROI only; semantic model unavailable" : FaceSegmentationService.source + "; face-skin class 3 probability >= 0.65; Vision feature exclusions")
        let width = raster.width, height = raster.height
        guard width >= 8, height >= 8, width <= 2048, height <= 2048,
              raster.pixels.count == width * height * 4,
              faceBox.width > 0, faceBox.height > 0,
              faceBox.minX >= 0, faceBox.maxX <= 1,
              faceBox.minY >= 0, faceBox.maxY <= 1 else { return unavailable("照片像素或面部区域无效。") }
        let face = CGRect(x: faceBox.minX, y: 1 - faceBox.maxY,
                          width: faceBox.width, height: faceBox.height)
        guard let layout = Layout(face: face, paths: landmarks),
              face.width * Double(width) >= 100 else {
            return unavailable("面部采样区域或分辨率不足，请露出眉眼鼻唇并靠近拍摄。")
        }
        let size = width * height
        var l = [Double](repeating: 0, count: size)
        var a = l, b = l
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x, rgb = raster.rgb(x: x, y: y)
                let lab = labFromSRGB(red: rgb.0, green: rgb.1, blue: rgb.2)
                l[index] = lab.l; a[index] = lab.a; b[index] = lab.b
            }
        }
        // Seed the color gate only from central cheeks, away from the eyes, lips and jaw hair.
        var seed: [Int] = []
        for y in 0..<height {
            for x in 0..<width {
                let p = point(x, y, width, height), i = y * width + x
                if layout.cheeks.contains(where: { inEllipse(p, $0.insetBy(dx: $0.width * 0.17, dy: $0.height * 0.17)) }),
                   !layout.exclusions.contains(where: { $0.contains(p) }),
                   segmentation?.accepts(.faceSkin, x: Double(p.x), y: Double(p.y)) ?? true,
                   l[i] > 15, l[i] < 96 {
                    seed.append(i)
                }
            }
        }
        guard seed.count >= 80 else { return unavailable("面颊有效颜色样本不足；过曝、阴影、遮挡或妆容可能影响采样。") }
        let baseL = median(seed.map { l[$0] }), baseA = median(seed.map { a[$0] }), baseB = median(seed.map { b[$0] })
        var skin = [Bool](repeating: false, count: size)
        var zone = [UInt8](repeating: 0, count: size)
        var eligible = [Int](), cheekIndices = [Int](), underEyeIndices = [Int]()
        var excludedDarkEye = 0, totalEye = 0
        for y in 0..<height {
            for x in 0..<width {
                let p = point(x, y, width, height), i = y * width + x
                let semanticSkin = segmentation?.accepts(.faceSkin, x: Double(p.x), y: Double(p.y)) ?? true
                let gated = semanticSkin && l[i] > max(12, baseL - 32) && l[i] < 98 && abs(a[i] - baseA) <= 23 && abs(b[i] - baseB) <= 28
                if layout.underEyes.contains(where: { $0.contains(p) }) {
                    totalEye += 1
                    if l[i] < baseL - 28 || abs(a[i] - baseA) > 26 || abs(b[i] - baseB) > 30 { excludedDarkEye += 1 }
                    if gated { underEyeIndices.append(i) }
                }
                guard !layout.exclusions.contains(where: { $0.contains(p) }), gated else { continue }
                var region: UInt8 = 0
                if layout.cheeks.contains(where: { inEllipse(p, $0) }) { region = 1; cheekIndices.append(i) }
                if layout.forehead.contains(p) { region = 2 }
                if inEllipse(p, layout.nose) { region = 3 }
                if layout.glabella.contains(p) { region = 4 }
                if layout.nasolabial.contains(where: { $0.contains(p) }) { region = 5 }
                if layout.eyeSides.contains(where: { $0.contains(p) }) { region = 6 }
                if region != 0 { skin[i] = true; zone[i] = region; eligible.append(i) }
            }
        }
        guard eligible.count >= 200, cheekIndices.count >= 80 else {
            return unavailable("可用面部外观区域不足；请关闭美颜、移开头发与眼镜，使用均匀光线。")
        }
        let count = Double(eligible.count)
        let facePixelWidth = Double(face.width) * Double(width)
        let fineSampling = facePixelWidth >= 280 && max(width, height) >= 512
        let radius = max(2, Int(facePixelWidth * 0.025))
        let integral = Integral(values: l, width: width, height: height)
        let aIntegral = Integral(values: a, width: width, height: height)
        var highlight = skin.map { _ in false }, red = highlight, pigment = highlight, dot = highlight, noseDot = highlight
        var lineMasks = (0..<4).map { _ in [Bool](repeating: false, count: size) }
        var residuals = [Double](), chroma = [Double]()
        let meanA = mean(eligible.map { a[$0] }), meanB = mean(eligible.map { b[$0] })
        let ridgeStep = max(1, Int(facePixelWidth / 180))
        for i in eligible {
            let x = i % width, y = i / width
            let rgb = raster.rgb(x: x, y: y), high = max(rgb.0, max(rgb.1, rgb.2)), low = min(rgb.0, min(rgb.1, rgb.2))
            let localL = integral.average(x: x, y: y, radius: radius)
            let deltaL = localL - l[i]
            let localA = aIntegral.average(x: x, y: y, radius: radius)
            highlight[i] = l[i] >= 84 && high >= 0.91 && (high - low) / max(0.001, high) <= 0.28
            red[i] = a[i] > baseA + 7 && a[i] > localA + 2 && rgb.0 > rgb.1 * 1.06 && l[i] > 20
            // Brown/darker relative-color candidates, not a lesion/nevus classification.
            pigment[i] = deltaL > 6 && b[i] >= baseB - 3 && a[i] >= baseA - 8 && !red[i] && zone[i] != 3
            let fineDelta = integral.average(x: x, y: y, radius: max(2, radius / 2)) - l[i]
            if fineSampling && fineDelta > 7 && l[i] >= max(18, baseL - 28) {
                if zone[i] == 1 { dot[i] = true }
                if zone[i] == 3 { noseDot[i] = true }
            }
            residuals.append(l[i] - localL)
            chroma.append(pow(a[i] - meanA, 2) + pow(b[i] - meanB, 2))
            // Directional dark-ridge response. Strong hard edges/hair are rejected by contrast cap.
            guard x >= ridgeStep, y >= ridgeStep, x + ridgeStep < width, y + ridgeStep < height else { continue }
            let horizontal = (l[i - ridgeStep] + l[i + ridgeStep]) / 2 - l[i]
            let vertical = (l[i - ridgeStep * width] + l[i + ridgeStep * width]) / 2 - l[i]
            let diagonal1 = (l[i - ridgeStep * width - ridgeStep] + l[i + ridgeStep * width + ridgeStep]) / 2 - l[i]
            let diagonal2 = (l[i - ridgeStep * width + ridgeStep] + l[i + ridgeStep * width - ridgeStep]) / 2 - l[i]
            let response = max(horizontal, max(vertical, max(diagonal1, diagonal2)))
            guard response > 2.5, response < 16, deltaL > 1.5, deltaL < 18, !red[i] else { continue }
            if zone[i] == 2 { lineMasks[0][i] = true }
            if zone[i] == 4 { lineMasks[1][i] = true }
            if zone[i] == 5 { lineMasks[2][i] = true }
            if zone[i] == 6 { lineMasks[3][i] = true }
        }
        let minSpot = max(3, Int(facePixelWidth * facePixelWidth * 0.000015))
        let maxSpot = max(minSpot, Int(facePixelWidth * facePixelWidth * 0.012))
        let redComponents = components(red, width: width, height: height, minSize: minSpot, maxSize: maxSpot)
        let pigmentComponents = components(pigment, width: width, height: height, minSize: minSpot, maxSize: maxSpot)
        let dotMax = max(4, Int(facePixelWidth * facePixelWidth * 0.0007))
        let dotComponents = components(dot, width: width, height: height, minSize: 2, maxSize: dotMax)
        let noseComponents = components(noseDot, width: width, height: height, minSize: 2, maxSize: dotMax)
        let redKept = componentMask(redComponents, size: size)
        let pigmentKept = componentMask(pigmentComponents, size: size)
        let dotKept = componentMask(dotComponents, size: size)
        let noseKept = componentMask(noseComponents, size: size)
        let highlightFraction = Double(highlight.filter { $0 }.count) / count
        let redFraction = Double(redKept.filter { $0 }.count) / count
        let pigmentFraction = Double(pigmentKept.filter { $0 }.count) / count
        let dotFraction = Double(dotKept.filter { $0 }.count) / count
        let residualSD = deviation(residuals)
        let chromaSD = sqrt(chroma.reduce(0, +) / count)
        let meanL = mean(eligible.map { l[$0] })
        let ita: Double? = meanB > 0.1 ? atan2(meanL - 50, meanB) * 180 / .pi : nil
        let toneScore = bounded(100 - 2 * chromaSD - 300 * pigmentFraction)
        let smoothScore: Double? = fineSampling ? bounded(100 - 8 * residualSD - 500 * dotFraction) : nil
        let lineCounts = lineMasks.map { $0.filter { $0 }.count }
        let lineFraction = Double(lineCounts.reduce(0, +)) / count
        let lineScore = bounded(100 - 600 * lineFraction)
        let underOccluded = totalEye == 0 || Double(excludedDarkEye) / Double(max(1, totalEye)) > 0.12
        let underDelta: Double? = !underOccluded && underEyeIndices.count >= 24
            ? mean(cheekIndices.map { l[$0] }) - mean(underEyeIndices.map { l[$0] }) : nil
        let scope = "面部采样经面颊颜色门控后 \(eligible.count) 像素；眼、眉、唇、鼻孔和下巴胡须区排除。" +
            (segmentation == nil ? "本次语义模型不可用，仅使用几何ROI；妆容/镜框/毛发/阴影仍可能干扰。" : "已与Google真实六分类模型的面部皮肤类（置信度≥0.65）取交集，排除毛发、身体皮肤、衣物与配饰类；仍不保证精确分割或排除妆容/阴影。")
        let scoreScope = "仅本照片视觉参考，非健康、治疗、年龄或仪器测量分；拍摄条件改变会改变数值。"
        var overlays: [OverlayLayer] = []
        func add(_ id: String, _ title: String, _ color: String, _ mask: [Bool], _ note: String, limit: Int = 650) {
            let rendered = maskRuns(mask, width: width, height: height, limit: limit)
            overlays.append(OverlayLayer(id: id, title: title, colorHex: color, kind: .polygons,
                paths: rendered.paths, note: note + (rendered.truncated ? " 图层碎片较多，仅显示按图像行序的前 \(limit) 段；统计仍使用全部候选。" : " 未出现颜色表示没有达到阈值的候选。"), source: source))
        }
        add("appearance-highlight", "高亮外观", "FFE45E", highlight, "L*≥84、maxRGB≥0.91、HSV饱和度≤0.28；是反光像素，不是皮脂测量。")
        add("appearance-redness", "相对偏红外观", "EF6B78", redKept, "a*高于面颊基线7且高于局部2，R>1.06G；保留连通区域\(minSpot)…\(maxSpot)像素。不是敏感/炎症/痘痘判定。")
        add("appearance-pigment", "相对色沉候选", "A97542", pigmentKept, "局部L*差>6且满足相对a*/b*门控，保留连通区域\(minSpot)…\(maxSpot)像素；可含阴影/妆容，不判断痣、色斑病变类型。")
        add("appearance-dots", "面颊细小暗点候选", "568FC6", dotKept, "细尺度局部L*差>7；连通2…\(dotMax)像素，面部横宽至少280像素才启用。不是经过标注模型确认的毛孔。")
        add("appearance-nose-dots", "鼻部细小暗点候选", "705B9A", noseKept, "仅鼻梁/上鼻部几何ROI，排除鼻底鼻孔；细尺度局部L*差>7、连通2…\(dotMax)像素。不是黑头病理分类。")
        let lineNames = ["额部", "眉间", "鼻唇侧", "眼外侧"]
        let lineIDs = ["forehead", "glabella", "nasolabial", "eye"]
        for index in 0..<4 {
            add("appearance-lines-" + lineIDs[index], lineNames[index] + "线状纹理响应", "8A81D9", lineMasks[index],
                "多方向暗脊响应2.5…16 L*，局部L*差1.5…18，间隔\(ridgeStep)像素。只代表可见线状纹理，排除区域外不分析；不是皱纹等级或组织松弛测量。", limit: 450)
        }
        var underMask = [Bool](repeating: false, count: size)
        if let delta = underDelta, delta > 3 { for i in underEyeIndices { underMask[i] = true } }
        add("appearance-under-eye", "眼下相对明暗区域", "8677B9", underMask,
            "眼下与双颊平均L*作差；差值>3时显示有效眼下ROI，不区分黑眼圈成因、眼袋、泪沟或疾病。深色遮挡比例>12%时停止比较。", limit: 350)
        var roiMask = [Bool](repeating: false, count: size)
        for i in eligible { roiMask[i] = true }
        add("appearance-roi", "有效外观采样区", "78BFA5", roiMask, scope, limit: 550)
        let unavailableFine = "采样分辨率不足（当前面部横宽约\(Int(facePixelWidth))像素，要求≥280且工作图长边≥512）；不强行计数。"
        let lineItems = (0..<4).map { index in
            SkinItem(id: "line-" + lineIDs[index], title: lineNames[index] + "线纹响应",
                     valueText: percent(Double(lineCounts[index]) / count),
                     note: "该区达到暗脊阈值的像素 / 全部有效外观像素。阈值与间隔详见图层；是纹理响应面积，不是皱纹根数。", overlayID: "appearance-lines-" + lineIDs[index])
        }
        let metrics = [
            SkinMetric(dimension: .waterOil, score: nil, status: "照片高亮外观", items: [
                SkinItem(id: "highlight", title: "高亮外观覆盖", valueText: percent(highlightFraction), note: scope + "高亮阈值详见图层；反光可来自灯光、护肤品、油光与妆容。", overlayID: "appearance-highlight"),
                SkinItem(id: "hydration", title: "含水量 / 皮脂量", valueText: "需仪器采集", note: "本算法没有水分、皮脂仪数据；不将反光比例换算为含水量或皮脂量。", overlayID: nil)
            ]),
            SkinMetric(dimension: .tone, score: toneScore, status: "色彩均匀视觉参考分", items: [
                SkinItem(id: "lab", title: "照片平均 Lab", valueText: String(format: "L* %.1f · a* %.1f · b* %.1f", meanL, meanA, meanB), note: "sRGB先线性化，再转D65 XYZ及CIELAB。无色卡校准；反映照片编码颜色，不是皮肤反射率。" + scope, overlayID: "appearance-roi"),
                SkinItem(id: "ita", title: "照片 ITA 参考角", valueText: ita.map { String(format: "%.1f°", $0) } ?? "b*过低，未计算", note: "b*>0.1时atan2(L*−50,b*)×180/π；不据此推断种族或固定肤色类型。", overlayID: "appearance-roi"),
                SkinItem(id: "pigment-candidates", title: "相对色沉候选", valueText: "\(pigmentComponents.count)处 · \(percent(pigmentFraction))", note: "固定阈值连通块数量及有效采样覆盖率；不区分雀斑、痣、色斑或阴影。", overlayID: "appearance-pigment"),
                SkinItem(id: "tone-formula", title: "视觉参考分计算", valueText: String(format: "%.1f / 100", toneScore), note: "clamp(100−2×sqrt(var(a*)+var(b*))−300×色沉候选覆盖率,0,100)。" + scoreScope, overlayID: "appearance-roi")
            ]),
            SkinMetric(dimension: .sensitivity, score: nil, status: "相对偏红照片外观", items: [
                SkinItem(id: "redness", title: "相对偏红候选", valueText: "\(redComponents.count)处 · \(percent(redFraction))", note: "只比较本照片相对a*与RGB差异；不将候选分型为痘痘、红血丝或炎症。", overlayID: "appearance-redness"),
                SkinItem(id: "barrier", title: "敏感性 / 屏障", valueText: "待问卷与专业评估", note: "外观颜色没有提供病史、刺激反应或屏障仪器数据，不生成敏感评分。", overlayID: nil)
            ]),
            SkinMetric(dimension: .smoothness, score: smoothScore, status: fineSampling ? "纹理平整视觉参考分" : "需更清晰的近距照片", items: [
                SkinItem(id: "pore-candidates", title: "面颊细小暗点（毛孔样）", valueText: fineSampling ? "\(dotComponents.count)处 · \(percent(dotFraction))" : "分辨率不足", note: fineSampling ? "固定局部暗点连通块，可能包含毛孔、毛发、压缩噪声或妆容；不是毛孔模型计数。" : unavailableFine, overlayID: "appearance-dots"),
                SkinItem(id: "nose-dark-candidates", title: "鼻部细小暗点", valueText: fineSampling ? "\(noseComponents.count)处" : "分辨率不足", note: fineSampling ? "鼻梁/上鼻部暗点候选，鼻孔区域排除；不自动认作黑头。" : unavailableFine, overlayID: "appearance-nose-dots"),
                SkinItem(id: "texture", title: "局部亮度纹理离散", valueText: String(format: "%.2f L*", residualSD), note: "有效像素L*减去半径\(radius)方窗均值后的标准差；清晰度、噪声、妆容也会改变结果。", overlayID: "appearance-roi"),
                SkinItem(id: "smooth-formula", title: "视觉参考分计算", valueText: smoothScore.map { String(format: "%.1f / 100", $0) } ?? "待更清晰照片", note: "clamp(100−8×局部亮度纹理标准差−500×细点覆盖率,0,100)。仅达到采样分辨率时给分。" + scoreScope, overlayID: "appearance-dots")
            ]),
            SkinMetric(dimension: .aging, score: lineScore, status: "线纹视觉参考分 · 非年龄", items: lineItems + [
                SkinItem(id: "under-eye", title: "眼下相对明暗差", valueText: underDelta.map { String(format: "%.1f L*", $0) } ?? "眼周遮挡或样本不足", note: "双颊平均L*−眼下平均L*；正值表示本图眼下更暗。不是黑眼圈类型、眼袋或泪沟诊断。", overlayID: "appearance-under-eye"),
                SkinItem(id: "aging-formula", title: "线纹视觉参考分计算", valueText: String(format: "%.1f / 100", lineScore), note: "clamp(100−600×四区线纹响应总像素/全部有效像素,0,100)。不估计生理年龄、弹性或衰老速度。" + scoreScope, overlayID: "appearance-lines-forehead")
            ])
        ]
        let sourcedMetrics = metrics.map { metric in
            var result = metric
            if result.score != nil { result.scoreSource = "photoHeuristic" }
            return result
        }
        return Result(metrics: sourcedMetrics, overlays: overlays,
            summary: (segmentation == nil ? "语义皮肤模型本次未运行；使用几何采样区作降级分析。" : "已由本机Google六分类预训练模型分离面部皮肤、毛发与配饰，并排除眼眉唇鼻孔后采样。") + "已完成面部颜色、相对高亮/偏红/色沉候选、分区线纹与眼下明暗外观分析。\(fineSampling ? "已按当前采样尺度提取面颊与鼻部细小暗点候选。" : unavailableFine)外观候选仍来自真实像素与公开公式，不是皮肤病变分类模型；视觉参考分不代表含水量、敏感性、病理类型或年龄。\(underOccluded ? "眼周存在深色遮挡线索，未强行做眼下比较。" : "")")
    }

    static func labFromSRGB(red: Double, green: Double, blue: Double) -> (l: Double, a: Double, b: Double) {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let r = linear(red), g = linear(green), b = linear(blue)
        let x = (0.4124564*r + 0.3575761*g + 0.1804375*b) / 0.95047
        let y = 0.2126729*r + 0.7151522*g + 0.0721750*b
        let z = (0.0193339*r + 0.1191920*g + 0.9503041*b) / 1.08883
        func f(_ value: Double) -> Double { value > 216.0 / 24389 ? pow(value, 1.0 / 3) : (24389.0 / 27 * value + 16) / 116 }
        return (116*f(y)-16, 500*(f(x)-f(y)), 200*(f(y)-f(z)))
    }

    private struct Layout {
        let cheeks: [CGRect], forehead: CGRect, nose: CGRect, glabella: CGRect
        let nasolabial: [CGRect], eyeSides: [CGRect], underEyes: [CGRect], exclusions: [CGRect]
        init?(face: CGRect, paths: [String: [NormalizedPoint]]) {
            func bounds(_ name: String) -> CGRect? {
                guard let points = paths[name], points.count >= 3,
                      let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                      let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX else { return nil }
                return CGRect(x: minX, y: minY, width: maxX-minX, height: max(0.001, maxY-minY))
            }
            guard let le = bounds("leftEye"), let re = bounds("rightEye"),
                  let lips = bounds("outerLips"), let n = bounds("nose"),
                  let lb = bounds("leftEyebrow"), let rb = bounds("rightEyebrow") else { return nil }
            let fw = face.width, fh = face.height, eyeBottom = max(le.maxY, re.maxY)
            let cheekTop = eyeBottom + fh * 0.045, cheekBottom = min(lips.minY - fh * 0.015, face.minY + fh * 0.80)
            guard cheekBottom > cheekTop, lips.minY > eyeBottom else { return nil }
            cheeks = [0.26, 0.74].map { fraction in CGRect(x: face.minX + fw*fraction - fw*0.115,
                y: cheekTop, width: fw*0.23, height: cheekBottom-cheekTop) }
            let browTop = min(lb.minY, rb.minY)
            forehead = CGRect(x: face.minX+fw*0.24, y: max(face.minY+fh*0.09, browTop-fh*0.23),
                width: fw*0.52, height: max(0, browTop-fh*0.035-max(face.minY+fh*0.09, browTop-fh*0.23)))
            nose = CGRect(x: n.minX+n.width*0.27, y: n.minY+max(0.003, n.height*0.05), width: n.width*0.46, height: n.height*0.63)
            let sortedEyes = [le, re].sorted { $0.midX < $1.midX }
            glabella = CGRect(x: sortedEyes[0].maxX+fw*0.025, y: browTop+fh*0.01,
                width: max(0, sortedEyes[1].minX-sortedEyes[0].maxX-fw*0.05), height: max(0, min(le.minY,re.minY)-browTop-fh*0.02))
            nasolabial = [CGRect(x:n.minX-fw*0.09,y:n.midY,width:fw*0.07,height:max(0,lips.minY-n.midY)),
                          CGRect(x:n.maxX+fw*0.02,y:n.midY,width:fw*0.07,height:max(0,lips.minY-n.midY))]
            eyeSides = [CGRect(x:sortedEyes[0].minX-fw*0.09,y:sortedEyes[0].midY,width:fw*0.065,height:fh*0.11),
                        CGRect(x:sortedEyes[1].maxX+fw*0.025,y:sortedEyes[1].midY,width:fw*0.065,height:fh*0.11)]
            underEyes = [le,re].map { CGRect(x:$0.minX+$0.width*0.12,y:$0.maxY+fh*0.025,width:$0.width*0.76,height:fh*0.065) }
            exclusions = [le.insetBy(dx:-fw*0.018,dy:-fh*0.018),re.insetBy(dx:-fw*0.018,dy:-fh*0.018),
                          lb.insetBy(dx:-fw*0.02,dy:-fh*0.02),rb.insetBy(dx:-fw*0.02,dy:-fh*0.02),
                          lips.insetBy(dx:-fw*0.035,dy:-fh*0.035),
                          CGRect(x:n.minX-fw*0.02,y:n.minY+n.height*0.77,width:n.width+fw*0.04,height:n.height*0.3)]
        }
    }
    private struct Integral {
        let width: Int, height: Int, values: [Double]
        init(values input: [Double], width: Int, height: Int) {
            self.width = width; self.height = height
            var output = [Double](repeating: 0, count: (width+1)*(height+1))
            for y in 0..<height {
                var row = 0.0
                for x in 0..<width { row += input[y*width+x]; output[(y+1)*(width+1)+x+1] = output[y*(width+1)+x+1]+row }
            }
            values = output
        }
        func average(x: Int, y: Int, radius: Int) -> Double {
            let x0=max(0,x-radius), x1=min(width,x+radius+1), y0=max(0,y-radius), y1=min(height,y+radius+1), stride=width+1
            return (values[y1*stride+x1]-values[y0*stride+x1]-values[y1*stride+x0]+values[y0*stride+x0]) / Double((x1-x0)*(y1-y0))
        }
    }
    private static func components(_ input: [Bool], width: Int, height: Int, minSize: Int, maxSize: Int) -> [[Int]] {
        var seen = [Bool](repeating:false,count:input.count), result:[[Int]]=[]
        for start in input.indices where input[start] && !seen[start] {
            var queue=[start], read=0
            seen[start]=true
            while read<queue.count {
                let current=queue[read]; read+=1
                let x=current%width,y=current/width
                for (nx,ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where nx>=0 && ny>=0 && nx<width && ny<height {
                    let next=ny*width+nx
                    if input[next] && !seen[next] { seen[next]=true;queue.append(next) }
                }
            }
            if queue.count>=minSize && queue.count<=maxSize { result.append(queue) }
        }
        return result
    }
    private static func componentMask(_ components: [[Int]], size: Int) -> [Bool] {
        var output=[Bool](repeating:false,count:size)
        for component in components { for i in component { output[i]=true } }
        return output
    }
    private static func maskRuns(_ mask:[Bool],width:Int,height:Int,limit:Int) -> (paths:[[NormalizedPoint]],truncated:Bool) {
        var paths:[[NormalizedPoint]]=[]
        for y in 0..<height {
            var x=0
            while x<width {
                guard mask[y*width+x] else { x+=1;continue }
                let start=x
                while x<width && mask[y*width+x] { x+=1 }
                if paths.count==limit { return (paths,true) }
                let x0=Double(start)/Double(width),x1=Double(x)/Double(width),y0=Double(y)/Double(height),y1=Double(y+1)/Double(height)
                paths.append([.init(x:x0,y:y0),.init(x:x1,y:y0),.init(x:x1,y:y1),.init(x:x0,y:y1)])
            }
        }
        return (paths,false)
    }
    private static func inEllipse(_ p:CGPoint,_ r:CGRect) -> Bool {
        r.width>0 && r.height>0 && pow((p.x-r.midX)/(r.width/2),2)+pow((p.y-r.midY)/(r.height/2),2)<=1
    }
    private static func point(_ x:Int,_ y:Int,_ width:Int,_ height:Int)->CGPoint { CGPoint(x:(Double(x)+0.5)/Double(width),y:(Double(y)+0.5)/Double(height)) }
    private static func median(_ values:[Double])->Double { let sorted=values.sorted();return sorted[sorted.count/2] }
    private static func mean(_ values:[Double])->Double { values.isEmpty ? 0 : values.reduce(0,+)/Double(values.count) }
    private static func deviation(_ values:[Double])->Double { let center=mean(values);return sqrt(values.reduce(0){$0+pow($1-center,2)}/Double(max(1,values.count))) }
    private static func bounded(_ value:Double)->Double { min(100,max(0,value)) }
    private static func percent(_ value:Double)->String { String(format:"%.1f%%",value*100) }
    private static func unavailable(_ reason:String)->Result {
        Result(metrics:SkinDimension.allCases.map { SkinMetric(dimension:$0,score:nil,status:"采样待完善",items:[
            SkinItem(id:"appearance-unavailable-"+$0.rawValue,title:"外观采样",valueText:"待重新采集",note:reason,overlayID:nil)]) },overlays:[],summary:reason)
    }
}
