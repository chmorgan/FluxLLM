import Foundation
import Observation
import XCTest

@testable import FluxLLM

private final class LiveScalarObservationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor
final class DashboardLiveScalarsTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testEveryProjectedValueMatchesLegacyPresentationAcrossBackendTransitions() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            try assertLegacyValues(store)
            store.updateConnection(.needsConfiguration)
            try assertLegacyValues(store)

            for kind in [BackendKind.vllm, .rapidMLX, .llamaCpp] {
                let epoch = UUID()
                store.beginBackendSession(kind: kind, epoch: epoch)
                try assertLegacyValues(store)
                store.applyBackendSample(
                    BackendSample(
                        kind: kind, timestamp: date(0), model: "Native model",
                        currentTPS: 12.34, runningRequests: 2, queuedRequests: 1,
                        outputTokens: 1234, promptTokens: 5678), epoch: epoch)
                store.sample(at: date(0))
                try assertLegacyValues(store)
                store.applyBackendSample(
                    BackendSample(
                        kind: kind, timestamp: date(0.5), model: "",
                        currentTPS: 0, basis: .serverReportedAverage,
                        runningRequests: 0, queuedRequests: 0,
                        outputTokens: -1, promptTokens: -1), epoch: epoch)
                try assertLegacyValues(store)
                // Readiness failure still exposes direct activity evidence,
                // while retained rate/count details follow their legacy rules.
                store.applyBackendSample(
                    BackendSample(
                        kind: kind, timestamp: date(1), isReady: false,
                        runningRequests: 3, queuedRequests: nil), epoch: epoch)
                try assertLegacyValues(store)
                store.updateConnection(.unavailable, at: date(7))
                try assertLegacyValues(store)
            }

            let epoch = UUID()
            store.beginBackendSession(kind: .ollama, epoch: epoch)
            store.applyBackendSample(
                BackendSample(
                    kind: .ollama, timestamp: origin, model: "Resident model"), epoch: epoch)
            try assertLegacyValues(store)
            let request = GenerationRequest(model: "Request model", startedAt: origin)
            store.apply(.began(request), epoch: epoch)
            try assertLegacyValues(store)
            update(store, request: request.id, tokens: 17, at: 0.2)
            try assertLegacyValues(store)
            store.sample(at: date(0.5))
            try assertLegacyValues(store)
            finish(store, request: request.id, tokens: 13, at: 0.75)
            try assertLegacyValues(store)
            for scope in [UsageScope.today, .selectedPeriod, .sinceLaunch] {
                store.usageScope = scope
                try assertLegacyValues(store)
            }
        }
    }

    func testTimestampOnlyGPUUpdatesDoNotInvalidateDisplayedValueOrHelp() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            let epoch = UUID()
            store.beginBackendSession(kind: .ollama, epoch: epoch)
            store.applyGPUSample(gpu(12.1, at: 0), epoch: epoch)
            let label = observe { _ = store.liveScalars.gpuLabel }
            let help = observe { _ = store.liveScalars.gpuHelp }
            for offset in [0.1, 0.2, 0.3] {
                store.applyGPUSample(gpu(12.1, at: offset), epoch: epoch)
            }
            store.sample(at: date(0.5))
            XCTAssertEqual(label.value, 0)
            XCTAssertEqual(help.value, 0)
            XCTAssertEqual(store.backendGPUActivity?.timestamp, date(0.3))
            XCTAssertEqual(store.systemGPUHistory.last?.value, 12.1)

            // A new numeric sample that renders identically also stays quiet.
            store.applyGPUSample(gpu(12.2, at: 0.6), epoch: epoch)
            XCTAssertEqual(label.value, 0)
            XCTAssertEqual(help.value, 0)
            store.applyGPUSample(gpu(15, at: 0.7), epoch: epoch)
            XCTAssertEqual(label.value, 1)
            XCTAssertEqual(help.value, 0, "Value changes do not invalidate constant GPU help")
            try assertLegacyValues(store)
        }
    }

    func testGPUUnavailableHelpScopeStalenessAndEpochStayAuthoritative() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            let epoch = UUID()
            store.beginBackendSession(kind: .ollama, epoch: epoch)
            store.applyGPUSample(gpu(nil, at: 0, reason: "Permission denied"), epoch: epoch)
            let label = observe { _ = store.liveScalars.gpuLabel }
            let help = observe { _ = store.liveScalars.gpuHelp }
            store.applyGPUSample(gpu(nil, at: 0.1, reason: "Permission denied"), epoch: epoch)
            XCTAssertEqual(help.value, 0)
            store.applyGPUSample(gpu(nil, at: 0.2, reason: "Sampler unavailable"), epoch: epoch)
            XCTAssertEqual(label.value, 0)
            XCTAssertEqual(help.value, 1)
            XCTAssertEqual(store.liveScalars.gpuHelp, "Sampler unavailable")

            // Per-process execution time is retained for its own history but
            // must never become the dashboard's system percentage or help.
            store.applyGPUSample(
                GPUActivitySample(
                    timestamp: date(0.3), activityPercent: 250, processIDs: [42],
                    source: "Process time", scope: .backendProcesses), epoch: epoch)
            XCTAssertEqual(store.liveScalars.gpuLabel, "—")
            try assertLegacyValues(store)
            store.applyGPUSample(gpu(25, at: 0.4), epoch: epoch)
            try assertLegacyValues(store)
            let untouched = observe {
                _ = store.liveScalars.gpuLabel
                _ = store.liveScalars.gpuHelp
            }
            store.applyGPUSample(gpu(90, at: 0.5), epoch: UUID())
            store.applyGPUSample(gpu(90, at: 0.1), epoch: epoch)
            XCTAssertEqual(untouched.value, 0)
            store.sample(at: date(6))
            XCTAssertEqual(store.liveScalars.gpuLabel, "—")
            XCTAssertEqual(store.liveScalars.gpuHelp, "GPU activity is no longer updating.")
            try assertLegacyValues(store)
            store.beginBackendSession(kind: nil, epoch: UUID())
            XCTAssertEqual(store.liveScalars.gpuHelp, "Waiting for macOS GPU utilization…")
            try assertLegacyValues(store)
        }
    }

    func testActivityClockPublishesOnlyChangedSecondsAndImmediateFirstOutput() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            let request = GenerationRequest(startedAt: origin)
            store.apply(.began(request))
            XCTAssertEqual(store.liveScalars.activityDetail, "Awaiting output · 0s")
            let activity = observe { _ = store.liveScalars.activityDetail }
            let status = observe {
                _ = store.liveScalars.statusTitle
                _ = store.liveScalars.statusTone
            }
            store.sample(at: date(0.5))
            XCTAssertEqual(activity.value, 0, "A half-second tick retains the displayed integer")
            update(store, request: request.id, tokens: 1, at: 0.6)
            XCTAssertEqual(activity.value, 1)
            XCTAssertEqual(store.liveScalars.activityDetail, "Generating · 0s")
            XCTAssertEqual(status.value, 0, "First output retains Active and its tone")
            let generated = observe { _ = store.liveScalars.activityDetail }
            for count in 2...20 { update(store, request: request.id, tokens: count, at: 0.7) }
            XCTAssertEqual(generated.value, 0)
            store.sample(at: date(1))
            XCTAssertEqual(generated.value, 1)
            XCTAssertEqual(store.liveScalars.activityDetail, "Generating · 1s")
            store.apply(.began(GenerationRequest(startedAt: date(1.1))))
            XCTAssertEqual(store.liveScalars.activityDetail, "2 requests in flight")
            let concurrent = observe { _ = store.liveScalars.activityDetail }
            store.sample(at: date(1.5))
            store.sample(at: date(2))
            XCTAssertEqual(
                concurrent.value, 0, "Concurrent count has no displayed clock dependency")
            try assertLegacyValues(store)
        }
    }

    func testResponseAndUsageObserveIndependentExistingCoalescedPublications() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            let older = GenerationRequest(startedAt: origin)
            let latest = GenerationRequest(startedAt: date(0.01))
            store.apply(.began(older))
            store.apply(.began(latest))
            update(store, request: latest.id, tokens: 20, at: 0.1)
            store.sample(at: date(0.5))
            XCTAssertEqual(store.liveScalars.responseTokensLabel, "~20")
            let response = observe { _ = store.liveScalars.responseTokensLabel }
            let usage = observe { _ = store.liveScalars.usage }
            for count in 1...40 { update(store, request: older.id, tokens: count, at: 0.6) }
            XCTAssertEqual(response.value, 0)
            XCTAssertEqual(usage.value, 0)
            XCTAssertEqual(store.usageSummary(in: allHistory).outputTokens, 60)
            XCTAssertEqual(store.liveScalars.usage.outputTokens, 20)
            store.sample(at: date(1))
            XCTAssertEqual(usage.value, 1)
            XCTAssertEqual(
                response.value, 0, "Unrelated request accounting cannot invalidate latest response")
            XCTAssertEqual(store.liveScalars.usage.outputTokens, 60)
            let currentResponse = observe { _ = store.liveScalars.responseTokensLabel }
            update(store, request: latest.id, tokens: 30, at: 1.1)
            XCTAssertEqual(currentResponse.value, 0)
            XCTAssertEqual(store.outputTokens, 30)
            finish(store, request: latest.id, tokens: 25, at: 1.2)
            XCTAssertEqual(
                currentResponse.value, 1, "Final authoritative correction publishes immediately")
            XCTAssertEqual(store.liveScalars.responseTokensLabel, "25")
            try assertLegacyValues(store)
        }
    }

    func testHeldRateCadenceAndChangedFormattingDoNotPublishExtraClockTicks() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            let epoch = UUID()
            store.beginBackendSession(kind: .vllm, epoch: epoch)
            @MainActor func backend(_ value: Double, at offset: Double) {
                store.applyBackendSample(
                    BackendSample(
                        kind: .vllm, timestamp: date(offset), currentTPS: value,
                        runningRequests: 1, queuedRequests: 0), epoch: epoch)
            }
            backend(12.31, at: 0)
            store.sample(at: origin)
            XCTAssertEqual(store.liveScalars.rateLabel, "12.3")
            let rate = observe { _ = store.liveScalars.rateLabel }
            backend(90, at: 0.5)
            store.sample(at: date(0.5))
            XCTAssertEqual(store.currentTPS, 90)
            XCTAssertEqual(store.displayTPS, 12.31)
            XCTAssertEqual(rate.value, 0)
            backend(12.32, at: 1)
            store.sample(at: date(1))
            XCTAssertEqual(store.displayTPS, 12.32)
            XCTAssertEqual(
                rate.value, 0, "A changed raw value with the same displayed decimal remains quiet")
            backend(40, at: 1.5)
            store.sample(at: date(1.5))
            XCTAssertEqual(rate.value, 0)
            store.sample(at: date(2))
            XCTAssertEqual(rate.value, 1)
            XCTAssertEqual(store.liveScalars.rateLabel, "40.0")
            store.updateConnection(.needsConfiguration)
            XCTAssertEqual(store.liveScalars.rateLabel, "—")
            XCTAssertEqual(
                store.liveScalars.configurationPrompt, "Choose an LLM system in Settings.")
            try assertLegacyValues(store)
        }
    }

    func testBatchFirstOutputAndTerminalBoundariesKeepLedgerAndProjectionEquivalent() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            let request = GenerationRequest(model: "Batch model", startedAt: origin)
            store.applyBatch([.began(request)])
            let firstOutput = observe { _ = store.liveScalars.activityDetail }
            store.applyBatch(
                (1...40).map { count in
                    .updated(
                        requestID: request.id,
                        snapshot: GenerationSnapshot(
                            outputTokens: count, liveTPS: 20, elapsed: 0.2, timestamp: date(0.2)))
                })
            XCTAssertEqual(firstOutput.value, 1)
            XCTAssertEqual(store.liveScalars.activityDetail, "Generating · 0s")
            XCTAssertEqual(store.outputTokens, 40)
            XCTAssertEqual(store.liveScalars.responseTokensLabel, "~0")
            store.applyBatch([
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: 37, promptTokens: 4, isEstimated: false,
                        finished: true, timestamp: date(0.3)))
            ])
            XCTAssertEqual(store.liveScalars.responseTokensLabel, "37")
            XCTAssertEqual(store.liveScalars.usage.outputTokens, 37)
            XCTAssertEqual(store.liveScalars.usage.inputTokens, 4)
            XCTAssertNil(store.liveScalars.activityDetail)
            try assertLegacyValues(store)
        }
    }

    func testHiddenDemandReactivationAndEpochResetReuseAuthoritativePresentation() throws {
        try withNormal {
            let store = MetricsStore(clock: { self.origin })
            let epoch = UUID()
            store.beginBackendSession(kind: .ollama, epoch: epoch)
            store.setChartPresentationDemand(true, consumer: .dashboard)
            let first = GenerationRequest(startedAt: origin)
            store.apply(.began(first))
            finish(store, request: first.id, tokens: 5, at: 0.2)
            store.setChartPresentationDemand(false, consumer: .dashboard)
            XCTAssertEqual(store.liveScalars.responseTokensLabel, "—")
            XCTAssertEqual(store.liveScalars.usage, DashboardScalarPresentation.empty.usage)
            let second = GenerationRequest(model: "Hidden model", startedAt: date(0.3))
            store.apply(.began(second))
            update(store, request: second.id, tokens: 7, at: 0.4)
            store.sample(at: date(0.5))
            XCTAssertEqual(store.liveScalars.responseTokensLabel, "—")
            XCTAssertEqual(store.usageSummary(in: allHistory).outputTokens, 12)
            store.usageScope = .today
            XCTAssertTrue(store.liveScalars.usageScopeHelp.hasPrefix("Requests completed today"))
            store.setChartPresentationDemand(true, consumer: .popover)
            XCTAssertEqual(store.liveScalars.responseTokensLabel, "~7")
            XCTAssertEqual(store.liveScalars.usage, DashboardScalarPresentation.empty.usage)
            store.setChartPresentationDemand(true, consumer: .dashboard)
            XCTAssertEqual(store.liveScalars.usage.outputTokens, 12)
            try assertLegacyValues(store)
            store.beginBackendSession(kind: .vllm, epoch: UUID())
            XCTAssertEqual(store.liveScalars.providerTitle, "vLLM")
            XCTAssertEqual(store.liveScalars.modelLabel, "—")
            XCTAssertEqual(store.liveScalars.responseTokensLabel, "—")
            XCTAssertEqual(store.liveScalars.usage.requests, 0)
            let changes = observe {
                _ = store.liveScalars.modelLabel
                _ = store.liveScalars.activityDetail
                _ = store.liveScalars.responseTokensLabel
            }
            store.apply(.began(GenerationRequest(model: "Stale", startedAt: date(1))), epoch: epoch)
            XCTAssertEqual(changes.value, 0)
            try assertLegacyValues(store)
            XCTAssertFalse(PerformanceGraphicsDiagnostics.shared.isEnabled)
        }
    }

    private func assertLegacyValues(
        _ store: MetricsStore, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // The immutable diagnostic uses the original raw helpers and existing
        // coalesced snapshot. It is an independent display-value oracle.
        let old = try DashboardFrozenScalars.capture(store: store, interval: allHistory)
        let live = store.liveScalars
        XCTAssertEqual(live.backendKind, old.backendKind, file: file, line: line)
        XCTAssertEqual(live.providerTitle, old.providerTitle, file: file, line: line)
        XCTAssertEqual(live.modelLabel, old.modelLabel, file: file, line: line)
        XCTAssertEqual(live.activityDetail, old.activityDetail, file: file, line: line)
        XCTAssertEqual(live.statusTitle, old.statusTitle, file: file, line: line)
        XCTAssertEqual(live.configurationPrompt, old.configurationPrompt, file: file, line: line)
        XCTAssertEqual(live.statusTone.rawValue, old.statusTone.rawValue, file: file, line: line)
        XCTAssertEqual(live.rateLabel, old.rateLabel, file: file, line: line)
        XCTAssertEqual(live.gpuLabel, old.gpuLabel, file: file, line: line)
        XCTAssertEqual(live.gpuHelp, old.gpuHelp, file: file, line: line)
        XCTAssertEqual(live.throughputHelp, old.throughputHelp, file: file, line: line)
        XCTAssertEqual(live.responseTokensLabel, old.responseTokensLabel, file: file, line: line)
        XCTAssertEqual(live.usage, old.usage, file: file, line: line)
        XCTAssertEqual(live.usageScopeHelp, old.usageScopeHelp, file: file, line: line)
        XCTAssertEqual(
            live.historyPersistenceError, old.historyPersistenceError, file: file, line: line)
        XCTAssertEqual(live.requestCountLabel, old.requestCountLabel, file: file, line: line)
        XCTAssertEqual(
            live.backendOutputTokensLabel, old.backendOutputTokensLabel, file: file, line: line)
        XCTAssertEqual(
            live.backendPromptTokensLabel, old.backendPromptTokensLabel, file: file, line: line)
        XCTAssertEqual(live.observationScope, old.observationScope, file: file, line: line)
    }

    private var allHistory: DateInterval { DateInterval(start: date(-86_400), end: date(86_400)) }
    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
    private func gpu(_ value: Double?, at offset: TimeInterval, reason: String? = nil)
        -> GPUActivitySample
    {
        GPUActivitySample(
            timestamp: date(offset), activityPercent: value,
            source: "System GPU", unavailableReason: reason, scope: .system)
    }
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
    private func observe(_ read: () -> Void) -> LiveScalarObservationCount {
        let count = LiveScalarObservationCount()
        withObservationTracking(read, onChange: { count.increment() })
        return count
    }
    private func withNormal(_ body: () throws -> Void) throws {
        try PerformanceGraphicsDiagnostics.shared.disable()
        defer { try? PerformanceGraphicsDiagnostics.shared.disable() }
        try body()
    }
}
