import SwiftUI

private enum ScanScene: Int, CaseIterable {
    case outline, face, thirds, eyes, triangle, brow, nose, texture, spots, eyeArea
    var title: String {
        switch self {
        case .outline:return "定位面部关键点"
        case .face:return "脸型与下颌轮廓"
        case .thirds:return "面部纵向比例"
        case .eyes:return "五眼与眼间距"
        case .triangle:return "面部三角与下巴"
        case .brow:return "眉眼精细分析"
        case .nose:return "鼻唇比例"
        case .texture:return "面部纹路与肌理"
        case .spots:return "肤色与点状外观"
        case .eyeArea:return "眼周外观"
        }
    }
    var tokens:[String] {
        switch self {
        case .outline:return ["face-landmarks"]
        case .face:return ["jaw","contour","face-shape","chin"]
        case .thirds:return ["third","vertical","lower-face"]
        case .eyes:return ["five","eye-inner","left-eye-width","right-eye-width","eye-gap"]
        case .triangle:return ["triangle","chin"]
        case .brow:return ["brow","eye-aspect","canthus"]
        case .nose:return ["nose","lip","mouth"]
        case .texture:return ["wrinkle","texture","line","forehead","nasolabial"]
        case .spots:return ["spot","pore","dark","redness","highlight","blackhead"]
        case .eyeArea:return ["under-eye","eye-area","dark-circle","crow"]
        }
    }
    var landmarkNames:[String] {
        switch self {
        case .outline:return ["faceContour","leftEye","rightEye","nose","outerLips"]
        case .face,.thirds:return ["faceContour","leftEyebrow","rightEyebrow","nose","outerLips"]
        case .eyes,.triangle:return ["leftEye","rightEye","nose","faceContour"]
        case .brow:return ["leftEyebrow","rightEyebrow","leftEye","rightEye"]
        case .nose:return ["nose","noseCrest","outerLips","innerLips"]
        default:return []
        }
    }
    var isCloseUp:Bool { self == .brow || self == .eyeArea }
}

