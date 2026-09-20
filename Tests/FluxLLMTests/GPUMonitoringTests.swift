import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class GPUMonitoringTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 2_000)

    func testGPUStoreRejectsPreviousSessionAndOutOfOrderSamples() {
        let store = MetricsStore()
        let oldEpoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: oldEpoch)
        store.applyGPUSample(gpuSample(25, at: origin), epoch: oldEpoch)
        store.sample(at: origin)

        let epoch = UUID()
        store.beginBackendSession(kind: .llamaCpp, epoch: epoch)
        XCTAssertNil(store.backendGPUActivity)
        XCTAssertTrue(store.gpuHistory.isEmpty)
        store.applyGPUSample(gpuSample(999, at: origin), epoch: oldEpoch)
        XCTAssertNil(store.backendGPUActivity)

        let latest = gpuSample(42, at: origin.addingTimeInterval(2))
        store.applyGPUSample(latest, epoch: epoch)
        store.applyGPUSample(
            GPUActivitySample(timestamp: origin, unavailableReason: "Old failure"), epoch: epoch)
        store.applyGPUSample(gpuSample(900, at: origin.addingTimeInterval(1)), epoch: epoch)
        XCTAssertEqual(store.backendGPUActivity, latest)
        XCTAssertEqual(store.gpuAvailabilityMessage, "")

        // Selecting the same backend again is also a new collection session.
        store.beginBackendSession(kind: .llamaCpp, epoch: UUID())
        store.applyGPUSample(latest, epoch: epoch)
        XCTAssertNil(store.backendGPUActivity)
    }

    func testHealthyBackendPollsCannotKeepStaleGPUActivityAlive() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyGPUSample(gpuSample(60, at: origin), epoch: epoch)
        store.applyBackendSample(
            BackendSample(kind: .vllm, timestamp: origin, currentTPS: 30, runningRequests: 1),
            epoch: epoch)
        store.sample(at: origin)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin.addingTimeInterval(5), currentTPS: 31,
                runningRequests: 1), epoch: epoch)
        store.sample(at: origin.addingTimeInterval(5))
        XCTAssertEqual(store.backendGPUActivity?.activityPercent, 60)

        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin.addingTimeInterval(6), currentTPS: 32,
                runningRequests: 1), epoch: epoch)
        store.sample(at: origin.addingTimeInterval(6))
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.currentTPS, 32)
        XCTAssertTrue(store.tpsHistory.last?.isAvailable == true)
        XCTAssertNil(store.backendGPUActivity)
        XCTAssertFalse(store.gpuHistory.last?.isAvailable == true)
        XCTAssertEqual(store.gpuAvailabilityMessage, "GPU activity is no longer updating.")
    }

    func testMeasuredZeroIsDistinctFromUnknownGPUActivity() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyGPUSample(gpuSample(0, at: origin), epoch: epoch)
        store.sample(at: origin)
        XCTAssertEqual(store.backendGPUActivity?.activityPercent, 0)
        XCTAssertEqual(store.gpuHistory.last?.value, 0)
        XCTAssertTrue(store.gpuHistory.last?.isAvailable == true)

        store.applyGPUSample(
            GPUActivitySample(
                timestamp: origin.addingTimeInterval(1),
                unavailableReason: "The inference worker has exited."), epoch: epoch)
        store.sample(at: origin.addingTimeInterval(1))
        XCTAssertNil(store.backendGPUActivity)
        XCTAssertFalse(store.gpuHistory.last?.isAvailable == true)
        XCTAssertEqual(store.gpuAvailabilityMessage, "The inference worker has exited.")
    }

    func testGPUExecutionRatioCanExceed100ButRequiresValidAttributedData() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .rapidMLX, epoch: epoch)
        store.applyGPUSample(gpuSample(175, at: origin), epoch: epoch)
        XCTAssertEqual(store.backendGPUActivity?.activityPercent, 175)
        XCTAssertNil(store.systemGPUUtilizationPercent)
        XCTAssertTrue(store.systemGPUHistory.isEmpty)

        let invalid = [
            gpuSample(-1, at: origin),
            gpuSample(.nan, at: origin),
            gpuSample(.infinity, at: origin),
            GPUActivitySample(timestamp: origin, activityPercent: 50, processIDs: []),
            GPUActivitySample(
                timestamp: origin, activityPercent: 50, processIDs: [101], source: ""),
        ]
        for sample in invalid {
            store.applyGPUSample(sample, epoch: epoch)
            XCTAssertNil(store.backendGPUActivity)
            XCTAssertFalse(store.gpuAvailabilityMessage.isEmpty)
        }
    }

    func testSystemGPUAcceptsRealZeroWithoutBackendOrProcessAndRejectsInvalidPercentages() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: nil, epoch: epoch)
        store.applyGPUSample(systemSample(0, at: origin), epoch: epoch)
        store.sample(at: origin)
        XCTAssertEqual(store.systemGPUUtilizationPercent, 0)
        XCTAssertTrue(store.systemGPUHistory.last?.isAvailable == true)
        XCTAssertEqual(store.systemGPUHistory.last?.value, 0)
        for value in [-1, 100.1, .nan, .infinity] {
            store.applyGPUSample(systemSample(value, at: origin), epoch: epoch)
            XCTAssertNil(store.systemGPUUtilizationPercent)
        }
        store.applyGPUSample(systemSample(100, at: origin), epoch: epoch)
        XCTAssertEqual(store.systemGPUUtilizationPercent, 100)
        store.updateConnection(.unavailable)
        store.sample(at: origin.addingTimeInterval(1))
        XCTAssertEqual(store.systemGPUUtilizationPercent, 100)
        store.sample(at: origin.addingTimeInterval(6))
        XCTAssertNil(store.systemGPUUtilizationPercent)
        XCTAssertFalse(store.systemGPUHistory.last?.isAvailable == true)
    }

    func testGPUHistoryDoesNotMixScopesOrSources() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyGPUSample(gpuSample(175, at: origin), epoch: epoch)
        store.sample(at: origin)
        XCTAssertTrue(store.systemGPUHistory.isEmpty)
        let next = origin.addingTimeInterval(1)
        store.applyGPUSample(systemSample(23, at: next), epoch: epoch)
        XCTAssertTrue(store.gpuHistory.isEmpty)
        store.sample(at: next)
        XCTAssertEqual(store.systemGPUHistory.map(\.value), [23])
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: next.addingTimeInterval(1), activityPercent: 24,
                source: "A different device source", scope: .system), epoch: epoch)
        XCTAssertTrue(store.systemGPUHistory.isEmpty)
        store.sample(at: next.addingTimeInterval(1))
        XCTAssertEqual(store.systemGPUHistory.map(\.value), [24])
        store.applyGPUSample(gpuSample(180, at: next.addingTimeInterval(2)), epoch: epoch)
        XCTAssertNil(store.systemGPUUtilizationPercent)
        XCTAssertTrue(store.systemGPUHistory.isEmpty)
    }

    func testSystemGPULoopRunsWithoutBackendAndReconfiguresCleanly() async throws {
        let gpu = GPUControlledMonitor(scope: .system)
        let context = try makeContext(gpu: gpu)
        context.settings.backendSelection = .automatic
        do {
            await context.coordinator.start()
            try await eventually { context.store.systemGPUUtilizationPercent == 55 }
            XCTAssertNil(context.coordinator.selectedConfiguration)
            XCTAssertEqual(context.store.connectionState, .needsConfiguration)
            context.settings.backendSelection = .vllm
            try await context.coordinator.applySettings()
            try await eventually { context.store.systemGPUUtilizationPercent == 35 }
            XCTAssertEqual(context.store.backendKind, .vllm)
            await context.coordinator.stop()
            let stoppedCount = await gpu.sampleCount
            try await Task.sleep(for: .milliseconds(10))
            let finalCount = await gpu.sampleCount
            XCTAssertEqual(finalCount, stoppedCount)
            XCTAssertNil(context.store.systemGPUUtilizationPercent)
        } catch {
            await context.close()
            throw error
        }
        await context.close()
    }

    func testGPUHistoryIncludesSleepGapsAndDoesNotDuplicateOrReorderTimestamps() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyGPUSample(gpuSample(20, at: origin), epoch: epoch)
        store.sample(at: origin)
        let later = origin.addingTimeInterval(61)
        store.applyGPUSample(gpuSample(75, at: later), epoch: epoch)
        store.sample(at: later)
        XCTAssertEqual(store.gpuHistory.count, 3)
        XCTAssertEqual(store.gpuHistory.first?.value, 20)
        XCTAssertFalse(store.gpuHistory[1].isAvailable)
        XCTAssertEqual(store.gpuHistory[1].timestamp, origin.addingTimeInterval(0.5))
        XCTAssertEqual(store.gpuHistory.last?.value, 75)
        XCTAssertEqual(store.visibleHistoryDuration, 300)

        store.applyGPUSample(gpuSample(80, at: later), epoch: epoch)
        store.sample(at: later)
        store.sample(at: origin.addingTimeInterval(1))
        XCTAssertEqual(store.gpuHistory.count, 3)
        XCTAssertEqual(store.gpuHistory.last?.value, 80)
        XCTAssertEqual(store.gpuHistory.map(\.timestamp), store.tpsHistory.map(\.timestamp))

        let beyondWindow = origin.addingTimeInterval(MetricsStore.chartWindow + 1)
        store.applyGPUSample(gpuSample(10, at: beyondWindow), epoch: epoch)
        store.sample(at: beyondWindow)
        XCTAssertTrue(store.gpuHistory.allSatisfy { $0.timestamp >= origin.addingTimeInterval(1) })
        XCTAssertEqual(store.gpuHistory.last?.value, 10)
    }

    func testBackendTelemetryFailureDoesNotEraseFreshIndependentGPUActivity() {
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyGPUSample(gpuSample(48, at: origin), epoch: epoch)
        store.updateConnection(.unavailable, message: "Backend metrics request timed out.")
        store.sample(at: origin.addingTimeInterval(1))
        XCTAssertEqual(store.connectionState, .unavailable)
        XCTAssertEqual(store.backendGPUActivity?.activityPercent, 48)
        XCTAssertTrue(store.gpuHistory.last?.isAvailable == true)
        XCTAssertFalse(store.tpsHistory.last?.isAvailable == true)
    }

    func testLocalMonitorSamplesOnlyTheResolvedProcessesAndResetsWhenTheyDisappear() async {
        let server = GPUProcessIdentity(pid: 101, startTimeMicroseconds: 1_000)
        let worker = GPUProcessIdentity(pid: 102, startTimeMicroseconds: 1_001)
        let processes: Set<GPUProcessIdentity> = [server, worker]
        let resolver = GPUFixtureResolver(selection: GPUProcessSelection(processes: processes))
        let expected = GPUActivitySample(
            timestamp: origin, activityPercent: 45, processIDs: [101, 102])
        let sampler = GPUFixtureSampler(result: expected)
        let monitor = LocalBackendGPUMonitor(resolver: resolver, sampler: sampler)
        let configuration = BackendConfiguration(
            kind: .ollama, baseURL: URL(string: "http://127.0.0.1:11434")!)

        let result = await monitor.sample(configuration)
        XCTAssertEqual(result, expected)
        let resolved = await resolver.configurations
        let sampled = await sampler.processSelections
        XCTAssertEqual(resolved, [configuration])
        XCTAssertEqual(sampled, [processes])

        await resolver.setSelection(
            GPUProcessSelection(processes: [], unavailableReason: "No verified local worker."))
        let unavailable = await monitor.sample(configuration)
        XCTAssertNil(unavailable.activityPercent)
        XCTAssertTrue(unavailable.processIDs.isEmpty)
        XCTAssertEqual(unavailable.unavailableReason, "No verified local worker.")
        let sampledAfterExit = await sampler.processSelections
        let resetCount = await sampler.resetCount
        XCTAssertEqual(sampledAfterExit, [processes], "Never fall back to whole-device sampling")
        XCTAssertEqual(resetCount, 1, "A disappeared worker must discard its old counter baseline")

        await monitor.reset()
        let resolverResets = await resolver.resetCount
        let samplerResets = await sampler.resetCount
        XCTAssertEqual(resolverResets, 1)
        XCTAssertEqual(samplerResets, 2)
    }

    func testSwitchRejectsDelayedGPUResultBeforeTheNextSessionClearsState() async throws {
        let gpu = GPUControlledMonitor(holdSecondSample: true, holdSecondReset: true)
        let context = try makeContext(gpu: gpu)
        do {
            await context.coordinator.start()
            try await eventually { await gpu.waitingForSample }
            XCTAssertEqual(context.store.backendGPUActivity?.activityPercent, 35)
            let oldEpoch = context.store.monitoringEpoch
            context.settings.backendSelection = .llamaCpp
            let switching = Task { try await context.coordinator.applySettings() }
            try await eventually { context.coordinator.isApplying }
            await gpu.releaseSample(value: 999)
            try await eventually { await gpu.waitingForReset }

            // Reset is held after the old GPU task exits but before the store is
            // cleared. A broken cancellation guard cannot hide behind that clear.
            XCTAssertEqual(context.store.monitoringEpoch, oldEpoch)
            XCTAssertEqual(context.store.backendKind, .vllm)
            XCTAssertEqual(context.store.backendGPUActivity?.activityPercent, 35)
            await gpu.releaseReset()
            try await switching.value
            try await eventually { context.store.backendGPUActivity?.activityPercent == 55 }
            XCTAssertEqual(context.store.backendKind, .llamaCpp)
            XCTAssertNotEqual(context.store.monitoringEpoch, oldEpoch)
            let resetCount = await gpu.resetCount
            XCTAssertEqual(resetCount, 2)
            await context.close()
        } catch {
            await context.close()
            throw error
        }
    }

    func testGPUUpdatesContinueWhileInitialBackendHTTPResponseIsPending() async throws {
        let gpu = GPUControlledMonitor()
        let client = GPUControlledBackendClient(holdFirstSample: true)
        let context = try makeContext(gpu: gpu, client: client)
        let startup = Task { await context.coordinator.start() }
        do {
            try await eventually { await client.waitingForSample }
            try await eventually { await gpu.sampleCount >= 3 }
            XCTAssertEqual(context.store.connectionState, .connecting)
            XCTAssertEqual(context.store.backendGPUActivity?.activityPercent, 35)
            XCTAssertEqual(context.store.currentTPS, 0)
            let backendCalls = await client.sampleCount
            XCTAssertEqual(backendCalls, 1)

            await client.releaseSample()
            await startup.value
            XCTAssertEqual(context.store.connectionState, .ready)
            XCTAssertEqual(context.store.currentTPS, 42)
            XCTAssertEqual(context.store.backendGPUActivity?.activityPercent, 35)
            await context.close()
            XCTAssertNil(context.store.backendGPUActivity)
            XCTAssertNil(context.store.backendKind)
        } catch {
            await context.close()
            await startup.value
            throw error
        }
    }

    /// Explicitly enabled validation of the installed app's complete read-only
    /// process resolution and IOKit path. This never sends a generation request.
    func testLiveLocalOllamaGPUCountersWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLUXLLM_GPU_LIVE"] == "1" else {
            throw XCTSkip("Set FLUXLLM_GPU_LIVE=1 to read an already running local Ollama worker.")
        }
        let monitor = LocalBackendGPUMonitor()
        let configuration = BackendConfiguration(
            kind: .ollama, baseURL: URL(string: "http://127.0.0.1:11434")!)
        _ = await monitor.sample(configuration)
        try await Task.sleep(for: .milliseconds(1_100))
        var sample = await monitor.sample(configuration)
        if sample.activityPercent == nil {
            // Permit one extra baseline interval if the worker's GPU client
            // changed during the first pair of registry snapshots.
            try await Task.sleep(for: .milliseconds(1_100))
            sample = await monitor.sample(configuration)
        }
        let activity = try XCTUnwrap(
            sample.activityPercent,
            "Live GPU sample unavailable: \(sample.unavailableReason ?? "unspecified reason")")
        XCTAssertTrue(activity.isFinite)
        XCTAssertGreaterThanOrEqual(activity, 0)
        XCTAssertFalse(sample.processIDs.isEmpty)
        XCTAssertFalse(sample.source.isEmpty)
        if let expected = environment["FLUXLLM_GPU_EXPECTED_PID"] {
            let pid = try XCTUnwrap(Int32(expected), "FLUXLLM_GPU_EXPECTED_PID must be a valid PID")
            XCTAssertTrue(
                sample.processIDs.contains(pid),
                "Expected worker \(pid), sampled \(sample.processIDs)")
        }
        let millisecondsPerSecond = String(format: "%.1f", activity * 10)
        print(
            "FluxLLM live GPU validation: PIDs \(sample.processIDs), "
                + "\(millisecondsPerSecond) ms/s GPU execution, source: \(sample.source)")
        await monitor.reset()
    }

    private func gpuSample(_ value: Double, at timestamp: Date) -> GPUActivitySample {
        GPUActivitySample(timestamp: timestamp, activityPercent: value, processIDs: [101])
    }

    private func systemSample(_ value: Double, at timestamp: Date) -> GPUActivitySample {
        GPUActivitySample(
            timestamp: timestamp, activityPercent: value,
            source: "macOS system GPU utilization", scope: .system)
    }

    private func makeContext(
        gpu: GPUControlledMonitor,
        client: GPUControlledBackendClient = GPUControlledBackendClient()
    ) throws -> GPULifecycleContext {
        let suite = "com.cmorgan.FluxLLM.gpu-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.backendSelection = .vllm
        let store = MetricsStore()
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store, client: client, gpuMonitor: gpu,
            pollInterval: .seconds(60), discoveryInterval: .seconds(60),
            gpuInterval: .milliseconds(1))
        return GPULifecycleContext(
            settings: settings, store: store, coordinator: coordinator,
            gpu: gpu, client: client, defaults: defaults, suite: suite)
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("GPU monitoring did not reach the expected lifecycle boundary")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor GPUFixtureResolver: BackendProcessResolving {
    private var selection: GPUProcessSelection
    private(set) var configurations: [BackendConfiguration] = []
    private(set) var resetCount = 0

    init(selection: GPUProcessSelection) { self.selection = selection }

    func setSelection(_ selection: GPUProcessSelection) { self.selection = selection }

    func resolve(_ configuration: BackendConfiguration) async -> GPUProcessSelection {
        configurations.append(configuration)
        return selection
    }

    func reset() async { resetCount += 1 }
}

