import Foundation
import XCTest

@testable import FluxLLM

final class HistoryNavigationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        now.addingTimeInterval(offset)
    }

    func testAutomaticRangeExpandsAtEachHistoryBoundary() {
        let navigation = HistoryNavigation()
        let examples: [(TimeInterval, TimeInterval)] = [
            (0, 60), (60, 60), (61, 300), (300, 300),
            (301, 900), (900, 900), (901, 1800), (1800, 1800),
            (1801, 3600), (3600, 3600), (3601, 21_600),
            (21_600, 21_600), (21_601, 86_400), (100_000, 86_400),
        ]

        XCTAssertTrue(navigation.isLive)
        XCTAssertEqual(navigation.preset, .automatic)
        for (age, duration) in examples {
            let interval = navigation.interval(now: now, historyAge: age)
            XCTAssertEqual(interval.duration, duration, "History age: \(age)")
            XCTAssertEqual(interval.end, now)
        }
    }

    func testRelativePresetsResumeLiveAndKeepTheirDurations() {
        let examples: [(HistoryRange, TimeInterval)] = [
            (.minute, 60), (.fiveMinutes, 300), (.fifteenMinutes, 900),
            (.thirtyMinutes, 1800), (.hour, 3600), (.sixHours, 21_600), (.day, 86_400),
        ]

        for (preset, duration) in examples {
            var navigation = HistoryNavigation()
            navigation.select(DateInterval(start: date(-300), duration: 100), now: now)
            navigation.selectPreset(preset, now: now, historyAge: 10)

            XCTAssertEqual(navigation.preset, preset)
            XCTAssertTrue(navigation.isLive)
            XCTAssertNil(navigation.pinnedInterval)
            let interval = navigation.interval(now: date(30), historyAge: 40)
            XCTAssertEqual(interval.duration, duration)
            XCTAssertEqual(interval.end, date(30))
        }
    }

    func testPinnedSelectionDoesNotMoveAsNewSamplesArrive() {
        var navigation = HistoryNavigation()
        let selected = DateInterval(start: date(-300), duration: 200)
        navigation.select(selected, now: now)

        XCTAssertEqual(navigation.preset, .custom)
        XCTAssertFalse(navigation.isLive)
        XCTAssertEqual(navigation.pinnedInterval, selected)
        XCTAssertEqual(navigation.interval(now: date(60), historyAge: 3600), selected)
    }

    func testSelectionClampsToAvailableDayWhilePreservingDuration() {
        let examples: [(DateInterval, DateInterval)] = [
            (
                DateInterval(start: date(60), duration: 20),
                DateInterval(start: date(-20), duration: 20)
            ),
            (
                DateInterval(start: date(-100_000), duration: 20),
                DateInterval(start: date(-86_400), duration: 20)
            ),
            (
                DateInterval(start: date(-100_000), duration: 200_000),
                DateInterval(start: date(-86_400), duration: 86_400)
            ),
        ]

        for (selected, expected) in examples {
            var navigation = HistoryNavigation()
            navigation.select(selected, now: now)
            XCTAssertEqual(navigation.interval(now: now, historyAge: 0), expected)
            XCTAssertFalse(navigation.isLive)
        }
    }

    func testZeroLengthSelectionHasUsableMinimumDuration() {
        var navigation = HistoryNavigation()
        navigation.select(DateInterval(start: now, duration: 0), now: now)

        let interval = navigation.interval(now: now, historyAge: 0)
        XCTAssertEqual(interval.duration, 1)
        XCTAssertEqual(interval.end, now)
    }

    func testPinnedSelectionMovesOnlyWhenItFallsOutsideRetention() {
        var navigation = HistoryNavigation()
        navigation.select(DateInterval(start: date(-86_400), duration: 120), now: now)

        let interval = navigation.interval(now: date(60), historyAge: 100_000)
        XCTAssertEqual(interval.start, date(-86_340))
        XCTAssertEqual(interval.duration, 120)
        XCTAssertFalse(navigation.isLive)
    }

    func testCustomSelectionAcceptsExactBoundsAndRejectsInvalidInputWithoutChangingSelection() {
        var navigation = HistoryNavigation()
        XCTAssertTrue(navigation.selectCustom(start: date(-86_400), end: now, now: now))
        XCTAssertEqual(navigation.preset, .custom)
        XCTAssertFalse(navigation.isLive)
        let valid = navigation

        let invalidDates: [(Date, Date)] = [
            (date(-10), date(-10)),
            (now, date(-10)),
            (date(-10), date(1)),
            (date(-86_401), now),
            (Date(timeIntervalSince1970: .infinity), now),
            (Date(timeIntervalSince1970: -.infinity), now),
            (date(-10), Date(timeIntervalSince1970: .nan)),
        ]

        for (start, end) in invalidDates {
            XCTAssertFalse(navigation.selectCustom(start: start, end: end, now: now))
            XCTAssertEqual(navigation, valid)
        }
    }

    func testCustomPresetPinsCurrentViewport() {
        var navigation = HistoryNavigation(preset: .fiveMinutes)
        navigation.selectPreset(.custom, now: now, historyAge: 30)

        XCTAssertEqual(navigation.preset, .custom)
        XCTAssertFalse(navigation.isLive)
        XCTAssertEqual(
            navigation.interval(now: date(10), historyAge: 40),
            DateInterval(start: date(-300), duration: 300))
    }

    func testPanFreezesAndPreservesPresetWithLiveReturningToLatestData() {
        var navigation = HistoryNavigation(preset: .fiveMinutes)
        navigation.pan(by: -1, now: now, historyAge: 3600)

        XCTAssertEqual(navigation.preset, .fiveMinutes)
        XCTAssertFalse(navigation.isLive)
        XCTAssertEqual(
            navigation.interval(now: now, historyAge: 3600),
            DateInterval(start: date(-600), duration: 300))

        navigation.pan(by: 0.5, now: now, historyAge: 3600)
        XCTAssertEqual(
            navigation.interval(now: now, historyAge: 3600),
            DateInterval(start: date(-450), duration: 300))

        navigation.pan(by: 10, now: now, historyAge: 3600)
        XCTAssertEqual(navigation.interval(now: now, historyAge: 3600).end, now)
        XCTAssertFalse(navigation.isLive)

        navigation.goLive()
        XCTAssertTrue(navigation.isLive)
        XCTAssertNil(navigation.pinnedInterval)
        XCTAssertEqual(
            navigation.interval(now: date(30), historyAge: 3630),
            DateInterval(start: date(-270), duration: 300))
    }

    func testLiveRetainsCustomDurationUntilAutomaticIsExplicitlySelected() {
        var navigation = HistoryNavigation()
        XCTAssertTrue(navigation.selectCustom(start: date(-300), end: date(-123), now: now))
        navigation.goLive()

        XCTAssertTrue(navigation.isLive)
        XCTAssertEqual(navigation.interval(now: date(10), historyAge: 21_601).duration, 177)
        XCTAssertEqual(navigation.interval(now: date(10), historyAge: 21_601).end, date(10))

        navigation.selectPreset(.automatic, now: date(10), historyAge: 21_601)
        XCTAssertTrue(navigation.isLive)
        XCTAssertEqual(navigation.interval(now: date(10), historyAge: 21_601).duration, 86_400)
    }

    func testFittingEndedRequestIncludesPadding() {
        var navigation = HistoryNavigation()
        let lane = RequestLane(id: UUID(), startedAt: date(-120), endedAt: date(-20))
        navigation.fit(lane, now: now)

        XCTAssertEqual(navigation.preset, .custom)
        XCTAssertFalse(navigation.isLive)
        XCTAssertEqual(
            navigation.interval(now: now, historyAge: 300),
            DateInterval(start: date(-130), duration: 120))
    }

    func testFittingActiveRequestClampsPaddingToNowAndKeepsDuration() {
        var navigation = HistoryNavigation()
        let lane = RequestLane(id: UUID(), startedAt: date(-100))
        navigation.fit(lane, now: now)

        XCTAssertFalse(navigation.isLive)
        XCTAssertEqual(
            navigation.interval(now: now, historyAge: 300),
            DateInterval(start: date(-120), duration: 120))
    }

    func testFittingInstantaneousRequestHasOneSecondPaddingOnEachSide() {
        var navigation = HistoryNavigation()
        let lane = RequestLane(id: UUID(), startedAt: date(-20), endedAt: date(-20))
        navigation.fit(lane, now: now)

        XCTAssertEqual(
            navigation.interval(now: now, historyAge: 300),
            DateInterval(start: date(-21), duration: 2))
    }
}
