import SwiftUI
import UIKit

@main
@MainActor
struct RuyuanApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-camera-review") {
                    CameraReviewUITestHarness()
                } else if ProcessInfo.processInfo.arguments.contains("--ui-test-viewer-framing") {
                    ViewerFramingUITestHarness().environmentObject(store)
                } else {
                    RootView().environmentObject(store)
                }
                #else
                RootView().environmentObject(store)
                #endif
            }
            .preferredColorScheme(.light)
        }
    }
}

#if DEBUG
/// Exercises the production confirmation layout with our own vector illustration.
/// No CameraService, camera permission, private photo, analysis, or persistence.
@MainActor
private struct CameraReviewUITestHarness: View {
    private enum Outcome: Equatable { case review, retake, use, close }
    @State private var outcome: Outcome = .review
    private let image: UIImage

    init() {
        let renderer = ImageRenderer(content: SampleFaceDiagram().frame(width: 600, height: 800))
        renderer.scale = 1
        guard let rendered = renderer.uiImage, rendered.cgImage != nil,
              rendered.size.width == 600, rendered.size.height == 800 else {
            preconditionFailure("Synthetic camera-review fixture must render its actual 600x800 illustration.")
        }
        image = rendered
    }

    var body: some View {
        Group {
            if outcome == .review {
                CameraPhotoReview(image: image,
                    depthNotice: "UI自动测试合成插画 · 不调用摄像头或生成测肤结果",
                    onRetake: { outcome = .retake }, onUse: { outcome = .use },
                    onClose: { outcome = .close })
            } else {
                VStack(spacing: 24) {
                    Text(outcome == .retake ? "测试已收到重拍操作" :
                         outcome == .use ? "测试已收到使用照片操作" : "测试已收到关闭操作")
                        .accessibilityIdentifier("cameraReviewFixtureOutcome")
                    Button("返回照片确认") { outcome = .review }
                        .accessibilityIdentifier("cameraReviewFixtureReturn")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.white).background(.black)
            }
        }
    }
}

/// Opens the unchanged production viewer on the bundled, explicitly synthetic
/// illustration and hand-authored points. No camera, models, network or saves.
@MainActor
private struct ViewerFramingUITestHarness: View {
    private enum Entry: String, Identifiable {
        case layer, original
        var id: String { rawValue }
    }
    @State private var entry: Entry?
    private let report = SampleData.scannerReport

    var body: some View {
        VStack(spacing: 24) {
            Text("仅用于自动测试的原创插画与手工点位，不是真实检测结果。")
            Button("打开合成面部图层") { entry = .layer }
                .accessibilityIdentifier("viewerFixtureLayerEntry")
            Button("打开合成完整原图") { entry = .original }
                .accessibilityIdentifier("viewerFixtureOriginalEntry")
        }
        .padding(24)
        .fullScreenCover(item: $entry) { target in
            OverlayView(report: report,
                initialLayerID: target == .layer ? "sample-pigment" : nil,
                initialItemReference: target == .layer ?
                    OverlayItemPresentation.reference(in: report, dimension: .tone, itemID: "sample-tone") : nil)
        }
    }
}
#endif

