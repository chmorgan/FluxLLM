import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class ThroughputPresentationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testBurstingChunksDoNotPublishBetweenOneSecondTicksButHistoryStaysDetailed() {
        let store = MetricsStore(clock: { self.origin })
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        update(store, request: request, offset: 1, rate: 10)
        store.sample(at: origin.addingTimeInterval(1))
        XCTAssertEqual(store.displayTPS, 10)
        XCTAssertTrue(store.displayRateIsEstimated)
        XCTAssertEqual(store.displayUpdatedAt, origin.addingTimeInterval(1))

        for index in 1...9 {
            update(
                store, request: request, offset: 1 + Double(index) / 10, rate: Double(10 + index))
            XCTAssertEqual(store.currentTPS, Double(10 + index))
            XCTAssertEqual(store.displayTPS, 10)
            XCTAssertEqual(store.displayUpdatedAt, origin.addingTimeInterval(1))
            if index == 5 {
                store.sample(at: origin.addingTimeInterval(1.5))
                XCTAssertEqual(store.tpsHistory.last?.value, 15)
                XCTAssertEqual(store.displayTPS, 10)
            }
        }
        store.sample(at: origin.addingTimeInterval(2))
        XCTAssertEqual(store.displayTPS, 19)
        XCTAssertEqual(store.displayUpdatedAt, origin.addingTimeInterval(2))
        XCTAssertEqual(store.tpsHistory.map(\.value), [10, 15, 19])
        XCTAssertEqual(BackendPresentation.rateLabel(store: store), "19.0")

        store.sample(at: origin.addingTimeInterval(3))
        XCTAssertEqual(store.displayTPS, 19)
        XCTAssertEqual(
            store.displayUpdatedAt, origin.addingTimeInterval(3),
            "An unchanged rate still advances the held meter scale once per second")
    }

    func testEstimateWarmupBeginsWithGeneratedTextInsteadOfModelLoading() {
        let store = MetricsStore(clock: { self.origin })
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 0, liveTPS: 0, elapsed: 30,
                    timestamp: origin.addingTimeInterval(30))))
        store.sample(at: origin.addingTimeInterval(30))
        XCTAssertEqual(
            store.displayTPS, 0, "Loading shows zero until an output rate can be estimated")
        for elapsed in [0.0, 0.5, 0.999] {
            let now = origin.addingTimeInterval(31 + elapsed)
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: 10, liveTPS: 900, elapsed: elapsed, timestamp: now)))
            store.sample(at: now)
            XCTAssertEqual(store.currentTPS, 900)
            XCTAssertEqual(store.tpsHistory.last?.value, 900)
            XCTAssertEqual(store.displayTPS, 0)
            XCTAssertEqual(BackendPresentation.rateLabel(store: store), "0.0")
        }
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 20, liveTPS: 20, elapsed: 1,
                    timestamp: origin.addingTimeInterval(32))))
        XCTAssertEqual(store.displayTPS, 0, "Eligible chunks wait for the existing sampling timer")
        store.sample(at: origin.addingTimeInterval(32))
        XCTAssertEqual(store.displayTPS, 20)
    }

    func testTerminalEventsClearRateImmediatelyWithoutWaitingForTick() {
        for terminal in ["completed", "cancelled", "failed", "errorSnapshot"] {
            let store = MetricsStore(clock: { self.origin.addingTimeInterval(1.1) })
            let request = GenerationRequest(startedAt: origin)
            store.apply(.began(request))
            update(store, request: request, offset: 1, rate: 20)
            store.sample(at: origin.addingTimeInterval(1))
            XCTAssertEqual(store.displayTPS, 20)
            switch terminal {
            case "completed":
                store.apply(
                    .updated(
                        requestID: request.id,
                        snapshot: GenerationSnapshot(
                            outputTokens: 100, isEstimated: false, authoritativeTPS: 23,
                            finished: true, elapsed: 5,
                            timestamp: origin.addingTimeInterval(1.1))))
                XCTAssertEqual(store.lastMeasuredTPS, 23)
                XCTAssertEqual(store.outputTokens, 100)
            case "cancelled":
                store.apply(.cancelled(requestID: request.id))
            case "failed":
                store.apply(.failed(requestID: request.id, message: "Connection reset"))
            default:
                store.apply(
                    .updated(
                        requestID: request.id,
                        snapshot: GenerationSnapshot(error: "Invalid response", timestamp: origin)))
            }
            XCTAssertEqual(
                store.displayTPS, ["completed", "cancelled"].contains(terminal) ? 0 : nil)
            XCTAssertFalse(store.displayRateIsEstimated)
            XCTAssertEqual(store.currentTPS, 0)
            store.sample(at: origin.addingTimeInterval(1.5))
            XCTAssertEqual(
                store.tpsHistory.last?.isAvailable,
                ["completed", "cancelled"].contains(terminal))
        }
    }

    func testNewRequestAndBackendSessionClearPresentedRateAndRejectOldOwner() {
        let store = MetricsStore(clock: { self.origin })
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        update(store, request: request, offset: 1, rate: 20)
        store.sample(at: origin.addingTimeInterval(1))
        let newer = GenerationRequest(startedAt: origin.addingTimeInterval(1.1))
        store.apply(.began(newer))
        XCTAssertEqual(store.displayTPS, 0)
        XCTAssertEqual(store.displayUpdatedAt, newer.startedAt)
        update(store, request: request, offset: 1.2, rate: 999)
        store.sample(at: origin.addingTimeInterval(1.5))
        XCTAssertEqual(store.displayTPS, 0)
        XCTAssertEqual(store.currentTPS, 0)

        update(store, request: newer, offset: 2, rate: 30)
        store.sample(at: origin.addingTimeInterval(2))
        // Both requests are still open and fresh, so their live rates sum.
        XCTAssertEqual(store.displayTPS, 1029)
        // `request` sent its last chunk at t1.2; after it goes stale (more than
        // `freshnessInterval` with no new chunk) it drops out of the sum,
        // leaving only the still-active `newer`.
        store.sample(at: origin.addingTimeInterval(7))
        XCTAssertEqual(store.currentTPS, 30)
    }

    func testHealthyBackendCannotKeepStaleRequestPresentationAlive() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        update(store, request: request, offset: 1, rate: 20)
        store.sample(at: origin.addingTimeInterval(1))
        store.applyBackendSample(
            BackendSample(kind: .ollama, timestamp: origin.addingTimeInterval(7)), epoch: epoch)
        store.sample(at: origin.addingTimeInterval(7))
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertTrue(store.isBackendActive)
        XCTAssertNil(store.displayTPS)
        XCTAssertNil(store.displayUpdatedAt)
        XCTAssertFalse(store.rateIsAvailable)
        XCTAssertFalse(store.tpsHistory.last!.isAvailable)
    }

    func testHealthyIdleLoadingStreamingAndCompletionKeepHistoryContinuous() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyBackendSample(BackendSample(kind: .ollama, timestamp: origin), epoch: epoch)
        store.sample(at: origin)
        let request = GenerationRequest(startedAt: origin.addingTimeInterval(0.5))
        store.apply(.began(request), epoch: epoch)
        XCTAssertEqual(store.displayTPS, 0, "Starting a request must not flash a hyphen")

        for index in 1...60 {
            let now = origin.addingTimeInterval(Double(index) / 2)
            if index.isMultiple(of: 8) {
                store.applyBackendSample(BackendSample(kind: .ollama, timestamp: now), epoch: epoch)
            }
            store.sample(at: now)
            XCTAssertEqual(store.displayTPS, 0)
            XCTAssertEqual(store.currentTPS, 0)
            XCTAssertTrue(store.rateIsAvailable)
            XCTAssertEqual(BackendPresentation.rateLabel(store: store), "0.0")
        }
        XCTAssertEqual(store.tpsHistory.count, 61)
        XCTAssertTrue(store.tpsHistory.allSatisfy { $0.isAvailable && $0.value == 0 })

        update(store, request: request, offset: 30.5, rate: 20)
        store.sample(at: origin.addingTimeInterval(30.5))
        XCTAssertEqual(store.displayTPS, 20, "Fresh output restores the rate after loading")
        XCTAssertEqual(store.tpsHistory.last?.value, 20)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 20, authoritativeTPS: 20, finished: true,
                    timestamp: origin.addingTimeInterval(31))), epoch: epoch)
        store.sample(at: origin.addingTimeInterval(31))
        store.applyBackendSample(
            BackendSample(kind: .ollama, timestamp: origin.addingTimeInterval(31.5)), epoch: epoch)
        store.sample(at: origin.addingTimeInterval(31.5))
        XCTAssertEqual(store.displayTPS, 0)
        XCTAssertEqual(store.tpsHistory.suffix(2).map(\.value), [0, 0])
        XCTAssertTrue(store.tpsHistory.allSatisfy(\.isAvailable))
    }

    func testLoadingConnectionFaultsStayUnavailableUntilHealthRecovers() {
        let faults: [BackendConnectionState] = [
            .unavailable, .needsConfiguration, .connecting, .detecting,
        ]
        for fault in faults {
            let store = MetricsStore(clock: { self.origin })
            let epoch = UUID()
            store.beginBackendSession(kind: .ollama, epoch: epoch)
            store.applyBackendSample(BackendSample(kind: .ollama, timestamp: origin), epoch: epoch)
            store.apply(.began(GenerationRequest(startedAt: origin)), epoch: epoch)
            store.sample(at: origin)

            let failedAt = origin.addingTimeInterval(0.5)
            store.updateConnection(fault, message: "Connection fault", at: failedAt)
            store.sample(at: failedAt)
            XCTAssertNil(store.displayTPS)
            XCTAssertFalse(store.tpsHistory.last!.isAvailable)

            let recoveredAt = origin.addingTimeInterval(1)
            store.applyBackendSample(
                BackendSample(kind: .ollama, timestamp: recoveredAt), epoch: epoch)
            store.sample(at: recoveredAt)
            XCTAssertEqual(store.displayTPS, 0)
            XCTAssertEqual(store.tpsHistory.map(\.isAvailable), [true, false, true])
        }
    }

    func testLoadingHealthExpiryCreatesGapAndFreshHealthRestoresZero() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyBackendSample(BackendSample(kind: .ollama, timestamp: origin), epoch: epoch)
        store.apply(.began(GenerationRequest(startedAt: origin)), epoch: epoch)
        for index in 0...13 {
            store.sample(at: origin.addingTimeInterval(Double(index) / 2))
        }
        XCTAssertTrue(store.tpsHistory.prefix(11).allSatisfy(\.isAvailable))
        XCTAssertTrue(store.tpsHistory.suffix(3).allSatisfy { !$0.isAvailable })
        XCTAssertEqual(store.connectionState, .unavailable)
        XCTAssertNil(store.displayTPS)

        let recoveredAt = origin.addingTimeInterval(7)
        store.applyBackendSample(
            BackendSample(kind: .ollama, timestamp: recoveredAt), epoch: epoch)
        store.sample(at: recoveredAt)
        XCTAssertEqual(store.displayTPS, 0)
        XCTAssertTrue(store.tpsHistory.last!.isAvailable)
    }

    func testHealthyLoadingDoesNotFillASamplingSuspension() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyBackendSample(BackendSample(kind: .ollama, timestamp: origin), epoch: epoch)
        store.apply(.began(GenerationRequest(startedAt: origin)), epoch: epoch)
        store.sample(at: origin)
        let resumedAt = origin.addingTimeInterval(30)
        store.applyBackendSample(BackendSample(kind: .ollama, timestamp: resumedAt), epoch: epoch)
        store.sample(at: resumedAt)
        XCTAssertEqual(store.displayTPS, 0)
        XCTAssertEqual(
            store.tpsHistory,
            [
                TimeSeriesPoint(timestamp: origin, value: 0),
                TimeSeriesPoint(
                    timestamp: origin.addingTimeInterval(0.5), value: 0, isAvailable: false),
                TimeSeriesPoint(timestamp: resumedAt, value: 0),
            ])
    }

    func testLoadingZeroDoesNotMaskAnExplicitlyInvalidRate() {
        for invalidRate in [Double.nan, Double.infinity, -1] {
            let store = MetricsStore(clock: { self.origin })
            let epoch = UUID()
            store.beginBackendSession(kind: .ollama, epoch: epoch)
            store.applyBackendSample(BackendSample(kind: .ollama, timestamp: origin), epoch: epoch)
            let request = GenerationRequest(startedAt: origin)
            store.apply(.began(request), epoch: epoch)
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: 0, liveTPS: invalidRate, timestamp: origin)), epoch: epoch)
            for index in 0...12 {
                let now = origin.addingTimeInterval(Double(index) / 2)
                if index == 8 {
                    store.applyBackendSample(
                        BackendSample(kind: .ollama, timestamp: now), epoch: epoch)
                }
                store.sample(at: now)
            }
            XCTAssertEqual(store.connectionState, .ready)
            XCTAssertNil(store.displayTPS)
            XCTAssertTrue(store.tpsHistory.allSatisfy { !$0.isAvailable })

            let recoveredAt = origin.addingTimeInterval(6.5)
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(liveTPS: 0, timestamp: recoveredAt)), epoch: epoch)
            store.sample(at: recoveredAt)
            XCTAssertEqual(store.displayTPS, 0)
            XCTAssertTrue(store.tpsHistory.last!.isAvailable)
        }
    }

    func testNativeRatesShareCadenceAndKeepDisplayedBasisUntilPublication() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin, currentTPS: 30,
                basis: .estimated, runningRequests: 1), epoch: epoch)
        store.sample(at: origin)
        XCTAssertEqual(store.displayTPS, 30)
        XCTAssertTrue(store.displayRateIsEstimated)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin.addingTimeInterval(0.5), currentTPS: 40,
                basis: .serverAggregate, runningRequests: 1), epoch: epoch)
        store.sample(at: origin.addingTimeInterval(0.5))
        XCTAssertEqual(store.currentTPS, 40)
        XCTAssertEqual(store.displayTPS, 30)
        XCTAssertTrue(store.displayRateIsEstimated)
        store.sample(at: origin.addingTimeInterval(1))
        XCTAssertEqual(store.displayTPS, 40)
        XCTAssertFalse(store.displayRateIsEstimated)
        XCTAssertEqual(BackendPresentation.rateLabel(store: store), "40.0")
    }

    func testNativeKnownIdleAndMissingMeasurementsImmediatelyReplaceRunningRate() {
        for missing in [false, true] {
            let store = MetricsStore(clock: { self.origin })
            let epoch = UUID()
            store.beginBackendSession(kind: .vllm, epoch: epoch)
            store.applyBackendSample(
                BackendSample(
                    kind: .vllm, timestamp: origin, currentTPS: 30, runningRequests: 1),
                epoch: epoch)
            store.sample(at: origin)
            store.applyBackendSample(
                BackendSample(
                    kind: .vllm, timestamp: origin.addingTimeInterval(0.1),
                    currentTPS: missing ? nil : 0, runningRequests: 0), epoch: epoch)
            XCTAssertEqual(store.displayTPS, missing ? nil : 0)
            XCTAssertFalse(store.displayRateIsEstimated)
            store.sample(at: origin.addingTimeInterval(0.5))
            XCTAssertEqual(store.displayTPS, missing ? nil : 0)
        }
    }

    func testCompletedNativeIntervalRetainsMeasuredCounterDelta() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin, currentTPS: 30,
                basis: .serverAggregate, runningRequests: 0), epoch: epoch)
        store.sample(at: origin)
        XCTAssertFalse(store.isBackendActive)
        XCTAssertEqual(store.currentTPS, 30)
        XCTAssertEqual(
            store.displayTPS, 30, "A completed polling interval still produced measured output")
        XCTAssertEqual(store.tpsHistory.last?.value, 30)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin.addingTimeInterval(0.5), currentTPS: 0,
                basis: .serverAggregate, runningRequests: 0), epoch: epoch)
        XCTAssertEqual(store.displayTPS, 0, "An actually idle interval clears immediately")
    }

    private func update(
        _ store: MetricsStore, request: GenerationRequest, offset: TimeInterval, rate: Double
    ) {
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: max(1, Int(rate)), liveTPS: rate, elapsed: offset,
                    timestamp: origin.addingTimeInterval(offset))))
    }
}
