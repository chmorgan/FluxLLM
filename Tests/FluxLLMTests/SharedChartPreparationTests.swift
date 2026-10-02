import Foundation
import XCTest

@testable import FluxLLM

final class SharedChartPreparationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testCorrectionsWinBeforeEachViewportFiltersTheirTimeAndOwner() throws {
        let future = event(101, at: 25, owner: 2, kind: .resultSubmission)
        let invalid = ToolActivityEvent(
            id: id(102), kind: .call, name: "invalid-correction",
            timestamp: Date(timeIntervalSince1970: .nan), requestID: id(3))
        var snapshot = ChartPresentationSnapshot(
            timestamp: date(30), toolActivity: [future, invalid],
            requestLanes: [lane(1), lane(2), lane(3)],
            toolObservation: observations(through: 30), supportsToolActivity: true,
            historicalToolActivity: [event(101, at: 5, owner: 1), event(102, at: 6, owner: 1)])
        snapshot.sharedPreparationMetadata = SharedChartPresentationMetadata(snapshot: snapshot)
        let metadata = try XCTUnwrap(snapshot.sharedPreparationMetadata)
        XCTAssertEqual(metadata.knownToolRequestIDs, [id(2), id(3)])
        XCTAssertEqual(metadata.toolEvents.map(\.id), [future.id])
        XCTAssertTrue(metadata.toolEvents(through: date(20)).isEmpty)
        XCTAssertEqual(metadata.toolEvents(through: date(25)), [future])
        let invalidEnd = Date(timeIntervalSince1970: .nan)
        XCTAssertEqual(
            metadata.toolEvents(through: invalidEnd),
            ToolActivityHistory.normalizedEvents([future], through: invalidEnd))

