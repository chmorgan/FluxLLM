import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class GenerationEventInboxCadenceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testReadyConsumerReceivesAtMostTwentyLiveBatchesPerSecond() async throws {
        let scheduler = ManualInboxScheduler()
        let inbox = GenerationEventInbox(schedule: scheduler.schedule)
        let request = GenerationRequest(startedAt: origin)
        var batches: [[GenerationEvent]] = []
        let consumer = Task { @MainActor in
            for await _ in inbox.notifications {
                batches.append(inbox.drainReadyEvents())
            }
        }
        defer {
            inbox.finish(deliveringPendingEvents: false)
            consumer.cancel()
        }
        inbox.submit(.began(request))
        try await waitForCondition("The consumer must be ready before streaming") {
            batches.count == 1
        }

        for batch in 1...20 {
            for offset in 1...100 {
                inbox.submit(update(request, count: (batch - 1) * 100 + offset))
                // Give the actual consumer a chance to process every token;
                // unlike the old burst test, MainActor is not held throughout.
                await Task.yield()
            }
            XCTAssertEqual(batches.count, batch)
            XCTAssertEqual(scheduler.pendingCount, 1)
            scheduler.advance(by: .milliseconds(49))
            await Task.yield()
            XCTAssertEqual(batches.count, batch, "Live updates must wait the full 50 ms")
            scheduler.advance(by: .milliseconds(1))
            try await waitForCondition("The latest live snapshot should be delivered at 50 ms") {
                batches.count >= batch + 1
            }
            XCTAssertEqual(batches.count, batch + 1)
            XCTAssertEqual(outputCounts(batches.last ?? []), [batch * 100])
        }

        inbox.finish()
        await consumer.value
        XCTAssertEqual(batches.count, 21, "One immediate begin plus 20 live batches")
        XCTAssertEqual(scheduler.scheduledCount, 20)
        XCTAssertEqual(scheduler.firedCount, 20)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testIdleInboxDoesNotScheduleAndIsolatedLiveUpdateHasBoundedLatency() {
        let scheduler = ManualInboxScheduler()
        let inbox = GenerationEventInbox(schedule: scheduler.schedule)
        let request = GenerationRequest(startedAt: origin)
        defer { inbox.finish() }
        scheduler.advance(by: .seconds(60))
        XCTAssertEqual(scheduler.scheduledCount, 0)

        inbox.submit(.began(request))
        XCTAssertEqual(inbox.drainReadyEvents().count, 1)
        inbox.submit(update(request, count: 1))
        XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
        scheduler.advance(by: .milliseconds(49))
        XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
        scheduler.advance(by: .milliseconds(1))
        XCTAssertEqual(outputCounts(inbox.drainReadyEvents()), [1])
        scheduler.advance(by: .seconds(60))
        XCTAssertEqual(scheduler.scheduledCount, 1, "No repeating timer while idle")
    }

    func testUrgentBeginPreservesOverlappingRequestOrderAndLatestOwnership() {
        let scheduler = ManualInboxScheduler()
        let inbox = GenerationEventInbox(schedule: scheduler.schedule)
        let store = MetricsStore(clock: { self.origin.addingTimeInterval(10) })
        let older = GenerationRequest(model: "older", startedAt: origin)
        let newer = GenerationRequest(model: "newer", startedAt: origin.addingTimeInterval(1))
        defer { inbox.finish() }
        inbox.submit(.began(older))
        apply(inbox.drainReadyEvents(), to: store)
        inbox.submit(update(older, count: 9))
        inbox.submit(.began(newer))
        let urgent = inbox.drainReadyEvents()
        XCTAssertEqual(kinds(urgent), ["live:9", "begin:newer"])
        XCTAssertEqual(scheduler.pendingCount, 0)
        apply(urgent, to: store)
        XCTAssertEqual(store.activeGeneration?.id, newer.id)
        XCTAssertEqual(store.outputTokens, 0)

        inbox.submit(update(newer, count: 3))
        inbox.submit(update(older, count: 12))
        scheduler.advance(by: .milliseconds(50))
        apply(inbox.drainReadyEvents(), to: store)
        XCTAssertEqual(store.outputTokens, 3)
        XCTAssertEqual(store.requestLanes.first(where: { $0.id == older.id })?.outputTokens, 12)
    }

    func testToolsAndCancellationBypassDeadlineWithoutLosingPendingCount() {
        for failed in [false, true] {
            let scheduler = ManualInboxScheduler()
            let inbox = GenerationEventInbox(schedule: scheduler.schedule)
            let request = GenerationRequest(startedAt: origin)
            let store = MetricsStore(clock: { self.origin.addingTimeInterval(10) })
            inbox.submit(.began(request))
            apply(inbox.drainReadyEvents(), to: store)
            inbox.submit(update(request, count: 5))
            let call = ToolActivityEvent(kind: .call, name: "read", timestamp: origin)
            inbox.submit(.toolActivity(requestID: request.id, events: [call]))
            let tools = inbox.drainReadyEvents()
            XCTAssertEqual(kinds(tools), ["live:5", "tools:1"])
            apply(tools, to: store)
            XCTAssertEqual(store.toolActivityEvents.map(\.id), [call.id])

            inbox.submit(update(request, count: 7))
            inbox.submit(update(request, count: 11))
            inbox.submit(
                failed
                    ? .failed(requestID: request.id, message: "Disconnected")
                    : .cancelled(requestID: request.id))
            let terminal = inbox.drainReadyEvents()
            XCTAssertEqual(kinds(terminal), ["live:11", failed ? "failed" : "cancelled"])
            apply(terminal, to: store)
            XCTAssertEqual(store.outputTokens, 11)
            XCTAssertEqual(store.activeGeneration?.state, failed ? .errored : .cancelled)
            XCTAssertEqual(scheduler.pendingCount, 0)
            scheduler.advance(by: .milliseconds(50))
            XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
            inbox.finish()
        }
    }

    func testAuthoritativeTerminalCorrectionIsImmediateAndReplacesEstimateExactly() {
        let scheduler = ManualInboxScheduler()
        let inbox = GenerationEventInbox(schedule: scheduler.schedule)
        let request = GenerationRequest(startedAt: origin)
        let store = MetricsStore(clock: { self.origin.addingTimeInterval(10) })
        defer { inbox.finish() }
        inbox.submit(.began(request))
        apply(inbox.drainReadyEvents(), to: store)
        inbox.submit(update(request, count: 100))
        scheduler.advance(by: .milliseconds(50))
        apply(inbox.drainReadyEvents(), to: store)
        XCTAssertEqual(store.outputTokens, 100)
        inbox.submit(update(request, count: 120))
        inbox.submit(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 92, promptTokens: 8, isEstimated: false,
                    authoritativeTPS: 42, finished: true,
                    timestamp: origin.addingTimeInterval(5))))
        let terminal = inbox.drainReadyEvents()
        XCTAssertEqual(kinds(terminal), ["finished:92"])
        apply(terminal, to: store)
        XCTAssertEqual(store.outputTokens, 92)
        XCTAssertEqual(store.promptTokens, 8)
        XCTAssertEqual(store.lastMeasuredTPS, 42)
        XCTAssertFalse(store.outputIsEstimated)
        let usage = store.usageSummary(in: DateInterval(start: origin, duration: 10))
        XCTAssertEqual(usage.outputTokens, 92)
        XCTAssertEqual(usage.requests, 1)
        XCTAssertEqual(usage.activeRequests, 0)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testTerminalErrorBypassesDeadlineWithItsOwnCumulativeUsage() {
        let scheduler = ManualInboxScheduler()
        let inbox = GenerationEventInbox(schedule: scheduler.schedule)
        let request = GenerationRequest(startedAt: origin)
        defer { inbox.finish() }
        inbox.submit(.began(request))
        _ = inbox.drainReadyEvents()
        inbox.submit(update(request, count: 50))
        inbox.submit(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(outputTokens: 41, error: "Error")))
        XCTAssertEqual(kinds(inbox.drainReadyEvents()), ["error:41"])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testDelayedOldEpochCannotMutateReconnectedStore() {
        let scheduler = ManualInboxScheduler()
        let inbox = GenerationEventInbox(schedule: scheduler.schedule)
        let store = MetricsStore(clock: { self.origin.addingTimeInterval(10) })
        let oldEpoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: oldEpoch, sourceID: "local")
        let request = GenerationRequest(startedAt: origin)
        inbox.submit(.began(request))
        apply(inbox.drainReadyEvents(), to: store, epoch: oldEpoch)
        inbox.submit(update(request, count: 100))
        store.beginBackendSession(kind: .ollama, epoch: UUID(), sourceID: "local")
        let interval = DateInterval(start: origin, duration: 10)
        let expected = store.usageSummary(in: interval)
        scheduler.advance(by: .milliseconds(50))
        apply(inbox.drainReadyEvents(), to: store, epoch: oldEpoch)
        XCTAssertNil(store.activeGeneration)
        XCTAssertEqual(store.usageSummary(in: interval), expected)
        inbox.finish()
    }

    func testFinishFlushesPendingLiveBatchAndRejectsLaterEvents() async {
        let scheduler = ManualInboxScheduler()
        let inbox = GenerationEventInbox(schedule: scheduler.schedule)
        let request = GenerationRequest(startedAt: origin)
        var iterator = inbox.notifications.makeAsyncIterator()
        inbox.submit(.began(request))
        _ = await iterator.next()
        _ = inbox.drainReadyEvents()
        inbox.submit(update(request, count: 17))
        inbox.finish()
        inbox.submit(update(request, count: 99))
        let signal: Void? = await iterator.next()
        XCTAssertNotNil(signal)
        XCTAssertEqual(outputCounts(inbox.drainReadyEvents()), [17])
        let end: Void? = await iterator.next()
        XCTAssertNil(end)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testDiscardFinishDropsEvenAlreadySignaledEvents() async {
        let scheduler = ManualInboxScheduler()
        let inbox = GenerationEventInbox(schedule: scheduler.schedule)
        let request = GenerationRequest(startedAt: origin)
        inbox.submit(.began(request))
        inbox.submit(update(request, count: 17))
        inbox.finish(deliveringPendingEvents: false)
        for await _ in inbox.notifications {
            XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
        }
        XCTAssertTrue(inbox.drain().isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testStaleNotificationAfterForcedDrainCannotBypassNextLiveDeadline() async {
        let scheduler = ManualInboxScheduler()
        let inbox = GenerationEventInbox(schedule: scheduler.schedule)
        let request = GenerationRequest(startedAt: origin)
        var iterator = inbox.notifications.makeAsyncIterator()
        defer { inbox.finish() }
        inbox.submit(.began(request))
        _ = inbox.drain()
        inbox.submit(update(request, count: 1))
        _ = await iterator.next()  // The buffered begin signal outlived the forced drain.
        XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
        scheduler.advance(by: .milliseconds(50))
        _ = await iterator.next()
        XCTAssertEqual(outputCounts(inbox.drainReadyEvents()), [1])
    }

    func testCanceledCallbackCannotWakeNewerBatchEarly() {
        let scheduler = ManualInboxScheduler()
        let inbox = GenerationEventInbox(schedule: scheduler.schedule)
        let request = GenerationRequest(startedAt: origin)
        defer { inbox.finish() }
        inbox.submit(.began(request))
        _ = inbox.drainReadyEvents()
        inbox.submit(update(request, count: 1))
        let canceledCallback = scheduler.nextAction
        inbox.submit(.toolActivity(requestID: request.id, events: []))
        _ = inbox.drainReadyEvents()
        inbox.submit(update(request, count: 2))
        canceledCallback?()  // Models cancellation racing an already dispatched callback.
        XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.advance(by: .milliseconds(50))
        XCTAssertEqual(outputCounts(inbox.drainReadyEvents()), [2])
    }

    private func update(_ request: GenerationRequest, count: Int) -> GenerationEvent {
        .updated(
            requestID: request.id,
            snapshot: GenerationSnapshot(
                outputTokens: count, liveTPS: 37, elapsed: 4,
                timestamp: origin.addingTimeInterval(4)))
    }

    private func apply(_ events: [GenerationEvent], to store: MetricsStore, epoch: UUID? = nil) {
        for event in events { store.apply(event, epoch: epoch) }
    }

    private func outputCounts(_ events: [GenerationEvent]) -> [Int] {
        events.compactMap {
            if case .updated(_, let snapshot) = $0 { return snapshot.outputTokens }
            return nil
        }
    }

    private func kinds(_ events: [GenerationEvent]) -> [String] {
        events.map {
            switch $0 {
            case .began(let request): "begin:\(request.model ?? "unknown")"
            case .toolActivity(_, let events): "tools:\(events.count)"
            case .updated(_, let snapshot):
                "\(snapshot.error != nil ? "error" : snapshot.finished ? "finished" : "live"):\(snapshot.outputTokens)"
            case .failed: "failed"
            case .cancelled: "cancelled"
            }
        }
    }
}

/// Advances deadlines without sleeping; callbacks run outside the scheduler
/// lock, so cancellation and submission can safely take the inbox lock.
private final class ManualInboxScheduler: @unchecked Sendable {
    private struct Entry {
        let deadline: Duration
        let action: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var now = Duration.zero
    private var entries: [Int: Entry] = [:]
    private var nextID = 0
    private var scheduled = 0
    private var fired = 0

    var pendingCount: Int { lock.withLock { entries.count } }
    var scheduledCount: Int { lock.withLock { scheduled } }
    var firedCount: Int { lock.withLock { fired } }
    var nextAction: (@Sendable () -> Void)? {
        lock.withLock { entries.min { $0.key < $1.key }?.value.action }
    }

    func schedule(after delay: Duration, action: @escaping @Sendable () -> Void)
        -> GenerationEventInbox.Cancellation
    {
        let id = lock.withLock {
            nextID += 1
            scheduled += 1
            entries[nextID] = Entry(deadline: now + delay, action: action)
            return nextID
        }
        return { [weak self] in
            self?.cancel(id)
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock {
            now += duration
            let due = entries.filter { $0.value.deadline <= now }.sorted { $0.key < $1.key }
            for (id, _) in due { entries.removeValue(forKey: id) }
            fired += due.count
            return due.map(\.value.action)
        }
        for action in due { action() }
    }

    private func cancel(_ id: Int) {
        _ = lock.withLock { entries.removeValue(forKey: id) }
    }
}
