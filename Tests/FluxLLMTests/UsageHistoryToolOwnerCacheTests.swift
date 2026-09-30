import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class UsageHistoryToolOwnerCacheTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let source = "ollama:tool-owner-cache"

    func testRollingQueriesMatchReferenceAcrossEndpointAndSourceChanges() {
        let history = UsageHistory(now: origin)
        var ledger: [(source: String, requestID: UUID, timestamp: Date)] = []
        let fixtures: [(String, Int, [TimeInterval])] = [
            (source, 1, [0, 2, 2, 6, 10, 12]),
            (source, 2, [1, 3, 9, 15]),
            ("other", 1, [2, 8, 11]),
            ("other", 3, [0, 4, 12]),
        ]
        for (owner, number, offsets) in fixtures {
            let request = begin(history, id: number, source: owner)
            var events: [ToolActivityEvent] = []
            for (index, offset) in offsets.enumerated() {
                events.append(event(id: index + 100, at: offset))
                ledger.append((owner, request.id, date(offset)))
            }
            apply(events, to: request, history: history, source: owner)
        }
        let queries: [(String, TimeInterval, TimeInterval)] = [
            (source, 0, 5), (source, 1, 6), (source, 2, 12), (source, 10, 14),
            (source, 4, 8), (source, 3, 10), (source, 4, 9),
            (source, 10, 10), (source, 10, 12), (source, 20, 25), (source, 25, 25),
            (source, 0, 20), ("other", 1, 5), ("other", 2, 12),
            (source, 2, 12), ("missing", 0, 20), (source, 2, 12),
        ]
        for (owner, lower, upper) in queries {
            let window = interval(lower, upper)
            var expected: Set<UUID> = []
            for entry in ledger where entry.source == owner {
                if entry.timestamp >= window.start && entry.timestamp < window.end {
                    expected.insert(entry.requestID)
                }
            }
            XCTAssertEqual(
                history.requestIDsWithToolEvents(source: owner, interval: window), expected,
                "Source \(owner), interval [\(lower), \(upper))")
        }
    }

    func testSlidingWindowKeepsAnOwnerUntilItsLastContributionLeaves() {
        let history = UsageHistory(now: origin)
        let first = begin(history, id: 1)
        let second = begin(history, id: 2)
        let third = begin(history, id: 3)
        apply(
            [
                event(id: 10, at: 0), event(id: 11, at: 1),
                event(id: 12, at: 5, kind: .resultSubmission),
            ],
            to: first, history: history)
        apply([event(id: 20, at: 2), event(id: 21, at: 4)], to: second, history: history)
        apply([event(id: 30, at: 6)], to: third, history: history)

        let queries: [(TimeInterval, TimeInterval, Set<UUID>)] = [
            (0, 6, Set([first.id, second.id])),
            (1, 6, Set([first.id, second.id])),
            (2, 6, Set([first.id, second.id])),
            (5, 7, Set([first.id, third.id])),
            (6, 7, Set([third.id])),
            (7, 8, []),
        ]
        for (lower, upper, expected) in queries {
            XCTAssertEqual(
                history.requestIDsWithToolEvents(source: source, interval: interval(lower, upper)),
                expected)
        }
    }

    func testDuplicatesAndRequestUpdatesReuseCacheButNewToolEventsInvalidateIt() {
        let history = UsageHistory(now: origin)
        let first = begin(history, id: 1)
        let second = begin(history, id: 2)
        let original = event(id: 10, at: 4, callID: "same-call")
        apply([event(id: 11, at: 0), original], to: first, history: history)
        let window = interval(0, 10)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window), Set([first.id]))
        let initialVisits = history.toolOwnerQueryVisitedEvents
        XCTAssertGreaterThan(initialVisits, 0)

        let sameCallWithNewEventID = event(id: 12, at: 6, callID: "same-call")
        apply([original, sameCallWithNewEventID], to: first, history: history)
        history.apply(
            .updated(
                requestID: first.id,
                snapshot: GenerationSnapshot(outputTokens: 20, timestamp: date(7))),
            source: source, at: date(7))
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window), Set([first.id]))
        XCTAssertEqual(history.toolOwnerQueryVisitedEvents, initialVisits)

        // Insert before the old upper index: a stale index/cache would miss this owner.
        apply([event(id: 20, at: 5)], to: second, history: history)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window),
            Set([first.id, second.id]))
        XCTAssertGreaterThan(history.toolOwnerQueryVisitedEvents, initialVisits)
        let afterInsertion = history.toolOwnerQueryVisitedEvents
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window),
            Set([first.id, second.id]))
        XCTAssertEqual(history.toolOwnerQueryVisitedEvents, afterInsertion)

        apply([event(id: 21, at: 100)], to: second, history: history)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window),
            Set([first.id, second.id]))
        XCTAssertGreaterThan(history.toolOwnerQueryVisitedEvents, afterInsertion)
    }

    func testCapacityEvictionInvalidatesCachedCountsAndUnboundedOwnership() {
        let history = UsageHistory(now: origin, toolEventLimit: 3)
        let first = begin(history, id: 1)
        let second = begin(history, id: 2)
        let third = begin(history, id: 3)
        apply([event(id: 10, at: 0), event(id: 11, at: 2)], to: first, history: history)
        apply([event(id: 20, at: 1)], to: second, history: history)
        let window = interval(0, 10)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window),
            Set([first.id, second.id]))

        apply([event(id: 30, at: 3)], to: third, history: history)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window),
            Set([first.id, second.id, third.id]))
        apply([event(id: 31, at: 4)], to: third, history: history)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window),
            Set([first.id, third.id]))
        apply([event(id: 32, at: 5)], to: third, history: history)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window), Set([third.id]))
        XCTAssertEqual(history.requestIDsWithToolEvents(source: source), Set([third.id]))
        let afterEvictions = history.toolOwnerQueryVisitedEvents
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window), Set([third.id]))
        XCTAssertEqual(history.toolOwnerQueryVisitedEvents, afterEvictions)
    }

    func testRetentionPruningWithoutInsertionInvalidatesCachedOwnership() {
        let history = UsageHistory(now: origin)
        let old = begin(history, id: 1)
        let recent = begin(history, id: 2)
        apply([event(id: 10, at: 1)], to: old, history: history)
        let retention = UsageHistory.retentionInterval
        apply([event(id: 20, at: retention - 1)], to: recent, history: history)
        let window = interval(0, retention + 120)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window),
            Set([old.id, recent.id]))
        let beforePrune = history.toolOwnerQueryVisitedEvents

        // Advance beyond both retention and the pruning cadence without adding a tool.
        history.apply(
            .updated(
                requestID: recent.id,
                snapshot: GenerationSnapshot(outputTokens: 10, timestamp: date(retention + 61))),
            source: source, at: date(retention + 61))
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: window), Set([recent.id]))
        XCTAssertGreaterThan(history.toolOwnerQueryVisitedEvents, beforePrune)
        XCTAssertEqual(history.requestIDsWithToolEvents(source: source), Set([recent.id]))
    }

    func testRepeatedAndSlidingLargeWindowVisitsOnlyCrossedEvents() {
        let history = UsageHistory(now: origin)
        let request = begin(history, id: 1)
        // One request and one insertion batch keep setup linear apart from the
        // single index sort; this test measures query work, not fixture churn.
        let events = (0..<38_000).map { event(id: 1_000 + $0, at: Double($0)) }
        apply(events, to: request, history: history)
        let expected: Set<UUID> = [request.id]
        let initialWindow = interval(0, 37_990)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: initialWindow), expected)
        let initialVisits = history.toolOwnerQueryVisitedEvents
        XCTAssertGreaterThanOrEqual(initialVisits, 37_990)
        for _ in 0..<30 {
            XCTAssertEqual(
                history.requestIDsWithToolEvents(source: source, interval: initialWindow), expected)
        }
        XCTAssertEqual(history.toolOwnerQueryVisitedEvents, initialVisits)

        // Unbounded lookups must not evict the separate rolling-window query.
        XCTAssertEqual(history.requestIDsWithToolEvents(source: source), expected)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: initialWindow), expected)
        XCTAssertEqual(history.toolOwnerQueryVisitedEvents, initialVisits)

        for step in 1...8 {
            XCTAssertEqual(
                history.requestIDsWithToolEvents(
                    source: source, interval: interval(Double(step), 37_990 + Double(step))),
                expected)
        }
        let slidingVisits = history.toolOwnerQueryVisitedEvents - initialVisits
        XCTAssertGreaterThan(slidingVisits, 0)
        XCTAssertLessThanOrEqual(
            slidingVisits, 32,
            "Eight one-event slides must examine boundary changes, not rescan the 38k-event window")
        let afterSliding = history.toolOwnerQueryVisitedEvents
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: interval(8, 37_998)),
            expected)
        XCTAssertEqual(history.toolOwnerQueryVisitedEvents, afterSliding)
    }

    private func begin(_ history: UsageHistory, id value: Int, source: String? = nil)
        -> GenerationRequest
    {
        let request = GenerationRequest(id: identifier(value), startedAt: origin)
        history.apply(.began(request), source: source ?? self.source, at: origin)
        return request
    }

    private func apply(
        _ events: [ToolActivityEvent], to request: GenerationRequest, history: UsageHistory,
        source: String? = nil
    ) {
        history.apply(
            .toolActivity(requestID: request.id, events: events), source: source ?? self.source,
            at: events.map(\.timestamp).max() ?? origin)
    }

    private func event(
        id value: Int, at offset: TimeInterval, kind: ToolActivityEvent.Kind = .call,
        callID: String? = nil
    ) -> ToolActivityEvent {
        ToolActivityEvent(
            id: identifier(value), kind: kind, callID: callID, timestamp: date(offset))
    }

    private func identifier(_ value: Int) -> UUID {
        UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)
            ))
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }

    private func interval(_ lower: TimeInterval, _ upper: TimeInterval) -> DateInterval {
        DateInterval(start: date(lower), end: date(upper))
    }
}
