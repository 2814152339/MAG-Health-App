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
            let sampling = layers.first(where: { $0.id == "appearance-under-eye" }).map {
                OverlayPresentationGeometry.eyeSamplingRegions(for: $0, landmarks: report.landmarks,
                    imageSize: CGSize(width: CGFloat(report.imageWidth), height: CGFloat(report.imageHeight)))
            } ?? []
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
                    NormalizedOverlayDrawing(layers: layers.filter { $0.id != "appearance-under-eye" },
                                             landmarks: showsLandmarks ? report.landmarks : [], samplingRegions: sampling)
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

/// One image-space transform for the photo, real paths, and measurement labels.
/// A focus region is derived from this report's points, never a guessed face box.
struct ReportPhotoTransform {
    let imageSize: CGSize
    let viewport: CGSize
    var region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var factor: CGFloat {
        min(viewport.width / max(1, imageSize.width * region.width),
            viewport.height / max(1, imageSize.height * region.height))
    }
    var renderedSize: CGSize { CGSize(width: imageSize.width * factor, height: imageSize.height * factor) }
    var origin: CGPoint {
        CGPoint(x: viewport.width / 2 - region.midX * renderedSize.width,
                y: viewport.height / 2 - region.midY * renderedSize.height)
    }
    func position(_ point: NormalizedPoint) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(point.x) * renderedSize.width,
                y: origin.y + CGFloat(point.y) * renderedSize.height)
    }
    static func region(points: [NormalizedPoint], padding: CGSize = CGSize(width: 0.10, height: 0.12),
                       minimum: CGSize = CGSize(width: 0.28, height: 0.28)) -> CGRect? {
        let valid = points.filter { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }
        guard let minX = valid.map(\.x).min(), let maxX = valid.map(\.x).max(),
              let minY = valid.map(\.y).min(), let maxY = valid.map(\.y).max() else { return nil }
        let width = min(1, max(minimum.width, CGFloat(maxX - minX) + padding.width * 2))
        let height = min(1, max(minimum.height, CGFloat(maxY - minY) + padding.height * 2))
        let x = min(1 - width, max(0, CGFloat(minX + maxX) / 2 - width / 2))
        let y = min(1 - height, max(0, CGFloat(minY + maxY) / 2 - height / 2))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct FocusedReportPhotoView: View {
    let report: AnalysisReport
    let image: UIImage?
    var layers: [OverlayLayer] = []
    var landmarks: [LandmarkPath] = []
    var region: CGRect? = nil
    var clipsToViewport = true

    @ViewBuilder
    var body: some View {
        if clipsToViewport { photoContent.clipped() }
        else { photoContent }
    }

    private var photoContent: some View {
        GeometryReader { proxy in
            let transform = ReportPhotoTransform(
                imageSize: CGSize(width: CGFloat(max(1, report.imageWidth)), height: CGFloat(max(1, report.imageHeight))),
                viewport: proxy.size, region: region ?? CGRect(x: 0, y: 0, width: 1, height: 1))
            ZStack {
                ReportPhotoView(report: report, image: image, layers: layers)
                NormalizedOverlayDrawing(layers: [], landmarks: landmarks)
            }
            .frame(width: transform.renderedSize.width, height: transform.renderedSize.height)
            .position(x: transform.origin.x + transform.renderedSize.width / 2,
                      y: transform.origin.y + transform.renderedSize.height / 2)
        }
    }
}

struct NormalizedOverlayDrawing: View {
    let layers: [OverlayLayer]
    let landmarks: [LandmarkPath]
    var samplingRegions: [CGRect] = []

    var body: some View {
        Canvas { context, size in
            for region in samplingRegions {
                let rect = CGRect(x: region.minX * size.width, y: region.minY * size.height,
                                  width: region.width * size.width, height: region.height * size.height)
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color(hex: "EE7189")),
                               style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            }
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
                        if layer.kind == .polygons { context.fill(path, with: .color(color.opacity(0.32))) }
                        // Pixel masks are actual horizontal runs/rectangles. A
                        // thick outline on every run would create artificial
                        // stripes and make the translucent mask look opaque.
                        if !((layer.id.hasPrefix("semantic-") || layer.id == "model-acne-segmentation") && layer.kind == .polygons) {
                            context.stroke(path, with: .color(color),
                                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        }
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
    var initialItemReference: OverlayItemReference? = nil
    @State private var selectedLayerID: String?
    @State private var selectedItemReference: OverlayItemReference?
    @State private var showOverlay = true
    @State private var showLandmarks = false
    @State private var scale: CGFloat = 1
    @State private var savedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var savedOffset: CGSize = .zero
    @State private var focusRegion: CGRect?
    @State private var showsLegend = true
    @State private var measuredLegendHeight: CGFloat = 0
    @State private var showsViewingTools = false
    @State private var currentViewport: CGSize = .zero

    private var selectedLayer: OverlayLayer? {
        let matches = report.overlays.filter { $0.id == selectedLayerID }
        return matches.count == 1 ? matches.first : nil
    }

    // Resolve the annotated legend only. Original mode constructs no observation
    // subtree and reserves only its previously measured presentation height.
    private var legendObservation: SkinItem? {
        OverlayItemPresentation.resolvedItem(selectedItemReference, in: report,
            selectedLayerID: selectedLayerID, showOverlay: true)
    }

    private var photoImageSize: CGSize {
        CGSize(width: CGFloat(max(1, report.imageWidth)), height: CGFloat(max(1, report.imageHeight)))
    }

    private var framingAccessibilityValue: String {
        let region = focusRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return "region=\(Double(region.minX)),\(Double(region.minY)),\(Double(region.width)),\(Double(region.height));scale=\(Double(scale));offset=\(Double(offset.width)),\(Double(offset.height))"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { available in
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
                    controls(maximumToolsHeight: min(220, max(0, available.size.height * 0.32)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(.black)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("overlayViewer")
            .navigationTitle(selectedLayer?.title ?? "原图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { focusRegion = nil; resetZoom() } label: { Image(systemName: "arrow.counterclockwise") }
                        .foregroundStyle(.white).accessibilityLabel("重置缩放与位置")
                        .accessibilityIdentifier("overlayResetView")
                }
            }
            .preferredColorScheme(.dark)
        }
        .onAppear {
            selectedLayerID = initialLayerID
            selectedItemReference = initialItemReference
            showOverlay = initialLayerID != nil
            showLandmarks = false
            focusRegion = OverlayViewerGeometry.initialFaceRegion(landmarks: report.landmarks,
                selectedLayer: selectedLayer, imageSize: photoImageSize)
            resetZoom()
        }
    }

    private var zoomablePhoto: some View {
        GeometryReader { proxy in
            let photo = FocusedReportPhotoView(report: report, image: store.image(for: report),
                layers: showOverlay ? selectedLayer.map { [$0] } ?? [] : [],
                landmarks: showOverlay && showLandmarks ? report.landmarks : [], region: focusRegion,
                clipsToViewport: false)
            let transform = ReportPhotoTransform(
                imageSize: CGSize(width: CGFloat(max(1, report.imageWidth)), height: CGFloat(max(1, report.imageHeight))),
                viewport: proxy.size, region: focusRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1))
            let imageBounds = CGRect(origin: transform.origin, size: transform.renderedSize)
            let panInput = OverlayViewerGeometry.PanInput(imageBounds: imageBounds, viewport: proxy.size, scale: scale)
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
                        guard value.isFinite else { return }
                        scale = min(max(savedScale * value, 1), 6)
                        offset = bounded(offset, scale: scale, imageBounds: imageBounds, bounds: proxy.size)
                    }
                    .onEnded { _ in
                        savedScale = scale
                        offset = bounded(offset, scale: scale, imageBounds: imageBounds, bounds: proxy.size)
                        savedOffset = offset
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        let next = CGSize(width: savedOffset.width + value.translation.width,
                                          height: savedOffset.height + value.translation.height)
                        offset = bounded(next, scale: scale, imageBounds: imageBounds, bounds: proxy.size)
                    }
                    .onEnded { _ in savedOffset = offset }
            )
            .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.2)) { resetZoom() } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("overlayPhotoViewport")
            .accessibilityValue(framingAccessibilityValue)
            .accessibilityHint("双指缩放，单指拖动，双击重置。展开图层与查看工具可使用缩放按钮。")
            .onChange(of: panInput, initial: true) { _, input in
                // Initial framing, focus/reset, button/pinch zoom, tool expansion,
                // and window resize all change this same real geometry input.
                currentViewport = input.viewport
                offset = bounded(offset, scale: input.scale, imageBounds: input.imageBounds, bounds: input.viewport)
                savedOffset = offset
            }
        }
    }

    private func controls(maximumToolsHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let layer = selectedLayer, showsLegend {
                if showOverlay {
                    legend(layer: layer)
                        .background {
                            GeometryReader { bounds in
                                Color.clear.onChange(of: bounds.size.height, initial: true) { _, height in
                                    guard height.isFinite, height > 0,
                                          abs(height - measuredLegendHeight) > 0.01 else { return }
                                    measuredLegendHeight = height
                                }
                            }
                        }
                } else {
                    // Opacity/accessibilityHidden can leave descendant values
                    // in the system AX tree. Do not build that subtree at all.
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: measuredLegendHeight)
                        .overlay {
                            Text("原图对照 · 已隐藏分析标注")
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                }
            }
            Picker("显示模式", selection: $showOverlay) {
                Text("原图").tag(false)
                Text(report.isSample ? "演示标注" : "分析标注").tag(true)
            }
            .pickerStyle(.segmented)
            Button { showsViewingTools.toggle() } label: {
                HStack {
                    Label("图层与查看工具", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: showsViewingTools ? "chevron.up" : "chevron.down")
                }
                .font(.caption.weight(.medium)).foregroundStyle(Color(hex: "E4D1F0"))
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overlayViewingTools")
            .accessibilityValue(showsViewingTools ? "已展开" : "已收起")
            if showsViewingTools {
                ScrollView {
                    viewingTools.padding(.bottom, 4)
                }
                // Reserve an actual drawer viewport. A maxHeight alone lets
                // the photo GeometryReader compress this to the layer strip,
                // leaving zoom/focus controls below a nearly unscrollable 42pt
                // nested horizontal scroller on the smallest supported phone.
                .frame(height: maximumToolsHeight)
                .accessibilityIdentifier("overlayToolsScrollView")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.black)
    }

    private func legend(layer: OverlayLayer) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle().fill(Color(hex: layer.colorHex)).frame(width: 7, height: 7)
                Text(legendObservation?.title ?? layer.title).font(.caption.weight(.semibold))
                    .accessibilityIdentifier("overlayObservationTitle")
                Spacer()
                Text(report.isSample ? "演示图层" : "照片外观参考")
                    .font(.caption2).foregroundStyle(RuyuanStyle.muted)
            }.foregroundStyle(RuyuanStyle.ink)
            if let item = legendObservation {
                Text(item.valueText).font(.subheadline.weight(.semibold))
                    .foregroundStyle(RuyuanStyle.purple)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overlayObservationValue")
                if item.title != layer.title {
                    Text(layer.title).font(.caption2).foregroundStyle(RuyuanStyle.muted)
                }
            }
            Text(layer.note).font(.caption2).lineSpacing(2).foregroundStyle(RuyuanStyle.muted)
                .lineLimit(2)
            if layer.id == "appearance-under-eye" {
                let regions = OverlayPresentationGeometry.eyeSamplingRegions(for: layer, landmarks: report.landmarks,
                    imageSize: photoImageSize)
                Text(regions.isEmpty ? "本次未标出稳定的眼下采样范围。" : "细框为眼下采样范围，不是病灶边界。")
                    .font(.caption2).foregroundStyle(RuyuanStyle.ink)
                    .accessibilityIdentifier("eyeSamplingRangeLegend")
            }
            Text("来源：\(report.isSample ? "原创演示" : layer.source)")
                .font(.caption2).foregroundStyle(RuyuanStyle.muted).lineLimit(1)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var viewingTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !report.overlays.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(report.overlays) { layer in
                            Button {
                                selectedLayerID = layer.id; showOverlay = true; showLandmarks = false; focusRegion = nil
                                // A layer-strip tap is not a particular report card.
                                selectedItemReference = nil
                                resetZoom()
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(Color(hex: layer.colorHex)).frame(width: 5, height: 5)
                                    Text(layer.title).font(.caption2)
                                }.padding(.horizontal, 10).padding(.vertical, 8)
                                    .foregroundStyle(.white)
                                    .background(selectedLayerID == layer.id ? RuyuanStyle.purple : .white.opacity(0.12), in: Capsule())
                            }.buttonStyle(.plain)
                                .accessibilityIdentifier("overlayLayer-\(layer.id)")
                                .accessibilityAddTraits(selectedLayerID == layer.id ? .isSelected : [])
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    if focusRegion != nil { focusRegion = nil }
                    else if let layer = selectedLayer {
                        focusRegion = ReportPhotoTransform.region(points: layer.paths.flatMap { $0 })
                    }
                    resetZoom()
                } label: { Label(focusRegion == nil ? "局部" : "全图", systemImage: "viewfinder") }
                    .font(.caption2).disabled(selectedLayer == nil && focusRegion == nil)
                    .accessibilityIdentifier("overlayFocusToggle")
                Button { showsLegend.toggle() } label: { Image(systemName: showsLegend ? "info.circle.fill" : "info.circle") }
                    .accessibilityLabel(showsLegend ? "收起图例" : "显示图例")
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
                Text("\(Int(scale * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Button { stepZoom(-0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityIdentifier("overlayZoomOut")
                    .accessibilityLabel("缩小图像").frame(width: 34, height: 36)
                Button { stepZoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityIdentifier("overlayZoomIn")
                    .accessibilityLabel("放大图像").frame(width: 34, height: 36)
            }
            .foregroundStyle(Color(hex: "E4D1F0"))
            if let layer = selectedLayer {
                Text(layer.note).font(.caption).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Text("来源：\(report.isSample ? "原创演示" : layer.source)")
                    .font(.caption2).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if report.landmarks.isEmpty && report.overlays.isEmpty {
                Text("此报告未提供可显示的特征点或图层。")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            } else if selectedLayer == nil && !showLandmarks {
                Text("当前显示原图，可从上方图层条选择对应标注。")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Text("双指缩放 · 拖动查看 · 双击重置")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
        }
    }

    private func bounded(_ value: CGSize, scale: CGFloat, imageBounds: CGRect, bounds: CGSize) -> CGSize {
        OverlayViewerGeometry.boundedOffset(value, scale: scale, imageBounds: imageBounds, viewport: bounds)
    }

    private func resetZoom() {
        scale = 1; savedScale = 1
        let transform = ReportPhotoTransform(imageSize: photoImageSize, viewport: currentViewport,
            region: focusRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1))
        // A double tap can reset an already-1x off-center ROI without changing
        // PanInput. Clamp here too; zero is not always a valid translation.
        offset = bounded(.zero, scale: 1,
            imageBounds: CGRect(origin: transform.origin, size: transform.renderedSize), bounds: currentViewport)
        savedOffset = offset
    }

    private func stepZoom(_ amount: CGFloat) {
        scale = min(max(scale + amount, 1), 6)
        savedScale = scale
        // Preserve the current pan until the new PanInput clamps it, rather than
        // replacing a valid off-center position with an invalid zero offset.
    }
}
