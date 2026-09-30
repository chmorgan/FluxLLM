import Foundation
import XCTest

@testable import FluxLLM

final class ChartPreparationEquivalenceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testPrunedHistoriesMatchFullHistoryReferenceAcrossEveryRangeAndFrozenEndpoint() {
        let observations = (0...7_200).map { index in
            point(Double(index) / 2, Double(index % 113), available: index % 131 != 0)
        }
        let archive = [
            [archived(-360, -301, 11, 119), archived(-300, -241, 17, 120)],
            [archived(-180, -121, 23, 120), archived(-120, -61, 31, 120)],
        ]
        let events = stride(from: -350, through: 3_610, by: 7).enumerated().map { index, offset in
            ToolActivityEvent(
                kind: index.isMultiple(of: 3) ? .resultSubmission : .call,
                name: "tool-\(index % 5)", timestamp: date(Double(offset)))
        }
        for duration in [60.0, 300, 900, 1_800, 3_600, 21_600, 86_400, 75.25, 302.3] {
            for end in [3_600.0, 3_591.5, 90.25, -60.0] {
                assertEquivalent(
                    observations: observations, events: events, now: end,
                    duration: duration, archive: archive)
            }
        }
    }

    func testClippingPreservesSparseCoverageOnBothSidesOfItsBoundary() throws {
        let observations = [point(1, 10), point(4, 40)]
        let events = [call(3.75)]
        assertEquivalent(observations: observations, events: events, now: 63.5, duration: 60)
        let chart = ChartDisplayHistory(samples: observations, now: date(63.5), duration: 60)
        XCTAssertEqual(chart.bucket(at: date(3.5))?.value, 40)
        let tools = ToolActivityHistory(
            events: events, observations: observations, now: date(63.5), duration: 60)
        XCTAssertEqual(tools.buckets.first?.start, date(3))
        XCTAssertEqual(tools.buckets.first?.end, date(4))
        XCTAssertEqual(tools.buckets.first?.callsPerMinute, 60)

        let gap = [point(1, 10), point(2.9, 0, available: false), point(4, 40)]
        assertEquivalent(observations: gap, events: events, now: 63.5, duration: 60)
        let broken = ChartDisplayHistory(samples: gap, now: date(63.5), duration: 60)
        XCTAssertNil(broken.bucket(at: date(3.5)))
        let pending = ToolActivityHistory(
            events: events, observations: gap, now: date(63.5), duration: 60)
        let evidence = try XCTUnwrap(pending.buckets.first { $0.callCount == 1 })
        XCTAssertEqual(evidence.observedDuration, 0)
        XCTAssertEqual(evidence.start, date(3.75))
    }

    func testClippingPreservesActualRetentionBoundaryInsteadOfInventingOne() {
        let observations = [
            point(0, 0), point(1, 10), point(2, 20), point(3.5, 30),
            point(4.5, 40), point(5.5, 50), point(6.5, 60),
        ]
        assertEquivalent(observations: observations, events: [call(3.75)], now: 64, duration: 60)
        let chart = ChartDisplayHistory(samples: observations, now: date(64), duration: 60)
        XCTAssertEqual(chart.buckets.first?.start, date(3.5))
        XCTAssertEqual(chart.buckets.first?.count, 3)
        XCTAssertEqual(chart.buckets.first?.value, 40)

        let retained = (1...14).map { point(Double($0) / 2, 0) }
        let events = [call(1), call(3.5)]
        assertEquivalent(observations: retained, events: events, now: 60.5, duration: 60)
        let tools = ToolActivityHistory(
            events: events, observations: retained, now: date(60.5), duration: 60)
        XCTAssertEqual(tools.buckets.first?.start, date(3))
        XCTAssertEqual(tools.buckets.first?.callCount, 1)
        XCTAssertEqual(tools.buckets.first?.callsPerMinute, 20)
    }

    func testArchivedBinKeepsItsContributorsBeforeTheViewportBoundary() {
        let archive = [
            [
                archived(0, 59, 0, 120), archived(60, 119, 10, 120), archived(120, 179, 30, 120),
            ]
        ]
        let events = [call(1), call(61), call(120)]
        assertEquivalent(
            observations: [], events: events, now: 7_261, duration: 7_200, archive: archive)
        let chart = ChartDisplayHistory(
            samples: [], now: date(7_261), duration: 7_200, archivedSegments: archive)
        XCTAssertEqual(chart.interval, 120)
        XCTAssertEqual(chart.buckets.first?.count, 240)
        XCTAssertEqual(chart.buckets.first?.value, 5)
        XCTAssertEqual(chart.bucket(at: date(61))?.value, 5)
        let tools = ToolActivityHistory(
            events: events, observations: [], now: date(7_261), duration: 7_200,
            archivedSegments: archive)
        XCTAssertEqual(tools.buckets.first?.start, date(0))
        XCTAssertEqual(tools.buckets.first?.end, date(120))
        XCTAssertEqual(tools.buckets.first?.callCount, 2)
        XCTAssertEqual(tools.buckets.first?.callsPerMinute, 1)
    }

    func testFrozenArchiveAndRawOverlapKeepOriginalResolutionRules() {
        let archive = [[archived(0, 59, 10, 120), archived(60, 119, 30, 120)]]
        assertEquivalent(
            observations: [point(120, 50)], events: [call(40), call(70), call(120)],
            now: 90, duration: 60, archive: archive)
        let frozen = ChartDisplayHistory(
            samples: [point(120, 50)], now: date(90), duration: 60, archivedSegments: archive)
        XCTAssertEqual(frozen.interval, 60)
        XCTAssertEqual(frozen.buckets.map(\.end), [date(59)])
        XCTAssertNil(frozen.current)

        let observations = (0...120).map { point(Double($0), 20) }
        assertEquivalent(
            observations: observations, events: [call(61)], now: 120, duration: 60,
            archive: archive)
        let overlapping = ChartDisplayHistory(
            samples: observations, now: date(120), duration: 60, archivedSegments: archive)
        XCTAssertEqual(overlapping.interval, 60)
        XCTAssertTrue(overlapping.buckets.allSatisfy { $0.value == 20 })
    }

    func testUnorderedDuplicatesAndInvalidSamplesKeepReplacementAndGapRules() {
        let observations = [
            point(8, 80), point(3, 30), point(1, 10), point(2.5, 20),
            point(4, 40), point(3, 0, available: false), point(5, .nan),
            point(6, -1), point(7, 70), point(9, 90), point(4, 44),
        ]
        let repeated = call(3.25)
        let events = [call(8.5), repeated, call(2.75), repeated, call(6.5)]
        for end in [8.0, 9, 63, 63.25, 64.0] {
            assertEquivalent(observations: observations, events: events, now: end, duration: 60)
        }
    }

    func testFreshnessRemainsIndependentFromCoverageGapPolicy() {
        let observations = [point(0, 10), point(1, 30)]
        assertEquivalent(
            observations: observations, events: [call(0.5)], now: 3, duration: 60,
            maximumGap: 1)
        let chart = ChartDisplayHistory(
            samples: observations, now: date(3), duration: 60, maximumGap: 1)
        let tools = ToolActivityHistory(
            events: [], observations: observations, now: date(3), duration: 60, maximumGap: 1)
        XCTAssertEqual(chart.current?.value, 20)
        XCTAssertNil(tools.current)
    }

    func testSharedCoverageMatchesIndependentFullHistoryForEveryRequestOverlay() {
        let snapshot = ChartPerformanceFixture.publications(
            retainedSeconds: 3_600, laneCount: 33, count: 1)[0]
        let prepared = DashboardChartPreparation().histories(snapshot: snapshot, duration: 60)
        for lane in snapshot.requestLanes {
            let reference = ReferenceToolActivityHistory(
                events: snapshot.toolActivity.filter { $0.requestID == lane.id },
                observations: snapshot.toolObservation, now: snapshot.timestamp, duration: 60)
            XCTAssertEqual(prepared.requestTools[lane.id]?.segments, reference.segments)
            XCTAssertEqual(prepared.requestTools[lane.id]?.resultMarkers, reference.resultMarkers)
            XCTAssertEqual(prepared.requestTools[lane.id]?.current, reference.current)
        }
    }

    func testFrozenRequestKeepsItsEmptyOverlayBeforeItsFirstEvent() {
        let lane = RequestLane(id: UUID(), startedAt: date(1))
        let event = ToolActivityEvent(kind: .call, timestamp: date(50), requestID: lane.id)
        let snapshot = ChartPresentationSnapshot(
            timestamp: date(60), toolActivity: [event], requestLanes: [lane],
            toolObservation: (0...60).map { point(Double($0), 0) }, supportsToolActivity: true)
        let prepared = DashboardChartPreparation().histories(
            snapshot: snapshot, duration: 60, windowEnd: date(30))
        XCTAssertNotNil(prepared.requestTools[lane.id])
        XCTAssertTrue(
            prepared.requestTools[lane.id]?.buckets.allSatisfy { $0.callCount == 0 } == true)
    }

    func testHiddenChartReleaseDropsPreparedArraysAndRetainsRequestIdentity() {
        let lane = RequestLane(id: UUID(), startedAt: origin)
        let snapshot = ChartPresentationSnapshot(timestamp: date(1), requestLanes: [lane])
        let preparation = DashboardChartPreparation()
        var prepared: PreparedDashboardCharts? = preparation.histories(
            snapshot: snapshot, duration: 60)
        let assignments = prepared?.requestRails.assignments
        weak var retained = prepared
        prepared = nil
        XCTAssertNotNil(retained)
        preparation.releasePreparedCharts()
        XCTAssertNil(retained)
        let restored = preparation.histories(snapshot: snapshot, duration: 60)
        XCTAssertEqual(restored.requestRails.assignments, assignments)
    }

    private func assertEquivalent(
        observations: [TimeSeriesPoint], events: [ToolActivityEvent], now: Double,
        duration: TimeInterval, maximumGap: TimeInterval = 5,
        archive: [[ArchivedChartBucket]] = [], file: StaticString = #filePath, line: UInt = #line
    ) {
        let chart = ChartDisplayHistory(
            samples: observations, now: date(now), duration: duration,
            maximumGap: maximumGap, archivedSegments: archive)
        let referenceChart = ReferenceChartDisplayHistory(
            samples: observations, now: date(now), duration: duration,
            maximumGap: maximumGap, archivedSegments: archive)
        XCTAssertEqual(chart.interval, referenceChart.interval, file: file, line: line)
        XCTAssertEqual(chart.segments, referenceChart.segments, file: file, line: line)
        XCTAssertEqual(chart.buckets, referenceChart.buckets, file: file, line: line)
        XCTAssertEqual(chart.plotSegments, referenceChart.plotSegments, file: file, line: line)
        XCTAssertEqual(
            chart.zeroFilledPlotSegments, referenceChart.zeroFilledPlotSegments, file: file,
            line: line)
        XCTAssertEqual(chart.peak, referenceChart.peak, file: file, line: line)
        XCTAssertEqual(chart.current, referenceChart.current, file: file, line: line)
        let tools = ToolActivityHistory(
            events: events, observations: observations, now: date(now), duration: duration,
            maximumGap: maximumGap, archivedSegments: archive)
        let referenceTools = ReferenceToolActivityHistory(
            events: events, observations: observations, now: date(now), duration: duration,
            maximumGap: maximumGap, archivedSegments: archive)
        XCTAssertEqual(tools.interval, referenceTools.interval, file: file, line: line)
        XCTAssertEqual(tools.segments, referenceTools.segments, file: file, line: line)
        XCTAssertEqual(tools.buckets, referenceTools.buckets, file: file, line: line)
        XCTAssertEqual(tools.plotSegments, referenceTools.plotSegments, file: file, line: line)
        XCTAssertEqual(
            tools.zeroFilledPlotSegments, referenceTools.zeroFilledPlotSegments, file: file,
            line: line)
        XCTAssertEqual(tools.resultMarkers, referenceTools.resultMarkers, file: file, line: line)
        XCTAssertEqual(tools.peak, referenceTools.peak, file: file, line: line)
        XCTAssertEqual(tools.current, referenceTools.current, file: file, line: line)
        var probes = [now - duration, now - duration + 0.25, now, now + 0.25]
        probes += observations.map { $0.timestamp.timeIntervalSince(origin) }
        probes += events.map { $0.timestamp.timeIntervalSince(origin) }
        probes += stride(from: now - duration, through: now, by: max(0.25, duration / 100))
        for offset in probes {
            XCTAssertEqual(
                chart.bucket(at: date(offset)), referenceChart.bucket(at: date(offset)), file: file,
                line: line)
            XCTAssertEqual(
                tools.bucket(at: date(offset)), referenceTools.bucket(at: date(offset)), file: file,
                line: line)
        }
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }

    private func point(_ offset: TimeInterval, _ value: Double, available: Bool = true)
        -> TimeSeriesPoint
    {
        TimeSeriesPoint(timestamp: date(offset), value: value, isAvailable: available)
    }

    private func call(_ offset: TimeInterval) -> ToolActivityEvent {
        ToolActivityEvent(kind: .call, name: "read_file", timestamp: date(offset))
    }

    private func archived(_ start: Double, _ end: Double, _ value: Double, _ count: Int)
        -> ArchivedChartBucket
    {
        ArchivedChartBucket(start: date(start), end: date(end), value: value, count: count)
    }
}
