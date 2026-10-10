import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class UnslothObservationStoreTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1000)
    private let sourceEpoch = UUID()

    func testNativeRequestProgressNeverOverridesAggregateRateActivityOrUsage() throws {
        let (store, epoch) = session()
        store.proxyState = .listening
        apply(
            store, epoch: epoch, at: 0,
            requests: snapshot([
                NativeRequestObservation(id: "one", outputTokens: 100, liveTPS: 1000),
                NativeRequestObservation(id: "two", outputTokens: 200, liveTPS: 2000),
            ]), running: 2)
        store.sample(at: date(0))
        let ids = Set(store.requestLanes.map(\.id))
        apply(
            store, epoch: epoch, at: 1,
            requests: snapshot([
                NativeRequestObservation(id: "one", outputTokens: 150, liveTPS: 1100),
                NativeRequestObservation(id: "two", outputTokens: 250, liveTPS: 2100),
            ]), running: 2)
        store.sample(at: date(1))

        XCTAssertEqual(Set(store.requestLanes.map(\.id)), ids)
        XCTAssertEqual(store.chartPresentation.requestLanes.count, 2)
        XCTAssertEqual(store.currentTPS, 88)
        XCTAssertEqual(store.displayTPS, 88)
        XCTAssertEqual(store.throughputBasis, .serverAggregate)
        XCTAssertEqual(store.currentModel, "engine-model")
        XCTAssertEqual(store.runningRequests, 2)
        XCTAssertEqual(store.backendActivity, .native(running: 2, queued: 0))
        XCTAssertEqual(store.backendOutputTokens, 5000)
        XCTAssertEqual(store.backendPromptTokens, 3000)
        XCTAssertNil(store.activeGeneration)
        XCTAssertEqual(store.outputTokens, 0)
        XCTAssertNil(store.promptTokens)
        XCTAssertEqual(
            store.usageSummary(in: DateInterval(start: origin, duration: 10)).requests, 0)
        XCTAssertTrue(store.tpsHistory.allSatisfy { $0.value == 88 && $0.isAvailable })
        XCTAssertFalse(store.chartPresentation.supportsToolActivity)
        XCTAssertTrue(store.toolActivityEvents.isEmpty)
        XCTAssertTrue(store.toolObservationHistory.isEmpty)
    }

    func testFreshNativeRequestsProveActivityWhenAggregateCountsAreZeroOrMissing() {
        let cases: [(Int?, Int?)] = [(0, 0), (nil, nil), (0, nil), (nil, 0)]
        for (running, queued) in cases {
            let (store, epoch) = session()
            apply(
                store, epoch: epoch, at: 0,
                requests: snapshot(
                    [
                        NativeRequestObservation(id: "one", outputTokens: 100, liveTPS: 1000),
                        NativeRequestObservation(id: "two", outputTokens: 200, liveTPS: 2000),
                    ], source: .studioMonitor, complete: false), running: running, queued: queued)
            store.sample(at: date(0))

            XCTAssertEqual(store.backendActivity, .observedNativeRequests(count: 2))
            XCTAssertEqual(BackendPresentation.statusTitle(store: store), "Active")
            XCTAssertEqual(
                BackendPresentation.activityDetail(store: store), "2 observed requests in progress")
            XCTAssertEqual(store.liveScalars.statusTitle, "Active")
            XCTAssertEqual(store.runningRequests, running)
            XCTAssertEqual(store.queuedRequests, queued)
            XCTAssertEqual(store.currentTPS, 88)
            XCTAssertEqual(store.displayTPS, 88)
            XCTAssertEqual(store.backendOutputTokens, 5000)
            XCTAssertNil(store.activityRequestStartedAt)
            XCTAssertNil(store.activeGeneration)
            XCTAssertEqual(
                store.usageSummary(in: DateInterval(start: origin, duration: 10)).requests, 0)
            // A complete snapshot clears observational evidence without inventing
            // missing aggregate counts or ruling out an unknown queue.
            apply(
                store, epoch: epoch, at: 1,
                requests: snapshot([], source: .studioMonitor), running: running, queued: queued)
            XCTAssertEqual(store.backendActivity, .native(running: running, queued: queued))
        }
    }

    func testMissingAndPartialSnapshotsKeepActivityOnlyUntilItsOwnFreshnessExpires() {
        let cases: [(NativeRequestSnapshot?, Bool)] = [
            (nil, true),
            (snapshot([], complete: false), true),
            (snapshot([]), false),
        ]
        for (nextSnapshot, remainsActive) in cases {
            let (store, epoch) = session()
            apply(
                store, epoch: epoch, at: 0,
                requests: snapshot([NativeRequestObservation(id: "one")]), running: 0)
            apply(store, epoch: epoch, at: 2, requests: nextSnapshot, running: 0)
            XCTAssertEqual(store.isBackendActive, remainsActive)
            for time in [4.0, 5.0] {
                apply(store, epoch: epoch, at: time, requests: nil, running: 0)
                store.sample(at: date(time))
                XCTAssertEqual(store.isBackendActive, remainsActive)
            }
            // Fresh zero counts do not extend the request's original observation.
            store.sample(at: date(5.5))
            XCTAssertEqual(store.connectionState, .ready)
            XCTAssertEqual(store.backendActivity, .idle)
            XCTAssertEqual(store.liveScalars.statusTitle, "Idle")
            XCTAssertTrue(store.requestLanes.allSatisfy(\.terminal))
        }
    }

    func testTerminalMonitorHistoryAndReplayCannotKeepActivityAlive() {
        for status in [ObservedRequestStatus.completed, .cancelled, .failed] {
            let (store, epoch) = session()
            apply(
                store, epoch: epoch, at: 0,
                requests: snapshot(
                    [NativeRequestObservation(id: "one")], source: .studioMonitor,
                    complete: false), running: 0)
            apply(
                store, epoch: epoch, at: 1,
                requests: snapshot(
                    [NativeRequestObservation(id: "one", liveTPS: 1000, status: status)],
                    source: .studioMonitor, complete: false), running: 0)
            XCTAssertEqual(store.backendActivity, .idle)
            apply(
                store, epoch: epoch, at: 2,
                requests: snapshot(
                    [NativeRequestObservation(id: "one", outputTokens: 300, liveTPS: 2000)],
                    source: .studioMonitor, complete: false), running: 0)
            XCTAssertEqual(store.backendActivity, .idle)
            XCTAssertEqual(store.requestLanes.first?.endStatus, status)
            XCTAssertEqual(store.liveScalars.statusTitle, "Idle")
        }
    }

    func testRetiredObservationSourceAndPreviousSessionCannotReactivateRequests() {
        let (store, epoch) = session()
        apply(
            store, epoch: epoch, at: 0,
            requests: snapshot([NativeRequestObservation(id: "one")]), running: 0)
        XCTAssertEqual(store.backendActivity, .observedNativeRequests(count: 1))
        let replacementEpoch = UUID()
        apply(
            store, epoch: epoch, at: 1, requests: snapshot([], epoch: replacementEpoch), running: 0)
        apply(
            store, epoch: epoch, at: 2,
            requests: snapshot([NativeRequestObservation(id: "late")]), running: 0)
        XCTAssertEqual(store.backendActivity, .idle)
        XCTAssertTrue(store.requestLanes.isEmpty)

        store.beginBackendSession(kind: .unsloth, epoch: UUID())
        apply(
            store, epoch: epoch, at: 3,
            requests: snapshot([NativeRequestObservation(id: "late")]), running: 0)
        XCTAssertEqual(store.backendActivity, .unknown)
        XCTAssertEqual(store.liveScalars.statusTitle, "Connecting")
    }

    func testIdentityExpiresDespiteHealthyAggregatePollsAndKeepsThroughputAvailable() throws {
        let (store, epoch) = session()
        apply(
            store, epoch: epoch, at: 0,
            requests: snapshot([NativeRequestObservation(id: "one", outputTokens: 100)]))
        store.sample(at: date(0))
        let id = try XCTUnwrap(store.requestLanes.first?.id)
        for offset in 1...6 {
            apply(store, epoch: epoch, at: Double(offset), requests: nil)
            store.sample(at: date(Double(offset)))
        }
        let lane = try XCTUnwrap(store.requestLanes.first)
        XCTAssertEqual(lane.id, id)
        XCTAssertEqual(lane.endStatus, .observationEnded)
        XCTAssertEqual(lane.endedAt, date(5))
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertTrue(store.isBackendActive)
        XCTAssertEqual(store.currentTPS, 88)
        XCTAssertTrue(store.rateIsAvailable)
        XCTAssertNil(store.activeGeneration)
    }

    func testEmptyCompleteSnapshotEndsObservationWithoutInventingAuthoritativeUsage() throws {
        let (store, epoch) = session()
        apply(
            store, epoch: epoch, at: 0,
            requests: snapshot([NativeRequestObservation(id: "one", outputTokens: 100)]))
        store.sample(at: date(0))
        apply(store, epoch: epoch, at: 1, requests: nil)
        XCTAssertFalse(try XCTUnwrap(store.requestLanes.first).terminal)
        apply(store, epoch: epoch, at: 2, requests: snapshot([]), rate: 0, running: 0)
        store.sample(at: date(2))
        let lane = try XCTUnwrap(store.requestLanes.first)
        XCTAssertEqual(lane.endStatus, .observationEnded)
        XCTAssertEqual(lane.endedAt, date(2))
        XCTAssertFalse(store.isBackendActive)
        XCTAssertEqual(store.displayTPS, 0)
        XCTAssertNil(store.activeGeneration)
        XCTAssertEqual(
            store.usageSummary(in: DateInterval(start: origin, duration: 10)).requests, 0)
        XCTAssertTrue(store.chartPresentation.historicalRequestLanes.isEmpty)
    }

    func testFaultDoesNotFabricateCompletionOrKeepIdentityFresh() throws {
        let (store, epoch) = session()
        apply(
            store, epoch: epoch, at: 0,
            requests: snapshot([NativeRequestObservation(id: "one")]))
        store.sample(at: date(0))
        store.applyBackendSample(
            BackendSample(kind: .unsloth, timestamp: date(1), isReady: false), epoch: epoch)
        store.sample(at: date(1))
        XCTAssertFalse(try XCTUnwrap(store.requestLanes.first).terminal)
        XCTAssertNil(store.displayTPS)
        store.sample(at: date(6))
        XCTAssertEqual(store.requestLanes.first?.endStatus, .observationEnded)
        XCTAssertFalse(store.rateIsAvailable)
        XCTAssertNil(store.activeGeneration)
    }

    func testSessionAndWorkerRolloverRejectLateIdentitySamples() throws {
        let (store, epoch) = session()
        apply(
            store, epoch: epoch, at: 0,
            requests: snapshot([NativeRequestObservation(id: "one")]))
        store.sample(at: date(0))
        let firstID = try XCTUnwrap(store.requestLanes.first?.id)
        let workerEpoch = UUID()
        apply(
            store, epoch: epoch, at: 1,
            requests: snapshot([NativeRequestObservation(id: "one")], epoch: workerEpoch))
        let workerID = try XCTUnwrap(store.requestLanes.first?.id)
        XCTAssertNotEqual(workerID, firstID)
        apply(
            store, epoch: epoch, at: 2,
            requests: snapshot([NativeRequestObservation(id: "late")]))
        XCTAssertEqual(store.requestLanes.map(\.id), [workerID])

        let sessionEpoch = UUID()
        store.beginBackendSession(kind: .unsloth, epoch: sessionEpoch)
        XCTAssertTrue(store.requestLanes.isEmpty)
        apply(
            store, epoch: epoch, at: 3,
            requests: snapshot([NativeRequestObservation(id: "late")]))
        XCTAssertTrue(store.requestLanes.isEmpty)
        apply(
            store, epoch: sessionEpoch, at: 4,
            requests: snapshot([NativeRequestObservation(id: "one")]))
        XCTAssertEqual(store.requestLanes.count, 1)
        XCTAssertNotEqual(store.requestLanes.first?.id, workerID)
    }

    func testProviderFallbackRecoveryDoesNotShowDuplicateNativeBars() throws {
        let (store, epoch) = session()
        let monitorEpoch = UUID()
        apply(
            store, epoch: epoch, at: 0,
            requests: snapshot(
                [NativeRequestObservation(id: "monitor-one")], source: .studioMonitor,
                epoch: monitorEpoch))
        store.sample(at: date(0))
        apply(
            store, epoch: epoch, at: 1,
            requests: snapshot([NativeRequestObservation(id: "slot-one")]))
        store.sample(at: date(1))
        XCTAssertEqual(store.chartPresentation.requestLanes.count, 1)
        XCTAssertEqual(store.chartPresentation.requestLanes.first?.observationSource, .slotPolling)
        apply(
            store, epoch: epoch, at: 2,
            requests: snapshot(
                [NativeRequestObservation(id: "monitor-one")], source: .studioMonitor,
                epoch: monitorEpoch))
        store.sample(at: date(2))
        XCTAssertEqual(store.chartPresentation.requestLanes.count, 1)
        XCTAssertEqual(
            store.chartPresentation.requestLanes.first?.observationSource, .studioMonitor)
    }

    func testNativeInspectionAndChartPreparationKeepSampledProvenanceAndNoToolTrack() throws {
        let (store, epoch) = session()
        apply(
            store, epoch: epoch, at: 1,
            requests: snapshot([
                NativeRequestObservation(id: "one", model: "provider/model", outputTokens: 1000)
            ]))
        store.sample(at: date(1))
        apply(
            store, epoch: epoch, at: 2,
            requests: snapshot([
                NativeRequestObservation(id: "one", model: "provider/model", outputTokens: 1050)
            ]))
        store.sample(at: date(2))
        let prepared = DashboardChartPreparation(clock: { self.date(2) }).histories(
            snapshot: store.chartPresentation, duration: 60, epoch: epoch)
        let lane = try XCTUnwrap(prepared.lanes.first)
        let inspection = ChartInspectionContent.request(lane, at: store.chartPresentation.timestamp)
        let metrics = try XCTUnwrap(inspection.requestMetrics)
        XCTAssertEqual(prepared.lanes.count, 1)
        XCTAssertEqual(inspection.title, "model")
        XCTAssertEqual(inspection.badge, "In progress")
        XCTAssertEqual(metrics.duration, "1.0 s")
        XCTAssertEqual(metrics.outputTokens, "\(1050.formatted()) tok")
        XCTAssertEqual(
            metrics.averageRate, "~50.0 tok/s", "Only the observed 50-token delta is averaged")
        XCTAssertEqual(inspection.rows.first { $0.label == "Source" }?.value, "Slot samples")
        XCTAssertEqual(
            inspection.rows.first { $0.label == "Coverage" }?.value, "Sampled times and average")
        XCTAssertNil(prepared.toolActivity)
        XCTAssertTrue(prepared.requestTools.isEmpty)

        apply(store, epoch: epoch, at: 3, requests: snapshot([]), rate: 0, running: 0)
        store.sample(at: date(3))
        let endedPrepared = DashboardChartPreparation(clock: { self.date(3) }).histories(
            snapshot: store.chartPresentation, duration: 60, epoch: epoch)
        let endedLane = try XCTUnwrap(endedPrepared.lanes.first)
        let endedInspection = ChartInspectionContent.request(endedLane, at: date(30))
        XCTAssertEqual(endedLane.id, lane.id)
        XCTAssertEqual(endedInspection.badge, "Observation ended")
        XCTAssertEqual(endedInspection.requestMetrics?.averageRate, "~50.0 tok/s")
        XCTAssertEqual(endedInspection.requestMetrics?.outputTokens, "\(1050.formatted()) tok")
    }

    func testExplicitMonitorCompletionKeepsReportedTimingAndUnknownAverage() throws {
        let (store, epoch) = session()
        apply(
            store, epoch: epoch, at: 12,
            requests: snapshot(
                [
                    NativeRequestObservation(
                        id: "one", startedAt: date(1), endedAt: date(11), outputTokens: 300,
                        status: .completed)
                ], source: .studioMonitor))
        store.sample(at: date(12))
        let lane = try XCTUnwrap(store.requestLanes.first)
        let inspection = ChartInspectionContent.request(lane, at: date(12))
        XCTAssertEqual(lane.startedAt, date(1))
        XCTAssertEqual(lane.endedAt, date(11))
        XCTAssertEqual(inspection.badge, "Completed")
        XCTAssertEqual(inspection.requestMetrics?.duration, "10.0 s")
        XCTAssertEqual(inspection.requestMetrics?.averageRate, "—")
        XCTAssertEqual(inspection.rows.first { $0.label == "Source" }?.value, "Studio monitor")
        XCTAssertEqual(
            inspection.rows.first { $0.label == "Coverage" }?.value, "Reported times; sampled avg")
        XCTAssertEqual(
            store.usageSummary(in: DateInterval(start: origin, duration: 20)).requests, 0)
    }

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    private func session() -> (MetricsStore, UUID) {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .unsloth, epoch: epoch)
        return (store, epoch)
    }

    private func snapshot(
        _ requests: [NativeRequestObservation], source: RequestObservationSource = .slotPolling,
        epoch: UUID? = nil, complete: Bool = true
    ) -> NativeRequestSnapshot {
        NativeRequestSnapshot(
            sourceEpoch: epoch ?? sourceEpoch, source: source, requests: requests,
            isComplete: complete)
    }

    private func apply(
        _ store: MetricsStore, epoch: UUID, at offset: TimeInterval,
        requests: NativeRequestSnapshot?, rate: Double = 88, running: Int? = 1, queued: Int? = 0
    ) {
        store.applyBackendSample(
            BackendSample(
                kind: .unsloth, timestamp: date(offset), model: "engine-model", currentTPS: rate,
                measurementDuration: 1, nativeRequests: requests,
                runningRequests: running, queuedRequests: queued,
                outputTokens: 5000, promptTokens: 3000),
            epoch: epoch)
    }
}
