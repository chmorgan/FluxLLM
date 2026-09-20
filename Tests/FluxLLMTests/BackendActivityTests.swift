import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class BackendActivityTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testObservedRequestRemainsActiveWhileHealthAndRatesAreUnavailable() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        store.updateConnection(.unavailable, message: "Health check timed out", at: origin)
        store.sample(at: origin.addingTimeInterval(18))

        XCTAssertEqual(store.connectionState, .unavailable)
        XCTAssertTrue(store.isBackendActive)
        XCTAssertEqual(store.activityRequestStartedAt, origin)
        XCTAssertEqual(BackendPresentation.statusTitle(store: store), "Active")
        XCTAssertEqual(BackendPresentation.activityDetail(store: store), "Awaiting output · 18s")
        XCTAssertEqual(BackendPresentation.rateLabel(store: store), "0.0")
        XCTAssertNotNil(BackendPresentation.configurationPrompt(store: store))
        XCTAssertFalse(store.rateIsAvailable, "Activity must not fabricate a measured rate")
    }

    func testOutputEvidenceChangesObservedPhaseWithoutChangingRequestStartTime() {
        let store = MetricsStore(clock: { self.origin })
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        store.sample(at: origin.addingTimeInterval(18))
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 5, liveTPS: 10, elapsed: 0.5,
                    timestamp: origin.addingTimeInterval(18))))

        XCTAssertEqual(BackendPresentation.activityDetail(store: store), "Generating · 18s")
        XCTAssertEqual(store.activityRequestStartedAt, origin)
    }

    func testNewestRequestFinishingDoesNotHideOlderOpenRequest() {
        let store = MetricsStore(clock: { self.origin })
        let first = GenerationRequest(startedAt: origin)
        let second = GenerationRequest(startedAt: origin.addingTimeInterval(1))
        store.apply(.began(first))
        store.apply(.began(second))
        XCTAssertEqual(BackendPresentation.activityDetail(store: store), "2 requests in flight")
        XCTAssertEqual(store.activityRequestStartedAt, origin)

        store.apply(
            .updated(requestID: second.id, snapshot: GenerationSnapshot(finished: true)))
        XCTAssertEqual(store.activeGeneration?.id, second.id)
        XCTAssertEqual(store.activeGeneration?.state, .completed)
        XCTAssertTrue(store.isBackendActive)
        XCTAssertEqual(store.activityRequestStartedAt, origin)

        store.apply(.cancelled(requestID: first.id))
        XCTAssertFalse(store.isBackendActive)
        XCTAssertNil(store.activityRequestStartedAt)
    }

    func testOlderRequestTerminalEventsRemoveOnlyTheirOwnActivity() {
        for terminal in ["finished", "failed", "cancelled", "snapshotError"] {
            let store = MetricsStore(clock: { self.origin })
            let first = GenerationRequest(startedAt: origin)
            let second = GenerationRequest(startedAt: origin.addingTimeInterval(1))
            store.apply(.began(first))
            store.apply(.began(second))
            switch terminal {
            case "finished":
                store.apply(
                    .updated(requestID: first.id, snapshot: GenerationSnapshot(finished: true)))
            case "failed":
                store.apply(.failed(requestID: first.id, message: "Connection failed"))
            case "cancelled":
                store.apply(.cancelled(requestID: first.id))
            default:
                store.apply(
                    .updated(
                        requestID: first.id, snapshot: GenerationSnapshot(error: "Invalid stream")))
            }
            XCTAssertTrue(store.isBackendActive, terminal)
            XCTAssertEqual(store.activityRequestStartedAt, second.startedAt, terminal)
            XCTAssertEqual(store.activeGeneration?.id, second.id, terminal)
            XCTAssertNil(store.generationError, terminal)

            store.apply(.began(first))
            XCTAssertEqual(store.activityRequestStartedAt, second.startedAt, "Duplicate began")
        }
    }

    func testDelayedOlderRequestStartIsTrackedWithoutTakingRateOwnership() {
        let store = MetricsStore(clock: { self.origin })
        let older = GenerationRequest(startedAt: origin)
        let newer = GenerationRequest(startedAt: origin.addingTimeInterval(1))
        store.apply(.began(newer))
        store.apply(.began(older))
        store.apply(
            .updated(
                requestID: older.id,
                snapshot: GenerationSnapshot(outputTokens: 12, liveTPS: 12)))
        XCTAssertEqual(store.activeGeneration?.id, newer.id)
        XCTAssertEqual(store.outputTokens, 0)
        XCTAssertEqual(store.activityRequestStartedAt, origin)
        store.apply(.cancelled(requestID: newer.id))
        XCTAssertTrue(store.isBackendActive)
        XCTAssertEqual(BackendPresentation.activityDetail(store: store), "Generating · 0s")
    }

    func testBackendSessionClearsActivityAndRejectsPreviousEpoch() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        store.apply(.began(request), epoch: epoch)
        XCTAssertFalse(store.isBackendActive)
        XCTAssertNil(store.activityRequestStartedAt)
        XCTAssertEqual(store.backendActivity, .unknown)
    }

    func testRetiredDuplicateCannotReopenDisplayedCompletedRequest() {
        let store = MetricsStore(clock: { self.origin })
        let displayed = GenerationRequest(startedAt: origin.addingTimeInterval(5_000))
        store.apply(.began(displayed))
        store.apply(
            .updated(requestID: displayed.id, snapshot: GenerationSnapshot(finished: true)))

        // Older concurrent requests can retire enough identities to evict the
        // displayed request from the bounded duplicate-event history.
        for offset in 0..<2_400 {
            let older = GenerationRequest(startedAt: origin.addingTimeInterval(Double(offset)))
            store.apply(.began(older))
            store.apply(.cancelled(requestID: older.id))
        }
        store.apply(.began(displayed))
        XCTAssertEqual(store.activeGeneration?.id, displayed.id)
        XCTAssertEqual(store.activeGeneration?.state, .completed)
        XCTAssertFalse(store.isBackendActive)
        XCTAssertNil(store.activityRequestStartedAt)
    }

    func testNativePositiveCountsProveActivityWithoutInventingRequestPhase() {
        for kind in [BackendKind.vllm, .rapidMLX, .llamaCpp] {
            let store = MetricsStore(clock: { self.origin })
            let epoch = UUID()
            store.beginBackendSession(kind: kind, epoch: epoch)
            store.applyBackendSample(
                BackendSample(
                    kind: kind, timestamp: origin, currentTPS: 85,
                    basis: .serverReportedAverage, runningRequests: 2, queuedRequests: 1),
                epoch: epoch)
            XCTAssertEqual(BackendPresentation.statusTitle(store: store), "Active")
            XCTAssertEqual(BackendPresentation.activityDetail(store: store), "2 running · 1 queued")
            XCTAssertNil(store.activityRequestStartedAt)

            store.applyBackendSample(
                BackendSample(kind: kind, timestamp: origin, queuedRequests: 1), epoch: epoch)
            XCTAssertTrue(store.isBackendActive)
            XCTAssertEqual(BackendPresentation.activityDetail(store: store), "1 queued")
        }
    }

    func testNativeMissingCountsDoNotBecomeIdleOrUseRetainedAverageAsActivity() {
        let examples: [(Int?, Int?)] = [(nil, nil), (0, nil), (nil, 0), (-1, 0)]
        for counts in examples {
            let store = MetricsStore(clock: { self.origin })
            let epoch = UUID()
            store.beginBackendSession(kind: .vllm, epoch: epoch)
            store.applyBackendSample(
                BackendSample(
                    kind: .vllm, timestamp: origin, currentTPS: 80,
                    basis: .serverReportedAverage, runningRequests: counts.0,
                    queuedRequests: counts.1, inferenceGPUPercent: 100, gpuSource: "Server"),
                epoch: epoch)
            XCTAssertFalse(store.isBackendActive)
            XCTAssertEqual(store.backendActivity, .unknown)
            XCTAssertEqual(BackendPresentation.statusTitle(store: store), "Unknown")
            XCTAssertNil(BackendPresentation.activityDetail(store: store))
        }
    }

    func testNativeKnownZeroCountsAreIdleEvenWithRetainedAverage() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .rapidMLX, epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .rapidMLX, timestamp: origin, currentTPS: 80,
                basis: .serverReportedAverage, runningRequests: 0, queuedRequests: 0), epoch: epoch)
        XCTAssertEqual(store.backendActivity, .idle)
        XCTAssertEqual(BackendPresentation.statusTitle(store: store), "Idle")
        XCTAssertNil(BackendPresentation.activityDetail(store: store))
    }

    func testNativeActivityFreshnessIsIndependentOfConnectionHealth() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyBackendSample(
            BackendSample(kind: .vllm, timestamp: origin, runningRequests: 2, queuedRequests: 0),
            epoch: epoch)
        store.updateConnection(.unavailable, at: origin.addingTimeInterval(1))
        XCTAssertEqual(BackendPresentation.statusTitle(store: store), "Active")
        XCTAssertEqual(BackendPresentation.activityDetail(store: store), "2 running · 0 queued")
        store.updateConnection(.ready, at: origin.addingTimeInterval(6))
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.backendActivity, .unknown, "Health success does not refresh counts")
        XCTAssertEqual(BackendPresentation.statusTitle(store: store), "Unknown")
    }

    func testNativeScrapeCountsRemainActivityEvidenceWhenReadinessFails() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin, isReady: false, currentTPS: 50,
                runningRequests: 2, queuedRequests: 1), epoch: epoch)

        XCTAssertEqual(store.connectionState, .connecting)
        XCTAssertEqual(BackendPresentation.statusTitle(store: store), "Active")
        XCTAssertEqual(BackendPresentation.activityDetail(store: store), "2 running · 1 queued")
        XCTAssertNil(store.activityRequestStartedAt)
        XCTAssertNil(store.displayTPS)
        XCTAssertFalse(store.rateIsAvailable, "Readiness still gates the raw rate")

        store.sample(at: origin.addingTimeInterval(6))
        XCTAssertEqual(store.backendActivity, .unknown, "Unrefreshed counts still expire")
    }

    func testNativeCountsExpireDuringSamplingAndClearOnSourceChange() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyBackendSample(
            BackendSample(kind: .vllm, timestamp: origin, runningRequests: 1), epoch: epoch)
        store.sample(at: origin.addingTimeInterval(6))
        XCTAssertFalse(store.isBackendActive)
        XCTAssertEqual(store.backendActivity, .unknown)

        store.applyBackendSample(
            BackendSample(kind: .vllm, timestamp: origin.addingTimeInterval(7), queuedRequests: 1),
            epoch: epoch)
        XCTAssertTrue(store.isBackendActive)
        store.beginBackendSession(kind: .llamaCpp, epoch: UUID())
        XCTAssertEqual(store.backendActivity, .unknown)
    }
}
