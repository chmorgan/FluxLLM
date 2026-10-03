import AppKit
import XCTest

@testable import FluxLLM

@MainActor
final class MetalArrivalBurstSurfaceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnlyUnexpiredArrivalStartsFramesAndClockRemainsRelative() {
        let burst = arrival(at: origin)
        let element = MetalArrivalBurstSurface.Element.burst(burst)
        XCTAssertFalse(element.isActiveArrival(at: origin.addingTimeInterval(-0.001)))
        XCTAssertTrue(element.isActiveArrival(at: origin))
        XCTAssertTrue(
            element.isActiveArrival(
                at: origin.addingTimeInterval(burst.profile.burstDuration - 0.001)))
        XCTAssertFalse(
            element.isActiveArrival(at: origin.addingTimeInterval(burst.profile.burstDuration)))
        let twinkle = twinkle(at: origin)
        XCTAssertFalse(
            MetalArrivalBurstSurface.Element.twinkle(twinkle).isActiveArrival(at: origin))
        let completion = MetalArrivalBurstSurface.Burst(
            id: burst.id, startDate: origin,
            profile: RequestRailEffectProfile(seed: 17, requestDuration: 20, completion: true),
            origin: burst.origin, color: burst.color)
        XCTAssertFalse(
            MetalArrivalBurstSurface.Element.burst(completion).isActiveArrival(at: origin))

