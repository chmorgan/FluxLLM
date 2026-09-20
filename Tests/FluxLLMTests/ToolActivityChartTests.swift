import Foundation
import XCTest

@testable import FluxLLM

final class ToolActivityChartTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testToolGeometryUsesItsOwnRateScaleAndRetainsStepTransitions() {
        let history = makeHistory(events: [event(.call, at: 1, name: "read_file")])
        let points = ToolActivityChartPresentation.normalizedSegments(
            history: history, now: origin.addingTimeInterval(9), duration: 60, upperBound: 40)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.map(\.y).max(), 0.5)
        let segment = points.first ?? []
        XCTAssertTrue(
            zip(segment, segment.dropFirst()).contains { first, second in
                first.x == second.x && first.y != second.y
            })
        XCTAssertEqual(segment.first?.x ?? -1, 0.85, accuracy: 0.000_001)
    }

    func testToolGeometryDoesNotBridgeUnavailableCoverage() {
        let samples = (0...9).map {
            TimeSeriesPoint(
                timestamp: origin.addingTimeInterval(Double($0)), value: 0,
                isAvailable: $0 != 4)
        }
        let history = ToolActivityHistory(
            events: [], observations: samples, now: origin.addingTimeInterval(9), duration: 60)
        let segments = ToolActivityChartPresentation.normalizedSegments(
            history: history, now: origin.addingTimeInterval(9), duration: 60, upperBound: 1)
        XCTAssertEqual(segments.count, 2)
        XCTAssertLessThan(segments[0].last!.x, segments[1].first!.x)
        XCTAssertTrue(segments.flatMap { $0 }.allSatisfy { $0.y == 0 })
    }

    func testResultSelectionUsesPixelProximityInsteadOfWholeBucket() {
        let result = event(.resultSubmission, at: 2, name: "read_file")
        let history = makeHistory(events: [result, event(.call, at: 2)])
        let close = ToolActivityChartPresentation.results(
            near: origin.addingTimeInterval(2.4), in: history, duration: 60, plotWidth: 600)
        XCTAssertEqual(close, [result])
        XCTAssertTrue(
            ToolActivityChartPresentation.results(
                near: origin.addingTimeInterval(2.6), in: history, duration: 60, plotWidth: 600
            ).isEmpty)
        XCTAssertEqual(
            ToolActivityChartPresentation.resultDescription(close),
            "Tool results submitted at \(result.timestamp.formatted(date: .omitted, time: .standard)): read_file"
        )
    }

    func testHoverExplainsActualCountExposureAndToolNames() throws {
        let history = makeHistory(events: [
            event(.call, at: 1, name: "read_file"), event(.call, at: 2, name: "search"),
        ])
        let bucket = try XCTUnwrap(history.bucket(at: origin.addingTimeInterval(1)))
        XCTAssertEqual(
            ToolActivityChartPresentation.rateDescription(bucket), "Tool calls 40.0 calls/min")
        XCTAssertEqual(
            ToolActivityChartPresentation.countDescription(bucket), "2 calls over 3.0 seconds")
        XCTAssertEqual(ToolActivityChartPresentation.namesDescription(bucket), "read_file, search")
        XCTAssertTrue(
            ToolActivityChartPresentation.accessibilitySummary(history).contains(
                "independent scale"))
        XCTAssertTrue(
            ToolActivityChartPresentation.accessibilitySummary(history).contains("2 calls"))
    }

    func testInstantaneousEvidenceDoesNotClaimZeroMeasuredRate() throws {
        let history = ToolActivityHistory(
            events: [event(.call, at: 0)],
            observations: [TimeSeriesPoint(timestamp: origin, value: 0)], now: origin, duration: 60)
        let bucket = try XCTUnwrap(history.bucket(at: origin))
        XCTAssertEqual(
            ToolActivityChartPresentation.rateDescription(bucket), "Tool-call rate pending")
        XCTAssertEqual(
            ToolActivityChartPresentation.countDescription(bucket), "1 call over 0.0 seconds")
        XCTAssertTrue(
            ToolActivityChartPresentation.accessibilitySummary(history).contains("rate pending"))
        XCTAssertTrue(
            ToolActivityChartPresentation.normalizedSegments(
                history: history, now: origin, duration: 60, upperBound: 1
            ).isEmpty)
    }

    func testGeneratedAndToolUnitsStayDistinct() {
        XCTAssertEqual(ChartMetric.throughput.unit, "tokens/s")
        XCTAssertEqual(ChartMetric.throughput.spokenUnit, "tokens per second")
        XCTAssertEqual(ToolActivityChartPresentation.unit, "calls/min")
        XCTAssertEqual(ToolActivityChartPresentation.spokenUnit, "tool calls per minute")
    }

    private func makeHistory(events: [ToolActivityEvent]) -> ToolActivityHistory {
        ToolActivityHistory(
            events: events,
            observations: (0...9).map {
                TimeSeriesPoint(timestamp: origin.addingTimeInterval(Double($0)), value: 0)
            }, now: origin.addingTimeInterval(9), duration: 60)
    }

    private func event(
        _ kind: ToolActivityEvent.Kind, at seconds: TimeInterval, name: String? = nil
    ) -> ToolActivityEvent {
        ToolActivityEvent(kind: kind, name: name, timestamp: origin.addingTimeInterval(seconds))
    }
}
