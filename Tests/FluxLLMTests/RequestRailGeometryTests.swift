import CoreGraphics
import Foundation
import XCTest

@testable import FluxLLM

final class RequestRailGeometryTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let band = CGRect(x: 10, y: 20, width: 1000, height: 84)

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

    func testProjectionClipsTimestampsWithoutExtendingShortBars() throws {
        let oldLive = lane(-10)
        let tiny = lane(50, 50.01)
        let offscreen = lane(-10, 0)
        let future = lane(101)
        let lanes = [oldLive, tiny, offscreen, future]
        let segments = RequestRailGeometry.layout(
            lanes: lanes, assignments: assignments(lanes.map { ($0, 0) }),
            now: origin.addingTimeInterval(100), duration: 100, rect: band)

        XCTAssertEqual(segments.count, 2)
        let live = try XCTUnwrap(segments.first { $0.lane.id == oldLive.id })
        XCTAssertEqual(live.rect.minX, band.minX, accuracy: 0.0001)
        XCTAssertEqual(live.rect.maxX, band.maxX, accuracy: 0.0001)
        XCTAssertTrue(live.isLive)
        let short = try XCTUnwrap(segments.first { $0.lane.id == tiny.id })
        XCTAssertEqual(short.rect.width, 0.1, accuracy: 0.00001)
        XCTAssertEqual(short.cornerRadius, 0.05, accuracy: 0.00001)
        XCTAssertFalse(short.isLive)
    }

    func testOverflowCountsOnlyHiddenConcurrentRequests() {
        let first = lane(-10, 30)
        let second = lane(20, 40)
        let individual = lane(0, 100)
        let missing = lane(0, 100)
        let spans = RequestRailGeometry.overflow(
            lanes: [first, second, individual, missing],
            assignments: assignments([(first, 5), (second, 7), (individual, 4)]),
            now: origin.addingTimeInterval(100), duration: 100, rect: band)

        XCTAssertEqual(spans.map(\.count), [1, 2, 1])
        XCTAssertEqual(spans.map { $0.rect.minX }, [10, 210, 310])
        XCTAssertEqual(spans.map { $0.rect.width }, [200, 100, 100])
        for span in spans {
            XCTAssertEqual(span.rect.minY, 93.5)
            XCTAssertEqual(span.rect.height, 7)
        }
        for (left, right) in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(left.rect.maxX, right.rect.minX)
        }
    }

    func testOverflowMergesEqualCountsAtFinishAndReuseBoundaryButPreservesGaps() {
        let first = lane(10, 20)
        let second = lane(20, 30)
        let third = lane(40, 50)
        let lanes = [third, second, first]
        let spans = RequestRailGeometry.overflow(
            lanes: lanes, assignments: assignments(lanes.map { ($0, 5) }),
            now: origin.addingTimeInterval(100), duration: 100, rect: band)

        XCTAssertEqual(spans.map(\.count), [1, 1])
        XCTAssertEqual(spans.map { $0.rect.minX }, [110, 410])
        XCTAssertEqual(spans.map { $0.rect.width }, [200, 100])
    }

    func testOverflowClipsRunningRequestsAtNowAndOmitsEmptyIntervals() throws {
        let live = lane(90)
        let future = lane(110)
        let zero = lane(50, 50)
        let invalid = lane(60, 55)
        let expired = lane(-20, -10)
        let lanes = [live, future, zero, invalid, expired]
        let spans = RequestRailGeometry.overflow(
            lanes: lanes, assignments: assignments(lanes.map { ($0, 5) }),
            now: origin.addingTimeInterval(100), duration: 100, rect: band)

        XCTAssertEqual(spans.count, 1)
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(span.rect.minX, 910)
        XCTAssertEqual(span.rect.maxX, band.maxX)
        XCTAssertEqual(span.count, 1)
    }

    func testPerimeterStartsAtFinishedTipAndWrapsInBothDirections() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 7)
        let route = RequestRailPerimeter(rect: rect)
        let tip = CGPoint(x: rect.maxX, y: rect.midY)
        XCTAssertEqual(route.length, 2 * (100 - 7) + .pi * 7, accuracy: 0.000001)
        assertPoint(route.point(at: 0), equals: tip)
        for turns in -3...3 {
            assertPoint(route.point(at: CGFloat(turns) * route.length), equals: tip)
            assertPoint(
                route.point(at: CGFloat(turns) * route.length + 3),
                equals: route.point(at: 3))
            assertPoint(
                route.point(at: CGFloat(turns) * route.length - 3),
                equals: route.point(at: -3))
        }
        XCTAssertGreaterThan(route.point(at: 0.1).y, tip.y)
        XCTAssertLessThan(route.point(at: -0.1).y, tip.y)
        assertPoint(
            route.point(at: route.length / 2),
            equals: CGPoint(x: rect.minX, y: rect.midY))
    }

    func testPerimeterFollowsExactBorderContinuouslyForWideAndShortBars() {
        for width in [CGFloat(100), 7, 2, 0.1] {
            let rect = CGRect(x: 10, y: 20, width: width, height: 7)
            let radius = min(width, rect.height) / 2
            let route = RequestRailPerimeter(rect: rect)
            let expected = 2 * (rect.width + rect.height - 4 * radius) + 2 * .pi * radius
            XCTAssertEqual(route.length, expected, accuracy: 0.000001)
            let step = route.length / 1000
            for direction in [CGFloat(-1), 1] {
                var previous = route.point(at: 0)
                for index in 1...1000 {
                    let point = route.point(at: CGFloat(index) * step * direction)
                    let center = CGPoint(
                        x: min(rect.maxX - radius, max(rect.minX + radius, point.x)),
                        y: min(rect.maxY - radius, max(rect.minY + radius, point.y)))
                    XCTAssertEqual(
                        hypot(point.x - center.x, point.y - center.y),
                        radius, accuracy: 0.000001)
                    XCTAssertLessThanOrEqual(
                        hypot(point.x - previous.x, point.y - previous.y),
                        step + 0.000001)
                    previous = point
                }
                assertPoint(previous, equals: route.point(at: 0))
            }
        }
    }

    func testShortBarPerimeterIncludesItsStraightVerticalEdge() {
        let rect = CGRect(x: 10, y: 20, width: 2, height: 7)
        let route = RequestRailPerimeter(rect: rect)
        assertPoint(route.point(at: 2), equals: CGPoint(x: 12, y: 25.5))
        assertPoint(route.point(at: -2), equals: CGPoint(x: 12, y: 21.5))
        assertPoint(route.point(at: 2.5 + .pi / 2), equals: CGPoint(x: 11, y: 27))
    }

    func testDegeneratePerimeterHasFiniteStablePoint() {
        let route = RequestRailPerimeter(rect: CGRect(x: 10, y: 20, width: 0, height: 0))
        XCTAssertEqual(route.length, 0)
        for distance in [CGFloat(-10), 0, 10, .infinity, .nan] {
            assertPoint(route.point(at: distance), equals: CGPoint(x: 10, y: 20))
        }
    }

    private func assertPoint(
        _ point: CGPoint, equals expected: CGPoint, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(point.x, expected.x, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(point.y, expected.y, accuracy: 0.000001, file: file, line: line)
    }
}

