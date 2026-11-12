import SwiftUI
import UIKit

enum RuyuanStyle {
    static let background = Color(hex: "F0EFFF")
    static let ink = Color(hex: "252138")
    static let muted = Color(hex: "7A758C")
    static let purple = Color(hex: "6250E8")
    static let lilac = Color(hex: "E7E2FF")
    static let line = Color(hex: "E7E4F4")
    static let green = Color(hex: "547B6D")
    static let peach = Color(hex: "F2E5DF")
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(cleaned, radix: 16) ?? 0x6250E8
        self.init(.sRGB,
                  red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255,
                  opacity: 1)
    }
}

struct RuyuanCard<Content: View>: View {
    var padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(RuyuanStyle.line.opacity(0.7), lineWidth: 0.7)
            }
    }
}

struct RuyuanPill: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = RuyuanStyle.purple

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(tint)
        .background(tint.opacity(0.09), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RuyuanPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity)
            .background(RuyuanStyle.purple, in: RoundedRectangle(cornerRadius: 18))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

struct RuyuanSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(RuyuanStyle.purple)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(RuyuanStyle.lilac.opacity(configuration.isPressed ? 0.8 : 0.5),
                        in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(RuyuanStyle.ink)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(RuyuanStyle.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReportThumbnail: View {
    let report: AnalysisReport
    let image: UIImage?

    var body: some View {
        ZStack {
            RuyuanStyle.lilac
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if report.isSample {
                SampleFaceDiagram().padding(7)
            } else {
                Image(systemName: "person.crop.rectangle")
                    .font(.title2).foregroundStyle(RuyuanStyle.purple)
            }
        }
        .frame(width: 62, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)
    }
}

struct ReportListRow: View {
    let report: AnalysisReport
    let image: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            ReportThumbnail(report: report, image: image)
            VStack(alignment: .leading, spacing: 7) {
                Text(report.isSample ? "了解你的示例报告" : "面部外观分析")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(RuyuanStyle.ink)
                Text(report.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(RuyuanStyle.muted)
                Text(report.origin.title)
                    .font(.caption.weight(.medium)).foregroundStyle(RuyuanStyle.purple)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(RuyuanStyle.muted)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// An original vector illustration, never a substitute for a person's photo.
struct SampleFaceDiagram: View {
    var showsGuides = false
    var body: some View {
        GeometryReader { proxy in
            Canvas { context,size in
                let w=size.width,h=size.height
                func point(_ x:CGFloat,_ y:CGFloat)->CGPoint {CGPoint(x:x*w,y:y*h)}
                func ellipse(_ x:CGFloat,_ y:CGFloat,_ width:CGFloat,_ height:CGFloat)->Path {
                    Path(ellipseIn:CGRect(x:x*w,y:y*h,width:width*w,height:height*h))
                }
                func fill(_ path:Path,_ colors:[Color],_ from:CGPoint,_ to:CGPoint) {
                    context.fill(path,with:.linearGradient(Gradient(colors:colors),startPoint:from,endPoint:to))
                }
                // Original layered vector avatar; decorative, never an analyzed person's image.
                context.fill(ellipse(0.13,0.13,0.74,0.75),with:.radialGradient(Gradient(colors:[.white.opacity(0.9),RuyuanStyle.lilac.opacity(0.1)]),center:point(0.5,0.48),startRadius:0,endRadius:w*0.55))
                fill(ellipse(0.38,0.025,0.25,0.16),[Color(hex:"45434C"),Color(hex:"17151E")],point(0.4,0.02),point(0.6,0.2))
                fill(ellipse(0.23,0.11,0.54,0.59),[Color(hex:"514D55"),Color(hex:"211C28")],point(0.3,0.12),point(0.73,0.6))
                var shoulders=Path()
                shoulders.move(to:point(0.20,0.96));shoulders.addQuadCurve(to:point(0.37,0.79),control:point(0.20,0.82))
                shoulders.addLine(to:point(0.63,0.79));shoulders.addQuadCurve(to:point(0.8,0.96),control:point(0.79,0.82));shoulders.closeSubpath()
                fill(shoulders,[Color.white,Color(hex:"DCD4F4")],point(0.4,0.80),point(0.6,0.96))
                var neck=Path();neck.move(to:point(0.42,0.65));neck.addLine(to:point(0.58,0.65));neck.addLine(to:point(0.61,0.82));neck.addQuadCurve(to:point(0.39,0.82),control:point(0.5,0.89));neck.closeSubpath()
                fill(neck,[Color(hex:"DFAE98"),Color(hex:"F3D3BB")],point(0.5,0.65),point(0.5,0.84))
                for x:CGFloat in [0.25,0.69] {fill(ellipse(x,0.40,0.07,0.16),[Color(hex:"E8B49D"),Color(hex:"F8DCCA")],point(x,0.40),point(x+0.08,0.5))}
                var face=Path();face.move(to:point(0.5,0.19))
                face.addCurve(to:point(0.28,0.43),control1:point(0.33,0.18),control2:point(0.25,0.28))
                face.addCurve(to:point(0.50,0.76),control1:point(0.28,0.61),control2:point(0.36,0.74))
                face.addCurve(to:point(0.72,0.43),control1:point(0.64,0.74),control2:point(0.72,0.61))
                face.addCurve(to:point(0.5,0.19),control1:point(0.75,0.28),control2:point(0.67,0.18))
                fill(face,[Color(hex:"FFF0E0"),Color(hex:"F5D0B8"),Color(hex:"DFA991")],point(0.35,0.28),point(0.71,0.71))
                var fringe=Path();fringe.move(to:point(0.26,0.43));fringe.addCurve(to:point(0.55,0.21),control1:point(0.23,0.18),control2:point(0.44,0.10));fringe.addCurve(to:point(0.74,0.37),control1:point(0.74,0.21),control2:point(0.79,0.26));fringe.addQuadCurve(to:point(0.57,0.24),control:point(0.62,0.37));fringe.addQuadCurve(to:point(0.26,0.43),control:point(0.45,0.24));fringe.closeSubpath()
                fill(fringe,[Color(hex:"4C4852"),Color(hex:"1F1B26")],point(0.3,0.13),point(0.72,0.4))
                for cx:CGFloat in [0.35,0.65] {
                    context.fill(ellipse(cx-0.055,0.51,0.11,0.07),with:.radialGradient(Gradient(colors:[Color(hex:"EEB1A5").opacity(0.65),.clear]),center:point(cx,0.55),startRadius:0,endRadius:w*0.07))
                }
                var brows=Path();brows.move(to:point(0.33,0.40));brows.addQuadCurve(to:point(0.44,0.39),control:point(0.38,0.375));brows.move(to:point(0.56,0.39));brows.addQuadCurve(to:point(0.67,0.40),control:point(0.62,0.375))
                context.stroke(brows,with:.color(Color(hex:"51404A")),style:StrokeStyle(lineWidth:max(1,w*0.018),lineCap:.round))
                var eyes=Path();eyes.move(to:point(0.32,0.465));eyes.addQuadCurve(to:point(0.45,0.47),control:point(0.39,0.505));eyes.move(to:point(0.55,0.47));eyes.addQuadCurve(to:point(0.68,0.465),control:point(0.61,0.505))
                context.stroke(eyes,with:.color(Color(hex:"503A43")),style:StrokeStyle(lineWidth:max(1,w*0.012),lineCap:.round))
                context.fill(ellipse(0.475,0.49,0.055,0.085),with:.linearGradient(Gradient(colors:[Color(hex:"FFEEDD"),Color(hex:"DCAB96")]),startPoint:point(0.49,0.49),endPoint:point(0.53,0.58)))
                var mouth=Path();mouth.move(to:point(0.44,0.63));mouth.addQuadCurve(to:point(0.56,0.63),control:point(0.5,0.66))
                context.stroke(mouth,with:.color(Color(hex:"C77B84")),style:StrokeStyle(lineWidth:max(1,w*0.018),lineCap:.round))
                if showsGuides {
                    var guide=Path();guide.move(to:point(0.5,0.28));guide.addLine(to:point(0.5,0.73));guide.move(to:point(0.28,0.47));guide.addLine(to:point(0.72,0.47));guide.move(to:point(0.33,0.58));guide.addLine(to:point(0.67,0.58))
                    context.stroke(guide,with:.color(.white.opacity(0.75)),style:StrokeStyle(lineWidth:0.7,dash:[3,4]))
                    for p in [point(0.32,0.47),point(0.45,0.47),point(0.55,0.47),point(0.68,0.47),point(0.5,0.58)] {
                        context.fill(Path(ellipseIn:CGRect(x:p.x-2,y:p.y-2,width:4,height:4)),with:.color(RuyuanStyle.purple))
                    }
                }
            }
        }.accessibilityLabel("原创矢量宣传插画，不是真人照片或检测结果")
    }
}

struct EmptyStateCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(RuyuanStyle.purple)
                .frame(width: 78, height: 78)
                .background(RuyuanStyle.lilac.opacity(0.65), in: Circle())
            Text(title).font(.headline).foregroundStyle(RuyuanStyle.ink)
            Text(message).font(.subheadline).foregroundStyle(RuyuanStyle.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}
