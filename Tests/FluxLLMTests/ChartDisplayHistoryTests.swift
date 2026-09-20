import Foundation
import XCTest

@testable import FluxLLM

final class ChartDisplayHistoryTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testOneMinuteUsesTwentyThreeSecondMeansWithoutReinsertingExtrema() throws {
        let samples = (0..<120).map {
            point(Double($0) / 2, $0 % 6 == 2 ? 100 : 0)
        }
        let original = samples
        let history = ChartDisplayHistory(samples: samples, now: date(60), duration: 60)

        XCTAssertEqual(history.interval, 3)
        XCTAssertEqual(history.segments.count, 1)
        XCTAssertEqual(history.buckets.count, 20)
        XCTAssertEqual(history.buckets.map(\.count), Array(repeating: 6, count: 20))
        for bucket in history.buckets {
            XCTAssertEqual(bucket.value, 100.0 / 6, accuracy: 0.000_001)
            XCTAssertEqual(bucket.timestamp, bucket.end)
            XCTAssertEqual(bucket.end.timeIntervalSince(bucket.start), 2.5)
        }
        XCTAssertEqual(try XCTUnwrap(history.peak), 100.0 / 6, accuracy: 0.000_001)
        XCTAssertEqual(samples, original)
    }

    func testLongerWindowsUseFiveFifteenAndSixtySecondBinsWithoutBreakingValidRuns() {
        for (duration, expectedInterval) in [(300.0, 5.0), (900, 15), (3_600, 60)] {
            let samples = (0..<Int(duration * 2)).map { point(Double($0) / 2, 37) }
            let history = ChartDisplayHistory(
                samples: samples, now: date(duration), duration: duration)

            XCTAssertEqual(history.interval, expectedInterval)
            XCTAssertEqual(history.segments.count, 1)
            XCTAssertEqual(history.buckets.count, 60)
            XCTAssertTrue(history.buckets.allSatisfy { $0.value == 37 })
            XCTAssertEqual(history.current, history.buckets.last)
        }
    }

    func testRecoveredPlotStartsStayAnchoredAsTheirFirstAverageGrowsInEveryWindow() {
        for duration in [60.0, 300, 900, 3_600] {
            let samples = [
                point(0, 10), point(0.5, 20), point(1, 0, available: false),
                point(1.5, 20), point(2, 40),
            ]
            let initial = ChartDisplayHistory(samples: samples, now: date(2), duration: duration)
            let updated = ChartDisplayHistory(
                samples: samples + [point(2.5, 60)], now: date(2.5), duration: duration)

            XCTAssertEqual(
                initial.plotSegments.map { $0.map(\.timestamp) },
                [
                    [date(0), date(0.5)], [date(1.5), date(2)],
                ])
            XCTAssertEqual(
                updated.plotSegments.map { $0.map(\.timestamp) },
                [
                    [date(0), date(0.5)], [date(1.5), date(2.5)],
                ])
            XCTAssertEqual(initial.plotSegments.last?.map(\.value), [30, 30])
            XCTAssertEqual(updated.plotSegments.last?.map(\.value), [40, 40])
            XCTAssertEqual(initial.buckets.map(\.count), [2, 2])
            XCTAssertEqual(updated.buckets.map(\.count), [2, 3])
            XCTAssertEqual(initial.buckets.map(\.value), [15, 30])
            XCTAssertEqual(updated.buckets.map(\.value), [15, 40])
            XCTAssertEqual(updated.current?.timestamp, date(2.5))
            XCTAssertNil(updated.bucket(at: date(1)))
            XCTAssertEqual(updated.bucket(at: date(1.5)), updated.current)
        }
    }

    func testPlotConnectsLaterAveragesAtTheirOriginalEndpoints() {
        let history = ChartDisplayHistory(
            samples: [point(1, 10), point(2, 30), point(3, 40), point(4, 80)],
            now: date(4), duration: 60)

        XCTAssertEqual(
            history.plotSegments,
            [
                [
                    ChartDisplayPoint(timestamp: date(1), value: 20),
                    ChartDisplayPoint(timestamp: date(2), value: 20),
                    ChartDisplayPoint(timestamp: date(4), value: 60),
                ]
            ])
        XCTAssertEqual(history.buckets.map(\.count), [2, 2])
        XCTAssertEqual(history.buckets.map(\.value), [20, 60])
    }

    func testSingletonObservationsRemainPointsWithoutExtendingIntoGaps() {
        let history = ChartDisplayHistory(
            samples: [
                point(0, 10), point(1, 0, available: false), point(2, 20),
                point(10, 30), point(11, 50),
            ], now: date(11), duration: 3_600)

        XCTAssertEqual(
            history.plotSegments,
            [
                [ChartDisplayPoint(timestamp: date(0), value: 10)],
                [ChartDisplayPoint(timestamp: date(2), value: 20)],
                [
                    ChartDisplayPoint(timestamp: date(10), value: 40),
                    ChartDisplayPoint(timestamp: date(11), value: 40),
                ],
            ])
    }

    func testZeroIsValidAndUnavailableSamplesDoNotEnterTheMean() {
        let history = ChartDisplayHistory(
            samples: [
                point(0, 0), point(0.5, 0), point(1, 500, available: false),
                point(1.5, 0), point(2, 0),
            ], now: date(2), duration: 60)

        XCTAssertEqual(history.segments.map(\.count), [1, 1])
        XCTAssertEqual(history.buckets.map(\.value), [0, 0])
        XCTAssertEqual(history.buckets.map(\.count), [2, 2])
        XCTAssertEqual(history.peak, 0)
        XCTAssertEqual(history.current?.value, 0)
        XCTAssertNil(history.bucket(at: date(1)))
    }

    func testNegativeAndNonfiniteValuesSplitRunsInsideTheSameBucket() {
        for invalid in [-1.0, .nan, .infinity, -.infinity] {
            let history = ChartDisplayHistory(
                samples: [
                    point(0, 0), point(0.5, 10), point(1, invalid),
                    point(1.5, 20), point(2, 30),
                ], now: date(2), duration: 60)

            XCTAssertEqual(history.segments.map(\.count), [1, 1])
            XCTAssertEqual(history.buckets.map(\.value), [5, 25])
            XCTAssertEqual(
                history.plotSegments.map { $0.map(\.timestamp) },
                [
                    [date(0), date(0.5)], [date(1.5), date(2)],
                ])
            XCTAssertEqual(history.bucket(at: date(0.25))?.value, 5)
            XCTAssertEqual(history.bucket(at: date(1.75))?.value, 25)
            XCTAssertNil(history.bucket(at: date(0.75)))
            XCTAssertNil(history.bucket(at: date(1)))
            XCTAssertNil(history.bucket(at: date(1.25)))
        }
    }

    func testSamplingGapsSplitBeforeAggregationEvenInASixtySecondBucket() {
        let history = ChartDisplayHistory(
            samples: [point(0, 10), point(1, 20), point(10, 30), point(11, 40)],
            now: date(11), duration: 3_600)

        XCTAssertEqual(history.segments.map(\.count), [1, 1])
        XCTAssertEqual(history.buckets.map(\.value), [15, 35])
        XCTAssertEqual(
            history.plotSegments.map { $0.map(\.timestamp) },
            [
                [date(0), date(1)], [date(10), date(11)],
            ])
        XCTAssertEqual(history.bucket(at: date(0.5))?.value, 15)
        XCTAssertEqual(history.bucket(at: date(10.5))?.value, 35)
        XCTAssertNil(history.bucket(at: date(5)))
    }

    func testCompletedMeansStayFixedAsTheVisibleWindowClipsTheirContributors() throws {
        let samples = (0..<12).map { point(Double($0) / 2, Double($0 * 10)) }
        let initial = ChartDisplayHistory(samples: samples, now: date(60), duration: 60)
        let clipped = ChartDisplayHistory(samples: samples, now: date(61), duration: 60)
        let boundary = ChartDisplayHistory(samples: samples, now: date(62.5), duration: 60)
        let expired = ChartDisplayHistory(samples: samples, now: date(62.501), duration: 60)
        let first = try XCTUnwrap(initial.buckets.first)

        XCTAssertEqual(first.value, 25)
        XCTAssertEqual(first.start, date(0))
        XCTAssertEqual(first.timestamp, date(2.5))
        XCTAssertEqual(clipped.buckets.first, first)
        XCTAssertEqual(boundary.buckets.first, first)
        XCTAssertEqual(initial.plotSegments.first?.first?.timestamp, date(0))
        XCTAssertEqual(clipped.plotSegments.first?.first?.timestamp, date(1))
        XCTAssertEqual(clipped.plotSegments.first?.first?.value, first.value)
        XCTAssertEqual(boundary.plotSegments.first?.map(\.timestamp), [date(2.5), date(5.5)])
        XCTAssertEqual(expired.buckets.count, 1)
        XCTAssertEqual(expired.buckets.first, initial.buckets.last)
        XCTAssertEqual(expired.plotSegments.first?.map(\.timestamp), [date(3), date(5.5)])
        XCTAssertNil(clipped.bucket(at: date(0.5)))
        XCTAssertEqual(clipped.bucket(at: date(1.25)), first)
    }

    func testPartialLatestBucketUpdatesWithoutChangingThePreviousBin() throws {
        let firstSamples = [point(0, 10), point(1, 20), point(2, 30), point(3, 40)]
        let initial = ChartDisplayHistory(samples: firstSamples, now: date(3), duration: 60)
        let updated = ChartDisplayHistory(
            samples: firstSamples + [point(4, 80)], now: date(4), duration: 60)

        XCTAssertEqual(initial.buckets.first, updated.buckets.first)
        XCTAssertEqual(initial.current?.value, 40)
        let current = try XCTUnwrap(updated.current)
        XCTAssertEqual(current.value, 60)
        XCTAssertEqual(current.count, 2)
        XCTAssertEqual(current.start, date(3))
        XCTAssertEqual(current.timestamp, date(4))
    }

    func testRollingOneHourRetentionOmitsOnlyItsIncompleteLeadingBin() throws {
        func rolling(_ now: Double) -> ChartDisplayHistory {
            let samples = (0...7_200).map {
                let offset = now - 3_600 + Double($0) / 2
                return point(offset, offset.truncatingRemainder(dividingBy: 100))
            }
            return ChartDisplayHistory(samples: samples, now: date(now), duration: 3_600)
        }

        let aligned = rolling(3_600)
        let retained = try XCTUnwrap(aligned.buckets.first { $0.start == date(60) })
        XCTAssertEqual(aligned.buckets.first?.start, date(0))
        for now in [3_600.5, 3_601, 3_610] {
            let history = rolling(now)
            XCTAssertEqual(history.buckets.first, retained)
            XCTAssertEqual(history.segments.count, 1)
            XCTAssertEqual(history.plotSegments.first?.first?.timestamp, retained.start)
            XCTAssertNil(history.bucket(at: date(now - 3_600)))
            XCTAssertEqual(history.bucket(at: date(60)), retained)
            XCTAssertNotNil(history.current)
        }
        XCTAssertEqual(rolling(3_660).buckets.first, retained)
        XCTAssertEqual(rolling(3_660.5).buckets.first?.start, date(120))
    }

    func testStartupPartialBinNearNowRemainsVisible() {
        let history = ChartDisplayHistory(
            samples: [point(1, 10), point(2, 20), point(3, 30)], now: date(3), duration: 3_600)

        XCTAssertEqual(history.buckets.count, 1)
        XCTAssertEqual(history.buckets.first?.start, date(1))
        XCTAssertEqual(history.buckets.first?.value, 20)
        XCTAssertEqual(history.current, history.buckets.first)
        XCTAssertEqual(history.bucket(at: date(2)), history.buckets.first)
    }

    func testCurrentFreshnessUsesLatestUnderlyingObservationNotTheLongBucketBoundary() {
        let samples = (0...120).map { point(Double($0) / 2, 50) }
        let atLimit = ChartDisplayHistory(samples: samples, now: date(65), duration: 3_600)
        let stale = ChartDisplayHistory(samples: samples, now: date(65.001), duration: 3_600)

        XCTAssertEqual(atLimit.current?.timestamp, date(60))
        XCTAssertEqual(atLimit.current?.value, 50)
        XCTAssertNil(stale.current)
        XCTAssertFalse(stale.buckets.isEmpty)
    }

    func testLatestUnavailableOrInvalidObservationHidesCurrentWithoutErasingHistory() {
        for latest in [
            point(2, 0, available: false), point(2, .nan), point(2, .infinity), point(2, -1),
        ] {
            let history = ChartDisplayHistory(
                samples: [point(0, 20), point(1, 40), latest], now: date(2), duration: 60)
            XCTAssertNil(history.current)
            XCTAssertEqual(history.buckets.map(\.value), [30])
            XCTAssertNil(history.bucket(at: date(2)))
        }
    }

    func testHoverUsesBinCoverageAcrossLongWindowsWithoutAFiveSecondNearestLimit() throws {
        let samples = (0..<240).map { point(Double($0) / 2, Double($0)) }
        let history = ChartDisplayHistory(samples: samples, now: date(120), duration: 3_600)
        let first = try XCTUnwrap(history.buckets.first)
        let second = try XCTUnwrap(history.buckets.last)

        XCTAssertEqual(history.bucket(at: date(5)), first)
        XCTAssertEqual(history.bucket(at: date(30)), first)
        XCTAssertEqual(history.bucket(at: date(59.9)), first)
        XCTAssertEqual(history.bucket(at: date(60)), second)
        XCTAssertEqual(history.bucket(at: date(90)), second)
        XCTAssertNil(history.bucket(at: date(-0.1)))
        XCTAssertNil(history.bucket(at: date(119.6)))
        XCTAssertNil(history.bucket(at: date(121)))
    }

    func testFutureReadingsAreExcludedAndOutOfOrderSamplesAreSortedWithoutMutation() {
        let samples = [point(3, 60), point(0, 0), point(1, 30), point(100, 900)]
        let original = samples
        let history = ChartDisplayHistory(samples: samples, now: date(3), duration: 60)

        XCTAssertEqual(history.buckets.map(\.value), [15, 60])
        XCTAssertEqual(history.current?.timestamp, date(3))
        XCTAssertEqual(history.peak, 60)
        XCTAssertEqual(samples, original)
    }

    func testDuplicateTimestampUsesTheLatestObservationInsteadOfDoubleWeightingIt() {
        let history = ChartDisplayHistory(
            samples: [point(0, 100), point(1, 40), point(0, 20)], now: date(1), duration: 60)
        XCTAssertEqual(history.buckets.map(\.count), [2])
        XCTAssertEqual(history.buckets.map(\.value), [30])

        let unavailable = ChartDisplayHistory(
            samples: [point(0, 20), point(1, 40), point(1, 0, available: false)],
            now: date(1), duration: 60)
        XCTAssertNil(unavailable.current)
        XCTAssertEqual(unavailable.buckets.map(\.value), [20])
    }

    func testFiniteMeansAvoidOverflowAndUtilizationStaysWithinItsObservedBounds() throws {
        let maximum = Double.greatestFiniteMagnitude
        let large = ChartDisplayHistory(
            samples: [point(0, maximum), point(0.5, maximum), point(1, maximum)],
            now: date(1), duration: 60)
        XCTAssertEqual(try XCTUnwrap(large.peak), maximum)
        XCTAssertTrue(large.buckets.allSatisfy { $0.value.isFinite })

        let gpu = ChartDisplayHistory(
            samples: [point(0, 0), point(0.5, 100), point(1, 0), point(1.5, 100)],
            now: date(1.5), duration: 60)
        XCTAssertEqual(gpu.peak, 50)
        XCTAssertTrue(gpu.buckets.allSatisfy { (0...100).contains($0.value) })
    }

    func testInvalidWindowOrGapPolicyProducesNoDisplayData() {
        for duration in [0.0, -1, .nan, .infinity] {
            let history = ChartDisplayHistory(
                samples: [point(0, 10)], now: date(0), duration: duration)
            XCTAssertTrue(history.buckets.isEmpty)
            XCTAssertTrue(history.plotSegments.isEmpty)
            XCTAssertTrue(history.zeroFilledPlotSegments.isEmpty)
            XCTAssertNil(history.peak)
            XCTAssertNil(history.current)
            XCTAssertNil(history.bucket(at: date(0)))
        }
        for maximumGap in [-1.0, .nan, .infinity] {
            let history = ChartDisplayHistory(
                samples: [point(0, 10)], now: date(0), duration: 60, maximumGap: maximumGap)
            XCTAssertTrue(history.segments.isEmpty)
            XCTAssertTrue(history.plotSegments.isEmpty)
            XCTAssertTrue(history.zeroFilledPlotSegments.isEmpty)
        }
    }

    func testZeroFilledEmptyAndUnavailableWindowsAreOnlyDrawingBaselines() {
        for samples in [[], [point(1, 900, available: false)]] {
            let history = ChartDisplayHistory(samples: samples, now: date(60), duration: 60)

            XCTAssertEqual(
                history.zeroFilledPlotSegments,
                [
                    [
                        ChartDisplayPoint(timestamp: date(0), value: 0),
                        ChartDisplayPoint(timestamp: date(60), value: 0),
                    ]
                ])
            XCTAssertTrue(history.buckets.isEmpty)
            XCTAssertTrue(history.plotSegments.isEmpty)
            XCTAssertNil(history.peak)
            XCTAssertNil(history.current)
            XCTAssertNil(history.bucket(at: date(30)))
        }
    }

    func testZeroFilledStartupAndMiddleGapPreserveObservedAverages() {
        let history = ChartDisplayHistory(
            samples: [
                point(1, 20), point(2, 40), point(2.5, 900, available: false),
                point(3, 60), point(4, 80),
            ], now: date(6), duration: 7)

        XCTAssertEqual(
            history.zeroFilledPlotSegments,
            [
                [
                    ChartDisplayPoint(timestamp: date(-1), value: 0),
                    ChartDisplayPoint(timestamp: date(1), value: 0),
                    ChartDisplayPoint(timestamp: date(1), value: 30),
                    ChartDisplayPoint(timestamp: date(2), value: 30),
                    ChartDisplayPoint(timestamp: date(2), value: 0),
                    ChartDisplayPoint(timestamp: date(3), value: 0),
                    ChartDisplayPoint(timestamp: date(3), value: 70),
                    ChartDisplayPoint(timestamp: date(4), value: 70),
                    ChartDisplayPoint(timestamp: date(6), value: 70),
                ]
            ])
        XCTAssertEqual(history.buckets.map(\.value), [30, 70])
        XCTAssertEqual(history.buckets.map(\.count), [2, 2])
        XCTAssertEqual(history.segments.count, 2)
        XCTAssertEqual(history.peak, 70)
        XCTAssertEqual(history.current?.value, 70)
        XCTAssertNil(history.bucket(at: date(2.5)))
        XCTAssertNil(history.bucket(at: date(5)))
    }

    func testZeroFilledFreshTailExtendsAndStaleOrUnavailableTailReturnsToZero() {
        let samples = [point(0, 20), point(1, 40)]
        let fresh = ChartDisplayHistory(samples: samples, now: date(6), duration: 60)
        let stale = ChartDisplayHistory(samples: samples, now: date(6.5), duration: 60)
        let unavailable = ChartDisplayHistory(
            samples: samples + [point(2, 0, available: false)], now: date(2), duration: 60)

        XCTAssertEqual(fresh.zeroFilledPlotSegments.last?.last?.value, 30)
        XCTAssertEqual(fresh.zeroFilledPlotSegments.last?.last?.timestamp, date(6))
        for history in [stale, unavailable] {
            XCTAssertEqual(history.buckets, fresh.buckets)
            XCTAssertEqual(history.plotSegments, fresh.plotSegments)
            XCTAssertEqual(history.zeroFilledPlotSegments.last?.suffix(3).map(\.value), [30, 0, 0])
            XCTAssertEqual(history.zeroFilledPlotSegments.last?.suffix(3).first?.timestamp, date(1))
            XCTAssertNil(history.current)
        }
        XCTAssertEqual(stale.zeroFilledPlotSegments.last?.last?.timestamp, date(6.5))
        XCTAssertEqual(unavailable.zeroFilledPlotSegments.last?.last?.timestamp, date(2))
    }

    func testZeroFilledPathStaysInsideClippedWindowWithoutChangingItsFirstMean() {
        let history = ChartDisplayHistory(
            samples: [point(0, 10), point(1, 20), point(2, 30), point(3, 40)],
            now: date(61), duration: 60)

        XCTAssertEqual(history.zeroFilledPlotSegments.first?.first?.timestamp, date(1))
        XCTAssertEqual(history.zeroFilledPlotSegments.first?.dropFirst().first?.value, 20)
        XCTAssertEqual(history.buckets.first?.start, date(0))
        XCTAssertEqual(history.buckets.first?.count, 3)
        XCTAssertEqual(history.buckets.first?.value, 20)
        XCTAssertTrue(
            history.zeroFilledPlotSegments.flatMap { $0 }.allSatisfy {
                $0.timestamp >= date(1) && $0.timestamp <= date(61)
            })
    }

    func testZeroFilledInvalidNowProducesNoGeometry() {
        for offset in [Double.nan, .infinity, -.infinity] {
            let history = ChartDisplayHistory(
                samples: [], now: Date(timeIntervalSince1970: offset), duration: 60)
            XCTAssertTrue(history.zeroFilledPlotSegments.isEmpty)
        }
    }

    func testArchivedMeansKeepSampleWeightsAndNeverBecomeFreshReadings() {
        let archive = [
            [
                ArchivedChartBucket(start: date(0), end: date(59), value: 10, count: 120),
                ArchivedChartBucket(start: date(60), end: date(61), value: 40, count: 4),
            ]
        ]
        let history = ChartDisplayHistory(
            samples: [], now: date(62), duration: 7_200, archivedSegments: archive)

        XCTAssertEqual(history.interval, 120)
        XCTAssertEqual(history.buckets.count, 1)
        XCTAssertEqual(history.buckets.first?.count, 124)
        XCTAssertEqual(history.buckets.first?.start, date(0))
        XCTAssertEqual(history.buckets.first?.end, date(61))
        XCTAssertEqual(history.buckets.first?.value ?? 0, 1_360.0 / 124, accuracy: 0.000_001)
        XCTAssertNil(history.current)
    }

    func testArchivedGapsStaySeparateFromEachOtherAndRecentRawHistory() {
        let history = ChartDisplayHistory(
            samples: [point(120, 50), point(121, 70)], now: date(121), duration: 3_600,
            archivedSegments: [
                [ArchivedChartBucket(start: date(0), end: date(10), value: 10, count: 21)],
                [ArchivedChartBucket(start: date(20), end: date(30), value: 30, count: 21)],
            ])

        XCTAssertEqual(history.segments.count, 3)
        XCTAssertEqual(history.buckets.map(\.value), [10, 30, 60])
        XCTAssertEqual(history.bucket(at: date(5))?.value, 10)
        XCTAssertNil(history.bucket(at: date(15)))
        XCTAssertNil(history.bucket(at: date(60)))
        XCTAssertEqual(history.current?.value, 60)
    }

    func testZoomingIntoArchiveDoesNotInventFinerResolutionOrSlowRecentRawChart() {
        let archive = [
            [
                ArchivedChartBucket(start: date(0), end: date(59), value: 10, count: 120)
            ]
        ]
        let historical = ChartDisplayHistory(
            samples: [], now: date(60), duration: 60, archivedSegments: archive)
        let recent = ChartDisplayHistory(
            samples: [point(120, 20), point(121, 40)], now: date(121), duration: 60,
            archivedSegments: archive)

        XCTAssertEqual(historical.interval, 60)
        XCTAssertEqual(historical.buckets.first?.count, 120)
        XCTAssertEqual(recent.interval, 3)
        XCTAssertEqual(recent.buckets.map(\.value), [30])
    }

    private func point(_ offset: TimeInterval, _ value: Double, available: Bool = true)
        -> TimeSeriesPoint
    {
        TimeSeriesPoint(timestamp: date(offset), value: value, isAvailable: available)
    }

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }
}