final class RequestRailEffectTests: XCTestCase {
    private let bar = CGRect(x: 12, y: 20, width: 160, height: 7)

    func testSeededProfilesAndFramesDoNotRerollWhenRedrawn() throws {
        let first = RequestRailEffectProfile(seed: 472, requestDuration: 12, completion: true)
        let copy = RequestRailEffectProfile(seed: 472, requestDuration: 12, completion: true)
        let other = RequestRailEffectProfile(seed: 473, requestDuration: 12, completion: true)
        XCTAssertEqual(first, copy)
        XCTAssertNotEqual(first, other)
        for age in stride(from: 0.1, through: 0.9, by: 0.025) {
            let frame = try XCTUnwrap(first.lightningFrame(age: age, rect: bar))
            XCTAssertEqual(frame, first.lightningFrame(age: age, rect: bar))
            XCTAssertEqual(frame, copy.lightningFrame(age: age, rect: bar))
            XCTAssertNotEqual(frame, other.lightningFrame(age: age, rect: bar))
        }
    }

    func testCracklesUseIrregularSeededIntervalsAndDifferentForkStates() {
        let profile = RequestRailEffectProfile(seed: 38, requestDuration: 9, completion: true)
        let intervals = zip(profile.crackles, profile.crackles.dropFirst()).map { $1.at - $0.at }
        XCTAssertTrue(intervals.allSatisfy { $0 >= 0.045 && $0 <= 0.1 })
        XCTAssertGreaterThan(Set(intervals.map { Int($0 * 1000) }).count, 10)
        XCTAssertNotEqual(profile.crackles[0].offsets, profile.crackles[1].offsets)
        XCTAssertNotEqual(profile.crackles[0].forks, profile.crackles[1].forks)
        XCTAssertEqual(profile.flashAt.count, 2)
    }

