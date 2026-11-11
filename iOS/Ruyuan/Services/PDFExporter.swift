import UIKit

enum PDFExporter {
    static func export(report: AnalysisReport, image: UIImage?) throws -> URL {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RuyuanExports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Exports are explicit user actions; remove old temporary exports on every new export.
        for old in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) {
            if let date = try old.resourceValues(forKeys: [.creationDateKey]).creationDate,
               Date().timeIntervalSince(date) > 3600 { try? FileManager.default.removeItem(at: old) }
        }
        let url = dir.appendingPathComponent("如愿美学-\(report.id).pdf")
        try renderer.writePDF(to: url) { context in
            var y: CGFloat = 52
            func newPage() {
                context.beginPage()
                UIColor(red: 0.98, green: 0.97, blue: 0.96, alpha: 1).setFill()
                context.cgContext.fill(page)
                y = 52
            }
            func text(_ value: String, size: CGFloat = 12, bold: Bool = false) {
                let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.darkGray]
                let rect = (value as NSString).boundingRect(with: CGSize(width: 491, height: 700),
                                                           options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
                if y + rect.height + 16 > 790 { newPage() }
                (value as NSString).draw(in: CGRect(x: 52, y: y, width: 491, height: ceil(rect.height) + 3), withAttributes: attrs)
                y += ceil(rect.height) + 16
            }
            newPage()
            text("如愿美学", size: 28, bold: true)
            text("面部与皮肤外观记录 · \(report.origin.title)", size: 16)
            if report.isSample { text("演示报告 — 所有评分和图层为样例", size: 14, bold: true) }
            text(report.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let image {
                let height: CGFloat = 210
                let width = min(250, height * image.size.width / image.size.height)
                image.draw(in: CGRect(x: 52, y: y, width: width, height: height))
                y += height + 20
            }
            text(report.summary)
            text("面部几何", size: 18, bold: true)
            for item in report.geometry { text("\(item.title)：\(item.formattedValue)\n\(item.note)") }
            text("皮肤外观", size: 18, bold: true)
            for metric in report.skin {
                let score = metric.score.map { String(format: "%.0f 分", $0) } ?? "未评分"
                text("\(metric.dimension.title) · \(score) · \(metric.status)", size: 14, bold: true)
                for item in metric.items { text("\(item.title)：\(item.valueText)\n\(item.note)") }
            }
            text("分析来源：\(report.modelVersion)")
            text("报告 ID：\(report.id)")
            text("本报告记录照片中的外观特征。数值、图层与问卷/仪器指标按来源区分。", size: 10)
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return url
    }
}
