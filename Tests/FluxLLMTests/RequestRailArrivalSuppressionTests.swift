import CoreGraphics
import Foundation
import XCTest

@testable import FluxLLM

final class RequestRailArrivalSuppressionTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let rect = CGRect(x: 10, y: 20, width: 300, height: 84)

    func testSelectionLeavesDefaultReceiptsAndCompletionOrderUnchanged() {
        let events = [
            event(1, kind: .arrival), event(2, kind: .completion),
            event(3, kind: .arrival), event(4, kind: .completion),
        ]
        XCTAssertEqual(RequestRailLifecycleEffects.selecting(events, omitsArrivals: false), events)
        XCTAssertEqual(
            RequestRailLifecycleEffects.selecting(events, omitsArrivals: true),
            [events[1], events[3]])
        XCTAssertTrue(RequestRailLifecycleEffects.selecting([], omitsArrivals: true).isEmpty)
    }

    func testCompletionProfilesPhasesAndCachedTimingAreIdentical() throws {
        let lanes = [lane(1, start: -0.1), lane(2, start: -100, end: 0)]
        let assignments = assignments(lanes)
        for seed in UInt64(0)..<24 {
            let events = [
                event(1, kind: .arrival, seed: seed), event(2, kind: .completion, seed: seed),
            ]
            let selected = RequestRailLifecycleEffects.selecting(events, omitsArrivals: true)
            let baseline = prepare(events, lanes: lanes, assignments: assignments)
            let candidate = prepare(selected, lanes: lanes, assignments: assignments)
            XCTAssertEqual(baseline.count, 2)
            XCTAssertEqual(candidate.count, 1)
            let expected = try XCTUnwrap(baseline.first { $0.key.completion })
            let actual = try XCTUnwrap(candidate.first)
            XCTAssertEqual(actual.key, expected.key)
            XCTAssertEqual(actual.startedAt, expected.startedAt)
            XCTAssertEqual(actual.expiresAt, expected.expiresAt)
            XCTAssertEqual(actual.visibleUntil, expected.visibleUntil)
            XCTAssertEqual(actual.profile, expected.profile)
            for age in [0.1, 0.24, 0.6, 1.0, 2.0] {
                XCTAssertEqual(
                    actual.profile.lightningFrame(age: age, rect: rect),
                    expected.profile.lightningFrame(age: age, rect: rect))
            }

            // A corrected request duration must still reuse the original receipt's
            // profile, including all burst particles and lightning forks.
            let corrected = [lanes[0], lane(2, start: -0.2, end: 0)]
            let cached = prepare(
                selected, lanes: corrected, assignments: assignments, at: 0.1, previous: baseline)
            XCTAssertEqual(cached.map(\.profile), candidate.map(\.profile))
            XCTAssertEqual(cached.map(\.visibleUntil), candidate.map(\.visibleUntil))
        }
    }

    func testArrivalOmissionKeepsLiveTwinklesAndCompletionSchedule() {
        let lanes = [lane(1, start: -1), lane(2, start: -10, end: 0)]
        let assignments = assignments(lanes)
        let events = [event(1, kind: .arrival), event(2, kind: .completion)]
        let selected = RequestRailLifecycleEffects.selecting(events, omitsArrivals: true)
        let baselineEligibility = eligibility(events, lanes: lanes, assignments: assignments)
        let candidateEligibility = eligibility(selected, lanes: lanes, assignments: assignments)
        XCTAssertEqual(candidateEligibility.liveIDs, baselineEligibility.liveIDs)
        XCTAssertEqual(candidateEligibility.liveIDs, [lanes[0].id])
        XCTAssertEqual(candidateEligibility.effectIDs, [events[1].id])
        let glints = [
            RequestRailTwinkle(
                requestID: lanes[0].id, startedAt: origin, duration: 0.59,
                location: date(-0.5), size: 3, angle: 0.4, star: true),
            RequestRailTwinkle(
                requestID: lanes[0].id, startedAt: date(-0.1), duration: 0.43,
                location: date(-0.7), size: 2, angle: 0.2, star: false),
        ]
        let retained = glints.filter {
            $0.endsAt > date(0.1) && candidateEligibility.liveIDs.contains($0.requestID)
        }
        XCTAssertEqual(retained, glints)
        let baseline = prepare(events, lanes: lanes, assignments: assignments)
        let candidate = prepare(selected, lanes: lanes, assignments: assignments)
        let nextTwinkle = date(RequestRailAnimationSchedule.twinkleInterval)
        for time in [0.0, 0.43, 0.505, 0.59, 1.5, 3.0] {
            let reference = RequestRailAnimationSchedule(
                at: date(time), visibleUntil: baseline.map(\.visibleUntil) + retained.map(\.endsAt),
                nextTwinkleAt: nextTwinkle, retainedUntil: baseline.map(\.visibleUntil))
            let actual = RequestRailAnimationSchedule(
                at: date(time),
                visibleUntil: candidate.map(\.visibleUntil) + retained.map(\.endsAt),
                nextTwinkleAt: nextTwinkle, retainedUntil: candidate.map(\.visibleUntil))
            XCTAssertEqual(actual, reference)
        }
    }

    func testRepeatedArrivalPublicationsCannotPrepareEffectsOrAcquireATickDeadline() {
        // The arrival receipt can remain after its lane has ended. There are no
        // live glints or completion receipts to independently require animation.
        let lanes = [lane(1, start: -1, end: 0)]
        let assignments = assignments(lanes)
        let events = [event(1, kind: .arrival)]
        var previous: [RequestRailLifecycleEffects.Prepared] = []
        let firstWork = work(events, lanes: lanes, assignments: assignments)
        for time in [0.0, 0.1, 0.4, 0.79, 0.8, 1.0] {
            let selected = RequestRailLifecycleEffects.selecting(events, omitsArrivals: true)
            let eligible = eligibility(selected, lanes: lanes, assignments: assignments, at: time)
            previous = prepare(
                selected, lanes: lanes, assignments: assignments, at: time, previous: previous)
            XCTAssertTrue(previous.isEmpty)
            XCTAssertTrue(eligible.effectIDs.isEmpty)
            XCTAssertTrue(eligible.liveIDs.isEmpty)
            let schedule = RequestRailAnimationSchedule(
                at: date(time), visibleUntil: previous.map(\.visibleUntil), nextTwinkleAt: nil,
                retainedUntil: previous.map(\.visibleUntil))
            XCTAssertFalse(schedule.isAnimating)
            XCTAssertNil(schedule.nextUpdate)
            XCTAssertEqual(
                work(events, lanes: lanes, assignments: assignments, at: time), firstWork)
        }
        let baseline = prepare(events, lanes: lanes, assignments: assignments)
        XCTAssertEqual(baseline.count, 1)
        XCTAssertFalse(baseline[0].profile.completion)
        XCTAssertTrue(
            RequestRailAnimationSchedule(
                at: origin, visibleUntil: baseline.map(\.visibleUntil), nextTwinkleAt: nil
            ).isAnimating)
    }

    func testSuppressedReceiptCountsOnceAcrossVisibilityResizeAndCompletion() {
        let lanes = [lane(1, start: -1)]
        let assignments = assignments(lanes)
        let arrival = event(1, kind: .arrival)
        var tracker = RequestRailArrivalSuppression()
        func count(_ events: [RequestRailEvent], enabled: Bool = true, visible: Bool = true) -> Int
        {
            tracker.update(
                events: events, eligibleIDs: visible ? events.map(\.id) : [],
                lanes: lanes, assignments: assignments, timestamp: date(0.1), enabled: enabled)
        }
        XCTAssertEqual(count([arrival], enabled: false), 0)
        XCTAssertEqual(count([arrival], visible: false), 0)
        XCTAssertEqual(tracker.retainedReceiptCount, 0)
        XCTAssertEqual(count([arrival]), 1)
        XCTAssertEqual(count([arrival, arrival]), 0)
        XCTAssertEqual(count([arrival], enabled: false), 0)
        XCTAssertEqual(count([arrival], visible: false), 0)
        XCTAssertEqual(count([event(1, kind: .completion), arrival]), 0)
        XCTAssertEqual(count([arrival]), 0)
        XCTAssertEqual(tracker.retainedReceiptCount, 1)

        let empty = work([arrival], lanes: lanes, assignments: assignments, in: .zero)
        let visible = work([arrival], lanes: lanes, assignments: assignments)
        XCTAssertNotEqual(empty, visible, "Becoming visible must retry receipt accounting.")
        XCTAssertEqual(
            visible,
            work(
                [arrival], lanes: lanes, assignments: assignments,
                in: CGRect(x: 10, y: 20, width: 600, height: 84)))
    }

    func testIneligibleOverflowMissingClippedAndExpiredReceiptsAreNotCounted() {
        let lanes = [lane(1, start: -1), lane(2, start: -100), lane(3, start: -1)]
        let assignments = [
            lanes[0].id: RequestRailAssignment(track: 0, colorIndex: 0),
            lanes[1].id: RequestRailAssignment(track: 1, colorIndex: 1),
            lanes[2].id: RequestRailAssignment(
                track: RequestRailState.overflowTrack, colorIndex: 2),
        ]
        let events = [
            event(1, kind: .arrival, start: -1), event(2, kind: .arrival),
            event(3, kind: .arrival), event(4, kind: .arrival), event(1, kind: .completion),
        ]
        let eligible = eligibility(events, lanes: lanes, assignments: assignments)
        var tracker = RequestRailArrivalSuppression()
        XCTAssertEqual(
            tracker.update(
                events: events, eligibleIDs: eligible.effectIDs, lanes: lanes,
                assignments: assignments, timestamp: origin, enabled: true), 0)
        XCTAssertEqual(tracker.retainedReceiptCount, 0)
    }

    func testReceiptIdentityAndRetentionAreBoundedByCurrentUnexpiredPublication() {
        let lanes = [lane(1, start: -1)]
        let assignments = assignments(lanes)
        var tracker = RequestRailArrivalSuppression()
        for index in 0..<80 {
            let receipt = event(1, kind: .arrival, start: Double(index), seed: UInt64(index))
            XCTAssertEqual(
                tracker.update(
                    events: [receipt], eligibleIDs: [receipt.id], lanes: lanes,
                    assignments: assignments,
                    timestamp: date(Double(index)), enabled: true), 1)
            XCTAssertEqual(tracker.retainedReceiptCount, 1)
            XCTAssertEqual(
                tracker.update(
                    events: [receipt], eligibleIDs: [receipt.id], lanes: lanes,
                    assignments: assignments,
                    timestamp: receipt.expiresAt, enabled: true), 0)
            XCTAssertEqual(tracker.retainedReceiptCount, 0)
        }
        let first = event(1, kind: .arrival)
        let differentSeed = event(1, kind: .arrival, seed: 99)
        XCTAssertEqual(
            tracker.update(
                events: [first, differentSeed], eligibleIDs: [first.id], lanes: lanes,
                assignments: assignments, timestamp: origin, enabled: true), 2)
        XCTAssertEqual(tracker.retainedReceiptCount, 2)
        XCTAssertEqual(
            tracker.update(
                events: [], eligibleIDs: [], lanes: [], assignments: [:], timestamp: origin,
                enabled: false), 0)
        XCTAssertEqual(tracker.retainedReceiptCount, 0)
    }

    private func prepare(
        _ events: [RequestRailEvent], lanes: [RequestLane],
        assignments: [UUID: RequestRailAssignment],
        at time: TimeInterval = 0, previous: [RequestRailLifecycleEffects.Prepared] = []
    ) -> [RequestRailLifecycleEffects.Prepared] {
        RequestRailLifecycleEffects.prepare(
            events, lanes: lanes, assignments: assignments, now: date(time), timestamp: date(time),
            previous: previous)
    }

    private func eligibility(
        _ events: [RequestRailEvent], lanes: [RequestLane],
        assignments: [UUID: RequestRailAssignment],
        at time: TimeInterval = 0, in bounds: CGRect? = nil
    ) -> RequestRailAnimationEligibility {
        RequestRailAnimationEligibility(
            segments: RequestRailGeometry.layout(
                lanes: lanes, assignments: assignments, now: date(time), duration: 60,
                rect: bounds ?? rect),
            events: events, now: date(time), duration: 60)
    }

    private func work(
        _ events: [RequestRailEvent], lanes: [RequestLane],
        assignments: [UUID: RequestRailAssignment],
        at time: TimeInterval = 0, in bounds: CGRect? = nil
    ) -> RequestRailLifecycleEffects.WorkKey {
        RequestRailLifecycleEffects.WorkKey(
            events: events.map(RequestRailLifecycleEffects.Key.init),
            eligibility: eligibility(
                events, lanes: lanes, assignments: assignments, at: time, in: bounds),
            duration: 60, enabled: true)
    }

    private func assignments(_ lanes: [RequestLane]) -> [UUID: RequestRailAssignment] {
        Dictionary(
            uniqueKeysWithValues: lanes.enumerated().map {
                ($0.element.id, RequestRailAssignment(track: $0.offset, colorIndex: $0.offset))
            })
    }
    private func lane(_ number: Int, start: TimeInterval, end: TimeInterval? = nil) -> RequestLane {
        RequestLane(id: id(number), startedAt: date(start), endedAt: end.map(date))
    }
    private func event(
        _ number: Int, kind: RequestRailEvent.Kind, start: TimeInterval = 0, seed: UInt64 = 17
    ) -> RequestRailEvent {
        RequestRailEvent(requestID: id(number), kind: kind, startedAt: date(start), seed: seed)
    }
    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
}
