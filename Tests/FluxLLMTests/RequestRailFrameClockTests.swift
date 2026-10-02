import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class RequestRailFrameClockTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testEarlyFramesAreRejectedAndDelayedFramesNeverCatchUp() throws {
        let clock = RequestRailFrameClock()
        let generation = clock.start(at: origin, monotonicTime: 10)
        let firstDeadline = try XCTUnwrap(clock.nextDeadline(for: generation))
        XCTAssertEqual(firstDeadline, 10 + 1.0 / 30, accuracy: 0.000001)
        XCTAssertFalse(
            clock.tick(
                generation: generation, at: origin.addingTimeInterval(0.01), monotonicTime: 10.01))
        XCTAssertEqual(clock.date, origin)
        XCTAssertEqual(clock.nextDeadline(for: generation), firstDeadline)

        let delayedDate = origin.addingTimeInterval(2)
        XCTAssertTrue(clock.tick(generation: generation, at: delayedDate, monotonicTime: 12))
        XCTAssertEqual(clock.date, delayedDate)
        let nextDeadline = try XCTUnwrap(clock.nextDeadline(for: generation))
        XCTAssertEqual(nextDeadline, 12 + 1.0 / 30, accuracy: 0.000001)
        XCTAssertFalse(clock.tick(generation: generation, at: delayedDate, monotonicTime: 12))
        XCTAssertFalse(clock.tick(generation: generation, at: delayedDate, monotonicTime: 12.02))
        XCTAssertTrue(
            clock.tick(
                generation: generation, at: delayedDate.addingTimeInterval(1.0 / 30),
                monotonicTime: nextDeadline))
    }

    func testStopAndRestartRejectOldCallbacksAndOldCleanup() throws {
        let clock = RequestRailFrameClock()
        let first = clock.start(at: origin, monotonicTime: 0)
        clock.stop()
        XCTAssertNil(clock.nextDeadline(for: first))
        XCTAssertFalse(
            clock.tick(generation: first, at: origin.addingTimeInterval(1), monotonicTime: 1))

        let resumedDate = origin.addingTimeInterval(2)
        let second = clock.start(at: resumedDate, monotonicTime: 2)
        let deadline = try XCTUnwrap(clock.nextDeadline(for: second))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(clock.tick(generation: first, at: origin, monotonicTime: 3))
        clock.stop(generation: first)
        XCTAssertEqual(
            clock.nextDeadline(for: second), deadline,
            "An old task's defer must not stop a reappeared clock")
        XCTAssertEqual(clock.date, resumedDate)
        clock.stop(generation: second)
        XCTAssertNil(clock.nextDeadline(for: second))
        XCTAssertFalse(clock.tick(generation: second, at: origin, monotonicTime: 3))
    }

    func testWallClockChangesAffectEffectAgeWithoutChangingMonotonicCadence() throws {
        let clock = RequestRailFrameClock()
        let generation = clock.start(at: origin, monotonicTime: 0)
        let deadline = try XCTUnwrap(clock.nextDeadline(for: generation))
        let changedWallTime = origin.addingTimeInterval(-3600)
        XCTAssertTrue(
            clock.tick(generation: generation, at: changedWallTime, monotonicTime: deadline))
        XCTAssertEqual(
            clock.date, changedWallTime, "Preserve the existing wall-time effect age calculation")
        XCTAssertEqual(
            try XCTUnwrap(clock.nextDeadline(for: generation)), deadline + 1.0 / 30,
            accuracy: 0.000001)
        XCTAssertFalse(
            clock.tick(
                generation: generation, at: origin.addingTimeInterval(3600),
                monotonicTime: deadline))
    }

    func testAlreadyCancelledRunnerCannotReplaceANewerActiveGeneration() async throws {
        let clock = RequestRailFrameClock()
        let generation = clock.start(at: origin, monotonicTime: 10)
        let deadline = try XCTUnwrap(clock.nextDeadline(for: generation))
        // Both operations run on the main actor, so cancellation happens before
        // this task can enter run(). No timer or real sleep is needed.
        let cancelled = Task { @MainActor in await clock.run() }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(clock.nextDeadline(for: generation), deadline)
        XCTAssertEqual(clock.date, origin)
        XCTAssertTrue(
            clock.tick(
                generation: generation, at: origin.addingTimeInterval(1.0 / 30),
                monotonicTime: deadline))
    }

    func testInvalidTimeCannotStartOrAdvanceTheClock() throws {
        let clock = RequestRailFrameClock()
        let invalid = clock.start(at: origin, monotonicTime: .nan)
        XCTAssertNil(clock.nextDeadline(for: invalid))
        XCTAssertFalse(clock.tick(generation: invalid, at: origin, monotonicTime: 1))
        let generation = clock.start(at: origin, monotonicTime: 0)
        let deadline = try XCTUnwrap(clock.nextDeadline(for: generation))
        XCTAssertFalse(clock.tick(generation: generation, at: origin, monotonicTime: .infinity))
        XCTAssertFalse(
            clock.tick(
                generation: generation, at: Date(timeIntervalSinceReferenceDate: .nan),
                monotonicTime: deadline))
        XCTAssertEqual(clock.date, origin)
        XCTAssertEqual(clock.nextDeadline(for: generation), deadline)
    }
}
