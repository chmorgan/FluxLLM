import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class AutomaticHistoryStoreTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testCollectedAutomaticWidthIsHeldUntilTheNextChartPublication() {
        let (store, clock, epoch) = makeStore()
        applyNative(store, epoch: epoch, at: 0, running: 1, queued: 0)
        for offset in stride(from: 0.5, through: 23.5, by: 0.5) {
            collectNative(store, clock: clock, epoch: epoch, at: offset)
        }
        let held = store.chartPresentation
        XCTAssertEqual(held.timestamp, date(23.5))
        XCTAssertEqual(held.automaticHistoryDuration, 30)

        collectNative(store, clock: clock, epoch: epoch, at: 24)
        XCTAssertEqual(store.visibleHistoryDuration, 60)
        XCTAssertEqual(store.chartHistoryDuration, 30)
        XCTAssertEqual(store.chartPresentation, held)

        store.historyRange = .fiveMinutes
        XCTAssertEqual(store.chartHistoryDuration, 300)
        store.historyRange = .automatic
        XCTAssertEqual(store.chartHistoryDuration, 30)
        collectNative(store, clock: clock, epoch: epoch, at: 24.5)
        XCTAssertEqual(store.chartHistoryDuration, 60)
        XCTAssertEqual(store.chartPresentation.automaticHistoryDuration, 60)
    }

    func testQueuedRequestsExpandAutoDuringLoadingWithoutAThroughputMeasurement() {
        let (store, clock, epoch) = makeStore()
        for offset in stride(from: 0.0, through: 96, by: 0.5) {
            clock.now = date(offset)
            applyNative(
                store, epoch: epoch, at: offset, running: 0, queued: 1,
                rate: nil, ready: false)
            store.sample(at: clock.now)
        }

        XCTAssertTrue(store.isBackendActive)
        XCTAssertEqual(store.currentTPS, 0)
        XCTAssertEqual(store.visibleHistoryDuration, 300)
        XCTAssertEqual(store.chartPresentation.automaticHistoryDuration, 300)
        XCTAssertFalse(store.chartPresentation.throughput.contains(where: \.isAvailable))
    }

    func testUnknownAndIdleCountsDoNotTurnRetainedRatesIntoAnActivityEpisode() {
        let (store, clock, epoch) = makeStore()
        for offset in stride(from: 0.0, through: 100, by: 0.5) {
            clock.now = date(offset)
            applyNative(
                store, epoch: epoch, at: offset,
                running: offset < 40 ? nil : 0,
                queued: offset < 40 ? nil : 0, rate: 900)
            store.sample(at: clock.now)
        }
        XCTAssertGreaterThan(store.historyAge, 30)
        XCTAssertEqual(store.chartHistoryDuration, 30)

        for offset in stride(from: 100.5, through: 125, by: 0.5) {
            collectNative(store, clock: clock, epoch: epoch, at: offset, rate: 0)
        }
        XCTAssertEqual(store.chartHistoryDuration, 60)

        for offset in stride(from: 125.5, through: 160, by: 0.5) {
            clock.now = date(offset)
            applyNative(store, epoch: epoch, at: offset, running: nil, queued: nil, rate: 900)
            store.sample(at: clock.now)
        }
        XCTAssertEqual(store.chartHistoryDuration, 60)
        XCTAssertEqual(store.backendActivity, .unknown)
    }

    func testRejectedSamplesCannotChangeAutoAndAStaleOutageStartsAFreshEpisode() {
        let (store, clock, epoch) = makeStore()
        for offset in stride(from: 0.0, through: 49, by: 0.5) {
            collectNative(store, clock: clock, epoch: epoch, at: offset)
        }
        XCTAssertEqual(store.chartHistoryDuration, 120)

        applyNative(store, epoch: UUID(), at: 500, running: 0, queued: 0)
        applyNative(store, epoch: epoch, at: 48, running: 0, queued: 0)
        clock.now = date(49.5)
        store.sample(at: clock.now)
        XCTAssertTrue(store.isBackendActive)
        XCTAssertEqual(store.visibleHistoryDuration, 120)

        for offset in stride(from: 50.0, through: 119.5, by: 0.5) {
            clock.now = date(offset)
            store.sample(at: clock.now)
        }
        XCTAssertEqual(store.backendActivity, .unknown)
        XCTAssertEqual(store.chartHistoryDuration, 120)
        collectNative(store, clock: clock, epoch: epoch, at: 120)
        XCTAssertEqual(store.chartHistoryDuration, 30)
    }

    func testSubsecondProxyLifecyclesAffectAutoEvenWhenEveryCollectionTickIsIdle() {
        let (store, clock, epoch) = makeStore(kind: .ollama)
        store.updateConnection(.ready, at: origin)
        completeRequest(store, clock: clock, epoch: epoch, start: 0, end: 0.1, tokens: 10)
        for offset in stride(from: 0.5, through: 23.5, by: 0.5) {
            collectProxy(store, clock: clock, at: offset)
        }
        XCTAssertEqual(store.chartHistoryDuration, 30)

        completeRequest(store, clock: clock, epoch: epoch, start: 24, end: 24.1, tokens: 20)
        XCTAssertFalse(store.isBackendActive)
        XCTAssertEqual(store.visibleHistoryDuration, 60)
        collectProxy(store, clock: clock, at: 24.5)
        XCTAssertEqual(store.chartHistoryDuration, 60)

        for offset in stride(from: 25.0, through: 85, by: 0.5) {
            collectProxy(store, clock: clock, at: offset)
        }
        XCTAssertEqual(store.chartHistoryDuration, 60, "Idle sampling holds the previous zoom")
        completeRequest(store, clock: clock, epoch: epoch, start: 85.1, end: 85.2, tokens: 5)
        XCTAssertEqual(store.visibleHistoryDuration, 30)
        collectProxy(store, clock: clock, at: 85.5)
        XCTAssertEqual(store.chartHistoryDuration, 30)
    }

    func testFinishingTheDashboardOwnerDoesNotHideAnOlderConcurrentRequestFromAuto() {
        let (store, clock, epoch) = makeStore(kind: .ollama)
        store.updateConnection(.ready, at: origin)
        let older = GenerationRequest(startedAt: origin)
        store.apply(.began(older), epoch: epoch)
        clock.now = date(1)
        let newer = GenerationRequest(startedAt: clock.now)
        store.apply(.began(newer), epoch: epoch)
        clock.now = date(1.1)
        finish(store, request: newer, epoch: epoch, at: 1.1, tokens: 1)
        XCTAssertEqual(store.activeGeneration?.state, .completed)
        XCTAssertTrue(store.isBackendActive)

        for offset in stride(from: 1.5, through: 60.5, by: 0.5) {
            collectProxy(store, clock: clock, at: offset)
        }
        XCTAssertEqual(store.chartHistoryDuration, 120)
        clock.now = date(60.6)
        finish(store, request: older, epoch: epoch, at: 60.6, tokens: 1)
        XCTAssertFalse(store.isBackendActive)
        collectProxy(store, clock: clock, at: 61.5)
        XCTAssertEqual(store.chartHistoryDuration, 120)
    }

    func testAutomaticDemandNavigationAndSelectedTotalsShareTheHeldInterval() {
        let (store, clock, epoch) = makeStore(kind: .ollama)
        store.updateConnection(.ready, at: origin)
        store.usageScope = .selectedPeriod
        store.setChartPresentationDemand(true, consumer: .dashboard)
        completeRequest(store, clock: clock, epoch: epoch, start: 0, end: 0.1, tokens: 10)
        for offset in stride(from: 0.5, through: 23.5, by: 0.5) {
            collectProxy(store, clock: clock, at: offset)
        }
        let held = store.chartPresentation
        completeRequest(store, clock: clock, epoch: epoch, start: 24, end: 24.1, tokens: 20)
        XCTAssertEqual(store.visibleHistoryDuration, 60)
        XCTAssertEqual(store.chartPresentation, held)
        XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 10)

        collectProxy(store, clock: clock, at: 24.5)
        for offset in stride(from: 25.0, through: 34.5, by: 0.5) {
            collectProxy(store, clock: clock, at: offset)
        }
        completeRequest(store, clock: clock, epoch: epoch, start: 35, end: 35.1, tokens: 5)
        collectProxy(store, clock: clock, at: 35.5)
        let snapshot = store.chartPresentation
        let navigation = HistoryNavigation()
        let interval = navigation.interval(
            now: snapshot.timestamp, historyAge: store.chartHistoryAge,
            automaticDuration: snapshot.automaticHistoryDuration)
        XCTAssertEqual(interval.duration, 60)
        XCTAssertEqual(store.dashboardScalarPresentation.selectedInterval, interval)
        XCTAssertEqual(store.dashboardScalarPresentation.usage, store.usageSummary(in: interval))
        XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 35)
        XCTAssertEqual(store.dashboardScalarPresentation.usage.requests, 3)
        XCTAssertEqual(Set(snapshot.historicalRequestLanes.map(\.id)).count, 3)
        let charts = PreparedDashboardCharts(
            snapshot: snapshot, duration: interval.duration, windowEnd: interval.end, isLive: true)
        XCTAssertEqual(charts.duration, interval.duration)
        XCTAssertEqual(charts.windowEnd, interval.end)
        XCTAssertEqual(charts.lanes.count, 3)
        XCTAssertEqual(
            ChartPresentationViewport.historyRange.interval(
                at: snapshot.timestamp, range: .automatic, historyAge: store.chartHistoryAge,
                automaticDuration: snapshot.automaticHistoryDuration), interval)
    }

    func testReplacingTheGPUTracePreservesTheAutomaticWidthAndPublicationTime() {
        let (store, clock, epoch) = makeStore()
        for offset in stride(from: 0.0, through: 48, by: 0.5) {
            clock.now = date(offset)
            applyNative(store, epoch: epoch, at: offset, running: 1, queued: 0)
            store.applyGPUSample(
                GPUActivitySample(
                    timestamp: clock.now, activityPercent: 20, source: "First GPU", scope: .system),
                epoch: epoch)
            store.sample(at: clock.now)
        }
        let held = store.chartPresentation
        XCTAssertEqual(held.automaticHistoryDuration, 120)
        XCTAssertFalse(held.systemGPU.isEmpty)

        store.applyGPUSample(
            GPUActivitySample(
                timestamp: date(48.25), activityPercent: 40, source: "Second GPU", scope: .system),
            epoch: epoch)
        XCTAssertEqual(store.chartPresentation.automaticHistoryDuration, 120)
        XCTAssertEqual(store.chartPresentation.timestamp, held.timestamp)
        XCTAssertEqual(store.chartPresentation.throughput, held.throughput)
        XCTAssertTrue(store.chartPresentation.systemGPU.isEmpty)
    }

    func testArchivedAgeAndSessionReconnectsDoNotRestoreThePreviousAutomaticZoom() {
        let archive = ChartHistoryArchive(now: origin)
        let point = TimeSeriesPoint(timestamp: date(-3_600), value: 15)
        archive.record(
            source: "same", at: point.timestamp, throughput: point, gpu: point,
            toolObservation: point)
        let clock = TestClock(now: origin)
        let store = MetricsStore(clock: { clock.now }, chartArchive: archive)
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch, sourceID: "same")
        XCTAssertEqual(store.chartHistoryDuration, 30)
        XCTAssertFalse(store.chartPresentation.archive.throughput.isEmpty)
        for offset in stride(from: 0.0, through: 49, by: 0.5) {
            collectNative(store, clock: clock, epoch: epoch, at: offset)
        }
        XCTAssertEqual(store.chartHistoryDuration, 120)

        clock.now = date(49.25)
        let nextEpoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: nextEpoch, sourceID: "same")
        XCTAssertEqual(store.visibleHistoryDuration, 30)
        XCTAssertEqual(store.chartHistoryDuration, 30)
        XCTAssertFalse(store.chartPresentation.archive.throughput.isEmpty)
        applyNative(store, epoch: epoch, at: 500, running: 1, queued: 0)
        collectNative(store, clock: clock, epoch: nextEpoch, at: 49.5)
        XCTAssertEqual(store.chartHistoryDuration, 30)

        clock.now = date(50)
        store.beginBackendSession(kind: .vllm, epoch: UUID(), sourceID: "other")
        XCTAssertEqual(store.chartHistoryDuration, 30)
        XCTAssertTrue(store.chartPresentation.archive.throughput.isEmpty)
    }

    func testHiddenCollectionContinuesAutoAndReopeningPublishesItsCurrentWidth() {
        let (store, clock, epoch) = makeStore()
        store.usageScope = .selectedPeriod
        store.setChartPresentationDemand(false, consumer: .dashboard)
        let hiddenID = store.chartPresentation.publicationID
        for offset in stride(from: 0.0, through: 300, by: 0.5) {
            collectNative(store, clock: clock, epoch: epoch, at: offset)
        }
        XCTAssertEqual(store.visibleHistoryDuration, 600)
        XCTAssertEqual(store.chartPresentation.publicationID, hiddenID)
        XCTAssertTrue(store.chartPresentation.throughput.isEmpty)

        store.setChartPresentationDemand(true, consumer: .dashboard)
        XCTAssertEqual(store.chartPresentation.timestamp, date(300))
        XCTAssertEqual(store.chartHistoryDuration, 600)
        XCTAssertEqual(store.chartPresentation.automaticHistoryDuration, 600)
        XCTAssertEqual(store.chartPresentation.throughput, store.tpsHistory)
        XCTAssertEqual(store.dashboardScalarPresentation.selectedInterval?.duration, 600)
    }

    private func makeStore(kind: BackendKind = .vllm) -> (MetricsStore, TestClock, UUID) {
        let clock = TestClock(now: origin)
        let store = MetricsStore(clock: { clock.now })
        let epoch = UUID()
        store.beginBackendSession(kind: kind, epoch: epoch)
        return (store, clock, epoch)
    }

    private func applyNative(
        _ store: MetricsStore, epoch: UUID, at offset: TimeInterval,
        running: Int?, queued: Int?, rate: Double? = 20, ready: Bool = true
    ) {
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: date(offset), isReady: ready, currentTPS: rate,
                runningRequests: running, queuedRequests: queued), epoch: epoch)
    }

    private func collectNative(
        _ store: MetricsStore, clock: TestClock, epoch: UUID, at offset: TimeInterval,
        rate: Double? = 20
    ) {
        clock.now = date(offset)
        applyNative(store, epoch: epoch, at: offset, running: 1, queued: 0, rate: rate)
        store.sample(at: clock.now)
    }

    private func completeRequest(
        _ store: MetricsStore, clock: TestClock, epoch: UUID, start: TimeInterval,
        end: TimeInterval, tokens: Int
    ) {
        clock.now = date(start)
        let request = GenerationRequest(startedAt: clock.now)
        store.apply(.began(request), epoch: epoch)
        clock.now = date(end)
        finish(store, request: request, epoch: epoch, at: end, tokens: tokens)
    }

    private func collectProxy(_ store: MetricsStore, clock: TestClock, at offset: TimeInterval) {
        clock.now = date(offset)
        // Fresh health probes make the absence of open proxy requests known idle.
        store.updateConnection(.ready, at: clock.now)
        store.sample(at: clock.now)
    }

    private func finish(
        _ store: MetricsStore, request: GenerationRequest, epoch: UUID, at offset: TimeInterval,
        tokens: Int
    ) {
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: tokens, isEstimated: false, finished: true,
                    elapsed: date(offset).timeIntervalSince(request.startedAt),
                    timestamp: date(offset))),
            epoch: epoch)
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }

    private final class TestClock {
        var now: Date
        init(now: Date) { self.now = now }
    }
}
