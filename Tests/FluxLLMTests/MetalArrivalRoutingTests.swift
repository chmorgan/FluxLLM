import Foundation
import XCTest

@testable import FluxLLM

final class MetalArrivalRoutingTests: XCTestCase {
    func testOnlyEligibleArrivalEpisodesSelectMetal() {
        let arrival = effect(completion: false)
        XCTAssertTrue(route([arrival], eligible: [arrival.key.eventID]))
        XCTAssertFalse(route([arrival], eligible: []))
        XCTAssertFalse(route([], eligible: [arrival.key.eventID]))
        XCTAssertFalse(route([arrival], eligible: [arrival.key.eventID], enabled: false))
        XCTAssertFalse(route([arrival], eligible: [arrival.key.eventID], draws: false))
    }

    func testAnyVisibleCompletionKeepsWholeEpisodeOnCanvas() {
        let arrival = effect(completion: false)
        let completion = effect(completion: true)
        XCTAssertFalse(route([completion], eligible: [completion.key.eventID]))
        XCTAssertFalse(
            route([arrival, completion], eligible: [arrival.key.eventID, completion.key.eventID]))
        XCTAssertFalse(
            route([completion, arrival], eligible: [arrival.key.eventID, completion.key.eventID]))
        XCTAssertTrue(
            route([arrival, completion], eligible: [arrival.key.eventID]),
            "An offscreen completion must not disable an otherwise eligible arrival")
    }

    private func route(
        _ effects: [RequestRailLifecycleEffects.Prepared], eligible: [RequestRailEvent.ID],
        enabled: Bool = true, draws: Bool = true
    ) -> Bool {
        RequestRailLifecycleEffects.usesMetalArrival(
            enabled: enabled, drawsLifecycle: draws, prepared: effects, eligibleIDs: eligible)
    }

    private func effect(completion: Bool) -> RequestRailLifecycleEffects.Prepared {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = RequestRailEvent(
            requestID: UUID(), kind: completion ? .completion : .arrival,
            startedAt: start, seed: 42)
        return .init(
            key: .init(event), startedAt: start, expiresAt: event.expiresAt,
            profile: .init(seed: event.seed, requestDuration: 1, completion: completion))
    }
}
