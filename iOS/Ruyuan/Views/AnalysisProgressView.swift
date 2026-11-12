import SwiftUI

private enum ScanScene: Int, CaseIterable {
    case outline, face, thirds, eyes, triangle, brow, nose, texture, spots, eyeArea
    var title: String {
        ["定位面部关键点", "脸型与下颌轮廓", "面部纵向比例", "五眼与眼间距", "面部三角与下巴",
         "眉眼精细分析", "鼻唇比例", "面部纹路与肌理", "肤色与点状外观", "眼周外观"][rawValue]
    }
    var duration: Double { [3, 7, 6, 6, 6, 8, 6, 9, 7, 8][rawValue] }
    var tokens: [String] {
        switch self {
        case .outline: return ["face-landmarks", "geometry-mp-"]
        case .face: return ["jaw", "contour", "face-shape", "chin", "depth-surface"]
        case .thirds: return ["third", "vertical", "user-calibration", "model-hairline"]
        case .eyes: return ["five", "eye-inner", "left-eye-width", "right-eye-width", "eye-gap"]
        case .triangle: return ["triangle", "chin"]
        case .brow: return ["brow", "eye-aspect", "canthus", "inner-angle", "geometry-eye"]
        case .nose: return ["nose", "lip", "mouth", "depth-surface"]
        case .texture: return ["wrinkle", "texture", "line-", "forehead", "nasolabial"]
        case .spots: return ["spot", "pore", "dark", "redness", "highlight", "blackhead", "acne"]
        case .eyeArea: return ["under-eye", "eye-area", "dark-circle", "lines-eye", "crow"]
        }
    }
    var landmarkNames: [String] {
        switch self {
        case .outline: return ["faceContour", "leftEye", "rightEye", "nose", "outerLips"]
        case .face, .thirds: return ["faceContour", "leftEyebrow", "rightEyebrow", "nose", "outerLips"]
        case .eyes, .triangle: return ["leftEye", "rightEye", "nose", "faceContour"]
        case .brow: return ["leftEyebrow", "rightEyebrow", "leftEye", "rightEye"]
        case .nose: return ["nose", "noseCrest", "outerLips", "innerLips"]
        default: return []
        }
    }
}

private struct ScanMeasurement: Identifiable {
    let id: String
    let anchor: NormalizedPoint
    let text: String
}

