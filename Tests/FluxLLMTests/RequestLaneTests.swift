import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class RequestLaneTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    // MARK: - Lane visibility

    func testRunningLaneIsAlwaysVisibleAndFinishedLaneExpiresPastWindow() {
        let running = RequestLane(id: UUID(), startedAt: origin, endedAt: nil)
        // A running lane has no end time, so it stays visible no matter how far
        // the window's lower cutoff advances.
        XCTAssertTrue(running.isVisible(at: date(10_000)))

        let finished = RequestLane(id: UUID(), startedAt: origin, endedAt: date(1))
        // Visible while its end time is at or after the cutoff.
        XCTAssertTrue(finished.isVisible(at: origin))
        // Gone once its end time scrolls past the cutoff.
        XCTAssertFalse(finished.isVisible(at: date(1).addingTimeInterval(1)))
    }

    // MARK: - Categorical palette

    func testLanePaletteColorsAreStableAndDistinctPerStartOrder() {
        // Same start order always yields the same color, so a request keeps a
        // stable hue for its lane and its tool markers.
        XCTAssertEqual(
            RequestLanePalette.color(at: 3, scheme: .dark),
            RequestLanePalette.color(at: 3, scheme: .dark))

        // The approved palette gives consecutive requests distinct hues.
        XCTAssertNotEqual(
            RequestLanePalette.color(at: 0, scheme: .dark),
            RequestLanePalette.color(at: 1, scheme: .dark))
        XCTAssertNotEqual(
            RequestLanePalette.color(at: 1, scheme: .dark),
            RequestLanePalette.color(at: 2, scheme: .dark))

        // Each appearance uses the preview's corresponding color variant.
        XCTAssertNotEqual(
            RequestLanePalette.color(at: 0, scheme: .dark),
            RequestLanePalette.color(at: 0, scheme: .light))
    }

    // MARK: - Store request lanes

    func testRequestModelIsAvailableBeforeResponseAndSurvivesCancellationOrFailure() throws {
        for failed in [false, true] {
            let store = MetricsStore(clock: { self.date(2) })
            let request = GenerationRequest(model: "provider/request-model", startedAt: origin)
            store.apply(.began(request))

            let open = try XCTUnwrap(store.requestLanes.first)
            XCTAssertEqual(open.model, request.model)
            XCTAssertEqual(open.outputTokens, 0)
            XCTAssertTrue(open.outputIsEstimated)
            XCTAssertEqual(
                ChartInspectionContent.request(open, at: date(1)).title, "request-model")

            store.apply(
                failed
                    ? .failed(requestID: request.id, message: "Disconnected")
                    : .cancelled(requestID: request.id))

            let ended = try XCTUnwrap(store.requestLanes.first)
            XCTAssertTrue(ended.terminal)
            XCTAssertEqual(ended.model, request.model)
            XCTAssertEqual(
                ChartInspectionContent.request(ended, at: date(2)).title, "request-model")
        }
    }

    func testResponseModelOverridesRequestAliasAndSurvivesMissingModelUpdates() throws {
        let store = MetricsStore(clock: { self.date(3) })
        let request = GenerationRequest(model: "alias", startedAt: origin)
        store.apply(.began(request))
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(model: "provider/resolved", timestamp: date(1))))
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(outputTokens: 12, liveTPS: 6, timestamp: date(2))))

        let open = try XCTUnwrap(store.requestLanes.first)
        XCTAssertEqual(open.model, "provider/resolved")
        XCTAssertEqual(ChartInspectionContent.request(open, at: date(2)).title, "resolved")

        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(finished: true, timestamp: date(3))))

        let ended = try XCTUnwrap(store.requestLanes.first)
        XCTAssertTrue(ended.terminal)
        XCTAssertEqual(ended.model, "provider/resolved")
        XCTAssertEqual(ChartInspectionContent.request(ended, at: date(3)).title, "resolved")
    }

    func testTerminalSnapshotRetainsFinalUsageAndModelWithoutReplacingLiveRate() throws {
        for failed in [false, true] {
            for hasLiveSnapshot in [false, true] {
                let store = MetricsStore(clock: { self.date(2) })
                let request = GenerationRequest(startedAt: origin)
                store.apply(.began(request))
                if hasLiveSnapshot {
                    store.apply(
                        .updated(
                            requestID: request.id,
                            snapshot: GenerationSnapshot(
                                outputTokens: 12, liveTPS: 6, timestamp: date(1))))
                }
                store.apply(
                    .updated(
                        requestID: request.id,
                        snapshot: GenerationSnapshot(
                            model: "provider/final-model", outputTokens: 8,
                            isEstimated: false, liveTPS: 10,
                            finished: !failed, error: failed ? "Backend error" : nil,
                            timestamp: date(2))))

                let lane = try XCTUnwrap(store.requestLanes.first)
                XCTAssertTrue(lane.terminal)
                XCTAssertEqual(lane.endedAt, date(2))
                XCTAssertEqual(lane.model, "provider/final-model")
                XCTAssertEqual(lane.outputTokens, 8)
                XCTAssertFalse(lane.outputIsEstimated)
                XCTAssertEqual(lane.liveTPS, hasLiveSnapshot ? 6 : 0)
                XCTAssertEqual(
                    ChartInspectionContent.request(lane, at: date(2)).title, "final-model")
                XCTAssertEqual(store.outputTokens, 8)
                XCTAssertEqual(store.currentTPS, 0)
            }
        }
    }

    func testFailureAndCancellationRetainLatestCountAndEstimate() throws {
        for failed in [false, true] {
            for isEstimated in [false, true] {
                let store = MetricsStore(clock: { self.date(3) })
                let request = GenerationRequest(startedAt: origin)
                store.apply(.began(request))
                store.apply(
                    .updated(
                        requestID: request.id,
                        snapshot: GenerationSnapshot(
                            outputTokens: 29, isEstimated: isEstimated, liveTPS: 7,
                            timestamp: date(2))))

                let open = try XCTUnwrap(store.requestLanes.first)
                XCTAssertEqual(open.outputTokens, 29)
                XCTAssertEqual(open.outputIsEstimated, isEstimated)

                store.apply(
                    failed
                        ? .failed(requestID: request.id, message: "Disconnected")
                        : .cancelled(requestID: request.id))

                let ended = try XCTUnwrap(store.requestLanes.first)
                XCTAssertTrue(ended.terminal)
                XCTAssertEqual(ended.endedAt, date(3))
                XCTAssertEqual(ended.outputTokens, 29)
                XCTAssertEqual(ended.outputIsEstimated, isEstimated)
                XCTAssertEqual(ended.liveTPS, 7)
                XCTAssertEqual(store.currentTPS, 0)
            }
        }
    }

    func testOlderTerminalUpdatesOnlyItsLaneAndPreservesNewestDashboard() throws {
        let store = MetricsStore(clock: { self.date(3) })
        let older = GenerationRequest(model: "older-alias", startedAt: origin)
        let newer = GenerationRequest(model: "newer-model", startedAt: date(1))
        store.apply(.began(older))
        store.apply(
            .updated(
                requestID: older.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 100, liveTPS: 6, timestamp: date(0.5))))
        store.apply(.began(newer))
        store.apply(
            .updated(
                requestID: newer.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 17, liveTPS: 5, timestamp: date(1.5))))
        store.apply(
            .updated(
                requestID: older.id,
                snapshot: GenerationSnapshot(
                    model: "provider/older-resolved", outputTokens: 90,
                    isEstimated: false, liveTPS: 1_000, finished: true,
                    timestamp: date(2))))

        let olderLane = try XCTUnwrap(store.requestLanes.first { $0.id == older.id })
        let newerLane = try XCTUnwrap(store.requestLanes.first { $0.id == newer.id })
        XCTAssertTrue(olderLane.terminal)
        XCTAssertEqual(olderLane.model, "provider/older-resolved")
        XCTAssertEqual(olderLane.outputTokens, 90)
        XCTAssertFalse(olderLane.outputIsEstimated)
        XCTAssertEqual(olderLane.liveTPS, 6)
        XCTAssertEqual(
            ChartInspectionContent.request(olderLane, at: date(2)).title, "older-resolved")
        XCTAssertFalse(newerLane.terminal)
        XCTAssertEqual(newerLane.model, "newer-model")
        XCTAssertEqual(newerLane.outputTokens, 17)
        XCTAssertTrue(newerLane.outputIsEstimated)
        XCTAssertEqual(store.currentModel, "newer-model")
        XCTAssertEqual(store.outputTokens, 17)
        XCTAssertTrue(store.outputIsEstimated)
        XCTAssertEqual(store.currentTPS, 5)
        XCTAssertEqual(store.activeGeneration?.id, newer.id)
        XCTAssertEqual(store.activeGeneration?.state, .running)
    }

    func testRequestLanesListOpenRequestsOldestFirstThenTerminal() {
        let store = MetricsStore(clock: { self.origin })
        let older = GenerationRequest(model: "alpha", startedAt: origin)
        let current = GenerationRequest(model: "beta", startedAt: date(1))
        store.apply(.began(older))
        store.apply(.began(current))

        let open = store.requestLanes
        // Both requests are their own lane, oldest start first.
        XCTAssertEqual(open.map(\.id), [older.id, current.id])
        XCTAssertTrue(open.allSatisfy { !$0.terminal })
        XCTAssertTrue(open.allSatisfy { $0.endedAt == nil })

        // Finishing one request turns its lane terminal without removing the
        // sibling that is still running.
        store.apply(
            .updated(
                requestID: current.id,
                snapshot: GenerationSnapshot(finished: true, timestamp: date(2))))

        let lanes = store.requestLanes
        XCTAssertEqual(lanes.map(\.id), [older.id, current.id])
        let currentLane = lanes.first { $0.id == current.id }
        XCTAssertEqual(currentLane?.terminal, true)
        XCTAssertEqual(currentLane?.endedAt, date(2))
        let olderLane = lanes.first { $0.id == older.id }
        XCTAssertEqual(olderLane?.terminal, false)
        XCTAssertNil(olderLane?.endedAt)
    }

    // MARK: - Prepared chart grouping

    func testPreparedChartsGroupToolActivityPerRequest() {
        let a = UUID()
        let b = UUID()
        let laneA = RequestLane(id: a, startedAt: origin, model: "alpha")
        let laneB = RequestLane(id: b, startedAt: date(1), model: "beta")
        let eventA = ToolActivityEvent(
            kind: .call, name: "read_file", timestamp: date(0.5), requestID: a)
        let eventB = ToolActivityEvent(
            kind: .call, name: "search", timestamp: date(1.5), requestID: b)
        let orphan = ToolActivityEvent(kind: .call, name: "orphan", timestamp: date(2))

        let snapshot = ChartPresentationSnapshot(
            timestamp: date(3),
            toolActivity: [eventA, eventB, orphan],
            requestLanes: [laneA, laneB],
            supportsToolActivity: true)

        let prepared = PreparedDashboardCharts(snapshot: snapshot, duration: 300)

        // Lanes and their start-ordered color indices are preserved.
        XCTAssertEqual(prepared.lanes, [laneA, laneB])
        XCTAssertEqual(prepared.laneColorIndex[a], 0)
        XCTAssertEqual(prepared.laneColorIndex[b], 1)

        // Tool activity is split into one history per owning request; an event
        // with no request ID is not grouped into any lane.
        XCTAssertEqual(Set(prepared.requestTools.keys), [a, b])
    }
}
