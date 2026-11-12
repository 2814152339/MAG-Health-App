import Foundation
import CoreGraphics

/// Presentation-only motion over existing screen-space evidence. Never writes report values.
enum ScanMotionTimeline {
    struct Phases: Equatable {
        let points: Double
        let referenceLines: Double
        let measurements: Double
        let labels: Double
        let panel: Double

        static let complete = Phases(points: 1, referenceLines: 1, measurements: 1, labels: 1, panel: 1)
    }

    struct LineSegment: Equatable {
        let start: CGPoint
        let end: CGPoint
    }

    struct AngleMotion: Equatable {
        let vertex: CGPoint
        let firstRayEndpoint: CGPoint
        let movingRayEndpoint: CGPoint
        let arcPoints: [CGPoint]
        let radius: CGFloat
        let startRadians: Double
        let finalSweepRadians: Double
        let animatedSweepRadians: Double
    }

    static let motionDuration: TimeInterval = 2.3

    /// NaN starts collapsed; infinities clamp to their corresponding endpoint.
    static func unitProgress(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(1, max(0, value))
    }

    static func smoothstep(_ value: Double) -> Double {
        let t = unitProgress(value)
        return t * t * (3 - 2 * t)
    }

    /// Long scenes finish motion at 2.3s and hold. Short scenes compress all windows
    /// proportionally, so no final label/panel is lost at the scene boundary.
    static func phases(elapsed: TimeInterval, sceneDuration: TimeInterval = motionDuration,
                       reduceMotion: Bool = false) -> Phases {
        if reduceMotion { return .complete }
        let duration = sceneDuration.isFinite && sceneDuration > 0 ? sceneDuration : motionDuration
        if !elapsed.isNaN, elapsed >= min(duration, motionDuration) { return .complete }
        let scale = min(1, duration / motionDuration)
        let time = elapsed.isNaN ? 0 : max(0, elapsed) / scale
        func phase(_ start: Double, _ end: Double) -> Double {
            smoothstep((time - start) / (end - start))
        }
        return Phases(points: phase(0, 0.35),
                      referenceLines: phase(0.25, 0.9),
                      measurements: phase(0.65, 1.65),
                      labels: phase(1.3, 2.0),
                      panel: phase(1.8, 2.3))
    }

    /// A distance-weighted prefix, not an index-weighted guess. A malformed point
    /// rejects the whole path instead of bridging across missing evidence.
    static func polylinePrefix(_ points: [CGPoint], progress: Double) -> [CGPoint] {
        guard let first = points.first, points.allSatisfy(isFinite) else { return [] }
        let p = unitProgress(progress)
        if p == 0 || points.count == 1 { return [first] }
        var lengths: [Double] = []
        var total = 0.0
        for (start, end) in zip(points, points.dropFirst()) {
            guard let length = distance(start, end) else { return [] }
            lengths.append(length)
            total += length
            guard total.isFinite else { return [] }
        }
        guard total > 0 else { return [first] }
        if p == 1 { return points }
        var remaining = total * p
        var result = [first]
        for (index, length) in lengths.enumerated() {
            if length == 0 { continue }
            if remaining >= length {
                result.append(points[index + 1])
                remaining -= length
                if remaining <= 0 { return result }
            } else {
                result.append(interpolate(points[index], points[index + 1], remaining / length))
                return result
            }
        }
        return result
    }

    /// Both ends grow away from the true midpoint; arrow tips may use only these
    /// returned endpoints, which always remain on the original segment.
    static func centerOutLine(from start: CGPoint, to end: CGPoint, progress: Double) -> LineSegment? {
        guard let length = distance(start, end), length > 0 else { return nil }
        let p = unitProgress(progress)
        if p == 1 { return LineSegment(start: start, end: end) }
        return LineSegment(start: interpolate(start, end, (1 - p) / 2),
                           end: interpolate(start, end, (1 + p) / 2))
    }

    /// Signed shortest sweep in [-pi, pi]. An exact half-turn retains the raw
    /// direction, avoiding arbitrary sign changes at the tie.
    static func shortestSweep(from start: Double, to end: Double) -> Double? {
        guard start.isFinite, end.isFinite else { return nil }
        let delta = end - start
        guard delta.isFinite else { return nil }
        var sweep = delta.truncatingRemainder(dividingBy: 2 * .pi)
        if sweep > .pi { sweep -= 2 * .pi }
        if sweep < -.pi { sweep += 2 * .pi }
        return sweep == 0 ? 0 : sweep
    }