@MainActor
struct AnalysisProgressView: View {
    @EnvironmentObject private var store: AppStore
    @State private var sceneIndex = 0
    @State private var sceneElapsed: Double = 0
    @State private var paused = false
    @State private var skipRequested = false
    @State private var showCancel = false
    @State private var showsSemanticMask = false
    @State private var showsMaskViewer = false
    private var scene: ScanScene { ScanScene.allCases[min(sceneIndex, ScanScene.allCases.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let report = store.scanReport {
                GeometryReader { proxy in
                    if scene == .brow || scene == .eyeArea {
                        ZStack(alignment: .bottom) {
                            scanPhoto(report)
                            resultPanel(report).padding(.horizontal, 24).padding(.bottom, 14)
                        }.frame(width: proxy.size.width, height: proxy.size.height)
                    } else {
                        // Full-face measurements stay above the tech panel,
                        // rather than hiding the chin / lower-face labels.
                        VStack(spacing: 8) {
                            scanPhoto(report)
                            resultPanel(report).padding(.horizontal, 24).padding(.bottom, 14)
                        }.frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                playback
            } else {
                waitingPhoto
                taskPanel
            }
        }
        .background(Color(hex: "444649")).ignoresSafeArea(edges: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analysisScanner")
        .task(id: store.scanReport?.id) {
            guard store.scanReport != nil else { return }
            if skipRequested { store.finishScanPresentation(); return }
            while store.scanReport != nil {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                if skipRequested { store.finishScanPresentation(); return }
                if paused || showsMaskViewer { continue }
                sceneElapsed += 0.25
                if sceneElapsed >= scene.duration {
                    if sceneIndex == ScanScene.allCases.count - 1 { store.finishScanPresentation(); return }
                    withAnimation(.easeInOut(duration: 0.5)) { sceneIndex += 1; sceneElapsed = 0 }
                }
            }
        }
        .alert("结束本次分析？", isPresented: $showCancel) {
            Button("继续分析", role: .cancel) {}
            Button("结束", role: .destructive) {
                if store.scanReport != nil { store.finishScanPresentation() } else { store.cancelAnalysis() }
            }
        } message: { Text("尚未完成的本次任务会被取消。") }
        .fullScreenCover(isPresented: $showsMaskViewer) {
            if let report = store.scanReport {
                OverlayView(report: report, initialLayerID: "semantic-face-skin")
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                if store.scanReport != nil { store.finishScanPresentation() } else { showCancel = true }
            } label: { Image(systemName: "chevron.left").font(.body).frame(width: 36, height: 42) }
                .accessibilityLabel("返回报告")
            Text("测肤质").font(.subheadline.weight(.medium))
            if store.scanReport?.isSample == true {
                Text("演示扫描").font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RuyuanStyle.lilac, in: Capsule())
                    .accessibilityIdentifier("sampleScanNotice")
            }
            Spacer()
            Button("跳过") {
                if store.scanReport != nil { store.finishScanPresentation() } else { skipRequested = true }
            }.font(.caption).padding(.horizontal, 14).accessibilityIdentifier("skipScanButton")
        }.foregroundStyle(RuyuanStyle.ink).padding(.horizontal, 6).background(.white)
    }

    private var waitingPhoto: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image = store.analysisImage { Image(uiImage: image).resizable().scaledToFit() }
                VStack {
                    HStack { Text(store.stage.title).font(.caption); Spacer(); ProgressView().tint(.white) }
                        .padding(14).background(.black.opacity(0.25))
                    Spacer()
                    Text("正在处理这张照片").font(.caption).padding(12)
                        .background(.black.opacity(0.45), in: Capsule()).padding(18)
                }.foregroundStyle(.white)
                TimelineView(.animation) { time in
                    let fraction = time.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                    Rectangle().fill(LinearGradient(colors: [.clear, Color(hex: "7775FF").opacity(0.75), .clear],
                                                    startPoint: .top, endPoint: .bottom))
                        .frame(height: 24).position(x: proxy.size.width / 2, y: proxy.size.height * fraction)
                }.allowsHitTesting(false)
            }
        }.frame(maxHeight: .infinity)
    }

