import SwiftUI

@MainActor
struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    let onCapture: () -> Void
    let onImport: () -> Void
    let onReport: (AnalysisReport) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                hero
                if store.hasPendingAnalysis { pendingAnalysisCard }
                captureActions
                preparationGuide
                sampleEntry
                if !store.reports.isEmpty { recentReports }
                footer
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(RuyuanStyle.background)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                Image(systemName: "sparkle")
                    .font(.title3.weight(.light))
                    .foregroundStyle(RuyuanStyle.purple)
                    .frame(width: 38, height: 38)
                    .background(.white, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text("如愿美学").font(.headline).tracking(2)
                    Text("RUYUAN AESTHETICS").font(.system(size: 8, weight: .medium)).tracking(1.4)
                        .foregroundStyle(RuyuanStyle.muted)
                }
                .foregroundStyle(RuyuanStyle.ink)
            }
            Spacer(minLength: 6)
            NavigationLink { SettingsView() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body).foregroundStyle(RuyuanStyle.ink)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.9), in: Circle())
            }
            .accessibilityLabel("隐私与设置")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 15) {
                    Text("YOUR BEAUTY, UNDERSTOOD")
                        .font(.system(size: 9, weight: .medium)).tracking(1.4)
                        .foregroundStyle(RuyuanStyle.purple)
                    Text("看见自己，\n如愿而美。")
                        .font(.system(.largeTitle, design: .serif, weight: .medium))
                        .lineSpacing(6)
                        .foregroundStyle(RuyuanStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("从一张照片开始，\n了解面部比例与皮肤外观。")
                        .font(.subheadline).lineSpacing(4)
                        .foregroundStyle(RuyuanStyle.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SampleFaceDiagram(showsGuides: true)
                    .frame(width: 105, height: 172)
                    .rotationEffect(.degrees(-5))
                    .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                Capsule().fill(RuyuanStyle.purple).frame(width: 18, height: 3)
                Text("以观察理解美，不以数字定义你")
                    .font(.caption).foregroundStyle(RuyuanStyle.purple)
            }
            Text("插画为示意，非真人分析结果")
                .font(.caption2).foregroundStyle(RuyuanStyle.muted)
        }
        .padding(23)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "EEE7F2"), Color(hex: "F5EEEB")],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var captureActions: some View {
        VStack(spacing: 12) {
            Button(action: onCapture) {
                HStack(spacing: 10) {
                    Image(systemName: "camera")
                    Text("开始面部观察")
                    Image(systemName: "arrow.up.right").font(.subheadline)
                }
            }
            .buttonStyle(RuyuanPrimaryButtonStyle())
            .accessibilityIdentifier("startCaptureButton")
            Button(action: onImport) {
                Label("从相册选择照片", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(RuyuanSecondaryButtonStyle())
            .accessibilityIdentifier("importPhotoButton")
            Label(store.serverEnabled ? "已选择服务端分析 · 照片将在同意后上传" : "默认本机处理 · 服务端上传由你决定",
                  systemImage: "lock.shield")
                .font(.caption).foregroundStyle(RuyuanStyle.muted)
                .padding(.top, 3)
                .frame(maxWidth: .infinity)
        }
    }

    private var pendingAnalysisCard: some View {
        RuyuanCard {
            VStack(alignment: .leading, spacing: 13) {
                Label("上次的分析尚未完成", systemImage: "arrow.clockwise.circle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(RuyuanStyle.ink)
                Text("可尝试恢复已保存的分析任务；这不表示任务仍在后台运行。")
                    .font(.caption).lineSpacing(3).foregroundStyle(RuyuanStyle.muted)
                HStack(spacing: 12) {
                    Button { Task { await store.resumePendingAnalysis() } } label: {
                        Label("继续分析", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(RuyuanSecondaryButtonStyle())
                    Button("放弃任务", role: .destructive) { store.cancelAnalysis() }
                        .font(.caption.weight(.medium)).padding(.horizontal, 8)
                }
            }
        }
    }

    private var preparationGuide: some View {
        RuyuanCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "让观察更清晰", subtitle: "一张自然光下的正面照片就好")
                HStack(alignment: .top, spacing: 8) {
                    photoTip("face.smiling", "正对镜头", "五官无遮挡")
                    photoTip("sun.max", "光线均匀", "避开强光阴影")
                    photoTip("camera.filters", "关闭美颜", "保留真实纹理")
                }
            }
        }
    }

    private func photoTip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title3.weight(.light))
                .foregroundStyle(RuyuanStyle.purple).frame(height: 28)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(RuyuanStyle.ink)
            Text(detail).font(.caption2).foregroundStyle(RuyuanStyle.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var sampleEntry: some View {
        Button { store.showSample() } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.stack.3d.up")
                    .font(.title2.weight(.light))
                    .foregroundStyle(RuyuanStyle.purple)
                    .frame(width: 50, height: 56)
                    .background(RuyuanStyle.lilac, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text("先看一份示例报告")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(RuyuanStyle.ink)
                    Text("浏览五维展示与可视化图层 · 纯演示数据")
                        .font(.caption).foregroundStyle(RuyuanStyle.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.subheadline)
                    .foregroundStyle(RuyuanStyle.purple)
            }
            .padding(17)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 23))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sampleReportButton")
    }

    private var recentReports: some View {
        VStack(spacing: 16) {
            HStack {
                SectionHeading(title: "最近的观察")
                NavigationLink { HistoryView(onReport: onReport) } label: {
                    Text("全部").font(.caption.weight(.medium)).foregroundStyle(RuyuanStyle.purple)
                }
            }
            RuyuanCard(padding: 16) {
                VStack(spacing: 14) {
                    ForEach(Array(store.reports.prefix(2))) { report in
                        if report.id != store.reports.first?.id { Divider().overlay(RuyuanStyle.line) }
                        Button { onReport(report) } label: {
                            ReportListRow(report: report, image: store.image(for: report))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text("仅用于外观观察与信息记录，不用于疾病诊断、治疗或医疗决策。")
            .font(.caption2).lineSpacing(4).foregroundStyle(RuyuanStyle.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
    }
}
