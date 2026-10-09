import Foundation
import XCTest

@testable import FluxLLM

final class NativeRequestTrackerTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1000)
    private let epoch = UUID()

    func testStableIdentityKeepsFirstObservationWhileCountsProgress() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(snapshot([request("one", tokens: 120, rate: 40)]), at: date(1))
        let first = try XCTUnwrap(tracker.lanes(at: date(1)).first)
        XCTAssertNil(first.sampledAverageTPS)
        tracker.apply(snapshot([request("one", tokens: 160, rate: 42)]), at: date(2))
        let latest = try XCTUnwrap(tracker.lanes(at: date(2)).first)

        XCTAssertEqual(latest.id, first.id)
        XCTAssertEqual(latest.startedAt, date(1))
        XCTAssertEqual(latest.outputTokens, 160)
        XCTAssertFalse(latest.outputIsEstimated)
        XCTAssertEqual(latest.liveTPS, 42)
        XCTAssertEqual(try XCTUnwrap(latest.sampledAverageTPS), 40, accuracy: 0.0001)
        XCTAssertEqual(latest.observationSource, .slotPolling)
        XCTAssertNil(latest.endedAt)
        XCTAssertFalse(latest.terminal)
    }

    func testSampledAverageWeightsUnevenCounterIntervals() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(snapshot([request("one", tokens: 120)]), at: date(0))
        tracker.apply(snapshot([request("one", tokens: 160, rate: 40)]), at: date(1))
        tracker.apply(snapshot([request("one", tokens: 280, rate: 60)]), at: date(3))
        let lane = try XCTUnwrap(tracker.lanes(at: date(3)).first)

        XCTAssertEqual(try XCTUnwrap(lane.sampledAverageTPS), 160.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(lane.liveTPS, 60)
    }

    func testUnknownCountersAndMissedPollsDoNotExtendTheMeasuredWindow() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(snapshot([request("one", rate: 900)]), at: date(0))
        tracker.apply(snapshot([request("one", tokens: 120)]), at: date(1))
        XCTAssertNil(tracker.lanes(at: date(1)).first?.sampledAverageTPS)
        tracker.apply(snapshot([request("one", tokens: 160)]), at: date(2))
        tracker.apply(nil, at: date(3))
        tracker.apply(snapshot([request("one", tokens: -1)]), at: date(4))
        tracker.apply(snapshot([request("one")]), at: date(5))
        let unchanged = try XCTUnwrap(tracker.lanes(at: date(5)).first)

        XCTAssertEqual(unchanged.outputTokens, 160)
        XCTAssertEqual(try XCTUnwrap(unchanged.sampledAverageTPS), 40, accuracy: 0.0001)
        tracker.apply(snapshot([request("one", tokens: 220)]), at: date(6))
        let resumed = try XCTUnwrap(tracker.lanes(at: date(6)).first)
        XCTAssertEqual(resumed.id, unchanged.id)
        XCTAssertEqual(try XCTUnwrap(resumed.sampledAverageTPS), 20, accuracy: 0.0001)
    }

    func testIdleAndFreshnessExpiryFreezeAverageAtLastCounterObservation() throws {
        var idleTracker = NativeRequestTracker()
        var staleTracker = NativeRequestTracker()
        for (time, count) in [(0.0, 100), (1.0, 150)] {
            idleTracker.apply(snapshot([request("one", tokens: count)]), at: date(time))
            staleTracker.apply(snapshot([request("one", tokens: count)]), at: date(time))
        }
        idleTracker.apply(snapshot([]), at: date(3))
        staleTracker.advance(at: date(7))
        let idle = try XCTUnwrap(idleTracker.lanes(at: date(7)).first)
        let stale = try XCTUnwrap(staleTracker.lanes(at: date(7)).first)

        XCTAssertEqual(idle.endedAt, date(3))
        XCTAssertEqual(stale.endedAt, date(6))
        XCTAssertEqual(try XCTUnwrap(idle.sampledAverageTPS), 50, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(stale.sampledAverageTPS), 50, accuracy: 0.0001)
        staleTracker.apply(snapshot([request("one", tokens: 500)]), at: date(8))
        let restarted = try XCTUnwrap(staleTracker.lanes(at: date(8)).first { !$0.terminal })
        XCTAssertNotEqual(restarted.id, stale.id)
        XCTAssertNil(restarted.sampledAverageTPS)
    }

    func testZeroProgressIsMeasuredButZeroElapsedTimeIsUnavailable() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(snapshot([request("one", tokens: 100)]), at: date(1))
        tracker.apply(snapshot([request("one", tokens: 100)]), at: date(1))
        XCTAssertNil(tracker.lanes(at: date(1)).first?.sampledAverageTPS)
        tracker.apply(snapshot([request("one", tokens: 100)]), at: date(2))
        let lane = try XCTUnwrap(tracker.lanes(at: date(2)).first)
        XCTAssertEqual(try XCTUnwrap(lane.sampledAverageTPS), 0, accuracy: 0.0001)
    }

    func testReplacedTaskDoesNotReusePreviousCounterBaseline() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(snapshot([request("slot:one", tokens: 80)]), at: date(0))
        tracker.apply(snapshot([request("slot:one", tokens: 100)]), at: date(1))
        tracker.apply(snapshot([request("slot:two", tokens: 500)]), at: date(2))
        let replaced = tracker.lanes(at: date(2))
        let previous = try XCTUnwrap(replaced.first { $0.terminal })
        let replacement = try XCTUnwrap(replaced.first { !$0.terminal })

        XCTAssertEqual(try XCTUnwrap(previous.sampledAverageTPS), 20, accuracy: 0.0001)
        XCTAssertNil(replacement.sampledAverageTPS)
        tracker.apply(snapshot([request("slot:two", tokens: 550)]), at: date(3))
        let advanced = try XCTUnwrap(tracker.lanes(at: date(3)).first { !$0.terminal })
        XCTAssertEqual(advanced.id, replacement.id)
        XCTAssertEqual(try XCTUnwrap(advanced.sampledAverageTPS), 50, accuracy: 0.0001)
    }

    func testTerminalMonitorReplayFreezesSampledWindowWhileCountsCanBeCorrected() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(
            snapshot([request("one", tokens: 120)], source: .studioMonitor), at: date(0))
        tracker.apply(
            snapshot([request("one", tokens: 160)], source: .studioMonitor), at: date(1))
        let completed = NativeRequestObservation(
            id: "one", endedAt: date(2), outputTokens: 220, liveTPS: 90, status: .completed)
        tracker.apply(snapshot([completed], source: .studioMonitor), at: date(3))
        let firstTerminal = try XCTUnwrap(tracker.lanes(at: date(3)).first)
        tracker.apply(snapshot([completed], source: .studioMonitor), at: date(4))
        tracker.apply(
            snapshot(
                [
                    NativeRequestObservation(
                        id: "one", endedAt: date(2), outputTokens: 225, status: .completed)
                ], source: .studioMonitor), at: date(8))
        let replayed = try XCTUnwrap(tracker.lanes(at: date(8)).first)

        XCTAssertEqual(firstTerminal.endedAt, date(2))
        XCTAssertEqual(
            try XCTUnwrap(firstTerminal.sampledAverageTPS), 100.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(replayed.id, firstTerminal.id)
        XCTAssertEqual(replayed.outputTokens, 225)
        XCTAssertEqual(replayed.sampledAverageTPS, firstTerminal.sampledAverageTPS)
    }

    func testConcurrentExplicitCompletionDoesNotEndSibling() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(snapshot([request("one"), request("two")]), at: date(1))
        let ids = Set(tracker.lanes(at: date(1)).map(\.id))
        tracker.apply(
            snapshot([
                NativeRequestObservation(
                    id: "one", model: "first", endedAt: date(1.8), outputTokens: 42,
                    status: .completed),
                request("two", tokens: 50, model: "second"),
            ]), at: date(2))
        let lanes = tracker.lanes(at: date(2))
        let completed = try XCTUnwrap(lanes.first { $0.endStatus == .completed })
        let running = try XCTUnwrap(lanes.first { !$0.terminal })

        XCTAssertEqual(Set(lanes.map(\.id)), ids)
        XCTAssertEqual(completed.endedAt, date(1.8))
        XCTAssertEqual(completed.outputTokens, 42)
        XCTAssertEqual(running.model, "second")
        XCTAssertEqual(running.outputTokens, 50)
    }

    func testMissingPartialAndCompleteEmptySnapshotsHaveDifferentMeaning() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(snapshot([request("one")]), at: date(0))
        let id = try XCTUnwrap(tracker.lanes(at: date(0)).first?.id)
        tracker.apply(nil, at: date(1))
        tracker.apply(snapshot([], complete: false), at: date(2))
        XCTAssertEqual(tracker.lanes(at: date(2)).first?.id, id)
        XCTAssertFalse(try XCTUnwrap(tracker.lanes(at: date(2)).first).terminal)

        tracker.apply(snapshot([]), at: date(3))
        let ended = try XCTUnwrap(tracker.lanes(at: date(3)).first)
        XCTAssertEqual(ended.id, id)
        XCTAssertEqual(ended.endedAt, date(3))
        XCTAssertEqual(ended.endStatus, .observationEnded)
    }

    func testIdentityFreshnessExpiresEvenWhenOtherPartialSnapshotsKeepArriving() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(snapshot([request("one")], complete: false), at: date(0))
        tracker.apply(snapshot([], complete: false), at: date(4))
        tracker.advance(at: date(5))
        XCTAssertNil(tracker.lanes(at: date(5)).first?.endStatus)
        tracker.advance(at: date(5.5))
        let ended = try XCTUnwrap(tracker.lanes(at: date(5.5)).first)
        XCTAssertEqual(ended.endStatus, .observationEnded)
        XCTAssertEqual(ended.endedAt, date(5))

        tracker.apply(snapshot([request("one")], complete: false), at: date(6))
        let lanes = tracker.lanes(at: date(6))
        XCTAssertEqual(lanes.count, 2)
        XCTAssertNotEqual(lanes.first { !$0.terminal }?.id, ended.id)
        XCTAssertEqual(lanes.first { !$0.terminal }?.startedAt, date(6))
    }

    func testSlotCounterDecreaseStartsFreshObservationForSameWireIdentity() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(snapshot([request("slot:task", tokens: 80)]), at: date(0))
        tracker.apply(snapshot([request("slot:task", tokens: 100)]), at: date(1))
        let original = try XCTUnwrap(tracker.lanes(at: date(1)).first)
        tracker.apply(snapshot([request("slot:task", tokens: 5)]), at: date(2))
        let lanes = tracker.lanes(at: date(2))
        let prior = try XCTUnwrap(lanes.first { $0.id == original.id })
        let replacement = try XCTUnwrap(lanes.first { !$0.terminal })
        XCTAssertEqual(prior.endStatus, .observationEnded)
        XCTAssertEqual(prior.outputTokens, 100)
        XCTAssertEqual(prior.endedAt, date(2))
        XCTAssertEqual(try XCTUnwrap(prior.sampledAverageTPS), 20, accuracy: 0.0001)
        XCTAssertNotEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.outputTokens, 5)
        XCTAssertEqual(replacement.startedAt, date(2))
        XCTAssertNil(replacement.sampledAverageTPS)
    }

    func testTerminalReplayAndDuplicateRowsNeverReopenOrDuplicateLane() throws {
        var tracker = NativeRequestTracker()
        let finished = NativeRequestObservation(id: "one", outputTokens: 50, status: .completed)
        tracker.apply(snapshot([finished, request("one", tokens: 10)]), at: date(1))
        let original = try XCTUnwrap(tracker.lanes(at: date(1)).first)
        tracker.apply(snapshot([request("one", tokens: 100)]), at: date(2))
        tracker.apply(snapshot([finished]), at: date(3))
        let lanes = tracker.lanes(at: date(3))
        XCTAssertEqual(lanes.count, 1)
        XCTAssertEqual(lanes.first?.id, original.id)
        XCTAssertEqual(lanes.first?.outputTokens, 50)
        XCTAssertEqual(lanes.first?.endStatus, .completed)
        XCTAssertEqual(lanes.first?.endedAt, date(1))
    }

    func testMonitorCountCorrectionKeepsTheSameRequestIdentity() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(
            snapshot([request("one", tokens: 70)], source: .studioMonitor), at: date(0))
        tracker.apply(
            snapshot([request("one", tokens: 100)], source: .studioMonitor), at: date(1))
        let originalID = try XCTUnwrap(tracker.lanes(at: date(1)).first?.id)
        XCTAssertEqual(tracker.lanes(at: date(1)).first?.sampledAverageTPS, 30)
        tracker.apply(
            snapshot([request("one", tokens: 80)], source: .studioMonitor), at: date(2))
        XCTAssertEqual(tracker.lanes(at: date(2)).count, 1)
        XCTAssertEqual(tracker.lanes(at: date(2)).first?.id, originalID)
        XCTAssertEqual(tracker.lanes(at: date(2)).first?.outputTokens, 80)
        XCTAssertNil(tracker.lanes(at: date(2)).first?.endStatus)
        XCTAssertNil(tracker.lanes(at: date(2)).first?.sampledAverageTPS)
        tracker.apply(
            snapshot([request("one", tokens: 110)], source: .studioMonitor), at: date(3))
        XCTAssertEqual(tracker.lanes(at: date(3)).first?.sampledAverageTPS, 30)
        tracker.apply(
            snapshot([request("one", tokens: 90)], source: .studioMonitor), at: date(4))
        XCTAssertEqual(tracker.lanes(at: date(4)).first?.id, originalID)
        XCTAssertNil(tracker.lanes(at: date(4)).first?.sampledAverageTPS)
        tracker.apply(
            snapshot([request("one", tokens: 100)], source: .studioMonitor), at: date(5))
        XCTAssertEqual(tracker.lanes(at: date(5)).first?.sampledAverageTPS, 10)
    }

    func testProviderFallbackAndRecoveryReuseEpochWithoutDuplicateBars() throws {
        var tracker = NativeRequestTracker()
        let monitorEpoch = UUID()
        tracker.apply(
            snapshot([request("one")], source: .studioMonitor, epoch: monitorEpoch), at: date(0))
        let monitorID = try XCTUnwrap(tracker.lanes(at: date(0)).first?.id)
        tracker.apply(snapshot([request("slot:one")]), at: date(1))
        XCTAssertEqual(tracker.lanes(at: date(1)).count, 1)
        XCTAssertEqual(tracker.lanes(at: date(1)).first?.observationSource, .slotPolling)
        tracker.apply(
            snapshot([request("one")], source: .studioMonitor, epoch: monitorEpoch), at: date(2))
        let recovered = tracker.lanes(at: date(2))
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.observationSource, .studioMonitor)
        XCTAssertNotEqual(recovered.first?.id, monitorID)
    }

    func testWorkerEpochResetRejectsOldProviderEpochAndOlderSamples() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(snapshot([request("one", tokens: 0)]), at: date(0))
        tracker.apply(snapshot([request("one", tokens: 10)]), at: date(1))
        let firstID = try XCTUnwrap(tracker.lanes(at: date(1)).first?.id)
        XCTAssertEqual(tracker.lanes(at: date(1)).first?.sampledAverageTPS, 10)
        let replacementEpoch = UUID()
        tracker.apply(
            snapshot([request("one", tokens: 20)], epoch: replacementEpoch), at: date(2))
        let replacement = try XCTUnwrap(tracker.lanes(at: date(2)).first)
        XCTAssertNotEqual(replacement.id, firstID)
        XCTAssertNil(replacement.sampledAverageTPS)
        tracker.apply(snapshot([request("old", tokens: 500)]), at: date(3))
        tracker.apply(
            snapshot([request("old", tokens: 1000)], epoch: replacementEpoch), at: date(1.5))
        XCTAssertEqual(tracker.lanes(at: date(3)).map(\.id), [replacement.id])
        XCTAssertEqual(tracker.lanes(at: date(3)).first?.outputTokens, 20)
    }

    func testMalformedMetadataCannotInventTimesCountsOrRates() throws {
        var tracker = NativeRequestTracker()
        tracker.apply(
            snapshot([
                NativeRequestObservation(
                    id: "one", startedAt: date(.nan), endedAt: date(.infinity),
                    outputTokens: -1, liveTPS: .nan, status: .failed),
                request(""),
            ]), at: date(1))
        let lanes = tracker.lanes(at: date(1))
        let lane = try XCTUnwrap(lanes.first)
        XCTAssertEqual(lanes.count, 1)
        XCTAssertEqual(lane.startedAt, date(1))
        XCTAssertEqual(lane.endedAt, date(1))
        XCTAssertEqual(lane.endStatus, .failed)
        XCTAssertEqual(lane.outputTokens, 0)
        XCTAssertTrue(lane.outputIsEstimated)
        XCTAssertEqual(lane.liveTPS, 0)
        tracker.apply(snapshot([]), at: date(.nan))
        tracker.apply(snapshot([]), at: date(.infinity))
        XCTAssertEqual(tracker.lanes(at: date(2)).map(\.id), [lane.id])
    }

    func testRetentionAndBurstBoundsDropTerminalLanesBeforeActiveIdentities() {
        var tracker = NativeRequestTracker(retentionInterval: 10, capacity: 3)
        tracker.apply(
            snapshot([
                NativeRequestObservation(id: "ended", endedAt: date(0), status: .cancelled),
                request("a"), request("b"), request("c"),
            ]), at: date(1))
        XCTAssertEqual(tracker.lanes(at: date(1)).count, 3)
        XCTAssertTrue(tracker.lanes(at: date(1)).allSatisfy { !$0.terminal })
        tracker.apply(snapshot([]), at: date(2))
        XCTAssertTrue(tracker.lanes(at: date(2)).allSatisfy { $0.endStatus == .observationEnded })
        tracker.advance(at: date(12))
        XCTAssertEqual(tracker.lanes(at: date(12)).count, 3, "The cutoff is inclusive")
        tracker.advance(at: date(12.1))
        XCTAssertTrue(tracker.lanes(at: date(12.1)).isEmpty)
    }

    func testFutureAndNegativeReportedDatesFallBackToObservationTime() {
        var tracker = NativeRequestTracker()
        tracker.apply(
            snapshot([
                NativeRequestObservation(
                    id: "future", startedAt: date(10), endedAt: date(11), status: .completed),
                NativeRequestObservation(
                    id: "negative", startedAt: Date(timeIntervalSince1970: -1),
                    endedAt: Date(timeIntervalSince1970: -0.5), status: .cancelled),
            ]), at: date(1))
        let lanes = tracker.lanes(at: date(1))
        XCTAssertEqual(lanes.count, 2)
        XCTAssertTrue(lanes.allSatisfy { $0.startedAt == date(1) && $0.endedAt == date(1) })
    }

    func testResetClearsIdentitiesProviderEpochsAndReplayProtection() {
        var tracker = NativeRequestTracker()
        tracker.apply(snapshot([request("one")]), at: date(1))
        tracker.apply(snapshot([], epoch: UUID()), at: date(2))
        tracker.reset()
        XCTAssertTrue(tracker.lanes(at: date(2)).isEmpty)
        tracker.apply(snapshot([request("one")]), at: date(0))
        XCTAssertEqual(tracker.lanes(at: date(0)).count, 1)
    }

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    private func request(
        _ id: String, tokens: Int? = nil, rate: Double? = nil, model: String? = nil
    ) -> NativeRequestObservation {
        NativeRequestObservation(id: id, model: model, outputTokens: tokens, liveTPS: rate)
    }

    private func snapshot(
        _ requests: [NativeRequestObservation], source: RequestObservationSource = .slotPolling,
        epoch: UUID? = nil, complete: Bool = true
    ) -> NativeRequestSnapshot {
        NativeRequestSnapshot(
            sourceEpoch: epoch ?? self.epoch, source: source, requests: requests,
            isComplete: complete)
    }
}