        let anchor = origin.addingTimeInterval(0.125)
        guard case .burst(let relative) = element.rendererElement(relativeTo: anchor) else {
            return XCTFail("Lost burst type")
        }
        XCTAssertEqual(relative.startTime, -0.125, accuracy: 0.000001)
        XCTAssertEqual(relative.profile, burst.profile)
        XCTAssertEqual(relative.origin, burst.origin)
        XCTAssertEqual(relative.color, burst.color)
    }

    func testClearWaitsForSubmittedContentAndCannotEraseANewerEpisode() throws {
        var state = MetalArrivalSurfaceLifecycle()
        state.update(visible: true, activeArrival: false)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.needsClear)
        state.update(visible: true, activeArrival: true)
        state.submittedArrival()
        state.update(visible: true, activeArrival: false)
        XCTAssertTrue(state.needsClear)
        let oldClear = try XCTUnwrap(state.beginClear())
        XCTAssertFalse(state.needsClear, "Only one clear may be pending on the command queue")
        XCTAssertNil(state.beginClear())

        state.update(visible: true, activeArrival: true)
        state.submittedArrival()
        state.update(visible: true, activeArrival: false)
        state.completedClear(oldClear, generation: state.generation, success: true)
        XCTAssertTrue(state.needsClear, "A newer submitted episode still needs its own final clear")
        let latestClear = try XCTUnwrap(state.beginClear())
        state.completedClear(latestClear, generation: state.generation, success: false)
        XCTAssertTrue(state.needsClear, "GPU failure cannot claim that pixels were cleared")
        let retry = try XCTUnwrap(state.beginClear())
        state.completedClear(retry, generation: state.generation, success: true)
        XCTAssertFalse(state.needsClear)
    }

    func testNewArrivalCancelsAnUnsubmittedClearAndHiddenCallbacksCannotRestart() throws {
        var state = MetalArrivalSurfaceLifecycle()
        state.update(visible: true, activeArrival: true)
        state.submittedArrival()
        state.update(visible: true, activeArrival: false)
        XCTAssertTrue(state.needsClear)
        state.update(visible: true, activeArrival: true)
        XCTAssertFalse(state.needsClear)
        state.update(visible: true, activeArrival: false)
        let clear = try XCTUnwrap(state.beginClear())
        let oldGeneration = state.generation
        state.update(visible: false, activeArrival: true)
        XCTAssertEqual(state.phase, .hidden)
        XCTAssertFalse(state.needsClear)
        state.update(visible: true, activeArrival: false)
        state.completedClear(clear, generation: oldGeneration, success: true)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.needsClear)
        XCTAssertNotEqual(state.generation, oldGeneration)
        state.stop()
        state.update(visible: true, activeArrival: true)
        state.submittedArrival()
        XCTAssertEqual(state.phase, .stopped)
        XCTAssertFalse(state.needsClear)
    }

    func testReservationsBoundFramesAndClearsWithoutWaitingOrDoubleRelease() throws {
        let limiter = MetalArrivalFrameLimiter()
        let first = try XCTUnwrap(limiter.begin())
        let second = try XCTUnwrap(limiter.begin())
        XCTAssertEqual(limiter.inFlight, 2)
        XCTAssertNil(limiter.begin())
        XCTAssertTrue(limiter.finish(first))
        XCTAssertFalse(limiter.finish(first))
        let clear = try XCTUnwrap(limiter.begin())
        XCTAssertEqual(limiter.inFlight, 2)
        XCTAssertTrue(limiter.finish(second))
        XCTAssertTrue(limiter.finish(clear))
        XCTAssertEqual(limiter.inFlight, 0)
    }

    func testDrawableBoundsRejectOverflowWithoutAllocatingTextures() {
        XCTAssertEqual(
            MetalArrivalSurfaceGeometry.drawableSize(
                points: CGSize(width: 100.25, height: 80.5), scale: 2),
            CGSize(width: 201, height: 161))
        for size in [
            CGSize.zero, CGSize(width: -1, height: 100),
            CGSize(width: CGFloat.infinity, height: 100), CGSize(width: 100, height: CGFloat.nan),
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: 10),
            CGSize(width: 4_096, height: 4_096),
        ] {
            XCTAssertNil(MetalArrivalSurfaceGeometry.drawableSize(points: size, scale: 2))
        }
        for scale in [CGFloat.zero, -1, .nan, .infinity] {
            XCTAssertNil(
                MetalArrivalSurfaceGeometry.drawableSize(
                    points: CGSize(width: 10, height: 10), scale: scale))
        }
        XCTAssertFalse(
            MetalArrivalSurfaceGeometry.valid(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)))
        XCTAssertFalse(
            MetalArrivalSurfaceGeometry.valid(CGRect(x: 0, y: 0, width: -10, height: 10)))
    }

    func testDetachedHostPreparesNoGPUResourcesAndRebasesAfterLongIdle() {
        let view = MetalArrivalBurstView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        let bounds = CGRect(x: 10, y: 20, width: 200, height: 80)
        let first: [MetalArrivalBurstSurface.Element] = [.burst(arrival(at: origin))]
        view.update(elements: first, drawingBounds: bounds, scale: 2, at: origin)
        XCTAssertFalse(view.hasNativeResources)
        XCTAssertEqual(view.lifecyclePhase, .hidden)
        XCTAssertEqual(view.timeAnchor, origin)
        view.update(
            elements: first, drawingBounds: bounds, scale: 2, at: origin.addingTimeInterval(0.1))
        XCTAssertEqual(
            view.timeAnchor, origin, "An equal source publication does not re-upload descriptors")

        let later = origin.addingTimeInterval(3 * 86_400)
        let source = arrival(at: later.addingTimeInterval(-0.03125))
        let next: [MetalArrivalBurstSurface.Element] = [
            .burst(source), .twinkle(twinkle(at: later)),
        ]
        view.update(elements: next, drawingBounds: bounds, scale: 2, at: later)
        XCTAssertEqual(view.timeAnchor, later)
        guard case .burst(let relative) = next[0].rendererElement(relativeTo: view.timeAnchor),
            case .twinkle(let glint) = next[1].rendererElement(relativeTo: view.timeAnchor)
        else { return XCTFail("Source ordering changed") }
        XCTAssertEqual(relative.startTime, -0.03125, accuracy: 0.000001)
        XCTAssertEqual(glint.startTime, 0, accuracy: 0.000001)
        XCTAssertFalse(view.hasNativeResources)
        view.stop()
        view.update(
            elements: first, drawingBounds: bounds, scale: 1, at: later.addingTimeInterval(1))
        XCTAssertEqual(view.lifecyclePhase, .stopped)
        XCTAssertFalse(view.hasNativeResources)
        XCTAssertEqual(view.timeAnchor, later)
    }

    private func arrival(at date: Date) -> MetalArrivalBurstSurface.Burst {
        let event = RequestRailEvent(requestID: UUID(), kind: .arrival, startedAt: date, seed: 17)
        return .init(
            id: .init(event), startDate: date,
            profile: RequestRailEffectProfile(
                seed: event.seed, requestDuration: 0, completion: false),
            origin: CGPoint(x: 40, y: 50), color: SIMD4(0.1, 0.6, 0.9, 1))
    }

    private func twinkle(at date: Date) -> MetalArrivalBurstSurface.Twinkle {
        .init(
            twinkle: RequestRailTwinkle(
                requestID: UUID(), startedAt: date, duration: 0.5,
                location: date, size: 3, angle: 0.4, star: true),
            placement: .init(
                center: CGPoint(x: 40, y: 50),
                bar: CGRect(x: 10, y: 46.5, width: 100, height: 7), cornerRadius: 3.5),
            color: SIMD4(0.1, 0.6, 0.9, 1))
    }
}
