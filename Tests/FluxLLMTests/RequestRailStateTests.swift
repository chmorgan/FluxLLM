import Foundation
import XCTest

@testable import FluxLLM

final class RequestRailStateTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    private func lane(_ number: Int, start: TimeInterval, end: TimeInterval? = nil) -> RequestLane {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
        return RequestLane(
            id: id, startedAt: date(start), endedAt: end.map(date), terminal: end != nil)
    }

    private func update(
        _ state: RequestRailState, _ lanes: [RequestLane], at time: TimeInterval,
        presentedAt: TimeInterval? = nil
    ) -> RequestRailPresentation {
        state.update(lanes: lanes, snapshotTime: date(time), presentedAt: date(presentedAt ?? time))
    }

    func testInitialHistorySeedsSilentlyInDeterministicOrder() {
        let state = RequestRailState()
        let a = lane(1, start: 0)
        let b = lane(2, start: 0)
        let c = lane(3, start: 1, end: 2)
        let presentation = update(state, [c, b, a], at: 2)

        XCTAssertEqual(
            presentation.assignments[a.id], RequestRailAssignment(track: 0, colorIndex: 0))
        XCTAssertEqual(
            presentation.assignments[b.id], RequestRailAssignment(track: 1, colorIndex: 1))
        XCTAssertEqual(
            presentation.assignments[c.id], RequestRailAssignment(track: 2, colorIndex: 2))
        XCTAssertTrue(presentation.events.isEmpty)
    }

    func testAssignmentsSurviveReorderExpiryRangeChangesAndEmptySnapshots() {
        let state = RequestRailState()
        let a = lane(1, start: 0, end: 4)
        let b = lane(2, start: 1)
        let original = update(state, [a, b], at: 4)
        XCTAssertEqual(update(state, [b, a], at: 5).assignments, original.assignments)
        XCTAssertEqual(update(state, [b], at: 6).assignments[b.id], original.assignments[b.id])
        XCTAssertTrue(update(state, [], at: 7).assignments.isEmpty)

        let restored = update(state, [a, b], at: 8)
        XCTAssertEqual(restored.assignments, original.assignments)
        XCTAssertTrue(restored.events.isEmpty)
    }

    func testUpdatesAllKnownEndsBeforeReusingExactEndpoint() {
        let state = RequestRailState()
        let a = lane(1, start: 0)
        _ = update(state, [a], at: 0)
        let ended = lane(1, start: 0, end: 2)
        let b = lane(2, start: 2)
        let presentation = update(state, [b, ended], at: 2)

        XCTAssertEqual(presentation.assignments[a.id]?.track, 0)
        XCTAssertEqual(presentation.assignments[b.id]?.track, 0)
        XCTAssertEqual(presentation.assignments[b.id]?.colorIndex, 1)
        XCTAssertEqual(Set(presentation.events.map(\.kind)), [.arrival, .completion])
    }

    func testLateIntervalsCheckEveryRetainedIntervalOnTrack() {
        let state = RequestRailState()
        let first = lane(1, start: 0, end: 4)
        let later = lane(2, start: 10, end: 14)
        _ = update(state, [first, later], at: 14)
        let overlapsFirst = lane(3, start: 2, end: 3)
        let fitsGap = lane(4, start: 4, end: 10)
        let presentation = update(state, [later, overlapsFirst, fitsGap], at: 15)

        XCTAssertEqual(presentation.assignments[overlapsFirst.id]?.track, 1)
        XCTAssertEqual(presentation.assignments[fitsGap.id]?.track, 0)
        XCTAssertEqual(presentation.assignments[later.id]?.track, 0)
        XCTAssertTrue(presentation.events.isEmpty)
    }

    func testSixthRequestUsesGroupAndIsNotPromotedAfterEarlierCompletion() {
        let state = RequestRailState()
        let lanes = (1...6).map { lane($0, start: Double($0)) }
        let original = update(state, lanes, at: 6)
        XCTAssertEqual(lanes.map { original.assignments[$0.id]!.track }, [0, 1, 2, 3, 4, 5])

        let ended = (1...5).map { lane($0, start: Double($0), end: 7) }
        let newest = lane(7, start: 7)
        let presentation = update(state, ended + [lanes[5], newest], at: 7)
        XCTAssertEqual(presentation.assignments[lanes[5].id], original.assignments[lanes[5].id])
        XCTAssertEqual(presentation.assignments[newest.id]?.track, 0)
        XCTAssertEqual(presentation.assignments[newest.id]?.colorIndex, 6)
    }

    func testArrivalAndCompletionDeduplicateAcrossRepeatedAndOlderPublications() {
        let state = RequestRailState()
        _ = update(state, [], at: 0)
        let running = lane(1, start: 1)
        let arrival = update(state, [running], at: 1, presentedAt: 10).events
        XCTAssertEqual(arrival.map(\.kind), [.arrival])
        XCTAssertEqual(arrival.first?.startedAt, date(10))
        XCTAssertEqual(update(state, [running], at: 1, presentedAt: 10.2).events, arrival)

        let completed = lane(1, start: 1, end: 2)
        let completion = update(state, [completed], at: 2, presentedAt: 11).events
        XCTAssertEqual(completion.map(\.kind), [.completion])
        XCTAssertNotEqual(arrival.first?.id, completion.first?.id)
        XCTAssertNotEqual(arrival.first?.seed, completion.first?.seed)
        _ = update(state, [running], at: 1, presentedAt: 11.2)
        XCTAssertEqual(update(state, [completed], at: 2, presentedAt: 11.3).events, completion)
        XCTAssertTrue(update(state, [], at: 5, presentedAt: 14).events.isEmpty)
        XCTAssertTrue(update(state, [completed], at: 5, presentedAt: 14).events.isEmpty)
    }

    func testShortRequestFirstSeenFinishedEmitsOnlyRecentCompletion() {
        let state = RequestRailState()
        _ = update(state, [], at: 0)
        let recent = lane(1, start: 0.2, end: 0.7)
        let stale = lane(2, start: -10, end: -3)
        let presentation = update(state, [recent, stale], at: 1)
        XCTAssertEqual(presentation.events.map(\.requestID), [recent.id])
        XCTAssertEqual(presentation.events.map(\.kind), [.completion])
    }

    func testNewArrivalAndCompletionAtPreviousPublicationTimestampAnimateOnce() {
        let state = RequestRailState()
        _ = update(state, [], at: 1)
        let running = lane(1, start: 1)
        let arrival = update(state, [running], at: 1, presentedAt: 10).events
        XCTAssertEqual(arrival.map(\.kind), [.arrival])
        XCTAssertEqual(update(state, [running], at: 1, presentedAt: 10.1).events, arrival)

        let completed = lane(1, start: 1, end: 1)
        let completion = update(state, [completed], at: 1, presentedAt: 11).events
        XCTAssertEqual(completion.map(\.kind), [.completion])
        XCTAssertEqual(update(state, [completed], at: 1, presentedAt: 11.1).events, completion)
        XCTAssertTrue(update(state, [completed], at: 1, presentedAt: 14).events.isEmpty)
    }

    func testOldBackfillDoesNotAnimateEvenWhenSnapshotRangeMovesBack() {
        let state = RequestRailState()
        _ = update(state, [], at: 10)
        let historical = lane(1, start: 2, end: 3)
        XCTAssertTrue(update(state, [historical], at: 3, presentedAt: 11).events.isEmpty)
        let runningBackfill = lane(2, start: 9)
        XCTAssertTrue(update(state, [runningBackfill], at: 10, presentedAt: 12).events.isEmpty)
        let fresh = lane(3, start: 11)
        XCTAssertEqual(
            update(state, [fresh], at: 11, presentedAt: 13).events.map(\.kind), [.arrival])
    }

    func testEffectsExpireAtTheirReceiptTimeDeadline() {
        let state = RequestRailState()
        _ = update(state, [], at: 0)
        let a = lane(1, start: 1)
        let event = update(state, [a], at: 1, presentedAt: 100).events[0]
        XCTAssertEqual(event.expiresAt, date(100.8))
        XCTAssertEqual(update(state, [a], at: 1, presentedAt: 100.79).events.count, 1)
        XCTAssertTrue(update(state, [a], at: 1, presentedAt: 100.8).events.isEmpty)

        let finished = lane(1, start: 1, end: 2)
        let completion = update(state, [finished], at: 2, presentedAt: 101).events[0]
        XCTAssertEqual(completion.expiresAt, date(103.8))
        XCTAssertTrue(update(state, [finished], at: 2, presentedAt: 103.8).events.isEmpty)
    }

    func testBoundedAbsentHistoryKeepsRecentIdentityAndSuppressesEvictedBackfill() {
        let state = RequestRailState()
        let count = RequestRailState.retainedAbsentLimit + 2
        var newestAssignment: RequestRailAssignment?
        for number in 1...count {
            let current = lane(number, start: Double(number * 3), end: Double(number * 3 + 1))
            newestAssignment =
                update(state, [current], at: Double(number * 3 + 2))
                .assignments[current.id]
        }
        _ = update(state, [], at: Double(count * 3 + 6))
        let newest = lane(count, start: Double(count * 3), end: Double(count * 3 + 1))
        let original = lane(1, start: 3, end: 4)
        let presentation = update(state, [original, newest], at: Double(count * 3 + 7))
        XCTAssertEqual(presentation.assignments[newest.id], newestAssignment)
        // The oldest absent record was evicted; observing it again gets a later color
        // ordinal, but its historical completion must never replay.
        XCTAssertGreaterThan(presentation.assignments[original.id]!.colorIndex, count - 1)
        XCTAssertTrue(presentation.events.isEmpty)
    }
}
