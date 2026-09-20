import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class ChartPresentationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testHalfSecondPeaksAndZerosAppearTogetherAtNextPublication() {
        let (store, epoch) = makeStore()
        collect(store, epoch: epoch, offset: 0, rate: 20, gpu: 30)
        let initial = store.chartPresentation
        XCTAssertEqual(initial.timestamp, origin)
        XCTAssertEqual(initial.throughput.map(\.value), [20])
        XCTAssertEqual(initial.systemGPU.map(\.value), [30])

        collect(store, epoch: epoch, offset: 0.5, rate: 999, gpu: 100)
        XCTAssertEqual(store.tpsHistory.map(\.value), [20, 999])
        XCTAssertEqual(store.systemGPUHistory.map(\.value), [30, 100])
        XCTAssertEqual(store.chartPresentation, initial)

        collect(store, epoch: epoch, offset: 1, rate: 0, gpu: 0)
        let published = store.chartPresentation
        XCTAssertEqual(published.timestamp, date(1))
        XCTAssertEqual(published.throughput, store.tpsHistory)
        XCTAssertEqual(published.systemGPU, store.systemGPUHistory)
        XCTAssertEqual(published.throughput.map(\.value), [20, 999, 0])
        XCTAssertEqual(published.systemGPU.map(\.value), [30, 100, 0])
        XCTAssertTrue(published.throughput.allSatisfy(\.isAvailable))
        XCTAssertTrue(published.systemGPU.allSatisfy(\.isAvailable))
    }

    func testMissingHalfSecondReadingRemainsAGapRatherThanBeingSmoothedAway() {
        let (store, epoch) = makeStore()
        collect(store, epoch: epoch, offset: 0, rate: 20, gpu: 30)
        let initial = store.chartPresentation
        collect(store, epoch: epoch, offset: 0.5, rate: nil, gpu: nil)
        XCTAssertEqual(store.chartPresentation, initial)
        collect(store, epoch: epoch, offset: 1, rate: 40, gpu: 50)

        XCTAssertEqual(store.chartPresentation.throughput.map(\.isAvailable), [true, false, true])
        XCTAssertEqual(store.chartPresentation.systemGPU.map(\.isAvailable), [true, false, true])
        XCTAssertEqual(
            store.chartPresentation.throughput.map(\.timestamp), [date(0), date(0.5), date(1)])
        XCTAssertEqual(
            store.chartPresentation.systemGPU.map(\.timestamp),
            store.chartPresentation.throughput.map(\.timestamp))
    }

    func testRepeatedAndOlderTimestampsCannotBypassPublicationCadence() {
        let (store, epoch) = makeStore()
        collect(store, epoch: epoch, offset: 0, rate: 20, gpu: 30)
        let initial = store.chartPresentation
        collect(store, epoch: epoch, offset: 0, rate: 90, gpu: 80)
        XCTAssertEqual(store.tpsHistory.map(\.value), [90])
        XCTAssertEqual(store.systemGPUHistory.map(\.value), [80])
        XCTAssertEqual(store.chartPresentation, initial)

        collect(store, epoch: epoch, offset: -1, rate: 1, gpu: 2)
        XCTAssertEqual(store.sampleDate, origin)
        XCTAssertEqual(store.tpsHistory.map(\.value), [90])
        XCTAssertEqual(store.systemGPUHistory.map(\.value), [80])
        XCTAssertEqual(store.chartPresentation, initial)

        collect(store, epoch: epoch, offset: 0.5, rate: 40, gpu: 50)
        collect(store, epoch: epoch, offset: 0.5, rate: 60, gpu: 70)
        XCTAssertEqual(store.chartPresentation, initial)
        collect(store, epoch: epoch, offset: 1, rate: 10, gpu: 20)
        XCTAssertEqual(store.chartPresentation.throughput.map(\.value), [90, 60, 10])
        XCTAssertEqual(store.chartPresentation.systemGPU.map(\.value), [80, 70, 20])
    }

    func testSleepAndExpiredTelemetryProduceGapsAndHistoryStillAgesOut() {
        let (store, epoch) = makeStore()
        collect(store, epoch: epoch, offset: 0, rate: 20, gpu: 30)
        store.sample(at: date(7))
        let expired = store.chartPresentation
        XCTAssertEqual(expired.timestamp, date(7))
        XCTAssertEqual(expired.throughput.map(\.timestamp), [date(0), date(0.5), date(7)])
        XCTAssertEqual(expired.throughput.map(\.isAvailable), [true, false, false])
        XCTAssertEqual(expired.systemGPU.map(\.isAvailable), [true, false, false])

        collect(store, epoch: epoch, offset: 7.5, rate: 40, gpu: 50)
        XCTAssertEqual(store.chartPresentation, expired)
        collect(store, epoch: epoch, offset: 8, rate: 45, gpu: 55)
        XCTAssertEqual(store.chartPresentation.throughput.suffix(2).map(\.value), [40, 45])
        XCTAssertEqual(store.chartPresentation.systemGPU.suffix(2).map(\.value), [50, 55])

        store.sample(at: date(MetricsStore.chartWindow + 9))
        XCTAssertEqual(store.chartPresentation.throughput.count, 1)
        XCTAssertEqual(store.chartPresentation.systemGPU.count, 1)
        XCTAssertFalse(store.chartPresentation.throughput[0].isAvailable)
        XCTAssertFalse(store.chartPresentation.systemGPU[0].isAvailable)
    }

    func testDifferentBackendSourceClearsBothTracesAndResetsFirstPublicationDeadline() {
        var now = origin
        let store = MetricsStore(clock: { now })
        let firstEpoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: firstEpoch, sourceID: "first-endpoint")
        collect(store, epoch: firstEpoch, offset: 0, rate: 20, gpu: 30)

        now = date(0.25)
        let nextEpoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: nextEpoch, sourceID: "next-endpoint")
        XCTAssertEqual(store.chartPresentation, ChartPresentationSnapshot(timestamp: now))
        XCTAssertTrue(store.tpsHistory.isEmpty)
        XCTAssertTrue(store.systemGPUHistory.isEmpty)

        store.applyBackendSample(
            BackendSample(kind: .vllm, timestamp: now, currentTPS: 999), epoch: firstEpoch)
        store.applyGPUSample(
            GPUActivitySample(timestamp: now, activityPercent: 100, scope: .system),
            epoch: firstEpoch)
        XCTAssertEqual(store.chartPresentation, ChartPresentationSnapshot(timestamp: now))

        collect(store, epoch: nextEpoch, offset: 0.25, rate: 40, gpu: 50)
        XCTAssertEqual(store.chartPresentation.timestamp, now)
        XCTAssertEqual(store.chartPresentation.throughput.map(\.value), [40])
        XCTAssertEqual(store.chartPresentation.systemGPU.map(\.value), [50])
    }

    func testSameSourceReconnectRetainsArchiveAndResetsFirstPublicationDeadline() {
        var now = origin
        let store = MetricsStore(clock: { now })
        let firstEpoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: firstEpoch, sourceID: "same-endpoint")
        collect(store, epoch: firstEpoch, offset: 0, rate: 20, gpu: 30)

        now = date(0.25)
        let nextEpoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: nextEpoch, sourceID: "same-endpoint")
        let archive = ArchivedChartHistory(
            throughput: [[ArchivedChartBucket(start: origin, end: origin, value: 20, count: 1)]],
            systemGPU: [[ArchivedChartBucket(start: origin, end: origin, value: 30, count: 1)]])
        let restored = ChartPresentationSnapshot(timestamp: now, archive: archive)
        XCTAssertEqual(store.chartPresentation, restored)
        XCTAssertTrue(store.tpsHistory.isEmpty)
        XCTAssertTrue(store.systemGPUHistory.isEmpty)

        store.applyBackendSample(
            BackendSample(kind: .vllm, timestamp: now, currentTPS: 999), epoch: firstEpoch)
        store.applyGPUSample(
            GPUActivitySample(timestamp: now, activityPercent: 100, scope: .system),
            epoch: firstEpoch)
        XCTAssertEqual(store.chartPresentation, restored)

        collect(store, epoch: nextEpoch, offset: 0.25, rate: 40, gpu: 50)
        XCTAssertEqual(store.chartPresentation.timestamp, now)
        XCTAssertEqual(store.chartPresentation.throughput.map(\.value), [40])
        XCTAssertEqual(store.chartPresentation.systemGPU.map(\.value), [50])
        XCTAssertEqual(store.chartPresentation.archive, archive)
    }

    func testGPUSourceAndScopeChangesClearOnlyGPUWithoutAdvancingPublication() {
        let (store, epoch) = makeStore()
        collect(store, epoch: epoch, offset: 0, rate: 20, gpu: 30)
        let initial = store.chartPresentation
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: date(0.25), activityPercent: 40, source: "Another device",
                scope: .system), epoch: epoch)
        XCTAssertTrue(store.chartPresentation.systemGPU.isEmpty)
        XCTAssertEqual(store.chartPresentation.timestamp, initial.timestamp)
        XCTAssertEqual(store.chartPresentation.throughput, initial.throughput)

        collect(store, epoch: epoch, offset: 0.5, rate: 50, gpu: 60, source: "Another device")
        XCTAssertTrue(store.chartPresentation.systemGPU.isEmpty)
        XCTAssertEqual(store.chartPresentation.throughput, initial.throughput)
        collect(store, epoch: epoch, offset: 1, rate: 70, gpu: 80, source: "Another device")
        XCTAssertEqual(store.chartPresentation.systemGPU.map(\.value), [60, 80])
        let beforeScopeChange = store.chartPresentation

        store.applyGPUSample(
            GPUActivitySample(
                timestamp: date(1.25), activityPercent: 140, processIDs: [101],
                source: "Process execution time", scope: .backendProcesses), epoch: epoch)
        XCTAssertTrue(store.chartPresentation.systemGPU.isEmpty)
        XCTAssertEqual(store.chartPresentation.timestamp, beforeScopeChange.timestamp)
        XCTAssertEqual(store.chartPresentation.throughput, beforeScopeChange.throughput)
        store.sample(at: date(1.5))
        XCTAssertEqual(store.chartPresentation.timestamp, date(1))
        store.sample(at: date(2))
        XCTAssertEqual(store.chartPresentation.timestamp, date(2))
        XCTAssertTrue(store.chartPresentation.systemGPU.isEmpty)
        XCTAssertEqual(store.gpuHistory.last?.value, 140)
    }

    func testUnavailableGPUDiagnosticDoesNotErasePreviousDeviceHistory() {
        let (store, epoch) = makeStore()
        collect(store, epoch: epoch, offset: 0, rate: 20, gpu: 30)
        let initial = store.chartPresentation
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: date(0.5), source: "Unavailable diagnostic",
                unavailableReason: "No current counters", scope: .system), epoch: epoch)
        XCTAssertEqual(store.chartPresentation, initial)
        store.sample(at: date(0.5))
        store.sample(at: date(1))
        XCTAssertEqual(store.chartPresentation.systemGPU.map(\.value), [30, 0, 0])
        XCTAssertEqual(store.chartPresentation.systemGPU.map(\.isAvailable), [true, false, false])
    }

    func testRangeChangesAreImmediateButAutomaticGrowthUsesPresentedTime() {
        let (store, epoch) = makeStore()
        collect(store, epoch: epoch, offset: 0, rate: 20, gpu: 30)
        collect(store, epoch: epoch, offset: 60, rate: 20, gpu: 30)
        XCTAssertEqual(store.chartHistoryDuration, 60)
        let held = store.chartPresentation
        collect(store, epoch: epoch, offset: 60.5, rate: 20, gpu: 30)
        XCTAssertEqual(store.visibleHistoryDuration, 300)
        XCTAssertEqual(store.chartHistoryDuration, 60)
        XCTAssertEqual(store.chartPresentation, held)

        store.historyRange = .hour
        XCTAssertEqual(store.chartHistoryDuration, 3_600)
        store.historyRange = .fiveMinutes
        XCTAssertEqual(store.chartHistoryDuration, 300)
        store.historyRange = .automatic
        XCTAssertEqual(store.chartHistoryDuration, 60)
        XCTAssertEqual(store.chartPresentation, held)
        collect(store, epoch: epoch, offset: 61, rate: 20, gpu: 30)
        XCTAssertEqual(store.chartHistoryDuration, 300)
    }

    func testChartUsesRawThroughputEvenWhileNumericEstimateIsSettling() {
        let store = MetricsStore(clock: { self.origin })
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 10, liveTPS: 400, elapsed: 0.5, timestamp: date(0.5))))
        store.sample(at: date(0.5))
        XCTAssertEqual(
            store.displayTPS, 0, "Numeric warmup stays at zero while raw history advances")
        XCTAssertEqual(store.chartPresentation.throughput.map(\.value), [400])
        XCTAssertTrue(store.chartPresentation.throughput[0].isAvailable)
    }

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    private func makeStore() -> (MetricsStore, UUID) {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        return (store, epoch)
    }

    private func collect(
        _ store: MetricsStore, epoch: UUID, offset: TimeInterval, rate: Double?, gpu: Double?,
        source: String = "System device utilization"
    ) {
        let timestamp = date(offset)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: timestamp, currentTPS: rate, runningRequests: 1),
            epoch: epoch)
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: timestamp, activityPercent: gpu, source: source, scope: .system),
            epoch: epoch)
        store.sample(at: timestamp)
    }
}
