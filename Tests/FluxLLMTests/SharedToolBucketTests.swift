import Foundation
import XCTest

@testable import FluxLLM

final class SharedToolBucketTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testSparseRunsMatchReferenceAndPreserveNonzeroBucketOrdinals() throws {
        let fixtures: [(Fixture, Int, Double)] = [
            (
                Fixture(
                    name: "empty raw run before and after calls",
                    observations: [
                        point(0), point(1), point(2, available: false),
                        point(6), point(7), point(8, available: false), point(12), point(13),
                    ],
                    events: [call(6.25), call(6.5, name: "write"), result(6.75)], now: 13),
                1, 0
            ),
            (
                Fixture(
                    name: "empty archive before called archive and empty raw tail",
                    observations: [point(600), point(601)],
                    events: [call(310), call(311), call(312, name: "write"), result(315)],
                    now: 601, duration: 3_600,
                    archive: [
                        [bucket(0, 59.5), bucket(60, 119.5), bucket(120, 120)],
                        [bucket(300, 359.5), bucket(360, 419.5), bucket(420, 420)],
                    ]),
                3, 0
            ),
            (
                Fixture(
                    name: "omitted leading run contributes no ordinal",
                    observations: [
                        point(0.5), point(1), point(2, available: false), point(6), point(7),
                    ],
                    events: [call(0.75), call(6.25), result(6.5)], now: 7, duration: 6),
                0, 60
            ),
        ]

