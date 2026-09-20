import Foundation
import XCTest

@testable import FluxLLM

final class ChartPreparationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testRepeatedDashboardRefreshesReusePreparedFullHourHistory() {
        let samples = (0...7_200).map {
            TimeSeriesPoint(
                timestamp: origin.addingTimeInterval(Double($0) / 2), value: Double($0 % 80))
        }
        let snapshot = ChartPresentationSnapshot(
            timestamp: origin.addingTimeInterval(3_600), throughput: samples, systemGPU: samples,
            toolActivity: [
                ToolActivityEvent(
                    kind: .call, name: "read_file", timestamp: origin.addingTimeInterval(3_598))
            ], toolObservation: samples, supportsToolActivity: true)
        let cache = DashboardChartPreparation()
        let prepared = cache.histories(snapshot: snapshot, duration: 3_600)

        // Token counters and pointer movement can redraw many times between publications.
        // The reference identity proves those redraws do not rebuild any history.
        for _ in 0..<1_000 {
            XCTAssertTrue(cache.histories(snapshot: snapshot, duration: 3_600) === prepared)
        }
        XCTAssertEqual(prepared.throughput.interval, 60)
        XCTAssertEqual(prepared.gpu.interval, 60)
        XCTAssertEqual(prepared.toolActivity?.interval, 60)
        XCTAssertEqual(prepared.toolActivity?.buckets.reduce(0) { $0 + $1.callCount }, 1)
        XCTAssertEqual(snapshot.throughput.count, 7_201)
        XCTAssertEqual(snapshot.systemGPU.count, 7_201)
    }

    func testRangeChangePreparesNewAveragesForTheSamePublication() {
        let samples = (0..<120).map {
            TimeSeriesPoint(
                timestamp: origin.addingTimeInterval(Double($0) / 2), value: Double($0))
        }
        let snapshot = ChartPresentationSnapshot(
            timestamp: origin.addingTimeInterval(60), throughput: samples)
        let cache = DashboardChartPreparation()
        let minute = cache.histories(snapshot: snapshot, duration: 60)
        let hour = cache.histories(snapshot: snapshot, duration: 3_600)

        XCTAssertFalse(minute === hour)
        XCTAssertEqual(minute.throughput.interval, 3)
        XCTAssertEqual(minute.throughput.buckets.count, 20)
        XCTAssertEqual(hour.throughput.interval, 60)
        XCTAssertEqual(hour.throughput.buckets.count, 1)
        XCTAssertEqual(hour.throughput.peak, 59.5)
        XCTAssertTrue(cache.histories(snapshot: snapshot, duration: 3_600) === hour)
    }

    func testPublicationRefreshUpdatesEndpointFreshnessEvenWithTheSameSamples() {
        let samples = [TimeSeriesPoint(timestamp: origin, value: 20)]
        let cache = DashboardChartPreparation()
        let first = cache.histories(
            snapshot: ChartPresentationSnapshot(timestamp: origin, throughput: samples),
            duration: 60)
        let later = cache.histories(
            snapshot: ChartPresentationSnapshot(
                timestamp: origin.addingTimeInterval(6), throughput: samples), duration: 60)

        XCTAssertFalse(first === later)
        XCTAssertEqual(first.throughput.current?.value, 20)
        XCTAssertNil(later.throughput.current)
    }

    func testSameTimestampResetInvalidatesGPUAndThroughputHistory() {
        let samples = [TimeSeriesPoint(timestamp: origin, value: 40)]
        let cache = DashboardChartPreparation()
        let first = cache.histories(
            snapshot: ChartPresentationSnapshot(
                timestamp: origin, throughput: samples, systemGPU: samples), duration: 60)
        let gpuCleared = cache.histories(
            snapshot: ChartPresentationSnapshot(timestamp: origin, throughput: samples),
            duration: 60)
        let reset = cache.histories(
            snapshot: ChartPresentationSnapshot(timestamp: origin), duration: 60)

        XCTAssertFalse(first === gpuCleared)
        XCTAssertEqual(gpuCleared.throughput.peak, 40)
        XCTAssertTrue(gpuCleared.gpu.buckets.isEmpty)
        XCTAssertFalse(gpuCleared === reset)
        XCTAssertTrue(reset.throughput.buckets.isEmpty)
        XCTAssertTrue(reset.gpu.buckets.isEmpty)
    }

    func testPublicationIdentityDoesNotChangeSnapshotValueEquality() {
        let samples = [TimeSeriesPoint(timestamp: origin, value: 40)]
        let first = ChartPresentationSnapshot(timestamp: origin, throughput: samples)
        let equivalent = ChartPresentationSnapshot(timestamp: origin, throughput: samples)
        let copy = first

        XCTAssertEqual(first, equivalent)
        XCTAssertNotEqual(first.publicationID, equivalent.publicationID)
        XCTAssertEqual(first.publicationID, copy.publicationID)
    }

    func testPreparedGPUHistoryRetainsValidationAndMissingDataGaps() {
        let samples = [
            TimeSeriesPoint(timestamp: origin, value: 0),
            TimeSeriesPoint(timestamp: origin.addingTimeInterval(0.5), value: 110),
            TimeSeriesPoint(timestamp: origin.addingTimeInterval(1), value: 60),
        ]
        let prepared = DashboardChartPreparation().histories(
            snapshot: ChartPresentationSnapshot(
                timestamp: origin.addingTimeInterval(1), throughput: samples, systemGPU: samples),
            duration: 60)

        XCTAssertEqual(prepared.gpu.segments.count, 2)
        XCTAssertEqual(prepared.gpu.buckets.map(\.value), [0, 60])
        XCTAssertNil(prepared.gpu.bucket(at: origin.addingTimeInterval(0.5)))
        XCTAssertEqual(prepared.throughput.segments.count, 1)
        XCTAssertEqual(prepared.throughput.buckets.first?.count, 3)
    }

    func testToolOverlayRequiresSupportedBackendAndResetsWithPublication() {
        let samples = (0...6).map {
            TimeSeriesPoint(timestamp: origin.addingTimeInterval(Double($0)), value: 0)
        }
        let events = [
            ToolActivityEvent(
                kind: .call, name: "read_file", timestamp: origin.addingTimeInterval(1))
        ]
        let now = origin.addingTimeInterval(6)
        let cache = DashboardChartPreparation()
        let enabled = cache.histories(
            snapshot: ChartPresentationSnapshot(
                timestamp: now, toolActivity: events, toolObservation: samples,
                supportsToolActivity: true), duration: 60)
        XCTAssertEqual(enabled.toolActivity?.peak, 20)
        let unsupported = cache.histories(
            snapshot: ChartPresentationSnapshot(
                timestamp: now, toolActivity: events, toolObservation: samples), duration: 60)
        XCTAssertNil(unsupported.toolActivity)
        XCTAssertFalse(unsupported === enabled)
        let reset = cache.histories(
            snapshot: ChartPresentationSnapshot(timestamp: now, supportsToolActivity: true),
            duration: 60)
        XCTAssertNotNil(reset.toolActivity)
        XCTAssertTrue(reset.toolActivity?.buckets.isEmpty == true)
    }

    func testRequestTracksAndColorsSurviveHistoryExpiryAndRangeChanges() throws {
        let a = RequestLane(id: UUID(), startedAt: origin, endedAt: origin.addingTimeInterval(3))
        let b = RequestLane(id: UUID(), startedAt: origin.addingTimeInterval(1))
        let cache = DashboardChartPreparation(clock: { self.origin })
        let initial = cache.histories(
            snapshot: ChartPresentationSnapshot(
                timestamp: origin.addingTimeInterval(4), requestLanes: [a, b]), duration: 60)
        let assignment = try XCTUnwrap(initial.requestRails.assignments[b.id])
        let laterSnapshot = ChartPresentationSnapshot(
            timestamp: origin.addingTimeInterval(120), requestLanes: [b])
        let later = cache.histories(snapshot: laterSnapshot, duration: 60)
        let expanded = cache.histories(snapshot: laterSnapshot, duration: 3_600)

        XCTAssertEqual(later.requestRails.assignments[b.id], assignment)
        XCTAssertEqual(expanded.requestRails.assignments[b.id], assignment)
        XCTAssertEqual(later.laneColorIndex[b.id], initial.laneColorIndex[b.id])
        XCTAssertTrue(expanded.requestRails.events.isEmpty)
    }

    func testRangeChangesDoNotRestartReceiptTimedRequestEffects() throws {
        var receipt = origin
        let cache = DashboardChartPreparation(clock: { receipt })
        _ = cache.histories(snapshot: ChartPresentationSnapshot(timestamp: origin), duration: 60)
        let request = RequestLane(id: UUID(), startedAt: origin.addingTimeInterval(1))
        let snapshot = ChartPresentationSnapshot(
            timestamp: origin.addingTimeInterval(1), requestLanes: [request])
        receipt = origin.addingTimeInterval(10)
        let minute = cache.histories(snapshot: snapshot, duration: 60)
        let event = try XCTUnwrap(minute.requestRails.events.first)
        XCTAssertEqual(event.kind, .arrival)
        XCTAssertEqual(event.startedAt, receipt)

        receipt = origin.addingTimeInterval(10.4)
        let hour = cache.histories(snapshot: snapshot, duration: 3_600)
        XCTAssertEqual(hour.requestRails.events, minute.requestRails.events)
        XCTAssertEqual(hour.requestRails.assignments, minute.requestRails.assignments)
    }

    func testBackendEpochResetsRequestIdentityAndSeedsWithoutEffects() {
        let cache = DashboardChartPreparation(clock: { self.origin })
        let oldEpoch = UUID()
        let a = RequestLane(id: UUID(), startedAt: origin)
        let b = RequestLane(id: UUID(), startedAt: origin.addingTimeInterval(1))
        _ = cache.histories(
            snapshot: ChartPresentationSnapshot(
                timestamp: origin.addingTimeInterval(2), requestLanes: [a, b]),
            duration: 60, epoch: oldEpoch)

        let replacement = RequestLane(id: UUID(), startedAt: origin.addingTimeInterval(3))
        let reset = cache.histories(
            snapshot: ChartPresentationSnapshot(
                timestamp: origin.addingTimeInterval(4), requestLanes: [replacement]),
            duration: 60, epoch: UUID())
        XCTAssertEqual(reset.requestRails.assignments[replacement.id]?.track, 0)
        XCTAssertEqual(reset.laneColorIndex[replacement.id], 0)
        XCTAssertNil(reset.requestRails.assignments[a.id])
        XCTAssertTrue(reset.requestRails.events.isEmpty)
    }

    func testFrozenEndpointParticipatesInPreparationCacheAndLimitsAllSeries() throws {
        let samples = (0...60).map {
            TimeSeriesPoint(timestamp: origin.addingTimeInterval(Double($0)), value: Double($0))
        }
        let events = [20.0, 50.0].map {
            ToolActivityEvent(kind: .call, timestamp: origin.addingTimeInterval($0))
        }
        let snapshot = ChartPresentationSnapshot(
            timestamp: origin.addingTimeInterval(60), throughput: samples, systemGPU: samples,
            toolActivity: events, toolObservation: samples, supportsToolActivity: true)
        let cache = DashboardChartPreparation()
        let end = origin.addingTimeInterval(30)
        let frozen = cache.histories(snapshot: snapshot, duration: 60, windowEnd: end)
        let repeated = cache.histories(snapshot: snapshot, duration: 60, windowEnd: end)
        let later = cache.histories(
            snapshot: snapshot, duration: 60, windowEnd: origin.addingTimeInterval(45))

        XCTAssertTrue(frozen === repeated)
        XCTAssertFalse(frozen === later)
        XCTAssertEqual(frozen.windowEnd, end)
        XCTAssertEqual(frozen.throughput.buckets.last?.end, end)
        XCTAssertEqual(frozen.gpu.buckets.last?.end, end)
        XCTAssertEqual(frozen.toolActivity?.buckets.reduce(0) { $0 + $1.callCount }, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(frozen.toolActivity?.buckets.last?.end), end)
        XCTAssertEqual(later.windowEnd, origin.addingTimeInterval(45))
    }

    func testHistoricalLanesAndToolEventsMergeWithoutDuplicatingRecentCopies() {
        let old = RequestLane(
            id: UUID(), startedAt: origin, endedAt: origin.addingTimeInterval(20), terminal: true)
        let saved = RequestLane(
            id: UUID(), startedAt: origin.addingTimeInterval(30), outputTokens: 10)
        let current = RequestLane(
            id: saved.id, startedAt: saved.startedAt, endedAt: origin.addingTimeInterval(50),
            outputTokens: 40, terminal: true)
        let future = RequestLane(id: UUID(), startedAt: origin.addingTimeInterval(70))
        let oldCall = ToolActivityEvent(
            kind: .call, timestamp: origin.addingTimeInterval(10), requestID: old.id)
        let recentCall = ToolActivityEvent(
            kind: .call, timestamp: origin.addingTimeInterval(40), requestID: current.id)
        let result = ToolActivityEvent(
            kind: .resultSubmission, timestamp: origin.addingTimeInterval(45),
            requestID: current.id)
        let snapshot = ChartPresentationSnapshot(
            timestamp: origin.addingTimeInterval(100), toolActivity: [recentCall, result],
            requestLanes: [current, future], supportsToolActivity: true,
            historicalRequestLanes: [old, saved],
            historicalToolActivity: [oldCall, recentCall, result])
        let prepared = DashboardChartPreparation().histories(
            snapshot: snapshot, duration: 60, windowEnd: origin.addingTimeInterval(60))

        XCTAssertEqual(prepared.lanes.map(\.id), [old.id, current.id])
        XCTAssertEqual(prepared.lanes.last?.outputTokens, 40)
        XCTAssertEqual(prepared.toolActivity?.buckets.reduce(0) { $0 + $1.callCount }, 2)
        XCTAssertEqual(prepared.toolActivity?.resultMarkers.map(\.id), [result.id])
        XCTAssertEqual(prepared.requestTools[old.id]?.buckets.reduce(0) { $0 + $1.callCount }, 1)
        XCTAssertEqual(
            prepared.requestTools[current.id]?.buckets.reduce(0) { $0 + $1.callCount }, 1)
        XCTAssertNotNil(prepared.requestRails.assignments[old.id])
        XCTAssertNil(prepared.requestTools[future.id])
    }

    func testArchivedThroughputAndGPUAreAvailableInsideAFrozenOlderWindow() throws {
        let archived = ArchivedChartBucket(
            start: origin, end: origin.addingTimeInterval(59), value: 30, count: 118)
        let recent = TimeSeriesPoint(timestamp: origin.addingTimeInterval(120), value: 80)
        let snapshot = ChartPresentationSnapshot(
            timestamp: recent.timestamp, throughput: [recent], systemGPU: [recent],
            archive: ArchivedChartHistory(throughput: [[archived]], systemGPU: [[archived]]))
        let prepared = DashboardChartPreparation().histories(
            snapshot: snapshot, duration: 60, windowEnd: origin.addingTimeInterval(60))

        XCTAssertEqual(prepared.throughput.buckets.count, 1)
        XCTAssertEqual(prepared.gpu.buckets.count, 1)
        XCTAssertEqual(prepared.throughput.bucket(at: origin.addingTimeInterval(30))?.value, 30)
        XCTAssertEqual(prepared.gpu.bucket(at: origin.addingTimeInterval(30))?.value, 30)
        XCTAssertEqual(try XCTUnwrap(prepared.throughput.buckets.first).count, 118)
        XCTAssertNil(prepared.throughput.current)
    }

    func testExplicitFrozenEndpointSuppressesEffectsEvenAtLatestPublication() throws {
        var receipt = origin
        let cache = DashboardChartPreparation(clock: { receipt })
        _ = cache.histories(snapshot: ChartPresentationSnapshot(timestamp: origin), duration: 60)
        let request = RequestLane(id: UUID(), startedAt: origin.addingTimeInterval(1))
        let snapshot = ChartPresentationSnapshot(
            timestamp: origin.addingTimeInterval(1), requestLanes: [request])
        receipt = origin.addingTimeInterval(10)
        let live = cache.histories(snapshot: snapshot, duration: 60)
        XCTAssertEqual(try XCTUnwrap(live.requestRails.events.first).kind, .arrival)

        let frozen = cache.histories(
            snapshot: snapshot, duration: 60, windowEnd: snapshot.timestamp)
        XCTAssertFalse(frozen === live)
        XCTAssertTrue(frozen.requestRails.events.isEmpty)
        XCTAssertEqual(frozen.requestRails.assignments, live.requestRails.assignments)

        let nextSnapshot = ChartPresentationSnapshot(
            timestamp: origin.addingTimeInterval(2), requestLanes: [request])
        let next = cache.histories(
            snapshot: nextSnapshot, duration: 60, windowEnd: snapshot.timestamp)
        XCTAssertTrue(next.requestRails.events.isEmpty)
        XCTAssertEqual(next.windowEnd, frozen.windowEnd)
    }

    func testBusyHistoryKeepsLongRunningRequestsWhenFinishedLanesAreCapped() {
        let running = RequestLane(id: UUID(), startedAt: origin)
        let completed = (1...260).map { index in
            let start = origin.addingTimeInterval(Double(index))
            return RequestLane(
                id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(0.5), terminal: true
            )
        }
        let snapshot = ChartPresentationSnapshot(
            timestamp: origin.addingTimeInterval(300), requestLanes: [running],
            historicalRequestLanes: completed)
        let prepared = DashboardChartPreparation().histories(snapshot: snapshot, duration: 600)

        XCTAssertEqual(prepared.lanes.count, 256)
        XCTAssertTrue(prepared.lanes.contains { $0.id == running.id })
        XCTAssertTrue(prepared.lanes.contains { $0.id == completed.last?.id })
        XCTAssertEqual(prepared.omittedRequestCount, 5)
        XCTAssertNotNil(prepared.requestRails.assignments[running.id])
    }
}