    func testBothDirectionsReturnToFinishedTipAndFadeBeforeExpiry() throws {
        var directions = Set<Double>()
        for seed in UInt64(0)..<100 {
            let profile = RequestRailEffectProfile(
                seed: seed, requestDuration: 120, completion: true)
            directions.insert(profile.direction)
            let returnAge = profile.surgeDelay + profile.surgeDuration
            let returned = try XCTUnwrap(profile.lightningFrame(age: returnAge, rect: bar))
            XCTAssertEqual(returned.head.x, bar.maxX, accuracy: 0.000001)
            XCTAssertEqual(returned.head.y, bar.midY, accuracy: 0.000001)
            var brightness = returned.brightness
            for offset in stride(from: 0.01, through: 0.149, by: 0.01) {
                let frame = try XCTUnwrap(
                    profile.lightningFrame(age: returnAge + offset, rect: bar))
                XCTAssertLessThanOrEqual(frame.brightness, brightness)
                brightness = frame.brightness
            }
            let last = try XCTUnwrap(profile.lightningFrame(age: returnAge + 0.149, rect: bar))
            XCTAssertLessThan(last.brightness, 0.0002)
            XCTAssertNil(profile.lightningFrame(age: returnAge + 0.151, rect: bar))
            XCTAssertLessThan(returnAge + max(0.15, profile.burstDuration), 2.8)
        }
        XCTAssertEqual(directions, [-1, 1])
    }

    func testShortBarsHaveFiniteLightningAndExactReturnPoints() throws {
        for width in [CGFloat(0.1), 2, 7, 400] {
            let rect = CGRect(x: 12, y: 20, width: width, height: 7)
            let profile = RequestRailEffectProfile(seed: 17, requestDuration: 0.1, completion: true)
            for age in stride(from: 0.1, to: profile.surgeDuration, by: 0.01) {
                let frame = try XCTUnwrap(profile.lightningFrame(age: age, rect: rect))
                XCTAssertTrue(frame.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                XCTAssertTrue(
                    frame.forks.flatMap(\.points).allSatisfy { $0.x.isFinite && $0.y.isFinite })
            }
            let returned = try XCTUnwrap(
                profile.lightningFrame(age: profile.surgeDelay + profile.surgeDuration, rect: rect))
            XCTAssertEqual(returned.head.x, rect.maxX, accuracy: 0.000001)
            XCTAssertEqual(returned.head.y, rect.midY, accuracy: 0.000001)
        }
    }

    func testArrivalAndExplosionDurationsStayWithinEventLifetimes() {
        var explosions = 0
        for seed in UInt64(0)..<1000 {
            let arrival = RequestRailEffectProfile(
                seed: seed, requestDuration: 0, completion: false)
            XCTAssertGreaterThanOrEqual(arrival.burstDuration, 0.54)
            XCTAssertLessThanOrEqual(arrival.burstDuration, 0.66)
            XCTAssertNil(arrival.lightningFrame(age: 0.2, rect: bar))
            let completion = RequestRailEffectProfile(
                seed: seed, requestDuration: 1_000, completion: true)
            XCTAssertGreaterThanOrEqual(completion.burstDuration, 0.72)
            XCTAssertLessThanOrEqual(completion.burstDuration, 0.88)
            XCTAssertLessThan(
                completion.surgeDelay + completion.surgeDuration + completion.burstDuration, 2.8)
            if completion.explodes { explosions += 1 }
        }
        XCTAssertGreaterThan(explosions, 550)
        XCTAssertLessThan(explosions, 750)
    }

    func testBurstEnvelopeFadesGentlyToZero() {
        XCTAssertEqual(RequestRailEffectProfile.envelope(0), 0)
        XCTAssertEqual(RequestRailEffectProfile.envelope(0.04), 1)
        XCTAssertEqual(RequestRailEffectProfile.envelope(1), 0)
        var strength = RequestRailEffectProfile.envelope(0.8)
        for progress in stride(from: 0.81, through: 1.0, by: 0.01) {
            let next = RequestRailEffectProfile.envelope(progress)
            XCTAssertLessThanOrEqual(next, strength)
            strength = next
        }
        XCTAssertLessThan(RequestRailEffectProfile.envelope(0.99), 0.001)
    }
}
