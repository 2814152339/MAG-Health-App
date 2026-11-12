import Foundation
import CoreGraphics
import XCTest
@testable import Ruyuan

final class ScanMotionTimelineTests: XCTestCase {
    func testUnitProgressClampsNegativeNaNAndInfinities() {
        XCTAssertEqual(ScanMotionTimeline.unitProgress(-2), 0)
        XCTAssertEqual(ScanMotionTimeline.unitProgress(.nan), 0)
        XCTAssertEqual(ScanMotionTimeline.unitProgress(-.infinity), 0)
        XCTAssertEqual(ScanMotionTimeline.unitProgress(.infinity), 1)
        XCTAssertEqual(ScanMotionTimeline.unitProgress(2), 1)
        XCTAssertEqual(ScanMotionTimeline.unitProgress(0.375), 0.375)
    }

    func testSmoothstepIsBoundedAndHasContinuousEndpointTangents() {
        XCTAssertEqual(ScanMotionTimeline.smoothstep(0), 0)
        XCTAssertEqual(ScanMotionTimeline.smoothstep(0.5), 0.5)
        XCTAssertEqual(ScanMotionTimeline.smoothstep(1), 1)
        XCTAssertEqual(ScanMotionTimeline.smoothstep(.nan), 0)
        let epsilon = 0.000001
        XCTAssertLessThan(ScanMotionTimeline.smoothstep(epsilon) / epsilon, 0.00001)
        XCTAssertLessThan((1 - ScanMotionTimeline.smoothstep(1 - epsilon)) / epsilon, 0.00001)
        for step in 0...100 {
            let p = Double(step) / 100
            let value = ScanMotionTimeline.smoothstep(p)
            XCTAssertTrue((0...1).contains(value))
            XCTAssertEqual(value + ScanMotionTimeline.smoothstep(1 - p), 1, accuracy: 0.000000001)
        }
    }

    func testPhaseWindowsRevealPointsReferencesMeasurementsLabelsThenPanel() {
        let start = ScanMotionTimeline.phases(elapsed: 0)
        XCTAssertEqual(values(start), [0, 0, 0, 0, 0])
        let points = ScanMotionTimeline.phases(elapsed: 0.35)
        XCTAssertEqual(points.points, 1)
        XCTAssertGreaterThan(points.referenceLines, 0)
        XCTAssertEqual(points.measurements, 0)
        XCTAssertEqual(points.labels, 0)
        let measurement = ScanMotionTimeline.phases(elapsed: 1)
        XCTAssertEqual(measurement.referenceLines, 1)
        XCTAssertGreaterThan(measurement.measurements, 0)
        XCTAssertEqual(measurement.labels, 0)
        let labels = ScanMotionTimeline.phases(elapsed: 1.7)
        XCTAssertEqual(labels.measurements, 1)
        XCTAssertGreaterThan(labels.labels, 0)
        XCTAssertEqual(labels.panel, 0)
        XCTAssertEqual(ScanMotionTimeline.phases(elapsed: 2.3), .complete)
        XCTAssertEqual(ScanMotionTimeline.phases(elapsed: 99), .complete)
    }

    func testShortScenesCompressAllPhasesWhileLongScenesHoldFinalState() {
        XCTAssertEqual(ScanMotionTimeline.phases(elapsed: 0.5, sceneDuration: 1.15),
                       ScanMotionTimeline.phases(elapsed: 1, sceneDuration: 2.3))
        XCTAssertEqual(ScanMotionTimeline.phases(elapsed: 1.15, sceneDuration: 1.15), .complete)
        XCTAssertEqual(ScanMotionTimeline.phases(elapsed: 2.3, sceneDuration: 12), .complete)
        for invalid in [0.0, -1, .nan, .infinity] {
            XCTAssertEqual(ScanMotionTimeline.phases(elapsed: 1, sceneDuration: invalid),
                           ScanMotionTimeline.phases(elapsed: 1))
        }
    }

