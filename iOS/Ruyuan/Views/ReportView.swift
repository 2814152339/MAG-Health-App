import SwiftUI
import UIKit

private struct InspectionTarget: Identifiable {
    let id = UUID()
    var layerID: String?
}

private enum ReportSheet: Identifiable {
    case details, feedback, export(URL)
    var id: String {
        switch self {
        case .details: return "details"
        case .feedback: return "feedback"
        case .export(let url): return url.absoluteString
        }
    }
}

/// A local report conversation. Scores and overlays come from this report only.
@MainActor
struct ReportView: View {
    @EnvironmentObject private var store: AppStore
    let report: AnalysisReport
    @State private var selectedDimension: SkinDimension = .waterOil
    @State private var sheet: ReportSheet?
    @State private var inspection: InspectionTarget?
    @State private var exportError: String?
    @State private var feedbackChoice = ""
    @State private var feedbackNote = ""
    @State private var feedbackSaved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(report.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9)).foregroundStyle(RuyuanStyle.muted).frame(maxWidth: .infinity)
                privatePhotoMessage
                assistantMessage
                if report.isSample { sampleNotice }
                ReportSummaryCard(report: report)
                dimensionList
                careSuggestions
                feedbackBar
                sourceDisclosure
                Text("仅作外观记录与养护参考，不替代皮肤科诊断。不同光线、表情和拍摄角度会影响结果。")
                    .font(.caption2).foregroundStyle(RuyuanStyle.muted).lineSpacing(4).padding(.horizontal, 4)
            }
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 26)
        }
        .background(RuyuanStyle.background)
        .navigationTitle(report.isSample ? "演示报告" : "如愿 · 测肤记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: exportPDF) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("导出并分享 PDF 报告")
            }
        }
        .accessibilityIdentifier("reportOverview")
        .fullScreenCover(item: $inspection) { target in
            OverlayView(report: report, initialLayerID: target.layerID)
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .details:
                ReportDetailSheet(report: report, initialDimension: selectedDimension)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible).presentationCornerRadius(28)
            case .feedback:
                ReportFeedbackEditor(initialNote: feedbackNote) { note in
                    feedbackNote = note; saveFeedback(); sheet = nil
                }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            case .export(let url): ReportShareSheet(url: url)
            }
        }
        .alert("暂时无法导出", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("知道了", role: .cancel) { exportError = nil }
            } message: { Text(exportError ?? "") }
        .onAppear(perform: loadFeedback)
    }

    private var privatePhotoMessage: some View {
        HStack {
            Spacer(minLength: 80)
            Button { inspection = InspectionTarget(layerID: nil) } label: {
                VStack(spacing: 7) {
                    ZStack(alignment: .topTrailing) {
                        ReportPhotoView(report: report, image: store.image(for: report))
                            .frame(width: 76, height: 76).blur(radius: 12)
                            .overlay(Color.black.opacity(0.12))
                            .overlay {
                                VStack(spacing: 5) {
                                    Image(systemName: "eye.slash").font(.caption)
                                    Text("点击查看").font(.system(size: 10))
                                }.foregroundStyle(.white)
                            }
                        Label("隐私保护", systemImage: "lock.shield.fill")
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(RuyuanStyle.purple)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.white.opacity(0.96), in: Capsule())
                    }.clipShape(RoundedRectangle(cornerRadius: 17))
                    Text(report.isSample ? "演示示意图" : "原图默认模糊保护")
                        .font(.system(size: 10)).foregroundStyle(RuyuanStyle.muted)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(report.isSample ? "查看演示示意图" : "查看本次原始照片")
            .accessibilityIdentifier("reportOriginalPhoto")
        }
    }

    private var assistantMessage: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("已为你整理这次的肤况观察，具体结果如下。")
                .font(.system(size: 12)).lineSpacing(4).foregroundStyle(RuyuanStyle.ink)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var sampleNotice: some View {
        Label("这是一份演示报告。分数、比例与图层均为示例，不代表你或任何真实人物的检测结果。", systemImage: "info.circle")
            .font(.system(size: 10)).foregroundStyle(RuyuanStyle.purple).lineSpacing(3)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }

    private var dimensionList: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("综合参考分").font(.subheadline.weight(.semibold))
                Text(reportScore(report.totalScore)).font(.title3.weight(.semibold)).foregroundStyle(RuyuanStyle.purple)
                Spacer()
                Text(report.isSample ? "演示" : "非仪器评分").font(.caption2).foregroundStyle(RuyuanStyle.muted)
            }.padding(.bottom, 12)
            ForEach(SkinDimension.allCases) { dimension in
                let metric = report.skin.first { $0.dimension == dimension }
                Button { openDetails(dimension) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: dimension.symbol).font(.system(size: 21, weight: .light))
                            .frame(width: 30).foregroundStyle(RuyuanStyle.ink)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(dimension.title).font(.subheadline.weight(.medium))
                                Text(metric?.score == nil ? "未评分" : reportScore(metric?.score))
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(RuyuanStyle.purple)
                            }
                            Text(dimensionDescription(dimension)).font(.caption2).foregroundStyle(RuyuanStyle.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RuyuanStyle.muted)
                    }
                    .foregroundStyle(RuyuanStyle.ink).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("dimension-\(dimension.rawValue)")
                if dimension != SkinDimension.allCases.last { Divider().overlay(RuyuanStyle.line) }
            }
            Button { openDetails(.waterOil) } label: {
                Text("本次解读结果").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .foregroundStyle(.white).background(RuyuanStyle.purple, in: Capsule())
            }
            .buttonStyle(.plain).padding(.top, 10).accessibilityIdentifier("openReportDetails")
        }
        .padding(14).background(.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 18))
    }

    private var careSuggestions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("把这次观察，变成日常照顾。")
                .font(.subheadline.weight(.medium)).foregroundStyle(RuyuanStyle.ink)
            Text(report.isSample ? "下面是示例护理思路，先从温和、规律的日常开始。" : "结合本次已提供的分项，给你几个温和的护理与记录方向。")
                .font(.caption).foregroundStyle(RuyuanStyle.muted).lineSpacing(4)
            ForEach(careDimensions, id: \.rawValue) { dimension in
                Button { openDetails(dimension) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(careTitle(dimension)).font(.subheadline.weight(.medium))
                            Text(careText(dimension)).font(.caption).lineSpacing(4)
                                .foregroundStyle(RuyuanStyle.muted).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 5)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RuyuanStyle.muted)
                    }
                    .foregroundStyle(RuyuanStyle.ink).padding(15).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 15))
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 3)
    }

    private var careDimensions: [SkinDimension] {
        let available = SkinDimension.allCases.filter { dimension in
            report.skin.contains { $0.dimension == dimension && !$0.items.isEmpty }
        }
        return Array(available.prefix(3))
    }

    private func careTitle(_ dimension: SkinDimension) -> String {
        switch dimension {
        case .waterOil: return "水油护理 · 温和清洁"
        case .tone: return "肤色记录 · 规律防晒"
        case .sensitivity: return "肤感观察 · 精简护理"
        case .smoothness: return "纹理护理 · 避免过度摩擦"
        case .aging: return "眼周与细纹 · 规律作息"
        }
    }

    private func careText(_ dimension: SkinDimension) -> String {
        let item = report.skin.first { $0.dimension == dimension }?.items.first
        let observation = item.map { "本次\($0.title)：\($0.valueText)。" } ?? ""
        switch dimension {
        case .waterOil: return observation + "不要仅凭反光加大去油力度；按真实肤感选择温和清洁与保湿。"
        case .tone: return observation + "保持日常防晒；尽量在相同光线下复拍，避免把光影变化当作肤色改变。"
        case .sensitivity: return observation + "单张照片不能确认敏感。以实际不适感为准，先减少叠加刺激性产品。"
        case .smoothness: return observation + "避免反复挤压、用力磨砂；保持规律清洁，结合清晰复拍持续观察。"
        case .aging: return observation + "保持规律作息、温和保湿；表情纹与阴影会随角度变化，不把视觉参考当作实际年龄。"
        }
    }

    private var feedbackBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 22) {
                Button { toggleFeedback("like") } label: {
                    Image(systemName: feedbackChoice == "like" ? "hand.thumbsup.fill" : "hand.thumbsup")
                }.accessibilityLabel("这份报告有帮助").accessibilityIdentifier("reportFeedbackLike")
                Button { toggleFeedback("dislike") } label: {
                    Image(systemName: feedbackChoice == "dislike" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }.accessibilityLabel("这份报告需要改进")
                Button("补充反馈") { sheet = .feedback }.font(.caption).accessibilityIdentifier("reportFeedbackNote")
                Spacer()
                Button(action: exportPDF) { Label("分享", systemImage: "square.and.arrow.up") }
                    .font(.caption).accessibilityLabel("分享 PDF 报告").accessibilityIdentifier("shareReportPDF")
            }.foregroundStyle(RuyuanStyle.purple).padding(.vertical, 5)
            if feedbackSaved {
                Text("反馈已保存在本机，不会自动上传。")
                    .font(.caption2).foregroundStyle(RuyuanStyle.muted)
            }
        }.padding(.horizontal, 5)
    }

    private var sourceDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                Text("来源：\(report.origin.title)").font(.caption)
                Text(report.modelVersion.isEmpty ? "未提供版本信息" : report.modelVersion)
                    .font(.caption2.monospaced()).textSelection(.enabled)
                Text("照片外观、自评与演示数据分别标示；缺失指标保持空缺，不以 0 分或示例数字补齐。")
                    .font(.caption).lineSpacing(4)
            }.foregroundStyle(RuyuanStyle.muted).padding(.top, 9)
        } label: {
            Label("查看分析依据", systemImage: "checkmark.shield").font(.caption).foregroundStyle(RuyuanStyle.muted)
        }.padding(14).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func openDetails(_ dimension: SkinDimension) { selectedDimension = dimension; sheet = .details }
    private var feedbackKey: String { "report.feedback.v1.\(report.id)" }
    private func loadFeedback() {
        let value = UserDefaults.standard.dictionary(forKey: feedbackKey)
        feedbackChoice = value?["choice"] as? String ?? ""
        feedbackNote = value?["note"] as? String ?? ""
        feedbackSaved = value != nil
    }
    private func toggleFeedback(_ value: String) {
        feedbackChoice = feedbackChoice == value ? "" : value
        saveFeedback()
    }
    private func saveFeedback() {
        UserDefaults.standard.set(["choice": feedbackChoice, "note": feedbackNote,
                                   "updatedAt": Date().timeIntervalSince1970] as [String: Any], forKey: feedbackKey)
        feedbackSaved = true
    }
    private func exportPDF() {
        do { sheet = .export(try store.exportPDF(report)) }
        catch { exportError = error.localizedDescription }
    }
}

