import CoreGraphics
import Foundation
import XCTest

@testable import FluxLLM

/// Integration checks for retained request identity and the rendered signal rails.
final class LaneLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_100)
    private let duration: TimeInterval = 100
    private let band = CGRect(x: 20, y: 10, width: 1000, height: 84)

    private func date(_ secondsAgo: TimeInterval) -> Date {
        now.addingTimeInterval(-secondsAgo)
    }

    private func lane(_ id: Int, start: TimeInterval, end: TimeInterval? = nil) -> RequestLane {
        RequestLane(
            id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", id))")!,
            startedAt: date(start), endedAt: end.map(date), terminal: end != nil)
    }

    private func layout(
        _ lanes: [RequestLane], state: RequestRailState = RequestRailState()
    ) -> [RequestRailGeometry.Segment] {
        let presentation = state.update(lanes: lanes, snapshotTime: now, presentedAt: now)
        return RequestRailGeometry.layout(
            lanes: lanes, assignments: presentation.assignments,
            now: now, duration: duration, rect: band)
    }

    func testLoneRequestRemainsASevenPointRail() throws {
        let live = lane(1, start: 100)
        let segment = try XCTUnwrap(layout([live]).first)
        XCTAssertEqual(segment.rect.height, 7, accuracy: 0.001)
        XCTAssertEqual(segment.rect.width, band.width, accuracy: 0.001)
        XCTAssertTrue(segment.isLive)
    }

    func testExactCompletionBoundaryReusesTrackWithoutOverlappingBars() throws {
        let earlier = lane(1, start: 100, end: 50)
        let later = lane(2, start: 50)
        let segments = layout([earlier, later])
        let first = try XCTUnwrap(segments.first { $0.lane.id == earlier.id })
        let second = try XCTUnwrap(segments.first { $0.lane.id == later.id })
        XCTAssertEqual(first.track, second.track)
        XCTAssertEqual(first.rect.midY, second.rect.midY, accuracy: 0.001)
        XCTAssertEqual(first.rect.maxX, second.rect.minX, accuracy: 0.001)
    }

    func testExistingRailsDoNotMoveWhenAnotherRequestDisappears() throws {
        let state = RequestRailState()
        let older = lane(1, start: 100, end: 20)
        let continuing = lane(2, start: 80)
        let before = try XCTUnwrap(
            layout([older, continuing], state: state).first { $0.lane.id == continuing.id })
        let after = try XCTUnwrap(layout([continuing], state: state).first)
        XCTAssertEqual(after.track, before.track)
        XCTAssertEqual(after.rect, before.rect)
    }

    func testBurstUsesSeparateFixedTracksWithNoBodyIntersections() {
        let lanes = (0..<5).map { lane($0, start: 100 - Double($0)) }
        let segments = layout(lanes)
        XCTAssertEqual(segments.count, 5)
        for segment in segments {
            XCTAssertEqual(segment.rect.height, 7, accuracy: 0.001)
            XCTAssertTrue(band.contains(segment.rect))
        }
        let ordered = segments.sorted { $0.track < $1.track }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertEqual(b.rect.midY - a.rect.midY, 14, accuracy: 0.001)
            XCTAssertFalse(a.rect.intersects(b.rect))
        }
    }

    func testExpiredHistoryAndFutureRequestsDoNotProduceBars() {
        XCTAssertTrue(layout([]).isEmpty)
        XCTAssertTrue(layout([lane(1, start: 150, end: 101)]).isEmpty)
        XCTAssertTrue(layout([lane(2, start: -1)]).isEmpty)
    }

    func testShortRequestKeepsItsActualLifetimeWithoutMinimumWidthExpansion() throws {
        let tiny = lane(1, start: 0.02, end: 0.01)
        let segment = try XCTUnwrap(layout([tiny]).first)
        XCTAssertEqual(segment.rect.width, 0.1, accuracy: 0.0001)
        XCTAssertLessThan(segment.rect.maxX, band.maxX)
    }
}
