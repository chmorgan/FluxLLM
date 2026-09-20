import CoreGraphics
import Foundation
import XCTest

@testable import FluxLLM

final class ChartInspectionGeometryTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let main = CGRect(x: 20, y: 10, width: 1000, height: 100)
    private let rails = CGRect(x: 20, y: 130, width: 1000, height: 84)
    private let tools = CGRect(x: 20, y: 240, width: 1000, height: 34)

    func testRegionsSelectTheirOwnContextAndTimestamp() throws {
        for (point, target) in [
            (CGPoint(x: 270, y: 40), ChartInspectionTarget.plot),
            (CGPoint(x: 270, y: 250), ChartInspectionTarget.tools),
        ] {
            let selected = try XCTUnwrap(select(point))
            XCTAssertEqual(selected.target, target)
            XCTAssertEqual(selected.timestamp, origin.addingTimeInterval(25))
        }
        for point in [
            CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 120),
            CGPoint(x: 20, y: 225), CGPoint(x: 20, y: 274),
            CGPoint(x: 19, y: 50), CGPoint(x: 1021, y: 50),
        ] {
            XCTAssertNil(select(point))
        }
    }

    func testReuseBoundarySelectsNewRequestWithoutInflatingLifetimes() throws {
        let first = lane(10, 20)
        let replacement = lane(20, 30)
        let mapping = assignments([(first, 2), (replacement, 2)])
        let requests = [replacement, first]
        XCTAssertEqual(
            select(CGPoint(x: 219.9, y: 163), lanes: requests, assignments: mapping)?.target,
            .request(first.id))
        XCTAssertEqual(
            select(CGPoint(x: 220, y: 163), lanes: requests, assignments: mapping)?.target,
            .request(replacement.id))
        XCTAssertNil(select(CGPoint(x: 119.9, y: 163), lanes: requests, assignments: mapping))
        XCTAssertNil(select(CGPoint(x: 320, y: 163), lanes: requests, assignments: mapping))
    }

    func testTrackStripeIncludesWhitespaceButNeverSelectsAnEmptyTrack() {
        let request = lane(0)
        let mapping = assignments([(request, 1)])
        for y in [CGFloat(144), 145, 150, 157.99] {
            XCTAssertEqual(
                select(CGPoint(x: 500, y: y), lanes: [request], assignments: mapping)?.target,
                .request(request.id))
        }
        for y in [CGFloat(143.99), 158, 213.99] {
            XCTAssertNil(select(CGPoint(x: 500, y: y), lanes: [request], assignments: mapping))
        }
        XCTAssertNil(select(CGPoint(x: 500, y: 150), lanes: [request]))
    }

    func testOverflowOnlySelectsOccupiedIntervalsAndHiddenAssignments() {
        let individual = lane(0)
        let hidden = lane(20, 30)
        let moreHidden = lane(25, 35)
        let requests = [individual, hidden, moreHidden]
        let mapping = assignments([(individual, 4), (hidden, 5), (moreHidden, 7)])
        for x in [CGFloat(220), 270, 369.9] {
            XCTAssertEqual(
                select(CGPoint(x: x, y: 207), lanes: requests, assignments: mapping)?.target,
                .overflow)
        }
        for x in [CGFloat(219.9), 370, 900] {
            XCTAssertNil(select(CGPoint(x: x, y: 207), lanes: requests, assignments: mapping))
        }
        XCTAssertNil(select(CGPoint(x: 270, y: 214), lanes: requests, assignments: mapping))
    }

    func testLiveTipAtNowIsSelectableButFinishedEndpointIsNot() {
        let live = lane(90)
        let finished = lane(90, 100)
        let mapping = assignments([(live, 0), (finished, 1)])
        let requests = [live, finished]
        XCTAssertEqual(
            select(CGPoint(x: 1020, y: 137), lanes: requests, assignments: mapping)?.target,
            .request(live.id))
        XCTAssertNil(select(CGPoint(x: 1020, y: 151), lanes: requests, assignments: mapping))
    }

    func testActiveLanesRejectMalformedIntervalsAndFutureTime() {
        let live = lane(0)
        let finished = lane(0, 10)
        let future = lane(20)
        let empty = lane(10, 10)
        let backwards = lane(20, 5)
        let badStart = RequestLane(id: UUID(), startedAt: Date(timeIntervalSince1970: .nan))
        let badEnd = RequestLane(
            id: UUID(), startedAt: origin, endedAt: Date(timeIntervalSince1970: .infinity))
        let requests = [live, finished, future, empty, backwards, badStart, badEnd]
        let now = origin.addingTimeInterval(100)
        XCTAssertEqual(
            ChartInspectionGeometry.activeLanes(
                at: origin.addingTimeInterval(10), now: now, lanes: requests), [live])
        XCTAssertTrue(
            ChartInspectionGeometry.activeLanes(
                at: now.addingTimeInterval(1), now: now, lanes: requests
            ).isEmpty)
        XCTAssertTrue(
            ChartInspectionGeometry.activeLanes(
                at: Date(timeIntervalSince1970: .nan), now: now, lanes: requests
            ).isEmpty)
    }

    func testInvalidProjectionCannotSelectAContext() {
        for duration in [TimeInterval(0), -1, .nan, .infinity] {
            XCTAssertNil(
                ChartInspectionGeometry.selection(
                    at: CGPoint(x: 100, y: 50), now: origin, duration: duration,
                    main: main, rails: rails, tools: tools, lanes: [], assignments: [:]))
        }
        for point in [CGPoint(x: CGFloat.nan, y: 50), CGPoint(x: 100, y: CGFloat.infinity)] {
            XCTAssertNil(select(point))
        }
        XCTAssertNil(
            ChartInspectionGeometry.selection(
                at: CGPoint(x: 100, y: 50), now: Date(timeIntervalSince1970: .nan), duration: 100,
                main: main, rails: rails, tools: tools, lanes: [], assignments: [:]))
        for invalid in [
            CGRect.zero, CGRect(x: 20, y: 10, width: -100, height: 100),
            CGRect(x: 20, y: 10, width: CGFloat.infinity, height: 100),
        ] {
            XCTAssertNil(
                ChartInspectionGeometry.selection(
                    at: CGPoint(x: 100, y: 50), now: origin, duration: 100,
                    main: invalid, rails: rails, tools: tools, lanes: [], assignments: [:]))
        }
    }

    func testCardFitsInsideBoundsAtEveryEdgeAndCorner() {
        for bounds in [
            CGRect(x: 8, y: 6, width: 280, height: 240),
            CGRect(x: 10, y: 20, width: 1200, height: 700),
        ] {
            let size = CGSize(width: 230, height: 100)
            for x in [bounds.minX, bounds.midX, bounds.maxX] {
                for y in [bounds.minY, bounds.midY, bounds.maxY] {
                    let pointer = CGPoint(x: x, y: y)
                    let card = CGRect(
                        origin: ChartInspectionGeometry.cardOrigin(
                            pointer: pointer, cardSize: size, bounds: bounds), size: size)
                    XCTAssertTrue(bounds.contains(card), "\(card) exceeds \(bounds)")
                    XCTAssertFalse(card.contains(pointer), "\(card) covers \(pointer)")
                }
            }
        }
    }

    func testCardUsesAnotherQuadrantWhenPreferredSideDoesNotFit() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let size = CGSize(width: 230, height: 100)
        XCTAssertEqual(
            ChartInspectionGeometry.cardOrigin(
                pointer: CGPoint(x: 590, y: 200), cardSize: size, bounds: bounds),
            CGPoint(x: 350, y: 90))
        XCTAssertEqual(
            ChartInspectionGeometry.cardOrigin(
                pointer: CGPoint(x: 10, y: 10), cardSize: size, bounds: bounds),
            CGPoint(x: 20, y: 20))
    }

    func testCardPlacementHandlesOversizedAndInvalidInputDefensively() {
        let bounds = CGRect(x: 12, y: 20, width: 180, height: 90)
        XCTAssertEqual(
            ChartInspectionGeometry.cardOrigin(
                pointer: CGPoint(x: 80, y: 60), cardSize: CGSize(width: 230, height: 120),
                bounds: bounds), bounds.origin)
        XCTAssertEqual(
            ChartInspectionGeometry.cardOrigin(
                pointer: CGPoint(x: CGFloat.nan, y: 60),
                cardSize: CGSize(width: 100, height: 40), bounds: bounds), bounds.origin)
        let origin = ChartInspectionGeometry.cardOrigin(
            pointer: .zero, cardSize: CGSize(width: CGFloat.infinity, height: 40), bounds: .null)
        XCTAssertTrue(origin.x.isFinite)
        XCTAssertTrue(origin.y.isFinite)
    }

    private func select(
        _ point: CGPoint, lanes: [RequestLane] = [],
        assignments: [UUID: RequestRailAssignment] = [:]
    ) -> ChartInspectionSelection? {
        ChartInspectionGeometry.selection(
            at: point, now: origin.addingTimeInterval(100), duration: 100,
            main: main, rails: rails, tools: tools, lanes: lanes, assignments: assignments)
    }

    private func lane(_ start: TimeInterval, _ end: TimeInterval? = nil) -> RequestLane {
        RequestLane(
            id: UUID(), startedAt: origin.addingTimeInterval(start),
            endedAt: end.map { origin.addingTimeInterval($0) })
    }

    private func assignments(_ entries: [(RequestLane, Int)]) -> [UUID: RequestRailAssignment] {
        Dictionary(
            uniqueKeysWithValues: entries.map {
                ($0.0.id, RequestRailAssignment(track: $0.1, colorIndex: 0))
            })
    }
}