        for (fixture, expectedOrdinal, expectedCurrentRate) in fixtures {
            for archived in fixture.archive.flatMap({ $0 }) {
                XCTAssertTrue(archived.isValid, fixture.name)
            }
            let actual = assertMatchesReference(fixture)
            if !fixture.archive.isEmpty {
                // Prove archived coverage actually survived validation, including
                // the terminal zero-duration bin that advances the next ordinal.
                XCTAssertEqual(actual.interval, 60, fixture.name)
                XCTAssertEqual(actual.segments.count, 3, fixture.name)
                XCTAssertEqual(
                    actual.segments.first?.map(\.start),
                    [date(0), date(60), date(120)], fixture.name)
                XCTAssertEqual(actual.segments.first?.map(\.callCount), [0, 0, 0], fixture.name)
                XCTAssertEqual(actual.segments.first?.last?.observedDuration, 0, fixture.name)
                XCTAssertEqual(actual.bucket(at: date(310))?.callCount, 3, fixture.name)
                XCTAssertEqual(actual.bucket(at: date(310))?.observedDuration, 60, fixture.name)
            }
            let key = try XCTUnwrap(actual.reusablePlotKey, fixture.name)
            XCTAssertEqual(key.nonzeroBuckets.map(\.ordinal), [expectedOrdinal], fixture.name)
            XCTAssertEqual(
                key.nonzeroBuckets.map(\.callCount),
                actual.buckets.filter { $0.observedDuration > 0 && $0.callCount > 0 }.map(
                    \.callCount),
                fixture.name)
            XCTAssertEqual(actual.current?.callsPerMinute, expectedCurrentRate, fixture.name)
        }
    }

    func testZeroRunsPreserveGapPendingAndInstantaneousBoundaryBehavior() {
        let fixtures: [(Fixture, Bool)] = [
            (
                Fixture(
                    name: "gap calls remain instantaneous between zero runs",
                    observations: [
                        point(0), point(1), point(2, available: false), point(6), point(7),
                    ],
                    events: [call(3), call(3, name: "write"), result(4)], now: 7),
                false
            ),
            (
                Fixture(
                    name: "pending call after empty coverage suppresses current",
                    observations: [point(0), point(1), point(2)],
                    events: [call(2.25), result(2.5)], now: 2.5),
                false
            ),
            (
                Fixture(
                    name: "terminal boundary call has no observed duration",
                    observations: [point(0), point(1), point(2), point(3)],
                    events: [call(3)], now: 3),
                true
            ),
            (
                Fixture(
                    name: "new observation gives the boundary call exposure",
                    observations: [point(0), point(1), point(2), point(3), point(3.5)],
                    events: [call(3)], now: 3.5),
                true
            ),
            (
                Fixture(
                    name: "unavailable sample separates zero and nonzero coverage",
                    observations: [
                        point(0), point(1), point(2, available: false), point(3), point(4),
                    ],
                    events: [call(3.25), result(2.5)], now: 4),
                true
            ),
        ]

        for (fixture, reusable) in fixtures {
            let actual = assertMatchesReference(fixture)
            XCTAssertEqual(actual.reusablePlotKey != nil, reusable, fixture.name)
        }
    }

    func testInvalidWindowsDoNotExposeCachedZeroCoverage() {
        let fixtures = [
            Fixture(
                name: "zero duration", observations: [point(0), point(1)],
                events: [result(1)], now: 1, duration: 0),
            Fixture(
                name: "nonfinite duration", observations: [point(0), point(1)],
                events: [call(0.5)], now: 1, duration: .infinity),
            Fixture(
                name: "invalid gap", observations: [point(0), point(1)],
                events: [call(0.5)], now: 1, maximumGap: -1),
        ]
        for fixture in fixtures {
            let actual = assertMatchesReference(fixture)
            XCTAssertTrue(actual.buckets.isEmpty, fixture.name)
            XCTAssertNil(actual.reusablePlotKey, fixture.name)
        }
    }

    private struct Fixture {
        var name: String
        var observations: [TimeSeriesPoint]
        var events: [ToolActivityEvent]
        var now: TimeInterval
        var duration: TimeInterval = 60
        var maximumGap: TimeInterval = 5
        var archive: [[ArchivedChartBucket]] = []
    }

    @discardableResult
    private func assertMatchesReference(
        _ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line
    ) -> ToolActivityHistory {
        let now = date(fixture.now)
        let observation = ToolActivityObservation(
            observations: fixture.observations, now: now, duration: fixture.duration,
            maximumGap: fixture.maximumGap, archivedSegments: fixture.archive)
        let actual = ToolActivityHistory(
            preparedEvents: ToolActivityHistory.normalizedEvents(fixture.events, through: now),
            observation: observation)
        let expected = ReferenceToolActivityHistory(
            events: fixture.events, observations: fixture.observations, now: now,
            duration: fixture.duration, maximumGap: fixture.maximumGap,
            archivedSegments: fixture.archive)

        XCTAssertEqual(actual.interval, expected.interval, fixture.name, file: file, line: line)
        XCTAssertEqual(actual.buckets, expected.buckets, fixture.name, file: file, line: line)
        XCTAssertEqual(actual.segments, expected.segments, fixture.name, file: file, line: line)
        XCTAssertEqual(
            actual.plotSegments, expected.plotSegments, fixture.name, file: file, line: line)
        XCTAssertEqual(
            actual.zeroFilledPlotSegments, expected.zeroFilledPlotSegments,
            fixture.name, file: file, line: line)
        XCTAssertEqual(
            actual.directZeroFilledPlotSegments, expected.zeroFilledPlotSegments,
            fixture.name, file: file, line: line)
        XCTAssertEqual(
            actual.resultMarkers, expected.resultMarkers, fixture.name, file: file, line: line)
        XCTAssertEqual(actual.peak, expected.peak, fixture.name, file: file, line: line)
        XCTAssertEqual(actual.current, expected.current, fixture.name, file: file, line: line)

        var probes = fixture.observations.map(\.timestamp) + fixture.events.map(\.timestamp)
        probes += expected.buckets.flatMap { bucket in
            [
                bucket.start.addingTimeInterval(-0.01), bucket.start,
                bucket.start.addingTimeInterval(bucket.observedDuration / 2), bucket.end,
                bucket.end.addingTimeInterval(0.01),
            ]
        }
        probes += [now, now.addingTimeInterval(0.01), date(2.5), date(5)]
        if fixture.duration.isFinite {
            probes += [
                now.addingTimeInterval(-fixture.duration),
                now.addingTimeInterval(-fixture.duration - 0.01),
            ]
        }
        for timestamp in probes {
            XCTAssertEqual(
                actual.bucket(at: timestamp), expected.bucket(at: timestamp),
                fixture.name, file: file, line: line)
        }
        return actual
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }

    private func point(_ offset: TimeInterval, available: Bool = true) -> TimeSeriesPoint {
        TimeSeriesPoint(timestamp: date(offset), value: 1, isAvailable: available)
    }

    private func call(_ offset: TimeInterval, name: String = "read") -> ToolActivityEvent {
        ToolActivityEvent(kind: .call, name: name, timestamp: date(offset))
    }

    private func result(_ offset: TimeInterval) -> ToolActivityEvent {
        ToolActivityEvent(kind: .resultSubmission, name: "read", timestamp: date(offset))
    }

    private func bucket(_ start: TimeInterval, _ end: TimeInterval) -> ArchivedChartBucket {
        ArchivedChartBucket(start: date(start), end: date(end), value: 1, count: 1)
    }
}