        for end in [10.0, 20, 25, 30] {
            let baseline = prepare(snapshot, end: date(end), shared: false)
            let shared = prepare(snapshot, end: date(end), shared: true)
            assertEquivalent(shared, baseline)
            XCTAssertNil(shared.requestTools[id(1)])
            XCTAssertNotNil(shared.requestTools[id(2)])
            XCTAssertNotNil(shared.requestTools[id(3)])
            XCTAssertEqual(shared.toolActivity?.buckets.reduce(0) { $0 + $1.callCount }, 0)
            XCTAssertEqual(shared.toolActivity?.resultMarkers.count, end >= 25 ? 1 : 0)
        }
    }

    func testUnorderedInputsPreserveEqualTimeSourceOrderAndLastCorrection() {
        let snapshot = ChartPresentationSnapshot(
            timestamp: date(10),
            toolActivity: [event(102, at: 5, owner: 2), event(101, at: 3, owner: 2)],
            requestLanes: [lane(2), lane(1, start: 2)],
            toolObservation: observations(through: 10), supportsToolActivity: true,
            historicalRequestLanes: [lane(3), lane(1), lane(3, start: 1)],
            historicalToolActivity: [
                event(103, at: 5, owner: 1), event(101, at: 2, owner: 1),
                event(104, at: 5, owner: 3),
            ])
        let metadata = SharedChartPresentationMetadata(snapshot: snapshot)
        XCTAssertEqual(metadata.toolEvents.map(\.id), [id(101), id(103), id(104), id(102)])
        XCTAssertEqual(metadata.toolEvents.first?.requestID, id(2))
        XCTAssertEqual(metadata.requestLanes.map(\.id), [id(2), id(3), id(1)])
        XCTAssertEqual(metadata.requestLanes.last?.startedAt, date(2))
        assertEquivalent(prepare(snapshot, shared: true), prepare(snapshot, shared: false))
    }

    func testExplicitKnownOwnersOverrideDerivedOwners() {
        let snapshot = ChartPresentationSnapshot(
            timestamp: date(10), toolActivity: [event(101, at: 20, owner: 2)],
            requestLanes: [lane(1), lane(2)], toolObservation: observations(through: 10),
            supportsToolActivity: true,
            toolActivityRequestIDs: [id(3)])
        let metadata = SharedChartPresentationMetadata(snapshot: snapshot)
        XCTAssertEqual(metadata.knownToolRequestIDs, [id(3)])
        XCTAssertEqual(metadata.requestLanes.map(\.id), [id(1), id(2)])
        let shared = prepare(snapshot, shared: true)
        assertEquivalent(shared, prepare(snapshot, shared: false))
        XCTAssertTrue(shared.requestTools.isEmpty)
    }

    func testLaneTiesAndNonfiniteTimesMatchExistingViewportSelection() throws {
        let snapshot = ChartPresentationSnapshot(
            timestamp: date(10),
            requestLanes: [
                lane(4, start: 3), lane(3, start: 3),
                RequestLane(id: id(1), startedAt: Date(timeIntervalSince1970: .nan)),
            ],
            historicalRequestLanes: [
                lane(1),
                RequestLane(id: id(2), startedAt: Date(timeIntervalSince1970: -.infinity)),
                RequestLane(id: id(5), startedAt: Date(timeIntervalSince1970: .infinity)),
                RequestLane(
                    id: id(6), startedAt: origin, endedAt: Date(timeIntervalSince1970: .nan)),
            ])
        let baseline = PreparedDashboardCharts.optimizedLaneSelection(
            snapshot: snapshot, end: date(10), duration: 60)
        let metadata = SharedChartPresentationMetadata(snapshot: snapshot)
        XCTAssertTrue(metadata.requiresLegacyLaneSelection)
        XCTAssertEqual(Set(metadata.requestLanes.map(\.id)), Set((1...6).map(id)))
        let corrected = try XCTUnwrap(metadata.requestLanes.first { $0.id == id(1) })
        let invalidEnd = try XCTUnwrap(metadata.requestLanes.first { $0.id == id(6) }?.endedAt)
        XCTAssertTrue(corrected.startedAt.timeIntervalSince1970.isNaN)
        XCTAssertTrue(invalidEnd.timeIntervalSince1970.isNaN)
        let shared = PreparedDashboardCharts.optimizedLaneSelection(
            snapshot: snapshot, end: date(10), duration: 60,
            sharedMetadata: metadata)
        // NaN makes the existing Date comparator non-total; dictionary traversal
        // never promised an ordering for these malformed lanes. Winner identity,
        // original boundaries, viewport membership and the cap must still match.
        XCTAssertEqual(Set(shared.rendered.map(\.id)), Set(baseline.rendered.map(\.id)))
        for lane in shared.rendered {
            let expected = try XCTUnwrap(baseline.rendered.first { $0.id == lane.id })
            XCTAssertEqual(
                lane.startedAt.timeIntervalSince1970.bitPattern,
                expected.startedAt.timeIntervalSince1970.bitPattern)
            XCTAssertEqual(
                lane.endedAt?.timeIntervalSince1970.bitPattern,
                expected.endedAt?.timeIntervalSince1970.bitPattern)
        }
        XCTAssertEqual(shared.omittedCount, baseline.omittedCount)

        let finite = ChartPresentationSnapshot(
            timestamp: date(10), requestLanes: [lane(4, start: 3), lane(3, start: 3)])
        let finiteMetadata = SharedChartPresentationMetadata(snapshot: finite)
        XCTAssertFalse(finiteMetadata.requiresLegacyLaneSelection)
        XCTAssertEqual(finiteMetadata.requestLanes.map(\.id), [id(3), id(4)])
        assertEquivalent(prepare(finite, shared: true), prepare(finite, shared: false))
    }

    func testOnePayloadServesDifferentWindowsWithoutSharingRailLifecycleState() throws {
        PerformancePresentationCounters.shared.enable()
        var snapshot = ChartPresentationSnapshot(
            timestamp: date(60),
            toolActivity: [event(101, at: 5, owner: 1), event(102, at: 50, owner: 2)],
            requestLanes: [lane(1, end: 10), lane(2, start: 45)],
            toolObservation: observations(through: 60), supportsToolActivity: true)
        snapshot.sharedPreparationMetadata = SharedChartPresentationMetadata(snapshot: snapshot)
        let first = DashboardChartPreparation(clock: { self.date(60) })
        let second = DashboardChartPreparation(clock: { self.date(60) })
        let frozen = first.histories(
            snapshot: snapshot, duration: 20, windowEnd: date(20), optimized: true,
            sharedNormalization: true)
        let live = second.histories(
            snapshot: snapshot, duration: 20, optimized: true, sharedNormalization: true)
        XCTAssertTrue(first.sharedMetadata === second.sharedMetadata)
        XCTAssertTrue(first.sharedMetadata === snapshot.sharedPreparationMetadata)
        XCTAssertEqual(normalizationBuilds, 1)
        XCTAssertEqual(frozen.lanes.map(\.id), [id(1)])
        XCTAssertEqual(live.lanes.map(\.id), [id(2)])
        assertEquivalent(frozen, prepare(snapshot, duration: 20, end: date(20), shared: false))
        assertEquivalent(live, prepare(snapshot, duration: 20, shared: false))

        let retained = DashboardChartPreparation(clock: { self.date(100) })
        _ = retained.histories(
            snapshot: ChartPresentationSnapshot(
                timestamp: date(0), requestLanes: [lane(99, end: 0)]),
            duration: 60, optimized: true)
        var arrival = ChartPresentationSnapshot(
            timestamp: date(1), requestLanes: [lane(4, start: 1)])
        arrival.sharedPreparationMetadata = SharedChartPresentationMetadata(snapshot: arrival)
        let seeded = retained.histories(
            snapshot: arrival, duration: 60, optimized: true, sharedNormalization: true)
        let freshCache = DashboardChartPreparation(clock: { self.date(100) })
        let fresh = freshCache.histories(
            snapshot: arrival, duration: 60, optimized: true, sharedNormalization: true)
        XCTAssertTrue(retained.sharedMetadata === freshCache.sharedMetadata)
        XCTAssertEqual(seeded.requestRails.assignments[id(4)]?.colorIndex, 1)
        XCTAssertEqual(fresh.requestRails.assignments[id(4)]?.colorIndex, 0)
        XCTAssertEqual(try XCTUnwrap(seeded.requestRails.events.first).kind, .arrival)
        XCTAssertTrue(fresh.requestRails.events.isEmpty)
    }

    func testFallbackMetadataReusesOnePublicationAndReleasesWhenHiddenOrReplaced() {
        PerformancePresentationCounters.shared.enable()
        let snapshot = ChartPresentationSnapshot(timestamp: date(10), requestLanes: [lane(1)])
        let cache = DashboardChartPreparation(clock: { self.date(10) })
        _ = cache.histories(
            snapshot: snapshot, duration: 60, optimized: true, sharedNormalization: true)
        weak var retained = cache.sharedMetadata
        XCTAssertNotNil(retained)
        _ = cache.histories(
            snapshot: snapshot, duration: 300, optimized: true, sharedNormalization: true)
        XCTAssertTrue(retained === cache.sharedMetadata)
        XCTAssertEqual(normalizationBuilds, 1)
        cache.releasePreparedCharts()
        XCTAssertNil(retained)
        _ = cache.histories(
            snapshot: snapshot, duration: 60, optimized: true, sharedNormalization: true)
        XCTAssertEqual(normalizationBuilds, 2)

        weak var replaced = cache.sharedMetadata
        let next = ChartPresentationSnapshot(timestamp: date(11), requestLanes: [lane(1)])
        _ = cache.histories(
            snapshot: next, duration: 60, optimized: true, sharedNormalization: true)
        XCTAssertNil(replaced)
        XCTAssertEqual(normalizationBuilds, 3)
        weak var oldEpoch = cache.sharedMetadata
        _ = cache.histories(
            snapshot: next, duration: 60, epoch: id(999), optimized: true, sharedNormalization: true
        )
        XCTAssertNil(oldEpoch)
        XCTAssertEqual(normalizationBuilds, 4)
    }

    func testModeSwitchRebuildsSamePublicationWithoutReplayingRequestEffects() throws {
        let cache = DashboardChartPreparation(clock: { self.date(10) })
        _ = cache.histories(snapshot: ChartPresentationSnapshot(timestamp: origin), duration: 60)
        let snapshot = ChartPresentationSnapshot(
            timestamp: date(1), requestLanes: [lane(1, start: 1)])
        let baseline = cache.histories(snapshot: snapshot, duration: 60, optimized: true)
        let shared = cache.histories(
            snapshot: snapshot, duration: 60, optimized: true, sharedNormalization: true)
        XCTAssertFalse(shared === baseline)
        assertEquivalent(shared, baseline)
        XCTAssertEqual(try XCTUnwrap(shared.requestRails.events.first).kind, .arrival)
        XCTAssertTrue(
            cache.histories(
                snapshot: snapshot, duration: 60, optimized: true, sharedNormalization: true)
                === shared)
        let restored = cache.histories(snapshot: snapshot, duration: 60, optimized: true)
        XCTAssertFalse(restored === shared)
        assertEquivalent(restored, baseline)
        XCTAssertNil(cache.sharedMetadata)
    }

    func testAttachedMetadataDoesNotChangeSnapshotValueEqualityOrPublicationIdentity() {
        let snapshot = ChartPresentationSnapshot(timestamp: date(10), requestLanes: [lane(1)])
        var attached = snapshot
        attached.sharedPreparationMetadata = SharedChartPresentationMetadata(snapshot: snapshot)
        XCTAssertEqual(attached, snapshot)
        XCTAssertEqual(attached.publicationID, snapshot.publicationID)
    }

    func testSharedPreparationMatchesCurrentAcrossRangesAndFrozenEndpoints() {
        let snapshots = ChartPerformanceFixture.publications(
            retainedSeconds: 3_600, laneCount: 33, count: 2)
        for duration in [60.0, 300, 3_600] {
            for endOffset in [0.0, -5.5, -20] {
                let baseline = DashboardChartPreparation(clock: { self.date(4_000) })
                let shared = DashboardChartPreparation(clock: { self.date(4_000) })
                for var snapshot in snapshots {
                    snapshot.sharedPreparationMetadata = SharedChartPresentationMetadata(
                        snapshot: snapshot)
                    let end = snapshot.timestamp.addingTimeInterval(endOffset)
                    assertEquivalent(
                        shared.histories(
                            snapshot: snapshot, duration: duration, windowEnd: end,
                            isLive: endOffset == 0, optimized: true, sharedNormalization: true),
                        baseline.histories(
                            snapshot: snapshot, duration: duration, windowEnd: end,
                            isLive: endOffset == 0, optimized: true))
                }
            }
        }
    }

    func testOpenLanesAboveCapAndPinnedOutsideCompletionsMatchCurrent() {
        let open = (1...259).map { lane($0, start: Double($0) / 100) }
        let busy = ChartPresentationSnapshot(
            timestamp: date(10), requestLanes: Array(open.reversed()),
            historicalRequestLanes: [lane(300, start: 4, end: 5), lane(301, start: 4, end: 5)])
        assertEquivalent(prepare(busy, shared: true), prepare(busy, shared: false))

        let baseline = DashboardChartPreparation(clock: { self.date(100) })
        let shared = DashboardChartPreparation(clock: { self.date(100) })
        for snapshot in [
            ChartPresentationSnapshot(timestamp: date(100), requestLanes: [lane(1, start: 90)]),
            ChartPresentationSnapshot(
                timestamp: date(101), requestLanes: [lane(1, start: 90, end: 101)]),
            ChartPresentationSnapshot(timestamp: date(102), requestLanes: [lane(2, start: 101)]),
        ] {
            assertEquivalent(
                shared.histories(
                    snapshot: snapshot, duration: 20, windowEnd: date(20), optimized: true,
                    sharedNormalization: true),
                baseline.histories(
                    snapshot: snapshot, duration: 20, windowEnd: date(20), optimized: true))
        }
    }

    private var normalizationBuilds: UInt64 {
        PerformancePresentationCounters.shared.snapshot()["shared_chart_normalization_builds"] ?? 0
    }

    private func prepare(
        _ snapshot: ChartPresentationSnapshot, duration: TimeInterval = 60,
        end: Date? = nil, shared: Bool
    ) -> PreparedDashboardCharts {
        DashboardChartPreparation(clock: { self.date(1_000) }).histories(
            snapshot: snapshot, duration: duration, windowEnd: end, optimized: true,
            sharedNormalization: shared)
    }

    private func assertEquivalent(
        _ actual: PreparedDashboardCharts, _ expected: PreparedDashboardCharts,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.windowEnd, expected.windowEnd, file: file, line: line)
        XCTAssertEqual(actual.lanes, expected.lanes, file: file, line: line)
        XCTAssertEqual(
            actual.omittedRequestCount, expected.omittedRequestCount, file: file, line: line)
        XCTAssertEqual(actual.requestRails, expected.requestRails, file: file, line: line)
        XCTAssertEqual(actual.laneColorIndex, expected.laneColorIndex, file: file, line: line)
        for (a, b) in [(actual.throughput, expected.throughput), (actual.gpu, expected.gpu)] {
            XCTAssertEqual(a.interval, b.interval, file: file, line: line)
            XCTAssertEqual(a.buckets, b.buckets, file: file, line: line)
            XCTAssertEqual(a.segments, b.segments, file: file, line: line)
            XCTAssertEqual(a.current, b.current, file: file, line: line)
            XCTAssertEqual(a.peak, b.peak, file: file, line: line)
        }
        assertToolsEquivalent(actual.toolActivity, expected.toolActivity, file: file, line: line)
        XCTAssertEqual(
            Set(actual.requestTools.keys), Set(expected.requestTools.keys), file: file, line: line)
        for id in expected.requestTools.keys {
            assertToolsEquivalent(
                actual.requestTools[id], expected.requestTools[id], file: file, line: line)
        }
    }

    private func assertToolsEquivalent(
        _ actual: ToolActivityHistory?, _ expected: ToolActivityHistory?,
        file: StaticString, line: UInt
    ) {
        XCTAssertEqual(actual == nil, expected == nil, file: file, line: line)
        guard let actual, let expected else { return }
        XCTAssertEqual(actual.interval, expected.interval, file: file, line: line)
        XCTAssertEqual(actual.buckets, expected.buckets, file: file, line: line)
        XCTAssertEqual(actual.segments, expected.segments, file: file, line: line)
        XCTAssertEqual(actual.plotSegments, expected.plotSegments, file: file, line: line)
        XCTAssertEqual(actual.current, expected.current, file: file, line: line)
        XCTAssertEqual(actual.peak, expected.peak, file: file, line: line)
        XCTAssertEqual(actual.resultMarkers, expected.resultMarkers, file: file, line: line)
        // ToolActivityEvent value equality deliberately excludes request ownership.
        XCTAssertEqual(
            actual.resultMarkers.map(\.requestID), expected.resultMarkers.map(\.requestID),
            file: file, line: line)
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
    private func lane(_ number: Int, start: TimeInterval = 0, end: TimeInterval? = nil)
        -> RequestLane
    {
        RequestLane(
            id: id(number), startedAt: date(start), endedAt: end.map(date), terminal: end != nil)
    }
    private func event(
        _ number: Int, at offset: TimeInterval, owner: Int,
        kind: ToolActivityEvent.Kind = .call
    ) -> ToolActivityEvent {
        ToolActivityEvent(
            id: id(number), kind: kind, name: "synthetic-tool", timestamp: date(offset),
            requestID: id(owner))
    }
    private func observations(through end: Int) -> [TimeSeriesPoint] {
        (0...end).map { TimeSeriesPoint(timestamp: date(Double($0)), value: 0) }
    }
}
