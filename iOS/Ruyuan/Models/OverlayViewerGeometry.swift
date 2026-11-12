import Foundation
import CoreGraphics

/// Display-only framing and pan limits. Never creates landmarks, measurements,
/// an anatomical forehead/hairline, or evidence of a detected skin condition.
enum OverlayViewerGeometry {
    struct PanInput: Equatable {
        let imageBounds: CGRect
        let viewport: CGSize
        let scale: CGFloat
    }

    /// nil means show the complete image. Canonical Vision's open faceContour
    /// covers the jaw, NOT the forehead; the extra margin is presentation only.
    static func initialFaceRegion(landmarks: [LandmarkPath], selectedLayer: OverlayLayer?,
                                  imageSize: CGSize) -> CGRect? {
        guard let layer = selectedLayer, validImageSize(imageSize),
              let contour = canonical("faceContour", minimum: 8, closed: false, in: landmarks),
              let firstEye = canonical("leftEye", minimum: 4, closed: true, in: landmarks),
              let secondEye = canonical("rightEye", minimum: 4, closed: true, in: landmarks),
              let firstBrow = canonical("leftEyebrow", minimum: 3, closed: false, in: landmarks),
              let secondBrow = canonical("rightEyebrow", minimum: 3, closed: false, in: landmarks),
              hasArea(contour.points, imageSize: imageSize),
              hasArea(firstEye.points, imageSize: imageSize),
              hasArea(secondEye.points, imageSize: imageSize),
              !firstEye.bounds.intersects(secondEye.bounds),
              !firstBrow.bounds.intersects(secondBrow.bounds),
              separation(firstBrow.bounds, secondBrow.bounds, imageSize: imageSize) >= 1 else { return nil }
        let evidence = [contour, firstEye, secondEye, firstBrow, secondBrow]
        guard evidence.allSatisfy({ max($0.bounds.width * imageSize.width,
                                      $0.bounds.height * imageSize.height) >= 1 }) else { return nil }
        guard let face = bounds(evidence.flatMap { $0.points }),
              face.width * imageSize.width >= 2, face.height * imageSize.height >= 2 else { return nil }
        // Relative display margins, not predicted anatomy or a reference-video scale.
        let side = face.width * 0.08
        let top = face.height * 0.25
        let bottom = face.height * 0.10
        var region = CGRect(x: face.minX - side, y: face.minY - top,
                            width: face.width + side * 2, height: face.height + top + bottom)
        // Keep every actual selected-layer path inside the initial framing. A
        // malformed path fails closed to full image instead of silently cropping it.
        for path in layer.paths {
            if path.isEmpty { continue }
            guard path.allSatisfy(valid), let bounds = bounds(path) else { return nil }
            region = region.union(bounds.insetBy(dx: -face.width * 0.01, dy: -face.height * 0.01))
        }
        region = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !region.isNull, region.width > 0, region.height > 0 else { return nil }
        if region.minX <= 0, region.minY <= 0, region.maxX >= 1, region.maxY >= 1 { return nil }
        return region
    }

    /// imageBounds is the actual transformed full-image rectangle BEFORE the
    /// viewer's scaleEffect (about viewport center) and offset. An off-center ROI
    /// is not symmetric about that center. Undersized axes retain their original
    /// letterbox/framing and have no additional user translation.
    static func boundedOffset(_ proposed: CGSize, scale: CGFloat, imageBounds: CGRect,
                              viewport: CGSize) -> CGSize {
        guard proposed.width.isFinite, proposed.height.isFinite, scale.isFinite, (1...6).contains(scale),
              viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              imageBounds.minX.isFinite, imageBounds.minY.isFinite,
              imageBounds.width.isFinite, imageBounds.height.isFinite,
              imageBounds.width > 0, imageBounds.height > 0 else { return .zero }
        func axis(_ offset: CGFloat, origin: CGFloat, extent: CGFloat, visible: CGFloat) -> CGFloat {
            let scaledExtent = extent * scale
            let lowerEdge = visible / 2 + scale * (origin - visible / 2)
            let upperEdge = lowerEdge + scaledExtent
            guard scaledExtent.isFinite, lowerEdge.isFinite, upperEdge.isFinite,
                  scaledExtent >= visible else { return 0 }
            let minimum = visible - upperEdge
            let maximum = -lowerEdge
            guard minimum <= maximum else { return 0 }
            return min(max(offset, minimum), maximum)
        }
        return CGSize(width: axis(proposed.width, origin: imageBounds.minX,
                                  extent: imageBounds.width, visible: viewport.width),
                      height: axis(proposed.height, origin: imageBounds.minY,
                                   extent: imageBounds.height, visible: viewport.height))
    }

    private struct Evidence {
        let points: [NormalizedPoint]
        let bounds: CGRect
    }

    private static func canonical(_ id: String, minimum: Int, closed: Bool,
                                  in landmarks: [LandmarkPath]) -> Evidence? {
        let matches = landmarks.filter { $0.id == id }
        guard matches.count == 1, let path = matches.first, path.closed == closed else { return nil }
        var points = path.points
        // A single explicit closing endpoint is equivalent to the closed flag;
        // repeated interior coordinates remain invalid evidence.
        if closed, points.count > 1, points.first == points.last { points.removeLast() }
        guard points.count >= minimum, points.allSatisfy(valid), Set(points).count == points.count,
              let bounds = bounds(points), bounds.width > 0 || bounds.height > 0 else { return nil }
        return Evidence(points: points, bounds: bounds)
    }

    private static func bounds(_ points: [NormalizedPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }

    private static func hasArea(_ points: [NormalizedPoint], imageSize: CGSize) -> Bool {
        guard points.count >= 3 else { return false }
        var twiceArea = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            twiceArea += points[index].x * next.y - next.x * points[index].y
        }
        return twiceArea.isFinite && abs(twiceArea) * Double(imageSize.width) * Double(imageSize.height) > 1
    }

    private static func separation(_ first: CGRect, _ second: CGRect, imageSize: CGSize) -> CGFloat {
        CGFloat(hypot(Double(first.midX - second.midX) * Double(imageSize.width),
                      Double(first.midY - second.midY) * Double(imageSize.height)))
    }

    private static func valid(_ point: NormalizedPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    private static func validImageSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 &&
            size.width <= 16384 && size.height <= 16384
    }
}
