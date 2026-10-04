import XCTest

@testable import FluxLLM

final class ChartScaleStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

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
}
