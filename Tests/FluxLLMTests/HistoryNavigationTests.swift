import Foundation
import XCTest

@testable import FluxLLM

final class HistoryNavigationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        now.addingTimeInterval(offset)
    }

    func testAutomaticRangeUsesResolvedActivityWidthRegardlessOfHistoryAge() {
        let navigation = HistoryNavigation()
        XCTAssertTrue(navigation.isLive)
        XCTAssertEqual(navigation.preset, .automatic)
        for age in [0.0, 60, 300, 3_600, 86_400, 100_000] {
            for duration in [30.0, 60, 120, 300, 600] {
                let interval = navigation.interval(
                    now: now, historyAge: age, automaticDuration: duration)
                XCTAssertEqual(interval.duration, duration, "History age: \(age)")
                XCTAssertEqual(interval.end, now)
                XCTAssertEqual(
                    navigation.presentationViewport.interval(
                        at: now, range: .automatic, historyAge: age, automaticDuration: duration),
                    interval)
            }
        }
        XCTAssertEqual(navigation.interval(now: now, historyAge: 100_000).duration, 30)
    }

    func testAutomaticRangeRejectsInvalidWidthsAndClampsToRecentTenMinutes() {
        let navigation = HistoryNavigation()
        let examples: [(TimeInterval, TimeInterval)] = [
            (-1, 30), (0, 30), (29, 30), (601, 600), (86_400, 600),
            (.nan, 30), (.infinity, 30), (-.infinity, 30),
        ]
        for (supplied, expected) in examples {
            let interval = navigation.interval(
                now: now, historyAge: 100_000, automaticDuration: supplied)
            XCTAssertEqual(interval.duration, expected)
            XCTAssertEqual(interval.end, now)
            XCTAssertEqual(
                navigation.presentationViewport.interval(
                    at: now, range: .automatic, historyAge: 100_000,
                    automaticDuration: supplied), interval)
        }
    }

    func testAutomaticTitleShowsResolvedWidthAndBrowsingCapturesThatWidth() {
        var navigation = HistoryNavigation()
        for (duration, title) in [
            (30.0, "Auto · 30s"), (60, "Auto · 1m"), (120, "Auto · 2m"),
            (300, "Auto · 5m"), (600, "Auto · 10m"),
        ] {
            XCTAssertEqual(
                navigation.title(now: now, historyAge: 100_000, automaticDuration: duration), title)
        }

        navigation.pan(by: -1, now: now, historyAge: 100_000, automaticDuration: 120)
        let pinned = DateInterval(start: date(-240), duration: 120)
        XCTAssertEqual(
            navigation.interval(now: date(30), historyAge: 100_030, automaticDuration: 600), pinned)
        XCTAssertEqual(navigation.presentationViewport, .fixed(pinned))
        XCTAssertEqual(
            navigation.title(now: now, historyAge: 100_000, automaticDuration: 600), "2m")

        navigation.goLive()
        XCTAssertEqual(navigation.presentationViewport, .live(duration: 120))
        XCTAssertEqual(
            navigation.interval(now: date(30), historyAge: 100_030, automaticDuration: 30),
            DateInterval(start: date(-90), duration: 120))
        XCTAssertEqual(
            navigation.title(now: date(30), historyAge: 100_030, automaticDuration: 30), "2m")

        navigation.selectPreset(.automatic, now: date(30), historyAge: 100_030)
        XCTAssertEqual(navigation.presentationViewport, .historyRange)
        XCTAssertEqual(
            navigation.interval(now: date(30), historyAge: 100_030, automaticDuration: 30).duration,
            30)
        XCTAssertEqual(
            navigation.title(now: date(30), historyAge: 100_030, automaticDuration: 30),
            "Auto · 30s")
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
            let interval = navigation.interval(
                now: date(30), historyAge: 40, automaticDuration: 600)
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

    func testCustomPresetPinsResolvedAutomaticViewport() {
        var navigation = HistoryNavigation()
        navigation.selectPreset(
            .custom, now: now, historyAge: 100_000, automaticDuration: 300)

        XCTAssertEqual(navigation.preset, .custom)
        XCTAssertFalse(navigation.isLive)
        XCTAssertEqual(
            navigation.interval(now: date(10), historyAge: 100_010, automaticDuration: 30),
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
        XCTAssertEqual(
            navigation.interval(now: date(10), historyAge: 21_601, automaticDuration: 120).duration,
            120)
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
