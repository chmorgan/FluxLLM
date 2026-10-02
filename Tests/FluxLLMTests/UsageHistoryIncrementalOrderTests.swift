import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class UsageHistoryIncrementalOrderTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let source = "incremental-order"

    func testWarmedPopulatedHistoryAppendsNewWorkWithoutRebuildingEitherOrder() throws {
        try withMode {
            let history = UsageHistory(now: origin)
            for index in 0..<1_000 {
                let request = begin(history, at: Double(index))
                tools(
                    history, request,
                    events: [
                        event(at: Double(index) + 0.1),
                        event(at: Double(index) + 0.2, kind: .resultSubmission),
                    ])
                finish(history, request, at: Double(index) + 0.3)
            }
            XCTAssertEqual(
                history.requestLanes(source: source, interval: interval(0, 1_000)).count, 1_000)
            XCTAssertEqual(
                history.toolEvents(source: source, interval: interval(0, 1_000)).count, 2_000)
            XCTAssertEqual(
                history.requestIDsWithToolEvents(source: source, interval: interval(0, 1_000))
                    .count, 1_000)
            let visits = history.toolOwnerQueryVisitedEvents
            XCTAssertEqual(history.completedOrderBuildCount, 1)
            XCTAssertEqual(history.toolOrderBuildCount, 1)

            for index in 1_001...1_002 {
                let request = begin(history, at: Double(index))
                tools(
                    history, request,
                    events: [
                        event(at: Double(index) + 0.1),
                        event(at: Double(index) + 0.2, kind: .resultSubmission),
                    ])
                finish(history, request, at: Double(index) + 0.3)
            }
            XCTAssertEqual(
                history.requestLanes(source: source, interval: interval(0, 1_003)).count, 1_002)
            XCTAssertEqual(
                history.toolEvents(source: source, interval: interval(0, 1_003)).count, 2_004)
            XCTAssertEqual(
                history.requestIDsWithToolEvents(source: source, interval: interval(0, 1_003))
                    .count, 1_002)
            XCTAssertEqual(
                history.toolOwnerQueryVisitedEvents - visits, 4,
                "Chronological events beyond the previous end must extend the owner cache by its delta"
            )
            XCTAssertEqual(history.completedOrderBuildCount, 1)
            XCTAssertEqual(history.toolOrderBuildCount, 1)
            XCTAssertEqual(history.completedOrderIncrementalInsertCount, 2)
            XCTAssertEqual(history.toolOrderIncrementalInsertCount, 4)
            XCTAssertEqual(summary(history).requests, 1_002)
            XCTAssertEqual(summary(history).toolCalls, 1_002)
            XCTAssertEqual(summary(history).outputTokens, 10_020)
        }
    }

    func testBackdatedAndEqualTimeInsertsMatchRebuiltHistoryAndInvalidateOwnerIndices() throws {
        try withMode {
            let candidate = UsageHistory(now: origin)
            let rebuilt = UsageHistory(now: origin)
            let histories = [candidate, rebuilt]
            let first = GenerationRequest(startedAt: origin)
            let second = GenerationRequest(startedAt: origin)
            let third = GenerationRequest(startedAt: origin)
            for history in histories {
                for request in [first, second, third] {
                    history.apply(.began(request), source: source, at: origin)
                }
            }
            let initial = event(at: 10, callID: "original")
            for history in histories {
                tools(history, first, events: [initial])
                finish(history, first, at: 12, estimated: true)
            }
            assertEquivalent(candidate, rebuilt, windows: [(0, 11), (0, 30)])
            let builds = (candidate.completedOrderBuildCount, candidate.toolOrderBuildCount)
            _ = candidate.requestIDsWithToolEvents(source: source, interval: interval(0, 11))
            let visits = candidate.toolOwnerQueryVisitedEvents
            let inserted = [event(at: 5), event(at: 10), event(at: 15)]
            for history in histories {
                tools(history, second, events: inserted)
                finish(history, second, at: 8)
                finish(history, third, at: 12)
                // A final authoritative correction changes value, never completion ordering.
                finish(history, first, at: 20, output: 3)
                tools(history, first, events: [initial, event(at: 22, callID: "original")])
            }
            XCTAssertEqual(
                candidate.requestIDsWithToolEvents(source: source, interval: interval(0, 11)),
                Set([first.id, second.id]))
            XCTAssertGreaterThan(candidate.toolOwnerQueryVisitedEvents, visits)
            assertEquivalent(
                candidate, rebuilt, windows: [(0, 5), (5, 10), (10, 12), (12, 21), (0, 30)])
            XCTAssertEqual(candidate.completedOrderBuildCount, builds.0)
            XCTAssertEqual(candidate.toolOrderBuildCount, builds.1)
            XCTAssertEqual(candidate.completedOrderIncrementalInsertCount, 2)
            XCTAssertEqual(candidate.toolOrderIncrementalInsertCount, 3)
            XCTAssertEqual(summary(candidate).outputTokens, 23)
            XCTAssertEqual(summary(candidate).toolCalls, 4)
        }
    }

    func testChronologicalAppendInsideUnchangedQueryInvalidatesOwnersAndEndRemainsHalfOpen() throws
    {
        try withMode {
            let history = UsageHistory(now: origin)
            let first = begin(history, at: 0)
            let second = begin(history, at: 0)
            tools(history, first, events: [event(at: 1)])
            let window = interval(0, 10)
            XCTAssertEqual(
                history.requestIDsWithToolEvents(source: source, interval: window), [first.id])
            tools(history, second, events: [event(at: 9)])
            XCTAssertEqual(
                history.requestIDsWithToolEvents(source: source, interval: window),
                [first.id, second.id])
            let third = begin(history, at: 0)
            let visits = history.toolOwnerQueryVisitedEvents
            tools(history, third, events: [event(at: 10)])
            XCTAssertEqual(
                history.requestIDsWithToolEvents(source: source, interval: window),
                [first.id, second.id])
            XCTAssertEqual(history.toolOwnerQueryVisitedEvents, visits)
            XCTAssertEqual(
                history.requestIDsWithToolEvents(source: source, interval: interval(0, 11)),
                [first.id, second.id, third.id])
            XCTAssertEqual(history.toolOwnerQueryVisitedEvents, visits + 1)
            XCTAssertEqual(history.toolOrderBuildCount, 1)
        }
    }

    func testReleasedCachesStayAbsentDuringCollectionAndRebuildOnceOnReopen() throws {
        try withMode {
            let history = UsageHistory(now: origin)
            let first = begin(history, at: 0)
            tools(history, first, events: [event(at: 1)])
            finish(history, first, at: 2)
            _ = history.requestLanes(source: source, interval: interval(0, 10))
            _ = history.requestIDsWithToolEvents(source: source, interval: interval(0, 10))
            history.releaseQueryCaches()
            let next = begin(history, at: 3)
            tools(history, next, events: [event(at: 4)])
            finish(history, next, at: 5)
            XCTAssertEqual(history.cachedQueryEntryCount, 0)
            XCTAssertEqual(history.completedOrderIncrementalInsertCount, 0)
            XCTAssertEqual(history.toolOrderIncrementalInsertCount, 0)
            XCTAssertEqual(history.completedOrderBuildCount, 1)
            XCTAssertEqual(history.toolOrderBuildCount, 1)
            XCTAssertEqual(summary(history).outputTokens, 20)
            XCTAssertEqual(history.requestLanes(source: source, interval: interval(0, 10)).count, 2)
            XCTAssertEqual(
                history.requestIDsWithToolEvents(source: source, interval: interval(0, 10)),
                [first.id, next.id])
            XCTAssertEqual(history.completedOrderBuildCount, 2)
            XCTAssertEqual(history.toolOrderBuildCount, 2)
        }
    }

    func testCapacityAndRetentionPruningRepairPreparedOrdersWithoutFullRebuilds() throws {
        try withMode {
            let candidate = UsageHistory(now: origin, recordLimit: 3, toolEventLimit: 4)
            let rebuilt = UsageHistory(now: origin, recordLimit: 3, toolEventLimit: 4)
            let histories = [candidate, rebuilt]
            for index in 0..<3 {
                let request = GenerationRequest(startedAt: date(Double(index)))
                let events = [event(at: Double(index) + 0.1)]
                for history in histories {
                    history.apply(.began(request), source: source, at: request.startedAt)
                    tools(history, request, events: events)
                    finish(history, request, at: Double(index) + 0.2)
                }
            }
            assertEquivalent(candidate, rebuilt, windows: [(0, 10)])
            for index in 3..<7 {
                let request = GenerationRequest(startedAt: date(Double(index)))
                let events = [event(at: Double(index) + 0.1)]
                for history in histories {
                    history.apply(.began(request), source: source, at: request.startedAt)
                    tools(history, request, events: events)
                    finish(history, request, at: Double(index) + 0.2)
                }
                assertEquivalent(candidate, rebuilt, windows: [(0, 10), (Double(index), 10)])
            }
            XCTAssertEqual(candidate.completedOrderBuildCount, 1)
            XCTAssertEqual(candidate.toolOrderBuildCount, 1)
            let future = UsageHistory.retentionInterval + 100
            let next = GenerationRequest(startedAt: date(future))
            let events = [event(at: future + 1)]
            for history in histories {
                history.apply(.began(next), source: source, at: next.startedAt)
                tools(history, next, events: events)
                finish(history, next, at: future + 2)
            }
            assertEquivalent(candidate, rebuilt, windows: [(0, future + 3), (future, future + 3)])
            XCTAssertEqual(candidate.completedOrderBuildCount, 1)
            XCTAssertEqual(candidate.toolOrderBuildCount, 1)
            XCTAssertEqual(
                summary(candidate).requests, 8, "Retention must not erase since-launch accounting")
            XCTAssertEqual(
                candidate.requestLanes(source: source, interval: interval(0, future + 3)).count, 1)
            XCTAssertEqual(
                candidate.toolEvents(source: source, interval: interval(0, future + 3)).count, 1)
        }
    }

    func testSourcesTerminalPathsAndAllActiveOverflowMatchColdQueries() throws {
        try withMode {
            let candidate = UsageHistory(now: origin, recordLimit: 2)
            let rebuilt = UsageHistory(now: origin, recordLimit: 2)
            let first = GenerationRequest(startedAt: origin)
            let second = GenerationRequest(startedAt: date(1))
            let third = GenerationRequest(startedAt: date(2))
            for history in [candidate, rebuilt] {
                history.apply(.began(first), source: source, at: origin)
                history.apply(.began(second), source: "other", at: date(1))
            }
            assertEquivalent(candidate, rebuilt, windows: [(0, 10)], sources: [source, "other"])
            let eventForOther = event(at: 3)
            for history in [candidate, rebuilt] {
                history.apply(.began(third), source: source, at: date(2))
                history.apply(
                    .toolActivity(requestID: second.id, events: [eventForOther]),
                    source: "other", at: date(3))
                history.apply(.cancelled(requestID: second.id), source: "other", at: date(4))
                history.apply(
                    .failed(requestID: third.id, message: "failed"), source: source, at: date(5))
                history.finishOpenRequests(source: source, at: date(6))
            }
            assertEquivalent(
                candidate, rebuilt, windows: [(0, 4), (4, 6), (0, 10)], sources: [source, "other"])
            XCTAssertEqual(candidate.completedOrderBuildCount, 1)
            XCTAssertEqual(candidate.toolOrderBuildCount, 1)
            XCTAssertTrue(summary(candidate).isPartial)
        }
    }

    func testBaselineComparisonStillUsesFullRebuildAfterAnInsertion() throws {
        try withMode(.nativeGPUOptimized) {
            let history = UsageHistory(now: origin)
            let first = begin(history, at: 0)
            tools(history, first, events: [event(at: 1)])
            finish(history, first, at: 2)
            _ = history.requestLanes(source: source, interval: interval(0, 10))
            _ = history.toolEvents(source: source, interval: interval(0, 10))
            let second = begin(history, at: 3)
            tools(history, second, events: [event(at: 4)])
            finish(history, second, at: 5)
            _ = history.requestLanes(source: source, interval: interval(0, 10))
            _ = history.toolEvents(source: source, interval: interval(0, 10))
            XCTAssertEqual(history.completedOrderBuildCount, 2)
            XCTAssertEqual(history.toolOrderBuildCount, 2)
            XCTAssertEqual(history.completedOrderIncrementalInsertCount, 0)
            XCTAssertEqual(history.toolOrderIncrementalInsertCount, 0)
        }
    }

    private func assertEquivalent(
        _ candidate: UsageHistory, _ rebuilt: UsageHistory,
        windows: [(TimeInterval, TimeInterval)], sources: [String]? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        rebuilt.releaseQueryCaches()
        for source in sources ?? [self.source] {
            for (start, end) in windows {
                let window = interval(start, end)
                for inclusive in [false, true] {
                    XCTAssertEqual(
                        candidate.requestLanes(
                            source: source, interval: window, inclusiveEnd: inclusive),
                        rebuilt.requestLanes(
                            source: source, interval: window, inclusiveEnd: inclusive), file: file,
                        line: line)
                    let actual = candidate.toolEvents(
                        source: source, interval: window, inclusiveEnd: inclusive)
                    let expected = rebuilt.toolEvents(
                        source: source, interval: window, inclusiveEnd: inclusive)
                    XCTAssertEqual(
                        actual.sorted { $0.id.uuidString < $1.id.uuidString },
                        expected.sorted { $0.id.uuidString < $1.id.uuidString }, file: file,
                        line: line)
                    XCTAssertEqual(
                        actual.map(\.timestamp), actual.map(\.timestamp).sorted(), file: file,
                        line: line)
                }
                XCTAssertEqual(
                    candidate.requestIDsWithToolEvents(source: source, interval: window),
                    rebuilt.requestIDsWithToolEvents(source: source, interval: window), file: file,
                    line: line)
                for scope in UsageScope.allCases {
                    XCTAssertEqual(
                        candidate.summary(
                            scope: scope, source: source, interval: window, now: date(end)),
                        rebuilt.summary(
                            scope: scope, source: source, interval: window, now: date(end)),
                        file: file, line: line)
                }
            }
        }
    }

    private func begin(_ history: UsageHistory, at offset: TimeInterval) -> GenerationRequest {
        let request = GenerationRequest(startedAt: date(offset))
        history.apply(.began(request), source: source, at: date(offset))
        return request
    }

    private func finish(
        _ history: UsageHistory, _ request: GenerationRequest, at offset: TimeInterval,
        output: Int = 10, estimated: Bool = false
    ) {
        history.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: output, promptTokens: 2, isEstimated: estimated, finished: true,
                    timestamp: date(offset))), source: source, at: date(offset))
    }

    private func tools(
        _ history: UsageHistory, _ request: GenerationRequest, events: [ToolActivityEvent]
    ) {
        history.apply(
            .toolActivity(requestID: request.id, events: events), source: source,
            at: events.map(\.timestamp).max() ?? origin)
    }

    private func event(
        at offset: TimeInterval, kind: ToolActivityEvent.Kind = .call, callID: String? = nil
    ) -> ToolActivityEvent {
        ToolActivityEvent(kind: kind, callID: callID, timestamp: date(offset))
    }

    private func summary(_ history: UsageHistory) -> UsageSummary {
        history.summary(
            scope: .sinceLaunch, source: source, interval: interval(0, 10), now: date(10))
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
    private func interval(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval {
        DateInterval(start: date(start), end: date(end))
    }

    private func withMode(
        _ mode: PerformanceGraphicsDiagnostics.Mode = .runtimeHistoryOrder,
        _ body: () throws -> Void
    ) throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: mode)
        defer { try? PerformanceGraphicsDiagnostics.shared.disable() }
        try body()
    }
}
