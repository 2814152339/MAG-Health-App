import Foundation

/// User-reported sensations are stored separately from image observations.
struct SkinSelfAssessment: Codable, Sendable {
    var dryness: Int
    var oiliness: Int
    var reactivity: Int
    var age: Int?
    static let frequency = ["几乎没有", "偶尔", "经常", "几乎每天"]
    var isValid: Bool { (0...3).contains(dryness) && (0...3).contains(oiliness) && (0...3).contains(reactivity) && (age.map { (12...100).contains($0) } ?? true) }
    var typeTitle: String {
        if dryness >= 2 && oiliness >= 2 { return "混合肤感" }
        if oiliness >= 2 { return "偏油肤感" }
        if dryness >= 2 { return "偏干肤感" }
        return "相对平衡肤感"
    }
    func applying(to source: AnalysisReport) -> AnalysisReport {
        guard isValid else { return source }
        var report = source
        report.assessment = self
        report.skin = source.skin.map { metric in
            var updated = metric
            if metric.dimension == .waterOil {
                if updated.score == nil {
                    updated.score = Double(max(0, 100 - dryness * 12 - oiliness * 10))
                    updated.scoreSource = "selfReport"
                    updated.status = "肤感自评参考分 · 非仪器水油测量"
                }
                updated.items.removeAll { $0.id.hasPrefix("self-") }
                updated.items += [
                    SkinItem(id: "self-dryness", title: "水分与干燥感", valueText: Self.frequency[dryness], note: "你自述洗脸后的紧绷或干燥频率。不是照片含水量测量；有紧绷时先减少过度清洁，使用温和保湿。", overlayID: nil),
                    SkinItem(id: "self-oiliness", title: "日常出油感", valueText: Self.frequency[oiliness], note: "你自述洗脸约两小时后 T 区明显出油的频率。参考分 = 100 − 干燥等级×12 − 出油等级×10；为本 App 的透明整理规则，不是人群常模。", overlayID: nil)
                ]
            }
            if metric.dimension == .sensitivity {
                if updated.score == nil {
                    updated.score = Double(100 - reactivity * 22)
                    updated.scoreSource = "selfReport"
                    updated.status = "耐受感自评参考分 · 非敏感诊断"
                }
                updated.items.removeAll { $0.id.hasPrefix("self-") }
                updated.items.append(SkinItem(id: "self-reactivity", title: "日常刺激反应", valueText: Self.frequency[reactivity], note: "你自述使用日常护肤品后刺痛或泛红的频率；参考分 = 100 − 自述等级×22，高分表示较少自述不适。无法据此判断过敏或皮肤屏障；反复不适时停止可疑刺激并咨询专业人员。", overlayID: nil))
            }
            return updated
        }
        report.summary = "根据你的日常感受，为\(typeTitle)。" + source.summary
        report.modelVersion += "; voluntary skin-feel questionnaire v1 (not diagnosis)"
        return report
    }
}
