import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class UsageHistoryCompletedLaneCacheTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let source = "ollama:completed-lane-cache"

    func testRollingQueriesPreserveOverlapInclusiveEdgesAndEqualStartOrdering() {
        let histories = pair()
        for index in 1...90 {
            let owner = index.isMultiple(of: 3) ? "other" : source
            let start = Double((index * 17) % 80) - 50
            begin(histories, id: index, at: start, source: owner)
            update(histories, id: index, at: start, source: owner, tokens: index, liveTPS: 4)
            if !index.isMultiple(of: 5) {
                update(
                    histories, id: index, at: start + Double((index * 11) % 100),
                    source: owner, tokens: index * 2, finished: true, estimated: false)
            }
        }
        // Same start with mixed active/completed state and reversed insertion.
        begin(histories, id: 102, at: 20)
        begin(histories, id: 101, at: 20)
        update(histories, id: 101, at: 20, finished: true, estimated: false)
        let windows: [(TimeInterval, TimeInterval)] = [
            (0, 20), (1, 21), (20, 20), (20, 21), (30, 40), (40, 60),
            (60, 100), (-60, 0), (-50, 20), (10, 19), (10, 20), (10, 21),
        ]
        for owner in [source, "other", "missing"] {
            for (lower, upper) in windows {
                for inclusive in [false, true] {
                    assertParity(
                        histories, owner: owner, lower: lower, upper: upper, inclusive: inclusive)
                }
            }
        }
    }

    func testMovingEndpointsAndLiveCorrectionsReuseUnchangedCompletedMembership() {
        let histories = pair()
        begin(histories, id: 1, at: -10)
        update(histories, id: 1, at: 5, finished: true, estimated: false)
        begin(histories, id: 2, at: 0)
        update(histories, id: 2, at: 50, tokens: 100, finished: true, estimated: false)
        begin(histories, id: 3, at: 30)
        update(histories, id: 3, at: 35, finished: true, estimated: false)
        begin(histories, id: 4, at: 2)
        assertParity(histories, lower: 10, upper: 20)
        let visits = histories.cached.completedLaneCacheVisitedRecords
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 1)
        XCTAssertEqual(histories.cached.completedLaneCacheEntryCount, 1)

        update(histories, id: 4, at: 12, tokens: 12, liveTPS: 7)
        assertParity(histories, lower: 11, upper: 21)
        update(histories, id: 4, at: 13, tokens: 24, liveTPS: 9, model: "updated-live-model")
        assertParity(histories, lower: 12, upper: 22, inclusive: true)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 1)
        XCTAssertEqual(histories.cached.completedLaneCacheHitCount, 2)
        XCTAssertEqual(histories.cached.completedLaneCacheVisitedRecords, visits)
        XCTAssertEqual(query(histories.cached, lower: 12, upper: 22).last?.outputTokens, 24)
        XCTAssertEqual(
            query(histories.cached, lower: 12, upper: 22).last?.model, "updated-live-model")
    }

    func testMembershipChangesAtBothExactBoundariesInvalidateWithoutChangingOverlapSemantics() {
        let histories = pair()
        begin(histories, id: 1, at: 0)
        update(histories, id: 1, at: 20, finished: true, estimated: false)
        begin(histories, id: 2, at: 15)
        update(histories, id: 2, at: 30, finished: true, estimated: false)
        assertParity(histories, lower: 10, upper: 15)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 1)
        assertParity(histories, lower: 20, upper: 15 + 5)
        // The lower-bound equality preserves the lane; upper-bound movement adds id 2.
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 2)
        assertParity(histories, lower: 20, upper: 21)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 2)
        assertParity(histories, lower: 20.01, upper: 21)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 3)
        assertParity(histories, lower: 10, upper: 15)
        let builds = histories.cached.completedLaneCacheBuildCount
        assertParity(histories, lower: 10, upper: 15, inclusive: true)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, builds + 1)
        assertParity(histories, lower: 10, upper: 15, inclusive: false)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, builds + 2)
    }

    func testCompletedEstimatedUsageCorrectionReplacesCachedModelAndCounts() {
        let histories = pair()
        begin(histories, id: 1, at: 0)
        update(histories, id: 1, at: 20, tokens: 100, finished: true, model: "estimated-model")
        assertParity(histories, lower: 10, upper: 30)
        let old = query(histories.cached, lower: 10, upper: 30)
        update(
            histories, id: 1, at: 21, tokens: 80, finished: true, estimated: false,
            model: "final-model")
        XCTAssertEqual(histories.cached.completedLaneCacheEntryCount, 0)
        assertParity(histories, lower: 10, upper: 30)
        let corrected = query(histories.cached, lower: 10, upper: 30)
        XCTAssertEqual(corrected.first?.outputTokens, 80)
        XCTAssertEqual(corrected.first?.outputIsEstimated, false)
        XCTAssertEqual(corrected.first?.model, "final-model")
        XCTAssertEqual(corrected.first?.endedAt, date(20))
        XCTAssertEqual(old.first?.model, "estimated-model", "Returned values remain independent")
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 2)
    }

    func testNewCompletionCancellationFailureAndFinishOpenRequestsRebuildCompletedProjection() {
        let histories = pair()
        for index in 1...4 { begin(histories, id: index, at: Double(index)) }
        update(histories, id: 1, at: 10, tokens: 15, finished: true, estimated: false)
        assertParity(histories, lower: 0, upper: 20)
        apply(.cancelled(requestID: id(2)), to: histories, at: 11)
        assertParity(histories, lower: 0, upper: 20)
        apply(.failed(requestID: id(3), message: "fixture failure"), to: histories, at: 12)
        assertParity(histories, lower: 0, upper: 20)
        histories.cached.finishOpenRequests(source: source, at: date(13))
        histories.reference.finishOpenRequests(source: source, at: date(13))
        assertParity(histories, lower: 0, upper: 20)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 4)
        XCTAssertEqual(histories.cached.completedLaneCacheEntryCount, 4)
        XCTAssertTrue(query(histories.cached, lower: 0, upper: 20).allSatisfy(\.terminal))
    }

    func testOtherSourceMutationKeepsCachedSourceWhileQueriesReplaceTheOneBoundedCache() {
        let histories = pair()
        for owner in [source, "other"] {
            begin(histories, id: 1, at: 0, source: owner)
            update(histories, id: 1, at: 10, source: owner, finished: true, estimated: false)
        }
        assertParity(histories, lower: 0, upper: 20)
        let visits = histories.cached.completedLaneCacheVisitedRecords
        XCTAssertEqual(visits, 2, "Work evidence includes inspected foreign-source identities")
        begin(histories, id: 2, at: 1, source: "other")
        update(histories, id: 2, at: 12, source: "other", finished: true, estimated: false)
        assertParity(histories, lower: 1, upper: 21)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 1)
        XCTAssertEqual(histories.cached.completedLaneCacheVisitedRecords, visits)
        assertParity(histories, owner: "other", lower: 0, upper: 20)
        XCTAssertEqual(histories.cached.completedLaneCacheEntryCount, 2)
        assertParity(histories, owner: "missing", lower: 0, upper: 20)
        XCTAssertEqual(histories.cached.completedLaneCacheEntryCount, 0)
        assertParity(histories, lower: 0, upper: 20)
        XCTAssertEqual(histories.cached.completedLaneCacheEntryCount, 1)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 3)
    }

    func testReleaseClearsStorageAndHiddenIngestionDoesNotRebuildIt() {
        let histories = pair()
        begin(histories, id: 1, at: 0)
        update(histories, id: 1, at: 10, finished: true, estimated: false)
        assertParity(histories, lower: 0, upper: 20)
        XCTAssertGreaterThan(histories.cached.cachedQueryEntryCount, 0)
        histories.cached.releaseQueryCaches()
        XCTAssertEqual(histories.cached.completedLaneCacheEntryCount, 0)
        XCTAssertEqual(histories.cached.cachedQueryEntryCount, 0)
        begin(histories, id: 2, at: 1)
        update(histories, id: 2, at: 12, finished: true, estimated: false)
        XCTAssertEqual(histories.cached.cachedQueryEntryCount, 0)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 1)
        assertParity(histories, lower: 0, upper: 20)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 2)
        XCTAssertEqual(histories.cached.completedLaneCacheEntryCount, 2)
        // Switching the experiment off releases its retained lane values.
        _ = histories.cached.requestLanes(source: source, interval: interval(0, 20))
        XCTAssertEqual(histories.cached.completedLaneCacheEntryCount, 0)
    }

    func testCapacityAndRetentionPruningNeverLeaveStaleCompletedLanes() {
        let histories = pair(recordLimit: 3)
        for index in 1...3 {
            begin(histories, id: index, at: Double(index))
            update(histories, id: index, at: Double(index + 10), finished: true, estimated: false)
        }
        assertParity(histories, lower: 0, upper: 20)
        begin(histories, id: 4, at: 15)
        assertParity(histories, lower: 0, upper: 20)
        XCTAssertEqual(
            query(histories.cached, lower: 0, upper: 20).map(\.id), [id(2), id(3), id(4)])
        XCTAssertLessThanOrEqual(histories.cached.completedLaneCacheEntryCount, 3)
        let future = UsageHistory.retentionInterval + 100
        begin(histories, id: 5, at: future)
        assertParity(histories, lower: 0, upper: future + 1)
        XCTAssertEqual(histories.cached.completedLaneCacheEntryCount, 0)
        XCTAssertEqual(
            query(histories.cached, lower: 0, upper: future + 1).map(\.id), [id(4), id(5)])
    }

    func testMalformedAndDelayedEventsDoNotInvalidateAValidProjection() {
        let histories = pair()
        begin(histories, id: 1, at: 0)
        update(histories, id: 1, at: 10, finished: true, estimated: false)
        assertParity(histories, lower: 0, upper: 20)
        let badDate = Date(timeIntervalSinceReferenceDate: .nan)
        let malformed = GenerationRequest(id: id(2), startedAt: badDate)
        histories.cached.apply(.began(malformed), source: source, at: date(11))
        histories.reference.apply(.began(malformed), source: source, at: date(11))
        apply(
            .updated(
                requestID: id(1),
                snapshot: GenerationSnapshot(
                    outputTokens: 500, finished: true, timestamp: badDate)), to: histories, at: 12)
        update(histories, id: 1, at: 9, tokens: 500, finished: true, estimated: false)
        update(histories, id: 1, at: 12, tokens: 500, liveTPS: 90)
        assertParity(histories, lower: 1, upper: 21)
        XCTAssertEqual(histories.cached.completedLaneCacheBuildCount, 1)
        XCTAssertEqual(histories.cached.completedLaneCacheHitCount, 1)
    }

    func testAgedImportedFixtureCachesOnlyTheQueriedViewport() {
        let candidate = PerformanceHistoryFixture.makeSessionHistory(
            source: source, endingAt: origin
        ).usage
        let reference = PerformanceHistoryFixture.makeSessionHistory(
            source: source, endingAt: origin
        ).usage
        let histories = (cached: candidate, reference: reference)
        assertParity(histories, lower: -3_800, upper: 0)
        let entries = candidate.completedLaneCacheEntryCount
        let visits = candidate.completedLaneCacheVisitedRecords
        XCTAssertGreaterThan(entries, 0)
        XCTAssertLessThan(entries, 20, "Do not retain a whole day or all seven fixture days")
        XCTAssertLessThanOrEqual(visits, UInt64(entries + 1))
        assertParity(histories, lower: -3_799, upper: 1)
        XCTAssertEqual(candidate.completedLaneCacheBuildCount, 1)
        XCTAssertEqual(candidate.completedLaneCacheHitCount, 1)
        XCTAssertEqual(candidate.completedLaneCacheVisitedRecords, visits)
    }

    private func pair(recordLimit: Int = 20_000) -> (cached: UsageHistory, reference: UsageHistory)
    {
        (
            UsageHistory(now: origin, recordLimit: recordLimit),
            UsageHistory(now: origin, recordLimit: recordLimit)
        )
    }

    private func begin(
        _ histories: (cached: UsageHistory, reference: UsageHistory), id number: Int,
        at offset: TimeInterval, source owner: String? = nil
    ) {
        apply(
            .began(
                GenerationRequest(id: id(number), model: "fixture-model", startedAt: date(offset))),
            to: histories, at: offset, source: owner)
    }

    private func update(
        _ histories: (cached: UsageHistory, reference: UsageHistory), id number: Int,
        at offset: TimeInterval, source owner: String? = nil, tokens: Int = 0,
        liveTPS: Double = 0, finished: Bool = false, estimated: Bool = true, model: String? = nil
    ) {
        apply(
            .updated(
                requestID: id(number),
                snapshot: GenerationSnapshot(
                    model: model, outputTokens: tokens, isEstimated: estimated, liveTPS: liveTPS,
                    finished: finished, timestamp: date(offset))), to: histories, at: offset,
            source: owner)
    }

    private func apply(
        _ event: GenerationEvent, to histories: (cached: UsageHistory, reference: UsageHistory),
        at offset: TimeInterval, source owner: String? = nil
    ) {
        for history in [histories.cached, histories.reference] {
            history.apply(event, source: owner ?? source, at: date(offset))
        }
    }

    private func query(
        _ history: UsageHistory, owner: String? = nil, lower: TimeInterval, upper: TimeInterval,
        inclusive: Bool = false, cached: Bool = true
    ) -> [RequestLane] {
        history.requestLanes(
            source: owner ?? source, interval: interval(lower, upper),
            inclusiveEnd: inclusive, useCompletedLaneCache: cached)
    }

    private func assertParity(
        _ histories: (cached: UsageHistory, reference: UsageHistory), owner: String? = nil,
        lower: TimeInterval, upper: TimeInterval, inclusive: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            query(histories.cached, owner: owner, lower: lower, upper: upper, inclusive: inclusive),
            query(
                histories.reference, owner: owner, lower: lower, upper: upper, inclusive: inclusive,
                cached: false),
            "Interval [\(lower), \(upper)\(inclusive ? "]" : ")")", file: file, line: line)
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
    private func interval(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval {
        DateInterval(start: date(start), end: date(end))
    }
}
