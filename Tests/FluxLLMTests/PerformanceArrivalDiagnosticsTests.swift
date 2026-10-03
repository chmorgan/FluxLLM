import Foundation
import XCTest

@testable import FluxLLM

final class PerformanceArrivalDiagnosticsTests: XCTestCase {
    private typealias Diagnostics = PerformanceArrivalDiagnostics
    private typealias Metric = Diagnostics.Metric
    private typealias Sample = Diagnostics.ClockSample

    func testSnapshotIncludesEveryMetricAndSerializesAsJSON() throws {
        let clock = ScriptedClock([])
        let diagnostics = Diagnostics(clock: { clock.read() })
        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot["schema_version"] as? Int, 1)
        XCTAssertEqual(snapshot["measurement_thread_cpu"] as? Bool, true)
        XCTAssertEqual(snapshot["enabled"] as? Bool, false)
        let expectedNames: Set<String> = [
            "profile_preparation", "profile_create", "metal_elements", "metal_descriptor_update",
            "metal_descriptor_upload", "metal_surface_setup", "metal_first_drawable",
            "metal_later_drawable", "metal_frame_callback", "metal_frame_encode",
            "metal_frame_submit",
            "metal_completion_callback", "metal_completion_main_actor", "metal_clear",
            "canvas_arrival_draw",
        ]
        XCTAssertEqual(Set(Metric.allCases.map(\.rawValue)), expectedNames)
        let metrics = try XCTUnwrap(snapshot["metrics"] as? [String: [String: UInt64]])
        XCTAssertEqual(Set(metrics.keys), expectedNames)
        for metric in Metric.allCases {
            XCTAssertEqual(metrics[metric.rawValue], counters())
        }
        let encoded = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(decoded["schema_version"] as? Int, 1)
        XCTAssertEqual((decoded["metrics"] as? [String: Any])?.count, expectedNames.count)
        XCTAssertEqual(clock.readCount, 0)
    }

    func testCPUAndWallTimeAggregateIndependentlyWithSeparateMaxima() throws {
        let clock = ScriptedClock([
            sample(cpu: 100, wall: 1_000), sample(cpu: 130, wall: 1_200),
            sample(cpu: 200, wall: 2_000), sample(cpu: 250, wall: 2_050),
            sample(cpu: 300, wall: 3_000), sample(cpu: 307, wall: 3_011),
        ])
        let diagnostics = Diagnostics(clock: { clock.read() })
        diagnostics.enable()
        diagnostics.end(try XCTUnwrap(diagnostics.begin(.profilePreparation)))
        diagnostics.end(try XCTUnwrap(diagnostics.begin(.profilePreparation)))
        diagnostics.end(try XCTUnwrap(diagnostics.begin(.metalFrameEncode)))
        XCTAssertEqual(
            try values(.profilePreparation, in: diagnostics),
            counters(calls: 2, cpu: 80, wall: 250, maxCPU: 50, maxWall: 200))
        XCTAssertEqual(
            try values(.metalFrameEncode, in: diagnostics),
            counters(calls: 1, cpu: 7, wall: 11, maxCPU: 7, maxWall: 11))
        XCTAssertEqual(try values(.canvasArrivalDraw, in: diagnostics), counters())
        XCTAssertEqual(clock.readCount, 6)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(diagnostics.snapshot()))
    }

    func testDisabledAndNilTokensNeverReadTheClock() throws {
        let clock = ScriptedClock([])
        let diagnostics = Diagnostics(clock: { clock.read() })
        for metric in Metric.allCases {
            XCTAssertNil(diagnostics.begin(metric))
            diagnostics.end(nil)
            XCTAssertEqual(try values(metric, in: diagnostics), counters())
        }
        diagnostics.enable()
        diagnostics.end(nil)
        diagnostics.disable()
        diagnostics.end(nil)
        XCTAssertNil(diagnostics.begin(.metalSurfaceSetup))
        XCTAssertEqual(clock.readCount, 0)
    }

    func testUnavailableBeginClockRecordsFailureWithoutCreatingToken() throws {
        let clock = ScriptedClock([nil])
        let diagnostics = Diagnostics(clock: { clock.read() })
        diagnostics.enable()
        let token = diagnostics.begin(.metalFirstDrawable)
        XCTAssertNil(token)
        diagnostics.end(token)
        XCTAssertEqual(try values(.metalFirstDrawable, in: diagnostics), counters(failures: 1))
        XCTAssertEqual(clock.readCount, 1)
    }

    func testUnavailableOrNonmonotonicEndClockConsumesTokenWithoutSuccessfulCall() throws {
        let endings: [Sample?] = [
            nil,
            sample(cpu: 99, wall: 1_001),
            sample(cpu: 101, wall: 999),
        ]
        for ending in endings {
            let clock = ScriptedClock([sample(cpu: 100, wall: 1_000), ending])
            let diagnostics = Diagnostics(clock: { clock.read() })
            diagnostics.enable()
            let token = try XCTUnwrap(diagnostics.begin(.metalLaterDrawable))
            diagnostics.end(token)
            XCTAssertEqual(try values(.metalLaterDrawable, in: diagnostics), counters(failures: 1))
            diagnostics.end(token)
            XCTAssertEqual(
                try values(.metalLaterDrawable, in: diagnostics), counters(failures: 1, rejected: 1)
            )
            XCTAssertEqual(clock.readCount, 2)
        }
    }

    func testCrossThreadEndIsRejectedAndConsumedWithoutClockFailure() throws {
        let clock = ScriptedClock([
            sample(thread: 7, cpu: 100, wall: 1_000),
            sample(thread: 8, cpu: 110, wall: 1_100),
        ])
        let diagnostics = Diagnostics(clock: { clock.read() })
        diagnostics.enable()
        let token = try XCTUnwrap(diagnostics.begin(.metalCompletionCallback))
        diagnostics.end(token)
        XCTAssertEqual(try values(.metalCompletionCallback, in: diagnostics), counters(rejected: 1))
        diagnostics.end(token)
        XCTAssertEqual(try values(.metalCompletionCallback, in: diagnostics), counters(rejected: 2))
        XCTAssertEqual(clock.readCount, 2)
    }

    func testDuplicateEndDoesNotResampleOrDoubleCount() throws {
        let clock = ScriptedClock([sample(cpu: 10, wall: 100), sample(cpu: 14, wall: 117)])
        let diagnostics = Diagnostics(clock: { clock.read() })
        diagnostics.enable()
        let token = try XCTUnwrap(diagnostics.begin(.metalDescriptorUpload))
        diagnostics.end(token)
        diagnostics.end(token)
        XCTAssertEqual(
            try values(.metalDescriptorUpload, in: diagnostics),
            counters(calls: 1, cpu: 4, wall: 17, maxCPU: 4, maxWall: 17, rejected: 1))
        XCTAssertEqual(clock.readCount, 2)
    }

    func testEnableResetsCountersAndRejectsOldGenerationWithoutResampling() throws {
        let clock = ScriptedClock([
            sample(cpu: 10, wall: 100), sample(cpu: 15, wall: 120),
            sample(cpu: 20, wall: 200),
            sample(cpu: 30, wall: 300), sample(cpu: 32, wall: 330),
        ])
        let diagnostics = Diagnostics(clock: { clock.read() })
        diagnostics.enable()
        diagnostics.end(try XCTUnwrap(diagnostics.begin(.metalElements)))
        let stale = try XCTUnwrap(diagnostics.begin(.metalDescriptorUpdate))
        diagnostics.enable()
        for metric in Metric.allCases {
            XCTAssertEqual(try values(metric, in: diagnostics), counters())
        }
        diagnostics.end(stale)
        XCTAssertEqual(try values(.metalDescriptorUpdate, in: diagnostics), counters(rejected: 1))
        XCTAssertEqual(clock.readCount, 3)
        diagnostics.end(try XCTUnwrap(diagnostics.begin(.metalElements)))
        XCTAssertEqual(
            try values(.metalElements, in: diagnostics),
            counters(calls: 1, cpu: 2, wall: 30, maxCPU: 2, maxWall: 30))
        XCTAssertEqual(clock.readCount, 5)
    }

    func testDisablePreservesResultsAndIgnoresOutstandingEndUntilReenabled() throws {
        let clock = ScriptedClock([
            sample(cpu: 10, wall: 100), sample(cpu: 15, wall: 120),
            sample(cpu: 20, wall: 200),
        ])
        let diagnostics = Diagnostics(clock: { clock.read() })
        diagnostics.enable()
        diagnostics.end(try XCTUnwrap(diagnostics.begin(.canvasArrivalDraw)))
        let pending = try XCTUnwrap(diagnostics.begin(.metalClear))
        diagnostics.disable()
        diagnostics.end(pending)
        XCTAssertNil(diagnostics.begin(.metalClear))
        XCTAssertEqual(diagnostics.snapshot()["enabled"] as? Bool, false)
        XCTAssertEqual(
            try values(.canvasArrivalDraw, in: diagnostics),
            counters(calls: 1, cpu: 5, wall: 20, maxCPU: 5, maxWall: 20))
        XCTAssertEqual(try values(.metalClear, in: diagnostics), counters())
        XCTAssertEqual(clock.readCount, 3)
        diagnostics.enable()
        diagnostics.end(pending)
        XCTAssertEqual(try values(.metalClear, in: diagnostics), counters(rejected: 1))
        XCTAssertEqual(try values(.canvasArrivalDraw, in: diagnostics), counters())
        XCTAssertEqual(clock.readCount, 3)
    }

    func testForeignOwnerRejectsWithoutSamplingOrConsumingOwnersToken() throws {
        let ownerClock = ScriptedClock([sample(cpu: 10, wall: 100), sample(cpu: 12, wall: 130)])
        let foreignClock = ScriptedClock([])
        let owner = Diagnostics(clock: { ownerClock.read() })
        let foreign = Diagnostics(clock: { foreignClock.read() })
        owner.enable()
        foreign.enable()
        let token = try XCTUnwrap(owner.begin(.metalFrameSubmit))
        foreign.end(token)
        XCTAssertEqual(try values(.metalFrameSubmit, in: foreign), counters(rejected: 1))
        XCTAssertEqual(try values(.metalFrameSubmit, in: owner), counters())
        XCTAssertEqual(foreignClock.readCount, 0)
        XCTAssertEqual(ownerClock.readCount, 1)
        owner.end(token)
        XCTAssertEqual(
            try values(.metalFrameSubmit, in: owner),
            counters(calls: 1, cpu: 2, wall: 30, maxCPU: 2, maxWall: 30))
        XCTAssertEqual(ownerClock.readCount, 2)
    }

    func testDroppingUnfinishedTokenReleasesItWithoutCollectorRegistry() throws {
        let clock = ScriptedClock([sample(cpu: 10, wall: 100)])
        let diagnostics = Diagnostics(clock: { clock.read() })
        diagnostics.enable()
        weak var released: Diagnostics.Token?
        do {
            let token = try XCTUnwrap(diagnostics.begin(.profileCreate))
            released = token
            XCTAssertNotNil(released)
        }
        XCTAssertNil(released)
        XCTAssertEqual(try values(.profileCreate, in: diagnostics), counters())
        XCTAssertEqual(clock.readCount, 1)
    }

    func testRetainedTokenDoesNotRetainCollector() throws {
        let clock = ScriptedClock([sample(cpu: 10, wall: 100)])
        weak var released: Diagnostics?
        var retainedToken: Diagnostics.Token?
        do {
            let diagnostics = Diagnostics(clock: { clock.read() })
            released = diagnostics
            diagnostics.enable()
            retainedToken = try XCTUnwrap(diagnostics.begin(.profileCreate))
        }
        withExtendedLifetime(retainedToken) {
            XCTAssertNil(released)
        }
        XCTAssertEqual(clock.readCount, 1)
    }

    private func sample(thread: UInt64 = 7, cpu: UInt64, wall: UInt64) -> Sample {
        Sample(threadID: thread, cpuNanoseconds: cpu, uptimeNanoseconds: wall)
    }

    private func values(_ metric: Metric, in diagnostics: Diagnostics) throws -> [String: UInt64] {
        let metrics = try XCTUnwrap(
            diagnostics.snapshot()["metrics"] as? [String: [String: UInt64]])
        return try XCTUnwrap(metrics[metric.rawValue])
    }

    private func counters(
        calls: UInt64 = 0, cpu: UInt64 = 0, wall: UInt64 = 0,
        maxCPU: UInt64 = 0, maxWall: UInt64 = 0,
        failures: UInt64 = 0, rejected: UInt64 = 0
    ) -> [String: UInt64] {
        [
            "calls": calls, "cpu_ns": cpu, "wall_ns": wall,
            "max_cpu_ns": maxCPU, "max_wall_ns": maxWall,
            "clock_failures": failures, "rejected_tokens": rejected,
        ]
    }

    private final class ScriptedClock: @unchecked Sendable {
        private let lock = NSLock()
        private let samples: [Sample?]
        private var reads = 0

        init(_ samples: [Sample?]) { self.samples = samples }

        var readCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }

        func read() -> Sample? {
            lock.lock()
            defer { lock.unlock() }
            let index = reads
            reads += 1
            return index < samples.count ? samples[index] : nil
        }
    }
}
