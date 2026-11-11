import Foundation

/// Optional, user-confirmed calibration. The original landmark/appearance evidence is retained.
enum FaceCalibration {
    static func applying(to source:AnalysisReport,hairlineY:Double?,pupilDistanceMM:Double?) throws -> AnalysisReport {
        guard hairlineY != nil || pupilDistanceMM != nil else { throw AnalysisError.poorQuality("请先在照片上标记发际线，或填写本人实测瞳距。") }
        let paths=Dictionary(uniqueKeysWithValues:source.landmarks.map{($0.id,$0.points)})
        func mean(_ key:String)->NormalizedPoint? {
            guard let p=paths[key],!p.isEmpty else{return nil}
            return .init(x:p.map(\.x).reduce(0,+)/Double(p.count),y:p.map(\.y).reduce(0,+)/Double(p.count))
        }
        var report=source
        report.geometry.removeAll{$0.id.hasPrefix("calibrated-")}
        report.overlays.removeAll{$0.id == "geometry-user-calibration"}
        var lines:[[NormalizedPoint]]=[]
        let w=Double(source.imageWidth),h=Double(source.imageHeight)
        guard w>0,h>0 else{throw AnalysisError.invalidImage}
        if let y=hairlineY {
            guard y.isFinite,(0...1).contains(y),
                  let lb=mean("leftEyebrow"),let rb=mean("rightEyebrow"),
                  let nose=paths["nose"]?.map(\.y).max(),let chin=paths["faceContour"]?.map(\.y).max(),
                  y < (lb.y+rb.y)/2, (lb.y+rb.y)/2 < nose, nose < chin else {
                throw AnalysisError.poorQuality("发际线需位于眉毛上方；请露出额头并在真实发际线中央轻点。")
            }
            let brow=(lb.y+rb.y)/2,total=chin-y
            let values=[("upper-third","上庭占比",brow-y),("middle-third","中庭占比",nose-brow),("lower-third","下庭占比",chin-nose)]
            for (id,title,value) in values {
                report.geometry.append(.init(id:"calibrated-"+id,title:title,value:value/total*100,unit:"%",note:"发际线由你手动标记，归一化Y=\(String(format:"%.4f",y))；眉线取双眉点均值，鼻底取鼻部最大Y，颏底取轮廓最大Y。三段之和100%，未使用审美正常阈值。"))
            }
            let left=paths["faceContour"]?.map(\.x).min() ?? 0.2,right=paths["faceContour"]?.map(\.x).max() ?? 0.8
            for value in [y,brow,nose,chin] {lines.append([.init(x:left,y:value),.init(x:right,y:value)])}
        }
        if let mm=pupilDistanceMM {
            guard mm.isFinite,(35...85).contains(mm),let a=mean("leftPupil"),let b=mean("rightPupil") else {
                throw AnalysisError.poorQuality("瞳距需填写本人实际测量的35–85毫米；本次照片也必须检测到双侧瞳孔。")
            }
            let distance=hypot((a.x-b.x)*w,(a.y-b.y)*h)
            guard distance>20 else {throw AnalysisError.poorQuality("瞳孔间距像素过小，无法稳定标定，请靠近拍摄。")}
            let scale=mm/distance
            let spans=[("faceContour","面部轮廓横宽估算"),("leftEye","左眼裂横宽估算"),("rightEye","右眼裂横宽估算"),("nose","鼻部轮廓横宽估算"),("outerLips","唇部横宽估算")]
            for (key,title) in spans {
                guard let points=paths[key],let low=points.map(\.x).min(),let high=points.map(\.x).max(),high>low else{continue}
                report.geometry.append(.init(id:"calibrated-"+key+"-mm",title:title,value:(high-low)*w*scale,unit:"mm",note:"依据你输入的本人实测瞳距\(String(format:"%.1f",mm))mm、Vision二维瞳孔中心计算每像素比例；只作同一照片平面投影估算，不是3D实体/骨骼尺寸。原始比例与点位保留。"))
            }
            lines.append([a,b])
        }
        report.overlays.append(.init(id:"geometry-user-calibration",title:"本人确认的手动标定",colorHex:"7775FF",kind:.lines,paths:lines,note:"横线来自本人手动确认的发际线和本报告五官点；毫米值仅在本人提供实测尺标时计算。",source:"User-confirmed image calibration v1"))
        try ReportValidator.validate(report)
        return report
    }
}
