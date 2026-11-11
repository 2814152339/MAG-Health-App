import SwiftUI

@MainActor
struct FaceCalibrationView:View {
    @EnvironmentObject private var store:AppStore
    @Environment(\.dismiss) private var dismiss
    let report:AnalysisReport
    @State private var hairlineY:Double?
    @State private var pupilDistance=""
    @State private var error:String?
    @State private var saved=false
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text("发际线与尺寸标定").font(.title2.bold()).foregroundStyle(RuyuanStyle.ink)
                Text("轻点照片中额头中央的真实发际线，补全三庭比例；头发遮挡时可只做尺标，不必猜位置。")
                    .font(.subheadline).foregroundStyle(RuyuanStyle.muted)
                GeometryReader { proxy in
                    let ratio=min(proxy.size.width/CGFloat(report.imageWidth),proxy.size.height/CGFloat(report.imageHeight))
                    let size=CGSize(width:CGFloat(report.imageWidth)*ratio,height:CGFloat(report.imageHeight)*ratio)
                    let x=(proxy.size.width-size.width)/2,y=(proxy.size.height-size.height)/2
                    ZStack {
                        ReportPhotoView(report:report,image:store.image(for:report),showsLandmarks:true)
                        if let hairlineY {
                            Path { path in
                                path.move(to:CGPoint(x:x,y:y+CGFloat(hairlineY)*size.height))
                                path.addLine(to:CGPoint(x:x+size.width,y:y+CGFloat(hairlineY)*size.height))
                            }.stroke(RuyuanStyle.purple,style:StrokeStyle(lineWidth:2,dash:[5,3]))
                        }
                    }.contentShape(Rectangle()).onTapGesture { point in
                        let value=(point.y-y)/size.height
                        if point.x>=x && point.x<=x+size.width && (0...1).contains(value) {hairlineY=Double(value);saved=false}
                    }
                }.frame(height:390).background(Color.black).clipShape(RoundedRectangle(cornerRadius:18)).accessibilityIdentifier("calibrationPhoto")
                HStack {
                    Text(hairlineY == nil ? "尚未标记发际线":"已标记；可再次轻点调整").font(.caption).foregroundStyle(RuyuanStyle.muted)
                    Spacer()
                    Button("重置本次标记"){hairlineY=nil}.font(.caption)
                }
                VStack(alignment:.leading,spacing:10) {
                    Text("本人实测瞳距（可选）").font(.subheadline.weight(.semibold))
                    HStack {TextField("已实测才填，例如 63.5",text:$pupilDistance).keyboardType(.decimalPad);Text("mm")}
                        .padding(14).background(.white,in:RoundedRectangle(cornerRadius:12))
                    Text("没有实测值请留空；不使用默认人均瞳距。提供尺标后，毫米值仍是照片平面投影估算。")
                        .font(.caption).foregroundStyle(RuyuanStyle.muted)
                }
                if let error {Text(error).font(.caption).foregroundStyle(.red)}
                if saved {Label("标定已保存，原始点位与分析结果保留",systemImage:"checkmark.circle").font(.caption).foregroundStyle(RuyuanStyle.green)}
                Button("保存标定") {
                    do {
                        let text=pupilDistance.trimmingCharacters(in:.whitespaces)
                        let mm=text.isEmpty ? nil:Double(text)
                        if !text.isEmpty && mm == nil {throw AnalysisError.poorQuality("请输入实测瞳距数字，或留空。")}
                        let current=store.reports.first{$0.id == report.id} ?? report
                        let calibrated=try FaceCalibration.applying(to:current,hairlineY:hairlineY,pupilDistanceMM:mm)
                        try store.saveCalibratedReport(calibrated)
                        error=nil;saved=true
                    } catch {self.error=error.localizedDescription}
                }.buttonStyle(RuyuanPrimaryButtonStyle()).disabled(report.isSample)
                if report.isSample {Text("演示报告不允许保存本人标定，请使用自己拍摄的照片。").font(.caption).foregroundStyle(RuyuanStyle.muted)}
            }.padding(20)
        }.background(RuyuanStyle.background).navigationTitle("手动标定").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                hairlineY=report.calibration?.hairlineY
                if let mm=report.calibration?.pupilDistanceMM {pupilDistance=String(format:"%.1f",mm)}
            }
    }
}