@MainActor
struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var consentAction: Int?
    @State private var inputRouter = PhotoAnalysisInputRouter()
    @AppStorage(PhotoAnalysisInputRouter.assessmentPreferenceKey) private var requestsAssessment = false
    @State private var approvedCaptureAction: Int?
    @State private var showAssessment = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeView(onCapture: { requestCapture(0) }, onImport: { requestCapture(1) },
                         onReport: { store.activeReport = $0 })
            }
            .tabItem { Label("测肤", systemImage: "viewfinder") }.tag(0)
            NavigationStack { HistoryView(onReport: { store.activeReport = $0 }) }
                .tabItem { Label("报告", systemImage: "chart.xyaxis.line") }.tag(1)
            NavigationStack { SettingsView() }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(2)
        }
        .tint(RuyuanStyle.purple)
        .fullScreenCover(isPresented: $showCamera, onDismiss: consumeInputIfReady) {
            CameraView(onDepthCapture: { capture in
                inputRouter.receive(image: capture.image, depth: capture.validatedDepth(), depthNotice: capture.depthNotice)
                showCamera = false
            })
        }
        .sheet(isPresented: $showPicker, onDismiss: consumeInputIfReady) {
            PhotoLibraryPicker { result in
                switch result {
                case .success(let image):
                    inputRouter.receiveImportedImage(image)
                case .failure(let error):
                    inputRouter.cancel()
                    store.errorMessage = error.localizedDescription
                }
                showPicker = false
            }
            .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $store.showsAnalysis, onDismiss: { store.presentCompletedReport() }) {
            AnalysisProgressView().interactiveDismissDisabled()
        }
        .sheet(isPresented: $showAssessment, onDismiss: {
            // A cancel or a late duplicate dismissal cannot revive a request.
            guard let input = inputRouter.afterAssessmentDismissal() else { return }
            startAnalysis(input)
        }) {
            SkinAssessmentView(onContinue: { assessment in
                guard inputRouter.completeAssessment(assessment) else { return }
                showAssessment = false
            }, onCancel: {
                inputRouter.cancel()
                showAssessment = false
            })
        }
        .fullScreenCover(item: $store.activeReport) { report in
            NavigationStack {
                ReportView(report: report)
                    .toolbar(.visible, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { store.activeReport = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: Binding(get: { consentAction != nil }, set: { if !$0 { consentAction = nil } }), onDismiss: {
            if let action = approvedCaptureAction {
                approvedCaptureAction = nil
                openCapture(action)
            }
        }) {
            consentSheet
        }
        .alert("请留意", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-scan") {
                store.beginUITestScan()
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-long-summary") {
                store.activeReport = SampleData.longSummaryReport
                return
            }
            #endif
            await store.resumePendingAnalysis()
        }
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-test-scan") || arguments.contains("--ui-test-long-summary") { return }
            #endif
            if phase == .active { Task { await store.resumePendingAnalysis() } }
        }
    }

    private func requestCapture(_ action: Int) {
        if store.hasConsent { openCapture(action) } else { consentAction = action }
    }

    private func consumeInputIfReady() {
        switch inputRouter.afterPhotoDismissal(cameraPresented: showCamera, pickerPresented: showPicker,
                                               requestsAssessment: requestsAssessment) {
        case .wait: break
        case .showAssessment: showAssessment = true
        case .analyze(let input): startAnalysis(input)
        }
    }

    private func startAnalysis(_ input: PhotoAnalysisInput) {
        // The router has already cleared the pending image/answers/depth before
        // this Task can yield or a second onDismiss callback can be delivered.
        Task {
            await store.analyze(image: input.image, assessment: input.assessment,
                                depth: input.depth, depthNotice: input.depthNotice)
        }
    }

    private func openCapture(_ action: Int) {
        inputRouter.cancel()
        if action == 0 { showCamera = true } else { showPicker = true }
    }

    private var consentSheet: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "hand.raised.circle").font(.system(size: 46)).foregroundStyle(.purple)
            Text("照片，由你掌控").font(.largeTitle.bold())
            Text("本机模式使用 iPhone 的 Vision 框架分析面部点位与照片外观，原图和报告保存在本机，不上传。")
            Text("若你在设置中主动启用自有服务端，照片将发送到你指定的服务器处理。删除报告会同步请求删除对应服务端数据。")
            Text("结果用于外观记录。真实报告只展示实际完成的指标；示例报告有单独的演示标记。")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button {
                let action = consentAction ?? 0
                store.acceptConsent()
                approvedCaptureAction = action
                consentAction = nil
            } label: {
                Text("同意并继续").fontWeight(.semibold).frame(maxWidth: .infinity).padding(10)
            }.buttonStyle(.borderedProminent).tint(.purple)
            Button("暂不使用") { consentAction = nil }.frame(maxWidth: .infinity)
        }.padding(28).presentationDetents([.large])
    }
}
