import Foundation

enum ReportValidator {
    static func validate(_ report: AnalysisReport) throws {
        let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !report.id.isEmpty, report.id.count <= 128,
              report.id.unicodeScalars.allSatisfy({ idCharacters.contains($0) }),
              report.imageWidth > 0, report.imageWidth <= 8192,
              report.imageHeight > 0, report.imageHeight <= 8192,
              report.geometry.count <= 100, report.overlays.count <= 50,
              report.landmarks.count <= 100,
              report.imageFileName.isEmpty || URL(fileURLWithPath: report.imageFileName).lastPathComponent == report.imageFileName,
              report.skin.count == SkinDimension.allCases.count,
              Set(report.skin.map(\.dimension)).count == report.skin.count else { throw invalid() }
        guard (report.assessment?.isValid ?? true), report.geometry.allSatisfy({ $0.value?.isFinite ?? true }),
              report.skin.allSatisfy({ metric in
                  guard metric.items.count <= 100 else { return false }
                  return metric.score.map { $0.isFinite && (0...100).contains($0) } ?? true
              }) else { throw invalid() }
        let paths = report.landmarks.map(\.points) + report.overlays.flatMap(\.paths)
        guard paths.count <= 10000,
              paths.reduce(0, { $0 + $1.count }) <= 100000,
              paths.flatMap({ $0 }).allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              Set(report.landmarks.map(\.id)).count == report.landmarks.count,
              Set(report.geometry.map(\.id)).count == report.geometry.count,
              Set(report.overlays.map(\.id)).count == report.overlays.count else { throw invalid() }
    }
    private static func invalid() -> AnalysisError { .network("报告格式或坐标校验未通过，请联系模型服务管理者。") }
}
