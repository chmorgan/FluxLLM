import AppKit
import XCTest

@testable import FluxLLM

@MainActor
final class MetalLifecycleEffectsSurfaceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let rail = CGRect(x: 10, y: 150, width: 300, height: 84)

    func testArrivalsAndCompletionsStartNativeClockButOrdinaryGlintsDoNot() {
        for completion in [false, true] {
            let effect = makeEffect(completion: completion)
            let element = MetalLifecycleEffectsSurface.Element.effect(effect)
            XCTAssertFalse(element.isActiveLifecycle(at: origin.addingTimeInterval(-0.001)))
            XCTAssertTrue(element.isActiveLifecycle(at: origin))
            XCTAssertTrue(
                element.isActiveLifecycle(at: effect.visibleUntil.addingTimeInterval(-0.001)))
            XCTAssertFalse(element.isActiveLifecycle(at: effect.visibleUntil))
            XCTAssertEqual(
                MetalLifecycleEffectsInput.nextBoundary(elements: [element], after: origin),
                effect.visibleUntil)
        }
        let glint = MetalLifecycleEffectsSurface.Element.twinkle(makeTwinkle())
        XCTAssertFalse(glint.isActiveLifecycle(at: origin.addingTimeInterval(0.1)))
    }

    func testReceiptExpiryBoundsNativeFramesEvenWhenProfileLivesLonger() {
        let original = makeEffect(completion: true)
        let effect = MetalLifecycleEffectsSurface.Effect(
            id: original.id, startDate: original.startDate,
            expiresAt: origin.addingTimeInterval(0.08), profile: original.profile,
            rect: original.rect, cornerRadius: original.cornerRadius, color: original.color)
        let element = MetalLifecycleEffectsSurface.Element.effect(effect)
        XCTAssertGreaterThan(original.profile.visibleDuration, 0.08)
        XCTAssertTrue(element.isActiveLifecycle(at: origin.addingTimeInterval(0.079)))
        XCTAssertFalse(element.isActiveLifecycle(at: origin.addingTimeInterval(0.08)))
        XCTAssertNil(
            MetalLifecycleEffectsInput.nextBoundary(elements: [element], after: effect.visibleUntil)
        )
    }

    func testFutureStartAndOverlappingEpisodeBoundariesAreExact() {
        let first = makeEffect(completion: false)
        let later = makeEffect(completion: true, at: origin.addingTimeInterval(0.05))
        let elements: [MetalLifecycleEffectsSurface.Element] = [.effect(first), .effect(later)]
        XCTAssertEqual(
            MetalLifecycleEffectsInput.nextBoundary(elements: elements, after: origin),
            later.startDate)
        XCTAssertEqual(
            MetalLifecycleEffectsInput.nextBoundary(elements: elements, after: later.startDate),
            min(first.visibleUntil, later.visibleUntil))
        XCTAssertTrue(elements.contains { $0.isActiveLifecycle(at: first.visibleUntil) })
        XCTAssertFalse(
            elements.contains {
                $0.isActiveLifecycle(at: max(first.visibleUntil, later.visibleUntil))
            })
    }

    func testMixedSegmentOrderRetainsExactProfilesThenOverlappingGlint() throws {
        let first = RequestLane(id: UUID(), startedAt: origin.addingTimeInterval(-55))
        let second = RequestLane(
            id: UUID(), startedAt: origin.addingTimeInterval(-15), endedAt: origin)
        let segments = [segment(first, track: 0), segment(second, track: 1)]
        let arrival = prepared(first.id, completion: false)
        let completion = prepared(second.id, completion: true)
        let glint = makeTwinkle(requestID: first.id)
        let input = try XCTUnwrap(
            MetalLifecycleEffectsInput.elements(
                segments: segments, prepared: [completion, arrival],
                eligibleIDs: [completion.key.eventID, arrival.key.eventID],
                twinkles: [glint.twinkle],
                now: origin, duration: 60, rail: rail, color: { _ in SIMD4(0.1, 0.6, 0.9, 1) }))
        XCTAssertEqual(input.count, 3)
        guard case .effect(let actualArrival) = input[0],
            case .twinkle(let actualGlint) = input[1],
            case .effect(let actualCompletion) = input[2]
        else { return XCTFail("Source order changed") }
        XCTAssertEqual(actualArrival.id, arrival.key)
        XCTAssertEqual(actualArrival.profile, arrival.profile)
        XCTAssertEqual(actualArrival.expiresAt, arrival.expiresAt)
        XCTAssertEqual(actualGlint.twinkle, glint.twinkle)
        XCTAssertEqual(actualCompletion.id, completion.key)
        XCTAssertEqual(actualCompletion.profile, completion.profile)
        XCTAssertEqual(actualCompletion.rect, segments[1].rect)
        let relative = input.map {
            $0.rendererElement(relativeTo: origin.addingTimeInterval(0.125))
        }
        guard case .effect(let shaderArrival) = relative[0],
            case .effect(let shaderCompletion) = relative[2]
        else { return XCTFail("Renderer lost lifecycle types") }
        XCTAssertEqual(shaderArrival.startTime, -0.125, accuracy: 0.000001)
        XCTAssertEqual(shaderCompletion.startTime, -0.125, accuracy: 0.000001)
        XCTAssertEqual(shaderCompletion.profile, completion.profile)
    }

    func testIneligibleArrivalsStayOmittedButOldCompletionsStillDraw() throws {
        let lane = RequestLane(
            id: UUID(), startedAt: origin.addingTimeInterval(-100), endedAt: origin)
        let arrival = prepared(lane.id, completion: false)
        let completion = prepared(lane.id, completion: true)
        let input = try XCTUnwrap(
            MetalLifecycleEffectsInput.elements(
                segments: [segment(lane)], prepared: [arrival, completion],
                eligibleIDs: [arrival.key.eventID, completion.key.eventID], twinkles: [],
                now: origin, duration: 60, rail: rail, color: { _ in SIMD4(0.1, 0.6, 0.9, 1) }))
        XCTAssertEqual(input.count, 1)
        guard case .effect(let effect) = input[0] else { return XCTFail("Expected completion") }
        XCTAssertTrue(effect.profile.completion)
        XCTAssertEqual(effect.profile, completion.profile)
        XCTAssertNil(
            MetalLifecycleEffectsInput.elements(
                segments: [segment(lane)], prepared: [completion],
                eligibleIDs: [completion.key.eventID], twinkles: [],
                now: origin, duration: 60, rail: rail, color: { _ in nil }))
    }

    func testOrdinaryGlintsProduceNoNativeDescriptorsOutsideLifecycleEpisodes() throws {
        let lane = RequestLane(id: UUID(), startedAt: origin.addingTimeInterval(-10))
        let glint = makeTwinkle(requestID: lane.id)
        let input = try XCTUnwrap(
            MetalLifecycleEffectsInput.elements(
                segments: [segment(lane)], prepared: [], eligibleIDs: [], twinkles: [glint.twinkle],
                now: origin, duration: 60, rail: rail, color: { _ in SIMD4(0.1, 0.6, 0.9, 1) }))
        XCTAssertTrue(input.isEmpty)
    }

    func testOverlayUsesTheExistingCroppedDecorationBand() {
        let plot = CGSize(width: 500, height: 400)
        let crop = ChartSurfaceBounds.decorations(rail: rail, plotSize: plot)
        XCTAssertEqual(crop, CGRect(x: 0, y: 109, width: 351, height: 166))
        XCTAssertLessThan(crop.width * crop.height, plot.width * plot.height)
        XCTAssertTrue(crop.contains(rail))
    }

    func testDetachedAndHiddenHostOwnNoResourcesOrDeadlineAndStopsPermanently() {
        let host = MetalLifecycleEffectsView(frame: CGRect(x: 0, y: 0, width: 300, height: 160))
        let elements: [MetalLifecycleEffectsSurface.Element] = [
            .effect(makeEffect(completion: true))
        ]
        host.update(elements: elements, drawingBounds: rail, scale: 2, at: origin)
        XCTAssertEqual(host.lifecyclePhase, .hidden)
        XCTAssertFalse(host.hasNativeResources)
        XCTAssertFalse(host.hasBoundaryTask)
        XCTAssertEqual(host.timeAnchor, origin)
        host.update(
            elements: elements, drawingBounds: rail, scale: 2, at: origin.addingTimeInterval(0.1))
        XCTAssertEqual(
            host.timeAnchor, origin, "Equal publications preserve the immutable time anchor")
        host.isHidden = true
        XCTAssertFalse(host.hasNativeResources)
        XCTAssertFalse(host.hasBoundaryTask)
        host.stop()
        host.update(elements: [], drawingBounds: rail, scale: 1, at: origin.addingTimeInterval(1))
        XCTAssertEqual(host.lifecyclePhase, .stopped)
        XCTAssertFalse(host.hasNativeResources)
        XCTAssertFalse(host.hasBoundaryTask)
    }

    func testFinalClearNeverAcknowledgesANewerEffectAndHideCancelsIt() throws {
        var lifecycle = MetalArrivalSurfaceLifecycle()
        lifecycle.update(visible: true, activeArrival: true)
        lifecycle.submittedArrival()
        lifecycle.update(visible: true, activeArrival: false)
        let clear = try XCTUnwrap(lifecycle.beginClear())
        let generation = lifecycle.generation
        lifecycle.update(visible: true, activeArrival: true)
        lifecycle.submittedArrival()
        lifecycle.completedClear(clear, generation: generation, success: true)
        lifecycle.update(visible: true, activeArrival: false)
        XCTAssertTrue(lifecycle.needsClear)
        lifecycle.update(visible: false, activeArrival: true)
        XCTAssertEqual(lifecycle.phase, .hidden)
        XCTAssertFalse(lifecycle.needsClear)
        lifecycle.completedClear(clear, generation: generation, success: true)
        XCTAssertEqual(lifecycle.phase, .hidden)
    }

    func testHostLifetimeWaitsForLastGPUCompletionAndCancelsRetryOnClose() {
        let destroyed = LockedCount()
        let retries = LockedCount()
        let lifetime = MetalLifecycleFrameLifetime(id: nil, onDestroyed: { destroyed.increment() })
        XCTAssertTrue(lifetime.begin())
        XCTAssertTrue(lifetime.begin())
        XCTAssertFalse(lifetime.begin())
        lifetime.retryWhenDrained { retries.increment() }
        lifetime.close()
        XCTAssertEqual(destroyed.value, 0)
        lifetime.finish()
        XCTAssertEqual(destroyed.value, 0)
        lifetime.finish()
        XCTAssertEqual(destroyed.value, 1)
        XCTAssertEqual(retries.value, 0)
        XCTAssertFalse(lifetime.begin())
        lifetime.close()
        lifetime.finish()
        XCTAssertEqual(destroyed.value, 1)
    }

    func testInvalidInputFallsBackOnceAndFailureStaysSticky() async {
        let host = MetalLifecycleEffectsView(frame: .zero)
        var fallbackCount = 0
        let fellBack = expectation(description: "Deferred sticky Canvas fallback")
        fellBack.assertForOverFulfill = true
        host.update(
            elements: [], drawingBounds: rail, scale: 1, isValid: false,
            onFailure: {
                fallbackCount += 1
                fellBack.fulfill()
            })
        host.update(
            elements: [], drawingBounds: rail, scale: 1, isValid: false,
            onFailure: {
                fallbackCount += 1
                fellBack.fulfill()
            })
        await fulfillment(of: [fellBack], timeout: 1)
        XCTAssertEqual(fallbackCount, 1)
        XCTAssertFalse(host.hasNativeResources)
        XCTAssertFalse(host.hasBoundaryTask)
        host.stop()
    }

    private func makeEffect(completion: Bool, at date: Date? = nil)
        -> MetalLifecycleEffectsSurface.Effect
    {
        let event = RequestRailEvent(
            requestID: UUID(), kind: completion ? .completion : .arrival,
            startedAt: date ?? origin, seed: 17)
        return .init(
            id: .init(event), startDate: event.startedAt, expiresAt: event.expiresAt,
            profile: RequestRailEffectProfile(
                seed: event.seed, requestDuration: 15, completion: completion),
            rect: CGRect(x: 40, y: 150, width: 100, height: 7), cornerRadius: 3.5,
            color: SIMD4(0.1, 0.6, 0.9, 1))
    }

    private func makeTwinkle(requestID: UUID = UUID()) -> MetalLifecycleEffectsSurface.Twinkle {
        .init(
            twinkle: .init(
                requestID: requestID, startedAt: origin, duration: 0.5,
                location: origin.addingTimeInterval(-46), size: 3, angle: 0.4, star: true),
            placement: .init(
                center: CGPoint(x: 80, y: 153.5),
                bar: CGRect(x: 40, y: 150, width: 100, height: 7), cornerRadius: 3.5),
            color: SIMD4(0.1, 0.6, 0.9, 1))
    }

    private func segment(_ lane: RequestLane, track: Int = 0) -> RequestRailGeometry.Segment {
        .init(
            lane: lane, rect: CGRect(x: 40, y: 150 + CGFloat(track) * 14, width: 100, height: 7),
            isLive: lane.endedAt == nil, track: track)
    }

    private func prepared(_ id: UUID, completion: Bool) -> RequestRailLifecycleEffects.Prepared {
        let event = RequestRailEvent(
            requestID: id, kind: completion ? .completion : .arrival,
            startedAt: origin, seed: 17)
        return .init(
            key: .init(event), startedAt: origin, expiresAt: event.expiresAt,
            profile: RequestRailEffectProfile(
                seed: event.seed, requestDuration: 15, completion: completion))
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