private actor GPUFixtureSampler: GPUActivitySampling {
    private let result: GPUActivitySample
    private(set) var processSelections: [Set<GPUProcessIdentity>] = []
    private(set) var resetCount = 0

    init(result: GPUActivitySample) { self.result = result }

    func sample(processes: Set<GPUProcessIdentity>) async -> GPUActivitySample {
        processSelections.append(processes)
        return result
    }

    func reset() async { resetCount += 1 }
}

/// Deliberately ignores cancellation while held, like a platform callback that
/// was already in flight. The coordinator must reject its result explicitly.
private actor GPUControlledMonitor: BackendGPUMonitoring {
    private let scope: GPUActivityScope
    private var holdSecondSample: Bool
    private var holdSecondReset: Bool
    private var sampleContinuation: CheckedContinuation<GPUActivitySample, Never>?
    private var resetContinuation: CheckedContinuation<Void, Never>?
    private(set) var sampleCount = 0
    private(set) var resetCount = 0
    var waitingForSample: Bool { sampleContinuation != nil }
    var waitingForReset: Bool { resetContinuation != nil }

    init(
        holdSecondSample: Bool = false, holdSecondReset: Bool = false,
        scope: GPUActivityScope = .backendProcesses
    ) {
        self.holdSecondSample = holdSecondSample
        self.holdSecondReset = holdSecondReset
        self.scope = scope
    }

    func sample(_ configuration: BackendConfiguration?) async -> GPUActivitySample {
        sampleCount += 1
        if sampleCount == 2, holdSecondSample {
            return await withCheckedContinuation { sampleContinuation = $0 }
        }
        return GPUActivitySample(
            activityPercent: configuration?.kind == .vllm ? 35 : 55,
            processIDs: scope == .system ? [] : [101],
            source: scope == .system
                ? "macOS system GPU utilization" : "macOS per-process GPU time",
            scope: scope)
    }

    func reset() async {
        resetCount += 1
        if resetCount == 2, holdSecondReset {
            await withCheckedContinuation { resetContinuation = $0 }
        }
    }

    func releaseSample(value: Double = 999) {
        holdSecondSample = false
        let continuation = sampleContinuation
        sampleContinuation = nil
        continuation?.resume(
            returning: GPUActivitySample(activityPercent: value, processIDs: [101]))
    }

    func releaseReset() {
        holdSecondReset = false
        let continuation = resetContinuation
        resetContinuation = nil
        continuation?.resume()
    }

    func releaseAll() {
        releaseSample()
        releaseReset()
    }
}

