import Foundation
import XCTest

@testable import FluxLLM

final class IncrementalChartPreparationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testCorrectedToolIDsUseLastWinnerIncludingItsKindTimeAndRequestOwner() throws {
        let oldOwner = lane(1, start: 0)
        let newOwner = lane(2, start: 0)
        let correctedResult = event(
            101, .resultSubmission, at: 4, name: "corrected-result", owner: 2)
        let snapshot = ChartPresentationSnapshot(
            timestamp: date(12),
            toolActivity: [
                correctedResult,
                event(102, .call, at: 5, name: "superseded-current", owner: 1),
                event(102, .call, at: 6, name: "current-winner", owner: 2),
            ], requestLanes: [oldOwner, newOwner], toolObservation: observations(through: 12),
            supportsToolActivity: true,
            historicalToolActivity: [
                event(101, .call, at: 1, name: "superseded-call", owner: 1),
                event(102, .resultSubmission, at: 2, name: "superseded-result", owner: 1),
                event(103, .call, at: 2, name: "superseded-history", owner: 1),
                event(103, .call, at: 3, name: "history-winner", owner: 2),
            ])
        let reference = prepare(snapshot, optimized: false)
        let candidate = prepare(snapshot, optimized: true)
        assertEquivalent(candidate, reference)
        for prepared in [reference, candidate] {
            let tools = try XCTUnwrap(prepared.toolActivity)
            XCTAssertEqual(tools.buckets.reduce(0) { $0 + $1.callCount }, 2)
            XCTAssertEqual(
                Set(tools.buckets.flatMap(\.toolNames)), ["current-winner", "history-winner"])
            XCTAssertEqual(tools.resultMarkers, [correctedResult])
            // ToolActivityEvent equality deliberately excludes requestID.
            XCTAssertEqual(tools.resultMarkers.first?.requestID, newOwner.id)
            XCTAssertNil(prepared.requestTools[oldOwner.id])
            let owned = try XCTUnwrap(prepared.requestTools[newOwner.id])
            XCTAssertEqual(owned.buckets.reduce(0) { $0 + $1.callCount }, 2)
            XCTAssertEqual(owned.resultMarkers.first?.timestamp, date(4))
            XCTAssertEqual(owned.resultMarkers.first?.requestID, newOwner.id)
        }
    }

    func testFutureOrInvalidWinningCorrectionSuppressesOldEventAndKeepsKnownOverlay() throws {
        for replacementTime in [date(21), Date(timeIntervalSince1970: .nan)] {
            let correction = ToolActivityEvent(
                id: id(101), kind: .resultSubmission, name: "replacement",
                timestamp: replacementTime, requestID: id(2))
            let snapshot = ChartPresentationSnapshot(
                timestamp: date(20), toolActivity: [correction],
                requestLanes: [lane(1, start: 0), lane(2, start: 0)],
                toolObservation: observations(through: 20), supportsToolActivity: true,
                historicalToolActivity: [event(101, .call, at: 5, name: "old", owner: 1)])
            let reference = prepare(snapshot, end: date(10), optimized: false)
            let candidate = prepare(snapshot, end: date(10), optimized: true)
            assertEquivalent(candidate, reference)
            for prepared in [reference, candidate] {
                let tools = try XCTUnwrap(prepared.toolActivity)
                XCTAssertEqual(tools.buckets.reduce(0) { $0 + $1.callCount }, 0)
                XCTAssertTrue(tools.resultMarkers.isEmpty)
                XCTAssertNil(
                    prepared.requestTools[id(1)], "A replaced historical owner must not survive")
                let known = try XCTUnwrap(prepared.requestTools[id(2)])
                XCTAssertFalse(
                    known.buckets.isEmpty, "Known ownership survives end/validity filtering")
                XCTAssertTrue(known.buckets.allSatisfy { $0.callCount == 0 })
                XCTAssertTrue(known.resultMarkers.isEmpty)
            }
        }
    }

    func testUnorderedAndSameTimeDistinctEventsRetainAllCountsAndResultOwners() throws {
        let events = [
            event(101, .call, at: 2, name: "first", owner: 1),
            event(102, .call, at: 5, name: "second", owner: 1),
            event(103, .call, at: 5, name: "third", owner: 2),
            event(104, .resultSubmission, at: 5, name: "result-a", owner: 1),
            event(105, .resultSubmission, at: 5, name: "result-b", owner: 2),
            event(106, .resultSubmission, at: 8, name: "result-c", owner: 2),
        ]
        func snapshot(_ events: [ToolActivityEvent]) -> ChartPresentationSnapshot {
            ChartPresentationSnapshot(
                timestamp: date(12), toolActivity: events,
                requestLanes: [lane(1, start: 0), lane(2, start: 0)],
                toolObservation: observations(through: 12), supportsToolActivity: true)
        }
        let reference = prepare(snapshot(events), optimized: false)
        let unordered = [events[5], events[2], events[4], events[0], events[3], events[1]]
        for optimized in [false, true] {
            let prepared = prepare(snapshot(unordered), optimized: optimized)
            assertEquivalent(prepared, reference)
            let tools = try XCTUnwrap(prepared.toolActivity)
            XCTAssertEqual(tools.buckets.reduce(0) { $0 + $1.callCount }, 3)
            XCTAssertEqual(Set(tools.resultMarkers.map(\.id)), [id(104), id(105), id(106)])
            XCTAssertEqual(tools.resultMarkers.map(\.timestamp), [date(5), date(5), date(8)])
            XCTAssertEqual(prepared.requestTools[id(1)]?.resultMarkers.map(\.requestID), [id(1)])
            XCTAssertEqual(
                prepared.requestTools[id(2)]?.resultMarkers.map(\.requestID), [id(2), id(2)])
        }
    }

    func testLaneSelectionPreservesBoundariesPrecedenceAndEveryOpenLaneAboveSoftCap() {
        let snapshot = ChartPresentationSnapshot(
            timestamp: date(100), requestLanes: [lane(5, start: 70)],
            historicalRequestLanes: [
                lane(1, start: 35, end: 40), lane(2, start: 60),
                lane(3, start: 35, end: 39.99), lane(4, start: 60.01),
                lane(5, start: 45, end: 55),
                lane(7, start: 50, end: 52), lane(6, start: 50, end: 52),
            ])
        let reference = prepare(snapshot, duration: 20, end: date(60), optimized: false)
        let candidate = prepare(snapshot, duration: 20, end: date(60), optimized: true)
        assertEquivalent(candidate, reference)
        XCTAssertEqual(candidate.lanes.map(\.id), [id(1), id(6), id(7), id(2)])
        XCTAssertEqual(candidate.omittedRequestCount, 0)

        let open = (1...259).map { lane($0, start: Double($0) / 100) }
        let ended = (300...302).map { lane($0, start: 4, end: 5) }
        let busy = ChartPresentationSnapshot(
            timestamp: date(10), requestLanes: Array(open.reversed()),
            historicalRequestLanes: ended)
        let busyReference = prepare(busy, optimized: false)
        let busyCandidate = prepare(busy, optimized: true)
        assertEquivalent(busyCandidate, busyReference)
        XCTAssertEqual(busyCandidate.lanes.map(\.id), open.map(\.id))
        XCTAssertEqual(busyCandidate.omittedRequestCount, 3)
    }

    func testFullHourFixtureMatchesLegacyAcrossRangesPublicationsAndFrozenEndpoints() {
        let snapshots = ChartPerformanceFixture.publications(
            retainedSeconds: 3_600, laneCount: 33, count: 2)
        for duration in [60.0, 300, 3_600] {
            for endOffset in [0.0, -5.5, -20] {
                let referenceCache = DashboardChartPreparation(clock: { self.date(4_000) })
                let candidateCache = DashboardChartPreparation(clock: { self.date(4_000) })
                for snapshot in snapshots {
                    let end = snapshot.timestamp.addingTimeInterval(endOffset)
                    let reference = referenceCache.histories(
                        snapshot: snapshot, duration: duration, windowEnd: end,
                        isLive: endOffset == 0, optimized: false)
                    let candidate = candidateCache.histories(
                        snapshot: snapshot, duration: duration, windowEnd: end,
                        isLive: endOffset == 0, optimized: true)
                    assertEquivalent(candidate, reference)
                    XCTAssertEqual(candidate.requestRails.events, reference.requestRails.events)
                }
            }
        }
    }

    func testSwitchingOptimizationOnSamePublicationInvalidatesCacheWithoutReplayingEffects() throws
    {
        let cache = DashboardChartPreparation(clock: { self.date(10) })
        _ = cache.histories(snapshot: ChartPresentationSnapshot(timestamp: origin), duration: 60)
        let snapshot = ChartPresentationSnapshot(
            timestamp: date(1), requestLanes: [lane(1, start: 1)])
        let legacy = cache.histories(snapshot: snapshot, duration: 60, optimized: false)
        let candidate = cache.histories(snapshot: snapshot, duration: 60, optimized: true)
        XCTAssertFalse(legacy === candidate)
        assertEquivalent(candidate, legacy)
        XCTAssertEqual(candidate.requestRails.events, legacy.requestRails.events)
        XCTAssertEqual(try XCTUnwrap(candidate.requestRails.events.first).kind, .arrival)
        XCTAssertTrue(
            cache.histories(snapshot: snapshot, duration: 60, optimized: true) === candidate)
        let switchedBack = cache.histories(snapshot: snapshot, duration: 60, optimized: false)
        XCTAssertFalse(switchedBack === candidate)
        XCTAssertEqual(switchedBack.requestRails.events, legacy.requestRails.events)
        let frozen = cache.histories(
            snapshot: snapshot, duration: 60, windowEnd: snapshot.timestamp,
            isLive: false, optimized: true)
        XCTAssertFalse(frozen === switchedBack)
        XCTAssertTrue(frozen.requestRails.events.isEmpty)
        XCTAssertEqual(frozen.requestRails.assignments, legacy.requestRails.assignments)
    }

    func testPinnedViewportStillTracksOutsideCompletionsForStableTrackReuse() throws {
        for optimized in [false, true] {
            var receipt = date(100)
            let cache = DashboardChartPreparation(clock: { receipt })
            let initial = cache.histories(
                snapshot: ChartPresentationSnapshot(
                    timestamp: date(100), requestLanes: [lane(1, start: 90)]),
                duration: 20, windowEnd: date(20), optimized: optimized)
            XCTAssertTrue(initial.lanes.isEmpty)
            let firstAssignment = try XCTUnwrap(initial.requestRails.assignments[id(1)])
            receipt = date(101)
            _ = cache.histories(
                snapshot: ChartPresentationSnapshot(
                    timestamp: date(101), requestLanes: [lane(1, start: 90, end: 101)]),
                duration: 20, windowEnd: date(20), optimized: optimized)
            receipt = date(102)
            let next = ChartPresentationSnapshot(
                timestamp: date(102), requestLanes: [lane(2, start: 101)])
            let pinned = cache.histories(
                snapshot: next, duration: 20, windowEnd: date(20), optimized: optimized)
            XCTAssertTrue(pinned.lanes.isEmpty)
            XCTAssertTrue(pinned.requestRails.events.isEmpty)
            let nextAssignment = try XCTUnwrap(pinned.requestRails.assignments[id(2)])
            XCTAssertEqual(nextAssignment.track, firstAssignment.track)
            XCTAssertEqual(nextAssignment.colorIndex, firstAssignment.colorIndex + 1)
            receipt = date(110)
            let live = cache.histories(snapshot: next, duration: 20, optimized: optimized)
            XCTAssertEqual(live.lanes.map(\.id), [id(2)])
            XCTAssertEqual(live.requestRails.assignments[id(2)], nextAssignment)
            XCTAssertTrue(
                live.requestRails.events.isEmpty, "Returning live must not replay expired arrivals")
        }
    }

    func testReleaseDropsPreparedStorageAndSamePublicationNewEpochReseedsIdentity() throws {
        for optimized in [false, true] {
            let cache = DashboardChartPreparation(clock: { self.date(10) })
            let epoch = id(900)
            _ = cache.histories(
                snapshot: ChartPresentationSnapshot(
                    timestamp: origin, requestLanes: [lane(1, start: 0)]),
                duration: 60, epoch: epoch, optimized: optimized)
            let snapshot = ChartPresentationSnapshot(
                timestamp: date(1), requestLanes: [lane(2, start: 1)])
            var prepared: PreparedDashboardCharts? = cache.histories(
                snapshot: snapshot, duration: 60, epoch: epoch, optimized: optimized)
            let assignments = try XCTUnwrap(prepared).requestRails.assignments
            XCTAssertEqual(assignments[id(2)]?.colorIndex, 1)
            weak var released = prepared
            prepared = nil
            XCTAssertNotNil(released)
            cache.releasePreparedCharts()
            XCTAssertNil(released)
            let restored = cache.histories(
                snapshot: snapshot, duration: 60, epoch: epoch, optimized: optimized)
            XCTAssertEqual(restored.requestRails.assignments, assignments)
            let reset = cache.histories(
                snapshot: snapshot, duration: 60, epoch: id(901), optimized: optimized)
            XCTAssertFalse(reset === restored)
            XCTAssertEqual(reset.publicationID, restored.publicationID)
            XCTAssertEqual(
                reset.requestRails.assignments[id(2)],
                RequestRailAssignment(track: 0, colorIndex: 0))
            XCTAssertTrue(reset.requestRails.events.isEmpty)
        }
    }

    private func prepare(
        _ snapshot: ChartPresentationSnapshot, duration: TimeInterval = 60,
        end: Date? = nil, optimized: Bool
    ) -> PreparedDashboardCharts {
        PreparedDashboardCharts(
            snapshot: snapshot, duration: duration, windowEnd: end, optimized: optimized)
    }

    private func assertEquivalent(
        _ actual: PreparedDashboardCharts, _ expected: PreparedDashboardCharts,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.windowEnd, expected.windowEnd, file: file, line: line)
        XCTAssertEqual(actual.lanes, expected.lanes, file: file, line: line)
        XCTAssertEqual(
            actual.omittedRequestCount, expected.omittedRequestCount, file: file, line: line)
        XCTAssertEqual(
            actual.requestRails.assignments, expected.requestRails.assignments, file: file,
            line: line)
        XCTAssertEqual(actual.laneColorIndex, expected.laneColorIndex, file: file, line: line)
        XCTAssertEqual(
            actual.throughput.interval, expected.throughput.interval, file: file, line: line)
        XCTAssertEqual(
            actual.throughput.buckets, expected.throughput.buckets, file: file, line: line)
        XCTAssertEqual(
            actual.throughput.segments, expected.throughput.segments, file: file, line: line)
        XCTAssertEqual(
            actual.throughput.current, expected.throughput.current, file: file, line: line)
        XCTAssertEqual(actual.throughput.peak, expected.throughput.peak, file: file, line: line)
        XCTAssertEqual(actual.gpu.interval, expected.gpu.interval, file: file, line: line)
        XCTAssertEqual(actual.gpu.buckets, expected.gpu.buckets, file: file, line: line)
        XCTAssertEqual(actual.gpu.segments, expected.gpu.segments, file: file, line: line)
        XCTAssertEqual(actual.gpu.current, expected.gpu.current, file: file, line: line)
        XCTAssertEqual(actual.gpu.peak, expected.gpu.peak, file: file, line: line)
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
        // Equal-time marker order inherits dictionary traversal, not UUID order.
        let actualMarkers = actual.resultMarkers.sorted { $0.id.uuidString < $1.id.uuidString }
        let expectedMarkers = expected.resultMarkers.sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(actualMarkers, expectedMarkers, file: file, line: line)
        XCTAssertEqual(
            actualMarkers.map(\.requestID), expectedMarkers.map(\.requestID), file: file, line: line
        )
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
    private func lane(_ number: Int, start: TimeInterval, end: TimeInterval? = nil) -> RequestLane {
        RequestLane(
            id: id(number), startedAt: date(start), endedAt: end.map(date), terminal: end != nil)
    }
    private func event(
        _ number: Int, _ kind: ToolActivityEvent.Kind, at offset: TimeInterval,
        name: String, owner: Int
    ) -> ToolActivityEvent {
        ToolActivityEvent(
            id: id(number), kind: kind, name: name, timestamp: date(offset), requestID: id(owner))
    }
    private func observations(through end: Int) -> [TimeSeriesPoint] {
        (0...end).map { TimeSeriesPoint(timestamp: date(Double($0)), value: 0) }
    }
}
