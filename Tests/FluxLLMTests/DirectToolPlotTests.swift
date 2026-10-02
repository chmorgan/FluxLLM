import Foundation
import XCTest

@testable import FluxLLM

final class DirectToolPlotTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testDirectHistoryPreservesExactRatesGapsAndCurrentTail() {
        let history = ToolActivityHistory(
            events: [call(0.25), call(2.75), call(3), call(3.25)],
            observations: [
                observation(0), observation(0.5), observation(1, available: false),
                observation(2), observation(2.5), observation(3), observation(3.5),
            ], now: date(4), duration: 4)
        let expected = [
            [
                point(0, 0), point(0, 120), point(0.5, 120), point(0.5, 0),
                point(2, 0), point(2, 60), point(3, 60), point(3, 240),
                point(3.5, 240), point(4, 240),
            ]
        ]
        XCTAssertEqual(history.directZeroFilledPlotSegments, expected)
        XCTAssertEqual(history.directZeroFilledPlotSegments, history.zeroFilledPlotSegments)
        XCTAssertEqual(history.buckets.map(\.callCount), [1, 1, 2])
        XCTAssertEqual(history.buckets.map(\.observedDuration), [0.5, 1, 0.5])
    }

    func testClippedStartsAndTouchingSegmentsKeepVerticalTransitions() {
        let segments = [[bucket(-2, 2, 5), bucket(2, 4, 9)], [bucket(4, 5, 11)]]
        let expected = [
            [
                point(0, 0), point(0, 5), point(2, 5), point(2, 9),
                point(4, 9), point(4, 11), point(5, 11), point(5, 0), point(6, 0),
            ]
        ]
        XCTAssertEqual(direct(segments, cutoff: 0, now: 6, current: false), expected)
        assertEquivalent(segments, cutoff: 0, now: 6, current: false)
        assertEquivalent(segments, cutoff: 0, now: 6, current: true)

        // Validation applies after clipping, just like the reference path.
        let clippedInfiniteStart = [[bucket(-.infinity, 1, 3)]]
        XCTAssertEqual(
            direct(clippedInfiniteStart, cutoff: 0, now: 2, current: false),
            [[point(0, 0), point(0, 3), point(1, 3), point(1, 0), point(2, 0)]])
        assertEquivalent(clippedInfiniteStart, cutoff: 0, now: 2, current: false)
    }

    func testObservedZeroBucketsKeepEveryIntermediateTimestamp() {
        let segments = [[bucket(0, 3, 0), bucket(3, 6, 0), bucket(6, 9, 0)]]
        let expected = [[point(0, 0), point(3, 0), point(6, 0), point(9, 0), point(10, 0)]]
        for current in [false, true] {
            XCTAssertEqual(direct(segments, cutoff: 0, now: 10, current: current), expected)
            assertEquivalent(segments, cutoff: 0, now: 10, current: current)
        }
        let equalRate = [[bucket(0, 3, 4), bucket(3, 6, 4)]]
        XCTAssertEqual(
            direct(equalRate, cutoff: 0, now: 7, current: true),
            [[point(0, 0), point(0, 4), point(3, 4), point(6, 4), point(7, 4)]])
    }

    func testEmptyInstantaneousAndNonpositiveSpansDoNotInventRates() {
        for segments in [
            [[ToolActivityBucket]](), [[]], [[bucket(2, 2, 80)]],
            [[bucket(3, 1, 80)]], [[bucket(.nan, 1, 80)]],
        ] {
            for current in [false, true] {
                XCTAssertEqual(
                    direct(segments, cutoff: 0, now: 6, current: current),
                    [[point(0, 0), point(6, 0)]])
                assertEquivalent(segments, cutoff: 0, now: 6, current: current)
            }
        }
        let pending = ToolActivityHistory(
            events: [call(1)], observations: [], now: date(6), duration: 6)
        XCTAssertEqual(pending.directZeroFilledPlotSegments, [[point(0, 0), point(6, 0)]])
        XCTAssertEqual(pending.directZeroFilledPlotSegments, pending.zeroFilledPlotSegments)
    }

    func testFreshStaleUnavailableAndPendingTailsMatchReference() {
        let samples = stride(from: 0.0, through: 2, by: 0.5).map { observation($0) }
        let histories = [
            ToolActivityHistory(
                events: [call(1)], observations: samples, now: date(7), duration: 60),
            ToolActivityHistory(
                events: [call(1)], observations: samples, now: date(7.5), duration: 60),
            ToolActivityHistory(
                events: [call(1)], observations: samples + [observation(2.5, available: false)],
                now: date(3), duration: 60),
            ToolActivityHistory(
                events: [call(1), call(2.5)], observations: samples, now: date(3), duration: 60),
        ]
        XCTAssertNotNil(histories[0].current)
        XCTAssertEqual(histories[0].directZeroFilledPlotSegments.last?.last, point(7, 30))
        for history in histories {
            XCTAssertEqual(history.directZeroFilledPlotSegments, history.zeroFilledPlotSegments)
        }
        for history in histories.dropFirst() {
            XCTAssertNil(history.current)
            XCTAssertEqual(
                history.directZeroFilledPlotSegments.last?.suffix(3).map(\.value), [30, 0, 0])
        }
    }

    func testMalformedEmittedGeometryFailsClosed() {
        let malformed: [[[ToolActivityBucket]]] = [
            [[bucket(-3, -1, 4)]],  // Clipped start lies after its out-of-window end.
            [[bucket(9, 11, 4)]],
            [[bucket(0, .infinity, 4)]],
            [[bucket(0, 1, -1)]],
            [[bucket(0, 1, .nan)]],
            [[bucket(0, 1, .infinity)]],
            [[bucket(0, 1, -.infinity)]],
            [[bucket(2, 3, 4), bucket(1, 2, 5)]],  // Reversed emitted points.
            [[bucket(0, 4, 4), bucket(3, 5, 5)]],  // Overlap within one segment.
            [[bucket(0, 4, 4)], [bucket(3, 5, 5)]],  // Overlap across segments.
        ]
        for segments in malformed {
            for current in [false, true] {
                XCTAssertTrue(reference(segments, cutoff: 0, now: 10, current: current).isEmpty)
                XCTAssertTrue(direct(segments, cutoff: 0, now: 10, current: current).isEmpty)
            }
        }
        for (cutoff, now) in [
            (0.0, 0.0), (2, 1), (.nan, 10), (0, .nan),
            (-.infinity, 10), (0, .infinity), (0, -.infinity),
        ] {
            XCTAssertTrue(direct([], cutoff: cutoff, now: now, current: false).isEmpty)
            assertEquivalent([], cutoff: cutoff, now: now, current: false)
        }
    }

    func testInvalidHistoryWindowsAndGapPoliciesRemainEmpty() {
        for duration in [0.0, -1, .nan, .infinity] {
            let history = ToolActivityHistory(
                events: [call(0)], observations: [observation(0)], now: date(0), duration: duration)
            XCTAssertTrue(history.directZeroFilledPlotSegments.isEmpty)
            XCTAssertEqual(history.directZeroFilledPlotSegments, history.zeroFilledPlotSegments)
        }
        for maximumGap in [-1.0, .nan, .infinity] {
            let history = ToolActivityHistory(
                events: [], observations: [observation(0)], now: date(0), duration: 60,
                maximumGap: maximumGap)
            XCTAssertTrue(history.directZeroFilledPlotSegments.isEmpty)
            XCTAssertEqual(history.directZeroFilledPlotSegments, history.zeroFilledPlotSegments)
        }
    }

    func testDeterministicVariedHistoriesAndArchivesMatchExactReferencePoints() {
        var sawCurrent = false
        var sawExpired = false
        var sawMultipleSegments = false
        var sawPending = false
        for seed in 0..<12 {
            var observations = (0...80).map { index in
                TimeSeriesPoint(
                    timestamp: date(Double(index) / 2),
                    value: (index + seed) % 17 == 0 ? .nan : 0,
                    isAvailable: (index + seed * 3) % 13 != 0)
            }
            observations += stride(from: 0, through: 80, by: 11).map { index in
                observation(Double(index) / 2, available: (index + seed) % 2 == 0)
            }
            if seed.isMultiple(of: 2) { observations.reverse() }
            var events = (0..<18).map { index in
                ToolActivityEvent(
                    id: identity(seed * 100 + index),
                    kind: index.isMultiple(of: 5) ? .resultSubmission : .call,
                    name: "tool-\(index % 3)",
                    timestamp: date(Double((index * 13 + seed) % 85) / 2 - 2))
            }
            events.append(events[3])
            events.reverse()
            let archive: [[ArchivedChartBucket]] =
                seed.isMultiple(of: 3)
                ? []
                : [
                    [ArchivedChartBucket(start: date(-120), end: date(-100), value: 0, count: 41)],
                    [ArchivedChartBucket(start: date(-90), end: date(-70), value: 0, count: 41)],
                ]
            for duration in [4.0, 60, 72.25, 300, 3_600] {
                for now in [36.0, 43.25] {
                    let history = ToolActivityHistory(
                        events: events, observations: observations, now: date(now),
                        duration: duration, archivedSegments: archive)
                    XCTAssertEqual(
                        history.directZeroFilledPlotSegments, history.zeroFilledPlotSegments,
                        "seed=\(seed), duration=\(duration), now=\(now)")
                    sawCurrent = sawCurrent || history.current != nil
                    sawExpired = sawExpired || history.current == nil
                    sawMultipleSegments = sawMultipleSegments || history.segments.count > 1
                    sawPending =
                        sawPending
                        || history.buckets.contains {
                            $0.observedDuration == 0 && $0.callCount > 0
                        }
                }
            }
        }
        XCTAssertTrue(sawCurrent)
        XCTAssertTrue(sawExpired)
        XCTAssertTrue(sawMultipleSegments)
        XCTAssertTrue(sawPending)
    }

    private func direct(
        _ segments: [[ToolActivityBucket]], cutoff: Double, now: Double, current: Bool
    ) -> [[ChartDisplayPoint]] {
        var offset = 0
        let ranges = segments.map { segment in
            let start = offset
            offset += segment.count
            return start..<offset
        }
        return ToolActivityHistory.directZeroFilledPlotSegments(
            buckets: segments.flatMap { $0 }, segmentRanges: ranges,
            cutoff: date(cutoff), now: date(now), extendsCurrentToNow: current)
    }

    /// Apply the unchanged two-stage reference to supplied prepared buckets.
    private func reference(
        _ segments: [[ToolActivityBucket]], cutoff: Double, now: Double, current: Bool
    ) -> [[ChartDisplayPoint]] {
        let paths: [[ChartDisplayPoint]] = segments.compactMap { segment in
            var points: [ChartDisplayPoint] = []
            for bucket in segment where bucket.observedDuration > 0 {
                let start = ChartDisplayPoint(
                    timestamp: max(bucket.start, date(cutoff)), value: bucket.callsPerMinute)
                if points.last != start { points.append(start) }
                let end = ChartDisplayPoint(timestamp: bucket.end, value: bucket.callsPerMinute)
                if points.last != end { points.append(end) }
            }
            return points.isEmpty ? nil : points
        }
        return ChartGapFilling.plotSegments(
            paths, cutoff: date(cutoff), now: date(now), extendsCurrentToNow: current)
    }

    private func assertEquivalent(
        _ segments: [[ToolActivityBucket]], cutoff: Double, now: Double, current: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            direct(segments, cutoff: cutoff, now: now, current: current),
            reference(segments, cutoff: cutoff, now: now, current: current), file: file, line: line)
    }

    private func bucket(_ start: Double, _ end: Double, _ rate: Double) -> ToolActivityBucket {
        ToolActivityBucket(
            start: date(start), end: date(end), callCount: 0, callsPerMinute: rate, toolNames: [])
    }
    private func point(_ offset: Double, _ value: Double) -> ChartDisplayPoint {
        ChartDisplayPoint(timestamp: date(offset), value: value)
    }
    private func observation(_ offset: Double, available: Bool = true) -> TimeSeriesPoint {
        TimeSeriesPoint(timestamp: date(offset), value: 0, isAvailable: available)
    }
    private func call(_ offset: Double) -> ToolActivityEvent {
        ToolActivityEvent(kind: .call, timestamp: date(offset))
    }
    private func identity(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
    private func date(_ offset: Double) -> Date { origin.addingTimeInterval(offset) }
}
