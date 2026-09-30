import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class UsageHistoryViewportTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let source = "ollama:viewport"

    func testViewportIncludesLongRunningOverlapAndExcludesOldCompletionsAndOtherSources() {
        let history = UsageHistory(now: origin)
        let spanning = addRequest(history, id: 1, start: -100, end: 15)
        let active = addRequest(history, id: 2, start: -90)
        _ = addRequest(history, id: 3, start: -80, end: 9.5)
        let touchingStart = addRequest(history, id: 4, start: -70, end: 10)
        _ = addRequest(history, id: 5, start: 20.5)
        _ = addRequest(history, id: 6, start: 21, end: 22)
        _ = addRequest(history, id: 1, start: -100, end: 15, source: "other")

        XCTAssertEqual(
            history.requestLanes(source: source, interval: interval(10, 20)),
            [spanning, active, touchingStart])
        XCTAssertEqual(
            history.requestLanes(source: "other", interval: interval(10, 20)).map(\.id),
            [spanning.id])
        XCTAssertTrue(history.requestLanes(source: "missing", interval: interval(10, 20)).isEmpty)
    }

    func testInclusiveChartEndAddsBoundaryRequestsAndEventsWithoutChangingUsageAccounting() {
        let history = UsageHistory(now: origin)
        let earlier = addRequest(history, id: 1, start: 0)
        // Insert equal-start requests in reverse UUID order and different states.
        let atEndActive = addRequest(history, id: 3, start: 20)
        let atEndCompleted = addRequest(history, id: 2, start: 20, end: 20)
        _ = addRequest(history, id: 4, start: 20.5)
        let atStart = event(id: 10, at: 10)
        let atEnd = event(id: 11, at: 20)
        let afterEnd = event(id: 12, at: 20.5)
        history.apply(
            .toolActivity(requestID: earlier.id, events: [afterEnd, atEnd, atStart]),
            source: source, at: date(21))

        let viewport = interval(10, 20)
        XCTAssertEqual(history.requestLanes(source: source, interval: viewport), [earlier])
        XCTAssertEqual(
            history.requestLanes(source: source, interval: viewport, inclusiveEnd: true),
            [earlier, atEndCompleted, atEndActive])
        XCTAssertEqual(history.toolEvents(source: source, interval: viewport), [atStart])
        XCTAssertEqual(
            history.toolEvents(source: source, interval: viewport, inclusiveEnd: true),
            [atStart, atEnd])
        let usage = history.summary(
            scope: .selectedPeriod, source: source, interval: viewport, now: date(21))
        XCTAssertEqual(usage.requests, 0)
        XCTAssertEqual(usage.toolCalls, 1)
    }

    func testIndexedViewportQueriesMatchReferenceOverlapAndEventFilters() {
        let history = UsageHistory(now: origin)
        var lanes: [(source: String, value: RequestLane)] = []
        var events: [(source: String, value: ToolActivityEvent)] = []
        // Shuffled starts and completion durations prevent either index from
        // accidentally passing by relying on insertion or request-start order.
        for index in 0..<150 {
            let owner = index.isMultiple(of: 3) ? "other" : source
            let start = Double((index * 73) % 800) / 4
            let end: TimeInterval? =
                index.isMultiple(of: 5) ? nil : start + Double((index * 11) % 400) / 8
            let lane = addRequest(history, id: index + 1, start: start, end: end, source: owner)
            lanes.append((owner, lane))
            let tool = event(id: 1_000 + index, at: start + Double((index * 7) % 40) / 8)
            history.apply(
                .toolActivity(requestID: lane.id, events: [tool]), source: owner,
                at: tool.timestamp)
            events.append((owner, tool))
        }
        let edges: [TimeInterval] = [-1, 0, 10, 40, 60, 99.5, 150, 200, 300]
        for owner in [source, "other", "missing"] {
            for lower in edges {
                for upper in edges where upper > lower {
                    let viewport = interval(lower, upper)
                    for inclusiveEnd in [false, true] {
                        var expectedLanes: [RequestLane] = []
                        for entry in lanes where entry.source == owner {
                            let lane: RequestLane = entry.value
                            let startsBeforeEnd =
                                lane.startedAt < viewport.end
                                || (inclusiveEnd && lane.startedAt == viewport.end)
                            let overlapsStart = lane.endedAt.map { $0 >= viewport.start } ?? true
                            if startsBeforeEnd && overlapsStart { expectedLanes.append(lane) }
                        }
                        expectedLanes.sort { (left: RequestLane, right: RequestLane) in
                            if left.startedAt == right.startedAt {
                                return left.id.uuidString < right.id.uuidString
                            }
                            return left.startedAt < right.startedAt
                        }
                        XCTAssertEqual(
                            history.requestLanes(
                                source: owner, interval: viewport, inclusiveEnd: inclusiveEnd),
                            expectedLanes)
                        var expectedEvents: [ToolActivityEvent] = []
                        for entry in events where entry.source == owner {
                            let event: ToolActivityEvent = entry.value
                            let beforeEnd =
                                event.timestamp < viewport.end
                                || (inclusiveEnd && event.timestamp == viewport.end)
                            if event.timestamp >= viewport.start && beforeEnd {
                                expectedEvents.append(event)
                            }
                        }
                        let actualEvents = history.toolEvents(
                            source: owner, interval: viewport, inclusiveEnd: inclusiveEnd)
                        XCTAssertEqual(Set(actualEvents.map(\.id)), Set(expectedEvents.map(\.id)))
                        XCTAssertEqual(actualEvents.count, expectedEvents.count)
                        XCTAssertEqual(
                            actualEvents.map(\.timestamp), actualEvents.map(\.timestamp).sorted())
                    }
                }
            }
        }
    }

    func testCompletedIndexRefreshesAfterActiveCompletionAndCapacityEviction() {
        let history = UsageHistory(now: origin, recordLimit: 2)
        let first = addRequest(history, id: 1, start: 0)
        let viewport = interval(10, 20)
        XCTAssertEqual(history.requestLanes(source: source, interval: viewport), [first])
        history.apply(.cancelled(requestID: first.id), source: source, at: date(9))
        XCTAssertTrue(history.requestLanes(source: source, interval: viewport).isEmpty)

        let second = addRequest(history, id: 2, start: 1, end: 15)
        XCTAssertEqual(history.requestLanes(source: source, interval: viewport), [second])
        let third = addRequest(history, id: 3, start: 2, end: 16)
        XCTAssertEqual(history.requestLanes(source: source, interval: viewport), [second, third])
        let fourth = addRequest(history, id: 4, start: 11)
        XCTAssertEqual(history.requestLanes(source: source, interval: viewport), [third, fourth])
        XCTAssertEqual(
            history.summary(
                scope: .selectedPeriod, source: source, interval: viewport, now: date(20)
            ).requests, 1)
    }

    func testToolOwnershipSurvivesClippingAndDeduplicationUntilItsLastEventIsEvicted() {
        let history = UsageHistory(now: origin, toolEventLimit: 2)
        let first = addRequest(history, id: 1, start: 0)
        let second = addRequest(history, id: 2, start: 0)
        let other = addRequest(history, id: 1, start: 0, source: "other")
        XCTAssertTrue(history.requestIDsWithToolEvents(source: source).isEmpty)
        XCTAssertTrue(history.requestIDsWithToolEvents(source: "missing").isEmpty)

        let call = event(id: 10, at: 1)
        let duplicateCall = ToolActivityEvent(
            id: id(11), kind: .call, callID: call.callID, timestamp: date(1.5))
        let result = ToolActivityEvent(
            id: id(12), kind: .resultSubmission, callID: call.callID, timestamp: date(2))
        history.apply(
            .toolActivity(requestID: first.id, events: [call, duplicateCall, result, result]),
            source: source, at: date(2))
        XCTAssertEqual(history.requestIDsWithToolEvents(source: source), Set([first.id]))
        XCTAssertTrue(history.requestIDsWithToolEvents(source: "other").isEmpty)
        XCTAssertTrue(history.toolEvents(source: source, interval: interval(0, 0.5)).isEmpty)
        XCTAssertEqual(history.requestIDsWithToolEvents(source: source), Set([first.id]))

        history.apply(
            .toolActivity(requestID: second.id, events: [event(id: 20, at: 3)]),
            source: source, at: date(3))
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source), Set([first.id, second.id]))
        history.apply(
            .toolActivity(requestID: second.id, events: [event(id: 21, at: 4)]),
            source: source, at: date(4))
        XCTAssertEqual(history.requestIDsWithToolEvents(source: source), Set([second.id]))

        history.apply(
            .toolActivity(requestID: other.id, events: [event(id: 30, at: 5)]),
            source: "other", at: date(5))
        XCTAssertEqual(history.requestIDsWithToolEvents(source: source), Set([second.id]))
        XCTAssertEqual(history.requestIDsWithToolEvents(source: "other"), Set([other.id]))
        history.apply(
            .toolActivity(requestID: other.id, events: [event(id: 31, at: 6)]),
            source: "other", at: date(6))
        XCTAssertTrue(history.requestIDsWithToolEvents(source: source).isEmpty)
        XCTAssertEqual(history.requestIDsWithToolEvents(source: "other"), Set([other.id]))
    }

    func testRetentionPruningRemovesToolOwnershipAcrossSources() {
        let history = UsageHistory(now: origin)
        for owner in [source, "other"] {
            let request = addRequest(history, id: 1, start: 0, source: owner)
            history.apply(
                .toolActivity(requestID: request.id, events: [event(id: 10, at: 1)]),
                source: owner, at: date(1))
            XCTAssertEqual(history.requestIDsWithToolEvents(source: owner), Set([request.id]))
        }
        _ = addRequest(history, id: 2, start: UsageHistory.retentionInterval + 2)
        XCTAssertTrue(history.requestIDsWithToolEvents(source: source).isEmpty)
        XCTAssertTrue(history.requestIDsWithToolEvents(source: "other").isEmpty)
    }

    func testBoundedToolOwnershipUsesOnlyEventsInsideTheHalfOpenDay() {
        let history = UsageHistory(now: origin)
        let oldOnly = addRequest(history, id: 1, start: 0)
        let oldAndRecent = addRequest(history, id: 2, start: 0)
        let atStart = addRequest(history, id: 3, start: 0)
        let atEnd = addRequest(history, id: 4, start: 0)
        let other = addRequest(history, id: 5, start: 0, source: "other")
        for (request, owner, offsets) in [
            (oldOnly, source, [9.0]),
            (oldAndRecent, source, [9.0, 11.0]),
            (atStart, source, [10.0]),
            (atEnd, source, [86_410.0]),
            (other, "other", [11.0]),
        ] {
            for (index, offset) in offsets.enumerated() {
                history.apply(
                    .toolActivity(
                        requestID: request.id, events: [event(id: 100 + index, at: offset)]),
                    source: owner, at: date(offset))
            }
        }
        let day = interval(10, 86_410)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source, interval: day),
            Set([oldAndRecent.id, atStart.id]))
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: "other", interval: day), Set([other.id]))
        XCTAssertTrue(history.requestIDsWithToolEvents(source: "missing", interval: day).isEmpty)
        XCTAssertEqual(
            history.requestIDsWithToolEvents(source: source),
            Set([oldOnly.id, oldAndRecent.id, atStart.id, atEnd.id]))
        XCTAssertEqual(history.requestLanes(source: source, interval: day).count, 4)
    }

    private func addRequest(
        _ history: UsageHistory, id value: Int, start: TimeInterval, end: TimeInterval? = nil,
        source: String? = nil
    ) -> RequestLane {
        let owner = source ?? self.source
        let request = GenerationRequest(
            id: id(value), model: "model-\(value % 3)", startedAt: date(start))
        history.apply(.began(request), source: owner, at: request.startedAt)
        history.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: value, liveTPS: 5, timestamp: date(start))),
            source: owner, at: date(start))
        if let end {
            history.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: value, isEstimated: false, finished: true,
                        timestamp: date(end))),
                source: owner, at: date(end))
        }
        return RequestLane(
            id: request.id, startedAt: request.startedAt, endedAt: end.map(date),
            model: request.model,
            outputTokens: value, outputIsEstimated: end == nil, liveTPS: 5, terminal: end != nil)
    }

    private func event(id value: Int, at offset: TimeInterval) -> ToolActivityEvent {
        ToolActivityEvent(
            id: id(value), kind: .call, name: "test-tool", callID: "call-\(value)",
            timestamp: date(offset))
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }

    private func interval(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval {
        DateInterval(start: date(start), end: date(end))
    }
}
