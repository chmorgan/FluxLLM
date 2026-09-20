import XCTest

@testable import FluxLLM

final class GPUActivityPresentationTests: XCTestCase {
    func testSystemUtilizationPreservesPercentAndRejectsInvalidDeviceReadings() {
        XCTAssertEqual(GPUActivityPresentation.utilizationPercent(0), 0)
        XCTAssertEqual(GPUActivityPresentation.utilizationPercent(37.5), 37.5)
        XCTAssertEqual(GPUActivityPresentation.utilizationPercent(100), 100)
        let invalidValues: [Double?] = [nil, -1, 100.1, .infinity, .nan, .greatestFiniteMagnitude]
        for value in invalidValues {
            XCTAssertNil(GPUActivityPresentation.utilizationPercent(value))
        }
        XCTAssertEqual(GPUActivityPresentation.valueLabel(0), "0")
        XCTAssertEqual(GPUActivityPresentation.valueLabel(100), "100")
        XCTAssertEqual(GPUActivityPresentation.valueLabel(nil), "—")
    }

    func testPercentageHistoryPreservesGapsAndRejectsExecutionTimeValues() {
        let origin = Date(timeIntervalSince1970: 1_000)
        let samples = [
            TimeSeriesPoint(timestamp: origin, value: 30),
            TimeSeriesPoint(timestamp: origin.addingTimeInterval(1), value: 0, isAvailable: false),
            TimeSeriesPoint(timestamp: origin.addingTimeInterval(2), value: .nan),
            TimeSeriesPoint(timestamp: origin.addingTimeInterval(3), value: 140),
            TimeSeriesPoint(timestamp: origin.addingTimeInterval(4), value: 100),
            TimeSeriesPoint(timestamp: origin.addingTimeInterval(5), value: 0),
        ]
        let converted = GPUActivityPresentation.chartSamples(samples)
        XCTAssertEqual(converted.map(\.timestamp), samples.map(\.timestamp))
        XCTAssertEqual(converted.map(\.value), [30, 0, 0, 0, 100, 0])
        XCTAssertEqual(converted.map(\.isAvailable), [true, false, false, false, true, true])
    }
}
