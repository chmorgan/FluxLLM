import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class IOKitGPUActivitySamplerTests: XCTestCase {
    private let worker = GPUProcessIdentity(pid: 42, startTimeMicroseconds: 100)

    func testWarmupThenMeasuredIdleAndActivity() async throws {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        fixture.set(time: 0, clients: [client(1, time: 100)])
        let warmup = await sampler.sample(processes: [worker])
        XCTAssertNil(warmup.activityPercent)
        fixture.set(time: 1, clients: [client(1, time: 100)])
        let idle = await sampler.sample(processes: [worker])
        XCTAssertEqual(idle.activityPercent, 0)
        fixture.set(time: 3, clients: [client(1, time: 1_000_000_100)])
        let active = await sampler.sample(processes: [worker])
        XCTAssertEqual(try XCTUnwrap(active.activityPercent), 50, accuracy: 0.0001)
        XCTAssertEqual(active.processIDs, [42])
    }

    func testIndependentClientsAndQueuesCanExceedOneHundredPercent() async throws {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        fixture.set(time: 0, clients: [client(1, times: [10, 20]), client(2, time: 30)])
        _ = await sampler.sample(processes: [worker])
        fixture.set(
            time: 1,
            clients: [
                client(1, times: [1_000_000_010, 1_000_000_020]),
                client(2, time: 500_000_030),
                client(3, pid: 999, time: 999_999_999_999),
            ], unreadableProcessIDs: [999])
        let sample = await sampler.sample(processes: [worker])
        XCTAssertEqual(try XCTUnwrap(sample.activityPercent), 250, accuracy: 0.0001)
        XCTAssertEqual(sample.processIDs, [42])
    }

    func testCPUOnlyServerDoesNotInvalidateMeasuredWorker() async {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        let server = GPUProcessIdentity(pid: 21, startTimeMicroseconds: 50)
        fixture.set(time: 0, clients: [client(1, time: 100), client(2, pid: 21, times: [])])
        _ = await sampler.sample(processes: [server, worker])
        fixture.set(time: 1, clients: [client(1, time: 100), client(2, pid: 21, times: [])])
        let sample = await sampler.sample(processes: [server, worker])
        XCTAssertEqual(sample.activityPercent, 0)
        XCTAssertEqual(sample.processIDs, [42])
    }

    func testNewAndDisappearingClientsDoNotInjectOrSubtractLifetimeCounters() async {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        fixture.set(time: 0, clients: [client(1, time: 1_000_000_000)])
        _ = await sampler.sample(processes: [worker])
        fixture.set(
            time: 1, clients: [client(1, time: 1_000_000_001), client(2, time: 99_000_000_000)])
        let created = await sampler.sample(processes: [worker])
        XCTAssertNil(created.activityPercent)
        fixture.set(time: 2, clients: [client(1, time: 1_000_000_002)])
        let removed = await sampler.sample(processes: [worker])
        XCTAssertNil(removed.activityPercent)
        fixture.set(time: 3, clients: [client(1, time: 1_500_000_002)])
        let stable = await sampler.sample(processes: [worker])
        XCTAssertEqual(stable.activityPercent, 50)
    }

    func testCounterResetDoesNotBecomeIdleOrHideBehindAnotherClientsGrowth() async {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        fixture.set(time: 0, clients: [client(1, time: 1_000), client(2, time: 0)])
        _ = await sampler.sample(processes: [worker])
        fixture.set(time: 1, clients: [client(1, time: 5), client(2, time: 2_000_000_000)])
        let reset = await sampler.sample(processes: [worker])
        XCTAssertNil(reset.activityPercent)
        fixture.set(time: 2, clients: [client(1, time: 5), client(2, time: 2_000_000_000)])
        let stable = await sampler.sample(processes: [worker])
        XCTAssertEqual(stable.activityPercent, 0)
    }

    func testQueueTopologyAndCounterReorderingRebaseline() async {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        fixture.set(time: 0, clients: [client(1, times: [1_000, 100])])
        _ = await sampler.sample(processes: [worker])
        fixture.set(time: 1, clients: [client(1, times: [100, 1_000])])
        let reordered = await sampler.sample(processes: [worker])
        XCTAssertNil(reordered.activityPercent)
        fixture.set(time: 2, clients: [client(1, times: [100, 1_000, 999_000_000_000])])
        let newQueue = await sampler.sample(processes: [worker])
        XCTAssertNil(newQueue.activityPercent)
    }

    func testPIDReuseAndExplicitResetDiscardBaseline() async {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        fixture.set(time: 0, clients: [client(1, time: 0)])
        _ = await sampler.sample(processes: [worker])
        fixture.set(time: 1, clients: [client(1, time: 500_000_000)])
        let reused = GPUProcessIdentity(pid: 42, startTimeMicroseconds: 200)
        let sample = await sampler.sample(processes: [reused])
        XCTAssertNil(sample.activityPercent)
        await sampler.reset()
        fixture.set(time: 2, clients: [client(1, time: 900_000_000)])
        let reset = await sampler.sample(processes: [reused])
        XCTAssertNil(reset.activityPercent)
    }

    func testMissingCountersAndReadFailureRequireNewBaseline() async {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        fixture.set(time: 0, clients: [client(1, time: 0)])
        _ = await sampler.sample(processes: [worker])
        fixture.set(time: 1, clients: [])
        let missing = await sampler.sample(processes: [worker])
        XCTAssertNil(missing.activityPercent)
        fixture.set(time: 2, clients: [client(1, time: 2_000_000_000)])
        let returning = await sampler.sample(processes: [worker])
        XCTAssertNil(returning.activityPercent)
        fixture.set(time: 3, clients: [], throwsError: true)
        let failure = await sampler.sample(processes: [worker])
        XCTAssertNil(failure.activityPercent)
        fixture.set(time: 4, clients: [client(1, time: 4_000_000_000)])
        let recovered = await sampler.sample(processes: [worker])
        XCTAssertNil(recovered.activityPercent)
    }

    func testMalformedSelectedClientInvalidatesAnOtherwiseStableZero() async {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        fixture.set(time: 0, clients: [client(1, time: 0)])
        _ = await sampler.sample(processes: [worker])
        let otherWorker = GPUProcessIdentity(pid: 43, startTimeMicroseconds: 100)
        fixture.set(time: 1, clients: [client(1, time: 0)], unreadableProcessIDs: [43])
        let sample = await sampler.sample(processes: [worker, otherWorker])
        XCTAssertNil(sample.activityPercent)
    }

    func testSleepAndClockDiscontinuitiesCannotCreateSpikes() async {
        for (elapsed, wallElapsed) in [(60.0, 60.0), (0, 1), (1, 60), (1, -1), (-1, 1)] {
            let fixture = Fixture()
            let sampler = fixture.sampler()
            fixture.set(time: 0, clients: [client(1, time: 0)])
            _ = await sampler.sample(processes: [worker])
            fixture.set(
                time: elapsed, wallTime: wallElapsed,
                clients: [client(1, time: 90_000_000_000)])
            let sample = await sampler.sample(processes: [worker])
            XCTAssertNil(sample.activityPercent, "elapsed=\(elapsed), wall=\(wallElapsed)")
            fixture.set(
                time: elapsed + 1, wallTime: wallElapsed + 1,
                clients: [client(1, time: 90_100_000_000)])
            let resumed = await sampler.sample(processes: [worker])
            XCTAssertEqual(resumed.activityPercent, 10)
        }
    }

    func testEmptySelectionUnsupportedHardwareAndDuplicateIdentitiesAreUnavailable() async {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        fixture.set(time: 0, clients: [client(1, time: 0)])
        let empty = await sampler.sample(processes: [])
        XCTAssertNil(empty.activityPercent)
        let ambiguous = await sampler.sample(
            processes: [worker, GPUProcessIdentity(pid: 42, startTimeMicroseconds: 101)])
        XCTAssertNil(ambiguous.activityPercent)
        fixture.set(time: 0, clients: [], acceleratorCount: 0)
        let unsupported = await sampler.sample(processes: [worker])
        XCTAssertNil(unsupported.activityPercent)
        XCTAssertNotNil(unsupported.unavailableReason)
    }

    func testDuplicateRegistryClientsAreNeverDoubleCounted() async {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        fixture.set(time: 0, clients: [client(1, time: 0), client(1, time: 0)])
        _ = await sampler.sample(processes: [worker])
        fixture.set(time: 1, clients: [client(1, time: 100), client(1, time: 100)])
        let sample = await sampler.sample(processes: [worker])
        XCTAssertNil(sample.activityPercent)
    }

    func testLargeCountersSubtractBeforeConvertingToDouble() async throws {
        let fixture = Fixture()
        let sampler = fixture.sampler()
        fixture.set(time: 0, clients: [client(1, time: UInt64.max - 1_000_000_000)])
        _ = await sampler.sample(processes: [worker])
        fixture.set(time: 1, clients: [client(1, time: UInt64.max - 500_000_000)])
        let sample = await sampler.sample(processes: [worker])
        XCTAssertEqual(try XCTUnwrap(sample.activityPercent), 50, accuracy: 0.0001)
    }

    func testRegistryParserRequiresOwnerAndWellTypedQueueCounters() throws {
        let valid: [String: Any] = [
            "API": "Metal", "accumulatedGPUTime": NSNumber(value: 250),
            "lastSubmittedTime": NSNumber(value: 1_000),
        ]
        let parsed = try XCTUnwrap(
            IOKitGPURegistry.parse(
                registryID: 7,
                properties: ["IOUserClientCreator": "pid 42, truncated name", "AppUsage": [valid]]))
        XCTAssertEqual(parsed.processID, 42)
        XCTAssertEqual(parsed.queues.first?.accumulatedNanoseconds, 250)
        let invalidCounters: [Any] = [
            "250", NSNumber(value: true), NSNumber(value: -1), NSNumber(value: 2.5),
        ]
        for invalid in invalidCounters {
            var queue = valid
            queue["accumulatedGPUTime"] = invalid
            XCTAssertNil(
                IOKitGPURegistry.parse(
                    registryID: 7,
                    properties: ["IOUserClientCreator": "pid 42, worker", "AppUsage": [queue]]))
        }
        for creator in [
            "pid 42worker", "pid -1, worker", "pid 0, worker", "pid 999999999999, worker",
        ] {
            XCTAssertNil(
                IOKitGPURegistry.parse(
                    registryID: 7,
                    properties: ["IOUserClientCreator": creator, "AppUsage": [valid]]))
        }
        XCTAssertNil(
            IOKitGPURegistry.parse(
                registryID: 7,
                properties: ["IOUserClientCreator": "pid 42, worker", "AppUsage": []]))
        XCTAssertNil(
            IOKitGPURegistry.parse(
                registryID: 7,
                properties: [
                    "IOUserClientCreator": "pid 42, worker", "AppUsage": [valid, "malformed"],
                ]))
        for missingKey in ["API", "lastSubmittedTime", "accumulatedGPUTime"] {
            var queue = valid
            queue.removeValue(forKey: missingKey)
            XCTAssertNil(
                IOKitGPURegistry.parse(
                    registryID: 7,
                    properties: ["IOUserClientCreator": "pid 42, worker", "AppUsage": [queue]]))
        }
        for invalidTimestamp in [NSNumber(value: true), NSNumber(value: 2.5)] {
            var queue = valid
            queue["lastSubmittedTime"] = invalidTimestamp
            XCTAssertNil(
                IOKitGPURegistry.parse(
                    registryID: 7,
                    properties: ["IOUserClientCreator": "pid 42, worker", "AppUsage": [queue]]))
        }
    }

    func testOptInNativeRegistryEnumeration() throws {
        guard ProcessInfo.processInfo.environment["FLUXLLM_GPU_PROBE"] == "1" else {
            throw XCTSkip("Set FLUXLLM_GPU_PROBE=1 to inspect this Mac's real GPU registry.")
        }
        let snapshot = try IOKitGPURegistry.read()
        XCTAssertGreaterThan(snapshot.acceleratorCount, 0)
        XCTAssertFalse(
            snapshot.clients.isEmpty, "This validation Mac should expose active GPU clients.")
        XCTAssertTrue(snapshot.clients.allSatisfy { $0.processID > 0 && !$0.queues.isEmpty })
        XCTAssertEqual(Set(snapshot.clients.map(\.registryID)).count, snapshot.clients.count)
        print(
            "Native GPU registry: \(snapshot.acceleratorCount) accelerator(s), \(snapshot.clients.count) readable clients."
        )
    }

    private func client(_ id: UInt64, pid: Int32 = 42, time: UInt64) -> GPURegistryClient {
        client(id, pid: pid, times: [time])
    }

    private func client(_ id: UInt64, pid: Int32 = 42, times: [UInt64]) -> GPURegistryClient {
        GPURegistryClient(
            registryID: id, processID: pid,
            queues: times.map {
                GPURegistryQueue(api: "Metal", accumulatedNanoseconds: $0, lastSubmittedTime: 1)
            })
    }

    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot = GPURegistrySnapshot(acceleratorCount: 1, clients: [])
        private var instant = GPUActivityInstant(
            uptime: 0, date: Date(timeIntervalSince1970: 1_000))
        private var throwsError = false

        func set(
            time: TimeInterval, wallTime: TimeInterval? = nil, clients: [GPURegistryClient],
            acceleratorCount: Int = 1, throwsError: Bool = false,
            unreadableProcessIDs: Set<Int32> = []
        ) {
            lock.withLock {
                snapshot = GPURegistrySnapshot(
                    acceleratorCount: acceleratorCount, clients: clients,
                    unreadableProcessIDs: unreadableProcessIDs)
                instant = GPUActivityInstant(
                    uptime: time, date: Date(timeIntervalSince1970: 1_000 + (wallTime ?? time)))
                self.throwsError = throwsError
            }
        }

        func sampler() -> IOKitGPUActivitySampler {
            IOKitGPUActivitySampler(
                reader: {
                    try self.lock.withLock {
                        if self.throwsError { throw GPURegistryReadError.enumerationFailed }
                        return self.snapshot
                    }
                },
                clock: { self.lock.withLock { self.instant } })
        }
    }
}
