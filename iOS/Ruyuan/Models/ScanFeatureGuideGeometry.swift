import Foundation
import CoreGraphics

/// Display guides over one observed eye and its same-ID-side eyebrow.
/// These screen-space envelopes are not anatomical dimensions or real millimetres;
/// no guide, clamp or offset becomes a measurement or changes the source report.
enum ScanFeatureGuideGeometry {
    struct Segment: Equatable, Identifiable {
        let id: String
        let start: CGPoint
        let end: CGPoint
    }

    struct Guides: Equatable {
        let eyeID: String
        let browID: String
        /// Actual mapped bounds, never replaced with their clipped display guides.
        let eyeBounds: CGRect
        let browBounds: CGRect
        let referenceSegments: [Segment]
        let dimensionSegments: [Segment]
    }

    struct ChinGuides: Equatable {
        let bounds: CGRect
        let referenceSegments: [Segment]
        let dimensionSegments: [Segment]
    }

    /// Input must contain exactly one canonical eye and its matching eyebrow,
    /// already selected by the caller. Another side, duplicate IDs, flat brows,
    /// invalid points or partially offscreen features abstain instead of guessing.
    /// The eye needs a closed, nondegenerate polygon; the brow must be open and
    /// have nonzero horizontal AND vertical extent. No width-only fallback.
    static func guides(landmarks: [LandmarkPath], transform: ReportPhotoTransform) -> Guides? {
        guard landmarks.count == 2, validTransform(transform) else { return nil }
        let ids = Set(landmarks.map(\.id))
        let eyeID: String
        let browID: String
        if ids == Set(["leftEye", "leftEyebrow"]) {
            eyeID = "leftEye"; browID = "leftEyebrow"
        } else if ids == Set(["rightEye", "rightEyebrow"]) {
            eyeID = "rightEye"; browID = "rightEyebrow"
        } else { return nil }
        guard let eye = landmarks.first(where: { $0.id == eyeID }),
              let brow = landmarks.first(where: { $0.id == browID }),
              validEye(eye), validBrow(brow),
              let eyeBounds = mappedBounds(eye.points, transform: transform),
              let browBounds = mappedBounds(brow.points, transform: transform),
              inside(eyeBounds, viewport: transform.viewport),
              inside(browBounds, viewport: transform.viewport) else { return nil }

        let viewport = transform.viewport
        let union = eyeBounds.union(browBounds)
        // Choose the same, roomier screen side for both height guides. This is
        // presentation placement, not an inference about anatomical left/right.
        let heightX = clamp(union.minX >= viewport.width - union.maxX
                            ? union.minX - 12 : union.maxX + 12,
                            upper: viewport.width)
        let browWidthY = clamp(browBounds.minY - 12, upper: viewport.height)
        let eyeWidthY = clamp(eyeBounds.maxY + 12, upper: viewport.height)
        let dimensions = [
            Segment(id: "brow-width", start: CGPoint(x: browBounds.minX, y: browWidthY),
                    end: CGPoint(x: browBounds.maxX, y: browWidthY)),
            Segment(id: "brow-height", start: CGPoint(x: heightX, y: browBounds.minY),
                    end: CGPoint(x: heightX, y: browBounds.maxY)),
            Segment(id: "eye-width", start: CGPoint(x: eyeBounds.minX, y: eyeWidthY),
                    end: CGPoint(x: eyeBounds.maxX, y: eyeWidthY)),
            Segment(id: "eye-height", start: CGPoint(x: heightX, y: eyeBounds.minY),
                    end: CGPoint(x: heightX, y: eyeBounds.maxY)),
        ]
        return Guides(eyeID: eyeID, browID: browID, eyeBounds: eyeBounds, browBounds: browBounds,
                      referenceSegments: references(browBounds, prefix: "brow", viewport: viewport)
                        + references(eyeBounds, prefix: "eye", viewport: viewport),
                      dimensionSegments: dimensions)
    }