    func testPhaseBreakpointsAreContinuousMonotonicAndFinite() {
        let epsilon = 0.000001
        for boundary in [0.0, 0.25, 0.35, 0.65, 0.9, 1.3, 1.65, 1.8, 2.0, 2.3] {
            let before = values(ScanMotionTimeline.phases(elapsed: boundary - epsilon))
            let after = values(ScanMotionTimeline.phases(elapsed: boundary + epsilon))
            for (a, b) in zip(before, after) {
                XCTAssertTrue(a.isFinite && b.isFinite)
                XCTAssertLessThanOrEqual(a, b)
                XCTAssertLessThan(abs(b - a), 0.0001)
            }
        }
        XCTAssertEqual(values(ScanMotionTimeline.phases(elapsed: -.infinity)), [0, 0, 0, 0, 0])
        XCTAssertEqual(values(ScanMotionTimeline.phases(elapsed: .nan)), [0, 0, 0, 0, 0])
        XCTAssertEqual(ScanMotionTimeline.phases(elapsed: .infinity), .complete)
    }

    func testReduceMotionReturnsFinalPresentationWithoutDisablingClock() {
        XCTAssertEqual(ScanMotionTimeline.phases(elapsed: -10, reduceMotion: true), .complete)
        XCTAssertEqual(ScanMotionTimeline.phases(elapsed: .nan, sceneDuration: 0.1, reduceMotion: true), .complete)
        var clock = ScanPlaybackClock(now: 0)
        clock.pause(at: 1)
        XCTAssertTrue(clock.isPaused)
        XCTAssertEqual(clock.elapsed(at: 10), 1)
        clock.reset(at: 10)
        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.elapsed(at: 10), 0)
    }

    func testPolylinePrefixUsesActualSegmentLengthAndExactBoundaries() throws {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 0), CGPoint(x: 3, y: 4)]
        XCTAssertEqual(ScanMotionTimeline.polylinePrefix(points, progress: 0), [points[0]])
        XCTAssertEqual(ScanMotionTimeline.polylinePrefix(points, progress: 1), points)
        let half = ScanMotionTimeline.polylinePrefix(points, progress: 0.5)
        XCTAssertEqual(half.count, 3)
        assertPoint(try XCTUnwrap(half.last), CGPoint(x: 3, y: 0.5))
        let boundary = ScanMotionTimeline.polylinePrefix(points, progress: 3.0 / 7)
        XCTAssertEqual(boundary, Array(points.prefix(2)))
        let before = try XCTUnwrap(ScanMotionTimeline.polylinePrefix(points, progress: 3.0 / 7 - 0.000001).last)
        let after = try XCTUnwrap(ScanMotionTimeline.polylinePrefix(points, progress: 3.0 / 7 + 0.000001).last)
        XCTAssertLessThan(hypot(after.x - before.x, after.y - before.y), 0.0001)
    }

    func testPolylineRejectsNonfinitePointsAndHandlesRepeatedOrDegenerateSegments() {
        let a = CGPoint(x: 1, y: 2)
        let b = CGPoint(x: 5, y: 2)
        XCTAssertEqual(ScanMotionTimeline.polylinePrefix([], progress: 0.5), [])
        XCTAssertEqual(ScanMotionTimeline.polylinePrefix([a], progress: 0.5), [a])
        XCTAssertEqual(ScanMotionTimeline.polylinePrefix([a, a, a], progress: 0.5), [a])
        XCTAssertEqual(ScanMotionTimeline.polylinePrefix([a, a, b, b], progress: 0.5).last, CGPoint(x: 3, y: 2))
        XCTAssertEqual(ScanMotionTimeline.polylinePrefix([a, b], progress: .nan), [a])
        XCTAssertEqual(ScanMotionTimeline.polylinePrefix([a, b], progress: .infinity), [a, b])
        XCTAssertTrue(ScanMotionTimeline.polylinePrefix([a, CGPoint(x: CGFloat.nan, y: 1), b], progress: 0.5).isEmpty)
        XCTAssertTrue(ScanMotionTimeline.polylinePrefix([a, CGPoint(x: 1, y: CGFloat.infinity)], progress: 1).isEmpty)
    }

    func testCenterOutEndpointsStayOnRealSegmentAndReverseSymmetrically() throws {
        let start = CGPoint(x: 2, y: 4)
        let end = CGPoint(x: 10, y: 4)
        let collapsed = try XCTUnwrap(ScanMotionTimeline.centerOutLine(from: start, to: end, progress: 0))
        XCTAssertEqual(collapsed.start, CGPoint(x: 6, y: 4))
        XCTAssertEqual(collapsed.start, collapsed.end)
        let half = try XCTUnwrap(ScanMotionTimeline.centerOutLine(from: start, to: end, progress: 0.5))
        XCTAssertEqual(half.start, CGPoint(x: 4, y: 4))
        XCTAssertEqual(half.end, CGPoint(x: 8, y: 4))
        for p in [-1.0, 0, 0.25, 0.75, 1, 2, .nan, .infinity] {
            let line = try XCTUnwrap(ScanMotionTimeline.centerOutLine(from: start, to: end, progress: p))
            let reverse = try XCTUnwrap(ScanMotionTimeline.centerOutLine(from: end, to: start, progress: p))
            XCTAssertTrue((start.x...end.x).contains(line.start.x))
            XCTAssertTrue((start.x...end.x).contains(line.end.x))
            assertPoint(line.start, reverse.end)
            assertPoint(line.end, reverse.start)
        }
        XCTAssertNil(ScanMotionTimeline.centerOutLine(from: start, to: start, progress: 1))
        XCTAssertNil(ScanMotionTimeline.centerOutLine(from: start, to: CGPoint(x: CGFloat.nan, y: 0), progress: 1))
    }

    func testCenterOutMirroredDiagonalDoesNotExtendBeyondTrueEndpoints() throws {
        let a = CGPoint(x: 20, y: 40)
        let b = CGPoint(x: 60, y: 80)
        let line = try XCTUnwrap(ScanMotionTimeline.centerOutLine(from: a, to: b, progress: 0.5))
        assertPoint(line.start, CGPoint(x: 30, y: 50))
        assertPoint(line.end, CGPoint(x: 50, y: 70))
        let mirror = try XCTUnwrap(ScanMotionTimeline.centerOutLine(from: CGPoint(x: -a.x, y: a.y),
                                                                     to: CGPoint(x: -b.x, y: b.y), progress: 0.5))
        assertPoint(mirror.start, CGPoint(x: -line.start.x, y: line.start.y))
        assertPoint(mirror.end, CGPoint(x: -line.end.x, y: line.end.y))
    }

    func testAngleOpensFromFirstRayToExactSecondEndpointAndClampsArcRadius() throws {
        let vertex = CGPoint(x: 100, y: 200)
        let first = CGPoint(x: 110, y: 200)
        let second = CGPoint(x: 100, y: 220)
        let collapsed = try XCTUnwrap(ScanMotionTimeline.angle(first: first, vertex: vertex, second: second, progress: 0))
        assertPoint(collapsed.movingRayEndpoint, CGPoint(x: 120, y: 200))
        XCTAssertEqual(collapsed.arcPoints.count, 1)
        let half = try XCTUnwrap(ScanMotionTimeline.angle(first: first, vertex: vertex, second: second, progress: 0.5))
        XCTAssertEqual(half.firstRayEndpoint, first)
        XCTAssertEqual(half.vertex, vertex)
        XCTAssertEqual(half.radius, 10)
        XCTAssertEqual(half.finalSweepRadians, .pi / 2, accuracy: 0.000000001)
        XCTAssertEqual(half.animatedSweepRadians, .pi / 4, accuracy: 0.000000001)
        assertPoint(half.movingRayEndpoint, CGPoint(x: 100 + sqrt(200.0), y: 200 + sqrt(200.0)))
        for point in half.arcPoints {
            XCTAssertEqual(hypot(point.x - vertex.x, point.y - vertex.y), half.radius, accuracy: 0.000000001)
        }
        let final = try XCTUnwrap(ScanMotionTimeline.angle(first: first, vertex: vertex, second: second, progress: 1))
        XCTAssertEqual(final.movingRayEndpoint, second)
        assertPoint(try XCTUnwrap(final.arcPoints.last), CGPoint(x: 100, y: 210))
    }

    func testAngleUsesActualScreenDistancesRatherThanNormalizedPhotoAspect() throws {
        let angle = try XCTUnwrap(ScanMotionTimeline.angle(first: CGPoint(x: 140, y: 200), vertex: CGPoint(x: 100, y: 200),
                                                          second: CGPoint(x: 120, y: 240), progress: 1, radius: 12))
        XCTAssertEqual(angle.finalSweepRadians, atan2(40.0, 20.0), accuracy: 0.000000001)
        XCTAssertNotEqual(angle.finalSweepRadians, .pi / 4)
        XCTAssertEqual(angle.radius, 12)
    }

    func testMirroredAnglesReverseSweepAndMirrorActualGeometry() throws {
        let original = try XCTUnwrap(ScanMotionTimeline.angle(first: CGPoint(x: 10, y: 0), vertex: .zero,
                                                             second: CGPoint(x: 0, y: 20), progress: 0.5, radius: 5))
        let mirrored = try XCTUnwrap(ScanMotionTimeline.angle(first: CGPoint(x: -10, y: 0), vertex: .zero,
                                                             second: CGPoint(x: 0, y: 20), progress: 0.5, radius: 5))
        XCTAssertEqual(mirrored.finalSweepRadians, -original.finalSweepRadians, accuracy: 0.000000001)
        assertPoint(mirrored.movingRayEndpoint, CGPoint(x: -original.movingRayEndpoint.x, y: original.movingRayEndpoint.y))
        XCTAssertEqual(mirrored.arcPoints.count, original.arcPoints.count)
        for (a, b) in zip(original.arcPoints, mirrored.arcPoints) { assertPoint(b, CGPoint(x: -a.x, y: a.y)) }
    }

    func testShortestSweepCrossesPlusMinusPiWithoutLongRotation() throws {
        let epsilon = 0.0001
        XCTAssertEqual(try XCTUnwrap(ScanMotionTimeline.shortestSweep(from: .pi - epsilon, to: -.pi + epsilon)),
                       2 * epsilon, accuracy: 0.000000001)
        XCTAssertEqual(try XCTUnwrap(ScanMotionTimeline.shortestSweep(from: -.pi + epsilon, to: .pi - epsilon)),
                       -2 * epsilon, accuracy: 0.000000001)
        XCTAssertEqual(try XCTUnwrap(ScanMotionTimeline.shortestSweep(from: 0, to: .pi)), Double.pi)
        XCTAssertEqual(try XCTUnwrap(ScanMotionTimeline.shortestSweep(from: 0, to: -.pi)), -Double.pi)
        XCTAssertEqual(try XCTUnwrap(ScanMotionTimeline.shortestSweep(from: .pi, to: -.pi)), 0)
        XCTAssertNil(ScanMotionTimeline.shortestSweep(from: .infinity, to: 0))
        let first = CGPoint(x: 10 * cos(.pi - epsilon), y: 10 * sin(.pi - epsilon))
        let second = CGPoint(x: 10 * cos(-.pi + epsilon), y: 10 * sin(-.pi + epsilon))
        let half = try XCTUnwrap(ScanMotionTimeline.angle(first: first, vertex: .zero, second: second, progress: 0.5))
        assertPoint(half.movingRayEndpoint, CGPoint(x: -10, y: 0))
    }

    func testAngleDegenerateNonfiniteAndCollinearInputsDoNotInventGeometry() throws {
        let first = CGPoint(x: 10, y: 0)
        let second = CGPoint(x: 0, y: 20)
        XCTAssertNil(ScanMotionTimeline.angle(first: .zero, vertex: .zero, second: second, progress: 1))
        XCTAssertNil(ScanMotionTimeline.angle(first: first, vertex: .zero, second: .zero, progress: 1))
        XCTAssertNil(ScanMotionTimeline.angle(first: first, vertex: CGPoint(x: CGFloat.nan, y: 0), second: second, progress: 1))
        for invalid in [CGFloat(0), -1, .nan, .infinity] {
            XCTAssertNil(ScanMotionTimeline.angle(first: first, vertex: .zero, second: second, progress: 1, radius: invalid))
        }
        let zero = try XCTUnwrap(ScanMotionTimeline.angle(first: first, vertex: .zero, second: CGPoint(x: 20, y: 0), progress: 0.5))
        XCTAssertEqual(zero.finalSweepRadians, 0)
        XCTAssertEqual(zero.arcPoints.count, 1)
        let halfTurn = try XCTUnwrap(ScanMotionTimeline.angle(first: first, vertex: .zero, second: CGPoint(x: -20, y: 0), progress: 1))
        XCTAssertEqual(abs(halfTurn.finalSweepRadians), .pi)
        XCTAssertEqual(halfTurn.movingRayEndpoint, CGPoint(x: -20, y: 0))
        let collapsed = try XCTUnwrap(ScanMotionTimeline.angle(first: first, vertex: .zero, second: second, progress: .nan))
        XCTAssertEqual(collapsed.animatedSweepRadians, 0)
    }

    func testAnimatedValuesUseOnlyFiniteExistingMeasurements() {
        XCTAssertNil(ScanMotionTimeline.animatedValue(nil, progress: 1))
        XCTAssertNil(ScanMotionTimeline.animatedValue(.nan, progress: 1))
        XCTAssertNil(ScanMotionTimeline.animatedValue(.infinity, progress: 1, reduceMotion: true))
        XCTAssertEqual(ScanMotionTimeline.animatedValue(124.36, progress: 0), 0)
        XCTAssertEqual(ScanMotionTimeline.animatedValue(124.36, progress: 0.5), 62.18)
        XCTAssertEqual(ScanMotionTimeline.animatedValue(-8.08, progress: 0.5), -4.04)
        XCTAssertEqual(ScanMotionTimeline.animatedValue(124.36, progress: .infinity), 124.36)
        XCTAssertEqual(ScanMotionTimeline.animatedValue(124.36, progress: .nan, reduceMotion: true), 124.36)
    }

    func testClockPauseFreezeResumeAndManualResetNeverJump() {
        var clock = ScanPlaybackClock(now: 10)
        XCTAssertEqual(clock.elapsed(at: 12), 2)
        clock.pause(at: 12)
        XCTAssertTrue(clock.isPaused)
        XCTAssertEqual(clock.elapsed(at: 999), 2)
        clock.pause(at: 999)
        XCTAssertEqual(clock.elapsed(at: 2000), 2)
        clock.resume(at: 100)
        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.elapsed(at: 100), 2)
        XCTAssertEqual(clock.elapsed(at: 101), 3)
        clock.resume(at: 200)
        XCTAssertEqual(clock.elapsed(at: 102), 4)
        clock.pause(at: 103)
        clock.reset(at: 500)
        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.elapsed(at: 500), 0)
        XCTAssertEqual(clock.elapsed(at: 501), 1)
    }

    func testClockMultiplePausesAndDateOverloadsPreserveElapsedTime() {
        var clock = ScanPlaybackClock(now: 0)
        clock.pause(at: 5)
        clock.resume(at: 100)
        clock.pause(at: 103)
        XCTAssertEqual(clock.elapsed(at: 1000), 8)
        clock.resume(at: 200)
        XCTAssertEqual(clock.elapsed(at: 201), 9)
        var dated = ScanPlaybackClock(now: Date(timeIntervalSinceReferenceDate: 100))
        dated.pause(at: Date(timeIntervalSinceReferenceDate: 103))
        XCTAssertEqual(dated.elapsed(at: Date(timeIntervalSinceReferenceDate: 900)), 3)
        dated.resume(at: Date(timeIntervalSinceReferenceDate: 1000))
        XCTAssertEqual(dated.elapsed(at: Date(timeIntervalSinceReferenceDate: 1001)), 4)
        dated.reset(at: Date(timeIntervalSinceReferenceDate: 1200))
        XCTAssertEqual(dated.elapsed(at: Date(timeIntervalSinceReferenceDate: 1201)), 1)
    }

    func testClockIgnoresNonfiniteControlsAndClampsBackwardTime() {
        var clock = ScanPlaybackClock(now: 0)
        clock.pause(at: TimeInterval.nan)
        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.elapsed(at: 2), 2)
        clock.pause(at: 2)
        clock.resume(at: TimeInterval.infinity)
        XCTAssertTrue(clock.isPaused)
        XCTAssertEqual(clock.elapsed(at: TimeInterval.infinity), 2)
        clock.resume(at: 10)
        clock.reset(at: TimeInterval.nan)
        XCTAssertEqual(clock.elapsed(at: 11), 3)
        clock.reset(at: -5)
        XCTAssertEqual(clock.elapsed(at: -6), 0)
        XCTAssertEqual(clock.elapsed(at: -3), 2)
        let invalidStart = ScanPlaybackClock(now: TimeInterval.nan)
        XCTAssertEqual(invalidStart.elapsed(at: 100), 0)
    }

    private func values(_ phases: ScanMotionTimeline.Phases) -> [Double] {
        [phases.points, phases.referenceLines, phases.measurements, phases.labels, phases.panel]
    }

    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.00000001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.00000001, file: file, line: line)
    }
}
