import Foundation

enum SampleData {
    static let report: AnalysisReport = {
        let values: [SkinDimension: Double] = [.waterOil: 78, .tone: 88, .sensitivity: 85, .smoothness: 82, .aging: 80]
        let items: [SkinDimension: [SkinItem]] = [
            .waterOil: [SkinItem(id: "sample-shine", title: "油光分布", valueText: "T 区较明显 · 演示", note: "示例区域用于体验原图与图层切换。真实报告显示照片外观代理结果。", overlayID: "sample-shine"),
                        SkinItem(id: "sample-hydration", title: "水分", valueText: "演示占位", note: "正式水分指标由配对验证模型提供。", overlayID: nil)],
            .tone: [SkinItem(id: "sample-tone", title: "肤色均匀度", valueText: "较均匀 · 演示", note: "本页数据由设计样例生成。", overlayID: "sample-pigment")],
            .sensitivity: [SkinItem(id: "sample-redness", title: "可见泛红", valueText: "局部区域 · 演示", note: "可见颜色与敏感倾向分开记录。", overlayID: "sample-redness")],
            .smoothness: [SkinItem(id: "sample-pores", title: "毛孔", valueText: "局部可见 · 演示", note: "正式计数来自已接入的专项模型。", overlayID: nil)],
            .aging: [SkinItem(id: "sample-lines", title: "额部纹理", valueText: "轻微 · 演示", note: "演示线段不对应任何真实用户照片。", overlayID: "sample-lines"),
                     SkinItem(id: "sample-eyes", title: "眼周", valueText: "局部色差 · 演示", note: "正式报告按模型完成情况显示。", overlayID: "sample-eyes"),
                     SkinItem(id: "line-forehead", title: "额部线纹响应", valueText: "3.0% · 演示", note: "合成演示覆盖率，不是用户检测数据。", overlayID: "sample-lines"),
                     SkinItem(id: "line-glabella", title: "眉间线纹响应", valueText: "1.2% · 演示", note: "合成演示覆盖率，不是用户检测数据。", overlayID: "sample-lines"),
                     SkinItem(id: "line-nasolabial", title: "鼻唇侧线纹响应", valueText: "4.5% · 演示", note: "合成演示覆盖率，不是用户检测数据。", overlayID: "sample-lines"),
                     SkinItem(id: "line-eye", title: "眼外侧线纹响应", valueText: "2.1% · 演示", note: "合成演示覆盖率，不是用户检测数据。", overlayID: "sample-eyes")]
        ]
        func p(_ x: Double, _ y: Double) -> NormalizedPoint { NormalizedPoint(x: x, y: y) }
        return AnalysisReport(
            id: "ruyuan-demo-v1", createdAt: Date(timeIntervalSince1970: 1_794_355_200), origin: .sample,
            status: "sample", imageFileName: "", imageWidth: 600, imageHeight: 800,
            geometry: [
                GeometryMetric(id: "faceRatio", title: "面部长宽比", value: 1.38, unit: "", note: "演示比例"),
                GeometryMetric(id: "eyeSpacing", title: "眼距 / 平均眼宽", value: 1.12, unit: "", note: "演示比例"),
                GeometryMetric(id: "noseWidth", title: "鼻宽 / 脸宽", value: 0.24, unit: "", note: "演示比例"),
                GeometryMetric(id: "lipRatio", title: "唇宽 / 脸宽", value: 0.36, unit: "", note: "演示比例"),
                GeometryMetric(id: "jaw", title: "二维轮廓夹角", value: 142.5, unit: "°", note: "演示角度，非骨性下颌角"),
                GeometryMetric(id: "thirds", title: "三庭", value: nil, unit: "", note: "发际线需要专项定位")
            ],
            skin: SkinDimension.allCases.map { SkinMetric(dimension: $0, score: values[$0], status: "演示数据", items: items[$0] ?? []) },
            landmarks: [],
            overlays: [
                OverlayLayer(id: "sample-shine", title: "油光 · 演示", colorHex: "F5CE68", kind: .polygons,
                             paths: [[p(0.40,0.24),p(0.60,0.24),p(0.57,0.36),p(0.43,0.36)], [p(0.48,0.36),p(0.52,0.36),p(0.55,0.54),p(0.45,0.54)]],
                             note: "示例图层，仅供交互预览", source: "sample"),
                OverlayLayer(id: "sample-redness", title: "泛红 · 演示", colorHex: "DF8C9B", kind: .polygons,
                             paths: [[p(0.27,0.46),p(0.40,0.48),p(0.39,0.57),p(0.29,0.58)],[p(0.60,0.48),p(0.73,0.46),p(0.71,0.58),p(0.61,0.57)]],
                             note: "示例色块，不代表模型检测", source: "sample"),
                OverlayLayer(id: "sample-pigment", title: "肤色 · 演示", colorHex: "AD8BD5", kind: .polygons,
                             paths: [[p(0.31,0.49),p(0.36,0.48),p(0.37,0.52),p(0.32,0.53)]], note: "示例区域", source: "sample"),
                OverlayLayer(id: "sample-lines", title: "纹理 · 演示", colorHex: "A18CD1", kind: .lines,
                             paths: [[p(0.40,0.28),p(0.47,0.27),p(0.54,0.27),p(0.60,0.28)],[p(0.41,0.31),p(0.49,0.30),p(0.59,0.31)]], note: "示例线段", source: "sample"),
                OverlayLayer(id: "sample-eyes", title: "眼周 · 演示", colorHex: "84BEB9", kind: .polygons,
                             paths: [[p(0.33,0.41),p(0.44,0.42),p(0.43,0.45),p(0.34,0.44)],[p(0.56,0.42),p(0.67,0.41),p(0.66,0.44),p(0.57,0.45)]], note: "示例眼周", source: "sample")
            ],
            quality: [QualityCheck(id: "sample", title: "演示画面", passed: true, detail: "矢量示意图，不含用户照片")],
            modelVersion: "sample-design-v1", summary: "这是一份交互演示报告。五维评分、标注和图层用于体验页面，不是你的测肤结果。拍摄或导入照片后，可查看独立生成的真实分析。"
        )
    }()
}