    /// Only the geometry-chin-points producer's four observed endpoints qualify:
    /// [left, right, top, bottom]. Width stays on its real middle horizontal line;
    /// height moves only sideways for display. These are not new measurements.
    static func chinGuides(points: [NormalizedPoint], transform: ReportPhotoTransform) -> ChinGuides? {
        guard points.count == 4, points.allSatisfy(validPoint), validTransform(transform) else { return nil }
        let left = points[0], right = points[1], top = points[2], bottom = points[3]
        guard left.x < right.x, top.y < bottom.y, left.y == right.y, top.x == bottom.x,
              (left.x...right.x).contains(top.x), (top.y...bottom.y).contains(left.y),
              let bounds = mappedBounds(points, transform: transform),
              inside(bounds, viewport: transform.viewport) else { return nil }
        let mappedLeft = transform.position(left), mappedRight = transform.position(right)
        let mappedTop = transform.position(top), mappedBottom = transform.position(bottom)
        let heightX = clamp(bounds.minX >= transform.viewport.width - bounds.maxX
                            ? bounds.minX - 12 : bounds.maxX + 12,
                            upper: transform.viewport.width)
        return ChinGuides(bounds: bounds,
                          referenceSegments: references(bounds, prefix: "chin", viewport: transform.viewport),
                          dimensionSegments: [
                            Segment(id: "chin-width", start: mappedLeft, end: mappedRight),
                            Segment(id: "chin-height", start: CGPoint(x: heightX, y: mappedTop.y),
                                    end: CGPoint(x: heightX, y: mappedBottom.y)),
                          ])
    }

    private static func validPoint(_ point: NormalizedPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    private static func validEye(_ path: LandmarkPath) -> Bool {
        guard path.closed, path.points.allSatisfy(validPoint), Set(path.points).count >= 4 else { return false }
        var twiceArea = 0.0
        for index in path.points.indices {
            let a = path.points[index], b = path.points[(index + 1) % path.points.count]
            twiceArea += a.x * b.y - b.x * a.y
        }
        // Reject near-zero normalized polygons instead of displaying dimensions
        // from a collapsed contour. This is a display safeguard, not a skin score.
        return twiceArea.isFinite && abs(twiceArea) > 0.000000000001
    }

    private static func validBrow(_ path: LandmarkPath) -> Bool {
        !path.closed && path.points.allSatisfy(validPoint) && Set(path.points).count >= 3
    }

    private static func validTransform(_ transform: ReportPhotoTransform) -> Bool {
        let image = transform.imageSize, viewport = transform.viewport, region = transform.region
        return image.width.isFinite && image.height.isFinite && image.width > 0 && image.height > 0
            && viewport.width.isFinite && viewport.height.isFinite && viewport.width > 0 && viewport.height > 0
            && region.origin.x.isFinite && region.origin.y.isFinite
            && region.size.width.isFinite && region.size.height.isFinite
            && region.size.width > 0 && region.size.height > 0
            && region.minX >= 0 && region.minY >= 0 && region.maxX <= 1 && region.maxY <= 1
            && transform.factor.isFinite && transform.factor > 0
            && transform.origin.x.isFinite && transform.origin.y.isFinite
    }

    private static func mappedBounds(_ points: [NormalizedPoint], transform: ReportPhotoTransform) -> CGRect? {
        let mapped = points.map(transform.position)
        guard mapped.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let left = mapped.map(\.x).min(), let right = mapped.map(\.x).max(),
              let top = mapped.map(\.y).min(), let bottom = mapped.map(\.y).max(),
              right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func inside(_ bounds: CGRect, viewport: CGSize) -> Bool {
        bounds.minX >= 0 && bounds.minY >= 0 && bounds.maxX <= viewport.width && bounds.maxY <= viewport.height
    }

    private static func references(_ bounds: CGRect, prefix: String, viewport: CGSize) -> [Segment] {
        let left = clamp(bounds.minX - 8, upper: viewport.width)
        let right = clamp(bounds.maxX + 8, upper: viewport.width)
        let top = clamp(bounds.minY - 8, upper: viewport.height)
        let bottom = clamp(bounds.maxY + 8, upper: viewport.height)
        return [
            Segment(id: prefix + "-top", start: CGPoint(x: left, y: bounds.minY), end: CGPoint(x: right, y: bounds.minY)),
            Segment(id: prefix + "-bottom", start: CGPoint(x: left, y: bounds.maxY), end: CGPoint(x: right, y: bounds.maxY)),
            Segment(id: prefix + "-left", start: CGPoint(x: bounds.minX, y: top), end: CGPoint(x: bounds.minX, y: bottom)),
            Segment(id: prefix + "-right", start: CGPoint(x: bounds.maxX, y: top), end: CGPoint(x: bounds.maxX, y: bottom)),
        ]
    }

    private static func clamp(_ value: CGFloat, upper: CGFloat) -> CGFloat { min(upper, max(0, value)) }
}
