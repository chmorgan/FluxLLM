import CoreGraphics
import Foundation
import XCTest

@testable import FluxLLM

final class ChartTimeSelectionTests: XCTestCase {
    private let windowEnd = Date(timeIntervalSince1970: 1_800_000_100)
    private let plot = CGRect(x: 20, y: 10, width: 1000, height: 250)

    func testForwardAndReverseDragsSelectTheSameInterval() throws {
        let forward = try XCTUnwrap(
            select(from: CGPoint(x: 220, y: 50), to: CGPoint(x: 820, y: 50)))
        let reverse = try XCTUnwrap(
            select(from: CGPoint(x: 820, y: 50), to: CGPoint(x: 220, y: 50)))
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.start, windowEnd.addingTimeInterval(-80))
        XCTAssertEqual(forward.end, windowEnd.addingTimeInterval(-20))
    }

    func testDragCanLeaveThePlotButItsTimeBoundsStayInside() throws {
        let left = try XCTUnwrap(select(from: CGPoint(x: 520, y: 40), to: CGPoint(x: -500, y: -50)))
        XCTAssertEqual(left.start, windowEnd.addingTimeInterval(-100))
        XCTAssertEqual(left.end, windowEnd.addingTimeInterval(-50))
        let right = try XCTUnwrap(
            select(from: CGPoint(x: 520, y: 40), to: CGPoint(x: 1800, y: 500)))
        XCTAssertEqual(right.start, windowEnd.addingTimeInterval(-50))
        XCTAssertEqual(right.end, windowEnd)
    }

    func testShortVerticalAndOutsideDragsCannotChangeTheViewport() {
        for end in [CGPoint(x: 527.9, y: 40), CGPoint(x: 520, y: 250)] {
            XCTAssertNil(select(from: CGPoint(x: 520, y: 40), to: end))
        }
        for start in [
            CGPoint(x: 19, y: 40), CGPoint(x: 1021, y: 40),
            CGPoint(x: 520, y: 9), CGPoint(x: 520, y: 261),
        ] {
            XCTAssertNil(select(from: start, to: CGPoint(x: 820, y: 40)))
        }
        XCTAssertNotNil(select(from: CGPoint(x: 520, y: 40), to: CGPoint(x: 528, y: 40)))
        XCTAssertNil(select(from: CGPoint(x: 1015, y: 40), to: CGPoint(x: 1800, y: 40)))
    }

    func testZeroAndNonfiniteInputsCannotCreateAnInterval() {
        for duration in [TimeInterval(0), -1, .nan, .infinity] {
            XCTAssertNil(
                ChartTimeSelection.interval(
                    from: CGPoint(x: 220, y: 40), to: CGPoint(x: 820, y: 40),
                    in: plot, endingAt: windowEnd, duration: duration))
        }
        for bounds in [
            CGRect.zero, CGRect(x: 20, y: 10, width: -1000, height: 250),
            CGRect(x: 20, y: 10, width: 1000, height: -250),
            CGRect(x: 20, y: 10, width: CGFloat.infinity, height: 250),
            CGRect(x: CGFloat.nan, y: 10, width: 1000, height: 250),
        ] {
            XCTAssertNil(
                ChartTimeSelection.interval(
                    from: CGPoint(x: 220, y: 40), to: CGPoint(x: 820, y: 40),
                    in: bounds, endingAt: windowEnd, duration: 100))
        }
        for point in [CGPoint(x: CGFloat.nan, y: 40), CGPoint(x: 220, y: CGFloat.infinity)] {
            XCTAssertNil(select(from: point, to: CGPoint(x: 820, y: 40)))
            XCTAssertNil(select(from: CGPoint(x: 220, y: 40), to: point))
        }
        XCTAssertNil(
            ChartTimeSelection.interval(
                from: CGPoint(x: 220, y: 40), to: CGPoint(x: 820, y: 40),
                in: plot, endingAt: Date(timeIntervalSince1970: .nan), duration: 100))
    }

    private func select(from start: CGPoint, to end: CGPoint) -> DateInterval? {
        ChartTimeSelection.interval(
            from: start, to: end, in: plot, endingAt: windowEnd, duration: 100)
    }
}
