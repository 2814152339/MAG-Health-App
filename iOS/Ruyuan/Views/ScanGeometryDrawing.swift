import SwiftUI

/// Presentation-only animation of this report's observed paths. Nothing drawn
/// here is added to the report or used as a new measurement.
struct ScanGeometryDrawing: View {
    let layers: [OverlayLayer]
    let landmarks: [LandmarkPath]
    let transform: ReportPhotoTransform
    let phases: ScanMotionTimeline.Phases
    let elapsed: Double
    let reduceMotion: Bool
    let angleProgress: Double
    var samplingRegions: [CGRect] = []
    var showsFeatureGuides: Bool = false
    var showsChinGuides: Bool = false

    private let violet = Color(hex: "7377FF")

    var body: some View {
        Canvas { context, _ in
            let featureGuides = showsFeatureGuides ? ScanFeatureGuideGeometry.guides(landmarks: landmarks, transform: transform) : nil
            let chinPoints = layers.first(where: { $0.id == "geometry-chin-points" })?.paths.first ?? []
            let chinGuides = showsChinGuides ? ScanFeatureGuideGeometry.chinGuides(points: chinPoints, transform: transform) : nil
            drawGuides(references: (featureGuides?.referenceSegments ?? []) + (chinGuides?.referenceSegments ?? []),
                       dimensions: (featureGuides?.dimensionSegments ?? []) + (chinGuides?.dimensionSegments ?? []),
                       context: &context)
            drawLandmarks(context: &context)
            for (index, layer) in layers.enumerated() {
                if layer.id == "geometry-chin", chinGuides != nil { continue }
                let stagger = min(0.22, Double(index) * 0.035)
                let progress = reducedProgress(phases.measurements, delay: stagger)
                if layer.id.hasPrefix("geometry-") {
                    if layer.kind == .points {
                        drawGeometryPoints(layer, context: &context)
                    } else if !isAngleLayer(layer.id) {
                        // The geometry producer stores a segment followed by
                        // its two arrowheads. Animate its true segment once,
                        // rather than independently flying in the old heads.
                        for points in layer.paths where points.count == 2 {
                            drawDimension(points.map(transform.position), progress: progress, context: &context)
                        }
                    }
                } else {
                    drawObservedLayer(layer, progress: progress, context: &context)
                }
            }
            drawAngles(context: &context)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func reducedProgress(_ value: Double, delay: Double) -> Double {
        guard !reduceMotion else { return 1 }
        return min(1, max(0, (value - delay) / max(0.01, 1 - delay)))
    }

    private func isAngleLayer(_ id: String) -> Bool {
        id.hasPrefix("geometry-jaw-") || id.hasPrefix("geometry-golden-triangle")
            || id.hasPrefix("geometry-brow-") || id.hasPrefix("geometry-eye-")
    }

    private func path(_ points: [CGPoint], closed: Bool = false) -> Path {
        var result = Path()
        guard let first = points.first else { return result }
        result.move(to: first)
        for point in points.dropFirst() { result.addLine(to: point) }
        if closed { result.closeSubpath() }
        return result
    }

    private func drawLandmarks(context: inout GraphicsContext) {
        for (index, landmark) in landmarks.enumerated() {
            guard !landmark.points.isEmpty else { continue }
            let progress = reducedProgress(phases.referenceLines, delay: min(0.24, Double(index) * 0.045))
            var points = landmark.points.map(transform.position)
            if landmark.closed, let first = points.first { points.append(first) }
            let traced = ScanMotionTimeline.polylinePrefix(points, progress: progress)
            context.stroke(path(traced), with: .color(violet.opacity(0.92)),
                           style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            // Only the observed vertices are illuminated. No decorative mesh
            // is synthesized between features or over the user's skin.
            for (pointIndex, point) in landmark.points.enumerated() {
                let reveal = reducedProgress(phases.points, delay: min(0.65, Double(pointIndex) * 0.025))
                drawPoint(transform.position(point), progress: reveal, context: &context)
            }
        }
    }

    private func drawGeometryPoints(_ layer: OverlayLayer, context: inout GraphicsContext) {
        for points in layer.paths {
            for (index, point) in points.enumerated() {
                drawPoint(transform.position(point), progress: reducedProgress(phases.points, delay: min(0.5, Double(index) * 0.12)), context: &context)
            }
        }
    }

    private func drawPoint(_ point: CGPoint, progress: Double, context: inout GraphicsContext) {
        guard progress > 0 else { return }
        let scale = CGFloat(progress)
        var glow = context
        glow.addFilter(.blur(radius: 3))
        glow.fill(Path(ellipseIn: CGRect(x: point.x - 5 * scale, y: point.y - 5 * scale,
                                         width: 10 * scale, height: 10 * scale)),
                  with: .color(violet.opacity(0.3 * progress)))
        context.fill(Path(ellipseIn: CGRect(x: point.x - 2.5 * scale, y: point.y - 2.5 * scale,
                                            width: 5 * scale, height: 5 * scale)),
                     with: .color(violet.opacity(progress)))
        context.fill(Path(ellipseIn: CGRect(x: point.x - 0.8, y: point.y - 0.8, width: 1.6, height: 1.6)),
                     with: .color(.white.opacity(progress * 0.8)))
    }

    private func drawGuides(references: [ScanFeatureGuideGeometry.Segment],
                            dimensions: [ScanFeatureGuideGeometry.Segment], context: inout GraphicsContext) {
        for (index, segment) in references.enumerated() {
            let progress = reducedProgress(phases.referenceLines, delay: min(0.18, Double(index) * 0.025))
            let points = ScanMotionTimeline.polylinePrefix([segment.start, segment.end], progress: progress)
            context.stroke(path(points), with: .color(.white.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
        }
        for (index, segment) in dimensions.enumerated() {
            ScanDimensionDrawing.draw(from: segment.start, to: segment.end,
                progress: reducedProgress(phases.measurements, delay: min(0.18, Double(index) * 0.04)), context: &context)
        }
    }

    private func drawDimension(_ points: [CGPoint], progress: Double, context: inout GraphicsContext) {
        guard points.count == 2 else { return }
        ScanDimensionDrawing.draw(from: points[0], to: points[1], progress: progress, context: &context)
    }

    private func drawAngles(context: inout GraphicsContext) {
        for layer in layers where layer.kind == .points && isAngleLayer(layer.id) {
            guard let points = layer.paths.first, points.count == 3 else { continue }
            let p = points.map(transform.position)
            let first: CGPoint, vertex: CGPoint, second: CGPoint
            if layer.id == "geometry-golden-triangle-points" {
                first = p[0]; vertex = p[2]; second = p[1]
            } else {
                first = p[0]; vertex = p[1]; second = p[2]
            }
            guard let angle = ScanMotionTimeline.angle(first: first, vertex: vertex, second: second,
                                                       progress: angleProgress, radius: 22), angleProgress > 0 else { continue }
            let arms = path([angle.firstRayEndpoint, angle.vertex, angle.movingRayEndpoint])
            context.stroke(arms, with: .color(.white.opacity(0.92)),
                           style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            context.stroke(path(angle.arcPoints), with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
            if layer.id == "geometry-golden-triangle-points" {
                context.stroke(path([p[0], p[1]]), with: .color(violet.opacity(phases.measurements)), lineWidth: 1.2)
            }
        }
    }

    private func drawObservedLayer(_ layer: OverlayLayer, progress: Double, context: inout GraphicsContext) {
        guard progress > 0 else { return }
        if layer.id == "appearance-under-eye" {
            for region in samplingRegions {
                let start = transform.position(.init(x: Double(region.minX), y: Double(region.minY)))
                let end = transform.position(.init(x: Double(region.maxX), y: Double(region.maxY)))
                let rect = CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)
                let outline = Path(roundedRect: rect, cornerRadius: 4).trimmedPath(from: 0, to: CGFloat(progress))
                context.stroke(outline, with: .color(.white.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 3]))
            }
            return
        }
        let color = Color(hex: layer.colorHex)
        var drawing = context
        drawing.opacity = progress
        for (index, points) in layer.paths.enumerated() where !points.isEmpty {
            let mapped = points.map(transform.position)
            if layer.kind == .points {
                let amount = reducedProgress(progress, delay: min(0.6, Double(index % 12) * 0.035))
                for point in mapped { drawPoint(point, progress: amount, context: &drawing) }
            } else if layer.kind == .polygons {
                drawing.fill(path(mapped, closed: true), with: .color(color.opacity(0.32)))
                if !layer.id.hasPrefix("semantic-"), layer.id != "model-acne-segmentation" {
                    drawing.stroke(path(mapped, closed: true), with: .color(color.opacity(0.8)), lineWidth: 0.8)
                }
            } else {
                let traced = ScanMotionTimeline.polylinePrefix(mapped, progress: progress)
                drawing.stroke(path(traced), with: .color(color),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// All scan dimensions share one center-out stroke and filled endpoint style.
/// Endpoints come from observed paths; this renderer does not produce values.
enum ScanDimensionDrawing {
    static func draw(from start: CGPoint, to end: CGPoint, progress: Double, context: inout GraphicsContext) {
        guard progress > 0,
              let segment = ScanMotionTimeline.centerOutLine(from: start, to: end, progress: progress) else { return }
        let violet = Color(hex: "7377FF")
        var line = Path(); line.move(to: segment.start); line.addLine(to: segment.end)
        var glow = context
        glow.addFilter(.blur(radius: 2))
        glow.stroke(line, with: .color(violet.opacity(0.32)), lineWidth: 3)
        context.stroke(line, with: .color(violet), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        let angle = atan2(segment.end.y - segment.start.y, segment.end.x - segment.start.x)
        let headSize = min(CGFloat(6), hypot(segment.end.x - segment.start.x, segment.end.y - segment.start.y) / 5)
        for (point, direction) in [(segment.start, angle), (segment.end, angle + .pi)] {
            var triangle = Path(); triangle.move(to: point)
            triangle.addLine(to: CGPoint(x: point.x + cos(direction - 0.48) * headSize, y: point.y + sin(direction - 0.48) * headSize))
            triangle.addLine(to: CGPoint(x: point.x + cos(direction + 0.48) * headSize, y: point.y + sin(direction + 0.48) * headSize))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(violet.opacity(min(1, progress * 2))))
        }
    }
}

/// Deterministic graphic bezel matching the reference's double keyline,
/// clipped corners and slanted tabs, without shipping private reference pixels.
struct ScanTechBezel: View {
    let progress: Double

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 3)
            let violet = Color(hex: "7477FF")
            let outer = outline(rect, cut: 8)
            context.stroke(outer.trimmedPath(from: 0, to: CGFloat(progress)), with: .color(violet),
                           style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            context.stroke(outline(rect.insetBy(dx: 6, dy: 6), cut: 3), with: .color(.white.opacity(0.85 * progress)), lineWidth: 1)
            func tab(_ points: [CGPoint]) {
                var path = Path(); guard let first = points.first else { return }
                path.move(to: first); for p in points.dropFirst() { path.addLine(to: p) }; path.closeSubpath()
                context.fill(path, with: .color(violet.opacity(progress)))
            }
            tab([.init(x: 28, y: 3), .init(x: 35, y: 0), .init(x: size.width * 0.42, y: 0), .init(x: size.width * 0.45, y: 3)])
            tab([.init(x: size.width * 0.14, y: size.height - 3), .init(x: size.width * 0.39, y: size.height - 3),
                 .init(x: size.width * 0.37, y: size.height), .init(x: size.width * 0.12, y: size.height)])
            for index in 0..<5 {
                let x = size.width - 48 + CGFloat(index) * 7
                tab([.init(x: x, y: 0), .init(x: x + 4, y: 0), .init(x: x + 7, y: 3), .init(x: x + 3, y: 3)])
                let y = size.height * 0.45 + CGFloat(index) * 7
                tab([.init(x: 0, y: y), .init(x: 3, y: y + 3), .init(x: 3, y: y + 8), .init(x: 0, y: y + 5)])
                tab([.init(x: size.width - 3, y: y), .init(x: size.width, y: y + 3),
                     .init(x: size.width, y: y + 8), .init(x: size.width - 3, y: y + 5)])
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func outline(_ rect: CGRect, cut: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
            path.addLines([.init(x: rect.maxX - cut, y: rect.minY), .init(x: rect.maxX, y: rect.minY + cut),
                           .init(x: rect.maxX, y: rect.maxY - cut), .init(x: rect.maxX - cut, y: rect.maxY),
                           .init(x: rect.minX + cut, y: rect.maxY), .init(x: rect.minX, y: rect.maxY - cut),
                           .init(x: rect.minX, y: rect.minY + cut)])
            path.closeSubpath()
        }
    }
}
