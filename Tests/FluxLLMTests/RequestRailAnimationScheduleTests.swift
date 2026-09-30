import CoreGraphics
import Foundation
import XCTest

@testable import FluxLLM

final class RequestRailAnimationScheduleTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testCompletionBecomingVisibleRestartsWorkWithoutANewReceipt() {
        let lane = RequestLane(
            id: UUID(), startedAt: origin.addingTimeInterval(-1), endedAt: origin)
        let event = RequestRailEvent(
            requestID: lane.id, kind: .completion, startedAt: origin, seed: 17)
        let assignments = [lane.id: RequestRailAssignment(track: 0, colorIndex: 0)]
        func eligibility(in rect: CGRect) -> RequestRailAnimationEligibility {
            let segments = RequestRailGeometry.layout(
                lanes: [lane], assignments: assignments, now: origin, duration: 30, rect: rect)
            return RequestRailAnimationEligibility(
                segments: segments, events: [event], now: origin, duration: 30)
        }

        let visible = eligibility(in: CGRect(x: 10, y: 20, width: 150, height: 84))
        XCTAssertEqual(visible.effectIDs, [event.id])
        XCTAssertTrue(visible.liveIDs.isEmpty)
        for emptyRect in [
            CGRect(x: 10, y: 20, width: 0, height: 84),
            CGRect(x: 10, y: 20, width: 150, height: 0),
        ] {
            let empty = eligibility(in: emptyRect)
            XCTAssertTrue(empty.effectIDs.isEmpty)
            XCTAssertEqual(empty.liveIDs, visible.liveIDs)
            XCTAssertNotEqual(empty, visible)
        }
        XCTAssertEqual(
            visible, eligibility(in: CGRect(x: 10, y: 20, width: 300, height: 84)),
            "An ordinary resize must retain the existing task and effect profile.")
    }

    func testShortestGlintPausesUntilUnchangedNextSpawnDeadline() {
        let end = origin.addingTimeInterval(0.43)
        let next = origin.addingTimeInterval(RequestRailAnimationSchedule.twinkleInterval)
        let active = RequestRailAnimationSchedule(
            at: origin, visibleUntil: [end], nextTwinkleAt: next)
        XCTAssertTrue(active.isAnimating)
        XCTAssertEqual(active.nextUpdate, end)

        let gap = RequestRailAnimationSchedule(
            at: end, visibleUntil: [end], nextTwinkleAt: next)
        XCTAssertFalse(gap.isAnimating)
        XCTAssertEqual(gap.nextUpdate, next)
        XCTAssertEqual(next.timeIntervalSince(origin), 0.505, accuracy: 0.000001)
    }

    func testPreparedProfileRetainsCleanupDeadlineThroughTemporaryEmptyGeometry() {
        let profile = RequestRailEffectProfile(seed: 17, requestDuration: 0.1, completion: false)
        let end = origin.addingTimeInterval(profile.visibleDuration)
        let empty = RequestRailAnimationSchedule(
            at: origin, visibleUntil: [], nextTwinkleAt: nil, retainedUntil: [end])
        XCTAssertFalse(empty.isAnimating)
        XCTAssertEqual(empty.nextUpdate, end)

        let visible = RequestRailAnimationSchedule(
            at: origin.addingTimeInterval(0.1), visibleUntil: [end], nextTwinkleAt: nil,
            retainedUntil: [end])
        XCTAssertTrue(visible.isAnimating)
        XCTAssertEqual(visible.nextUpdate, end)

        let expired = RequestRailAnimationSchedule(
            at: end, visibleUntil: [], nextTwinkleAt: nil, retainedUntil: [end])
        XCTAssertFalse(expired.isAnimating)
        XCTAssertNil(expired.nextUpdate)
    }

    func testOverlappingGlintsKeepAnimatingUntilLastVisibleEnd() {
        let firstEnd = origin.addingTimeInterval(0.59)
        let secondStart = origin.addingTimeInterval(0.505)
        let secondEnd = secondStart.addingTimeInterval(0.59)
        let next = secondStart.addingTimeInterval(RequestRailAnimationSchedule.twinkleInterval)
        let overlap = RequestRailAnimationSchedule(
            at: secondStart, visibleUntil: [firstEnd, secondEnd], nextTwinkleAt: next)
        XCTAssertTrue(overlap.isAnimating)
        XCTAssertEqual(overlap.nextUpdate, next)

        let tail = RequestRailAnimationSchedule(
            at: firstEnd, visibleUntil: [firstEnd, secondEnd], nextTwinkleAt: nil)
        XCTAssertTrue(tail.isAnimating)
        XCTAssertEqual(tail.nextUpdate, secondEnd)
    }

    func testLifecycleEffectKeepsTimelineRunningAcrossGlintGap() {
        let glintEnd = origin.addingTimeInterval(0.43)
        let effectEnd = origin.addingTimeInterval(1.1)
        let next = origin.addingTimeInterval(RequestRailAnimationSchedule.twinkleInterval)
        let schedule = RequestRailAnimationSchedule(
            at: glintEnd, visibleUntil: [glintEnd, effectEnd], nextTwinkleAt: next)
        XCTAssertTrue(schedule.isAnimating)
        XCTAssertEqual(schedule.nextUpdate, next)
    }

    func testNoWakeRemainsAfterLastEffectWithoutLiveRequests() {
        let end = origin.addingTimeInterval(1.5)
        let schedule = RequestRailAnimationSchedule(
            at: end, visibleUntil: [origin, end], nextTwinkleAt: nil)
        XCTAssertFalse(schedule.isAnimating)
        XCTAssertNil(schedule.nextUpdate)
    }

    func testVisibleDurationEndsAfterFinalRenderedPhaseBeforeReceiptExpires() {
        let rect = CGRect(x: 10, y: 20, width: 150, height: 7)
        let epsilon = 0.0001
        for seed in UInt64(0)..<24 {
            let arrival = RequestRailEffectProfile(
                seed: seed, requestDuration: 0.1, completion: false)
            XCTAssertGreaterThan(
                RequestRailEffectProfile.envelope(
                    (arrival.visibleDuration - epsilon) / arrival.burstDuration), 0)
            XCTAssertEqual(
                RequestRailEffectProfile.envelope(
                    (arrival.visibleDuration + epsilon) / arrival.burstDuration), 0)
            XCTAssertLessThan(arrival.visibleDuration, 0.8)

            for requestDuration in [0.1, 1_000] {
                let profile = RequestRailEffectProfile(
                    seed: seed, requestDuration: requestDuration, completion: true)
                let before = profile.visibleDuration - epsilon
                let after = profile.visibleDuration + epsilon
                func finalBurst(at age: TimeInterval) -> Double {
                    guard profile.explodes else { return 0 }
                    return RequestRailEffectProfile.envelope(
                        (age - profile.surgeDelay - profile.surgeDuration) / profile.burstDuration)
                }
                XCTAssertTrue(
                    profile.lightningFrame(age: before, rect: rect) != nil
                        || finalBurst(at: before) > 0)
                XCTAssertNil(profile.lightningFrame(age: after, rect: rect))
                XCTAssertEqual(finalBurst(at: after), 0)
                XCTAssertLessThan(profile.visibleDuration, 2.8)

                let end = origin.addingTimeInterval(profile.visibleDuration)
                let schedule = RequestRailAnimationSchedule(
                    at: end, visibleUntil: [end], nextTwinkleAt: nil)
                XCTAssertFalse(schedule.isAnimating)
                XCTAssertNil(schedule.nextUpdate)
            }
        }
    }
}