private actor GPUControlledBackendClient: BackendClientProtocol {
    private var holdFirstSample: Bool
    private var sampleContinuation: CheckedContinuation<Void, Never>?
    private(set) var sampleCount = 0
    var waitingForSample: Bool { sampleContinuation != nil }

    init(holdFirstSample: Bool = false) { self.holdFirstSample = holdFirstSample }

    func detect(at baseURL: URL) async throws -> DetectedBackend? { nil }

    func sample(_ configuration: BackendConfiguration) async throws -> BackendSample {
        sampleCount += 1
        if sampleCount == 1, holdFirstSample {
            await withCheckedContinuation { sampleContinuation = $0 }
        }
        return BackendSample(kind: configuration.kind, currentTPS: 42, runningRequests: 1)
    }

    func releaseSample() {
        holdFirstSample = false
        let continuation = sampleContinuation
        sampleContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private struct GPULifecycleContext {
    let settings: AppSettings
    let store: MetricsStore
    let coordinator: MonitoringCoordinator
    let gpu: GPUControlledMonitor
    let client: GPUControlledBackendClient
    let defaults: UserDefaults
    let suite: String

    func close() async {
        await gpu.releaseAll()
        await client.releaseSample()
        await coordinator.stop()
        defaults.removePersistentDomain(forName: suite)
    }
}
