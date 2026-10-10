import Foundation
import XCTest

@testable import FluxLLM

final class AutomaticHistoryRangeTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)
    private let active = BackendActivity.requests(running: 1, queued: 0)

    func testIdleStartupDoesNotGrowAndFirstActivityUsesThirtySeconds() {
        var range = AutomaticHistoryRange()
        observe(.idle, from: 0, through: 600, in: &range)
        XCTAssertEqual(range.duration, 30)
        range.observe(active, at: date(601))
        XCTAssertEqual(range.duration, 30)
    }

    func testSustainedActivityWidensBeforeEachBoundaryAndStopsAtTenMinutes() {
        var range = AutomaticHistoryRange()
        let transitions: [(Double, Double, Double)] = [
            (24, 30, 60), (48, 60, 120), (96, 120, 300), (240, 300, 600),
        ]
        var previous = 0.0
        for (threshold, before, after) in transitions {
            observe(active, from: previous, through: threshold - 0.5, in: &range)
            XCTAssertEqual(range.duration, before)
            range.observe(active, at: date(threshold))
            XCTAssertEqual(range.duration, after)
            previous = threshold + 0.5
        }
        observe(active, from: previous, through: 3_600, in: &range)
        XCTAssertEqual(range.duration, 600)
    }

    func testShortPauseHoldsWidthAndRemainsPartOfTheSameEpisode() {
        var range = AutomaticHistoryRange()
        observe(active, from: 0, through: 30, in: &range)
        observe(.idle, from: 30.5, through: 45, in: &range)
        XCTAssertEqual(range.duration, 60)
        range.observe(active, at: date(45.5))
        XCTAssertEqual(range.duration, 60)
        observe(active, from: 46, through: 48, in: &range)
        XCTAssertEqual(range.duration, 120)
    }

    func testConfirmedIdleArmsFreshEpisodeWithoutShrinkingWhileIdle() {
        var range = AutomaticHistoryRange()
        observe(active, from: 0, through: 100, in: &range)
        observe(.idle, from: 100.5, through: 400, in: &range)
        XCTAssertEqual(range.duration, 300)
        range.observe(active, at: date(400.5))
        XCTAssertEqual(range.duration, 30)
    }

    func testIdleSeparationRequiresSixtySecondsOfContinuousObservation() {
        var shortPause = AutomaticHistoryRange()
        observe(active, from: 0, through: 30, in: &shortPause)
        observe(.idle, from: 30.5, through: 90, in: &shortPause)
        shortPause.observe(active, at: date(90.25))
        XCTAssertEqual(shortPause.duration, 120)

        var separated = AutomaticHistoryRange()
        observe(active, from: 0, through: 30, in: &separated)
        observe(.idle, from: 30.5, through: 90.5, in: &separated)
        separated.observe(active, at: date(90.5))
        XCTAssertEqual(separated.duration, 30)
    }

    func testUnknownBreaksIdleContinuityAndDoesNotGrowTheRange() {
        var range = AutomaticHistoryRange()
        observe(active, from: 0, through: 30, in: &range)
        observe(.idle, from: 30.5, through: 70, in: &range)
        range.observe(.unknown, at: date(70.5))
        observe(.idle, from: 71, through: 110, in: &range)
        XCTAssertEqual(range.duration, 60)
        range.observe(active, at: date(110.5))
        XCTAssertEqual(range.duration, 300)
    }

    func testLongUnknownPeriodHoldsWidthThenStartsFreshOnReliableActivity() {
        var range = AutomaticHistoryRange()
        observe(active, from: 0, through: 100, in: &range)
        observe(.unknown, from: 100.5, through: 160.5, in: &range)
        XCTAssertEqual(range.duration, 300)
        range.observe(active, at: date(161))
        XCTAssertEqual(range.duration, 30)
    }

    func testUnobservedGapCannotAccumulateConfirmedIdle() {
        var range = AutomaticHistoryRange()
        observe(active, from: 0, through: 30, in: &range)
        range.observe(.idle, at: date(30.5))
        range.observe(.idle, at: date(85))
        observe(.idle, from: 85.5, through: 91, in: &range)
        range.observe(active, at: date(91.5))
        XCTAssertEqual(range.duration, 120)
    }

    func testLongObservationGapStartsFreshWithoutCallingTheGapIdle() {
        var range = AutomaticHistoryRange()
        observe(active, from: 0, through: 100, in: &range)
        range.observe(.unknown, at: date(500))
        XCTAssertEqual(range.duration, 300)
        range.observe(active, at: date(500.5))
        XCTAssertEqual(range.duration, 30)

        observe(active, from: 501, through: 601, in: &range)
        XCTAssertEqual(range.duration, 300)
        range.observe(active, at: date(661))
        XCTAssertEqual(range.duration, 30)
    }

    func testQueuedConcurrentAndAwaitingOutputRequestsAllCountAsActivity() {
        let examples: [BackendActivity] = [
            .requests(running: 0, queued: 1),
            .requests(running: 3, queued: 2),
            .observedRequests(count: 1, startedAt: origin, hasOutput: false),
        ]
        for activity in examples {
            var range = AutomaticHistoryRange()
            observe(activity, from: 0, through: 100, in: &range)
            XCTAssertEqual(range.duration, 300)
        }
    }

    func testSameTimestampBoundariesAndResetPreserveSubsecondEpisodes() {
        var range = AutomaticHistoryRange()
        range.observe(active, at: date(0))
        range.observe(.idle, at: date(0))
        observe(.idle, from: 0.5, through: 60, in: &range)
        range.observe(active, at: date(60))
        XCTAssertEqual(range.duration, 30)
        observe(active, from: 60.5, through: 84, in: &range)
        XCTAssertEqual(range.duration, 60)

        range.reset()
        XCTAssertEqual(range.duration, 30)
        range.observe(active, at: date(0))
        observe(active, from: 0.5, through: 24, in: &range)
        XCTAssertEqual(range.duration, 60, "Reset also clears the old timestamp barrier")
    }

    func testNonfiniteAndOlderObservationsCannotChangeEpisodeState() {
        var range = AutomaticHistoryRange()
        observe(active, from: 0, through: 30, in: &range)
        range.observe(.idle, at: date(0))
        range.observe(.unknown, at: Date(timeIntervalSinceReferenceDate: .infinity))
        range.observe(.idle, at: Date(timeIntervalSinceReferenceDate: .nan))
        observe(active, from: 30.5, through: 48, in: &range)
        XCTAssertEqual(range.duration, 120)
    }

    private func observe(
        _ activity: BackendActivity, from start: Double, through end: Double,
        in range: inout AutomaticHistoryRange
    ) {
        for offset in stride(from: start, through: end, by: 0.5) {
            range.observe(activity, at: date(offset))
        }
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
}