    private var taskPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(store.isCancelling ? "正在结束任务…" : "正在生成您的测肤报告…", systemImage: "sparkle.magnifyingglass")
                .font(.subheadline.weight(.medium))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("进行中  当前已用时 \(max(0, Int(context.date.timeIntervalSince(store.analysisStartedAt)))) 秒")
                    .font(.caption2).foregroundStyle(RuyuanStyle.muted)
            }
            ForEach(AnalysisStage.allCases, id: \.rawValue) { item in
                let a = AnalysisStage.allCases.firstIndex(of: item) ?? 0
                let b = AnalysisStage.allCases.firstIndex(of: store.stage) ?? 0
                HStack(spacing: 7) {
                    Image(systemName: a < b ? "checkmark.circle.fill" : a == b ? "circle.dotted" : "circle")
                    Text(item.title); Spacer()
                    if item == store.stage { ProgressView().controlSize(.mini) }
                }.font(.caption2).foregroundStyle(a <= b ? RuyuanStyle.purple : RuyuanStyle.muted)
            }
            if skipRequested { Text("计算完成后直接打开报告，不再播放结果动画。").font(.caption2).foregroundStyle(RuyuanStyle.muted) }
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 16)).padding(18).padding(.bottom, 20)
    }

    private func displayLayers(_ report: AnalysisReport) -> [OverlayLayer] {
        report.overlays.filter { layer in
            if layer.id.hasPrefix("semantic-") {
                return showsSemanticMask && layer.id == "semantic-face-skin"
            }
            return scene.tokens.contains { layer.id.localizedCaseInsensitiveContains($0) }
        }.map { layer in
            guard layer.id.hasPrefix("geometry-") else { return layer }
            var styled = layer; styled.colorHex = "8C86FF"; return styled
        }
    }

    private func region(_ report: AnalysisReport) -> CGRect? {
        guard scene == .brow || scene == .eyeArea else { return nil }
        let eye = report.landmarks.filter { ["leftEye", "rightEye"].contains($0.id) }
            .min { ($0.points.map(\.x).min() ?? 1) < ($1.points.map(\.x).min() ?? 1) }
        guard let eye else { return nil }
        let browID = eye.id == "leftEye" ? "leftEyebrow" : "rightEyebrow"
        let points = eye.points + (report.landmarks.first { $0.id == browID }?.points ?? [])
        return ReportPhotoTransform.region(points: points, padding: CGSize(width: 0.13, height: 0.19),
                                           minimum: CGSize(width: 0.40, height: 0.48))
    }

    private func scanPhoto(_ report: AnalysisReport) -> some View {
        let focus = region(report)
        let paths = report.landmarks.filter { scene.landmarkNames.contains($0.id) }
        return GeometryReader { proxy in
            let transform = ReportPhotoTransform(
                imageSize: CGSize(width: CGFloat(max(1, report.imageWidth)), height: CGFloat(max(1, report.imageHeight))),
                viewport: proxy.size, region: focus ?? CGRect(x: 0, y: 0, width: 1, height: 1))
            ZStack(alignment: .topLeading) {
                FocusedReportPhotoView(report: report, image: store.analysisImage, layers: displayLayers(report),
                                       landmarks: paths, region: focus)
                    .allowsHitTesting(false)
                measurementGuides(report, transform: transform)
                ForEach(measurements(report)) { item in
                    Text(item.text).font(.system(size: 9, weight: .medium)).multilineTextAlignment(.center)
                        .foregroundStyle(.white).shadow(color: .black.opacity(0.9), radius: 2)
                        .padding(3).background(.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 3))
                        .position(transform.position(item.anchor))
                        .allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: "8A82FF")).frame(width: 5, height: 5)
                        Text("\(scene.title) · \(report.isSample ? "合成示例回放" : "已计算结果回放")").font(.system(size: 10))
                            .accessibilityIdentifier("scanSceneTitle")
                        Spacer()
                        Text("\(sceneIndex + 1)/\(ScanScene.allCases.count)").font(.system(size: 9).monospacedDigit())
                    }
                    if report.overlays.contains(where: { $0.id == "semantic-face-skin" && !$0.paths.isEmpty }) {
                        HStack(spacing: 14) {
                            Button { showsSemanticMask.toggle() } label: {
                                Label("模型皮肤掩膜", systemImage: showsSemanticMask ? "checkmark.circle.fill" : "circle")
                            }.accessibilityIdentifier("scanSemanticMaskToggle")
                                .accessibilityValue(showsSemanticMask ? "显示" : "隐藏")
                            Button("放大核对") { showsMaskViewer = true }
                                .accessibilityIdentifier("scanSemanticMaskViewer")
                            Spacer()
                        }.font(.system(size: 10)).buttonStyle(.plain)
                    }
                }.foregroundStyle(.white).padding(10).background(.black.opacity(0.20))
            }.animation(.easeInOut(duration: 0.5), value: sceneIndex)
        }
        // A focused image is intentionally larger than its visible viewport.
        // Clipping pixels alone does not clip SwiftUI's hit-test region; its
        // offscreen image must not swallow the header's Skip / Back controls.
        .contentShape(Rectangle()).clipped().accessibilityElement(children: .contain)
        .accessibilityLabel(report.isSample ? "合成示意与示例测量标注" : "本次照片与实际测量标注")
        .accessibilityValue(focus == nil ? "完整照片" : "已按本报告眉眼点位定位局部")
        .accessibilityIdentifier("scanOriginalPhoto")
    }

    private func measurementGuides(_ report: AnalysisReport, transform: ReportPhotoTransform) -> some View {
        Canvas { context, _ in
            guard [.face, .thirds, .eyes].contains(scene),
                  let contour = report.landmarks.first(where: { $0.id == "faceContour" }),
                  let left = contour.points.map(\.x).min(), let right = contour.points.map(\.x).max(),
                  let top = contour.points.map(\.y).min(), let bottom = contour.points.map(\.y).max() else { return }
            func line(_ a: NormalizedPoint, _ b: NormalizedPoint, arrows: Bool = false) {
                let start = transform.position(a), end = transform.position(b)
                var path = Path(); path.move(to: start); path.addLine(to: end)
                context.stroke(path, with: .color(arrows ? Color(hex: "8C86FF") : .white.opacity(0.8)),
                               style: StrokeStyle(lineWidth: arrows ? 1.1 : 0.7, dash: arrows ? [] : [2, 3]))
                if arrows {
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    for (point, direction) in [(start, angle), (end, angle + .pi)] {
                        var head = Path()
                        head.move(to: CGPoint(x: point.x + cos(direction - 0.5) * 6, y: point.y + sin(direction - 0.5) * 6))
                        head.addLine(to: point)
                        head.addLine(to: CGPoint(x: point.x + cos(direction + 0.5) * 6, y: point.y + sin(direction + 0.5) * 6))
                        context.stroke(head, with: .color(Color(hex: "8C86FF")), lineWidth: 1)
                    }
                }
            }
            if scene == .face {
                let corners: [NormalizedPoint] = [.init(x: left, y: top), .init(x: right, y: top),
                    .init(x: right, y: bottom), .init(x: left, y: bottom), .init(x: left, y: top)]
                for index in 1..<corners.count { line(corners[index - 1], corners[index]) }
                line(.init(x: max(0, left - 0.025), y: top), .init(x: max(0, left - 0.025), y: bottom), arrows: true)
                line(.init(x: left, y: (top + bottom) / 2), .init(x: right, y: (top + bottom) / 2), arrows: true)
            } else if scene == .thirds {
                let eyebrows = report.landmarks.filter { ["leftEyebrow", "rightEyebrow"].contains($0.id) }.flatMap(\.points)
                let brow = eyebrows.isEmpty ? nil : eyebrows.map(\.y).reduce(0, +) / Double(eyebrows.count)
                let nose = report.landmarks.first(where: { $0.id == "nose" })?.points.map(\.y).max()
                let modelBoundary = report.landmarks.first(where: { $0.id == "modelVisibleHairBoundary" })?.points.map(\.y).sorted()
                let modelTop = modelBoundary.flatMap { $0.isEmpty ? nil : $0[$0.count / 2] }
                let guides = [report.calibration?.hairlineY ?? modelTop, brow, nose, bottom].compactMap { $0 }
                for y in guides { line(.init(x: left, y: y), .init(x: right, y: y)) }
            } else {
                let eyes = report.landmarks.filter { ["leftEye", "rightEye"].contains($0.id) }
                let positions = ([left, right] + eyes.flatMap { eye in [eye.points.map(\.x).min(), eye.points.map(\.x).max()].compactMap { $0 } }).sorted()
                for x in positions { line(.init(x: x, y: top), .init(x: x, y: bottom)) }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func measurements(_ report: AnalysisReport) -> [ScanMeasurement] {
        func center(_ names: [String]) -> NormalizedPoint? {
            let matchingPaths: [LandmarkPath] = report.landmarks.filter { names.contains($0.id) }
            let points: [NormalizedPoint] = matchingPaths.flatMap { $0.points }
            guard !points.isEmpty else { return nil }
            var sumX: Double = 0
            var sumY: Double = 0
            for point in points { sumX += point.x; sumY += point.y }
            let count: Double = Double(points.count)
            let meanX: Double = sumX / count
            let meanY: Double = sumY / count
            return NormalizedPoint(x: meanX, y: meanY)
        }
        var values: [ScanMeasurement] = []
        func add(_ id: String, _ title: String, _ names: [String], dy: Double = 0) {
            guard let metric = report.geometry.first(where: { $0.id == id && $0.value != nil }), var point = center(names) else { return }
            point.y = min(0.96, max(0.04, point.y + dy))
            values.append(.init(id: id, anchor: point, text: title + "\n" + metric.formattedValue))
        }
        func addDistance(_ depthID: String, calibratedID: String? = nil, names: [String], dy: Double = 0) {
            let depth = report.geometry.first { $0.id == depthID && $0.value != nil && $0.unit == "mm" }
            let calibrated = report.geometry.first { $0.id == calibratedID && $0.value != nil && $0.unit == "mm" }
            guard let metric = depth ?? calibrated else { return }
            add(metric.id, depth != nil ? "同拍表面弦距" : "本人标尺二维距离", names, dy: dy)
        }
        switch scene {
        case .face:
            add("v2-jaw-left-angle", "二维轮廓角", ["faceContour"], dy: 0.17)
            add("v2-contour-aspect", "可见轮廓高宽比", ["leftEyebrow", "rightEyebrow"], dy: -0.11)
            addDistance("depth-surface-faceContour", calibratedID: "calibrated-faceContour-mm", names: ["faceContour"], dy: 0.02)
        case .thirds:
            let calibrated = report.geometry.contains { $0.id == "calibrated-upper-third" && $0.value != nil }
            add(calibrated ? "calibrated-upper-third" : "model-third-upper", calibrated ? "标定上庭占比" : "可见边界上段", ["leftEyebrow", "rightEyebrow"], dy: -0.08)
            add(calibrated ? "calibrated-middle-third" : "model-third-middle", calibrated ? "标定中庭占比" : "可见边界中段", ["nose"], dy: -0.05)
            add(calibrated ? "calibrated-lower-third" : "model-third-lower", calibrated ? "标定下庭占比" : "可见边界下段", ["outerLips"], dy: 0.08)
        case .eyes:
            add("v2-five-left-eye", "眼宽 / 平均眼宽", ["leftEye"], dy: -0.055)
            add("v2-five-right-eye", "眼宽 / 平均眼宽", ["rightEye"], dy: -0.055)
            add("v2-five-gap", "眼间距比", ["leftEye", "rightEye"], dy: 0.07)
        case .triangle:
            add("v2-triangle-mouth-angle", "三角顶角", ["outerLips"], dy: -0.045)
            add("v2-chin-height-width", "颏区高宽比", ["faceContour"], dy: 0.20)
            addDistance("depth-surface-lip-to-chin", names: ["outerLips", "faceContour"], dy: 0.12)
        case .brow:
            for (eye, brow, tilt) in [("leftEye", "leftEyebrow", "left-brow-tilt"), ("rightEye", "rightEyebrow", "right-brow-tilt")] {
                add(tilt, "眉端点倾角", [brow], dy: -0.045)
                add("v2-\(eye)-inner-angle", "眼内侧轮廓角", [eye], dy: 0.045)
            }
        case .nose:
            add("nose-mouth", "鼻宽 / 嘴宽", ["nose"], dy: -0.055)
            add("lip-upper-lower", "上下唇轮廓比", ["outerLips"], dy: 0.065)
            addDistance("depth-surface-nose", calibratedID: "calibrated-nose-mm", names: ["nose"], dy: 0.025)
            addDistance("depth-surface-outerLips", calibratedID: "calibrated-outerLips-mm", names: ["outerLips"], dy: -0.025)
        default:
            for item in report.skin.flatMap(\.items) where scene.tokens.contains(where: { item.id.localizedCaseInsensitiveContains($0) }) {
                // Spatial summary, pixel denominator and component count can
                // reference the same model layer; do not stack three labels
                // at one anchor or turn model probabilities into locations.
                guard !item.id.hasSuffix("-pixels"), !item.id.hasSuffix("-components"),
                      !item.id.hasSuffix("-distribution") else { continue }
                guard let id = item.overlayID, let layer = report.overlays.first(where: { $0.id == id }),
                      let rect = ReportPhotoTransform.region(points: layer.paths.flatMap { $0 }, padding: .zero, minimum: .zero) else { continue }
                values.append(.init(id: item.id, anchor: .init(x: Double(rect.midX), y: Double(rect.minY)),
                                    text: item.title + "\n" + item.valueText))
            }
        }
        return Array(values.prefix(6))
    }

    private func resultPanel(_ report: AnalysisReport) -> some View {
        let hasManualThirds = report.geometry.contains { $0.id == "calibrated-upper-third" && $0.value != nil }
        let matchingMetrics = report.geometry.filter { metric in
            guard metric.value != nil else { return false }
            if scene == .thirds { return metric.id.hasPrefix(hasManualThirds ? "calibrated-" : "model-third-") && metric.id.contains("third") }
            return scene.tokens.contains(where: { metric.id.localizedCaseInsensitiveContains($0) })
        }
        let items = report.skin.flatMap(\.items).filter { item in
            !item.id.hasSuffix("-distribution") && scene.tokens.contains(where: { item.id.localizedCaseInsensitiveContains($0) })
        }
        return VStack(alignment: .leading, spacing: 7) {
            HStack { Text(scene.title).font(.caption.weight(.semibold)); Spacer(); Image(systemName: "scope").font(.caption) }
            if scene.rawValue <= ScanScene.nose.rawValue {
                if matchingMetrics.isEmpty {
                    Text(scene == .thirds ? "缺少稳定可见发肤边界及手动标记，不补三段值；可在报告中标定。" : report.isSample ? "当前点位来自手工构造的示例，不是相机检测。" : "显示本次实际识别的面部轮廓与五官点位。")
                        .font(.caption2).lineSpacing(3)
                } else {
                    ForEach(Array(matchingMetrics.prefix(3))) { metric in
                        HStack(alignment: .firstTextBaseline) {
                            Text(metric.title).font(.system(size: 10)).lineLimit(1); Spacer()
                            Text(metric.formattedValue).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        }
                    }
                }
                if scene == .thirds && !matchingMetrics.isEmpty && !hasManualThirds {
                    Text("上界是模型可见发肤边界，不等同已确认的解剖发际线。")
                        .font(.system(size: 9)).foregroundStyle(Color(hex: "C6BFFF"))
                }
            } else if items.isEmpty {
                Text("本次没有这一部位的可靠分项，不生成假计数或严重程度。").font(.caption2).lineSpacing(3)
            } else {
                ForEach(Array(items.prefix(3))) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).font(.system(size: 10)); Spacer()
                        Text(item.valueText).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.trailing)
                    }
                }
            }
            Text("照片外观参考 · 毫米值仅来自同拍深度或本人标定")
                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.60))
        }.foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.72), in: ScanPanelShape())
            .overlay { ScanPanelShape().stroke(Color(hex: "7E78FF"), lineWidth: 1.5) }
            .overlay { RoundedRectangle(cornerRadius: 5).inset(by: 7).stroke(.white.opacity(0.7), lineWidth: 0.7) }
            .overlay(alignment: .topLeading) { Capsule().fill(Color(hex: "7775FF")).frame(width: 55, height: 3).offset(x: 24, y: -3) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("scanMeasurementPanel")
    }

    private var playback: some View {
        HStack {
            Button { if sceneIndex > 0 { sceneIndex -= 1; sceneElapsed = 0 } } label: { Image(systemName: "backward.end").frame(width: 36, height: 38) }
                .disabled(sceneIndex == 0).accessibilityLabel("上一分析画面").accessibilityIdentifier("scanPreviousScene")
            Spacer()
            Button { paused.toggle() } label: { Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill") }
                .font(.caption2).accessibilityIdentifier("scanPausePlayback")
            Spacer()
            Button { if sceneIndex < ScanScene.allCases.count - 1 { sceneIndex += 1; sceneElapsed = 0 } } label: { Image(systemName: "forward.end").frame(width: 36, height: 38) }
                .accessibilityLabel("下一分析画面").accessibilityIdentifier("scanNextScene")
            Button("查看报告") { store.finishScanPresentation() }.font(.caption.weight(.medium)).accessibilityIdentifier("scanViewReport")
        }.foregroundStyle(.white).padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 20)
    }
}

private struct ScanPanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cut: CGFloat = 9
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut)); path.closeSubpath()
        }
    }
}