private func reportScore(_ score: Double?) -> String {
    guard let score, score.isFinite else { return "—" }
    return String(format: "%.0f", score)
}

private func dimensionDescription(_ dimension: SkinDimension) -> String {
    switch dimension {
    case .waterOil: return "油光、保湿肤感与照片中的亮区"
    case .tone: return "肤色、色差与暗沉外观"
    case .sensitivity: return "泛红外观与本人肤感自评"
    case .smoothness: return "痘样、点状纹理与毛孔外观"
    case .aging: return "细纹、眼周与面部线条"
    }
}

private struct ReportSummaryCard: View {
    let report: AnalysisReport
    var body: some View {
        RuyuanCard(padding: 16) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.isSample ? "认真养肤 · 示例" : "认真养肤，慢慢变好")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(RuyuanStyle.ink)
                        Text(report.assessment?.typeTitle ?? (report.isSample ? "肤况示例" : "单次照片外观记录"))
                            .font(.caption).foregroundStyle(RuyuanStyle.muted)
                        if let age = report.assessment?.age {
                            Text("实际年龄 \(age) 岁 · 来自本人填写").font(.caption2).foregroundStyle(RuyuanStyle.muted)
                        }
                        Text(report.isSample ? "分数和标注仅作演示" : "照片观察与自评参考，不是仪器测量")
                            .font(.caption2).foregroundStyle(RuyuanStyle.purple)
                    }
                    Spacer(minLength: 0)
                    referenceRing
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("总体结论").font(.caption.weight(.semibold)).foregroundStyle(RuyuanStyle.ink)
                    Text(report.summary.isEmpty ? "本报告未提供总体文字结论，可查看已提供的分项。" : report.summary)
                        .font(.caption).lineSpacing(4).foregroundStyle(RuyuanStyle.muted)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if report.totalScore == nil {
                    Label("部分维度未评分，不生成综合分、肤龄或同龄排名。", systemImage: "minus.circle")
                        .font(.caption2).foregroundStyle(RuyuanStyle.muted)
                }
                Text(report.scoreBasisDescription)
                    .font(.system(size: 10)).foregroundStyle(RuyuanStyle.muted).lineSpacing(3)
            }
        }
    }
    private var referenceRing: some View {
        ZStack {
            Circle().stroke(RuyuanStyle.lilac, lineWidth: 7)
            if let score = report.totalScore, score.isFinite {
                Circle().trim(from: 0, to: CGFloat(min(max(score / 100, 0), 1)))
                    .stroke(AngularGradient(colors: [RuyuanStyle.purple, Color(hex: "B3A5FF"), Color(hex: "FFCE54")], center: .center),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text(reportScore(report.totalScore)).font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(report.isSample ? "演示" : "参考").font(.system(size: 9))
            }.foregroundStyle(RuyuanStyle.purple)
        }.frame(width: 54, height: 54).padding(3)
        .accessibilityLabel("综合参考分 \(reportScore(report.totalScore))")
    }
}

