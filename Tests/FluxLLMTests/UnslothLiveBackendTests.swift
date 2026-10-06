import Darwin
import Foundation
import XCTest

@testable import FluxLLM

/// Opt-in, read-only verification against an already running managed Studio.
/// It neither generates text nor changes Studio, app settings, or model state.
@MainActor
final class UnslothLiveBackendTests: XCTestCase {
    func testRunningStudioDiscoveryAndNativeMonitoring() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLUXLLM_UNSLOTH_LIVE"] == "1" else {
            throw XCTSkip(
                "Set FLUXLLM_UNSLOTH_LIVE=1 to observe an already running Unsloth GGUF worker.")
        }
        let url = try AppSettings.endpointURL(
            environment["FLUXLLM_UNSLOTH_STUDIO_URL"] ?? BackendKind.unsloth.defaultEndpoint)
        try AppSettings.validateUnslothEndpoint(url)
        let discovery = UnslothProcessDiscovery()
        let coldStart = Date()
        let servers = await discovery.servers()
        let coldMilliseconds = Date().timeIntervalSince(coldStart) * 1_000
        let server = try XCTUnwrap(servers.first { $0.studioURL.port == url.port })
        let worker = try XCTUnwrap(
            server.workerURL, "Load a GGUF model in Unsloth before running this check.")
        let workerIdentity = try XCTUnwrap(server.workerIdentity)
        XCTAssertGreaterThan(server.studioIdentity.startTimeMicroseconds, 0)
        XCTAssertGreaterThan(workerIdentity.startTimeMicroseconds, 0)
        XCTAssertNotEqual(server.studioIdentity.pid, workerIdentity.pid)

        let cpuStart = processCPUSeconds()
        let warmStart = Date()
        for _ in 0..<100 {
            let cached = await discovery.servers()
            XCTAssertTrue(cached.contains { $0.studioIdentity == server.studioIdentity })
        }
        let warmMilliseconds = Date().timeIntervalSince(warmStart) * 1_000
        let warmCPUMilliseconds = (processCPUSeconds() - cpuStart) * 1_000

        let client = UnslothBackendClient(discovery: discovery)
        let detections = await client.discoverLocalBackends()
        XCTAssertTrue(detections.contains { $0.kind == .unsloth && $0.baseURL == server.studioURL })
        let sample = try await client.sample(BackendConfiguration(kind: .unsloth, baseURL: url))
        XCTAssertEqual(sample.kind, .unsloth)
        XCTAssertEqual(sample.basis, .serverReportedAverage)
        XCTAssertNotNil(sample.model)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sample.runningRequests), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sample.outputTokens), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sample.promptTokens), 0)
        XCTAssertNil(sample.inferenceGPUPercent)

        let suite = "com.cmorgan.FluxLLM.unsloth-live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.backendSelection = .unsloth
        settings.backendEndpoints[.unsloth] = url.absoluteString
        let store = MetricsStore()
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store, client: client,
            gpuMonitor: UnavailableBackendGPUMonitor(),
            proxyFactory: { _, _ in
                XCTFail("Unsloth must be observed without starting a client proxy")
                return LiveUnexpectedUnslothProxy()
            }, pollInterval: .seconds(60), discoveryInterval: .seconds(60))
        await coordinator.start()
        let ready = store.connectionState == .ready
        let message = store.connectionMessage
        let source = store.historySource
        await coordinator.stop()
        XCTAssertTrue(ready, message ?? "The native Unsloth session did not become ready")
        XCTAssertEqual(source, "unsloth|\(url.absoluteString)|")
        XCTAssertNil(defaults.data(forKey: "appSettings"))

        if let output = environment["FLUXLLM_UNSLOTH_LIVE_OUTPUT"] {
            let record: [String: Any] = [
                "status": ready ? "passed" : "failed", "read_only": true,
                "studio_url": server.studioURL.absoluteString, "worker_url": worker.absoluteString,
                "studio_pid": server.studioIdentity.pid, "worker_pid": workerIdentity.pid,
                "model": sample.model ?? "", "running_requests": sample.runningRequests ?? -1,
                "queued_requests": sample.queuedRequests ?? -1,
                "output_tokens": sample.outputTokens ?? -1,
                "prompt_tokens": sample.promptTokens ?? -1,
                "throughput_basis": sample.basis.rawValue, "ready": ready,
                "discovery_cold_wall_ms": coldMilliseconds, "discovery_warm_calls": 100,
                "discovery_warm_wall_ms": warmMilliseconds,
                "discovery_warm_process_cpu_ms": warmCPUMilliseconds,
                "measurement_scope":
                    "Discovery timings cover only these calls; they are not whole-app CPU/GPU utilization.",
            ]
            let destination = URL(fileURLWithPath: output)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            try JSONSerialization.data(
                withJSONObject: record, options: [.prettyPrinted, .sortedKeys]
            )
            .write(to: destination, options: .withoutOverwriting)
        }
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}

@MainActor
private final class LiveUnexpectedUnslothProxy: MonitoringProxy {
    func start() async throws { XCTFail("A native backend must never start a proxy") }
    func stop() async {}
}
