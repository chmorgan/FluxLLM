import Foundation
import Observation
import XCTest

@testable import FluxLLM

private final class ScalarObservationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor
final class DashboardScalarPresentationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testLiveUpdatesKeepExactLedgerWhileOnlySamplingPublishesScalars() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            store.setChartPresentationDemand(true, consumer: .dashboard)
            let older = GenerationRequest(startedAt: date(0))
            let latest = GenerationRequest(startedAt: date(0.001))
            store.apply(.began(older))
            store.apply(.began(latest))
            let changes = observe(store)
            let beforeLiveUpdates = scalarPublications
            for count in 1...40 {
                update(store, request: older.id, tokens: count, at: Double(count) / 200)
                update(store, request: latest.id, tokens: count * 2, at: Double(count) / 200)
            }
            XCTAssertEqual(changes.value, 0, "Live accounting must not invalidate scalar views")
            XCTAssertEqual(scalarPublications, beforeLiveUpdates)
            XCTAssertEqual(store.outputTokens, 80)
            XCTAssertEqual(store.usageSummary(in: allHistory).outputTokens, 120)
            XCTAssertEqual(store.dashboardScalarPresentation.latestResponse?.outputTokens, 0)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 0)

            store.sample(at: date(0.5))
            XCTAssertEqual(changes.value, 1)
            XCTAssertEqual(scalarPublications, beforeLiveUpdates + 1)
            XCTAssertEqual(store.dashboardScalarPresentation.latestResponse?.requestID, latest.id)
            XCTAssertEqual(store.dashboardScalarPresentation.latestResponse?.outputTokens, 80)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 120)
            let unchanged = observe(store)
            let publications = scalarPublications
            store.sample(at: date(0.5))
            XCTAssertEqual(
                unchanged.value, 0, "Equal values must not publish an arbitrary clock tick")
            XCTAssertEqual(scalarPublications, publications)
        }
    }

    func testNormalPresentationWorksWithDiagnosticsDisabledAcrossNativeDemandLifecycle() throws {
        try PerformanceGraphicsDiagnostics.shared.disable()
        defer { try? PerformanceGraphicsDiagnostics.shared.disable() }
        XCTAssertEqual(PerformanceGraphicsDiagnostics.shared.mode, .normal)
        XCTAssertFalse(PerformanceGraphicsDiagnostics.shared.isEnabled)
        let store = MetricsStore(clock: { self.origin })
        // Mirrors MenuBarController.start before sampling/monitoring begins.
        store.setChartPresentationDemand(false, consumer: .popover)
        store.setChartPresentationDemand(false, consumer: .dashboard)
        let first = GenerationRequest(startedAt: origin)
        store.apply(.began(first))
        update(store, request: first.id, tokens: 12, at: 0.1)
        store.sample(at: date(0.5))
        XCTAssertEqual(store.dashboardScalarPresentation, .empty)
        XCTAssertEqual(store.usageSummary(in: allHistory).outputTokens, 12)

        store.setChartPresentationDemand(true, consumer: .dashboard)
        XCTAssertEqual(store.dashboardScalarPresentation.latestResponse?.outputTokens, 12)
        XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 12)
        let changes = observe(store)
        update(store, request: first.id, tokens: 24, at: 0.6)
        XCTAssertEqual(changes.value, 0)
        XCTAssertEqual(store.outputTokens, 24)
        XCTAssertEqual(store.dashboardScalarPresentation.latestResponse?.outputTokens, 12)
        store.sample(at: date(1))
        XCTAssertEqual(changes.value, 1)
        XCTAssertEqual(store.dashboardScalarPresentation.latestResponse?.outputTokens, 24)
        finish(store, request: first.id, tokens: 25, at: 1.2)
        XCTAssertEqual(
            store.dashboardScalarPresentation.latestResponse,
            .init(
                requestID: first.id, outputTokens: 25, outputIsEstimated: false))
        XCTAssertEqual(store.dashboardScalarPresentation.usage.activeRequests, 0)

        store.setChartPresentationDemand(false, consumer: .dashboard)
        XCTAssertEqual(store.dashboardScalarPresentation, .empty)
        let next = GenerationRequest(startedAt: date(1.3))
        store.apply(.began(next))
        update(store, request: next.id, tokens: 7, at: 1.4)
        store.sample(at: date(1.5))
        XCTAssertEqual(store.dashboardScalarPresentation, .empty)
        store.setChartPresentationDemand(true, consumer: .popover)
        XCTAssertEqual(store.dashboardScalarPresentation.latestResponse?.requestID, next.id)
        XCTAssertEqual(store.dashboardScalarPresentation.latestResponse?.outputTokens, 7)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 32)
        XCTAssertEqual(store.dashboardScalarPresentation.usage.activeRequests, 1)
        store.apply(.failed(requestID: next.id, message: "interrupted"))
        XCTAssertEqual(store.dashboardScalarPresentation.usage.activeRequests, 0)
        XCTAssertEqual(store.generationError, "interrupted")
        XCTAssertEqual(scalarPublications, 0, "Production publication must not enable diagnostics")
        XCTAssertFalse(PerformanceGraphicsDiagnostics.shared.isEnabled)
    }

    func testInjectedHistoryHasAnInitialScalarSnapshotWithoutSamplingOrQueryCaches() throws {
        try PerformanceGraphicsDiagnostics.shared.disable()
        defer { try? PerformanceGraphicsDiagnostics.shared.disable() }
        let history = UsageHistory(now: origin)
        let request = GenerationRequest(startedAt: date(-2))
        history.apply(.began(request), source: BackendKind.ollama.rawValue, at: date(-2))
        history.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 63, promptTokens: 8, isEstimated: false,
                    finished: true, timestamp: date(-1))), source: BackendKind.ollama.rawValue,
            at: date(-1))
        XCTAssertEqual(history.cachedQueryEntryCount, 0)
        let store = MetricsStore(clock: { self.origin }, usageHistory: history)
        XCTAssertEqual(store.dashboardScalarPresentation.usage.requests, 1)
        XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 63)
        XCTAssertEqual(store.dashboardScalarPresentation.usage.inputTokens, 8)
        XCTAssertNil(store.dashboardScalarPresentation.latestResponse)
        XCTAssertEqual(history.cachedQueryEntryCount, 0)
        XCTAssertEqual(scalarPublications, 0)
        XCTAssertFalse(PerformanceGraphicsDiagnostics.shared.isEnabled)
    }

    func testToolBurstKeepsDiscreteEventsExactWithoutPublishingEveryCounterChange() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            let request = GenerationRequest(startedAt: origin)
            store.apply(.began(request))
            let changes = observe(store)
            let before = scalarPublications
            for index in 0..<40 {
                let timestamp = date(Double(index) / 200)
                store.apply(
                    .toolActivity(
                        requestID: request.id,
                        events: [
                            ToolActivityEvent(
                                kind: .call, callID: "call-\(index)", timestamp: timestamp),
                            ToolActivityEvent(
                                kind: .resultSubmission, callID: "call-\(index)",
                                timestamp: timestamp),
                        ]))
            }
            XCTAssertEqual(changes.value, 0)
            XCTAssertEqual(scalarPublications, before)
            XCTAssertEqual(store.toolActivityEvents.count, 80)
            XCTAssertEqual(store.usageSummary(in: allHistory).toolCalls, 40)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.toolCalls, 0)
            store.sample(at: date(0.5))
            XCTAssertEqual(changes.value, 1)
            XCTAssertEqual(scalarPublications, before + 1)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.toolCalls, 40)
        }
    }

    func testEveryNonOwningTerminalImmediatelyPublishesAggregateUsage() throws {
        try withNormal {
            for terminal in ["completed", "snapshot-error", "failed", "cancelled"] {
                let store = MetricsStore(clock: { self.origin })
                let older = GenerationRequest(startedAt: date(0))
                let latest = GenerationRequest(startedAt: date(0.01))
                store.apply(.began(older))
                store.apply(.began(latest))
                update(store, request: older.id, tokens: 10, at: 0.1)
                update(store, request: latest.id, tokens: 20, at: 0.1)
                store.sample(at: date(0.5))
                let changes = observe(store)
                switch terminal {
                case "completed", "snapshot-error":
                    store.apply(
                        .updated(
                            requestID: older.id,
                            snapshot: GenerationSnapshot(
                                outputTokens: 7, isEstimated: false,
                                finished: terminal == "completed",
                                error: terminal == "snapshot-error" ? "interrupted" : nil,
                                timestamp: date(0.75))))
                case "failed":
                    store.apply(.failed(requestID: older.id, message: "interrupted"))
                default:
                    store.apply(.cancelled(requestID: older.id))
                }
                XCTAssertEqual(changes.value, 1, terminal)
                XCTAssertEqual(store.dashboardScalarPresentation.usage.activeRequests, 1, terminal)
                XCTAssertEqual(
                    store.dashboardScalarPresentation.usage,
                    store.usageSummary(in: allHistory), terminal)
                XCTAssertEqual(
                    store.dashboardScalarPresentation.latestResponse?.requestID, latest.id)
                XCTAssertEqual(store.dashboardScalarPresentation.latestResponse?.outputTokens, 20)
            }
        }
    }

    func testLatestResponseCompletionAndNextBeginPublishWithoutSampling() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            let request = GenerationRequest(startedAt: origin)
            store.apply(.began(request))
            update(store, request: request.id, tokens: 9, at: 0.1)
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: 13, promptTokens: 4, isEstimated: false,
                        finished: true, timestamp: date(0.2))))
            XCTAssertEqual(
                store.dashboardScalarPresentation.latestResponse,
                .init(
                    requestID: request.id, outputTokens: 13, outputIsEstimated: false))
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 13)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.inputTokens, 4)
            let next = GenerationRequest(startedAt: date(0.3))
            store.apply(.began(next))
            XCTAssertEqual(
                store.dashboardScalarPresentation.latestResponse,
                .init(
                    requestID: next.id, outputTokens: 0, outputIsEstimated: true))
        }
    }

    func testSelectedUsageUsesHeldChartEndpointRatherThanFasterScalarClock() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            store.historyRange = .minute
            store.usageScope = .selectedPeriod
            store.sample(at: date(10))
            let request = GenerationRequest(startedAt: date(9))
            store.apply(.began(request))
            finish(store, request: request.id, tokens: 13, at: 10.25)
            let displayed = HistoryNavigation(preset: .minute).interval(
                now: store.chartPresentation.timestamp, historyAge: store.chartHistoryAge)
            XCTAssertEqual(store.dashboardScalarPresentation.selectedInterval, displayed)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.requests, 0)
            store.sample(at: date(10.5))
            XCTAssertEqual(store.chartPresentation.timestamp, date(10))
            XCTAssertEqual(store.dashboardScalarPresentation.selectedInterval, displayed)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.requests, 0)
            store.sample(at: date(11))
            XCTAssertEqual(store.dashboardScalarPresentation.usage.requests, 1)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 13)
            XCTAssertEqual(store.dashboardScalarPresentation.selectedInterval?.end, date(11))
        }
    }

    func testHiddenCollectionReleasesCachesAndReopenUsesPinnedDashboardInterval() throws {
        try withNormal {
            let history = UsageHistory(now: origin)
            let store = MetricsStore(clock: { self.origin }, usageHistory: history)
            store.setChartPresentationDemand(true, consumer: .dashboard)
            store.usageScope = .selectedPeriod
            let first = GenerationRequest(startedAt: date(1))
            store.apply(.began(first))
            finish(store, request: first.id, tokens: 5, at: 2)
            store.sample(at: date(10))
            XCTAssertGreaterThan(history.cachedQueryEntryCount, 0)
            store.setChartPresentationDemand(false, consumer: .dashboard)
            XCTAssertEqual(history.cachedQueryEntryCount, 0)
            XCTAssertEqual(store.dashboardScalarPresentation, .empty)

            let later = GenerationRequest(startedAt: date(18))
            store.apply(.began(later))
            update(store, request: later.id, tokens: 9, at: 18.5)
            finish(store, request: later.id, tokens: 17, at: 19)
            store.sample(at: date(21))
            let pinned = DateInterval(start: date(15), end: date(20))
            store.setChartPresentationViewport(.fixed(pinned), consumer: .dashboard)
            store.usageScope = .today
            store.usageScope = .selectedPeriod
            XCTAssertEqual(
                history.cachedQueryEntryCount, 0, "Hidden scalar work must not rebuild query arrays"
            )
            XCTAssertEqual(store.chartPresentation.timestamp, date(10))
            store.setChartPresentationDemand(true, consumer: .dashboard)
            XCTAssertEqual(store.chartPresentation.timestamp, date(21))
            XCTAssertEqual(store.dashboardScalarPresentation.selectedInterval, pinned)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 17)
            XCTAssertEqual(store.dashboardScalarPresentation.latestResponse?.requestID, later.id)
            store.setChartPresentationDemand(true, consumer: .popover)
            XCTAssertEqual(store.dashboardScalarPresentation.selectedInterval, pinned)
            XCTAssertEqual(store.dashboardScalarPresentation.usage, store.usageSummary(in: pinned))
        }
    }

    func testScopeAndPresetChangesPublishExactTotalsWithoutWaitingForSample() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            let older = GenerationRequest(startedAt: date(1))
            let recent = GenerationRequest(startedAt: date(90))
            store.apply(.began(older))
            finish(store, request: older.id, tokens: 5, at: 2)
            store.apply(.began(recent))
            finish(store, request: recent.id, tokens: 17, at: 91)
            store.sample(at: date(100))
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 22)
            store.historyRange = .minute
            store.usageScope = .selectedPeriod
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 17)
            store.historyRange = .hour
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 22)
            XCTAssertEqual(
                store.dashboardScalarPresentation.selectedInterval,
                HistoryNavigation(preset: .hour).interval(
                    now: store.chartPresentation.timestamp, historyAge: store.chartHistoryAge))
            store.usageScope = .sinceLaunch
            XCTAssertNil(store.dashboardScalarPresentation.selectedInterval)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 22)
        }
    }

    func testTodayCrossesMidnightWhileSelectedChartTimeRemainsHeld() throws {
        try withNormal {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let midnight = calendar.startOfDay(for: origin).addingTimeInterval(86_400)
            let start = midnight.addingTimeInterval(-0.25)
            let store = MetricsStore(
                clock: { start }, usageHistory: UsageHistory(now: start, calendar: calendar))
            store.usageScope = .today
            store.sample(at: start)
            let request = GenerationRequest(startedAt: midnight.addingTimeInterval(-10))
            store.apply(.began(request))
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: 30, isEstimated: false, finished: true,
                        timestamp: midnight.addingTimeInterval(-0.1))))
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 30)
            store.sample(at: midnight.addingTimeInterval(0.25))
            XCTAssertEqual(store.chartPresentation.timestamp, start)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 0)
        }
    }

    func testSourceResetPublishesClearedIdentityAndRejectsStaleEpoch() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            let firstEpoch = UUID()
            store.beginBackendSession(kind: .ollama, epoch: firstEpoch, sourceID: "first")
            let request = GenerationRequest(startedAt: origin)
            store.apply(.began(request), epoch: firstEpoch)
            finish(store, request: request.id, tokens: 13, at: 0.2)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 13)
            store.beginBackendSession(kind: .ollama, epoch: UUID(), sourceID: "second")
            XCTAssertNil(store.dashboardScalarPresentation.latestResponse)
            XCTAssertEqual(store.dashboardScalarPresentation.usage.requests, 0)
            let changes = observe(store)
            store.apply(.began(GenerationRequest(startedAt: date(1))), epoch: firstEpoch)
            XCTAssertEqual(changes.value, 0)
            XCTAssertNil(store.dashboardScalarPresentation.latestResponse)
        }
    }

    private var allHistory: DateInterval { DateInterval(start: date(-86_400), end: date(86_400)) }
    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }

    private func update(_ store: MetricsStore, request: UUID, tokens: Int, at offset: TimeInterval)
    {
        store.apply(
            .updated(
                requestID: request,
                snapshot: GenerationSnapshot(
                    outputTokens: tokens, liveTPS: 20, elapsed: offset, timestamp: date(offset))))
    }

    private func finish(_ store: MetricsStore, request: UUID, tokens: Int, at offset: TimeInterval)
    {
        store.apply(
            .updated(
                requestID: request,
                snapshot: GenerationSnapshot(
                    outputTokens: tokens, isEstimated: false, finished: true,
                    timestamp: date(offset))))
    }

    private func observe(_ store: MetricsStore) -> ScalarObservationCount {
        let changes = ScalarObservationCount()
        withObservationTracking {
            _ = store.dashboardScalarPresentation
            _ = store.dashboardScalarPresentation.historyPersistenceError
        } onChange: {
            changes.increment()
        }
        return changes
    }

    private var scalarPublications: UInt64 {
        PerformanceGraphicsDiagnostics.shared.snapshot()["scalar_presentation_publications"]
            as? UInt64 ?? 0
    }

    private func withNormal(_ body: () throws -> Void) throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .normal)
        defer { try? PerformanceGraphicsDiagnostics.shared.disable() }
        try body()
    }
}