@MainActor
private struct ReportDetailSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let report: AnalysisReport
    let initialDimension: SkinDimension
    @State private var selectedDimension: SkinDimension = .waterOil
    @State private var inspection: InspectionTarget?
    private var metric: SkinMetric? { report.skin.first { $0.dimension == selectedDimension } }

    init(report: AnalysisReport, initialDimension: SkinDimension) {
        self.report = report
        self.initialDimension = initialDimension
        _selectedDimension = State(initialValue: initialDimension)
    }

    var body: some View {
        NavigationStack {
          VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("皮肤质量解读结果").font(.system(size: 16, weight: .semibold)).foregroundStyle(RuyuanStyle.ink)
                    Text(report.isSample ? "交互演示 · 不是真实检测" : "照片外观与肤感参考分析")
                        .font(.caption2).foregroundStyle(RuyuanStyle.muted)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RuyuanStyle.muted).frame(width: 30, height: 30)
                        .background(.white.opacity(0.65), in: Circle())
                }.accessibilityLabel("关闭报告详情")
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            GeometryReader { viewport in
              ScrollViewReader { reader in
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ReportSummaryCard(report: report)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "atom").foregroundStyle(RuyuanStyle.purple)
                            Text("综合参考分").font(.subheadline.weight(.semibold))
                            Text(reportScore(report.totalScore)).font(.title3.weight(.semibold)).foregroundStyle(RuyuanStyle.purple)
                        }
                        SkinRadarChart(metrics: report.skin, isSample: report.isSample).frame(height: 205)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("reportRadarChart")
                    }.padding(.horizontal, 6)
                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            dimensionContent
                            if !report.geometry.isEmpty { geometryContent }
                            if !report.overlays.isEmpty { allLayerGallery }
                            qualityContent
                        }
                        // A short dimension still needs enough scroll extent
                        // to bring its tab strip fully to the pinned top. This
                        // prevents the previous radar's caption being stranded
                        // above the tabs merely because content hits the bottom.
                        .frame(minHeight: max(0, viewport.size.height - 66), alignment: .top)
                    } header: { dimensionTabs }
                    .id("reportDimensionSection")
                }.padding(.horizontal, 14).padding(.bottom, 28)
              }
              .onChange(of: selectedDimension) { _, _ in
                  // A tab switch must not retain the previous dimension's long
                  // scroll offset (which used to hide the next title/chart).
                  withAnimation(.easeInOut(duration: 0.25)) {
                      reader.scrollTo("reportDimensionSection", anchor: .top)
                  }
              }
              }
            }
        }
        .background(RuyuanStyle.background).accessibilityIdentifier("reportDetailSheet")
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $inspection) { target in
            OverlayView(report: report, initialLayerID: target.layerID)
        }
        }
    }

    private var dimensionTabs: some View {
        HStack(spacing: 5) {
            ForEach(SkinDimension.allCases) { dimension in
                let value = report.skin.first { $0.dimension == dimension }
                Button { withAnimation(.easeInOut(duration: 0.2)) { selectedDimension = dimension } } label: {
                    VStack(spacing: 4) {
                        Text(dimension.title).font(.system(size: 11, weight: .medium))
                        Text(value?.score == nil ? "未评分" : "\(reportScore(value?.score))分")
                            .font(.system(size: 10)).foregroundStyle(RuyuanStyle.muted)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .foregroundStyle(selectedDimension == dimension ? RuyuanStyle.purple : RuyuanStyle.ink)
                    .background(.white.opacity(selectedDimension == dimension ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selectedDimension == dimension ? RuyuanStyle.purple.opacity(0.75) : .clear, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain).accessibilityIdentifier("detail-tab-\(dimension.rawValue)")
                .accessibilityAddTraits(selectedDimension == dimension ? .isSelected : [])
            }
        }.padding(.vertical, 7).background(RuyuanStyle.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reportDimensionTabs")
    }

    private var dimensionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: selectedDimension.symbol).font(.title3)
                Text(selectedDimension.title).font(.title3.weight(.semibold))
                Text(metric?.score == nil ? "未评分" : reportScore(metric?.score))
                    .font(.title3.weight(.semibold)).foregroundStyle(RuyuanStyle.purple)
                Spacer()
            }.foregroundStyle(RuyuanStyle.ink)
            Text(metric?.status ?? "本报告未提供该维度的结果")
                .font(.caption2).foregroundStyle(RuyuanStyle.muted).lineSpacing(4)
            if let source = metric?.scoreSource {
                Text(source == "selfReport" ? "自评参考分 · 来自本人回答" : source == "photoHeuristic" ? "照片外观参考分 · 非仪器测量" : "分析参考分 · 具体定义见来源")
                    .font(.system(size: 10)).foregroundStyle(RuyuanStyle.purple)
            }
            if let metric, !metric.items.isEmpty {
                ForEach(Array(metric.items.filter { !$0.id.hasSuffix("-formula") }.enumerated()), id: \.element.id) { index, item in
                    detailItem(item, index: index)
                }
                if selectedDimension == .aging { regionalLineChart(metric.items) }
                if metric.items.contains(where: { $0.id.hasSuffix("-formula") }) {
                    DisclosureGroup("参考分计算依据") {
                        ForEach(metric.items.filter { $0.id.hasSuffix("-formula") }) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.valueText).font(.caption.weight(.medium))
                                Text(item.note).font(.caption2).lineSpacing(4).textSelection(.enabled)
                            }.padding(.top, 9)
                        }
                    }.font(.caption).foregroundStyle(RuyuanStyle.muted).padding(14)
                        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                }
            } else {
                RuyuanCard(padding: 16) {
                    Text("本维度尚无可用分项，不以示例数据补齐。可继续查看原图与其他已有结果。")
                        .font(.caption).foregroundStyle(RuyuanStyle.muted).lineSpacing(4)
                }
            }
        }
    }

    private func regionalLineChart(_ items: [SkinItem]) -> some View {
        let regions: [(String, String)] = [("line-forehead", "额头"), ("line-glabella", "眉间"),
                                           ("line-nasolabial", "鼻唇"), ("line-eye", "眼周")]
        let values = regions.map { region -> Double? in
            guard let text = items.first(where: { $0.id == region.0 })?.valueText,
                  text.contains("%"),
                  let range = text.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
                  let value = Double(text[range]), value.isFinite, (0...100).contains(value) else { return nil }
            return value
        }
        let upper = max(1, ((values.compactMap { $0 }.max() ?? 1) / 5).rounded(.up) * 5)
        return VStack(alignment: .leading, spacing: 10) {
            Text("分区域纹理响应").font(.subheadline.weight(.semibold))
            Text("覆盖率 · 图示范围 0—\(String(format: "%.0f", upper))%")
                .font(.caption2).foregroundStyle(RuyuanStyle.muted)
            HStack(alignment: .bottom, spacing: 15) {
                ForEach(regions.indices, id: \.self) { index in
                    VStack(spacing: 7) {
                        Text(values[index].map { String(format: "%.1f%%", $0) } ?? "未提供")
                            .font(.system(size: 10)).foregroundStyle(RuyuanStyle.purple)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 5).fill(RuyuanStyle.lilac.opacity(0.6))
                            if let value = values[index] {
                                RoundedRectangle(cornerRadius: 5).fill(RuyuanStyle.purple.opacity(0.85))
                                    .frame(height: max(value > 0 ? 2 : 0, CGFloat(value / upper) * 85))
                            }
                        }.frame(width: 22, height: 85)
                        Text(regions[index].1).font(.caption2).foregroundStyle(RuyuanStyle.muted)
                    }.frame(maxWidth: .infinity)
                }
            }.padding(.top, 4)
            Text("仅为照片中纹理响应的区域覆盖率，不是皱纹根数或临床严重程度。缺失项不补值。")
                .font(.system(size: 10)).foregroundStyle(RuyuanStyle.muted).lineSpacing(3)
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("regionalLineChart")
    }

    private func detailItem(_ item: SkinItem, index: Int) -> some View {
        let layer = report.overlays.first { $0.id == item.overlayID }
        return RuyuanCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 13) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("\(index + 1). \(item.title)").font(.subheadline.weight(.semibold))
                        Text(observationValue(item)).font(.caption.weight(.medium)).foregroundStyle(RuyuanStyle.purple)
                        Label(item.id.hasPrefix("trained-") ? "整张面部分类 · 无像素位置输出" : layer == nil ? "点击缩略图查看原图" : "图片标色代表对应观察区域",
                              systemImage: layer == nil ? "photo" : "circle.lefthalf.filled")
                            .font(.system(size: 10)).foregroundStyle(RuyuanStyle.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    overlayThumbnail(layer, width: 62, height: 78, accessibilityID: "detail-overlay-\(item.id)")
                }
                if let layer {
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: layer.colorHex)).frame(width: 5, height: 5)
                        Text(layer.title).font(.caption2).foregroundStyle(RuyuanStyle.muted)
                    }
                }
                Text(explanation(for: item)).font(.caption).lineSpacing(5).foregroundStyle(RuyuanStyle.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                itemIndicator(item)
                if item.id.hasPrefix("trained-") || (!report.isSample && report.modelVersion.contains(AppearanceAnalyzer.version)) {
                    DisclosureGroup("计算依据与来源") {
                        Text(item.note).font(.caption2).foregroundStyle(RuyuanStyle.muted).lineSpacing(4).padding(.top,6).textSelection(.enabled)
                    }.font(.caption2).tint(RuyuanStyle.purple)
                }
            }
        }
    }

    /// Translate only the checkpoint's documented labels, while retaining the
    /// original class and probability. A classifier confidence is not coverage.
    private func observationValue(_ item: SkinItem) -> String {
        guard item.id.hasPrefix("trained-") else { return item.valueText }
        var value = item.valueText
        let statuses = ["runtime_not_installed": "未安装推理运行库", "checksum_mismatch": "模型校验未通过",
                        "not_downloaded": "模型尚未下载", "not_bundled": "本安装包未包含该模型",
                        "metadata_mismatch": "模型版本信息校验未通过", "invalid_input": "本次面部裁剪不可用",
                        "invalid_output": "本次模型输出无效", "inference_failed": "本次推理失败", "disabled": "未启用"]
        for (raw, chinese) in statuses { value = value.replacingOccurrences(of: raw, with: chinese + "（" + raw + "）") }
        let labels: [(String, String)]
        if item.id.hasPrefix("trained-skin_type") {
            labels = [("dry", "干性图像类别"), ("normal", "正常图像类别"), ("oily", "油性图像类别")]
        } else if item.id.hasPrefix("trained-wrinkles") {
            labels = [("non-wrinkle", "无线纹图像类别"), ("wrinkle", "有线纹图像类别")]
        } else { labels = [] }
        // Word boundaries prevent translating 'wrinkle' inside 'non-wrinkle'
        // or rewriting a previously inserted original label twice.
        if !labels.isEmpty {
            let alternatives = labels.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")
            if let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z-])(?:" + alternatives + ")(?![A-Za-z-])", options: [.caseInsensitive]) {
                let original = value as NSString
                for match in regex.matches(in: value, range: NSRange(location: 0, length: original.length)).reversed() {
                    let raw = original.substring(with: match.range)
                    if let translated = labels.first(where: { $0.0.caseInsensitiveCompare(raw) == .orderedSame })?.1,
                       let range = Range(match.range, in: value) {
                        value.replaceSubrange(range, with: translated + "（" + raw + "）")
                    }
                }
            }
        }
        return value
    }

    @ViewBuilder
    private func itemIndicator(_ item: SkinItem) -> some View {
        if let assessment = report.assessment,
           ["self-dryness", "self-oiliness", "self-reactivity"].contains(item.id) {
            let selected = item.id == "self-dryness" ? assessment.dryness : item.id == "self-oiliness" ? assessment.oiliness : assessment.reactivity
            VStack(alignment: .leading, spacing: 7) {
                Text("本人自述频率").font(.system(size: 9)).foregroundStyle(RuyuanStyle.muted)
                HStack(spacing: 4) {
                    ForEach(SkinSelfAssessment.frequency.indices, id: \.self) { index in
                        VStack(spacing: 5) {
                            Capsule().fill(index == selected ? RuyuanStyle.purple : RuyuanStyle.lilac).frame(height: 4)
                            Text(SkinSelfAssessment.frequency[index]).font(.system(size: 9))
                                .foregroundStyle(index == selected ? RuyuanStyle.purple : RuyuanStyle.muted)
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
        } else if (["highlight", "pigment-candidates", "redness", "pore-candidates"].contains(item.id) || item.id.hasPrefix("line-")),
                  let range = item.valueText.range(of: #"[0-9]+(?:\.[0-9]+)?(?=\s*%)"#, options: .regularExpression),
                  let percentage = Double(item.valueText[range]), percentage.isFinite, (0...100).contains(percentage) {
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(RuyuanStyle.lilac)
                        Capsule().fill(RuyuanStyle.purple.opacity(0.65))
                            .frame(width: proxy.size.width * CGFloat(percentage / 100))
                    }
                }.frame(height: 4)
                Text("本图覆盖率 \(String(format: "%.1f", percentage))% · 不是严重程度分级")
                    .font(.system(size: 9)).foregroundStyle(RuyuanStyle.muted)
            }
        }
    }

    private func explanation(for item:SkinItem)->String {
        if item.id.hasPrefix("trained-") {
            if item.valueText.hasPrefix("未运行") { return "本次没有此训练模型的可靠分类结果，保留实际未运行状态，不补分类、置信度或分数。" }
            if item.id.hasSuffix("-distribution") { return "各类别的模型 softmax 概率，未做人群校准。它们不是准确率、皮肤面积或临床严重度比例。" }
            let uncertainty = item.valueText.hasPrefix("不确定候选") ? "本次最高类别概率较低，按不确定候选看待。" : ""
            if item.id == "trained-skin_type" { return uncertainty + "训练模型对整张面部裁剪作 dry／normal／oily 图像分类；不测量含水量或皮脂量，也不覆盖本人填写的实际肤感。" }
            if item.id == "trained-acne" { return uncertainty + "保留权重配置中的 level 原始类别，不将其改写为临床分级。模型不区分丘疹、结节或粉刺，不输出病变位置、数量或掩膜。" }
            if item.id == "trained-wrinkles" { return uncertainty + "模型判断面部裁剪更接近 wrinkle 或 non-wrinkle 图像类别。不是皱纹根数、松弛程度或肤龄；下方区域覆盖率来自独立外观方法。" }
            return item.note
        }
        guard !report.isSample,report.modelVersion.contains(AppearanceAnalyzer.version) else{return item.note}
        switch item.id {
        case "highlight":return "黄色标记展示本次照片的高亮反光分布。可以点开原图对照额头、鼻部和两颊，再结合自己当天的出油感记录。"
        case "self-dryness":return "这是你填写的洗脸后紧绷或干燥频率。日常护理以舒适为准，有明显紧绷时先减少过度清洁，做好温和保湿。"
        case "self-oiliness":return "这是你填写的日常出油感。将同光线下的反光分布与自己的感受一起记录，比单看照片更有参考意义。"
        case "self-reactivity":return "这是你自述的日常刺激反应频率。近期先精简护肤、减少多种刺激性产品叠加；持续或反复不适请咨询专业人员。"
        case "lab","ita":return "记录这次照片的色彩基线。后续尽量使用同一相机、相同光线与角度复拍，查看色彩变化趋势。"
        case "pigment-candidates":return "标记展示相对周围颜色较暗的片区。点击缩略图可以查看具体分布；阴影、毛发和妆容也可能形成候选。"
        case "redness":return "红色标记展示相对面颊基线偏红的片区，方便与原图逐处对照。请结合当天温度、运动与实际肤感一起观察。"
        case "pore-candidates":return "蓝色标记展示面颊的细小暗点候选。使用清晰、无美颜的近距照片，便于查看局部纹理；分辨率不足时会提示重拍。"
        case "nose-dark-candidates":return "标记展示鼻梁及上鼻部的细小暗点候选。点开图层查看位置，日常避免反复挤压或用力磨砂。"
        case "texture":return "这项记录局部亮度纹理的离散程度。结合原图和同条件复拍对照，避免将拍摄锐化、噪声变化当作皮肤改变。"
        case "under-eye":return "这项比较照片中眼下与面颊的明暗差。保持光线均匀并露出眼周，眼镜或明显阴影遮挡时会暂停比较。"
        case "hydration":return "本次没有连接水分或皮脂检测仪。下方已单独记录你填写的干燥与出油感。"
        case "barrier":return "本人日常反应与照片偏红外观分开记录，结合实际感受选择温和、精简的护理。"
        default:
            if item.id.hasPrefix("line-") {return "标记展示该部位在这张照片里的线状纹理。放大后可与原图切换查看；表情、角度和光照变化会影响纹理显现。"}
            if item.id.hasSuffix("-formula") {return "参考分来自这张照片的实际像素统计。详细公式与来源可在下方展开查看，适合在一致拍摄条件下留存对照。"}
            return item.note
        }
    }

    private func overlayThumbnail(_ layer: OverlayLayer?, width: CGFloat, height: CGFloat,
                                  accessibilityID: String? = nil) -> some View {
        Button { inspection = InspectionTarget(layerID: layer?.id) } label: {
            ZStack(alignment: .topTrailing) {
                ReportPhotoView(report: report, image: store.image(for: report), layers: layer.map { [$0] } ?? [])
                    .frame(width: width, height: height).background(Color(hex: "28252D"))
                Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white).padding(5).background(.black.opacity(0.5), in: Circle()).padding(4)
                VStack {
                    Spacer()
                    Text(layer == nil ? "原图" : "图层").font(.system(size: 8)).foregroundStyle(.white)
                        .padding(3).frame(maxWidth: .infinity).background(.black.opacity(0.5))
                }
            }
            // The caption's maxWidth must resolve inside the thumbnail, not the
            // containing report row. Otherwise the AX button expands left while
            // its visible photo stays right, and a normal center tap hits air.
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .buttonStyle(.plain).accessibilityLabel(layer.map { "放大\($0.title)图层" } ?? "放大本次原始照片")
        .accessibilityIdentifier(accessibilityID ?? "gallery-overlay-\(layer?.id ?? "original")")
    }

    private var geometryContent: some View {
        RuyuanCard(padding: 14) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 16) {
                    NavigationLink {
                        FaceCalibrationView(report: report).toolbar(.visible, for: .navigationBar)
                    } label: {
                        Label(report.isSample ? "标定工具示例（不保存）" : "发际线与尺寸标定", systemImage: "ruler")
                            .font(.caption.weight(.semibold)).foregroundStyle(RuyuanStyle.purple)
                    }
                    .accessibilityIdentifier("openCalibrationTools")
                    Button {
                        inspection = InspectionTarget(layerID: report.overlays.first { $0.id.hasPrefix("geometry-") }?.id)
                    } label: {
                        HStack {
                            Label("查看五官定位与比例图层", systemImage: "face.dashed")
                            Spacer(); Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }.font(.caption).foregroundStyle(RuyuanStyle.purple).padding(.vertical, 8)
                    }
                    ForEach(report.geometry) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.title).font(.caption.weight(.medium)); Spacer()
                                Text(item.formattedValue).font(.subheadline.weight(.semibold)).foregroundStyle(RuyuanStyle.purple)
                            }
                            Text(item.note).font(.caption2).foregroundStyle(RuyuanStyle.muted).lineSpacing(4)
                        }
                    }
                }.padding(.top, 12)
            } label: {
                Label("面部比例与几何", systemImage: "face.dashed")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(RuyuanStyle.ink)
                    .accessibilityIdentifier("reportGeometryTools")
            }
            // Keep the disclosure's ID on its header, not on the expanded
            // content subtree where it would overwrite the calibration link.
        }
    }

    private var allLayerGallery: some View {
        DisclosureGroup {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(report.overlays) { layer in
                        VStack(alignment: .leading, spacing: 7) {
                            overlayThumbnail(layer, width: 97, height: 120)
                            Text(layer.title).font(.caption2).foregroundStyle(RuyuanStyle.ink)
                                .frame(width: 97, alignment: .leading).lineLimit(2)
                        }
                    }
                }
            }.padding(.top, 12)
        } label: {
            Label("本次全部图层", systemImage: "square.3.layers.3d")
                .font(.caption.weight(.medium)).foregroundStyle(RuyuanStyle.ink)
        }
        .padding(14).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
    }

    private var qualityContent: some View {
        RuyuanCard(padding: 16) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(report.quality) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.passed ? "checkmark.circle" : "info.circle")
                                .foregroundStyle(item.passed ? RuyuanStyle.green : RuyuanStyle.purple)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.caption.weight(.medium))
                                Text(item.detail).font(.caption2).foregroundStyle(RuyuanStyle.muted).lineSpacing(3)
                            }
                        }
                    }
                    Text(report.modelVersion).font(.caption2.monospaced()).foregroundStyle(RuyuanStyle.muted)
                }.padding(.top, 13)
            } label: {
                Label("拍摄质量与来源", systemImage: "checkmark.shield")
                    .font(.caption.weight(.medium)).foregroundStyle(RuyuanStyle.ink)
            }
        }
    }
}

