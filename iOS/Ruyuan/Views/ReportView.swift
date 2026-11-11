import SwiftUI
import UIKit

private enum ReportSection: String, CaseIterable {
    case skin = "皮肤外观"
    case geometry = "面部几何"
}

private struct InspectionTarget: Identifiable {
    var id = UUID()
    var layerID: String?
}

private struct ExportDocument: Identifiable {
    var id = UUID()
    var url: URL
}

@MainActor
struct ReportView: View {
    @EnvironmentObject private var store: AppStore
    let report: AnalysisReport
    @State private var section: ReportSection = .skin
    @State private var selectedDimension: SkinDimension = .waterOil
    @State private var inspection: InspectionTarget?
    @State private var exportDocument: ExportDocument?
    @State private var exportError: String?

    private var selectedMetric: SkinMetric? {
        report.skin.first { $0.dimension == selectedDimension }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                reportHeading
                if report.isSample { sampleNotice }
                summaryCard
                overviewCard
                Picker("报告内容", selection: $section) {
                    ForEach(ReportSection.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                if section == .skin {
                    skinSection
                } else {
                    geometrySection
                }
                if !report.overlays.isEmpty { overlaySection }
                qualitySection
                reportFooter
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 32)
        }
        .background(RuyuanStyle.background)
        .navigationTitle(report.isSample ? "演示报告" : "观察报告")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: exportPDF) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导出并分享 PDF 报告")
            }
        }
        .fullScreenCover(item: $inspection) { target in
            OverlayView(report: report, initialLayerID: target.layerID)
        }
        .sheet(item: $exportDocument) { document in
            ReportShareSheet(url: document.url)
        }
        .alert("暂时无法导出", isPresented: exportErrorPresented) {
            Button("知道了", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var reportHeading: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("THE OBSERVATION REPORT")
                    .font(.system(size: 9, weight: .medium)).tracking(1.8)
                    .foregroundStyle(RuyuanStyle.purple)
                Spacer()
                RuyuanPill(title: report.origin.title,
                           symbol: report.isSample ? "sparkles" : report.origin == .local ? "iphone" : "network")
            }
            Text(report.isSample ? "先了解报告，\n再认识自己。" : "每个细节，\n都有自己的美。")
                .font(.system(.title, design: .serif, weight: .medium))
                .lineSpacing(5).foregroundStyle(RuyuanStyle.ink)
            Text(report.createdAt.formatted(date: .long, time: .shortened))
                .font(.caption).foregroundStyle(RuyuanStyle.muted)
        }
    }

    private var sampleNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").padding(.top, 2)
            Text("这是一份演示报告。分数、比例与图层均为示例，不代表你或任何真实人物的检测结果。")
                .font(.caption).lineSpacing(4)
        }
        .foregroundStyle(RuyuanStyle.purple)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RuyuanStyle.lilac.opacity(0.7), in: RoundedRectangle(cornerRadius: 17))
    }

    private var summaryCard: some View {
        RuyuanCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 22) {
                    Button {
                        inspection = InspectionTarget(layerID: nil)
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            ReportPhotoView(report: report, image: store.image(for: report))
                                .frame(width: 100, height: 136)
                                .background(RuyuanStyle.lilac)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                .padding(7).background(RuyuanStyle.purple, in: Circle())
                                .padding(6)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(report.isSample ? "查看演示面部示意图" : "放大查看原图")
                    VStack(alignment: .leading, spacing: 9) {
                        Text(report.isSample ? "演示 · 五维均值" : "五维均值")
                            .font(.caption.weight(.medium)).foregroundStyle(RuyuanStyle.muted)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(scoreText(report.totalScore))
                                .font(.system(size: 48, weight: .light, design: .rounded))
                                .monospacedDigit().foregroundStyle(RuyuanStyle.purple)
                            if report.totalScore != nil {
                                Text("/ 100").font(.caption).foregroundStyle(RuyuanStyle.muted)
                            }
                        }
                        Text(report.totalScore == nil ? "尚无完整五维评分" : report.isSample ? "仅为界面演示" : "五个外观维度的算术均值")
                            .font(.caption).foregroundStyle(RuyuanStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !report.summary.isEmpty {
                    Rectangle().fill(RuyuanStyle.line).frame(height: 1)
                    Text(report.summary)
                        .font(.subheadline).lineSpacing(5).foregroundStyle(RuyuanStyle.ink)
                        .textSelection(.enabled)
                }
                if report.totalScore == nil && !report.isSample {
                    Label("未提供的数据保持空缺，不使用演示分数补齐。", systemImage: "minus.circle")
                        .font(.caption).foregroundStyle(RuyuanStyle.muted)
                }
            }
        }
    }

    private var overviewCard: some View {
        RuyuanCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeading(title: "五维观察", subtitle: report.isSample ? "演示数据 · 不是真实检测" : "外观信息，不是健康评级")
                    if report.isSample { RuyuanPill(title: "演示") }
                }
                SkinRadarChart(metrics: report.skin, isSample: report.isSample)
                    .frame(height: 245)
                VStack(spacing: 13) {
                    ForEach(SkinDimension.allCases) { dimension in
                        let metric = report.skin.first { $0.dimension == dimension }
                        HStack(spacing: 9) {
                            Image(systemName: dimension.symbol)
                                .font(.caption).foregroundStyle(RuyuanStyle.purple).frame(width: 19)
                            Text(dimension.title).font(.caption).foregroundStyle(RuyuanStyle.ink)
                            Spacer()
                            Text(metric?.score == nil ? "未评分" : "\(scoreText(metric?.score)) / 100")
                                .font(.caption.weight(.medium)).monospacedDigit()
                                .foregroundStyle(metric?.score == nil ? RuyuanStyle.muted : RuyuanStyle.purple)
                        }
                    }
                }
                .padding(.top, 5)
            }
        }
    }

    private var skinSection: some View {
        VStack(alignment: .leading, spacing: 17) {
            SectionHeading(title: "逐项了解皮肤外观", subtitle: "点击维度，查看实际提供的信息")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(SkinDimension.allCases) { dimension in
                        Button { selectedDimension = dimension } label: {
                            Label(dimension.title, systemImage: dimension.symbol)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .foregroundStyle(selectedDimension == dimension ? .white : RuyuanStyle.purple)
                                .background(selectedDimension == dimension ? RuyuanStyle.purple : .white,
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedDimension == dimension ? .isSelected : [])
                    }
                }
            }
            RuyuanCard {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(selectedDimension.title).font(.title3.weight(.semibold)).foregroundStyle(RuyuanStyle.ink)
                            Text(selectedMetric?.status ?? "本报告未提供此维度的分析输出")
                                .font(.caption).foregroundStyle(RuyuanStyle.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 15)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(selectedMetric?.score == nil ? "未评分" : scoreText(selectedMetric?.score))
                                .font(selectedMetric?.score == nil ? .subheadline.weight(.medium) : .title.weight(.light))
                                .foregroundStyle(RuyuanStyle.purple).monospacedDigit()
                            if report.isSample { Text("演示分").font(.caption2).foregroundStyle(RuyuanStyle.muted) }
                        }
                    }
                    if let metric = selectedMetric, !metric.items.isEmpty {
                        ForEach(metric.items) { item in
                            if item.id != metric.items.first?.id { Divider() }
                            skinItem(item)
                        }
                    } else {
                        Text("没有可展示的分项结果。你仍可查看原图和已提供的面部几何信息。")
                            .font(.subheadline).lineSpacing(4).foregroundStyle(RuyuanStyle.muted)
                    }
                }
            }
        }
    }

    private func skinItem(_ item: SkinItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(RuyuanStyle.ink)
                Spacer(minLength: 0)
                Text(item.valueText).font(.subheadline.weight(.medium)).foregroundStyle(RuyuanStyle.purple)
                    .multilineTextAlignment(.trailing)
            }
            Text(item.note).font(.caption).lineSpacing(4).foregroundStyle(RuyuanStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let overlayID = item.overlayID, report.overlays.contains(where: { $0.id == overlayID }) {
                Button {
                    inspection = InspectionTarget(layerID: overlayID)
                } label: {
                    Label(report.isSample ? "查看演示图层" : "查看对应图层", systemImage: "viewfinder")
                        .font(.caption.weight(.semibold)).foregroundStyle(RuyuanStyle.purple)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private var geometrySection: some View {
        VStack(alignment: .leading, spacing: 17) {
            SectionHeading(title: "面部几何观察", subtitle: "二维照片比例 · 会受表情与拍摄角度影响")
            Button {
                inspection = InspectionTarget(layerID: nil)
            } label: {
                ZStack(alignment: .bottom) {
                    ReportPhotoView(report: report, image: store.image(for: report),
                                    showsLandmarks: true)
                        .frame(height: 285)
                        .background(RuyuanStyle.lilac.opacity(0.4))
                    HStack {
                        Label(geometryPreviewTitle, systemImage: "face.dashed")
                        Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(RuyuanStyle.purple)
                    .padding(15).background(.regularMaterial)
                }
                .clipShape(RoundedRectangle(cornerRadius: 23))
            }
            .buttonStyle(.plain)
            if report.geometry.isEmpty {
                RuyuanCard {
                    Text("本报告未提供可用的面部几何指标。")
                        .font(.subheadline).foregroundStyle(RuyuanStyle.muted)
                }
            } else {
                RuyuanCard {
                    VStack(alignment: .leading, spacing: 19) {
                        ForEach(report.geometry) { metric in
                            if metric.id != report.geometry.first?.id { Divider() }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(metric.title).font(.subheadline.weight(.medium)).foregroundStyle(RuyuanStyle.ink)
                                    Spacer()
                                    Text(metric.formattedValue).font(.title3.weight(.light))
                                        .monospacedDigit().foregroundStyle(RuyuanStyle.purple)
                                }
                                Text(metric.note).font(.caption).lineSpacing(3).foregroundStyle(RuyuanStyle.muted)
                            }
                        }
                        if report.isSample {
                            RuyuanPill(title: "上述比例均为演示数据", symbol: "info.circle")
                        }
                    }
                }
            }
        }
    }

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 17) {
            SectionHeading(title: "可视化图层", subtitle: report.isSample ? "点击放大演示标注 · 非真实检测" : "标注来自本报告输出，可与原图切换对照")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 13) {
                    ForEach(report.overlays) { layer in
                        Button {
                            inspection = InspectionTarget(layerID: layer.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                ZStack(alignment: .bottomTrailing) {
                                    ReportPhotoView(report: report, image: store.image(for: report), layers: [layer])
                                        .frame(width: 145, height: 170)
                                        .background(RuyuanStyle.lilac.opacity(0.6))
                                    Image(systemName: "plus.magnifyingglass")
                                        .font(.caption).foregroundStyle(RuyuanStyle.purple)
                                        .padding(7).background(.regularMaterial, in: Circle()).padding(8)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                HStack(spacing: 6) {
                                    Circle().fill(Color(hex: layer.colorHex)).frame(width: 6, height: 6)
                                    Text(layer.title).font(.caption.weight(.medium)).foregroundStyle(RuyuanStyle.ink)
                                }
                                .frame(width: 145, alignment: .leading)
                                .multilineTextAlignment(.leading)
                                if report.isSample {
                                    Text("演示图层").font(.caption2).foregroundStyle(RuyuanStyle.muted)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("放大查看\(report.isSample ? "演示" : "")\(layer.title)图层")
                    }
                }
                .padding(.bottom, 3)
            }
        }
    }

    private var qualitySection: some View {
        RuyuanCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 18) {
                    if report.quality.isEmpty {
                        Text("本报告未提供拍摄质量检查记录。")
                            .font(.caption).foregroundStyle(RuyuanStyle.muted)
                    }
                    ForEach(report.quality) { check in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: check.passed ? "checkmark.circle" : "info.circle")
                                .foregroundStyle(check.passed ? RuyuanStyle.green : RuyuanStyle.purple)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(check.title).font(.caption.weight(.semibold)).foregroundStyle(RuyuanStyle.ink)
                                Text(check.detail).font(.caption).lineSpacing(3).foregroundStyle(RuyuanStyle.muted)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("分析来源与版本").font(.caption.weight(.semibold)).foregroundStyle(RuyuanStyle.ink)
                        Text(report.modelVersion.isEmpty ? "未提供版本信息" : report.modelVersion)
                            .font(.caption2.monospaced()).foregroundStyle(RuyuanStyle.muted)
                            .textSelection(.enabled)
                        Text("报告状态：\(statusTitle)").font(.caption2).foregroundStyle(RuyuanStyle.muted)
                    }
                }
                .padding(.top, 18)
            } label: {
                Label("拍摄质量与分析来源", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.medium)).foregroundStyle(RuyuanStyle.ink)
            }
            .tint(RuyuanStyle.purple)
        }
    }

    private var reportFooter: some View {
        VStack(spacing: 11) {
            Image(systemName: "sparkle").font(.title3.weight(.light)).foregroundStyle(RuyuanStyle.purple)
            Text("美不止一种答案。")
                .font(.system(.subheadline, design: .serif)).foregroundStyle(RuyuanStyle.ink)
            Text("报告仅用于外观观察与记录，不用于医学诊断、疾病筛查或治疗决策。照片条件与模型局限可能影响结果。")
                .font(.caption2).lineSpacing(4).foregroundStyle(RuyuanStyle.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.top, 5)
    }

    private func scoreText(_ score: Double?) -> String {
        guard let score, score.isFinite else { return "—" }
        return String(format: "%.0f", score)
    }

    private var statusTitle: String {
        switch report.status.lowercased() {
        case "sample", "demo": return "演示样例"
        case "completed", "ready": return "已完成"
        case "partial": return "部分指标已完成"
        default: return report.status
        }
    }

    private var geometryPreviewTitle: String {
        if report.isSample { return report.landmarks.isEmpty ? "演示面部示意图" : "演示特征点" }
        return report.landmarks.isEmpty ? "放大查看原图" : "查看真实特征点"
    }

    private func exportPDF() {
        do { exportDocument = ExportDocument(url: try store.exportPDF(report)) }
        catch { exportError = error.localizedDescription }
    }

    private var exportErrorPresented: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }
}

