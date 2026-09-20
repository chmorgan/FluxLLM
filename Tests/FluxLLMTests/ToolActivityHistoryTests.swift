import Foundation
import XCTest

@testable import FluxLLM

final class ToolActivityHistoryTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testCountsUseWholeObservedBinsAcrossSamplingEdges() {
        let events = [call(0.25), call(2.75), call(3), call(5.75)]
        let history = ToolActivityHistory(
            events: events, observations: samples(0, through: 6.5),
            now: date(6.5), duration: 60)

        XCTAssertEqual(history.interval, 3)
        XCTAssertEqual(history.buckets.map(\.start), [date(0), date(3), date(6)])
        XCTAssertEqual(history.buckets.map(\.end), [date(3), date(6), date(6.5)])
        XCTAssertEqual(history.buckets.map(\.observedDuration), [3, 3, 0.5])
        XCTAssertEqual(history.buckets.map(\.callCount), [2, 2, 0])
        XCTAssertEqual(history.buckets.map(\.callsPerMinute), [40, 40, 0])
        XCTAssertEqual(history.buckets.reduce(0) { $0 + $1.callCount }, events.count)
        XCTAssertEqual(history.peak, 40)
        XCTAssertEqual(history.current?.callsPerMinute, 0)
        XCTAssertEqual(history.bucket(at: date(2.9)), history.buckets[0])
        XCTAssertEqual(history.bucket(at: date(3)), history.buckets[1])
    }

    func testStepPlotUsesBinBoundariesRatherThanInterpolatingCounts() {
        let history = ToolActivityHistory(
            events: [call(1), call(3), call(4)], observations: samples(0, through: 6.5),
            now: date(6.5), duration: 60)

        XCTAssertEqual(
            history.plotSegments,
            [
                [
                    ChartDisplayPoint(timestamp: date(0), value: 20),
                    ChartDisplayPoint(timestamp: date(3), value: 20),
                    ChartDisplayPoint(timestamp: date(3), value: 40),
                    ChartDisplayPoint(timestamp: date(6), value: 40),
                    ChartDisplayPoint(timestamp: date(6), value: 0),
                    ChartDisplayPoint(timestamp: date(6.5), value: 0),
                ]
            ])
    }

    func testLongerWindowsRecountEventsWithoutAveragingShortBinRates() {
        for (duration, interval) in [(300.0, 5.0), (900, 15), (3_600, 60)] {
            let history = ToolActivityHistory(
                events: [call(1), call(interval - 0.1), call(interval + 0.5)],
                observations: samples(0, through: interval + 1),
                now: date(interval + 1), duration: duration)

            XCTAssertEqual(history.interval, interval)
            XCTAssertEqual(history.buckets.map(\.observedDuration), [interval, 1])
            XCTAssertEqual(history.buckets.map(\.callCount), [2, 1])
            XCTAssertEqual(history.buckets[0].callsPerMinute, 120 / interval)
            XCTAssertEqual(history.buckets[1].callsPerMinute, 60)
        }
    }

    func testHealthyIdleIsZeroButUnavailableIntervalsStayDisconnected() {
        let history = ToolActivityHistory(
            events: [call(0.25), call(2.75)],
            observations: [
                point(0), point(0.5), point(1, available: false),
                point(2), point(2.5), point(3), point(3.5),
            ], now: date(3.5), duration: 60)

        XCTAssertEqual(history.segments.count, 2)
        XCTAssertEqual(history.segments[0].map(\.callsPerMinute), [120])
        XCTAssertEqual(history.segments[1].map(\.callsPerMinute), [60, 0])
        XCTAssertEqual(history.plotSegments.first?.first?.timestamp, date(0))
        XCTAssertEqual(history.plotSegments.first?.last?.timestamp, date(0.5))
        XCTAssertEqual(history.plotSegments.last?.first?.timestamp, date(2))
        XCTAssertNil(history.bucket(at: date(0.75)))
        XCTAssertNil(history.bucket(at: date(1)))
        XCTAssertNil(history.bucket(at: date(1.75)))
        XCTAssertEqual(history.current?.callsPerMinute, 0)
    }

    func testEventsInsideSamplingGapCannotReconnectItOrCreateAFalseZeroRate() {
        let history = ToolActivityHistory(
            events: [call(4), call(7)],
            observations: [point(0), point(1), point(10), point(11)],
            now: date(11), duration: 3_600)

        XCTAssertEqual(history.buckets.reduce(0) { $0 + $1.callCount }, 2)
        XCTAssertEqual(history.buckets.filter { $0.callCount > 0 }.map(\.observedDuration), [0, 0])
        XCTAssertEqual(
            history.plotSegments.map { $0.map(\.timestamp) },
            [[date(0), date(1)], [date(10), date(11)]])
        XCTAssertNil(history.bucket(at: date(5)))
        XCTAssertEqual(history.bucket(at: date(4))?.callCount, 1)
        XCTAssertEqual(history.peak, 0)
    }

    func testBoundaryAndTerminalCallsRemainPendingUntilTimeIsObserved() {
        let events = [call(3)]
        let atBoundary = ToolActivityHistory(
            events: events, observations: samples(0, through: 3), now: date(3), duration: 60)
        let afterNextSample = ToolActivityHistory(
            events: events, observations: samples(0, through: 3.5),
            now: date(3.5), duration: 60)

        XCTAssertEqual(atBoundary.buckets.map(\.callCount), [0, 1])
        XCTAssertEqual(atBoundary.buckets.last?.observedDuration, 0)
        XCTAssertTrue(atBoundary.buckets.allSatisfy { $0.callsPerMinute.isFinite })
        XCTAssertNil(atBoundary.current)
        XCTAssertEqual(atBoundary.peak, 0)
        XCTAssertEqual(atBoundary.plotSegments.last?.last?.value, 0)
        XCTAssertEqual(afterNextSample.buckets.map(\.callCount), [0, 1])
        XCTAssertEqual(afterNextSample.current?.callsPerMinute, 120)

        let terminal = ToolActivityHistory(
            events: [call(3.25)], observations: samples(0, through: 3),
            now: date(3.25), duration: 60)
        XCTAssertEqual(terminal.buckets.reduce(0) { $0 + $1.callCount }, 1)
        XCTAssertEqual(terminal.bucket(at: date(3.25))?.observedDuration, 0)
        XCTAssertNil(terminal.current)
        XCTAssertEqual(terminal.plotSegments.last?.last?.timestamp, date(3))
    }

    func testEmptyBoundaryBucketKeepsTheLastMeasuredCurrentRate() {
        let history = ToolActivityHistory(
            events: [call(1)], observations: samples(0, through: 3),
            now: date(3), duration: 60)

        XCTAssertEqual(history.buckets.last?.observedDuration, 0)
        XCTAssertEqual(history.buckets.last?.callCount, 0)
        XCTAssertEqual(history.current, history.buckets.first)
        XCTAssertEqual(history.current?.callsPerMinute, 20)
    }

    func testStartupRetainsPartialSpanAndDoesNotInventExposureBeforeFirstSample() {
        let event = call(1)
        let pending = ToolActivityHistory(
            events: [event], observations: [], now: date(1), duration: 60)
        XCTAssertEqual(pending.buckets.first?.callCount, 1)
        XCTAssertEqual(pending.buckets.first?.observedDuration, 0)
        XCTAssertTrue(pending.plotSegments.isEmpty)
        XCTAssertNil(pending.peak)
        XCTAssertNil(pending.current)

        let observed = ToolActivityHistory(
            events: [event], observations: [point(1), point(1.5), point(2)],
            now: date(2), duration: 60)
        XCTAssertEqual(observed.current?.start, date(1))
        XCTAssertEqual(observed.current?.observedDuration, 1)
        XCTAssertEqual(observed.current?.callsPerMinute, 60)
        XCTAssertNil(observed.bucket(at: date(0.5)))
    }

    func testPartialLatestBinDoesNotChangeCompletedRateWhenItGrows() {
        let events = [call(1), call(3.25)]
        let initial = ToolActivityHistory(
            events: events, observations: samples(0, through: 3.5),
            now: date(3.5), duration: 60)
        let updated = ToolActivityHistory(
            events: events, observations: samples(0, through: 5.5),
            now: date(5.5), duration: 60)

        XCTAssertEqual(initial.buckets.first, updated.buckets.first)
        XCTAssertEqual(initial.current?.callsPerMinute, 120)
        XCTAssertEqual(updated.current?.callsPerMinute, 24)
        XCTAssertEqual(updated.current?.callCount, 1)
    }

    func testClippingPreservesCompletedCountsAndRatesButBoundsPlotAndHover() {
        let events = [call(0.5), call(2)]
        let observations = samples(0, through: 6)
        let initial = ToolActivityHistory(
            events: events, observations: observations, now: date(60), duration: 60)
        let clipped = ToolActivityHistory(
            events: events, observations: observations, now: date(61), duration: 60)

        XCTAssertEqual(initial.buckets.first, clipped.buckets.first)
        XCTAssertEqual(clipped.buckets.first?.observedDuration, 3)
        XCTAssertEqual(clipped.buckets.first?.callCount, 2)
        XCTAssertEqual(clipped.buckets.first?.callsPerMinute, 40)
        XCTAssertEqual(clipped.plotSegments.first?.first?.timestamp, date(1))
        XCTAssertNil(clipped.bucket(at: date(0.9)))
        XCTAssertEqual(clipped.bucket(at: date(1))?.callCount, 2)
    }

    func testRetentionOmitsIncompleteLeadingBinWithoutChangingFollowingBin() {
        let events = [call(1), call(3.5)]
        let initial = ToolActivityHistory(
            events: events, observations: samples(0, through: 7), now: date(60), duration: 60)
        let retained = ToolActivityHistory(
            events: events, observations: samples(0.5, through: 7),
            now: date(60.5), duration: 60)

        XCTAssertEqual(retained.buckets.first, initial.buckets[1])
        XCTAssertEqual(retained.buckets.first?.start, date(3))
        XCTAssertNil(retained.bucket(at: date(0.5)))
        XCTAssertEqual(retained.plotSegments.first?.first?.timestamp, date(3))
    }

    func testResultMarkersUseExactTimesAndDoNotCountAsCalls() {
        let result = ToolActivityEvent(kind: .resultSubmission, timestamp: date(2.2))
        let beforeViewport = ToolActivityEvent(kind: .resultSubmission, timestamp: date(-61))
        let future = ToolActivityEvent(kind: .resultSubmission, timestamp: date(10))
        let history = ToolActivityHistory(
            events: [result, beforeViewport, future], observations: samples(0, through: 3.5),
            now: date(3.5), duration: 60)

        XCTAssertEqual(history.resultMarkers, [result])
        XCTAssertTrue(history.buckets.allSatisfy { $0.callCount == 0 })
        XCTAssertEqual(history.current?.callsPerMinute, 0)
    }

    func testEventDeduplicationUsesEventIdentityAndRetainsIndependentRepeatedTools() {
        let first = call(1, name: "read_file", callID: "same-id")
        let second = call(1.5, name: "read_file", callID: "same-id")
        let third = call(2, name: "search")
        let events = [third, first, first, second]
        let original = events
        let history = ToolActivityHistory(
            events: events, observations: samples(0, through: 3.5),
            now: date(3.5), duration: 60)

        XCTAssertEqual(history.buckets.first?.callCount, 3)
        XCTAssertEqual(history.buckets.first?.toolNames, ["read_file", "search"])
        XCTAssertEqual(history.buckets.first?.callsPerMinute, 60)
        XCTAssertEqual(events, original)
    }

    func testFutureObservationsAndCallsAreExcludedAndLatestDuplicateObservationWins() {
        let history = ToolActivityHistory(
            events: [call(1), call(100)],
            observations: [point(2), point(0), point(100), point(1), point(2, available: false)],
            now: date(2), duration: 60)

        XCTAssertEqual(history.buckets.first?.callCount, 1)
        XCTAssertEqual(history.buckets.first?.observedDuration, 1)
        XCTAssertEqual(history.buckets.first?.callsPerMinute, 60)
        XCTAssertNil(history.current)
        XCTAssertNil(history.bucket(at: date(2)))
        XCTAssertNil(history.bucket(at: date(100)))
    }

    func testUnavailableAndInvalidObservationsBreakCoverageAndHideCurrent() {
        for invalid in [-1.0, .nan, .infinity, -.infinity] {
            let history = ToolActivityHistory(
                events: [call(0.25)],
                observations: [
                    point(0), point(0.5), TimeSeriesPoint(timestamp: date(1), value: invalid),
                ], now: date(1), duration: 60)

            XCTAssertEqual(history.buckets.first?.observedDuration, 0.5)
            XCTAssertEqual(history.peak, 120)
            XCTAssertNil(history.current)
            XCTAssertNil(history.bucket(at: date(0.75)))
        }
    }

    func testCurrentExpiresWithUnderlyingObservationRatherThanBucketSize() {
        let observations = samples(0, through: 2)
        let fresh = ToolActivityHistory(
            events: [call(1)], observations: observations, now: date(7), duration: 3_600)
        let stale = ToolActivityHistory(
            events: [call(1)], observations: observations, now: date(7.001), duration: 3_600)

        XCTAssertEqual(fresh.current?.callsPerMinute, 30)
        XCTAssertNil(stale.current)
        XCTAssertEqual(fresh.buckets, stale.buckets)
    }

    func testInvalidWindowAndGapPolicyProduceNoDisplayData() {
        for duration in [0.0, -1, .nan, .infinity] {
            let history = ToolActivityHistory(
                events: [call(0)], observations: [point(0)], now: date(0), duration: duration)
            XCTAssertTrue(history.buckets.isEmpty)
            XCTAssertTrue(history.plotSegments.isEmpty)
            XCTAssertTrue(history.zeroFilledPlotSegments.isEmpty)
            XCTAssertTrue(history.resultMarkers.isEmpty)
            XCTAssertNil(history.current)
            XCTAssertNil(history.peak)
        }
        for maximumGap in [-1.0, .nan, .infinity] {
            let history = ToolActivityHistory(
                events: [], observations: [point(0)], now: date(0), duration: 60,
                maximumGap: maximumGap)
            XCTAssertTrue(history.segments.isEmpty)
            XCTAssertTrue(history.zeroFilledPlotSegments.isEmpty)
        }
    }

    func testZeroFilledEmptyAndPendingWindowsDoNotInventExposure() {
        for events in [[], [call(1)]] {
            let history = ToolActivityHistory(
                events: events, observations: [], now: date(60), duration: 60)

            XCTAssertEqual(
                history.zeroFilledPlotSegments,
                [
                    [
                        ChartDisplayPoint(timestamp: date(0), value: 0),
                        ChartDisplayPoint(timestamp: date(60), value: 0),
                    ]
                ])
            XCTAssertEqual(history.buckets.reduce(0) { $0 + $1.callCount }, events.count)
            XCTAssertTrue(history.buckets.allSatisfy { $0.observedDuration == 0 })
            XCTAssertTrue(history.plotSegments.isEmpty)
            XCTAssertNil(history.peak)
            XCTAssertNil(history.current)
            XCTAssertNil(history.bucket(at: date(30)))
        }
    }

    func testZeroFilledGapsPreserveExactCountsRatesAndStepTransitions() {
        let history = ToolActivityHistory(
            events: [call(0.25), call(2.75), call(3), call(3.25)],
            observations: [
                point(0), point(0.5), point(1, available: false),
                point(2), point(2.5), point(3), point(3.5),
            ], now: date(4), duration: 4)

        XCTAssertEqual(
            history.zeroFilledPlotSegments,
            [
                [
                    ChartDisplayPoint(timestamp: date(0), value: 0),
                    ChartDisplayPoint(timestamp: date(0), value: 120),
                    ChartDisplayPoint(timestamp: date(0.5), value: 120),
                    ChartDisplayPoint(timestamp: date(0.5), value: 0),
                    ChartDisplayPoint(timestamp: date(2), value: 0),
                    ChartDisplayPoint(timestamp: date(2), value: 60),
                    ChartDisplayPoint(timestamp: date(3), value: 60),
                    ChartDisplayPoint(timestamp: date(3), value: 240),
                    ChartDisplayPoint(timestamp: date(3.5), value: 240),
                    ChartDisplayPoint(timestamp: date(4), value: 240),
                ]
            ])
        XCTAssertEqual(history.buckets.map(\.callCount), [1, 1, 2])
        XCTAssertEqual(history.buckets.map(\.observedDuration), [0.5, 1, 0.5])
        XCTAssertEqual(history.buckets.map(\.callsPerMinute), [120, 60, 240])
        XCTAssertEqual(history.segments.count, 2)
        XCTAssertEqual(history.peak, 240)
        XCTAssertEqual(history.current?.callsPerMinute, 240)
        XCTAssertNil(history.bucket(at: date(1)))
        XCTAssertNil(history.bucket(at: date(3.75)))
    }

    func testZeroFilledFreshTailExtendsWithoutAddingToTheRateDenominator() {
        let events = [call(1)]
        let observations = samples(0, through: 2)
        let fresh = ToolActivityHistory(
            events: events, observations: observations, now: date(7), duration: 60)
        let stale = ToolActivityHistory(
            events: events, observations: observations, now: date(7.5), duration: 60)
        let unavailable = ToolActivityHistory(
            events: events, observations: observations + [point(2.5, available: false)],
            now: date(3), duration: 60)

        XCTAssertEqual(fresh.zeroFilledPlotSegments.last?.last?.value, 30)
        XCTAssertEqual(fresh.zeroFilledPlotSegments.last?.last?.timestamp, date(7))
        XCTAssertEqual(fresh.current?.observedDuration, 2)
        for history in [stale, unavailable] {
            XCTAssertEqual(history.buckets, fresh.buckets)
            XCTAssertEqual(history.plotSegments, fresh.plotSegments)
            XCTAssertEqual(history.zeroFilledPlotSegments.last?.suffix(3).map(\.value), [30, 0, 0])
            XCTAssertEqual(history.zeroFilledPlotSegments.last?.suffix(3).first?.timestamp, date(2))
            XCTAssertNil(history.current)
        }
        XCTAssertEqual(stale.zeroFilledPlotSegments.last?.last?.timestamp, date(7.5))
        XCTAssertEqual(unavailable.zeroFilledPlotSegments.last?.last?.timestamp, date(3))
    }

    func testZeroFilledPendingTailReturnsToZeroWithoutPlottingAnUnmeasuredRate() {
        let history = ToolActivityHistory(
            events: [call(0.5), call(2.5)], observations: samples(0, through: 2),
            now: date(3), duration: 60)

        XCTAssertEqual(history.buckets.map(\.callCount), [1, 1])
        XCTAssertEqual(history.buckets.map(\.observedDuration), [2, 0])
        XCTAssertEqual(history.peak, 30)
        XCTAssertNil(history.current)
        XCTAssertEqual(history.zeroFilledPlotSegments.last?.suffix(3).map(\.value), [30, 0, 0])
        XCTAssertEqual(history.zeroFilledPlotSegments.last?.last?.timestamp, date(3))
        XCTAssertEqual(history.bucket(at: date(2.5))?.callCount, 1)
    }

    func testZeroFilledInvalidNowProducesNoGeometry() {
        for offset in [Double.nan, .infinity, -.infinity] {
            let history = ToolActivityHistory(
                events: [], observations: [], now: Date(timeIntervalSince1970: offset), duration: 60
            )
            XCTAssertTrue(history.zeroFilledPlotSegments.isEmpty)
        }
    }

    func testArchivedObservationSpansRetainExactExposureAndCallCounts() {
        let history = ToolActivityHistory(
            events: [call(1), call(61)], observations: [], now: date(62), duration: 7_200,
            archivedSegments: [
                [
                    ArchivedChartBucket(start: date(0), end: date(59), value: 0, count: 119),
                    ArchivedChartBucket(start: date(60), end: date(62), value: 0, count: 5),
                ]
            ])

        XCTAssertEqual(history.interval, 120)
        XCTAssertEqual(history.buckets.count, 1)
        XCTAssertEqual(history.buckets.first?.callCount, 2)
        XCTAssertEqual(history.buckets.first?.observedDuration, 62)
        XCTAssertEqual(history.buckets.first?.callsPerMinute ?? 0, 120.0 / 62, accuracy: 0.000_001)
        XCTAssertNil(history.current)
    }

    func testArchivedObservationGapsKeepCallsPendingWithoutInventingExposure() {
        let history = ToolActivityHistory(
            events: [call(1), call(15), call(21)], observations: [],
            now: date(31), duration: 3_600,
            archivedSegments: [
                [ArchivedChartBucket(start: date(0), end: date(10), value: 0, count: 21)],
                [ArchivedChartBucket(start: date(20), end: date(30), value: 0, count: 21)],
            ])

        XCTAssertEqual(history.buckets.reduce(0) { $0 + $1.callCount }, 3)
        XCTAssertEqual(history.buckets.map(\.observedDuration), [10, 0, 10])
        XCTAssertEqual(history.buckets.map(\.callsPerMinute), [6, 0, 6])
        XCTAssertNil(history.bucket(at: date(12)))
        XCTAssertEqual(history.bucket(at: date(15))?.observedDuration, 0)
        XCTAssertNil(history.current)
    }

    func testArchivedCoverageDoesNotDuplicateRecentRawSamplesOrTheirCalls() {
        let history = ToolActivityHistory(
            events: [call(1), call(61)], observations: samples(60, through: 62),
            now: date(62), duration: 3_600,
            archivedSegments: [
                [
                    ArchivedChartBucket(start: date(0), end: date(59), value: 0, count: 119),
                    ArchivedChartBucket(start: date(60), end: date(62), value: 0, count: 5),
                ]
            ])

        XCTAssertEqual(history.buckets.reduce(0) { $0 + $1.callCount }, 2)
        XCTAssertEqual(history.buckets.map(\.observedDuration), [59, 2])
        XCTAssertEqual(history.current?.callsPerMinute, 30)
    }

    private func samples(_ start: Double, through end: Double) -> [TimeSeriesPoint] {
        stride(from: start, through: end, by: 0.5).map { point($0) }
    }

    private func point(_ offset: TimeInterval, available: Bool = true) -> TimeSeriesPoint {
        TimeSeriesPoint(timestamp: date(offset), value: 0, isAvailable: available)
    }

    private func call(_ offset: TimeInterval, name: String? = nil, callID: String? = nil)
        -> ToolActivityEvent
    {
        ToolActivityEvent(kind: .call, name: name, callID: callID, timestamp: date(offset))
    }

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }
}
