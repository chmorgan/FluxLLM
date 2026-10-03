import Dispatch
import Foundation
import XCTest

@testable import FluxLLM

final class GenerationRelayCadenceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testCompactStatesUseOneGlobalDeadlineAndMaterializeOnlyDeliveredSnapshot() {
        let relayScheduler = RelayTestScheduler()
        let inboxScheduler = RelayTestScheduler()
        let recorder = RelayTestRecorder()
        let inbox = GenerationEventInbox(
            schedule: inboxScheduler.schedule, makeSnapshot: recorder.makeSnapshot)
        defer { inbox.finish() }
        let relay = makeCumulativeRelay(inbox, relayScheduler)
        _ = inbox.drainReadyEvents()
        var state = TokenState()
        for index in 1...200 {
            let timestamp = origin.addingTimeInterval(Double(index) * 0.005)
            state.ingest(["response": "x"], at: timestamp)
            relay.update(state, at: timestamp)
        }
        XCTAssertEqual(recorder.snapshotConstructionCount, 0)
        XCTAssertEqual(relayScheduler.scheduledCount, 0, "No per-request deadline is installed")
        XCTAssertEqual(inboxScheduler.scheduledCount, 1)
        inboxScheduler.advance(by: .milliseconds(49))
        XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
        inboxScheduler.advance(by: .milliseconds(1))
        let batch = inbox.drainReadyBatch()
        XCTAssertEqual(batch.cumulativeStatesEnqueued, 200)
        XCTAssertEqual(batch.snapshotsMaterialized, 1)
        XCTAssertEqual(recorder.snapshotConstructionCount, 1)
        XCTAssertEqual(outputCounts(batch.events), [200])
        guard let event = batch.events.first, case .updated(_, let snapshot) = event else {
            return XCTFail("The surviving cumulative state must produce an update")
        }
        XCTAssertEqual(snapshot.timestamp, origin.addingTimeInterval(1))
        XCTAssertEqual(inboxScheduler.pendingCount, 0)
        inboxScheduler.advance(by: .seconds(60))
        XCTAssertTrue(
            inbox.drainReadyEvents().isEmpty, "Quiet tails must not create a repeating timer")
    }

    func testConcurrentCompactRequestsShareTwentyGlobalDeliveriesPerSecond() {
        let relayScheduler = RelayTestScheduler()
        let inboxScheduler = RelayTestScheduler()
        let recorder = RelayTestRecorder()
        let inbox = GenerationEventInbox(
            schedule: inboxScheduler.schedule, makeSnapshot: recorder.makeSnapshot)
        defer { inbox.finish() }
        let first = makeCumulativeRelay(inbox, relayScheduler)
        let second = makeCumulativeRelay(inbox, relayScheduler)
        _ = inbox.drainReadyEvents()
        var states = [TokenState(), TokenState()]
        var deliveries = 0
        var latestCounts: [Int] = []
        for index in 0..<200 {
            let timestamp = origin.addingTimeInterval(Double(index) * 0.005)
            for request in states.indices {
                states[request].ingest(["response": "x"], at: timestamp)
            }
            first.update(states[0], at: timestamp)
            second.update(states[1], at: timestamp)
            inboxScheduler.advance(by: .milliseconds(5))
            let batch = inbox.drainReadyBatch()
            if !batch.events.isEmpty {
                deliveries += 1
                XCTAssertEqual(batch.snapshotsMaterialized, 2)
                latestCounts = outputCounts(batch.events)
            }
            XCTAssertLessThanOrEqual(inboxScheduler.pendingCount, 1)
        }
        XCTAssertEqual(deliveries, 20)
        XCTAssertEqual(latestCounts, [200, 200])
        XCTAssertEqual(inboxScheduler.scheduledCount, 20)
        XCTAssertEqual(relayScheduler.scheduledCount, 0)
        XCTAssertEqual(
            recorder.snapshotConstructionCount, 40,
            "Each global delivery constructs one surviving snapshot per request")
    }

    func testCompactTerminalAndToolsAreAtomicAndDiscardSupersededEstimate() {
        let scheduler = RelayTestScheduler()
        let recorder = RelayTestRecorder()
        let inbox = GenerationEventInbox(
            schedule: scheduler.schedule, makeSnapshot: recorder.makeSnapshot)
        defer { inbox.finish() }
        let relay = makeCumulativeRelay(inbox, RelayTestScheduler())
        _ = inbox.drainReadyEvents()
        var state = TokenState()
        for index in 0..<10 {
            state.ingest(["response": "x"], at: origin.addingTimeInterval(Double(index) * 0.005))
            relay.update(state, at: origin.addingTimeInterval(Double(index) * 0.005))
        }
        let stale = scheduler.nextAction
        let call = ToolActivityEvent(kind: .call, name: "read", timestamp: origin)
        state.ingest(
            [
                "done": true, "eval_count": 3, "prompt_eval_count": 4,
                "eval_duration": NSNumber(value: 500_000_000),
            ], at: origin.addingTimeInterval(1))
        relay.update(state, at: origin.addingTimeInterval(1), toolEvents: [call])
        let batch = inbox.drainReadyBatch()
        let terminalRecorder = RelayTestRecorder()
        for event in batch.events { terminalRecorder.record(event) }
        XCTAssertEqual(terminalRecorder.kinds, ["tools:1", "finished:3"])
        XCTAssertEqual(batch.cumulativeStatesEnqueued, 11)
        XCTAssertEqual(batch.snapshotsMaterialized, 1)
        XCTAssertEqual(recorder.snapshotConstructionCount, 1)
        XCTAssertEqual(terminalRecorder.snapshots.first?.promptTokens, 4)
        XCTAssertEqual(terminalRecorder.snapshots.first?.authoritativeTPS, 6)
        XCTAssertEqual(scheduler.pendingCount, 0)
        stale?()
        relay.cancel()
        relay.fail("late")
        relay.update(state, at: origin.addingTimeInterval(2), toolEvents: [call])
        XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
    }

    func testCompactCancellationAndFailureFlushLatestAcceptedUsageWithoutDeadline() {
        for cancel in [false, true] {
            let scheduler = RelayTestScheduler()
            let inbox = GenerationEventInbox(schedule: scheduler.schedule)
            defer { inbox.finish() }
            let relay = makeCumulativeRelay(inbox, RelayTestScheduler())
            _ = inbox.drainReadyEvents()
            var state = TokenState()
            for index in 1...5 {
                let timestamp = origin.addingTimeInterval(Double(index) * 0.005)
                state.ingest(["response": "x"], at: timestamp)
                relay.update(state, at: timestamp)
            }
            if cancel { relay.cancel() } else { relay.fail("disconnected") }
            let recorder = RelayTestRecorder()
            for event in inbox.drainReadyEvents() { recorder.record(event) }
            XCTAssertEqual(recorder.kinds, ["live:5", cancel ? "cancelled" : "failed"])
            XCTAssertEqual(recorder.snapshots.first?.timestamp, origin.addingTimeInterval(0.025))
            XCTAssertEqual(scheduler.pendingCount, 0)
            relay.update(state, at: origin.addingTimeInterval(1))
            XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
        }
    }

    func testCompactErrorReplacesPendingEstimateAndRacingCancellationIsTerminalExactlyOnce() {
        for _ in 0..<40 {
            let scheduler = RelayTestScheduler()
            let inbox = GenerationEventInbox(schedule: scheduler.schedule)
            defer { inbox.finish() }
            let relay = makeCumulativeRelay(inbox, RelayTestScheduler())
            _ = inbox.drainReadyEvents()
            var state = TokenState()
            state.ingest(["response": "x"], at: origin)
            relay.update(state, at: origin)
            state.ingest(["error": "runner stopped"], at: origin.addingTimeInterval(0.01))
            let errorState = state
            let errorDate = origin.addingTimeInterval(0.01)
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { relay.update(errorState, at: errorDate) } else { relay.cancel() }
            }
            let events = inbox.drainReadyEvents()
            XCTAssertEqual(events.filter(isTerminal).count, 1)
            XCTAssertTrue(events.last.map(isTerminal) == true)
            XCTAssertEqual(outputCounts(events), [1])
            XCTAssertEqual(scheduler.pendingCount, 0)
            relay.fail("late")
            XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
        }
    }

    private func makeCumulativeRelay(
        _ inbox: GenerationEventInbox, _ scheduler: RelayTestScheduler
    ) -> GenerationRelay {
        GenerationRelay(
            request: GenerationRequest(startedAt: origin), sink: { inbox.submit($0) },
            schedule: scheduler.schedule,
            cumulativeSink: { id, state, timestamp, tools in
                inbox.submit(requestID: id, state: state, at: timestamp, toolEvents: tools)
            })
    }

    private func outputCounts(_ events: [GenerationEvent]) -> [Int] {
        events.compactMap {
            if case .updated(_, let snapshot) = $0 { snapshot.outputTokens } else { nil }
        }
    }

    func testTwoHundredRecordsPerSecondConstructAtMostTwentyPeriodicSnapshots() {
        let scheduler = RelayTestScheduler()
        let recorder = RelayTestRecorder()
        let relay = makeRelay(scheduler, recorder)
        var state = TokenState()

        for index in 0..<200 {
            let timestamp = origin.addingTimeInterval(Double(index) * 0.005)
            state.ingest(["response": "x", "done": false], at: timestamp)
            relay.update(state, at: timestamp)
            XCTAssertLessThanOrEqual(scheduler.pendingCount, 1)
            scheduler.advance(by: .milliseconds(5))
        }
        // No new records arrive: the final accepted state must still flush.
        scheduler.advance(by: .milliseconds(50))
        XCTAssertEqual(recorder.snapshots.last?.outputTokens, 200)
        XCTAssertEqual(recorder.snapshots.last?.timestamp, origin.addingTimeInterval(0.995))
        XCTAssertLessThanOrEqual(
            recorder.snapshotConstructionCount, 21,
            "One first-output snapshot plus at most 20 periodic snapshots")
        XCTAssertEqual(recorder.snapshotConstructionCount, recorder.snapshots.count)
        XCTAssertLessThanOrEqual(scheduler.scheduledCount, 20)
        XCTAssertEqual(scheduler.pendingCount, 0)
        let constructions = recorder.snapshotConstructionCount
        scheduler.advance(by: .seconds(60))
        XCTAssertEqual(recorder.snapshotConstructionCount, constructions, "No repeating idle timer")
    }

    func testQuietTailFlushesLatestCountAndRecordTimestampAtDeadline() {
        let scheduler = RelayTestScheduler()
        let recorder = RelayTestRecorder()
        let relay = makeRelay(scheduler, recorder)
        var state = TokenState()
        state.ingest(["response": "first"], at: origin)
        relay.update(state, at: origin)
        XCTAssertEqual(recorder.snapshots.map(\.outputTokens), [1])
        XCTAssertEqual(scheduler.scheduledCount, 0, "First output is immediate")

        let second = origin.addingTimeInterval(0.005)
        state.ingest(["response": "second"], at: second)
        relay.update(state, at: second)
        scheduler.advance(by: .milliseconds(20))
        let latest = origin.addingTimeInterval(0.025)
        state.ingest(["response": "third"], at: latest)
        relay.update(state, at: latest)
        XCTAssertEqual(scheduler.scheduledCount, 1, "Replacing state must not replace the timer")
        scheduler.advance(by: .milliseconds(29))
        XCTAssertEqual(recorder.snapshots.map(\.outputTokens), [1])
        scheduler.advance(by: .milliseconds(1))
        XCTAssertEqual(recorder.snapshots.map(\.outputTokens), [1, 3])
        XCTAssertEqual(recorder.snapshots.last?.timestamp, latest)
        XCTAssertEqual(recorder.snapshots.last?.elapsed ?? -1, 0.025, accuracy: 0.000_001)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testQuietTailReachesExistingInboxWithinTwoFiftyMillisecondStages() {
        let relayScheduler = RelayTestScheduler()
        let inboxScheduler = RelayTestScheduler()
        let inbox = GenerationEventInbox(schedule: inboxScheduler.schedule)
        defer { inbox.finish() }
        let relay = GenerationRelay(
            request: GenerationRequest(startedAt: origin),
            sink: { inbox.submit($0) }, schedule: relayScheduler.schedule)
        _ = inbox.drainReadyEvents()  // Immediate request beginning.
        var state = TokenState()
        state.ingest(["response": "one"], at: origin)
        relay.update(state, at: origin)
        inboxScheduler.advance(by: .milliseconds(50))
        _ = inbox.drainReadyEvents()

        let timestamp = origin.addingTimeInterval(0.005)
        state.ingest(["response": "two"], at: timestamp)
        relay.update(state, at: timestamp)
        relayScheduler.advance(by: .milliseconds(49))
        XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
        relayScheduler.advance(by: .milliseconds(1))
        XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
        inboxScheduler.advance(by: .milliseconds(49))
        XCTAssertTrue(inbox.drainReadyEvents().isEmpty)
        inboxScheduler.advance(by: .milliseconds(1))
        let snapshots = inbox.drainReadyEvents().compactMap { event -> GenerationSnapshot? in
            if case .updated(_, let snapshot) = event { return snapshot }
            return nil
        }
        XCTAssertEqual(snapshots.map(\.outputTokens), [2])
        XCTAssertEqual(snapshots.first?.timestamp, timestamp)
        XCTAssertEqual(relayScheduler.pendingCount, 0)
        XCTAssertEqual(inboxScheduler.pendingCount, 0)
    }

    func testFirstTextBypassesPreviouslyScheduledEmptyRecord() {
        let scheduler = RelayTestScheduler()
        let recorder = RelayTestRecorder()
        let relay = makeRelay(scheduler, recorder)
        var state = TokenState()
        state.ingest(["model": "fixture", "response": ""], at: origin)
        relay.update(state, at: origin)
        let stale = scheduler.nextAction
        XCTAssertTrue(recorder.snapshots.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 1)
        state.ingest(["response": "first"], at: origin.addingTimeInterval(0.01))
        relay.update(state, at: origin.addingTimeInterval(0.01))
        XCTAssertEqual(recorder.snapshots.map(\.outputTokens), [1])
        XCTAssertEqual(scheduler.pendingCount, 0)
        stale?()
        XCTAssertEqual(recorder.snapshots.map(\.outputTokens), [1])
    }

    func testToolsAndAuthoritativeTerminalBypassPendingDeadlineInOrder() {
        let scheduler = RelayTestScheduler()
        let recorder = RelayTestRecorder()
        let relay = makeRelay(scheduler, recorder)
        var state = TokenState()
        state.ingest(["response": "one"], at: origin)
        relay.update(state, at: origin)
        state.ingest(["response": "two"], at: origin.addingTimeInterval(0.005))
        relay.update(state, at: origin.addingTimeInterval(0.005))
        let stale = scheduler.nextAction
        let call = ToolActivityEvent(kind: .call, name: "read", timestamp: origin)
        relay.update(state, at: origin.addingTimeInterval(0.01), toolEvents: [call])
        XCTAssertEqual(recorder.kinds, ["began", "live:1", "tools:1", "live:2"])
        XCTAssertEqual(scheduler.pendingCount, 0)

        state.ingest(["response": "three"], at: origin.addingTimeInterval(0.015))
        relay.update(state, at: origin.addingTimeInterval(0.015))
        // JSONSerialization supplies NSNumber for native integer durations;
        // an unbridged Swift Int in this direct dictionary does not cast to Double.
        state.ingest(
            [
                "done": true, "eval_count": 1, "prompt_eval_count": 4,
                "eval_duration": NSNumber(value: 500_000_000),
            ], at: origin.addingTimeInterval(0.02))
        relay.update(state, at: origin.addingTimeInterval(0.02), toolEvents: [call])
        XCTAssertEqual(Array(recorder.kinds.suffix(2)), ["tools:1", "finished:1"])
        XCTAssertEqual(recorder.snapshots.last?.promptTokens, 4)
        XCTAssertEqual(recorder.snapshots.last?.authoritativeTPS, 2)
        XCTAssertEqual(scheduler.pendingCount, 0)
        let count = recorder.events.count
        stale?()
        scheduler.advance(by: .seconds(1))
        relay.cancel()
        relay.fail("late")
        relay.update(state, at: origin.addingTimeInterval(1), toolEvents: [call])
        XCTAssertEqual(recorder.events.count, count)
    }

    func testErrorRecordImmediatelyReplacesPendingEstimateAndKeepsItsTimestamp() {
        let scheduler = RelayTestScheduler()
        let recorder = RelayTestRecorder()
        let relay = makeRelay(scheduler, recorder)
        var state = TokenState()
        state.ingest(["response": "one"], at: origin)
        relay.update(state, at: origin)
        state.ingest(["response": "two"], at: origin.addingTimeInterval(0.005))
        relay.update(state, at: origin.addingTimeInterval(0.005))
        let errorDate = origin.addingTimeInterval(0.01)
        state.ingest(["error": "runner stopped"], at: errorDate)
        relay.update(state, at: errorDate)
        XCTAssertEqual(recorder.kinds, ["began", "live:1", "error:2"])
        XCTAssertEqual(recorder.snapshots.last?.timestamp, errorDate)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testCancelAndFailureFlushAcceptedCountBeforeTheirTerminalEvent() {
        for cancel in [false, true] {
            let scheduler = RelayTestScheduler()
            let recorder = RelayTestRecorder()
            let relay = makeRelay(scheduler, recorder)
            var state = TokenState()
            for index in 1...5 {
                let timestamp = origin.addingTimeInterval(Double(index) * 0.005)
                state.ingest(["response": "x"], at: timestamp)
                relay.update(state, at: timestamp)
            }
            let stale = scheduler.nextAction
            if cancel { relay.cancel() } else { relay.fail("disconnected") }
            XCTAssertEqual(
                recorder.kinds, ["began", "live:1", "live:5", cancel ? "cancelled" : "failed"])
            XCTAssertEqual(recorder.snapshots.last?.timestamp, origin.addingTimeInterval(0.025))
            XCTAssertEqual(scheduler.pendingCount, 0)
            let count = recorder.events.count
            stale?()
            scheduler.advance(by: .seconds(1))
            relay.update(state, at: origin.addingTimeInterval(1))
            XCTAssertEqual(recorder.events.count, count)
        }
    }

    func testRacingTerminalAndCancellationEmitExactlyOneTerminalAndNoLaterUpdates() {
        // Exercise terminal races under the relay's cross-side lock without
        // sleeps or wall-clock rate assertions. Replayed stale callbacks model
        // an already-dispatched scheduled action racing cancellation.
        for _ in 0..<40 {
            let scheduler = RelayTestScheduler()
            let recorder = RelayTestRecorder()
            let relay = makeRelay(scheduler, recorder)
            var state = TokenState()
            state.ingest(["response": "one"], at: origin)
            relay.update(state, at: origin)
            state.ingest(["response": "two"], at: origin.addingTimeInterval(0.005))
            relay.update(state, at: origin.addingTimeInterval(0.005))
            let stale = scheduler.nextAction
            let terminalDate = origin.addingTimeInterval(0.01)
            state.ingest(
                ["done": true, "eval_count": 2, "eval_duration": NSNumber(value: 1_000_000_000)],
                at: terminalDate)
            XCTAssertNil(state.snapshot().error)
            XCTAssertEqual(state.snapshot().authoritativeTPS, 2)
            let finalState = state
            DispatchQueue.concurrentPerform(iterations: 3) { index in
                switch index {
                case 0: relay.update(finalState, at: terminalDate)
                case 1: relay.cancel()
                default: stale?()
                }
            }
            let events = recorder.events
            let terminalIndices = events.indices.filter { isTerminal(events[$0]) }
            XCTAssertEqual(terminalIndices.count, 1)
            XCTAssertEqual(terminalIndices.first, events.indices.last)
            XCTAssertEqual(recorder.snapshots.last?.outputTokens, 2)
            XCTAssertEqual(scheduler.pendingCount, 0)
            let count = events.count
            stale?()
            relay.fail("late")
            scheduler.advance(by: .seconds(1))
            XCTAssertEqual(recorder.events.count, count)
        }
    }

    private func makeRelay(_ scheduler: RelayTestScheduler, _ recorder: RelayTestRecorder)
        -> GenerationRelay
    {
        GenerationRelay(
            request: GenerationRequest(startedAt: origin), sink: recorder.record,
            schedule: scheduler.schedule, makeSnapshot: recorder.makeSnapshot)
    }

    private func isTerminal(_ event: GenerationEvent) -> Bool {
        switch event {
        case .updated(_, let snapshot): snapshot.finished || snapshot.error != nil
        case .failed, .cancelled: true
        default: false
        }
    }
}

private final class RelayTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [GenerationEvent] = []
    private var constructions = 0

    var events: [GenerationEvent] { lock.withLock { storedEvents } }
    var snapshotConstructionCount: Int { lock.withLock { constructions } }
    var snapshots: [GenerationSnapshot] {
        events.compactMap { if case .updated(_, let snapshot) = $0 { snapshot } else { nil } }
    }
    var kinds: [String] {
        events.map {
            switch $0 {
            case .began: "began"
            case .toolActivity(_, let events): "tools:\(events.count)"
            case .updated(_, let snapshot):
                "\(snapshot.error != nil ? "error" : snapshot.finished ? "finished" : "live"):\(snapshot.outputTokens)"
            case .failed: "failed"
            case .cancelled: "cancelled"
            }
        }
    }

    func record(_ event: GenerationEvent) { lock.withLock { storedEvents.append(event) } }
    func makeSnapshot(_ state: TokenState, at timestamp: Date) -> GenerationSnapshot {
        lock.withLock { constructions += 1 }
        return state.snapshot(at: timestamp)
    }
}

private final class RelayTestScheduler: @unchecked Sendable {
    private struct Entry {
        let deadline: Duration
        let action: @Sendable () -> Void
    }
    private let lock = NSLock()
    private var now = Duration.zero
    private var entries: [Int: Entry] = [:]
    private var nextID = 0

    var pendingCount: Int { lock.withLock { entries.count } }
    var scheduledCount: Int { lock.withLock { nextID } }
    var nextAction: (@Sendable () -> Void)? {
        lock.withLock { entries.min { $0.key < $1.key }?.value.action }
    }

    func schedule(after delay: Duration, action: @escaping @Sendable () -> Void)
        -> GenerationEventInbox.Cancellation
    {
        let id = lock.withLock {
            nextID += 1
            entries[nextID] = Entry(deadline: now + delay, action: action)
            return nextID
        }
        return { [weak self] in self?.cancel(id) }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock {
            now += duration
            let due = entries.filter { $0.value.deadline <= now }.sorted { $0.key < $1.key }
            for (id, _) in due { entries.removeValue(forKey: id) }
            return due.map(\.value.action)
        }
        for action in due { action() }
    }

    private func cancel(_ id: Int) { _ = lock.withLock { entries.removeValue(forKey: id) } }
}