@MainActor
struct AnalysisProgressView: View {
    @EnvironmentObject private var store:AppStore
    @State private var sceneIndex = 0
    @State private var paused = false
    @State private var skipRequested = false
    @State private var showCancel = false
    private var scene:ScanScene { ScanScene.allCases[min(sceneIndex,ScanScene.allCases.count-1)] }
    var body: some View {
        VStack(spacing:0) {
            header
            if let report=store.scanReport {
                scanPhoto(report)
                resultPanel(report)
                playback(report)
            } else {
                waitingPhoto
                taskPanel
            }
        }
        .background(Color(hex:"444649")).ignoresSafeArea(edges:.bottom)
        .accessibilityIdentifier("analysisScanner")
        .task(id:store.scanReport?.id) {
            guard store.scanReport != nil else { return }
            if skipRequested { store.finishScanPresentation();return }
            while sceneIndex < ScanScene.allCases.count {
                do { try await Task.sleep(for:.milliseconds(250)) } catch { return }
                if paused { continue }
                var elapsed = 0
                while elapsed < 12 {
                    do { try await Task.sleep(for:.milliseconds(250)) } catch { return }
                    if !paused { elapsed += 1 }
                    if skipRequested { store.finishScanPresentation();return }
                }
                if sceneIndex < ScanScene.allCases.count-1 {
                    withAnimation(.easeInOut(duration:0.45)) { sceneIndex += 1 }
                } else {
                    store.finishScanPresentation();return
                }
            }
        }
        .alert("结束本次分析？",isPresented:$showCancel) {
            Button("继续分析",role:.cancel) {}
            Button("结束",role:.destructive) {
                if store.scanReport != nil { store.finishScanPresentation() } else { store.cancelAnalysis() }
            }
        } message:{ Text("尚未完成的本次任务会被取消。") }
    }
    private var header:some View {
        HStack {
            Button {
                if store.scanReport != nil { store.finishScanPresentation() } else { showCancel=true }
            } label:{Image(systemName:"chevron.left").font(.title3).frame(width:40,height:42)}
            Text("测肤质").font(.headline)
            Spacer()
            Button("跳过") {
                if store.scanReport != nil { store.finishScanPresentation() } else { skipRequested=true }
            }.font(.subheadline).padding(.horizontal,14).accessibilityIdentifier("skipScanButton")
        }.foregroundStyle(RuyuanStyle.ink).padding(.vertical,5).padding(.horizontal,8).background(.white)
    }
    private var waitingPhoto:some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image=store.analysisImage { Image(uiImage:image).resizable().scaledToFit() }
                VStack {
                    HStack { Text(store.stage.title).font(.caption);Spacer();ProgressView().tint(.white) }
                        .padding(14).background(.black.opacity(0.2))
                    Spacer()
                    Text("正在处理这张照片").font(.subheadline).padding(12).background(.black.opacity(0.45),in:Capsule()).padding(18)
                }.foregroundStyle(.white)
                TimelineView(.animation) { time in
                    let fraction = time.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:3)/3
                    Rectangle().fill(LinearGradient(colors:[.clear,Color(hex:"7775FF").opacity(0.75),.clear],startPoint:.top,endPoint:.bottom))
                        .frame(height:24).position(x:proxy.size.width/2,y:proxy.size.height*fraction)
                }.allowsHitTesting(false)
            }
        }.frame(maxHeight:.infinity)
    }
    private var taskPanel:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(store.isCancelling ? "正在结束任务…":"正在生成您的测肤报告…").font(.headline)
            TimelineView(.periodic(from:.now,by:1)) { context in
                Text("进行中  当前已用时 \(max(0,Int(context.date.timeIntervalSince(store.analysisStartedAt)))) 秒")
                    .font(.caption).foregroundStyle(RuyuanStyle.muted)
            }
            ForEach(AnalysisStage.allCases,id:\.rawValue) { item in
                let a=AnalysisStage.allCases.firstIndex(of:item) ?? 0
                let b=AnalysisStage.allCases.firstIndex(of:store.stage) ?? 0
                HStack {
                    Image(systemName:a < b ? "checkmark.circle.fill":a == b ? "circle.dotted":"circle")
                    Text(item.title)
                    Spacer()
                    if item == store.stage { ProgressView().controlSize(.small) }
                }.font(.caption).foregroundStyle(a <= b ? RuyuanStyle.purple:RuyuanStyle.muted)
            }
            if skipRequested { Text("已跳过结果动画，计算完成后直接打开报告。").font(.caption).foregroundStyle(RuyuanStyle.muted) }
        }.padding(22).background(.white,in:RoundedRectangle(cornerRadius:18)).padding(20).padding(.bottom,15)
    }
    private func scanPhoto(_ report:AnalysisReport)->some View {
        let layers=report.overlays.filter { layer in scene.tokens.contains(where:{layer.id.localizedCaseInsensitiveContains($0)}) }
        let selected=report.landmarks.filter { scene.landmarkNames.contains($0.id) }
        return GeometryReader { proxy in
            ZStack(alignment:.topLeading) {
                ReportPhotoView(report:report,image:store.analysisImage,layers:layers)
                if !selected.isEmpty {
                    let w=CGFloat(report.imageWidth),h=CGFloat(report.imageHeight)
                    let factor=min(proxy.size.width/max(w,1),proxy.size.height/max(h,1))
                    NormalizedOverlayDrawing(layers:[],landmarks:selected)
                        .frame(width:w*factor,height:h*factor)
                        .position(x:proxy.size.width/2,y:proxy.size.height/2)
                }
                VStack(alignment:.leading,spacing:5) {
                    Text(scene.title).font(.subheadline.weight(.semibold))
                    Text("已计算结果 · \(sceneIndex+1)/\(ScanScene.allCases.count)").font(.caption2)
                }.foregroundStyle(.white).padding(12).background(.black.opacity(0.35),in:RoundedRectangle(cornerRadius:10)).padding(12)
            }
            .scaleEffect(scene.isCloseUp ? 1.55:1,anchor:scene.isCloseUp ? .top:.center)
            .animation(.easeInOut(duration:0.5),value:sceneIndex)
        }.clipped().frame(maxHeight:.infinity).accessibilityIdentifier("scanOriginalPhoto")
    }
    private func resultPanel(_ report:AnalysisReport)->some View {
        let metrics=report.geometry.filter{ metric in metric.value != nil && scene.tokens.contains(where:{metric.id.localizedCaseInsensitiveContains($0)}) }
        let layers=report.overlays.filter{layer in scene.tokens.contains(where:{layer.id.localizedCaseInsensitiveContains($0)})}
        return VStack(alignment:.leading,spacing:9) {
            HStack {Text(scene.title).font(.headline);Spacer();Image(systemName:"viewfinder")}
            if sceneIndex <= ScanScene.nose.rawValue {
                if metrics.isEmpty {
                    Text(scene == .thirds ? "三庭需要发际线位置，可在报告的校准工具中手动标记。":"已显示实际识别的面部轮廓与关键点。")
                        .font(.subheadline).fixedSize(horizontal:false,vertical:true)
                } else {
                    ForEach(Array(metrics.prefix(4))) { metric in
                        HStack(alignment:.firstTextBaseline) {
                            Text(metric.title).font(.caption).lineLimit(2)
                            Spacer()
                            Text(metric.formattedValue).font(.subheadline.weight(.medium)).monospacedDigit()
                        }
                    }
                }
                Text("二维照片投影 · 无标尺时使用比例与角度，不伪造毫米值").font(.system(size:10)).foregroundStyle(.white.opacity(0.6))
            } else if layers.isEmpty {
                Text("本次未形成这一部位的有效标注，请在报告中查看采样说明。").font(.caption)
            } else {
                ForEach(Array(layers.prefix(3))) { layer in
                    HStack { Circle().fill(Color(hex:layer.colorHex)).frame(width:5,height:5);Text(layer.title);Spacer();Text(layer.paths.isEmpty ? "无有效标注":"已生成标注") }
                        .font(.caption)
                }
                Text("显示实际图像响应；具体含义见报告，不将候选标注当诊断。").font(.system(size:10)).foregroundStyle(.white.opacity(0.6))
            }
        }.foregroundStyle(.white).padding(18).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.black.opacity(0.55),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(Color(hex:"7775FF"),lineWidth:2))
            .padding(.horizontal,20).padding(.top,14).frame(minHeight:165)
    }
    private func playback(_ report:AnalysisReport)->some View {
        HStack {
            Button { if sceneIndex>0 { sceneIndex -= 1 } } label:{Image(systemName:"backward.end").frame(width:44,height:44)}.disabled(sceneIndex == 0)
            Spacer()
            Button { paused.toggle() } label:{Label(paused ? "继续":"暂停",systemImage:paused ? "play.fill":"pause.fill")}.font(.caption)
            Spacer()
            Button("查看报告") {store.finishScanPresentation()}.font(.subheadline.weight(.medium)).accessibilityIdentifier("scanViewReport")
        }.foregroundStyle(.white).padding(.horizontal,24).padding(.top,8).padding(.bottom,30)
    }
}
