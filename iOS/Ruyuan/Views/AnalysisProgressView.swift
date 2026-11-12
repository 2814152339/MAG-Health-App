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
        case .texture: return ["wrinkle", "texture", "line-", "lines", "forehead", "nasolabial"]
        case .spots: return ["spot", "pore", "dark", "redness", "highlight", "blackhead", "acne"]
        case .eyeArea: return ["under-eye", "eye-area", "dark-circle", "lines-eye", "line-eye", "crow"]
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
    var numericValue: Double? = nil
    var unit: String = ""
    var title: String = ""

    func displayedText(progress: Double) -> String {
        guard let value = ScanMotionTimeline.animatedValue(numericValue, progress: progress) else { return text }
        if progress >= 1 { return text }
        return (title.isEmpty ? "" : title + "\n") + String(format: "%.2f", value) + unit
    }
}

@MainActor
struct AnalysisProgressView: View {
    @EnvironmentObject private var store: AppStore
    @State private var sceneIndex = 0
    @State private var clock = ScanPlaybackClock(now: Date())
    @State private var cameraFromRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var cameraFromFocus: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paused = false
    @State private var manuallyInspectedScene = false
    @State private var skipRequested = false
    @State private var showCancel = false
    @State private var showsSemanticMask = false
    @State private var showsMaskViewer = false
    private var scene: ScanScene { ScanScene.allCases[min(sceneIndex, ScanScene.allCases.count - 1)] }
    private var staticInspection: Bool { paused && manuallyInspectedScene }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let report = store.scanReport {
                let activeLayers = displayLayers(report)
                let activePaths = sceneLandmarks(report)
                let activeMeasurements = measurements(report)
                let sampling = activeLayers.first(where: { $0.id == "appearance-under-eye" }).map {
                    OverlayPresentationGeometry.eyeSamplingRegions(for: $0, landmarks: report.landmarks,
                        imageSize: CGSize(width: CGFloat(report.imageWidth), height: CGFloat(report.imageHeight)))
                } ?? []
                GeometryReader { proxy in
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused || showsMaskViewer || reduceMotion)) { context in
                        let elapsed = clock.elapsed(at: context.date)
                        let phases = motionPhases(elapsed: elapsed)
                        let focus = cameraRegion(report, elapsed: elapsed)
                        let focusAmount = cameraFocus(elapsed: elapsed)
                        let photoHeight = proxy.size.height * (0.77 + 0.23 * focusAmount)
                        let exit = (reduceMotion || staticInspection) ? 1 : 1 - ScanMotionTimeline.smoothstep((elapsed - scene.duration + 0.32) / 0.25)
                        ZStack(alignment: .bottom) {
                            scanPhoto(report, focus: focus, elapsed: elapsed, phases: phases, exit: exit,
                                      layers: activeLayers, paths: activePaths, values: activeMeasurements, sampling: sampling)
                                .frame(height: photoHeight)
                                .frame(maxHeight: .infinity, alignment: .top)
                            resultPanel(report)
                                .overlay { ScanTechBezel(progress: phases.panel) }
                                .padding(.horizontal, 22).padding(.bottom, 13)
                                .offset(x: proxy.size.width * CGFloat((1 - phases.panel) + (1 - exit)))
                                .opacity(phases.panel * exit)
                                .allowsHitTesting(false)
                        }
                        .overlay(alignment: .top) { scanTopBar }
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
            clock.reset(at: Date())
            while store.scanReport != nil {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                if skipRequested { store.finishScanPresentation(); return }
                if paused || showsMaskViewer { continue }
                if clock.elapsed(at: Date()) >= scene.duration {
                    if sceneIndex == ScanScene.allCases.count - 1 { store.finishScanPresentation(); return }
                    changeScene(to: sceneIndex + 1)
                }
            }
        }
        .alert("结束本次分析？", isPresented: $showCancel) {
            Button("继续分析", role: .cancel) {}
            Button("结束", role: .destructive) {
                if store.scanReport != nil { store.finishScanPresentation() } else { store.cancelAnalysis() }
            }
        } message: { Text("尚未完成的本次任务会被取消。") }
        .onChange(of: showsMaskViewer) { _, visible in
            if visible { clock.pause(at: Date()) }
            else if !paused { clock.resume(at: Date()) }
        }
        .fullScreenCover(isPresented: $showsMaskViewer) {
            if let report = store.scanReport {
                OverlayView(report: report, initialLayerID: "semantic-face-skin")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                if store.scanReport != nil { store.finishScanPresentation() } else { showCancel = true }
            } label: { Image(systemName: "chevron.left").font(.system(size: 20)).frame(width: 36, height: 44) }
                .accessibilityLabel("返回报告")
            Text("测肤质").font(.system(size: 19, weight: .medium))
            if store.scanReport?.isSample == true {
                Text("演示扫描").font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RuyuanStyle.lilac, in: Capsule())
                    .accessibilityIdentifier("sampleScanNotice")
            }
            Spacer()
            Menu {
                if store.scanReport?.overlays.contains(where: { $0.id == "semantic-face-skin" && !$0.paths.isEmpty }) == true {
                    Button(showsSemanticMask ? "隐藏模型皮肤掩膜" : "显示模型皮肤掩膜") { showsSemanticMask.toggle() }
                        .accessibilityIdentifier("scanSemanticMaskToggle")
                    Button("放大核对掩膜") { clock.pause(at: Date()); showsMaskViewer = true }
                        .accessibilityIdentifier("scanSemanticMaskViewer")
                }
                Text("动画展示本次报告的已有点位与数值，不参与计算。")
            } label: { Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).frame(width: 44, height: 44) }
        }.foregroundStyle(RuyuanStyle.ink).padding(.horizontal, 6).background(.white)
    }

    private var scanTopBar: some View {
        HStack {
            Spacer()
            Button("跳过") {
                if store.scanReport != nil { store.finishScanPresentation() } else { skipRequested = true }
            }
            .font(.system(size: 14)).padding(.horizontal, 19).frame(height: 35)
            .accessibilityIdentifier("skipScanButton")
        }.foregroundStyle(.white).background(.black.opacity(0.12))
    }

    private func motionPhases(elapsed: Double) -> ScanMotionTimeline.Phases {
        if reduceMotion || staticInspection { return .complete }
        if scene == .face {
            func phase(_ start: Double, _ end: Double) -> Double {
                ScanMotionTimeline.smoothstep((elapsed - start) / (end - start))
            }
            return .init(points: phase(0, 0.6), referenceLines: phase(2.0, 2.7),
                         measurements: phase(2.7, 3.9), labels: phase(3.1, 4.0), panel: phase(4.1, 4.4))
        }
        let cameraLead = (scene == .brow || scene == .eyeArea) ? 0.85 : 0.25
        let revealDuration = max(2.3, scene.duration - cameraLead - 1.3)
        return ScanMotionTimeline.phases(elapsed: max(0, elapsed - cameraLead) * 2.3 / revealDuration)
    }

    private func angleProgress(elapsed: Double, phases: ScanMotionTimeline.Phases) -> Double {
        if reduceMotion || staticInspection { return 1 }
        if scene == .face { return ScanMotionTimeline.smoothstep((elapsed - 0.55) / 1.05) }
        return phases.measurements
    }

    private func cameraProgress(elapsed: Double) -> Double {
        (reduceMotion || staticInspection) ? 1 : ScanMotionTimeline.smoothstep(elapsed / 0.85)
    }

    private func cameraRegion(_ report: AnalysisReport, elapsed: Double) -> CGRect {
        let target = region(report) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let t = CGFloat(cameraProgress(elapsed: elapsed))
        return CGRect(x: cameraFromRegion.minX + (target.minX - cameraFromRegion.minX) * t,
                      y: cameraFromRegion.minY + (target.minY - cameraFromRegion.minY) * t,
                      width: cameraFromRegion.width + (target.width - cameraFromRegion.width) * t,
                      height: cameraFromRegion.height + (target.height - cameraFromRegion.height) * t)
    }

    private func cameraFocus(elapsed: Double) -> Double {
        let target = (scene == .brow || scene == .eyeArea) ? 1.0 : 0.0
        return cameraFromFocus + (target - cameraFromFocus) * cameraProgress(elapsed: elapsed)
    }

    private func changeScene(to index: Int) {
        guard ScanScene.allCases.indices.contains(index), index != sceneIndex else { return }
        let now = Date()
        if let report = store.scanReport {
            cameraFromRegion = cameraRegion(report, elapsed: clock.elapsed(at: now))
            cameraFromFocus = cameraFocus(elapsed: clock.elapsed(at: now))
        }
        // Keep one photo node throughout: no implicit old/new-face crossfade.
        sceneIndex = index
        clock.reset(at: now)
        manuallyInspectedScene = paused
        if paused {
            // Explicit stepping while paused is a static inspection of the
            // next result, not an animation silently running behind Pause.
            clock.pause(at: now)
        }
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
                scanTopBar.frame(maxHeight: .infinity, alignment: .top)
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { time in
                        let fraction = time.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                        Rectangle().fill(LinearGradient(colors: [.clear, Color(hex: "7775FF").opacity(0.75), .clear],
                                                        startPoint: .top, endPoint: .bottom))
                            .frame(height: 24).position(x: proxy.size.width / 2, y: proxy.size.height * fraction)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
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
            if scene == .outline { return false }
            if scene == .brow {
                guard let focus = ScanFocusPresentation.eyeFocus(landmarks: report.landmarks) else { return false }
                return focus.allowsGeometryLayer(id: layer.id)
            }
            if scene == .face && layer.id.contains("jaw-left") { return false }
            if scene == .thirds && (layer.id.hasPrefix("geometry-model-hairline") || layer.id.hasPrefix("geometry-user-calibration")) {
                // The same source guides are animated below as white dotted
                // references plus three vertical dimensions, not duplicated
                // as full-face blue horizontal arrow bars.
                return false
            }
            return scene.tokens.contains { layer.id.localizedCaseInsensitiveContains($0) }
        }.map { layer in
            guard layer.id.hasPrefix("geometry-") else { return layer }
            var styled = layer; styled.colorHex = "8C86FF"; return styled
        }
    }

    private func region(_ report: AnalysisReport) -> CGRect? {
        guard scene == .brow || scene == .eyeArea else { return nil }
        return ScanFocusPresentation.eyeFocus(landmarks: report.landmarks)?.region
    }

    private func scanPhoto(_ report: AnalysisReport, focus: CGRect, elapsed: Double,
                           phases: ScanMotionTimeline.Phases, exit: Double, layers: [OverlayLayer],
                           paths: [LandmarkPath], values: [ScanMeasurement], sampling: [CGRect]) -> some View {
        return GeometryReader { proxy in
            let transform = ReportPhotoTransform(
                imageSize: CGSize(width: CGFloat(max(1, report.imageWidth)), height: CGFloat(max(1, report.imageHeight))),
                viewport: proxy.size, region: focus)
            ZStack(alignment: .topLeading) {
                FocusedReportPhotoView(report: report, image: store.analysisImage, region: focus)
                    .allowsHitTesting(false)
                ZStack(alignment: .topLeading) {
                    ScanGeometryDrawing(layers: layers, landmarks: paths, transform: transform,
                                        phases: phases, elapsed: elapsed, reduceMotion: reduceMotion,
                                        angleProgress: angleProgress(elapsed: elapsed, phases: phases), samplingRegions: sampling,
                                        showsFeatureGuides: scene == .brow, showsChinGuides: scene == .triangle)
                    measurementGuides(report, transform: transform, progress: phases.referenceLines,
                                      measurementProgress: phases.measurements)
                    ForEach(values) { item in
                        let progress = item.unit == "°" ? angleProgress(elapsed: elapsed, phases: phases) : phases.measurements
                        let labelOpacity = scene == .face && item.unit == "°" ? progress : phases.labels
                        Text(item.displayedText(progress: progress))
                            .font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.75), radius: 2)
                            .position(transform.position(item.anchor))
                            .opacity(labelOpacity)
                            .offset(y: CGFloat(1 - labelOpacity) * 5)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("scanMeasurement-\(item.id)")
                    }
                    if !sampling.isEmpty {
                        Text("眼下采样范围").font(.system(size: 11)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.35), in: Capsule())
                            .padding(.horizontal, 12).padding(.top, 43).opacity(phases.labels)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("scanEyeSamplingRangeNotice")
                    }
                }.opacity(exit)
            }
        }
        .contentShape(Rectangle()).clipped().accessibilityElement(children: .contain)
        .accessibilityLabel(report.isSample ? "合成示意与示例测量标注" : "本次照片与实际测量标注")
        .accessibilityValue((region(report) == nil ? "完整照片" : "已按本报告眉眼点位定位局部")
            + (phases.panel >= 1 ? " · 标注展开完成" : " · 动画展开中"))
        .accessibilityIdentifier("scanOriginalPhoto")
    }

    private func sceneLandmarks(_ report: AnalysisReport) -> [LandmarkPath] {
        let names: [String]
        switch scene {
        case .outline: names = []
        case .face: names = []
        case .thirds: names = []
        case .eyes: names = ["leftEye", "rightEye"]
        case .triangle: names = []
        case .brow: names = ScanFocusPresentation.eyeFocus(landmarks: report.landmarks)?.landmarkIDs ?? []
        case .nose: names = ["nose", "outerLips", "innerLips"]
        default: names = []
        }
        if scene == .outline {
            // A small set of real feature centers, not 478 points all at once.
            return report.landmarks.filter { ["leftEye", "rightEye", "nose", "outerLips"].contains($0.id) }
                .compactMap { item in
                    guard !item.points.isEmpty else { return nil }
                    let n = Double(item.points.count)
                    return LandmarkPath(id: item.id, points: [.init(x: item.points.map(\.x).reduce(0, +) / n,
                        y: item.points.map(\.y).reduce(0, +) / n)], closed: false)
                }
        }
        return report.landmarks.filter { names.contains($0.id) }
    }

    private func measurementGuides(_ report: AnalysisReport, transform: ReportPhotoTransform, progress: Double,
                                   measurementProgress: Double) -> some View {
        Canvas { context, _ in
            guard [.face, .thirds, .eyes].contains(scene),
                  let contour = report.landmarks.first(where: { $0.id == "faceContour" }),
                  let left = contour.points.map(\.x).min(), let right = contour.points.map(\.x).max(),
                  let top = contour.points.map(\.y).min(), let bottom = contour.points.map(\.y).max() else { return }
            func line(_ a: NormalizedPoint, _ b: NormalizedPoint, arrows: Bool = false) {
                let start = transform.position(a), end = transform.position(b)
                if arrows {
                    ScanDimensionDrawing.draw(from: start, to: end, progress: measurementProgress, context: &context)
                    return
                }
                let points = ScanMotionTimeline.polylinePrefix([start, end], progress: progress)
                var path = Path(); if let first = points.first { path.move(to: first) }; for p in points.dropFirst() { path.addLine(to: p) }
                context.stroke(path, with: .color(.white.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
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
                if let first = guides.first, let last = guides.last {
                    line(.init(x: (left + right) / 2, y: first), .init(x: (left + right) / 2, y: last))
                }
                // Three intervals are drawn only when all four real guides
                // exist. A missing visible hair boundary is not invented.
                if guides.count == 4 {
                    for index in 0..<3 {
                        line(.init(x: max(0.02, left - 0.035), y: guides[index]),
                             .init(x: max(0.02, left - 0.035), y: guides[index + 1]), arrows: true)
                    }
                }
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
            values.append(.init(id: id, anchor: point, text: title + "\n" + metric.formattedValue,
                                numericValue: metric.value, unit: metric.unit, title: title))
        }
        func addDistance(_ depthID: String, calibratedID: String? = nil, names: [String], dy: Double = 0) {
            let depth = report.geometry.first { $0.id == depthID && $0.value != nil && $0.unit == "mm" }
            let calibrated = report.geometry.first { $0.id == calibratedID && $0.value != nil && $0.unit == "mm" }
            guard let metric = depth ?? calibrated else { return }
            add(metric.id, depth != nil ? "同拍表面弦距" : "本人标尺二维距离", names, dy: dy)
        }
        switch scene {
        case .face:
            if let metric = report.geometry.first(where: { $0.id == "v2-jaw-right-angle" && $0.value != nil }),
               let vertex = report.overlays.first(where: { $0.id == "geometry-jaw-right-points" })?.paths.first,
               vertex.count == 3 {
                values.append(.init(id: metric.id, anchor: .init(x: max(0.05, vertex[1].x - 0.075), y: vertex[1].y - 0.025),
                                    text: metric.formattedValue, numericValue: metric.value, unit: metric.unit, title: ""))
            }
            add("v2-contour-aspect", "可见轮廓高宽比", ["leftEyebrow", "rightEyebrow"], dy: -0.11)
            addDistance("depth-surface-faceContour", calibratedID: "calibrated-faceContour-mm", names: ["faceContour"], dy: 0.02)
        case .thirds:
            let calibrated = report.geometry.contains { $0.id == "calibrated-upper-third" && $0.value != nil }
            add(calibrated ? "calibrated-upper-third" : "model-third-upper", calibrated ? "标定上庭占比" : "可见边界上段", ["leftEyebrow", "rightEyebrow"], dy: -0.08)
            add(calibrated ? "calibrated-middle-third" : "model-third-middle", calibrated ? "标定中庭占比" : "可见边界中段", ["nose"], dy: -0.05)
            add(calibrated ? "calibrated-lower-third" : "model-third-lower", calibrated ? "标定下庭占比" : "可见边界下段", ["outerLips"], dy: 0.08)
        case .eyes:
            let keys = ["left-margin", "left-eye", "gap", "right-eye", "right-margin"]
            let titles = ["左留白 / 眼宽", "左眼宽比", "眼间距 / 眼宽", "右眼宽比", "右留白 / 眼宽"]
            if let points = report.overlays.first(where: { $0.id == "geometry-five-eyes-points" })?.paths.first,
               points.count == 10 {
                for index in 0..<5 {
                    guard let metric = report.geometry.first(where: { $0.id == "v2-five-" + keys[index] && $0.value != nil }) else { continue }
                    let a = points[index * 2], b = points[index * 2 + 1]
                    let yOffset = (index == 1 || index == 3) ? 0.09 : -0.065
                    values.append(.init(id: metric.id,
                        anchor: .init(x: (a.x + b.x) / 2, y: min(0.95, max(0.05, (a.y + b.y) / 2 + yOffset))),
                        text: titles[index] + "\n" + metric.formattedValue,
                        numericValue: metric.value, unit: metric.unit, title: titles[index]))
                }
            }
        case .triangle:
            add("v2-triangle-mouth-angle", "三角顶角", ["outerLips"], dy: -0.045)
            add("v2-chin-height-width", "颏区高宽比", ["faceContour"], dy: 0.20)
            addDistance("depth-surface-lip-to-chin", names: ["outerLips", "faceContour"], dy: 0.12)
        case .brow:
            if let focus = ScanFocusPresentation.eyeFocus(landmarks: report.landmarks) {
                // This number belongs to the endpoint–arch–endpoint arc,
                // not the unrelated eyebrow chord's horizontal tilt.
                add("v2-\(focus.browID)-arch-angle", "眉弓轮廓夹角", [focus.browID], dy: -0.045)
                add("v2-\(focus.eyeID)-inner-angle", "眼内侧轮廓角", [focus.eyeID], dy: 0.045)
            }
        case .nose:
            add("nose-mouth", "鼻宽 / 嘴宽", ["nose"], dy: -0.055)
            add("lip-upper-lower", "上下唇轮廓比", ["outerLips"], dy: 0.065)
            addDistance("depth-surface-nose", calibratedID: "calibrated-nose-mm", names: ["nose"], dy: 0.025)
            addDistance("depth-surface-outerLips", calibratedID: "calibrated-outerLips-mm", names: ["outerLips"], dy: -0.025)
        default:
            var labelledLayerIDs = Set<String>()
            for item in report.skin.flatMap(\.items) where scene.tokens.contains(where: { item.id.localizedCaseInsensitiveContains($0) }) {
                // Spatial summary, pixel denominator and component count can
                // reference the same model layer; do not stack three labels
                // at one anchor or turn model probabilities into locations.
                guard !item.id.hasSuffix("-pixels"), !item.id.hasSuffix("-components"),
                      !item.id.hasSuffix("-distribution") else { continue }
                guard let id = item.overlayID, let layer = report.overlays.first(where: { $0.id == id }),
                      let rect = ReportPhotoTransform.region(points: layer.paths.flatMap { $0 }, padding: .zero, minimum: .zero) else { continue }
                guard labelledLayerIDs.insert(id).inserted else { continue }
                values.append(.init(id: item.id, anchor: .init(x: Double(rect.midX), y: Double(rect.minY)),
                                    text: item.title + "\n" + item.valueText))
            }
        }
        return Array(values.prefix(6))
    }

    private func resultPanel(_ report: AnalysisReport) -> some View {
        let hasManualThirds = report.geometry.contains { $0.id == "calibrated-upper-third" && $0.value != nil }
        let matchingMetrics = panelMetrics(report).filter { metric in
            guard metric.value != nil else { return false }
            if scene == .thirds { return metric.id.hasPrefix(hasManualThirds ? "calibrated-" : "model-third-") && metric.id.contains("third") }
            return scene.tokens.contains(where: { metric.id.localizedCaseInsensitiveContains($0) })
        }
        let items = report.skin.flatMap(\.items).filter { item in
            !item.id.hasSuffix("-distribution") && scene.tokens.contains(where: { item.id.localizedCaseInsensitiveContains($0) })
        }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(scene.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                    .accessibilityIdentifier("scanSceneTitle")
                Spacer(minLength: 8)
                Text("\(sceneIndex + 1)/\(ScanScene.allCases.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
            }
            if scene.rawValue <= ScanScene.nose.rawValue {
                if matchingMetrics.isEmpty {
                    Text(scene == .thirds ? "可在报告中补充上界标记" : report.isSample ? "合成点位 · 交互示例" : "已完成本次轮廓定位")
                        .font(.system(size: 12)).lineSpacing(3)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(matchingMetrics.prefix(scene == .thirds ? 3 : 2))) { metric in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(panelMetricTitle(metric)).font(.system(size: 13, weight: .semibold))
                                    .lineLimit(2).minimumScaleFactor(0.8)
                                Text(metric.formattedValue).font(.system(size: 18, weight: .medium)).monospacedDigit()
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else if items.isEmpty {
                Text("这一部位的分项结果待采集").font(.system(size: 12)).lineSpacing(3)
            } else {
                ForEach(Array(items.prefix(2))) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).font(.system(size: 10)); Spacer()
                        Text(item.valueText).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.trailing)
                    }
                }
            }
            Text(report.isSample ? "合成示例 · 非真实测量" : "原图点位 · 照片外观参考")
                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.60))
        }.foregroundStyle(.white).padding(.horizontal, 19).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.72), in: ScanPanelShape())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("scanMeasurementPanel")
    }

    private func panelMetrics(_ report: AnalysisReport) -> [GeometryMetric] {
        let priority: [String]
        switch scene {
        case .face: priority = ["v2-jaw-right-angle", "v2-contour-aspect"]
        case .triangle: priority = ["v2-triangle-mouth-angle", "v2-chin-height-width"]
        case .brow:
            guard let focus = ScanFocusPresentation.eyeFocus(landmarks: report.landmarks) else { return [] }
            priority = ["v2-\(focus.browID)-arch-angle", "v2-\(focus.eyeID)-inner-angle"]
        case .eyes: priority = ["v2-five-gap", "v2-five-left-eye"]
        case .nose: priority = ["nose-mouth", "lip-upper-lower", "v2-nose-height-width", "v2-upper-lower-lip"]
        default: priority = []
        }
        if priority.isEmpty { return report.geometry }
        let chosen = priority.compactMap { id in report.geometry.first { $0.id == id && $0.value != nil } }
        if scene == .brow { return chosen }
        return chosen.isEmpty ? report.geometry : chosen
    }

    private func panelMetricTitle(_ metric: GeometryMetric) -> String {
        switch metric.id {
        case "v2-jaw-right-angle": return "二维轮廓夹角"
        case "v2-contour-aspect": return "轮廓高宽比"
        case "v2-triangle-mouth-angle": return "唇中心三角顶角"
        case "v2-chin-height-width": return "颏区高宽比"
        case "v2-five-gap": return "眼间距 / 平均眼宽"
        case "v2-five-left-eye": return "左眼宽 / 平均眼宽"
        default:
            if metric.id.hasSuffix("arch-angle") { return "眉弓轮廓夹角" }
            if metric.id.hasSuffix("inner-angle") { return "眼内侧轮廓角" }
            if metric.id.hasSuffix("upper-third") || metric.id.hasSuffix("third-upper") { return "上段占比" }
            if metric.id.hasSuffix("middle-third") || metric.id.hasSuffix("third-middle") { return "中段占比" }
            if metric.id.hasSuffix("lower-third") || metric.id.hasSuffix("third-lower") { return "下段占比" }
            return metric.title
        }
    }

    private var playback: some View {
        HStack {
            Button { if sceneIndex > 0 { changeScene(to: sceneIndex - 1) } } label: { Image(systemName: "backward.end").frame(width: 36, height: 38) }
                .disabled(sceneIndex == 0).accessibilityLabel("上一分析画面").accessibilityIdentifier("scanPreviousScene")
            Spacer()
            Button {
                paused.toggle()
                if paused { clock.pause(at: Date()) }
                else if manuallyInspectedScene {
                    // Resuming a manually inspected final frame replays that
                    // scene; a normal mid-animation pause resumes in place.
                    manuallyInspectedScene = false
                    clock.reset(at: Date())
                } else { clock.resume(at: Date()) }
            } label: { Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill") }
                .font(.caption2).accessibilityIdentifier("scanPausePlayback")
            Spacer()
            Button { if sceneIndex < ScanScene.allCases.count - 1 { changeScene(to: sceneIndex + 1) } } label: { Image(systemName: "forward.end").frame(width: 36, height: 38) }
                .accessibilityLabel("下一分析画面").accessibilityIdentifier("scanNextScene")
            Button("查看报告") { store.finishScanPresentation() }.font(.caption.weight(.medium)).accessibilityIdentifier("scanViewReport")
        }.foregroundStyle(.white).padding(.horizontal, 18).padding(.top, 2).padding(.bottom, 16)
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
