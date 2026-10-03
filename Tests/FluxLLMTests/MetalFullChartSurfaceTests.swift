import AppKit
import XCTest

@testable import FluxLLM

@MainActor
final class MetalFullChartSurfaceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let requestID = UUID(uuidString: "00000000-0000-4000-8000-000000000017")!

    func testOrdinaryPublicationPreservesReceiptAndTwinkleSequence() throws {
        let lane = liveLane()
        let event = receipt(.arrival)
        var scheduler = MetalFullChartAnimationScheduler()
        scheduler.update(
            input(lanes: [lane], events: [event]), visible: true,
            at: origin, deterministic: true)
        let prepared = try XCTUnwrap(scheduler.prepared.first)
        let initialTwinkles = scheduler.twinkles
        let initialWork = scheduler.work
        let initialDeadline = scheduler.nextTwinkleAt
        var uninterrupted = scheduler

        scheduler.update(
            input(lanes: [lane], events: [event], now: date(0.125), width: 600),
            visible: true, at: date(0.125), deterministic: true)
        XCTAssertEqual(scheduler.work, initialWork)
        XCTAssertEqual(scheduler.prepared.count, 1)
        assertSameReceipt(try XCTUnwrap(scheduler.prepared.first), prepared)
        XCTAssertEqual(scheduler.twinkles, initialTwinkles)
        XCTAssertEqual(scheduler.nextTwinkleAt, initialDeadline)

        let due = try XCTUnwrap(initialDeadline)
        scheduler.advance(at: due)
        uninterrupted.advance(at: due)
        XCTAssertEqual(
            scheduler.twinkles, uninterrupted.twinkles,
            "An ordinary publication must not reseed the next glint")
        XCTAssertEqual(scheduler.nextTwinkleAt, uninterrupted.nextTwinkleAt)
    }

    func testChangedWorkRestartsReferenceCadenceWithoutReplayingReceipt() throws {
        let lane = liveLane()
        let event = receipt(.arrival)
        var scheduler = MetalFullChartAnimationScheduler()
        scheduler.update(
            input(lanes: [lane], events: [event]), visible: true,
            at: origin, deterministic: true)
        let prepared = try XCTUnwrap(scheduler.prepared.first)
        let existingTwinkle = try XCTUnwrap(scheduler.twinkles.first)
        let oldWork = scheduler.work
        let changed = input(lanes: [lane], events: [event], duration: 60)
        scheduler.update(changed, visible: true, at: date(0.1), deterministic: true)

        XCTAssertNotEqual(scheduler.work, oldWork)
        assertSameReceipt(try XCTUnwrap(scheduler.prepared.first), prepared)
        XCTAssertEqual(scheduler.twinkles.count, 2)
        XCTAssertEqual(scheduler.twinkles.first, existingTwinkle)
        XCTAssertEqual(scheduler.twinkles.last?.startedAt, date(0.1))
        XCTAssertEqual(
            scheduler.nextTwinkleAt,
            date(0.1).addingTimeInterval(RequestRailAnimationSchedule.twinkleInterval))
        var fresh = MetalFullChartAnimationScheduler()
        fresh.update(changed, visible: true, at: date(0.1), deterministic: true)
        XCTAssertEqual(
            scheduler.twinkles.last, fresh.twinkles.last,
            "Changed work uses the reference scheduler's fresh deterministic sequence")
    }

    func testEmptyGeometryRetainsCompletionProfileAndOriginalDeadlineThroughResize() throws {
        let lane = finishedLane()
        let event = receipt(.completion)
        var scheduler = MetalFullChartAnimationScheduler()
        scheduler.update(
            input(lanes: [lane], events: [event], width: 0), visible: true,
            at: origin, deterministic: true)
        let prepared = try XCTUnwrap(scheduler.prepared.first)
        XCTAssertFalse(scheduler.schedule.isAnimating)
        XCTAssertEqual(scheduler.schedule.nextUpdate, prepared.visibleUntil)
        XCTAssertTrue(scheduler.twinkles.isEmpty)

        scheduler.update(
            input(lanes: [lane], events: [event], width: 300), visible: true,
            at: date(0.125), deterministic: true)
        assertSameReceipt(try XCTUnwrap(scheduler.prepared.first), prepared)
        XCTAssertTrue(scheduler.schedule.isAnimating)
        XCTAssertEqual(scheduler.schedule.nextUpdate, prepared.visibleUntil)
        let visibleWork = scheduler.work
        scheduler.update(
            input(lanes: [lane], events: [event], width: 700), visible: true,
            at: date(0.25), deterministic: true)
        XCTAssertEqual(scheduler.work, visibleWork)
        assertSameReceipt(try XCTUnwrap(scheduler.prepared.first), prepared)
        XCTAssertEqual(scheduler.schedule.nextUpdate, prepared.visibleUntil)

        scheduler.update(
            input(lanes: [lane], events: [event], width: 0), visible: true,
            at: date(0.3), deterministic: true)
        XCTAssertFalse(scheduler.schedule.isAnimating)
        scheduler.advance(at: prepared.visibleUntil)
        XCTAssertTrue(scheduler.prepared.isEmpty)
        XCTAssertNil(scheduler.schedule.nextUpdate)
    }

    func testArrivalAndCompletionStopAtVisibleEndAndUnexpiredReceiptDoesNotReplay() throws {
        for kind in [RequestRailEvent.Kind.arrival, .completion] {
            let event = receipt(kind)
            let source = input(lanes: [finishedLane()], events: [event])
            var scheduler = MetalFullChartAnimationScheduler()
            scheduler.update(source, visible: true, at: origin, deterministic: true)
            let prepared = try XCTUnwrap(scheduler.prepared.first)
            XCTAssertLessThan(prepared.visibleUntil, event.expiresAt)
            XCTAssertTrue(scheduler.schedule.isAnimating)
            XCTAssertEqual(scheduler.schedule.nextUpdate, prepared.visibleUntil)
            scheduler.advance(at: prepared.visibleUntil.addingTimeInterval(-0.001))
            XCTAssertTrue(scheduler.schedule.isAnimating)

            scheduler.advance(at: prepared.visibleUntil)
            XCTAssertTrue(scheduler.prepared.isEmpty)
            XCTAssertFalse(scheduler.schedule.isAnimating)
            XCTAssertNil(scheduler.schedule.nextUpdate)
            XCTAssertNil(scheduler.nextTwinkleAt)
            scheduler.update(
                source, visible: true,
                at: prepared.visibleUntil.addingTimeInterval(0.001), deterministic: true)
            XCTAssertTrue(scheduler.prepared.isEmpty)
            XCTAssertFalse(scheduler.schedule.isAnimating)
            XCTAssertNil(scheduler.schedule.nextUpdate)
        }
    }

    func testHiddenAndDisabledUpdatesDiscardEffectsWithoutADeferredSpawn() throws {
        for hidden in [true, false] {
            let source = input(lanes: [liveLane()], events: [receipt(.arrival)])
            var scheduler = MetalFullChartAnimationScheduler()
            scheduler.update(source, visible: true, at: origin, deterministic: true)
            XCTAssertFalse(scheduler.prepared.isEmpty)
            XCTAssertFalse(scheduler.twinkles.isEmpty)
            scheduler.update(
                input(lanes: [liveLane()], events: [receipt(.arrival)], enabled: hidden),
                visible: !hidden, at: date(0.1), deterministic: true)
            XCTAssertEqual(scheduler.work?.enabled, false)
            assertIdle(scheduler)
            scheduler.advance(at: date(10))
            assertIdle(scheduler)

            scheduler.update(source, visible: true, at: date(11), deterministic: true)
            XCTAssertTrue(
                scheduler.prepared.isEmpty, "An expired receipt cannot replay after reveal")
            XCTAssertEqual(scheduler.twinkles.count, 1)
            XCTAssertEqual(scheduler.twinkles.first?.startedAt, date(11))
            XCTAssertEqual(
                scheduler.nextTwinkleAt,
                date(11).addingTimeInterval(RequestRailAnimationSchedule.twinkleInterval))
        }
    }

    func testMissedTwinkleDeadlinesProduceOneCurrentGlintWithoutCatchUp() throws {
        var scheduler = MetalFullChartAnimationScheduler()
        scheduler.update(input(lanes: [liveLane()]), visible: true, at: origin, deterministic: true)
        scheduler.advance(at: date(500))
        XCTAssertEqual(scheduler.twinkles.count, 1)
        XCTAssertEqual(scheduler.twinkles.first?.startedAt, date(500))
        XCTAssertEqual(
            scheduler.nextTwinkleAt,
            date(500).addingTimeInterval(RequestRailAnimationSchedule.twinkleInterval))
        let current = scheduler.twinkles
        let deadline = scheduler.nextTwinkleAt
        scheduler.advance(at: date(500))
        scheduler.advance(at: date(500.1))
        XCTAssertEqual(scheduler.twinkles, current)
        XCTAssertEqual(scheduler.nextTwinkleAt, deadline)
    }

    func testRapidWorkChangesRetainOnlyTheTwoNewestGlints() throws {
        var scheduler = MetalFullChartAnimationScheduler()
        scheduler.update(input(lanes: [liveLane()]), visible: true, at: origin, deterministic: true)
        for index in 1...12 {
            let previousNewest = try XCTUnwrap(scheduler.twinkles.last)
            let timestamp = date(Double(index) * 0.01)
            scheduler.update(
                input(lanes: [liveLane()], duration: 30 + Double(index)),
                visible: true, at: timestamp, deterministic: true)
            XCTAssertEqual(scheduler.twinkles.count, 2)
            XCTAssertEqual(scheduler.twinkles.first, previousNewest)
            XCTAssertEqual(scheduler.twinkles.last?.startedAt, timestamp)
            XCTAssertTrue(scheduler.twinkles.allSatisfy { $0.requestID == requestID })
        }
    }

    func testStopClearsRetainedPublicationAndCannotAdvanceWithoutNewInput() {
        var scheduler = MetalFullChartAnimationScheduler()
        scheduler.update(
            input(lanes: [liveLane()], events: [receipt(.arrival)]), visible: true,
            at: origin, deterministic: true)
        scheduler.stop(at: date(0.1))
        XCTAssertNil(scheduler.work)
        assertIdle(scheduler)
        scheduler.advance(at: date(1))
        XCTAssertNil(scheduler.work)
        assertIdle(scheduler)
    }

    func testDetachedAndHiddenHostUpdatesAllocateNoNativeResourcesOrWake() {
        let view = MetalFullChartView(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
        let scene = MetalFullChartScene(size: view.bounds.size, primitives: [])
        let source = input(lanes: [liveLane()], events: [receipt(.arrival)])
        var failures = 0
        view.update(
            scene: scene, revision: 1, cursor: nil, cursorRevision: nil,
            decorations: source, scale: 2, onFailure: { failures += 1 })
        XCTAssertNil(view.window)
        XCTAssertFalse(view.hasNativeResources)
        XCTAssertFalse(view.isAnimating)
        XCTAssertFalse(view.hasScheduledWake)
        view.isHidden = true
        view.update(
            scene: scene, revision: 2, cursor: scene, cursorRevision: 1,
            decorations: source, scale: 1, onFailure: { failures += 1 })
        view.layout()
        XCTAssertFalse(view.hasNativeResources)
        XCTAssertFalse(view.isAnimating)
        XCTAssertFalse(view.hasScheduledWake)
        XCTAssertEqual(failures, 0)
        view.stop()
    }

    func testStoppedHostIgnoresFurtherPublicationsIncludingInvalidInput() {
        let view = MetalFullChartView(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
        let source = input(lanes: [liveLane()], events: [receipt(.arrival)])
        var failures = 0
        view.stop()
        view.stop()
        view.update(
            scene: MetalFullChartScene(
                size: CGSize(width: CGFloat.nan, height: 120), primitives: []),
            revision: 1, cursor: nil, cursorRevision: nil,
            decorations: source, scale: .nan, onFailure: { failures += 1 })
        view.layout()
        XCTAssertEqual(failures, 0, "A dismantled host must not invoke new publication callbacks")
        XCTAssertFalse(view.hasNativeResources)
        XCTAssertFalse(view.isAnimating)
        XCTAssertFalse(view.hasScheduledWake)
    }

    func testInvalidPublicationFailsOnceBeforeNativeResourceAllocation() async {
        let view = MetalFullChartView(frame: CGRect(x: 0, y: 0, width: 300, height: 120))
        let scene = MetalFullChartScene(size: view.bounds.size, primitives: [])
        let mismatchedCursor = MetalFullChartScene(
            size: CGSize(width: 1, height: 1), primitives: [])
        let failureCallback = expectation(description: "Deferred failure callback")
        failureCallback.assertForOverFulfill = true
        var failures = 0
        for _ in 0..<2 {
            view.update(
                scene: scene, revision: 1, cursor: mismatchedCursor, cursorRevision: 1,
                decorations: input(lanes: []), scale: 1,
                onFailure: {
                    failures += 1
                    failureCallback.fulfill()
                })
        }
        XCTAssertEqual(
            failures, 0, "Failure publication must be deferred beyond the native view update")
        await fulfillment(of: [failureCallback], timeout: 2)
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(view.hasNativeResources)
        XCTAssertFalse(view.isAnimating)
        XCTAssertFalse(view.hasScheduledWake)
        view.stop()
    }

    private func date(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    private func liveLane() -> RequestLane {
        RequestLane(id: requestID, startedAt: date(-1))
    }

    private func finishedLane() -> RequestLane {
        RequestLane(id: requestID, startedAt: date(-1), endedAt: origin)
    }

    private func receipt(_ kind: RequestRailEvent.Kind) -> RequestRailEvent {
        RequestRailEvent(requestID: requestID, kind: kind, startedAt: origin, seed: 17)
    }

    private func input(
        lanes: [RequestLane], events: [RequestRailEvent] = [], now: Date? = nil,
        duration: TimeInterval = 30, width: CGFloat = 300, enabled: Bool = true
    ) -> MetalFullChartDecorationInput {
        let now = now ?? origin
        let assignments = Dictionary(
            uniqueKeysWithValues: lanes.enumerated().map {
                ($0.element.id, RequestRailAssignment(track: $0.offset, colorIndex: $0.offset))
            })
        let rail = CGRect(x: 10, y: 20, width: width, height: 84)
        return MetalFullChartDecorationInput(
            lanes: lanes,
            segments: RequestRailGeometry.layout(
                lanes: lanes, assignments: assignments,
                now: now, duration: duration, rect: rail),
            presentation: RequestRailPresentation(assignments: assignments, events: events),
            now: now, duration: duration, rail: rail,
            colors: Dictionary(
                uniqueKeysWithValues: lanes.map { ($0.id, SIMD4<Float>(0.1, 0.6, 0.9, 1)) }),
            enabled: enabled)
    }

    private func assertSameReceipt(
        _ actual: RequestRailLifecycleEffects.Prepared,
        _ expected: RequestRailLifecycleEffects.Prepared,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.key, expected.key, file: file, line: line)
        XCTAssertEqual(actual.startedAt, expected.startedAt, file: file, line: line)
        XCTAssertEqual(actual.expiresAt, expected.expiresAt, file: file, line: line)
        XCTAssertEqual(actual.visibleUntil, expected.visibleUntil, file: file, line: line)
        XCTAssertEqual(actual.profile, expected.profile, file: file, line: line)
    }

    private func assertIdle(
        _ scheduler: MetalFullChartAnimationScheduler, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(scheduler.prepared.isEmpty, file: file, line: line)
        XCTAssertTrue(scheduler.twinkles.isEmpty, file: file, line: line)
        XCTAssertNil(scheduler.nextTwinkleAt, file: file, line: line)
        XCTAssertFalse(scheduler.schedule.isAnimating, file: file, line: line)
        XCTAssertNil(scheduler.schedule.nextUpdate, file: file, line: line)
    }
}
