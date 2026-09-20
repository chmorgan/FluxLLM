import XCTest

@testable import FluxLLM

final class SparklineGeometryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testUnavailableSamplesAndTimeGapsBreakTheTrace() {
        let samples = [
            point(-20, 2), point(-19, 3), point(-18, 0, available: false),
            point(-17, 4), point(-16, 5), point(-2, 8), point(-1, 9),
        ]
        let segments = SparklineGeometry.normalizedSegments(samples: samples, now: now)
        XCTAssertEqual(segments.map(\.count), [2, 2, 2])
        XCTAssertEqual(segments[1][0].x, 43.0 / 60, accuracy: 0.0001)
    }

    func testDenseHistoryPreservesSingleSamplePeakAndValley() {
        var samples = (0..<600).map { point(Double($0) / 10 - 60, 10) }
        samples[241] = point(-35.9, 100)
        samples[242] = point(-35.8, 0)
        let segments = SparklineGeometry.normalizedSegments(
            samples: samples, now: now, pixelWidth: 12)
        XCTAssertEqual(segments.count, 1)
        XCTAssertLessThanOrEqual(segments[0].count, 48)
        XCTAssertEqual(segments[0].map(\.y).max(), 1)
        XCTAssertEqual(segments[0].map(\.y).min(), 0)
        XCTAssertEqual(segments[0].first?.x, 0)
        XCTAssertEqual(segments[0].last!.x, 59.9 / 60, accuracy: 0.0001)
        XCTAssertTrue(
            zip(segments[0], segments[0].dropFirst()).allSatisfy { pair in
                pair.0.x <= pair.1.x
            })
    }

    func testSelectedWindowAndScaleUseRealTime() {
        let segments = SparklineGeometry.normalizedSegments(
            samples: [point(-301, 100), point(-300, 10), point(-150, 20), point(0, 30)],
            now: now, duration: 300, upperBound: 50)
        let points = segments.flatMap { $0 }
        XCTAssertEqual(points.map(\.x), [0, 0.5, 1])
        XCTAssertEqual(points.map(\.y), [0.2, 0.4, 0.6])
    }

    func testNonfiniteObservationsBreakInsteadOfConnectingAroundThem() {
        let segments = SparklineGeometry.normalizedSegments(
            samples: [point(-2, 3), point(-1, .nan), point(0, 5)], now: now)
        XCTAssertEqual(segments.map(\.count), [1, 1])
        XCTAssertTrue(
            SparklineGeometry.normalizedSegments(
                samples: [point(0, 5)], now: now, duration: 0
            ).isEmpty)
    }

    func testScaleAddsHeadroomAndOnlyShrinksAfterSustainedLowerActivity() {
        var scale = ChartScaleState()
        scale.update(peak: 80, now: now)
        XCTAssertEqual(scale.upperBound, 100)
        scale.update(peak: 10, now: now.addingTimeInterval(1))
        scale.update(peak: 10, now: now.addingTimeInterval(8))
        XCTAssertEqual(scale.upperBound, 100)
        scale.update(peak: 10, now: now.addingTimeInterval(9))
        XCTAssertEqual(scale.upperBound, 20)
        scale.update(peak: 190, now: now.addingTimeInterval(10))
        XCTAssertEqual(scale.upperBound, 500)
    }

    func testNewBurstCancelsPendingScaleShrink() {
        var scale = ChartScaleState()
        scale.update(peak: 80, now: now)
        scale.update(peak: 10, now: now.addingTimeInterval(1))
        scale.update(peak: 80, now: now.addingTimeInterval(7))
        scale.update(peak: 10, now: now.addingTimeInterval(9))
        XCTAssertEqual(scale.upperBound, 100)
    }

    func testSystemGPUUsesFixedCapacityScaleForLowAndFullUtilization() throws {
        let upperBound = try XCTUnwrap(ChartMetric.gpuActivity.fixedUpperBound)
        let lowActivity = SparklineGeometry.normalizedSegments(
            samples: [point(-1, 0), point(0, 25)], now: now, upperBound: upperBound)
        let fullActivity = SparklineGeometry.normalizedSegments(
            samples: [point(-1, 50), point(0, 100)], now: now, upperBound: upperBound)

        XCTAssertEqual(upperBound, 100)
        XCTAssertEqual(lowActivity[0].map(\.y), [0, 0.25])
        XCTAssertEqual(fullActivity[0].map(\.y), [0.5, 1])
        XCTAssertEqual(ChartMetric.gpuActivity.unit, "%")
        XCTAssertEqual(ChartMetric.gpuActivity.spokenUnit, "percent system GPU utilization")
        XCTAssertNil(ChartMetric.throughput.fixedUpperBound)
    }

    func testCurrentMarkerKeepsZeroAndFullUtilizationAtTheirActualCoordinates() throws {
        let zero = try XCTUnwrap(
            SparklineGeometry.currentPoint(
                samples: [point(-1, 75), point(0, 0)], now: now, duration: 60, upperBound: 100))
        let full = try XCTUnwrap(
            SparklineGeometry.currentPoint(
                samples: [point(-1, 0), point(0, 100)], now: now, duration: 60, upperBound: 100))
        XCTAssertEqual(zero, CGPoint(x: 1, y: 0))
        XCTAssertEqual(full, CGPoint(x: 1, y: 1))
    }

    func testCurrentMarkerDoesNotReachBackAcrossTheLatestUnavailableOrInvalidObservation() {
        for last in [
            point(0, 0, available: false), point(0, .nan), point(0, .infinity), point(0, -1),
        ] {
            XCTAssertNil(
                SparklineGeometry.currentPoint(
                    samples: [point(-2, 10), point(-1, 20), last], now: now,
                    duration: 60, upperBound: 100))
        }
        let gpuSamples = GPUActivityPresentation.chartSamples([point(-1, 50), point(0, 150)])
        XCTAssertNil(
            SparklineGeometry.currentPoint(
                samples: gpuSamples, now: now, duration: 60, upperBound: 100))
        XCTAssertEqual(
            SparklineGeometry.normalizedSegments(
                samples: gpuSamples, now: now, upperBound: 100
            ).flatMap { $0 }.map(\.y), [0.5])
    }

    func testCurrentMarkerExpiresWhileHistoricalTraceRemainsVisible() {
        let samples = [point(-6, 10), point(-5, 20)]
        XCTAssertNotNil(
            SparklineGeometry.currentPoint(
                samples: samples, now: now, duration: 60, upperBound: 100))
        XCTAssertNil(
            SparklineGeometry.currentPoint(
                samples: samples, now: now.addingTimeInterval(0.001), duration: 60, upperBound: 100)
        )
        XCTAssertEqual(
            SparklineGeometry.normalizedSegments(
                samples: samples, now: now.addingTimeInterval(1), upperBound: 100
            ).map(\.count), [2])
    }

    func testCurrentMarkerRejectsFutureAndOutOfWindowSamplesWithoutInventingEndpoints() {
        XCTAssertNil(
            SparklineGeometry.currentPoint(
                samples: [point(1, 40)], now: now, duration: 60, upperBound: 100))
        XCTAssertNil(
            SparklineGeometry.currentPoint(
                samples: [point(-61, 40)], now: now, duration: 60, upperBound: 100))
        XCTAssertNil(
            SparklineGeometry.currentPoint(
                samples: [point(0, 40)], now: now, duration: 0, upperBound: 100))
        XCTAssertNil(
            SparklineGeometry.currentPoint(
                samples: [point(0, 40)], now: now, duration: 60, upperBound: .nan))
    }

    private func point(_ offset: TimeInterval, _ value: Double, available: Bool = true)
        -> TimeSeriesPoint
    {
        TimeSeriesPoint(
            timestamp: now.addingTimeInterval(offset), value: value, isAvailable: available)
    }
}
