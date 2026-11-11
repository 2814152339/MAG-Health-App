import SwiftUI

@MainActor
struct HistoryView: View {
    @EnvironmentObject private var store: AppStore
    let onReport: (AnalysisReport) -> Void
    @State private var pendingDelete: AnalysisReport?

    var body: some View {
        Group {
            if store.reports.isEmpty {
                VStack {
                    EmptyStateCard(symbol: "rectangle.stack", title: "留一份自己的观察记录",
                                   message: "完成一次拍摄或相册分析后，报告会出现在这里。")
                    Button("浏览演示报告") { store.showSample() }
                        .buttonStyle(RuyuanSecondaryButtonStyle())
                        .padding(.horizontal, 50)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RuyuanStyle.background)
            } else {
                List {
                    Section {
                        Text("每一次观察，都是对自己的进一步了解。")
                            .font(.subheadline).foregroundStyle(RuyuanStyle.muted)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 12, trailing: 0))
                    }
                    Section {
                        ForEach(store.reports) { report in
                            Button { onReport(report) } label: {
                                ReportListRow(report: report, image: store.image(for: report))
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.white)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = report } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .accessibilityHint("打开完整报告。向左轻扫可删除。")
                        }
                    } header: {
                        Text("共 \(store.reports.count) 份记录")
                    } footer: {
                        Text("演示报告不是你的分析结果。真实报告中的空缺数据不会被自动补分。")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(RuyuanStyle.background)
            }
        }
        .navigationTitle("我的报告")
        .toolbar(.visible, for: .navigationBar)
        .confirmationDialog("删除这份报告？", isPresented: deletePresented, titleVisibility: .visible) {
            Button("删除报告与关联照片", role: .destructive) {
                if let pendingDelete { store.delete(pendingDelete) }
                pendingDelete = nil
            }
            Button("保留", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("删除后无法恢复。服务端报告会先请求删除远端副本；未成功时会保留记录并提示。")
        }
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}