private struct SkinRadarChart: View {
    let metrics: [SkinMetric]
    let isSample: Bool
    private let dimensions = SkinDimension.allCases
    private var completeScores: [Double]? {
        let values = dimensions.compactMap { dimension in metrics.first { $0.dimension == dimension }?.score }
        guard values.count == dimensions.count, values.allSatisfy({ $0.isFinite }) else { return nil }
        return values
    }
    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = Double(min(size.width * 0.31, size.height * 0.34))
                for step in 1...4 {
                    let ring = polygon(center: center, radius: radius * Double(step) / 4)
                    context.fill(ring, with: .color(RuyuanStyle.purple.opacity(0.015)))
                    context.stroke(ring, with: .color(RuyuanStyle.purple.opacity(0.13)), lineWidth: 0.8)
                }
                for index in dimensions.indices {
                    let outer = position(index: index, center: center, radius: radius)
                    var axis = Path(); axis.move(to: center); axis.addLine(to: outer)
                    context.stroke(axis, with: .color(RuyuanStyle.line), lineWidth: 0.7)
                    let value = metrics.first { $0.dimension == dimensions[index] }?.score
                    let label = "\(dimensions[index].title) \(reportScore(value))"
                    context.draw(Text(label).font(.system(size: 10)).foregroundColor(RuyuanStyle.muted),
                                 at: position(index: index, center: center, radius: radius + 26))
                }
                if let scores = completeScores {
                    var data = Path()
                    for index in scores.indices {
                        let point = position(index: index, center: center, radius: radius * min(max(scores[index] / 100, 0), 1))
                        if index == 0 { data.move(to: point) } else { data.addLine(to: point) }
                    }
                    data.closeSubpath()
                    context.fill(data, with: .color(RuyuanStyle.purple.opacity(0.16)))
                    context.stroke(data, with: .color(RuyuanStyle.purple.opacity(0.7)), lineWidth: 1.3)
                    for index in scores.indices {
                        let point = position(index: index, center: center, radius: radius * min(max(scores[index] / 100, 0), 1))
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 2.3, y: point.y - 2.3, width: 4.6, height: 4.6)),
                                     with: .color(RuyuanStyle.purple))
                    }
                }
            }
            if completeScores == nil {
                VStack(spacing: 5) {
                    Text("未提供完整评分").font(.caption.weight(.medium))
                    Text("不以 0 分代替空缺").font(.caption2)
                }.foregroundStyle(RuyuanStyle.muted).padding(10)
                    .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack {
                Spacer()
                Text(isSample ? "演示五维图" : "综合参考 · 不同维度来源见分项")
                    .font(.system(size: 9)).foregroundStyle(RuyuanStyle.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isSample ? "演示雷达图" : completeScores == nil ? "五维评分不完整" : "五维综合参考雷达图，非仪器测量")
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
        path.closeSubpath(); return path
    }
}

private struct ReportFeedbackEditor: View {
    @Environment(\.dismiss) private var dismiss
    let initialNote: String
    let onSave: (String) -> Void
    @State private var note = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 15) {
                Text("哪部分有帮助，或想改进？").font(.headline)
                TextEditor(text: $note).padding(9).frame(minHeight: 100)
                    .accessibilityIdentifier("reportFeedbackEditor")
                    .scrollContentBackground(.hidden).background(.white, in: RoundedRectangle(cornerRadius: 15))
                Label("反馈仅保存在这台设备，不会自动发往服务器。", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(RuyuanStyle.muted)
                Spacer(minLength: 0)
            }.padding(22).background(RuyuanStyle.background)
                .navigationTitle("本次报告反馈").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(String(note.prefix(2000))) } }
                }
        }.onAppear { note = initialNote }
    }
}

private struct ReportShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.loadViewIfNeeded()
        controller.view.accessibilityIdentifier = "reportShareSheet"
        controller.view.accessibilityContainerType = .semanticGroup
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
