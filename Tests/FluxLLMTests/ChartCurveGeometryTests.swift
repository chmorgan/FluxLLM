import Foundation
import XCTest

@testable import FluxLLM

final class ChartCurveGeometryTests: XCTestCase {
    func testSmoothingPreservesEveryReadingAndNeverExceedsAdjacentReadings() {
        let points: [CGPoint] = [
            .init(x: 0, y: 0), .init(x: 0.1, y: 60), .init(x: 3, y: 20),
            .init(x: 3.01, y: 100), .init(x: 7, y: 99), .init(x: 7.2, y: 1),
            .init(x: 9, y: 0), .init(x: 10, y: 0),
        ]
        let spans = ChartCurveGeometry.spans(points: points)
        XCTAssertEqual(spans.count, points.count - 1)
        for (index, span) in spans.enumerated() {
            XCTAssertEqual(span.start, points[index])
            XCTAssertEqual(span.end, points[index + 1])
            let lower = min(span.start.y, span.end.y)
            let upper = max(span.start.y, span.end.y)
            var previous = span.start.y
            for step in 0...100 {
                let value = span.value(at: CGFloat(step) / 100)
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, lower - 0.000_001)
                XCTAssertLessThanOrEqual(value, upper + 0.000_001)
                if span.end.y >= span.start.y {
                    XCTAssertGreaterThanOrEqual(value, previous - 0.000_001)
                } else {
                    XCTAssertLessThanOrEqual(value, previous + 0.000_001)
                }
                previous = value
            }
        }
    }

    func testZeroPlateausRemainExactlyZeroBesideSteepBursts() throws {
        let spans = ChartCurveGeometry.spans(points: [
            .init(x: 0, y: 40), .init(x: 1, y: 0), .init(x: 2, y: 0),
            .init(x: 10, y: 0), .init(x: 11, y: 80),
        ])
        for x in stride(from: 1.0, through: 10.0, by: 0.1) {
            let value = try XCTUnwrap(ChartCurveGeometry.value(atX: x, spans: spans))
            XCTAssertEqual(value, 0)
        }
    }

    func testRepeatedTimestampsKeepVerticalTransitionsAndPreferNewValue() throws {
        let spans = ChartCurveGeometry.spans(points: [
            .init(x: 0, y: 0), .init(x: 2, y: 0), .init(x: 2, y: 20),
            .init(x: 4, y: 20), .init(x: 4, y: 0), .init(x: 6, y: 0),
        ])
        XCTAssertEqual(spans.filter(\.isVertical).count, 2)
        XCTAssertTrue(
            spans.allSatisfy {
                $0.control1.x.isFinite && $0.control1.y.isFinite
                    && $0.control2.x.isFinite && $0.control2.y.isFinite
            })
        XCTAssertEqual(try XCTUnwrap(ChartCurveGeometry.value(atX: 2, spans: spans)), 20)
        XCTAssertEqual(try XCTUnwrap(ChartCurveGeometry.value(atX: 4, spans: spans)), 0)
        XCTAssertEqual(try XCTUnwrap(ChartCurveGeometry.value(atX: 3, spans: spans)), 20)
        XCTAssertEqual(try XCTUnwrap(ChartCurveGeometry.value(atX: 5, spans: spans)), 0)
    }

    func testCurveInspectionDoesNotReachOutsideObservedSegment() {
        let spans = ChartCurveGeometry.spans(points: [
            .init(x: 4, y: 20), .init(x: 6, y: 25),
        ])
        XCTAssertNil(ChartCurveGeometry.value(atX: 3.9, spans: spans))
        XCTAssertNil(ChartCurveGeometry.value(atX: 6.1, spans: spans))
        XCTAssertNil(ChartCurveGeometry.value(atX: .nan, spans: spans))
        XCTAssertTrue(ChartCurveGeometry.spans(points: []).isEmpty)
        XCTAssertTrue(ChartCurveGeometry.spans(points: [.zero]).isEmpty)
    }

    func testSteppedInspectionUsesExactToolBinAndNewValueAtBoundary() {
        let points: [CGPoint] = [
            .init(x: 1, y: 0), .init(x: 3, y: 0), .init(x: 3, y: 20),
            .init(x: 6, y: 20), .init(x: 6, y: 0), .init(x: 9, y: 0),
        ]
        XCTAssertNil(ChartCurveGeometry.stepValue(atX: 0, points: points))
        XCTAssertEqual(ChartCurveGeometry.stepValue(atX: 2.9, points: points), 0)
        XCTAssertEqual(ChartCurveGeometry.stepValue(atX: 3, points: points), 20)
        XCTAssertEqual(ChartCurveGeometry.stepValue(atX: 5.9, points: points), 20)
        XCTAssertEqual(ChartCurveGeometry.stepValue(atX: 6, points: points), 0)
        XCTAssertEqual(ChartCurveGeometry.stepValue(atX: 9, points: points), 0)
        XCTAssertNil(ChartCurveGeometry.stepValue(atX: 10, points: points))
    }
}
