import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class SlotThroughputPresentationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testMeasuredDisplayWeightsDurationAndLeavesChartHistoryRaw() throws {
        let (store, epoch) = session()
        apply(store, epoch: epoch, at: 1, rate: 20, duration: 1)
        store.sample(at: date(1))
        XCTAssertEqual(store.displayTPS, 20)
        store.sample(at: date(1.5))
        store.sample(at: date(2))

        apply(store, epoch: epoch, at: 3, rate: 80, duration: 2)
        XCTAssertEqual(store.currentTPS, 80)
        XCTAssertEqual(store.displayTPS, 20)
        store.sample(at: date(3))
        XCTAssertEqual(store.displayTPS, 60, "Two measured seconds weigh twice as much as one")
        XCTAssertEqual(store.tpsHistory.map(\.value), [20, 20, 20, 80])
        XCTAssertTrue(store.tpsHistory.allSatisfy(\.isAvailable))

        apply(store, epoch: epoch, at: 4, rate: 100, duration: 1)
        store.sample(at: date(4))
        XCTAssertEqual(try XCTUnwrap(store.displayTPS), 260.0 / 3, accuracy: 0.000_001)
        XCTAssertEqual(store.currentTPS, 100)
        XCTAssertEqual(store.tpsHistory.last?.value, 100)
    }

    func testThreeSecondWindowClipsPartOfTheOldestMeasurement() {
        let (store, epoch) = session()
        apply(store, epoch: epoch, at: 2, rate: 10, duration: 2)
        store.sample(at: date(2))
        apply(store, epoch: epoch, at: 4, rate: 100, duration: 2)
        store.sample(at: date(4))
        XCTAssertEqual(store.displayTPS, 70, "Only one second of the older interval remains")

        apply(store, epoch: epoch, at: 5, rate: 100, duration: 1)
        store.sample(at: date(5))
        XCTAssertEqual(store.displayTPS, 100)
    }

    func testHalfSecondSamplingDoesNotAddMeasurementsOrBypassOneSecondCadence() throws {
        let (store, epoch) = session()
        apply(store, epoch: epoch, at: 1, rate: 10, duration: 1)
        store.sample(at: date(1))
        apply(store, epoch: epoch, at: 1.5, rate: 50, duration: 0.5)
        store.sample(at: date(1.5))
        store.sample(at: date(1.75))
        XCTAssertEqual(store.displayTPS, 10)
        XCTAssertEqual(store.displayUpdatedAt, date(1))
        XCTAssertEqual(store.currentTPS, 50)

        store.sample(at: date(2))
        XCTAssertEqual(try XCTUnwrap(store.displayTPS), 70.0 / 3, accuracy: 0.000_001)
        XCTAssertEqual(store.displayUpdatedAt, date(2))
        store.sample(at: date(2.5))
        XCTAssertEqual(store.displayUpdatedAt, date(2))
        store.sample(at: date(3))
        XCTAssertEqual(try XCTUnwrap(store.displayTPS), 70.0 / 3, accuracy: 0.000_001)
        XCTAssertEqual(store.displayUpdatedAt, date(3))
        XCTAssertEqual(store.tpsHistory.last?.value, 50)
    }

    func testHealthyWarmupStaysZeroWithoutFabricatingHistoryOrReplacingLastRate() {
        let (store, epoch) = session()
        apply(
            store, epoch: epoch, at: 0, rate: 80, duration: nil,
            running: 0, basis: .serverReportedAverage)
        XCTAssertEqual(store.lastMeasuredTPS, 80)
        apply(store, epoch: epoch, at: 0.2, rate: nil, duration: nil, state: .warmingUp)
        store.sample(at: date(0.2))
        store.sample(at: date(0.5))
        XCTAssertEqual(store.displayTPS, 0)
        XCTAssertEqual(store.liveScalars.rateLabel, "0.0")
        XCTAssertEqual(store.currentTPS, 0)
        XCTAssertFalse(store.rateIsAvailable)
        XCTAssertTrue(store.tpsHistory.allSatisfy { !$0.isAvailable })
        XCTAssertEqual(store.lastMeasuredTPS, 80)
        XCTAssertTrue(store.isBackendActive)

        apply(store, epoch: epoch, at: 0.8, rate: 56, duration: 0.6)
        store.sample(at: date(0.8))
        XCTAssertEqual(store.displayTPS, 0)
        store.sample(at: date(1))
        XCTAssertEqual(store.displayTPS, 56, "Repeated warmup zeros do not postpone publication")
        XCTAssertEqual(store.lastMeasuredTPS, 80)
        XCTAssertTrue(store.tpsHistory.last!.isAvailable)
    }

    func testNewRequestWarmupImmediatelyZerosOldSpeedAndResetsTheAverage() {
        let (store, epoch) = session()
        apply(store, epoch: epoch, at: 0, rate: 80, duration: 1)
        store.sample(at: date(0))
        XCTAssertEqual(store.displayTPS, 80)
        apply(store, epoch: epoch, at: 0.2, rate: nil, duration: nil, state: .warmingUp)
        XCTAssertEqual(store.displayTPS, 0)
        store.sample(at: date(0.5))
        XCTAssertEqual(store.displayTPS, 0)
        apply(store, epoch: epoch, at: 0.8, rate: 10, duration: 0.6)
        store.sample(at: date(1))
        XCTAssertEqual(store.displayTPS, 0)
        store.sample(at: date(1.2))
        XCTAssertEqual(store.displayTPS, 10)
    }

    func testIdleClearsImmediatelyAndRepeatedZerosDoNotResetRecoveryDeadline() {
        let (store, epoch) = session()
        apply(store, epoch: epoch, at: 0, rate: 40, duration: 1)
        store.sample(at: date(0))
        apply(store, epoch: epoch, at: 0.2, rate: 0, duration: nil, running: 0)
        XCTAssertEqual(store.displayTPS, 0)
        store.sample(at: date(0.5))
        apply(store, epoch: epoch, at: 0.6, rate: 0, duration: nil, running: 0)
        apply(store, epoch: epoch, at: 0.8, rate: 10, duration: 0.2)
        store.sample(at: date(1))
        XCTAssertEqual(store.displayTPS, 0)
        store.sample(at: date(1.2))
        XCTAssertEqual(
            store.displayTPS, 10, "Idle observations neither retain speed nor defer recovery")
    }

    func testUnavailableClearsImmediatelyAndRepeatedGapsDoNotResetRecoveryDeadline() {
        let (store, epoch) = session()
        apply(store, epoch: epoch, at: 0, rate: 40, duration: 1)
        store.sample(at: date(0))
        apply(store, epoch: epoch, at: 0.2, rate: nil, duration: nil, state: .unavailable)
        XCTAssertNil(store.displayTPS)
        store.sample(at: date(0.5))
        XCTAssertFalse(store.tpsHistory.last!.isAvailable)
        apply(store, epoch: epoch, at: 0.6, rate: nil, duration: nil, state: .unavailable)
        apply(store, epoch: epoch, at: 0.8, rate: 10, duration: 0.2)
        store.sample(at: date(1))
        XCTAssertNil(store.displayTPS)
        store.sample(at: date(1.2))
        XCTAssertEqual(store.displayTPS, 10)
    }

    func testFaultAndStaleTelemetryCannotBeMaskedByWarmupPresentation() {
        let (store, epoch) = session()
        apply(store, epoch: epoch, at: 0, rate: nil, duration: nil, state: .warmingUp)
        store.sample(at: date(0.5))
        XCTAssertEqual(store.displayTPS, 0)
        store.updateConnection(.unavailable, at: date(0.6))
        XCTAssertNil(store.displayTPS)
        store.sample(at: date(1))
        XCTAssertNil(store.displayTPS)

        apply(store, epoch: epoch, at: 1.1, rate: 20, duration: 0.5)
        store.sample(at: date(1.5))
        XCTAssertNil(store.displayTPS)
        store.sample(at: date(1.6))
        XCTAssertEqual(store.displayTPS, 20)
        store.sample(at: date(6.2))
        XCTAssertEqual(store.connectionState, .unavailable)
        XCTAssertNil(store.displayTPS)
        XCTAssertFalse(store.tpsHistory.last!.isAvailable)
        apply(store, epoch: epoch, at: 6.4, rate: 100, duration: 0.2)
        store.sample(at: date(7.2))
        XCTAssertEqual(store.displayTPS, 100, "Stale intervals cannot enter the recovered average")
    }

    func testHealthyWarmupExpiresWithBackendFreshness() {
        let (store, epoch) = session()
        apply(store, epoch: epoch, at: 0, rate: nil, duration: nil, state: .warmingUp)
        for offset in stride(from: 0.5, through: 5, by: 0.5) {
            store.sample(at: date(offset))
            XCTAssertEqual(store.displayTPS, 0)
        }
        store.sample(at: date(5.5))
        XCTAssertEqual(store.connectionState, .unavailable)
        XCTAssertNil(store.displayTPS)
        XCTAssertTrue(store.tpsHistory.allSatisfy { !$0.isAvailable })
    }

    func testModelAndSessionChangesNeverBlendEarlierSpeed() {
        let (store, epoch) = session()
        apply(store, epoch: epoch, at: 0, rate: 100, duration: 1, model: "first")
        store.sample(at: date(0))
        apply(store, epoch: epoch, at: 1, rate: 10, duration: 1, model: "second")
        store.sample(at: date(1))
        XCTAssertEqual(store.displayTPS, 10)

        let replacement = UUID()
        store.beginBackendSession(kind: .unsloth, epoch: replacement)
        apply(store, epoch: replacement, at: 1.2, rate: 20, duration: 1, model: "third")
        store.sample(at: date(1.2))
        XCTAssertEqual(
            store.displayTPS, 20, "A new session permits its first measurement immediately")
        apply(store, epoch: epoch, at: 1.3, rate: 1000, duration: 1, model: "first")
        XCTAssertEqual(store.currentTPS, 20)
        XCTAssertEqual(store.displayTPS, 20)
    }

    func testFallbackAndMissingDurationsDoNotEnterTheSlotAverage() {
        let (store, epoch) = session(kind: .llamaCpp)
        apply(store, epoch: epoch, kind: .llamaCpp, at: 0, rate: 100, duration: 1)
        store.sample(at: date(0))
        apply(
            store, epoch: epoch, kind: .llamaCpp, at: 1, rate: 10, duration: nil,
            basis: .serverReportedAverage)
        store.sample(at: date(1))
        XCTAssertEqual(store.displayTPS, 10)
        apply(store, epoch: epoch, kind: .llamaCpp, at: 2, rate: 30, duration: 1)
        store.sample(at: date(2))
        XCTAssertEqual(store.displayTPS, 30)
        apply(store, epoch: epoch, kind: .llamaCpp, at: 3, rate: 60, duration: nil)
        store.sample(at: date(3))
        XCTAssertEqual(store.displayTPS, 60)
        apply(store, epoch: epoch, kind: .llamaCpp, at: 4, rate: 100, duration: 1)
        store.sample(at: date(4))
        XCTAssertEqual(store.displayTPS, 100)

        let (other, otherEpoch) = session(kind: .vllm)
        apply(other, epoch: otherEpoch, kind: .vllm, at: 0, rate: 10, duration: 1)
        other.sample(at: date(0))
        apply(other, epoch: otherEpoch, kind: .vllm, at: 1, rate: 80, duration: 1)
        other.sample(at: date(1))
        XCTAssertEqual(other.displayTPS, 80, "Other backend publication behavior is unchanged")
    }

    func testInconsistentWarmupMetadataDoesNotInventHealthyZero() {
        for bogusRate in [Double.nan, -1, 99] {
            let (store, epoch) = session()
            apply(store, epoch: epoch, at: 0, rate: bogusRate, duration: nil, state: .warmingUp)
            store.sample(at: date(0))
            XCTAssertNil(store.displayTPS)
            XCTAssertFalse(store.rateIsAvailable)
        }
        for ready in [false, true] {
            let (store, epoch) = session()
            store.applyBackendSample(
                BackendSample(
                    kind: .unsloth, timestamp: date(0), isReady: ready,
                    throughputState: .warmingUp, runningRequests: ready ? nil : 1), epoch: epoch)
            store.sample(at: date(0))
            XCTAssertNil(store.displayTPS)
        }
        let (store, epoch) = session()
        apply(store, epoch: epoch, at: 0, rate: nil, duration: 1, state: .warmingUp)
        store.sample(at: date(0))
        XCTAssertNil(store.displayTPS)
    }

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    private func session(kind: BackendKind = .unsloth) -> (MetricsStore, UUID) {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: kind, epoch: epoch)
        return (store, epoch)
    }

    private func apply(
        _ store: MetricsStore, epoch: UUID, kind: BackendKind = .unsloth,
        at offset: TimeInterval, rate: Double?, duration: TimeInterval?, running: Int = 1,
        basis: ThroughputBasis = .serverAggregate,
        state: ThroughputMeasurementState? = nil, model: String = "model"
    ) {
        store.applyBackendSample(
            BackendSample(
                kind: kind, timestamp: date(offset), model: model, currentTPS: rate,
                basis: basis, throughputState: state, measurementDuration: duration,
                runningRequests: running, queuedRequests: 0), epoch: epoch)
    }
}
