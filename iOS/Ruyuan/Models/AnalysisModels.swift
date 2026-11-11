import Foundation

// All coordinates use the upright original photo, normalized [0, 1], top-left origin.
struct NormalizedPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

enum ReportOrigin: String, Codable, Sendable {
    case local, server, sample
    var title: String {
        switch self {
        case .local: return "本机分析"
        case .server: return "服务端分析"
        case .sample: return "演示样例"
        }
    }
}

struct GeometryMetric: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var value: Double?
    var unit: String
    var note: String
    var formattedValue: String {
        guard let value else { return "待采集" }
        return String(format: "%.2f", value) + unit
    }
}

enum SkinDimension: String, Codable, CaseIterable, Identifiable, Sendable {
    case waterOil, tone, sensitivity, smoothness, aging
    var id: String { rawValue }
    var title: String {
        switch self {
        case .waterOil: return "水油度"
        case .tone: return "肤色"
        case .sensitivity: return "敏感度"
        case .smoothness: return "光滑度"
        case .aging: return "衰老度"
        }
    }
    var symbol: String {
        switch self {
        case .waterOil: return "drop"
        case .tone: return "sun.max"
        case .sensitivity: return "leaf"
        case .smoothness: return "sparkles"
        case .aging: return "clock"
        }
    }
}

struct SkinItem: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var valueText: String
    var note: String
    var overlayID: String?
}

struct SkinMetric: Codable, Identifiable, Sendable {
    var dimension: SkinDimension
    var score: Double?
    var status: String
    var items: [SkinItem]
    var scoreSource: String? = nil
    var id: String { dimension.rawValue }
}

enum OverlayKind: String, Codable, Sendable { case polygons, lines, points }

struct OverlayLayer: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var colorHex: String
    var kind: OverlayKind
    var paths: [[NormalizedPoint]]
    var note: String
    var source: String
}

struct LandmarkPath: Codable, Identifiable, Sendable {
    var id: String
    var points: [NormalizedPoint]
    var closed: Bool
}

struct QualityCheck: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var passed: Bool
    var detail: String
}

struct AnalysisReport: Codable, Identifiable, Sendable {
    var id: String
    var createdAt: Date
    var origin: ReportOrigin
    var status: String
    var imageFileName: String
    var imageWidth: Int
    var imageHeight: Int
    var geometry: [GeometryMetric]
    var skin: [SkinMetric]
    var landmarks: [LandmarkPath]
    var overlays: [OverlayLayer]
    var quality: [QualityCheck]
    var modelVersion: String
    var summary: String
    var assessment: SkinSelfAssessment? = nil
    var totalScore: Double? {
        let scores = skin.compactMap(\.score)
        guard scores.count == SkinDimension.allCases.count else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }
    var scoreBasisDescription: String {
        if isSample { return "演示数据，不用于真实检测。" }
        let selfCount = skin.filter { $0.score != nil && $0.scoreSource == "selfReport" }.count
        let photoCount = skin.filter { $0.score != nil && $0.scoreSource == "photoHeuristic" }.count
        if selfCount > 0 || photoCount > 0 {
            return "已提供 \(photoCount) 项照片视觉参考、\(selfCount) 项自评参考；综合分为五项都有值时的算术均值，不是皮肤仪测量或人群排名。"
        }
        return "分数及定义来自报告注明的分析来源；缺项不补零、不生成综合分。"
    }
    var isSample: Bool { origin == .sample }
}

enum AnalysisStage: String, CaseIterable, Sendable {
    case preparing, quality, geometry, skin, report
    var title: String {
        switch self {
        case .preparing: return "准备原始照片"
        case .quality: return "检查拍摄质量"
        case .geometry: return "定位面部特征"
        case .skin: return "分析皮肤外观"
        case .report: return "整理你的报告"
        }
    }
    var progress: Double {
        Double(Self.allCases.firstIndex(of: self)! + 1) / Double(Self.allCases.count)
    }
}

enum AnalysisError: LocalizedError {
    case invalidImage, noFace, multipleFaces, poorQuality(String), network(String)
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "照片读取失败，请重新选择。"
        case .noFace: return "没有找到清晰的正面人脸，请露出五官后重拍。"
        case .multipleFaces: return "请只保留一张人脸后重新拍摄。"
        case .poorQuality(let message): return message
        case .network(let message): return message
        }
    }
}
