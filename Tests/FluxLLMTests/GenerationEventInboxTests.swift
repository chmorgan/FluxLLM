import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class GenerationEventInboxTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testDelayedConsumerReceivesNewestSnapshotWithoutTokenBacklog() async {
        let inbox = GenerationEventInbox()
        let now = start.addingTimeInterval(30)
        let store = MetricsStore(clock: { now })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyBackendSample(BackendSample(kind: .ollama, timestamp: start), epoch: epoch)
        let request = GenerationRequest(model: "fixture", startedAt: start)
        let consumer = Task { @MainActor in
            var deliveries = 0
            var wakeups = 0
            for await _ in inbox.notifications {
                wakeups += 1
                for event in inbox.drain() {
                    deliveries += 1
                    store.apply(event, epoch: epoch)
                }
                store.sample(at: now)
            }
            return (deliveries, wakeups)
        }

        // This synchronous burst holds the main actor until every fragment is
        // queued, reproducing a busy UI without relying on timing or sleeps.
        inbox.submit(.began(request))
        for count in 1...10_000 {
            inbox.submit(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: count, liveTPS: 37, elapsed: Double(count) * 0.003,
                        timestamp: start.addingTimeInterval(Double(count) * 0.003))))
        }
        inbox.finish()
        let (deliveries, wakeups) = await consumer.value

        XCTAssertEqual(deliveries, 2)
        XCTAssertEqual(wakeups, 1)
        XCTAssertEqual(store.outputTokens, 10_000)
        XCTAssertEqual(store.currentTPS, 37)
        XCTAssertEqual(store.displayTPS, 37)
        XCTAssertEqual(BackendPresentation.rateLabel(store: store), "37.0")
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertTrue(store.rateIsAvailable)
        XCTAssertTrue(store.tpsHistory.last?.isAvailable == true)
        XCTAssertEqual(store.activeGeneration?.state, .running)
    }

    func testCoalescedUpdatesKeepTheirLatestPositionAcrossRequestBeginnings() {
        let inbox = GenerationEventInbox()
        let older = GenerationRequest(model: "older", startedAt: start)
        let newer = GenerationRequest(
            model: "newer", startedAt: start.addingTimeInterval(1))
        inbox.submit(.began(older))
        inbox.submit(update(older, count: 1))
        inbox.submit(.began(newer))
        inbox.submit(update(newer, count: 2))
        inbox.submit(update(older, count: 3))

        let events = inbox.drain()
        XCTAssertEqual(
            descriptions(events),
            ["begin:older", "begin:newer", "update:2", "update:3"])
        let store = MetricsStore()
        for event in events { store.apply(event) }
        XCTAssertEqual(store.activeGeneration?.id, newer.id)
        XCTAssertEqual(store.outputTokens, 2)
        XCTAssertTrue(inbox.drain().isEmpty)
        inbox.finish()
    }

    func testCompletionReplacesPendingLiveSnapshotAndPublishesFinalUsageAndModel() throws {
        let inbox = GenerationEventInbox()
        let request = GenerationRequest(model: "fixture", startedAt: start)
        inbox.submit(.began(request))
        for count in 1...1_000 {
            inbox.submit(update(request, count: count, model: "provider/resolved"))
        }
        inbox.submit(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    model: "provider/resolved", outputTokens: 920, promptTokens: 8,
                    isEstimated: false,
                    authoritativeTPS: 42, finished: true,
                    timestamp: start.addingTimeInterval(30))))

        let events = inbox.drain()
        XCTAssertEqual(descriptions(events), ["begin:fixture", "finished:920"])
        let store = MetricsStore(clock: { self.start.addingTimeInterval(30) })
        for event in events { store.apply(event) }
        XCTAssertEqual(store.outputTokens, 920)
        XCTAssertEqual(store.promptTokens, 8)
        XCTAssertEqual(store.lastMeasuredTPS, 42)
        XCTAssertFalse(store.outputIsEstimated)
        XCTAssertEqual(store.activeGeneration?.state, .completed)
        XCTAssertEqual(store.currentModel, "provider/resolved")
        let lane = try XCTUnwrap(store.requestLanes.first)
        XCTAssertEqual(lane.model, "provider/resolved")
        XCTAssertEqual(lane.outputTokens, 920)
        XCTAssertFalse(lane.outputIsEstimated)
        XCTAssertEqual(lane.endedAt, start.addingTimeInterval(30))
        XCTAssertEqual(lane.liveTPS, 0)
        XCTAssertEqual(store.currentTPS, 0)
        XCTAssertEqual(ChartInspectionContent.request(lane, at: start).title, "resolved")
        inbox.finish()
    }

    func testFailureAndCancellationPreserveLatestCountBeforeTerminalEvent() throws {
        for failed in [false, true] {
            let inbox = GenerationEventInbox()
            let request = GenerationRequest(model: "fixture", startedAt: start)
            inbox.submit(.began(request))
            inbox.submit(update(request, count: 1))
            inbox.submit(update(request, count: 29))
            inbox.submit(
                failed
                    ? .failed(requestID: request.id, message: "Disconnected")
                    : .cancelled(requestID: request.id))

            let events = inbox.drain()
            XCTAssertEqual(
                descriptions(events),
                ["begin:fixture", "update:29", failed ? "failed" : "cancelled"])
            let store = MetricsStore()
            for event in events { store.apply(event) }
            XCTAssertEqual(store.outputTokens, 29)
            XCTAssertEqual(store.activeGeneration?.state, failed ? .errored : .cancelled)
            let lane = try XCTUnwrap(store.requestLanes.first)
            XCTAssertEqual(lane.outputTokens, 29)
            XCTAssertTrue(lane.outputIsEstimated)
            inbox.finish()
        }
    }

    func testTerminalErrorSnapshotPreservesItsCumulativeUsage() throws {
        let inbox = GenerationEventInbox()
        let request = GenerationRequest(model: "fixture", startedAt: start)
        inbox.submit(.began(request))
        inbox.submit(update(request, count: 5))
        inbox.submit(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(outputTokens: 7, error: "Backend error")))
        let events = inbox.drain()
        XCTAssertEqual(descriptions(events), ["begin:fixture", "error:7"])
        let store = MetricsStore()
        for event in events { store.apply(event) }
        XCTAssertEqual(store.outputTokens, 7)
        XCTAssertEqual(store.activeGeneration?.state, .errored)
        let lane = try XCTUnwrap(store.requestLanes.first)
        XCTAssertEqual(lane.outputTokens, 7)
        XCTAssertTrue(lane.outputIsEstimated)
        inbox.finish()
    }

    func testOlderTerminalDoesNotDiscardNewerRequestsPendingSnapshot() {
        let inbox = GenerationEventInbox()
        let older = GenerationRequest(model: "older", startedAt: start)
        let newer = GenerationRequest(
            model: "newer", startedAt: start.addingTimeInterval(1))
        inbox.submit(.began(older))
        inbox.submit(update(older, count: 1))
        inbox.submit(.began(newer))
        inbox.submit(update(newer, count: 2))
        inbox.submit(update(older, count: 3))
        inbox.submit(.cancelled(requestID: older.id))
        inbox.submit(update(newer, count: 9))

        let events = inbox.drain()
        XCTAssertEqual(
            descriptions(events),
            ["begin:older", "begin:newer", "update:3", "cancelled", "update:9"])
        let store = MetricsStore()
        for event in events { store.apply(event) }
        XCTAssertEqual(store.activeGeneration?.id, newer.id)
        XCTAssertEqual(store.activeGeneration?.state, .running)
        XCTAssertEqual(store.outputTokens, 9)
        inbox.finish()
    }

    func testAllRequestBoundariesSurviveWhenSeveralRequestsFinishBeforeDrain() {
        let inbox = GenerationEventInbox()
        for index in 0..<10 {
            let request = GenerationRequest(
                model: "request-\(index)", startedAt: start.addingTimeInterval(Double(index)))
            inbox.submit(.began(request))
            inbox.submit(update(request, count: 1))
            inbox.submit(update(request, count: 100))
            inbox.submit(.cancelled(requestID: request.id))
        }
        let events = inbox.drain()
        XCTAssertEqual(events.count, 30)
        for index in 0..<10 {
            XCTAssertEqual(
                descriptions(Array(events[(index * 3)..<(index * 3 + 3)])),
                ["begin:request-\(index)", "update:100", "cancelled"])
        }
        inbox.finish()
    }

    func testFreshSnapshotsArriveAfterPreviousBatchWasDrained() async {
        let inbox = GenerationEventInbox()
        let request = GenerationRequest(model: "fixture", startedAt: start)
        var iterator = inbox.notifications.makeAsyncIterator()
        inbox.submit(.began(request))
        inbox.submit(update(request, count: 3))
        let firstSignal: Void? = await iterator.next()
        XCTAssertNotNil(firstSignal)
        XCTAssertEqual(descriptions(inbox.drain()), ["begin:fixture", "update:3"])

        inbox.submit(update(request, count: 5))
        inbox.submit(update(request, count: 8))
        inbox.finish()
        inbox.submit(update(request, count: 99))
        let secondSignal: Void? = await iterator.next()
        XCTAssertNotNil(secondSignal)
        XCTAssertEqual(descriptions(inbox.drain()), ["update:8"])
        let finalSignal: Void? = await iterator.next()
        XCTAssertNil(finalSignal)
    }

    func testDiscreteToolEventsSurviveCoalescingAndTerminalSnapshotInOrder() {
        let inbox = GenerationEventInbox()
        let request = GenerationRequest(model: "fixture", startedAt: start)
        let first = ToolActivityEvent(kind: .call, name: "read_file", timestamp: start)
        let result = ToolActivityEvent(
            kind: .resultSubmission, name: "read_file", timestamp: start.addingTimeInterval(1))
        let last = ToolActivityEvent(
            kind: .call, name: "search", timestamp: start.addingTimeInterval(2))
        inbox.submit(.began(request))
        inbox.submit(.toolActivity(requestID: request.id, events: [first]))
        for count in 1...1_000 { inbox.submit(update(request, count: count)) }
        inbox.submit(.toolActivity(requestID: request.id, events: [result, last]))
        inbox.submit(
            .updated(requestID: request.id, snapshot: GenerationSnapshot(finished: true)))

        let events = inbox.drain()
        XCTAssertEqual(
            descriptions(events), ["begin:fixture", "tools:1", "tools:2", "finished:0"])
        let activity = events.flatMap { event -> [ToolActivityEvent] in
            if case .toolActivity(let requestID, let records) = event {
                XCTAssertEqual(requestID, request.id)
                return records
            }
            return []
        }
        XCTAssertEqual(activity, [first, result, last])
        inbox.finish()
    }

    func testRelayPublishesCallsBeforeTerminalSnapshotAndIgnoresLateActivity() {
        let inbox = GenerationEventInbox()
        let request = GenerationRequest(model: "fixture", startedAt: start)
        let relay = GenerationRelay(request: request, sink: { inbox.submit($0) })
        let result = ToolActivityEvent(kind: .resultSubmission, timestamp: start)
        let call = ToolActivityEvent(kind: .call, name: "search", timestamp: start)
        relay.toolActivity([result])
        relay.update(GenerationSnapshot(finished: true), toolEvents: [call])
        relay.toolActivity([call])
        relay.update(GenerationSnapshot(), toolEvents: [call])
        relay.fail("late failure")
        relay.cancel()

        XCTAssertEqual(
            descriptions(inbox.drain()), ["begin:fixture", "tools:1", "tools:1", "finished:0"])
        inbox.finish()
    }

    private func update(
        _ request: GenerationRequest, count: Int, model: String? = nil
    ) -> GenerationEvent {
        .updated(
            requestID: request.id,
            snapshot: GenerationSnapshot(
                model: model, outputTokens: count, liveTPS: 37, elapsed: 4,
                timestamp: start.addingTimeInterval(4)))
    }

    private func descriptions(_ events: [GenerationEvent]) -> [String] {
        events.map { event in
            switch event {
            case .began(let request):
                return "begin:\(request.model ?? "unknown")"
            case .toolActivity(_, let events):
                return "tools:\(events.count)"
            case .updated(_, let snapshot):
                let kind =
                    snapshot.error != nil ? "error" : (snapshot.finished ? "finished" : "update")
                return "\(kind):\(snapshot.outputTokens)"
            case .failed:
                return "failed"
            case .cancelled:
                return "cancelled"
            }
        }
    }
}
