import CoreGraphics
import XCTest

@testable import FluxLLM

final class ChartSurfaceBoundsTests: XCTestCase {
    func testDecorationBoundsPreserveBurstMarginAndClipToPlot() {
        let plot = CGSize(width: 220, height: 260)
        let interior = ChartSurfaceBounds.decorations(
            rail: CGRect(x: 60, y: 80, width: 80, height: 84), plotSize: plot)
        XCTAssertEqual(interior, CGRect(x: 19, y: 39, width: 162, height: 166))
        // A strict crop to the rail would lose an endpoint burst extending 40 points.
        XCTAssertTrue(interior.contains(CGPoint(x: 20, y: 80)))
        XCTAssertTrue(interior.contains(CGPoint(x: 140, y: 204)))
        let edge = ChartSurfaceBounds.decorations(
            rail: CGRect(x: 0, y: 0, width: 220, height: 84), plotSize: plot)
        XCTAssertEqual(edge, CGRect(x: 0, y: 0, width: 220, height: 125))
        let bottom = ChartSurfaceBounds.decorations(
            rail: CGRect(x: 60, y: 220, width: 80, height: 40), plotSize: plot)
        XCTAssertEqual(bottom, CGRect(x: 19, y: 179, width: 162, height: 81))
    }

    func testCursorBoundsKeepEndpointHalosAndClipAtBothEdges() {
        let plot = CGSize(width: 220, height: 260)
        let middle = ChartSurfaceBounds.cursor(x: 110, plotSize: plot)
        XCTAssertEqual(middle, CGRect(x: 103, y: 0, width: 14, height: 260))
        XCTAssertTrue(middle.contains(CGPoint(x: 104, y: 30)))
        XCTAssertTrue(middle.contains(CGPoint(x: 116, y: 30)))
        XCTAssertEqual(
            ChartSurfaceBounds.cursor(x: 0, plotSize: plot),
            CGRect(x: 0, y: 0, width: 7, height: 260))
        XCTAssertEqual(
            ChartSurfaceBounds.cursor(x: 220, plotSize: plot),
            CGRect(x: 213, y: 0, width: 7, height: 260))
    }

    func testFractionalBoundsRoundOutwardToPreserveRasterizationPhase() {
        let plot = CGSize(width: 220, height: 260)
        let cursorX: CGFloat = 110.25
        let cursor = ChartSurfaceBounds.cursor(x: cursorX, plotSize: plot)
        XCTAssertEqual(cursor, CGRect(x: 103, y: 0, width: 15, height: 260))
        XCTAssertLessThanOrEqual(cursor.width, 15)
        XCTAssertTrue(cursor.contains(CGPoint(x: cursorX - 6, y: 30)))
        XCTAssertTrue(cursor.contains(CGPoint(x: cursorX + 6, y: 30)))

        let rail = CGRect(x: 60.25, y: 80.75, width: 80.5, height: 84.5)
        let decorations = ChartSurfaceBounds.decorations(rail: rail, plotSize: plot)
        XCTAssertEqual(decorations, CGRect(x: 19, y: 39, width: 163, height: 168))
        XCTAssertTrue(decorations.contains(rail.insetBy(dx: -41, dy: -41)))
    }

    func testInvalidAndDisjointBoundsHaveNoDrawingSurface() {
        let rail = CGRect(x: 30, y: 80, width: 160, height: 84)
        let invalidSizes = [
            CGSize.zero, CGSize(width: -1, height: 260), CGSize(width: 220, height: -1),
            CGSize(width: 220, height: 0),
            CGSize(width: CGFloat.nan, height: 260),
            CGSize(width: 220, height: CGFloat.infinity),
        ]
        for plot in invalidSizes {
            XCTAssertEqual(ChartSurfaceBounds.decorations(rail: rail, plotSize: plot), .zero)
            XCTAssertEqual(ChartSurfaceBounds.cursor(x: 110, plotSize: plot), .zero)
        }
        let plot = CGSize(width: 220, height: 260)
        for invalid in [CGFloat.nan, .infinity, -.infinity] {
            XCTAssertEqual(ChartSurfaceBounds.cursor(x: invalid, plotSize: plot), .zero)
            XCTAssertEqual(
                ChartSurfaceBounds.decorations(
                    rail: CGRect(x: invalid, y: 80, width: 160, height: 84), plotSize: plot),
                .zero)
        }
        for empty in [
            CGRect.zero, CGRect(x: 1_000, y: 1_000, width: 160, height: 84),
            CGRect(x: 30, y: 80, width: -1, height: 84),
            CGRect(x: 30, y: 80, width: 160, height: -1),
        ] {
            XCTAssertEqual(ChartSurfaceBounds.decorations(rail: empty, plotSize: plot), .zero)
        }
        XCTAssertEqual(ChartSurfaceBounds.cursor(x: 1_000, plotSize: plot), .zero)
    }
}
