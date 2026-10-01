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

    func testReleasedQueryCachesRebuildWithoutChangingHistoryOrLaterCorrections() {
        let released = UsageHistory(now: origin)
        let reference = UsageHistory(now: origin)
        let histories = [released, reference]
        let completed = GenerationRequest(model: "completed", startedAt: origin)
        let active = GenerationRequest(model: "active", startedAt: date(2))
        let other = GenerationRequest(model: "other", startedAt: date(1))
        let call = ToolActivityEvent(kind: .call, name: "read", callID: "a", timestamp: date(4))
        let result = ToolActivityEvent(
            kind: .resultSubmission, name: "read", callID: "a", timestamp: date(5))
        for history in histories {
            history.apply(.began(completed), source: source, at: origin)
            history.apply(.began(active), source: source, at: date(2))
            history.apply(.began(other), source: "other", at: date(1))
            history.apply(
                .toolActivity(requestID: completed.id, events: [call, result]),
                source: source, at: date(5))
            update(history, completed, at: 10, output: 12, finished: true)
            update(history, active, at: 6, output: 4)
            update(history, other, at: 11, output: 7, finished: true, source: "other")
        }

        func assertEquivalent(file: StaticString = #filePath, line: UInt = #line) {
            for owner in [source, "other"] {
                for (start, end) in [(0.0, 7.0), (4, 5), (5, 11), (10, 13), (0, 30)] {
                    let interval = DateInterval(start: date(start), end: date(end))
                    for inclusiveEnd in [false, true] {
                        XCTAssertEqual(
                            released.requestLanes(
                                source: owner, interval: interval, inclusiveEnd: inclusiveEnd),
                            reference.requestLanes(
                                source: owner, interval: interval, inclusiveEnd: inclusiveEnd),
                            file: file, line: line)
                        XCTAssertEqual(
                            released.toolEvents(
                                source: owner, interval: interval, inclusiveEnd: inclusiveEnd),
                            reference.toolEvents(
                                source: owner, interval: interval, inclusiveEnd: inclusiveEnd),
                            file: file, line: line)
                    }
                    XCTAssertEqual(
                        released.requestIDsWithToolEvents(source: owner, interval: interval),
                        reference.requestIDsWithToolEvents(source: owner, interval: interval),
                        file: file, line: line)
                    for scope in UsageScope.allCases {
                        XCTAssertEqual(
                            summary(released, scope: scope, start: start, end: end, source: owner),
                            summary(reference, scope: scope, start: start, end: end, source: owner),
                            file: file, line: line)
                    }
                }
            }
        }

        assertEquivalent()
        let interval = DateInterval(start: origin, end: date(30))
        let retainedOwners = released.requestIDsWithToolEvents(source: source, interval: interval)
        XCTAssertGreaterThan(released.cachedQueryEntryCount, 0)
        let visitedBeforeRelease = released.toolOwnerQueryVisitedEvents
        released.releaseQueryCaches()
        released.releaseQueryCaches()
        XCTAssertEqual(released.cachedQueryEntryCount, 0)
        XCTAssertEqual(released.toolOwnerQueryVisitedEvents, visitedBeforeRelease)
        XCTAssertEqual(
            released.requestIDsWithToolEvents(source: source, interval: interval), retainedOwners)
        XCTAssertGreaterThan(released.toolOwnerQueryVisitedEvents, visitedBeforeRelease)
        let visitedAfterRebuild = released.toolOwnerQueryVisitedEvents
        XCTAssertEqual(
            released.requestIDsWithToolEvents(source: source, interval: interval), retainedOwners)
        XCTAssertEqual(released.toolOwnerQueryVisitedEvents, visitedAfterRebuild)
        assertEquivalent()

        released.releaseQueryCaches()
        let earlierCall = ToolActivityEvent(
            kind: .call, name: "search", callID: "earlier", timestamp: date(3))
        for history in histories {
            update(
                history, completed, at: 12, output: 3, input: 2, estimated: false, finished: true)
            update(history, active, at: 13, output: 6, input: 1, estimated: false, finished: true)
            history.apply(
                .toolActivity(requestID: completed.id, events: [earlierCall, call]),
                source: source, at: date(14))
        }
        XCTAssertEqual(
            released.cachedQueryEntryCount, 0, "Hidden ingestion must not rebuild query caches")
        assertEquivalent()
        XCTAssertEqual(summary(released).outputTokens, 9)
        XCTAssertEqual(summary(released).toolCalls, 2, "Replayed call must remain deduplicated")
        XCTAssertEqual(
            retainedOwners, [completed.id], "Previously returned owner values remain valid")
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

    func testSessionHistoryDoesNotCreateFilesAndANewSessionStartsEmpty() async throws {
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
                events: [
                    ToolActivityEvent(kind: .call, name: "search", timestamp: date(3))
                ]), source: source, at: date(4))
        history.finishOpenRequests(source: source, at: date(5))
        history.flush()
        await history.waitForPendingWrites()
        XCTAssertNil(history.persistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(summary(history, scope: .today).outputTokens, 25)
        XCTAssertEqual(summary(history, scope: .today).activeRequests, 0)
        XCTAssertEqual(summary(history).toolCalls, 1)
        let newSession = UsageHistory(directory: directory, now: date(6))
        XCTAssertEqual(summary(newSession).requests, 0)
        XCTAssertEqual(summary(newSession, scope: .today).requests, 0)
        XCTAssertTrue(
            newSession.requestLanes(
                source: source, interval: DateInterval(start: origin, end: date(10))
            ).isEmpty)
    }

    func testCompatibilityFlushNeverChangesLatestInMemoryCorrection() async {
        let history = UsageHistory(now: origin)
        let request = begin(history)
        update(history, request, at: 1, output: 100)
        history.flush()
        update(history, request, at: 2, output: 50, input: 3, estimated: false, finished: true)
        history.flush()
        await history.waitForPendingWrites()
        XCTAssertEqual(summary(history, scope: .today).outputTokens, 50)
        XCTAssertFalse(summary(history, scope: .today).outputIsEstimated)
    }

    func testLegacyFilesAreNeitherLoadedNorChanged() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("usage-history.json")
        let previous = Data("{legacy history deliberately not decoded}".utf8)
        try previous.write(to: file)
        let history = UsageHistory(directory: directory, now: origin)
        XCTAssertNil(history.persistenceError)
        XCTAssertEqual(summary(history, scope: .today).requests, 0)
        let request = begin(history)
        update(history, request, at: 1, output: 3)
        await history.waitForPendingWrites()
        XCTAssertEqual(try Data(contentsOf: file), previous)
        XCTAssertEqual(summary(history).outputTokens, 3)
        XCTAssertFalse(summary(history, scope: .today).isPartial)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["usage-history.json"])
    }

    func testInvalidLegacyLocationCannotAffectSessionUsage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = Data("not a directory".utf8)
        try previous.write(to: directory)
        let history = UsageHistory(directory: directory, now: origin)
        let request = begin(history)
        update(history, request, at: 1, output: 8)
        await history.waitForPendingWrites()
        XCTAssertNil(history.persistenceError)
        XCTAssertEqual(summary(history).outputTokens, 8)
        XCTAssertEqual(try Data(contentsOf: directory), previous)
    }

    func testIndexedTotalsMatchReferenceLedgerAcrossHourEdgesAndCorrections() {
        let history = UsageHistory(now: origin)
        // Deliberately shuffled completion times and sub-second boundaries ensure
        // the optimized complete-hour totals agree with exact edge timestamps.
        var ledger: [(source: String, end: TimeInterval, output: Int, input: Int)] = []
        var calls: [(source: String, time: TimeInterval)] = []
        for index in 0..<240 {
            let owner = index.isMultiple(of: 3) ? "other" : source
            let start = Double(index * 113)
            let end = start + Double((index * 17) % 300) + 0.25
            let request = begin(history, at: start, source: owner)
            let output = index * 7 + 1
            let input = index % 13
            update(history, request, at: end, output: output + 100, finished: true, source: owner)
            update(
                history, request, at: end + 0.1, output: output, input: input,
                estimated: false, finished: true, source: owner)
            ledger.append((owner, end, output, input))
            let callTime = start + 0.125
            let call = ToolActivityEvent(
                kind: .call, name: "search", callID: "call-\(index)", timestamp: date(callTime))
            history.apply(
                .toolActivity(requestID: request.id, events: [call, call]), source: owner,
                at: date(end))
            calls.append((owner, callTime))
        }
        let edges: [TimeInterval] = [
            0, 0.125, 0.25, 3_599.5, 3_600, 3_600.25, 7_200, 11_321.25, 27_500,
        ]
        for owner in [source, "other"] {
            for lower in edges {
                for upper in edges where upper > lower {
                    let expected = ledger.filter {
                        $0.source == owner && $0.end >= lower && $0.end < upper
                    }
                    let actual = summary(
                        history, scope: .selectedPeriod, start: lower, end: upper, source: owner)
                    XCTAssertEqual(actual.requests, expected.count)
                    XCTAssertEqual(actual.outputTokens, expected.reduce(0) { $0 + $1.output })
                    XCTAssertEqual(actual.inputTokens, expected.reduce(0) { $0 + $1.input })
                    XCTAssertEqual(
                        actual.toolCalls,
                        calls.filter { $0.source == owner && $0.time >= lower && $0.time < upper }
                            .count)
                    XCTAssertFalse(actual.outputIsEstimated)
                }
            }
        }
    }

    func testMetadataSlotsAndIndicesRemainCorrectAfterRepeatedCapacityEviction() {
        let history = UsageHistory(now: origin, recordLimit: 3, toolEventLimit: 4)
        for index in 0..<100 {
            let start = Double(index * 4)
            let request = GenerationRequest(model: "model-\(index)", startedAt: date(start))
            history.apply(.began(request), source: source, at: date(start))
            let call = ToolActivityEvent(
                kind: .call, name: "tool-\(index)", callID: "call-\(index)",
                timestamp: date(start + 1))
            let result = ToolActivityEvent(
                kind: .resultSubmission, name: "tool-\(index)", callID: "call-\(index)",
                timestamp: date(start + 2))
            history.apply(
                .toolActivity(requestID: request.id, events: [call, call, result]), source: source,
                at: date(start + 2))
            update(
                history, request, at: start + 3, output: index, input: 1, estimated: false,
                finished: true)
            let interval = DateInterval(start: origin, end: date(start + 4))
            let lanes = history.requestLanes(source: source, interval: interval)
            XCTAssertEqual(lanes.last?.model, "model-\(index)")
            XCTAssertEqual(lanes.count, min(index + 1, 3))
            let tools = history.toolEvents(source: source, interval: interval)
            XCTAssertEqual(tools.last?.name, "tool-\(index)")
            XCTAssertEqual(tools.last?.callID, "call-\(index)")
            XCTAssertEqual(tools.count, min((index + 1) * 2, 4))
        }
        XCTAssertEqual(summary(history).requests, 100)
        XCTAssertEqual(summary(history).outputTokens, (0..<100).reduce(0, +))
        XCTAssertEqual(summary(history).toolCalls, 100)
        XCTAssertFalse(summary(history).isPartial)
        XCTAssertTrue(summary(history, scope: .selectedPeriod, end: 400).isPartial)
        XCTAssertEqual(
            summary(history, scope: .selectedPeriod, end: 400).outputTokens, 97 + 98 + 99)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("UsageHistoryTests-\(UUID())")
    }
}