private struct SkinRadarChart: View {
    let metrics: [SkinMetric]
    let isSample: Bool
    private let dimensions = SkinDimension.allCases

    private var completeScores: [Double]? {
        let values = dimensions.compactMap { dimension in
            metrics.first { $0.dimension == dimension }?.score
        }
        guard values.count == dimensions.count, values.allSatisfy({ $0.isFinite }) else { return nil }
        return values
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2 + 3)
                let radius = Double(min(size.width * 0.31, size.height * 0.34))
                for step in 1...4 {
                    let ring = polygon(center: center, radius: radius * Double(step) / 4)
                    context.stroke(ring, with: .color(RuyuanStyle.line), lineWidth: 1)
                }
                for index in dimensions.indices {
                    let outer = position(index: index, center: center, radius: radius)
                    var axis = Path(); axis.move(to: center); axis.addLine(to: outer)
                    context.stroke(axis, with: .color(RuyuanStyle.line), lineWidth: 1)
                    let labelPoint = position(index: index, center: center, radius: radius + 25)
                    context.draw(Text(dimensions[index].title).font(.caption2).foregroundColor(RuyuanStyle.muted),
                                 at: labelPoint)
                }
                if let scores = completeScores {
                    var data = Path()
                    for index in scores.indices {
                        let point = position(index: index, center: center,
                                             radius: radius * min(max(scores[index] / 100, 0), 1))
                        if index == 0 { data.move(to: point) } else { data.addLine(to: point) }
                    }
                    data.closeSubpath()
                    context.fill(data, with: .color(RuyuanStyle.purple.opacity(0.15)))
                    context.stroke(data, with: .color(RuyuanStyle.purple), style: StrokeStyle(lineWidth: 1.7, lineJoin: .round))
                    for index in scores.indices {
                        let point = position(index: index, center: center,
                                             radius: radius * min(max(scores[index] / 100, 0), 1))
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                                     with: .color(RuyuanStyle.purple))
                    }
                }
            }
            if completeScores == nil {
                VStack(spacing: 5) {
                    Text("未提供完整评分").font(.caption.weight(.medium))
                    Text("不以 0 分代替空缺").font(.caption2)
                }
                .foregroundStyle(RuyuanStyle.muted)
                .padding(10).background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
            }
            if isSample {
                VStack { Spacer(); Text("演示五维图").font(.caption2).foregroundStyle(RuyuanStyle.purple) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isSample ? "五维演示雷达图，不是真实检测结果" : completeScores == nil ? "五维雷达图，未提供完整评分" : "五维外观雷达图，各维度分数见下方文字")
    }

    private func position(index: Int, center: CGPoint, radius: Double) -> CGPoint {
        let angle = Double(index) * 2 * .pi / Double(dimensions.count) - .pi / 2
        return CGPoint(x: center.x + CGFloat(cos(angle) * radius), y: center.y + CGFloat(sin(angle) * radius))
    }

    private func polygon(center: CGPoint, radius: Double) -> Path {
        var path = Path()
        for index in dimensions.indices {
            let point = position(index: index, center: center, radius: radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

private struct ReportShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
