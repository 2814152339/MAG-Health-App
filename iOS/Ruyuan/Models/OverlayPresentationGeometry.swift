import Foundation
import CoreGraphics

/// Presentation envelopes of existing sampling rows, NOT newly detected lesions.
enum OverlayPresentationGeometry {
    /// Top-left-origin normalized rectangles, ordered by actual eye-center X (then Y).
    /// A rectangle may enclose gaps between sampled rows: render a thin/dashed outline
    /// labelled "眼下采样范围", never a filled segmentation mask or diagnostic border.
    /// Both unique Vision eye contours are required; no fixed face position is assumed.
    static func eyeSamplingRegions(for layer: OverlayLayer, landmarks: [LandmarkPath],
                                   imageSize: CGSize) -> [CGRect] {
        guard layer.id == "appearance-under-eye", layer.kind == .polygons, !layer.paths.isEmpty,
              imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return [] }
        let longestSide = max(imageSize.width, imageSize.height)
        let scaleX = Double(imageSize.width / longestSide)
        let scaleY = Double(imageSize.height / longestSide)
        guard scaleX > 0, scaleY > 0,
              let first = eye(named: "leftEye", in: landmarks),
              let second = eye(named: "rightEye", in: landmarks),
              !first.bounds.intersects(second.bounds) else { return [] }
        let eyes: [Eye] = [first, second].sorted { (lhs: Eye, rhs: Eye) -> Bool in
            if lhs.center.x == rhs.center.x {
                return lhs.center.y < rhs.center.y
            }
            return lhs.center.x < rhs.center.x
        }
        guard eyes[0].center != eyes[1].center else { return [] }
        var envelopes: [CGRect?] = [nil, nil]

        func nearestEye(to point: NormalizedPoint) -> Int? {
            let distances = eyes.map { eye -> Double in
                let dx = (point.x - eye.center.x) * scaleX
                let dy = (point.y - eye.center.y) * scaleY
                return dx * dx + dy * dy
            }
            // The common scale preserves pixel-aspect distances without overflow.
            // Equidistant/ambiguous rows are not assigned to a guessed eye.
            guard abs(distances[0] - distances[1]) > 1e-12 else { return nil }
            return distances[0] < distances[1] ? 0 : 1
        }

        for path in layer.paths {
            guard let row = rowRectangle(path),
                  let owner = nearestEye(to: NormalizedPoint(x: Double(row.midX), y: Double(row.midY))),
                  path.allSatisfy({ nearestEye(to: $0) == owner }),
                  row.minY >= eyes[owner].bounds.maxY else { return [] }
            // No padding, artificial counterpart, or expansion from a model label.
            envelopes[owner] = envelopes[owner].map { $0.union(row) } ?? row
        }
        return envelopes.compactMap { $0 }
    }

    private struct Eye {
        let center: NormalizedPoint
        let bounds: CGRect
    }

    private static func eye(named id: String, in landmarks: [LandmarkPath]) -> Eye? {
        let matches = landmarks.filter { $0.id == id }
        guard matches.count == 1, let path = matches.first, path.closed else { return nil }
        var points = path.points
        if points.count > 1, points.first == points.last { points.removeLast() }
        guard points.count >= 4, Set(points).count >= 4, points.allSatisfy(valid),
              let bounds = bounds(points), bounds.width > 0, bounds.height > 0 else { return nil }
        var twiceArea = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            twiceArea += points[index].x * next.y - next.x * points[index].y
        }
        guard twiceArea.isFinite, abs(twiceArea) > 0 else { return nil }
        let center = NormalizedPoint(x: points.reduce(0) { $0 + $1.x } / Double(points.count),
                                     y: points.reduce(0) { $0 + $1.y } / Double(points.count))
        return Eye(center: center, bounds: bounds)
    }

    /// Accept only the actual axis-aligned four-corner row-run representation
    /// (optionally repeated first corner). Arbitrary polygons are not boxed.
    private static func rowRectangle(_ path: [NormalizedPoint]) -> CGRect? {
        var points = path
        if points.count == 5, points.first == points.last { points.removeLast() }
        guard points.count == 4, Set(points).count == 4, points.allSatisfy(valid),
              let rectangle = bounds(points), rectangle.width > 0, rectangle.height > 0 else { return nil }
        let xs = Set(points.map(\.x))
        let ys = Set(points.map(\.y))
        guard xs.count == 2, ys.count == 2 else { return nil }
        // Use original corner values, not min + CGRect.width round-tripping.
        let corners = Set(xs.flatMap { x in ys.map { NormalizedPoint(x: x, y: $0) } })
        guard Set(points) == corners else { return nil }
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            guard (points[index].x == next.x) != (points[index].y == next.y) else { return nil }
        }
        return rectangle
    }

    private static func valid(_ point: NormalizedPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    private static func bounds(_ points: [NormalizedPoint]) -> CGRect? {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
