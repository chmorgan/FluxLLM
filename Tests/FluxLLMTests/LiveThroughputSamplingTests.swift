import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class LiveThroughputSamplingTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testSamplingTaskPublishesGrowingStreamAndCompletionWithoutManualSamples() async throws {
        var now = origin
        let store = MetricsStore(clock: { now })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyBackendSample(BackendSample(kind: .ollama, timestamp: now), epoch: epoch)
        store.startSampling()
        defer { store.stopSampling() }
        XCTAssertEqual(store.displayTPS, 0)

        now = origin.addingTimeInterval(0.25)
        let request = GenerationRequest(model: "test-model", startedAt: now)
        store.apply(.began(request), epoch: epoch)
        update(store, request: request, at: now, tokens: 0, rate: 0, elapsed: 0)
        try await eventually("The live task samples the loading request") {
            store.sampleDate == now
        }
        XCTAssertEqual(store.outputTokens, 0)
        XCTAssertEqual(store.activeGeneration?.state, .running)
        XCTAssertEqual(store.displayTPS, 0)

        now = origin.addingTimeInterval(1.25)
        update(store, request: request, at: now, tokens: 12, rate: 24, elapsed: 0.5)
        try await eventually("The live task samples the estimate warmup") {
            store.sampleDate == now
        }
        XCTAssertEqual(store.outputTokens, 12)
        XCTAssertEqual(store.tpsHistory.last?.value, 24)
        XCTAssertEqual(store.displayTPS, 0, "Warmup keeps a stable zero until the first estimate")

        now = origin.addingTimeInterval(2)
        update(store, request: request, at: now, tokens: 36, rate: 24, elapsed: 1.5)
        XCTAssertEqual(store.outputTokens, 36, "Streaming usage updates before the sampling tick")
        try await eventually("Growing output publishes a numeric rate through the real task") {
            store.sampleDate == now && store.displayTPS == 24
        }
        XCTAssertEqual(BackendPresentation.rateLabel(store: store), "24.0")
        XCTAssertTrue(store.displayRateIsEstimated)

        now = origin.addingTimeInterval(2.25)
        update(store, request: request, at: now, tokens: 42, rate: 30, elapsed: 1.75)
        try await eventually("The task keeps raw history current between display publications") {
            store.sampleDate == now
        }
        XCTAssertEqual(store.tpsHistory.last?.value, 30)
        XCTAssertEqual(store.displayTPS, 24, "The numeric display retains its one-second cadence")

        now = origin.addingTimeInterval(3)
        update(store, request: request, at: now, tokens: 68, rate: 32, elapsed: 2.5)
        try await eventually("The next eligible tick refreshes the displayed rate") {
            store.sampleDate == now && store.displayTPS == 32
        }
        XCTAssertEqual(store.outputTokens, 68)

        now = origin.addingTimeInterval(3.1)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 70, isEstimated: false, authoritativeTPS: 31,
                    finished: true, elapsed: 2.6, timestamp: now)), epoch: epoch)
        XCTAssertEqual(store.displayTPS, 0, "Completion clears the live rate without another tick")
        XCTAssertEqual(store.outputTokens, 70)
        XCTAssertEqual(store.lastMeasuredTPS, 31)
        XCTAssertEqual(store.activeGeneration?.state, .completed)

        now = origin.addingTimeInterval(4)
        try await eventually("Sampling continues after completion") { store.sampleDate == now }
        XCTAssertEqual(store.displayTPS, 0)
        XCTAssertEqual(store.tpsHistory.last?.value, 0)
        XCTAssertTrue(store.tpsHistory.last?.isAvailable == true)
    }

    func testSamplingTaskExpiresAfterSleepGapAndRecoversOnFreshStream() async throws {
        var now = origin
        let store = MetricsStore(clock: { now })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyBackendSample(BackendSample(kind: .ollama, timestamp: now), epoch: epoch)
        let request = GenerationRequest(startedAt: now)
        store.apply(.began(request), epoch: epoch)
        store.startSampling()
        defer { store.stopSampling() }

        now = origin.addingTimeInterval(1)
        update(store, request: request, at: now, tokens: 20, rate: 20, elapsed: 1)
        try await eventually("The initial streamed rate becomes visible") {
            store.sampleDate == now && store.displayTPS == 20
        }

        // Advancing only the injected data clock simulates a long suspension
        // without slowing this test or depending on the machine's wall clock.
        now = origin.addingTimeInterval(31)
        store.applyBackendSample(BackendSample(kind: .ollama, timestamp: now), epoch: epoch)
        try await eventually("A healthy backend does not preserve stale request throughput") {
            store.sampleDate == now && store.displayTPS == nil
        }
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.activeGeneration?.state, .running)
        XCTAssertEqual(store.outputTokens, 20)
        XCTAssertFalse(store.rateIsAvailable)
        XCTAssertFalse(store.tpsHistory.last!.isAvailable)
        XCTAssertTrue(
            store.tpsHistory.contains {
                $0.timestamp == origin.addingTimeInterval(1.5) && !$0.isAvailable
            }, "The suspension creates a gap instead of joining unrelated observations")

        now = origin.addingTimeInterval(31.5)
        update(store, request: request, at: now, tokens: 80, rate: 16, elapsed: 31.5)
        try await eventually("Fresh streamed output restores the displayed rate") {
            store.sampleDate == now && store.displayTPS == 16
        }
        XCTAssertEqual(store.outputTokens, 80)
        XCTAssertTrue(store.rateIsAvailable)
        XCTAssertTrue(store.tpsHistory.last!.isAvailable)
    }

    func testStoppedSamplingTaskRemainsStoppedAndCanRestart() async throws {
        var now = origin
        let store = MetricsStore(clock: { now })
        store.startSampling()
        store.startSampling()
        defer { store.stopSampling() }
        now = origin.addingTimeInterval(1)
        try await eventually("Sampling starts normally") { store.sampleDate == now }

        store.stopSampling()
        let stoppedDate = store.sampleDate
        let stoppedHistory = store.tpsHistory
        now = origin.addingTimeInterval(2)
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertEqual(store.sampleDate, stoppedDate)
        XCTAssertEqual(store.tpsHistory, stoppedHistory)

        store.startSampling()
        XCTAssertEqual(store.sampleDate, now, "Restart immediately captures the current state")
        now = origin.addingTimeInterval(3)
        try await eventually("The restarted task continues sampling asynchronously") {
            store.sampleDate == now
        }
        XCTAssertEqual(store.tpsHistory.last?.timestamp, now)
    }

    private func update(
        _ store: MetricsStore, request: GenerationRequest, at date: Date,
        tokens: Int, rate: Double, elapsed: TimeInterval
    ) {
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: tokens, liveTPS: rate, elapsed: elapsed, timestamp: date)))
    }

    private func eventually(
        _ message: String, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(message, file: file, line: line)
                throw SamplingTimeout.elapsed
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum SamplingTimeout: Error {
        case elapsed
    }
}
