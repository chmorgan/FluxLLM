import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class BackendMetricsStoreTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testAggregateMetricsDoNotFabricateAnIndividualGeneration() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin, model: "model-a", currentTPS: 80,
                runningRequests: 2, queuedRequests: 1, outputTokens: 50_000), epoch: epoch)
        XCTAssertNil(store.activeGeneration)
        XCTAssertTrue(store.isBackendActive)
        XCTAssertEqual(store.currentTPS, 80)
        XCTAssertEqual(store.backendOutputTokens, 50_000)
        XCTAssertEqual(store.throughputBasis, .serverAggregate)
        XCTAssertNil(store.inferenceGPUPercent)
    }

    func testSwitchClearsHistoryAndRejectsLatePollsAndProxyEvents() {
        let store = MetricsStore()
        let oldEpoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: oldEpoch)
        store.updateConnection(.ready)
        let request = GenerationRequest(model: "old", startedAt: origin)
        store.apply(.began(request), epoch: oldEpoch)
        store.sample(at: origin)
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin, currentTPS: 30, runningRequests: 1), epoch: epoch)
        store.apply(
            .updated(requestID: request.id, snapshot: GenerationSnapshot(liveTPS: 900)),
            epoch: oldEpoch)
        store.applyBackendSample(BackendSample(kind: .ollama, currentTPS: 999), epoch: oldEpoch)
        XCTAssertEqual(store.currentTPS, 30)
        XCTAssertNil(store.activeGeneration)
        XCTAssertTrue(store.tpsHistory.isEmpty)

        // Even switching back to the same backend cannot revive an old request.
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        store.apply(.began(request), epoch: oldEpoch)
        XCTAssertNil(store.activeGeneration)
    }

    func testRetainedServerAverageDoesNotLookLikeCurrentActivity() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .rapidMLX, epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .rapidMLX, timestamp: origin, currentTPS: 75,
                basis: .serverReportedAverage, runningRequests: 0), epoch: epoch)
        XCTAssertFalse(store.isBackendActive)
        XCTAssertEqual(store.currentTPS, 0)
        XCTAssertEqual(store.lastMeasuredTPS, 75)
        XCTAssertTrue(store.rateIsAvailable)
    }

    func testUnavailableRateAndStaleConnectionCreateGapsInsteadOfZeroMeasurements() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin, runningRequests: 1), epoch: epoch)
        store.sample(at: origin)
        XCTAssertFalse(store.tpsHistory.last!.isAvailable)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin.addingTimeInterval(1), currentTPS: 12,
                runningRequests: 1), epoch: epoch)
        store.sample(at: origin.addingTimeInterval(1))
        XCTAssertTrue(store.tpsHistory.last!.isAvailable)
        store.sample(at: origin.addingTimeInterval(7))
        XCTAssertEqual(store.connectionState, .unavailable)
        XCTAssertFalse(store.tpsHistory.last!.isAvailable)
        XCTAssertFalse(store.isBackendActive)
    }

    func testSleepIntroducesExplicitGapAndHistoryRangeExpandsWithoutLosingOlderSamples() {
        let store = MetricsStore()
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        store.apply(.updated(requestID: request.id, snapshot: GenerationSnapshot(liveTPS: 40)))
        store.sample(at: origin)
        XCTAssertEqual(store.visibleHistoryDuration, 60)
        store.sample(at: origin.addingTimeInterval(61))
        XCTAssertEqual(store.visibleHistoryDuration, 300)
        XCTAssertEqual(store.tpsHistory.count, 3)
        XCTAssertFalse(store.tpsHistory[1].isAvailable)
        XCTAssertEqual(store.tpsHistory.first?.value, 40)
        store.historyRange = .minute
        XCTAssertEqual(store.visibleHistoryDuration, 60)
        XCTAssertEqual(store.tpsHistory.first?.timestamp, origin)
    }

    func testOllamaReadinessPollDoesNotOverwriteObservedRequestThroughput() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        let request = GenerationRequest(model: "generating", startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        store.apply(
            .updated(requestID: request.id, snapshot: GenerationSnapshot(liveTPS: 22)),
            epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .ollama, timestamp: origin, model: "loaded-but-not-generating"), epoch: epoch)
        XCTAssertEqual(store.currentModel, "generating")
        XCTAssertEqual(store.currentTPS, 22)
        XCTAssertTrue(store.isBackendActive)
    }

    func testOutOfOrderPollCannotChangeCurrentBackendState() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin.addingTimeInterval(2), currentTPS: 44,
                runningRequests: 1), epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin, isReady: false), epoch: epoch)
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.currentTPS, 44)
    }

    func testGPUReadingRequiresAttributionAndValidPercentage() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        for (value, source) in [(50.0, nil), (101.0, "worker"), (Double.nan, "worker")] {
            store.applyBackendSample(
                BackendSample(
                    kind: .vllm, timestamp: origin, inferenceGPUPercent: value, gpuSource: source),
                epoch: epoch)
            XCTAssertNil(store.inferenceGPUPercent)
        }
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin, inferenceGPUPercent: 50,
                gpuSource: "Instrumented inference worker"), epoch: epoch)
        XCTAssertEqual(store.inferenceGPUPercent, 50)
        store.updateConnection(.unavailable)
        XCTAssertNil(store.inferenceGPUPercent)
    }

    func testOllamaHealthCannotRefreshStalledRequestRateAndStreamEvidenceRestoresReadiness() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    liveTPS: 30, timestamp: origin)), epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .ollama, timestamp: origin.addingTimeInterval(6)), epoch: epoch)
        store.sample(at: origin.addingTimeInterval(6))
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertTrue(store.isBackendActive)
        XCTAssertFalse(store.rateIsAvailable)
        XCTAssertFalse(store.tpsHistory.last!.isAvailable)
        XCTAssertNil(
            store.displayTPS, "A positive observed rate is output evidence even without tokens")

        store.sample(at: origin.addingTimeInterval(6.5))
        XCTAssertFalse(store.rateIsAvailable, "Clearing a stale rate must not turn it into loading")
        XCTAssertFalse(store.tpsHistory.last!.isAvailable)
        XCTAssertNil(store.displayTPS)

        store.updateConnection(.unavailable)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 21, liveTPS: 21, elapsed: 1,
                    timestamp: origin.addingTimeInterval(7))), epoch: epoch)
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertTrue(store.isRateEstimated)
        store.sample(at: origin.addingTimeInterval(7))
        XCTAssertEqual(BackendPresentation.rateLabel(store: store), "21.0")
        XCTAssertTrue(store.tpsHistory.last!.isAvailable)
    }

    func testFreshSuccessfulStreamOutweighsStaleHealthAndTransientPollFailures() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyBackendSample(BackendSample(kind: .ollama, timestamp: origin), epoch: epoch)
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        for offset in [6.0, 6.5, 7.0, 7.5] {
            let now = origin.addingTimeInterval(offset)
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: 40, liveTPS: 20, elapsed: offset, timestamp: now)),
                epoch: epoch)
            store.updateConnection(.unavailable, message: "Health check timed out", at: now)
            store.sample(at: now)
            XCTAssertEqual(store.connectionState, .ready)
            XCTAssertEqual(BackendPresentation.statusTitle(store: store), "Active")
            XCTAssertNil(BackendPresentation.configurationPrompt(store: store))
            XCTAssertEqual(store.currentTPS, 20)
            XCTAssertEqual(store.displayTPS, 20)
            XCTAssertTrue(store.tpsHistory.last!.isAvailable)
            XCTAssertEqual(store.connectionMessage, "Health check timed out")
        }
        store.updateConnection(.connecting, at: origin.addingTimeInterval(8))
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.currentTPS, 20)

        store.sample(at: origin.addingTimeInterval(13))
        XCTAssertEqual(store.connectionState, .unavailable)
        XCTAssertNil(store.displayTPS)
        XCTAssertFalse(store.rateIsAvailable)
    }

    func testStreamOnlyReadinessExpiresEvenWithoutAnyHealthSample() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 20, liveTPS: 20, elapsed: 1, timestamp: origin)), epoch: epoch)
        store.sample(at: origin)
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.displayTPS, 20)
        store.sample(at: origin.addingTimeInterval(5))
        XCTAssertEqual(store.connectionState, .ready)
        store.sample(at: origin.addingTimeInterval(5.5))
        XCTAssertEqual(store.connectionState, .unavailable)
        XCTAssertNil(store.displayTPS)
        store.sample(at: origin.addingTimeInterval(6))
        XCTAssertEqual(store.connectionState, .unavailable)
    }

    func testRequestBeginAndErrorDoNotCreateSuccessfulStreamEvidence() {
        for snapshotError in [false, true] {
            let store = MetricsStore(clock: { self.origin })
            let epoch = UUID()
            store.beginBackendSession(kind: .ollama, epoch: epoch)
            let request = GenerationRequest(startedAt: origin)
            store.apply(.began(request), epoch: epoch)
            XCTAssertEqual(store.connectionState, .connecting)
            if snapshotError {
                store.apply(
                    .updated(
                        requestID: request.id,
                        snapshot: GenerationSnapshot(error: "Backend failed", timestamp: origin)),
                    epoch: epoch)
            } else {
                store.apply(.failed(requestID: request.id, message: "Backend failed"), epoch: epoch)
            }
            store.updateConnection(.unavailable, at: origin)
            store.sample(at: origin)
            XCTAssertEqual(store.connectionState, .unavailable)
            XCTAssertNil(store.displayTPS)
        }
    }

    func testStreamCannotMaskConfigurationErrorOrCrossBackendSession() {
        let store = MetricsStore(clock: { self.origin })
        let oldEpoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: oldEpoch)
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: oldEpoch)
        let update = GenerationEvent.updated(
            requestID: request.id,
            snapshot: GenerationSnapshot(
                outputTokens: 20, liveTPS: 20, elapsed: 1, timestamp: origin))
        store.apply(update, epoch: oldEpoch)
        store.sample(at: origin)
        store.updateConnection(.needsConfiguration, message: "Choose a valid endpoint", at: origin)
        store.apply(update, epoch: oldEpoch)
        XCTAssertEqual(store.connectionState, .needsConfiguration)
        XCTAssertFalse(store.rateIsAvailable)
        XCTAssertEqual(store.currentTPS, 0)
        XCTAssertNil(store.displayTPS)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 20, authoritativeTPS: 20, finished: true,
                    timestamp: origin.addingTimeInterval(0.1))), epoch: oldEpoch)
        XCTAssertEqual(store.connectionState, .needsConfiguration)
        XCTAssertFalse(store.rateIsAvailable)
        XCTAssertNil(store.displayTPS)
        XCTAssertEqual(store.lastMeasuredTPS, 20, "Final usage is still retained for diagnostics")
        store.sample(at: origin)
        XCTAssertEqual(store.connectionState, .needsConfiguration)
        XCTAssertNil(store.displayTPS)

        store.beginBackendSession(kind: .ollama, epoch: UUID())
        store.apply(update, epoch: oldEpoch)
        store.updateConnection(.unavailable, at: origin)
        XCTAssertEqual(store.connectionState, .unavailable)
        XCTAssertNil(store.activeGeneration)
        XCTAssertNil(store.displayTPS)
    }

    func testCompletedStreamDoesNotHideLaterHealthFaultIndefinitely() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 20, finished: true, timestamp: origin)), epoch: epoch)
        store.updateConnection(.unavailable, message: "Connection refused", at: origin)
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.displayTPS, 0)
        store.sample(at: origin.addingTimeInterval(6))
        XCTAssertEqual(store.connectionState, .unavailable)
        XCTAssertEqual(store.connectionMessage, "Connection refused")
        XCTAssertNil(store.displayTPS)
    }
}
