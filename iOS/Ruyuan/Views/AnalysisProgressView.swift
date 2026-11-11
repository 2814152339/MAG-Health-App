import SwiftUI

@MainActor
struct AnalysisProgressView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
          VStack(spacing: 30) {
            Spacer(minLength: 20)
            ZStack {
                Circle().stroke(RuyuanStyle.lilac, lineWidth: 1).frame(width: 210, height: 210)
                Circle().stroke(RuyuanStyle.lilac.opacity(0.5), lineWidth: 1).frame(width: 250, height: 250)
                SampleFaceDiagram().frame(width: 158, height: 206)
                ProgressView().tint(RuyuanStyle.purple)
                    .padding(11).background(.regularMaterial, in: Circle()).offset(x: 83, y: 65)
            }
            .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("为你整理，清晰的观察")
                    .font(.title2.weight(.medium)).foregroundStyle(RuyuanStyle.ink)
                Text(store.isCancelling ? "正在取消并清理本次数据" : store.stage.title)
                    .font(.subheadline).foregroundStyle(RuyuanStyle.purple)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            VStack(spacing: 15) {
                ForEach(AnalysisStage.allCases, id: \.rawValue) { stage in
                    stageRow(stage)
                }
            }
            .padding(22)
            .background(.white, in: RoundedRectangle(cornerRadius: 24))
            Text("进度以实际处理阶段显示，不代表剩余时间。\n照片质量、设备性能与网络状态可能影响处理。")
                .font(.caption).lineSpacing(4).multilineTextAlignment(.center)
                .foregroundStyle(RuyuanStyle.muted)
          }
          .padding(.horizontal, 30)
          .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RuyuanStyle.background)
        .safeAreaInset(edge: .bottom) {
            Button(store.isCancelling ? "正在结束任务…" : "取消本次分析", role: .cancel) { store.cancelAnalysis() }
                .disabled(store.isCancelling)
                .font(.subheadline.weight(.medium)).foregroundStyle(RuyuanStyle.purple)
                .padding(.vertical, 17)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
        }
        .interactiveDismissDisabled()
    }

    private func stageRow(_ stage: AnalysisStage) -> some View {
        let index = AnalysisStage.allCases.firstIndex(of: stage) ?? 0
        let currentIndex = AnalysisStage.allCases.firstIndex(of: store.stage) ?? 0
        let isComplete = index < currentIndex
        let isCurrent = stage == store.stage
        return HStack(spacing: 13) {
            ZStack {
                Circle().fill(isComplete || isCurrent ? RuyuanStyle.lilac : RuyuanStyle.background)
                    .frame(width: 28, height: 28)
                if isComplete {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                        .foregroundStyle(RuyuanStyle.purple)
                } else {
                    Text(String(index + 1)).font(.caption.weight(.medium))
                        .foregroundStyle(isCurrent ? RuyuanStyle.purple : RuyuanStyle.muted)
                }
            }
            Text(stage.title).font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? RuyuanStyle.ink : RuyuanStyle.muted)
            Spacer()
            if isCurrent { ProgressView().controlSize(.small).tint(RuyuanStyle.purple) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stage.title + (isComplete ? "，已完成" : isCurrent ? "，正在处理" : "，等待处理"))
    }
}