    /// Call ONLY after all three real points share the same screen transform.
    /// The moving ray retains the real second-ray length; at progress 0 it lies
    /// on the first ray and at 1 its endpoint is exactly the supplied second point.
    static func angle(first: CGPoint, vertex: CGPoint, second: CGPoint, progress: Double,
                      radius requestedRadius: CGFloat = 24) -> AngleMotion? {
        guard let firstLength = distance(vertex, first), firstLength > 0,
              let secondLength = distance(vertex, second), secondLength > 0,
              requestedRadius.isFinite, requestedRadius > 0 else { return nil }
        let start = atan2(Double(first.y - vertex.y), Double(first.x - vertex.x))
        let end = atan2(Double(second.y - vertex.y), Double(second.x - vertex.x))
        guard let finalSweep = shortestSweep(from: start, to: end) else { return nil }
        let p = unitProgress(progress)
        let sweep = finalSweep * p
        let radius = min(Double(requestedRadius), min(firstLength, secondLength))
        let moving = p == 1 ? second : polar(vertex: vertex, radius: secondLength, angle: start + sweep)
        guard isFinite(moving) else { return nil }
        let arcStart = interpolate(vertex, first, radius / firstLength)
        var arc = [arcStart]
        if sweep != 0 {
            // At most 36 segments for a half-turn; no unbounded sampling.
            let count = min(128, max(1, Int(ceil(abs(sweep) / (.pi / 36)))))
            for index in 1...count {
                if index == count && p == 1 {
                    arc.append(interpolate(vertex, second, radius / secondLength))
                } else {
                    arc.append(polar(vertex: vertex, radius: radius, angle: start + sweep * Double(index) / Double(count)))
                }
            }
        }
        guard arc.allSatisfy(isFinite) else { return nil }
        return AngleMotion(vertex: vertex, firstRayEndpoint: first, movingRayEndpoint: moving,
                           arcPoints: arc, radius: CGFloat(radius), startRadians: start,
                           finalSweepRadians: finalSweep, animatedSweepRadians: sweep)
    }

    /// Display interpolation only: nil/nonfinite source measurements stay absent.
    /// Pass an eased phase if easing is desired; never persist this intermediate value.
    static func animatedValue(_ existing: Double?, progress: Double, reduceMotion: Bool = false) -> Double? {
        guard let existing, existing.isFinite else { return nil }
        return reduceMotion ? existing : existing * unitProgress(progress)
    }

    private static func isFinite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }

    private static func distance(_ start: CGPoint, _ end: CGPoint) -> Double? {
        guard isFinite(start), isFinite(end) else { return nil }
        let dx = Double(end.x) - Double(start.x)
        let dy = Double(end.y) - Double(start.y)
        guard dx.isFinite, dy.isFinite else { return nil }
        let value = hypot(dx, dy)
        return value.isFinite ? value : nil
    }

    private static func interpolate(_ start: CGPoint, _ end: CGPoint, _ progress: Double) -> CGPoint {
        let t = CGFloat(unitProgress(progress))
        return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
    }

    private static func polar(vertex: CGPoint, radius: Double, angle: Double) -> CGPoint {
        CGPoint(x: vertex.x + CGFloat(radius * cos(angle)), y: vertex.y + CGFloat(radius * sin(angle)))
    }
}

/// Per-scene playback only. Supply one time domain consistently (Date or monotonic
/// TimeInterval). Paused elapsed time is frozen, and resume reanchors without a jump.
struct ScanPlaybackClock {
    private var accumulated: TimeInterval = 0
    private var anchor: TimeInterval?
    private(set) var isPaused = false

    init(now: TimeInterval = 0) { anchor = now.isFinite ? now : nil }
    init(now: Date) { self.init(now: now.timeIntervalSinceReferenceDate) }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        guard !isPaused, let anchor, now.isFinite else { return accumulated }
        let delta = now - anchor
        guard delta > 0 else { return accumulated }
        let result = accumulated + delta
        return result.isFinite ? result : .greatestFiniteMagnitude
    }

    func elapsed(at now: Date) -> TimeInterval { elapsed(at: now.timeIntervalSinceReferenceDate) }

    mutating func reset(at now: TimeInterval) {
        guard now.isFinite else { return }
        accumulated = 0
        anchor = now
        isPaused = false
    }

    mutating func reset(at now: Date) { reset(at: now.timeIntervalSinceReferenceDate) }

    mutating func pause(at now: TimeInterval) {
        guard !isPaused, now.isFinite else { return }
        accumulated = elapsed(at: now)
        anchor = nil
        isPaused = true
    }

    mutating func pause(at now: Date) { pause(at: now.timeIntervalSinceReferenceDate) }

    mutating func resume(at now: TimeInterval) {
        guard isPaused, now.isFinite else { return }
        anchor = now
        isPaused = false
    }

    mutating func resume(at now: Date) { resume(at: now.timeIntervalSinceReferenceDate) }
}
