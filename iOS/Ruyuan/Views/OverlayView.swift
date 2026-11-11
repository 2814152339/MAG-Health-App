import SwiftUI
import UIKit

/// The image and every overlay share one aspect-fit rectangle and one transform.
struct ReportPhotoView: View {
    let report: AnalysisReport
    let image: UIImage?
    var layers: [OverlayLayer] = []
    var showsLandmarks = false

    var body: some View {
        GeometryReader { proxy in
            let fitted = aspectFitSize(in: proxy.size)
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if report.isSample {
                    SampleFaceDiagram()
                } else {
                    Color(hex: "ECE6EE")
                    VStack(spacing: 9) {
                        Image(systemName: "photo.badge.exclamationmark").font(.title2)
                        Text("原始照片不可用").font(.caption)
                    }
                    .foregroundStyle(RuyuanStyle.muted)
                }
                if image != nil || report.isSample {
                    NormalizedOverlayDrawing(layers: layers,
                                             landmarks: showsLandmarks ? report.landmarks : [])
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .clipped()
        .accessibilityLabel(report.isSample ? "演示面部示意与演示标注" : "原始照片与分析标注")
    }

    func aspectFitSize(in bounds: CGSize) -> CGSize {
        let width = report.imageWidth > 0 ? CGFloat(report.imageWidth) : image?.size.width ?? 3
        let height = report.imageHeight > 0 ? CGFloat(report.imageHeight) : image?.size.height ?? 4
        let factor = min(bounds.width / max(width, 1), bounds.height / max(height, 1))
        return CGSize(width: width * factor, height: height * factor)
    }
}

struct NormalizedOverlayDrawing: View {
    let layers: [OverlayLayer]
    let landmarks: [LandmarkPath]

    var body: some View {
        Canvas { context, size in
            for layer in layers {
                let color = Color(hex: layer.colorHex)
                for points in layer.paths where valid(points) {
                    if layer.kind == .points {
                        for point in points {
                            let p = position(point, size: size)
                            let circle = Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
                            context.fill(circle, with: .color(color.opacity(0.9)))
                        }
                    } else {
                        let path = makePath(points, closed: layer.kind == .polygons, size: size)
                        if layer.kind == .polygons { context.fill(path, with: .color(color.opacity(0.25))) }
                        context.stroke(path, with: .color(color),
                                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            for landmark in landmarks where valid(landmark.points) {
                let path = makePath(landmark.points, closed: landmark.closed, size: size)
                context.stroke(path, with: .color(.white.opacity(0.95)),
                               style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                for point in landmark.points {
                    let p = position(point, size: size)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2)),
                                 with: .color(Color(hex: "EAD6F7")))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func valid(_ points: [NormalizedPoint]) -> Bool {
        !points.isEmpty && points.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
        }
    }

    private func position(_ point: NormalizedPoint, size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * size.width, y: CGFloat(point.y) * size.height)
    }

    private func makePath(_ points: [NormalizedPoint], closed: Bool, size: CGSize) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: position(first, size: size))
        for point in points.dropFirst() { path.addLine(to: position(point, size: size)) }
        if closed { path.closeSubpath() }
        return path
    }
}

@MainActor
struct OverlayView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let report: AnalysisReport
    var initialLayerID: String? = nil
    @State private var selectedLayerID: String?
    @State private var showOverlay = true
    @State private var showLandmarks = false
    @State private var scale: CGFloat = 1
    @State private var savedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var savedOffset: CGSize = .zero

    private var selectedLayer: OverlayLayer? {
        report.overlays.first { $0.id == selectedLayerID }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if report.isSample {
                    Label("演示图层 · 非真实检测结果", systemImage: "info.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(hex: "E4D1F0"))
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(RuyuanStyle.purple.opacity(0.2))
                }
                zoomablePhoto
                controls
            }
            .background(Color(hex: "211D25"))
            .navigationTitle(selectedLayer?.title ?? "面部特征与原图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: "211D25"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { resetZoom() } label: { Image(systemName: "arrow.counterclockwise") }
                        .foregroundStyle(.white).accessibilityLabel("重置缩放与位置")
                }
            }
            .preferredColorScheme(.dark)
        }
        .onAppear {
            selectedLayerID = initialLayerID
            showLandmarks = initialLayerID == nil && !report.landmarks.isEmpty
        }
    }

    private var zoomablePhoto: some View {
        GeometryReader { proxy in
            let photo = ReportPhotoView(report: report, image: store.image(for: report),
                                        layers: showOverlay ? selectedLayer.map { [$0] } ?? [] : [],
                                        showsLandmarks: showOverlay && showLandmarks)
            let fitted = photo.aspectFitSize(in: proxy.size)
            ZStack {
                Color.clear
                photo
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
            }
            .contentShape(Rectangle())
            .clipped()
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(savedScale * value, 1), 6)
                        offset = bounded(offset, scale: scale, fitted: fitted, bounds: proxy.size)
                    }
                    .onEnded { _ in
                        savedScale = scale
                        offset = bounded(offset, scale: scale, fitted: fitted, bounds: proxy.size)
                        savedOffset = offset
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        let next = CGSize(width: savedOffset.width + value.translation.width,
                                          height: savedOffset.height + value.translation.height)
                        offset = bounded(next, scale: scale, fitted: fitted, bounds: proxy.size)
                    }
                    .onEnded { _ in savedOffset = offset }
            )
            .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.2)) { resetZoom() } }
            .accessibilityHint("双指缩放，单指拖动，双击重置。也可使用下方缩放按钮。")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("显示模式", selection: $showOverlay) {
                Text("原图").tag(false)
                Text(report.isSample ? "演示标注" : "分析标注").tag(true)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                if !report.overlays.isEmpty {
                    Menu {
                        ForEach(report.overlays) { layer in
                            Button {
                                selectedLayerID = layer.id
                                showOverlay = true
                            } label: {
                                if selectedLayerID == layer.id { Label(layer.title, systemImage: "checkmark") }
                                else { Text(layer.title) }
                            }
                        }
                    } label: {
                        Label(selectedLayer?.title ?? "选择图层", systemImage: "square.3.layers.3d")
                            .font(.caption.weight(.medium)).lineLimit(2)
                    }
                }
                if !report.landmarks.isEmpty {
                    Button {
                        showLandmarks.toggle()
                        if showLandmarks { showOverlay = true }
                    } label: {
                        Label("特征点", systemImage: showLandmarks ? "checkmark.circle.fill" : "circle")
                            .font(.caption.weight(.medium))
                    }
                    .accessibilityLabel(showLandmarks ? "隐藏面部特征点" : "显示面部特征点")
                }
                Spacer(minLength: 0)
                Button { stepZoom(-0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("缩小图像").frame(width: 34, height: 36)
                Button { stepZoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("放大图像").frame(width: 34, height: 36)
            }
            .foregroundStyle(Color(hex: "E4D1F0"))
            if let layer = selectedLayer {
                VStack(alignment: .leading, spacing: 6) {
                    Text(layer.note).font(.caption).foregroundStyle(.white.opacity(0.8))
                    Text("来源：\(report.isSample ? "原创矢量交互示例" : layer.source)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if report.landmarks.isEmpty && report.overlays.isEmpty {
                Text("此报告未提供可显示的特征点或图层。")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            } else if selectedLayer == nil && !showLandmarks {
                Text("当前显示原图，可从图层菜单选择对应标注。")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Text("双指缩放 · 拖动查看 · 双击重置")
                .font(.caption2).foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(Color(hex: "2C2632"))
    }

    private func bounded(_ value: CGSize, scale: CGFloat, fitted: CGSize, bounds: CGSize) -> CGSize {
        let maxX = max(0, (fitted.width * scale - bounds.width) / 2)
        let maxY = max(0, (fitted.height * scale - bounds.height) / 2)
        return CGSize(width: min(max(value.width, -maxX), maxX),
                      height: min(max(value.height, -maxY), maxY))
    }

    private func resetZoom() {
        scale = 1; savedScale = 1; offset = .zero; savedOffset = .zero
    }

    private func stepZoom(_ amount: CGFloat) {
        scale = min(max(scale + amount, 1), 6)
        savedScale = scale
        offset = .zero; savedOffset = .zero
    }
}
