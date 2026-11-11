import SwiftUI
import UIKit

enum RuyuanStyle {
    static let background = Color(hex: "F8F6F3")
    static let ink = Color(hex: "302737")
    static let muted = Color(hex: "817A86")
    static let purple = Color(hex: "7B5E96")
    static let lilac = Color(hex: "EAE2F0")
    static let line = Color(hex: "E8E2E9")
    static let green = Color(hex: "547B6D")
    static let peach = Color(hex: "F2E5DF")
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(cleaned, radix: 16) ?? 0x7B5E96
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
            .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
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
            let size = proxy.size
            let w = size.width
            let h = size.height
            ZStack {
                Ellipse()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.9), RuyuanStyle.lilac],
                                         center: .center, startRadius: 8, endRadius: w * 0.7))
                    .frame(width: w * 0.88, height: h * 0.88)
                Canvas { context, _ in
                    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                        CGPoint(x: x * w, y: y * h)
                    }
                    var face = Path()
                    face.move(to: point(0.50, 0.10))
                    face.addCurve(to: point(0.26, 0.45), control1: point(0.29, 0.10), control2: point(0.22, 0.25))
                    face.addCurve(to: point(0.50, 0.88), control1: point(0.27, 0.69), control2: point(0.38, 0.85))
                    face.addCurve(to: point(0.74, 0.45), control1: point(0.62, 0.85), control2: point(0.73, 0.69))
                    face.addCurve(to: point(0.50, 0.10), control1: point(0.78, 0.25), control2: point(0.71, 0.10))
                    context.fill(face, with: .linearGradient(Gradient(colors: [Color(hex: "F1D9CC"), Color(hex: "E6BFB2")]),
                                                           startPoint: point(0.25, 0.1), endPoint: point(0.7, 0.9)))
                    context.stroke(face, with: .color(RuyuanStyle.purple.opacity(0.45)), lineWidth: 1)
                    var features = Path()
                    features.move(to: point(0.32, 0.41))
                    features.addQuadCurve(to: point(0.44, 0.41), control: point(0.38, 0.45))
                    features.move(to: point(0.56, 0.41))
                    features.addQuadCurve(to: point(0.68, 0.41), control: point(0.62, 0.45))
                    features.move(to: point(0.50, 0.43))
                    features.addCurve(to: point(0.52, 0.61), control1: point(0.48, 0.52), control2: point(0.45, 0.61))
                    features.move(to: point(0.40, 0.70))
                    features.addQuadCurve(to: point(0.60, 0.70), control: point(0.50, 0.76))
                    context.stroke(features, with: .color(Color(hex: "8B6068")), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    if showsGuides {
                        var guide = Path()
                        guide.move(to: point(0.50, 0.13)); guide.addLine(to: point(0.50, 0.84))
                        guide.move(to: point(0.27, 0.41)); guide.addLine(to: point(0.73, 0.41))
                        guide.move(to: point(0.32, 0.61)); guide.addLine(to: point(0.68, 0.61))
                        context.stroke(guide, with: .color(RuyuanStyle.purple.opacity(0.35)),
                                       style: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
                        let horizontalPoints: [CGFloat] = [0.32, 0.44, 0.50, 0.56, 0.68]
                        for x in horizontalPoints {
                            let p = point(x, x == 0.50 ? 0.61 : 0.41)
                            context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                                         with: .color(RuyuanStyle.purple))
                        }
                    }
                }
            }
        }
        .accessibilityLabel("演示用矢量面部示意图，非真实人像")
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
