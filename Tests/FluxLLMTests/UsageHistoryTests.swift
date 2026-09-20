import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class UsageHistoryTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let source = "ollama:http://localhost:11434"

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    private func summary(
        _ history: UsageHistory, scope: UsageScope = .sinceLaunch,
        start: TimeInterval = 0, end: TimeInterval = 100, source: String? = nil
    ) -> UsageSummary {
        history.summary(
            scope: scope, source: source ?? self.source,
            interval: DateInterval(start: date(start), end: date(end)), now: date(end))
    }

    private func begin(
        _ history: UsageHistory, at offset: TimeInterval = 0, source: String? = nil
    ) -> GenerationRequest {
        let request = GenerationRequest(model: "test-model", startedAt: date(offset))
        history.apply(.began(request), source: source ?? self.source, at: date(offset))
        return request
    }

    private func update(
        _ history: UsageHistory, _ request: GenerationRequest, at offset: TimeInterval,
        output: Int, input: Int? = nil, estimated: Bool = true,
        finished: Bool = false, source: String? = nil
    ) {
        history.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: output, promptTokens: input, isEstimated: estimated,
                    liveTPS: 5, finished: finished, timestamp: date(offset))),
            source: source ?? self.source, at: date(offset))
    }

    func testEmptyUsageAndDuplicateBeginDoNotInventOrResetCounts() {
        let history = UsageHistory(now: origin)
        XCTAssertEqual(summary(history).inputTokens, 0)
        XCTAssertEqual(summary(history).requests, 0)
        let request = begin(history)
        update(history, request, at: 1, output: 19)
        history.apply(.began(request), source: source, at: date(2))
        update(
            history, GenerationRequest(startedAt: origin), at: 3,
            output: 900, finished: true)
        let total = summary(history)
        XCTAssertEqual(total.requests, 1)
        XCTAssertEqual(total.activeRequests, 1)
        XCTAssertEqual(total.outputTokens, 19)
        XCTAssertNil(total.inputTokens)
        XCTAssertEqual(total.unknownInputRequests, 1)
    }

    func testFinalUsageReplacesEstimateAndRepeatedFinalCannotDoubleCount() {
        let history = UsageHistory(now: origin)
        let request = begin(history)
        update(history, request, at: 1, output: 120)
        update(history, request, at: 2, output: 94, input: 23, estimated: false, finished: true)
        update(history, request, at: 2, output: 94, input: 23, estimated: false, finished: true)
        update(history, request, at: 3, output: 150)
        update(history, request, at: 4, output: 180, finished: true)
        update(history, request, at: 5, output: 999, input: 999, estimated: false, finished: true)

        let total = summary(history)
        XCTAssertEqual(total.outputTokens, 94)
        XCTAssertEqual(total.inputTokens, 23)
        XCTAssertEqual(total.unknownInputRequests, 0)
        XCTAssertEqual(total.requests, 1)
        XCTAssertEqual(total.activeRequests, 0)
        XCTAssertFalse(total.outputIsEstimated)
        let lane = history.requestLanes(
            source: source, interval: DateInterval(start: origin, end: date(10))
        ).first
        XCTAssertEqual(lane?.endedAt, date(2))
        XCTAssertEqual(lane?.outputTokens, 94)
        XCTAssertEqual(lane?.liveTPS, 5)
    }

    func testCoalescedFinalAndLaterAuthoritativeCorrectionUseOneRequest() {
        let history = UsageHistory(now: origin)
        let request = begin(history)
        update(history, request, at: 3, output: 80, finished: true)
        update(history, request, at: 4, output: 60, input: 10, estimated: false, finished: true)
        let total = summary(history)
        XCTAssertEqual(total.outputTokens, 60)
        XCTAssertEqual(total.inputTokens, 10)
        XCTAssertFalse(total.outputIsEstimated)
        XCTAssertEqual(total.requests, 1)
        XCTAssertEqual(summary(history, scope: .selectedPeriod, start: 3, end: 4).requests, 1)
        XCTAssertEqual(summary(history, scope: .selectedPeriod, start: 4, end: 5).requests, 0)
    }

    func testConcurrentRequestsAndConfigurationSourcesRemainIndependent() {
        let history = UsageHistory(now: origin)
        let older = begin(history)
        let newer = begin(history, at: 1)
        let other = begin(history, at: 2, source: "other")
        update(history, newer, at: 3, output: 90, input: 4, estimated: false, finished: true)
        update(history, older, at: 4, output: 10, input: 2, estimated: false, finished: true)
        update(history, other, at: 5, output: 1_000, source: "other")
        XCTAssertEqual(summary(history).requests, 2)
        XCTAssertEqual(summary(history).outputTokens, 100)
        XCTAssertEqual(summary(history).inputTokens, 6)
        XCTAssertEqual(summary(history, source: "other").outputTokens, 1_000)
        XCTAssertEqual(summary(history, source: "other").activeRequests, 1)
        history.finishOpenRequests(source: source, at: date(6))
        XCTAssertEqual(summary(history, source: "other").activeRequests, 1)
        history.finishOpenRequests(source: "other", at: date(7))
        XCTAssertEqual(summary(history, source: "other").activeRequests, 0)
        XCTAssertEqual(summary(history, source: "other").outputTokens, 1_000)
    }

    func testUnknownInputIsNotTreatedAsZeroAndKnownSubtotalIsExplicit() {
        let history = UsageHistory(now: origin)
        let unknown = begin(history)
        update(history, unknown, at: 1, output: 2, finished: true)
        XCTAssertNil(summary(history).inputTokens)
        let known = begin(history, at: 2)
        update(history, known, at: 3, output: 5, input: 11, estimated: false, finished: true)
        XCTAssertEqual(summary(history).inputTokens, 11)
        XCTAssertEqual(summary(history).unknownInputRequests, 1)
        XCTAssertTrue(summary(history).outputIsEstimated)
        update(history, unknown, at: 4, output: 1, input: 0, estimated: false, finished: true)
        XCTAssertEqual(summary(history).inputTokens, 11)
        XCTAssertEqual(summary(history).unknownInputRequests, 0)
        XCTAssertFalse(summary(history).outputIsEstimated)
    }

    func testToolCallsDeduplicateByRequestAndKindWithoutCountingResultsAsCalls() {
        let history = UsageHistory(now: origin)
        let first = begin(history)
        let second = begin(history, at: 1)
        let call = ToolActivityEvent(
            kind: .call, name: "search", callID: "call-1", timestamp: date(2))
        let repeated = ToolActivityEvent(
            kind: .call, name: "search", callID: "call-1", timestamp: date(2))
        let result = ToolActivityEvent(
            kind: .resultSubmission, name: "search", callID: "call-1", timestamp: date(3))
        for request in [first, second] {
            history.apply(
                .toolActivity(requestID: request.id, events: [call, repeated, result, result]),
                source: source, at: date(3))
        }
        let events = history.toolEvents(
            source: source, interval: DateInterval(start: origin, end: date(10)))
        XCTAssertEqual(summary(history).toolCalls, 2)
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(Set(events.compactMap(\.requestID)), Set([first.id, second.id]))
        XCTAssertEqual(summary(history, scope: .selectedPeriod, start: 2, end: 3).toolCalls, 2)
        XCTAssertEqual(summary(history, scope: .selectedPeriod, start: 3, end: 4).toolCalls, 0)
    }

    func testSelectedPeriodUsesCompletionAndHalfOpenBoundaries() {
        let history = UsageHistory(now: origin)
        let first = begin(history)
        let middle = begin(history, at: 1)
        let last = begin(history, at: 2)
        let active = begin(history, at: 3)
        update(history, first, at: 10, output: 10, input: 1, estimated: false, finished: true)
        update(history, middle, at: 15, output: 20, input: 2, estimated: false, finished: true)
        update(history, last, at: 20, output: 30, input: 3, estimated: false, finished: true)
        update(history, active, at: 21, output: 1_000)
        let selected = summary(history, scope: .selectedPeriod, start: 10, end: 20)
        XCTAssertEqual(selected.requests, 2)
        XCTAssertEqual(selected.outputTokens, 30)
        XCTAssertEqual(selected.inputTokens, 3)
        XCTAssertEqual(selected.activeRequests, 0)
        XCTAssertEqual(summary(history, scope: .selectedPeriod, start: 20, end: 21).requests, 1)
        XCTAssertEqual(summary(history).outputTokens, 1_060)
    }

    func testTodayFollowsLocalCalendarAcrossDaylightSavingBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let noon = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
        let day = try XCTUnwrap(calendar.dateInterval(of: .day, for: noon))
        XCTAssertEqual(day.duration, 25 * 3_600)
        let history = UsageHistory(now: day.start.addingTimeInterval(-10), calendar: calendar)
        for (offset, output) in [(-1.0, 1), (0.0, 2), (86_500.0, 4), (90_000.0, 8)] {
            let timestamp = day.start.addingTimeInterval(offset)
            let request = GenerationRequest(startedAt: timestamp.addingTimeInterval(-1))
            history.apply(.began(request), source: source, at: request.startedAt)
            history.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: output, isEstimated: false, finished: true,
                        timestamp: timestamp)),
                source: source, at: timestamp)
        }
        let total = history.summary(scope: .today, source: source, interval: day, now: noon)
        XCTAssertEqual(total.requests, 2)
        XCTAssertEqual(total.outputTokens, 6)
    }

    func testStaleSnapshotsAndDuplicateBeginAfterCompletionCannotReopenRequest() {
        let history = UsageHistory(now: origin)
        let request = begin(history)
        update(history, request, at: 3, output: 12)
        update(history, request, at: 2, output: 900)
        history.apply(.cancelled(requestID: request.id), source: source, at: date(4))
        history.apply(.began(request), source: source, at: date(5))
        history.apply(.failed(requestID: request.id, message: "late"), source: source, at: date(6))
        XCTAssertEqual(summary(history).requests, 1)
        XCTAssertEqual(summary(history).outputTokens, 12)
        XCTAssertEqual(summary(history).activeRequests, 0)
        XCTAssertTrue(summary(history).outputIsEstimated)
    }

    func testInvalidTimestampsAndToolEventsBeforeRequestAreRejected() {
        let history = UsageHistory(now: origin)
        let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
        history.apply(
            .began(GenerationRequest(startedAt: invalid)), source: source, at: origin)
        let request = begin(history)
        history.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(outputTokens: 900, timestamp: invalid)),
            source: source, at: date(1))
        history.apply(
            .toolActivity(
                requestID: request.id,
                events: [
                    ToolActivityEvent(kind: .call, timestamp: date(-1)),
                    ToolActivityEvent(kind: .call, timestamp: invalid),
                    ToolActivityEvent(kind: .call, timestamp: date(1)),
                ]), source: source, at: date(1))
        XCTAssertEqual(summary(history).requests, 1)
        XCTAssertEqual(summary(history).outputTokens, 0)
        XCTAssertEqual(summary(history).toolCalls, 1)
    }

    func testHugeUsageClampsWithoutOverflowAndLaterCorrectionsRestoreExactTotals() {
        let history = UsageHistory(now: origin)
        let first = begin(history)
        let second = begin(history, at: 1)
        update(history, first, at: 2, output: Int.max, input: Int.max)
        update(history, second, at: 3, output: Int.max, input: Int.max)
        XCTAssertEqual(summary(history).outputTokens, Int.max)
        XCTAssertEqual(summary(history).inputTokens, Int.max)
        XCTAssertTrue(summary(history).isPartial)
        update(history, first, at: 4, output: 10, input: 5, estimated: false, finished: true)
        update(history, second, at: 5, output: 20, input: 5, estimated: false, finished: true)
        XCTAssertEqual(summary(history).outputTokens, 30)
        XCTAssertEqual(summary(history).inputTokens, 10)
        XCTAssertFalse(summary(history).isPartial)
    }

    func testHistoryRetentionAndCapacityDoNotReduceSinceLaunchTotals() {
        let history = UsageHistory(now: origin, recordLimit: 1, toolEventLimit: 1)
        let first = begin(history)
        history.apply(
            .toolActivity(
                requestID: first.id,
                events: [
                    ToolActivityEvent(kind: .call, timestamp: date(1)),
                    ToolActivityEvent(kind: .call, timestamp: date(2)),
                ]), source: source, at: date(2))
        update(history, first, at: 3, output: 10, input: 5, estimated: false, finished: true)
        let second = begin(history, at: 4)
        update(history, second, at: 5, output: 20, input: 5, estimated: false, finished: true)
        XCTAssertEqual(summary(history).outputTokens, 30)
        XCTAssertEqual(summary(history).requests, 2)
        XCTAssertEqual(summary(history).toolCalls, 2)
        XCTAssertFalse(summary(history).isPartial)
        XCTAssertTrue(summary(history, scope: .selectedPeriod).isPartial)
        let muchLater = UsageHistory.retentionInterval + 200
        _ = begin(history, at: muchLater)
        XCTAssertEqual(summary(history).outputTokens, 30)
        XCTAssertEqual(summary(history).requests, 3)
        XCTAssertEqual(summary(history).toolCalls, 2)
        XCTAssertEqual(
            history.requestLanes(
                source: source, interval: DateInterval(start: origin, end: date(muchLater + 1))
            )
            .count, 1)
    }

    func testPersistenceReloadRetainsTodayButStartsFreshLaunchAndClosesInterruptedRequests()
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = UsageHistory(directory: directory, now: origin)
        let completed = begin(history)
        update(history, completed, at: 1, output: 8, input: 3, estimated: false, finished: true)
        let interrupted = begin(history, at: 2)
        update(history, interrupted, at: 4, output: 17)
        history.apply(
            .toolActivity(
                requestID: interrupted.id,
                events: [ToolActivityEvent(kind: .call, name: "search", timestamp: date(3))]),
            source: source, at: date(4))
        await history.waitForPendingWrites()
        XCTAssertNil(history.persistenceError)
        let reloaded = UsageHistory(directory: directory, now: date(5))
        XCTAssertEqual(summary(reloaded).requests, 0)
        let today = summary(reloaded, scope: .today)
        XCTAssertEqual(today.requests, 2)
        XCTAssertEqual(today.activeRequests, 0)
        XCTAssertEqual(today.outputTokens, 25)
        XCTAssertEqual(today.toolCalls, 1)
        XCTAssertTrue(today.outputIsEstimated)
        let lane = reloaded.requestLanes(
            source: source, interval: DateInterval(start: origin, end: date(10))
        )
        .first { $0.id == interrupted.id }
        XCTAssertEqual(lane?.endedAt, date(4))
        XCTAssertTrue(lane?.terminal == true)
        XCTAssertEqual(lane?.model, "test-model")
    }

    func testQueuedWritesCannotReplaceNewerUsageWithAnOlderSnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = UsageHistory(directory: directory, now: origin)
        let request = begin(history)
        update(history, request, at: 1, output: 100)
        history.flush()
        update(history, request, at: 2, output: 50, input: 3, estimated: false, finished: true)
        history.flush()
        await history.waitForPendingWrites()
        let reloaded = UsageHistory(directory: directory, now: date(3))
        XCTAssertEqual(summary(reloaded, scope: .today).outputTokens, 50)
        XCTAssertFalse(summary(reloaded, scope: .today).outputIsEstimated)
    }

    func testCorruptHistoryIsReportedAndPreservedWhileCurrentUsageStillWorks() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("usage-history.json")
        let invalid = Data("{not valid history}".utf8)
        try invalid.write(to: file)
        let history = UsageHistory(directory: directory, now: origin)
        XCTAssertNotNil(history.persistenceError)
        let request = begin(history)
        update(history, request, at: 1, output: 3)
        await history.waitForPendingWrites()
        XCTAssertEqual(try Data(contentsOf: file), invalid)
        XCTAssertEqual(summary(history).outputTokens, 3)
        XCTAssertTrue(summary(history, scope: .today).isPartial)
    }

    func testStorageFailureDoesNotLoseInMemoryUsage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a directory".utf8).write(to: directory)
        let history = UsageHistory(directory: directory, now: origin)
        let request = begin(history)
        update(history, request, at: 1, output: 8)
        await history.waitForPendingWrites()
        XCTAssertNotNil(history.persistenceError)
        XCTAssertEqual(summary(history).outputTokens, 8)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("UsageHistoryTests-\(UUID())")
    }
}
