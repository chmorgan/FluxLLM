import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class ToolActivityStoreTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testOllamaReservesOverlayBeforeTheFirstSampleOrRequest() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.chartPresentation.supportsToolActivity)
        XCTAssertTrue(store.chartPresentation.toolObservation.isEmpty)
        XCTAssertTrue(store.chartPresentation.toolActivity.isEmpty)
    }

    func testEventsKeepTheirTimesAndPublishWithBothHistories() {
        let (store, epoch) = makeStore()
        store.sample(at: origin)
        let initial = store.chartPresentation
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        let first = event(at: 0.2, name: "read_file")
        let second = event(at: 0.4, name: "search")
        store.apply(.toolActivity(requestID: request.id, events: [first, second]), epoch: epoch)
        store.sample(at: date(0.5))

        XCTAssertEqual(store.toolActivityEvents, [first, second])
        XCTAssertEqual(store.chartPresentation, initial)
        XCTAssertEqual(store.outputTokens, 0)
        XCTAssertEqual(store.currentTPS, 0)

        store.sample(at: date(1))
        XCTAssertEqual(store.chartPresentation.timestamp, date(1))
        XCTAssertEqual(store.chartPresentation.toolActivity, [first, second])
        XCTAssertEqual(store.chartPresentation.throughput, store.tpsHistory)
        XCTAssertEqual(store.chartPresentation.toolObservation, store.toolObservationHistory)
        XCTAssertTrue(store.chartPresentation.supportsToolActivity)
    }

    func testToolActivityRetainsEachRequestLaneAndEnforcesEpochAndDedup() {
        let (store, epoch) = makeStore()
        let older = GenerationRequest(startedAt: origin)
        let current = GenerationRequest(startedAt: date(1))
        store.apply(.began(older), epoch: epoch)
        store.apply(.began(current), epoch: epoch)
        let accepted = event(at: 1.1)
        let olderCall = event(at: 1.2)
        let afterCancel = event(at: 1.3)
        store.apply(.toolActivity(requestID: older.id, events: [olderCall]), epoch: epoch)
        store.apply(.toolActivity(requestID: current.id, events: [accepted]), epoch: UUID())
        store.apply(.toolActivity(requestID: current.id, events: [event(at: 0.9)]), epoch: epoch)
        store.apply(
            .toolActivity(requestID: current.id, events: [accepted, accepted]), epoch: epoch)
        store.apply(.cancelled(requestID: current.id), epoch: epoch)
        store.apply(.toolActivity(requestID: current.id, events: [afterCancel]), epoch: epoch)
        // Each request keeps its own tool calls for its lane: the older request's
        // call at 1.2 and the current request's calls at 1.1 and 1.3. The
        // wrong-epoch event is ignored, the 0.9 event precedes the current
        // request's start and is rejected, and the duplicate accepted is deduped.
        XCTAssertEqual(store.toolActivityEvents, [accepted, olderCall, afterCancel])
        XCTAssertEqual(store.activeGeneration?.state, .cancelled)
    }

    func testResultsAndNextGenerationRetainPreviousCallHistory() {
        let (store, epoch) = makeStore()
        let first = GenerationRequest(startedAt: origin)
        let call = event(at: 0.2)
        store.apply(.began(first), epoch: epoch)
        store.apply(.toolActivity(requestID: first.id, events: [call]), epoch: epoch)
        store.apply(
            .updated(
                requestID: first.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 8, authoritativeTPS: 20, finished: true, timestamp: date(0.3))),
            epoch: epoch)
        let next = GenerationRequest(startedAt: date(1))
        let result = ToolActivityEvent(
            kind: .resultSubmission, callID: "call-1", timestamp: date(1))
        store.apply(.began(next), epoch: epoch)
        store.apply(.toolActivity(requestID: next.id, events: [result]), epoch: epoch)
        store.sample(at: date(1))
        XCTAssertEqual(store.chartPresentation.toolActivity, [call, result])
        XCTAssertEqual(store.outputTokens, 0)
        XCTAssertEqual(store.activeGeneration?.id, next.id)
    }

    func testObservationSeparatesIdleZeroStoppedProxyAndSleepGap() {
        let (store, _) = makeStore()
        store.sample(at: origin)
        store.sample(at: date(0.5))
        XCTAssertTrue(store.toolObservationHistory.allSatisfy(\.isAvailable))
        XCTAssertTrue(store.toolActivityEvents.isEmpty)
        store.proxyState = .stopped
        store.sample(at: date(1))
        XCTAssertFalse(store.toolObservationHistory.last?.isAvailable ?? true)
        store.proxyState = .listening
        store.updateConnection(.ready, at: date(8))
        store.sample(at: date(8))
        XCTAssertEqual(
            store.toolObservationHistory.suffix(2).map(\.timestamp), [date(1.5), date(8)])
        XCTAssertEqual(store.toolObservationHistory.suffix(2).map(\.isAvailable), [false, true])
        store.sample(at: date(8))
        XCTAssertEqual(store.toolObservationHistory.filter { $0.timestamp == date(8) }.count, 1)
    }

    func testFreshProxyObservationDoesNotInventGeneratedThroughput() {
        let (store, epoch) = makeStore()
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(outputTokens: 10, liveTPS: 10, timestamp: date(1))),
            epoch: epoch)
        store.sample(at: date(1))
        store.updateConnection(.ready, at: date(6))
        store.sample(at: date(6.5))
        XCTAssertFalse(store.tpsHistory.last?.isAvailable ?? true)
        XCTAssertTrue(store.toolObservationHistory.last?.isAvailable ?? false)
        XCTAssertEqual(store.currentTPS, 0)
    }

    func testSessionResetClearsToolsAndUnsupportedBackendsHaveNoOverlay() {
        let (store, epoch) = makeStore()
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        store.apply(.toolActivity(requestID: request.id, events: [event(at: 0)]), epoch: epoch)
        store.sample(at: origin)
        store.beginBackendSession(kind: .vllm, epoch: UUID())
        store.apply(.toolActivity(requestID: request.id, events: [event(at: 1)]), epoch: epoch)
        store.sample(at: date(1))
        XCTAssertTrue(store.toolActivityEvents.isEmpty)
        XCTAssertTrue(store.toolObservationHistory.isEmpty)
        XCTAssertFalse(store.chartPresentation.supportsToolActivity)
        XCTAssertTrue(store.chartPresentation.toolActivity.isEmpty)
    }

    func testGPUResetPreservesHeldToolPublication() {
        let (store, epoch) = makeStore()
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: origin, activityPercent: 50, source: "GPU A", scope: .system),
            epoch: epoch)
        let request = GenerationRequest(startedAt: origin)
        let call = event(at: 0)
        store.apply(.began(request), epoch: epoch)
        store.apply(.toolActivity(requestID: request.id, events: [call]), epoch: epoch)
        store.sample(at: origin)
        let before = store.chartPresentation
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: date(0.1), activityPercent: 60, source: "GPU B", scope: .system),
            epoch: epoch)
        XCTAssertTrue(store.chartPresentation.systemGPU.isEmpty)
        XCTAssertEqual(store.chartPresentation.toolActivity, before.toolActivity)
        XCTAssertEqual(store.chartPresentation.requestLanes, before.requestLanes)
        XCTAssertEqual(store.chartPresentation.requestLanes.map(\.id), [request.id])
        XCTAssertEqual(store.chartPresentation.toolObservation, before.toolObservation)
        XCTAssertEqual(store.chartPresentation.timestamp, before.timestamp)
        XCTAssertTrue(store.chartPresentation.supportsToolActivity)
    }

    func testRetentionAndOverflowDoNotLeaveIncompleteObservationCoverage() {
        let (store, epoch) = makeStore()
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        store.sample(at: origin)
        let events = (0...MetricsStore.maxToolActivityEvents).map { index in
            event(at: Double(index) / 10_000)
        }
        store.apply(.toolActivity(requestID: request.id, events: events), epoch: epoch)
        XCTAssertEqual(store.toolActivityEvents.count, MetricsStore.maxToolActivityEvents)
        XCTAssertFalse(store.toolActivityEvents.contains(events[0]))
        XCTAssertTrue(store.toolObservationHistory.isEmpty)
        store.sample(at: date(1))
        XCTAssertTrue(store.toolObservationHistory.allSatisfy { $0.timestamp > origin })
        store.sample(at: date(MetricsStore.chartWindow + 2))
        XCTAssertTrue(store.toolActivityEvents.isEmpty)
        XCTAssertTrue(store.chartPresentation.toolActivity.isEmpty)
    }

    private func makeStore() -> (MetricsStore, UUID) {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.proxyState = .listening
        store.updateConnection(.ready, at: origin)
        return (store, epoch)
    }

    private func event(at offset: TimeInterval, name: String = "read_file") -> ToolActivityEvent {
        ToolActivityEvent(kind: .call, name: name, timestamp: date(offset))
    }

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }
}
