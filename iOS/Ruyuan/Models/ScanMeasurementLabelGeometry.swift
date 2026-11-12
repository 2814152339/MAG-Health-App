import Foundation
import CoreGraphics

/// Placement only: preserves the source anchor and measurement, and never makes
/// a new value. The caller supplies the text's actual measured screen size.
enum ScanMeasurementLabelGeometry {
    private static let clearance: CGFloat = 6

    private struct Box {
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        let bottom: CGFloat

        func containsInterior(_ point: CGPoint) -> Bool {
            point.x > left && point.x < right && point.y > top && point.y < bottom
        }
    }

    /// Returns the nearest safe screen-space label center, or nil when the input
    /// is invalid or no complete label fits. `viewport` retains its real origin;
    /// the caller can inset it to reserve a border. No extra viewport inset is
    /// applied here. Each obstacle (including a zero-thickness line) is padded
    /// by exactly 6pt ONCE; callers should pass the actual stroke bounds only.
    /// Exact-distance ties prefer up, down, left, right, then topmost/leftmost.
    static func safeCenter(desiredAnchor: CGPoint, labelSize: CGSize, viewport: CGRect,
                           obstacles: [CGRect]) -> CGPoint? {
        guard desiredAnchor.x.isFinite, desiredAnchor.y.isFinite,
              labelSize.width.isFinite, labelSize.height.isFinite,
              labelSize.width > 0, labelSize.height > 0,
              valid(viewport, allowsZeroSize: false),
              labelSize.width <= viewport.size.width, labelSize.height <= viewport.size.height else { return nil }
        let halfWidth = labelSize.width / 2, halfHeight = labelSize.height / 2
        let feasible = Box(left: viewport.minX + halfWidth, right: viewport.maxX - halfWidth,
                           top: viewport.minY + halfHeight, bottom: viewport.maxY - halfHeight)
        guard finite(feasible), feasible.left <= feasible.right, feasible.top <= feasible.bottom else { return nil }

        // A center may not enter these open boxes. Their boundaries represent
        // exactly the required clearance; touching is safe, overlap is not.
        var forbidden: [Box] = []
        for obstacle in obstacles {
            guard valid(obstacle, allowsZeroSize: true) else { return nil }
            let box = Box(left: obstacle.minX - clearance - halfWidth,
                          right: obstacle.maxX + clearance + halfWidth,
                          top: obstacle.minY - clearance - halfHeight,
                          bottom: obstacle.maxY + clearance + halfHeight)
            guard finite(box) else { return nil }
            forbidden.append(box)
        }
        func clamped(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(feasible.right, max(feasible.left, point.x)),
                    y: min(feasible.bottom, max(feasible.top, point.y)))
        }
        func isSafe(_ point: CGPoint) -> Bool { !forbidden.contains { $0.containsInterior(point) } }
        let nearestInViewport = clamped(desiredAnchor)
        if isSafe(nearestInViewport) { return nearestInViewport }

        // For axis-aligned obstacles the nearest feasible point lies on a box
        // edge, an edge intersection, or the desired coordinate's projection.
        // Including the Cartesian edge candidates avoids falsely giving up when
        // all four direct directions are blocked but a corner remains free.
        var xs = Set([nearestInViewport.x, feasible.left, feasible.right])
        var ys = Set([nearestInViewport.y, feasible.top, feasible.bottom])
        for box in forbidden {
            xs.insert(min(feasible.right, max(feasible.left, box.left)))
            xs.insert(min(feasible.right, max(feasible.left, box.right)))
            ys.insert(min(feasible.bottom, max(feasible.top, box.top)))
            ys.insert(min(feasible.bottom, max(feasible.top, box.bottom)))
        }

        // Ordinary display coordinates use unscaled distances. A common scale
        // for every candidate avoids overflow with extreme but finite inputs.
        let dx = max(abs(feasible.left - desiredAnchor.x), abs(feasible.right - desiredAnchor.x))
        let dy = max(abs(feasible.top - desiredAnchor.y), abs(feasible.bottom - desiredAnchor.y))
        let magnitudes: [CGFloat] = [1, abs(desiredAnchor.x), abs(desiredAnchor.y),
                                    abs(feasible.left), abs(feasible.right), abs(feasible.top), abs(feasible.bottom)]
        let scale: CGFloat = hypot(dx, dy).isFinite ? 1 : magnitudes.max()!
        func distance(_ point: CGPoint) -> CGFloat {
            hypot(point.x / scale - desiredAnchor.x / scale, point.y / scale - desiredAnchor.y / scale)
        }
        func direction(_ point: CGPoint) -> Int {
            if point.x == nearestInViewport.x {
                return point.y < nearestInViewport.y ? 0 : 1
            }
            if point.y == nearestInViewport.y { return point.x < nearestInViewport.x ? 2 : 3 }
            return 4
        }
        var best: CGPoint?
        var bestDistance = CGFloat.infinity
        var bestDirection = Int.max
        for x in xs.sorted() {
            for y in ys.sorted() {
                let point = CGPoint(x: x, y: y)
                guard isSafe(point) else { continue }
                let length = distance(point), rank = direction(point)
                if best == nil || length < bestDistance
                    || (length == bestDistance && (rank < bestDirection
                        || (rank == bestDirection && (point.y < best!.y
                            || (point.y == best!.y && point.x < best!.x))))) {
                    best = point; bestDistance = length; bestDirection = rank
                }
            }
        }
        return best
    }

    private static func valid(_ rect: CGRect, allowsZeroSize: Bool) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.maxX.isFinite, rect.maxY.isFinite else { return false }
        return allowsZeroSize ? rect.size.width >= 0 && rect.size.height >= 0
            : rect.size.width > 0 && rect.size.height > 0
    }

    private static func finite(_ box: Box) -> Bool {
        box.left.isFinite && box.right.isFinite && box.top.isFinite && box.bottom.isFinite
    }
}
