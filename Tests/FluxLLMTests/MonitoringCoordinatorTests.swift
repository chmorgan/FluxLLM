import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class MonitoringCoordinatorTests: XCTestCase {
    func testAutomaticSelectsUniqueNativeBackendWithoutStartingProxy() async throws {
        let context = try makeContext(detections: [.vllm])
        await context.coordinator.start()
        XCTAssertEqual(context.store.backendKind, .vllm)
        XCTAssertEqual(context.store.connectionState, .ready)
        XCTAssertEqual(context.store.currentTPS, 42)
        XCTAssertTrue(context.proxies.instances.isEmpty)
        XCTAssertEqual(
            context.settings.lastAutomaticBackendID,
            "vllm|http://127.0.0.1:8000")
        await context.close()
    }

    func testAmbiguousAutomaticSelectionRequiresSettingsUnlessLastChoiceStillExists() async throws {
        let context = try makeContext(detections: [.ollama, .vllm])
        await context.coordinator.start()
        XCTAssertNil(context.store.backendKind)
        XCTAssertEqual(context.store.connectionState, .needsConfiguration)
        XCTAssertTrue(context.proxies.instances.isEmpty)
        context.settings.lastAutomaticBackendID = "vllm|http://127.0.0.1:8000"
        try await context.coordinator.applySettings()
        XCTAssertEqual(context.store.backendKind, .vllm)
        XCTAssertTrue(context.proxies.instances.isEmpty)
        await context.close()
    }

    func testNoDetectionsProducesConfigurationStateWithoutOpeningListener() async throws {
        let context = try makeContext(detections: [])
        await context.coordinator.start()
        XCTAssertNil(context.coordinator.selectedConfiguration)
        XCTAssertEqual(context.store.connectionState, .needsConfiguration)
        XCTAssertTrue(context.proxies.instances.isEmpty)
        await context.close()
    }

    func testManualChoiceIsPreservedAndOtherDetectedBackendIsDisclosed() async throws {
        let context = try makeContext(detections: [.ollama, .vllm])
        context.settings.backendSelection = .ollama
        await context.coordinator.start()
        XCTAssertEqual(context.store.backendKind, .ollama)
        XCTAssertEqual(context.settings.backendSelection, .ollama)
        XCTAssertTrue(context.store.selectionNotice?.contains("vLLM") == true)
        XCTAssertEqual(context.proxies.instances.count, 1)
        XCTAssertEqual(context.proxies.instances.first?.starts, 1)
        await context.coordinator.rescan()
        XCTAssertEqual(
            context.proxies.instances.first?.starts, 1, "Rescan must not restart an active proxy")
        await context.close()
    }

    func testManualEndpointFingerprintMismatchDoesNotStartProxy() async throws {
        let context = try makeContext(detections: [.vllm])
        context.settings.backendSelection = .ollama
        context.settings.ollamaPort = 8000
        await context.coordinator.start()
        XCTAssertEqual(context.store.connectionState, .needsConfiguration)
        XCTAssertTrue(context.store.connectionMessage?.contains("vLLM") == true)
        XCTAssertTrue(context.proxies.instances.isEmpty)
        await context.close()
    }

    func testLeavingOllamaAwaitsProxyShutdownAndRejectsOldRequestEvents() async throws {
        let context = try makeContext(detections: [.ollama, .vllm])
        context.settings.backendSelection = .ollama
        await context.coordinator.start()
        let oldEpoch = context.store.monitoringEpoch
        let proxy = try XCTUnwrap(context.proxies.instances.first)
        proxy.holdStop = true
        context.settings.backendSelection = .vllm
        let applying = Task { try await context.coordinator.applySettings() }
        try await eventually { proxy.stopContinuation != nil }
        XCTAssertEqual(context.store.backendKind, .ollama)
        proxy.releaseStop()
        try await applying.value
        XCTAssertEqual(proxy.stops, 1)
        XCTAssertEqual(context.store.backendKind, .vllm)
        context.store.apply(.began(GenerationRequest(model: "late-ollama")), epoch: oldEpoch)
        XCTAssertNil(context.store.activeGeneration)
        XCTAssertEqual(context.store.currentTPS, 42)
        XCTAssertEqual(context.proxies.instances.count, 1)
        context.settings.backendSelection = .ollama
        try await context.coordinator.applySettings()
        XCTAssertEqual(context.proxies.instances.count, 2)
        context.store.apply(
            .began(GenerationRequest(model: "stale-first-session")), epoch: oldEpoch)
        XCTAssertNil(
            context.store.activeGeneration,
            "Returning to Ollama must not reopen the previous session")
        let resets = await context.client.resetCount
        XCTAssertEqual(resets, 3, "Each collection session starts with fresh counter baselines")
        await context.close()
    }

    func testQuitDuringProxyStartCannotPublishReadyOrLeaveListenerRunning() async throws {
        let context = try makeContext(detections: [.ollama])
        context.settings.backendSelection = .ollama
        context.proxies.holdStart = true
        let startup = Task { await context.coordinator.start() }
        try await eventually { context.proxies.instances.first?.startContinuation != nil }
        let proxy = try XCTUnwrap(context.proxies.instances.first)
        let stopping = Task { await context.coordinator.stop() }
        await Task.yield()
        proxy.releaseStart()
        await startup.value
        await stopping.value
        XCTAssertEqual(proxy.stops, 1)
        XCTAssertNil(context.coordinator.selectedConfiguration)
        XCTAssertNil(context.store.backendKind)
        context.removeDefaults()
    }

    func testDetectionIsBoundedAndCoalescesDefaultPortAndLocalhostAliases() throws {
        let context = try makeContext(detections: [])
        XCTAssertEqual(context.coordinator.detectionURLs().count, 3)
        context.settings.backendEndpoints[.vllm] = "https://inference.example/service"
        let urls = context.coordinator.detectionURLs()
        XCTAssertEqual(urls.count, 4)
        XCTAssertTrue(urls.contains { $0.absoluteString == "https://inference.example/service" })
        context.removeDefaults()
    }

    private func makeContext(detections: [BackendKind]) throws -> CoordinatorContext {
        let suite = "com.cmorgan.FluxLLM.coordinator-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        let store = MetricsStore()
        let proxies = ProxyRecorder()
        let client = FixtureBackendClient(detections: detections)
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store, client: client,
            gpuMonitor: UnavailableBackendGPUMonitor(),
            proxyFactory: { _, _ in proxies.makeProxy() },
            pollInterval: .seconds(60), discoveryInterval: .seconds(60))
        return CoordinatorContext(
            settings: settings, store: store, proxies: proxies,
            coordinator: coordinator, client: client, defaults: defaults, suite: suite)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Coordinator did not reach the expected lifecycle point")
                throw CancellationError()
            }
            await Task.yield()
        }
    }
}

private actor FixtureBackendClient: BackendClientProtocol {
    let detections: [DetectedBackend]
    private(set) var resetCount = 0

    init(detections: [BackendKind]) {
        self.detections = detections.map {
            DetectedBackend(kind: $0, baseURL: URL(string: $0.defaultEndpoint)!)
        }
    }

    func detect(at baseURL: URL) async throws -> DetectedBackend? {
        detections.first { $0.baseURL.port == baseURL.port }
    }

    func sample(_ configuration: BackendConfiguration) async throws -> BackendSample {
        BackendSample(
            kind: configuration.kind, model: "fixture", currentTPS: 42,
            runningRequests: configuration.kind == .ollama ? nil : 1)
    }

    func reset() { resetCount += 1 }
}

@MainActor
private final class ProxyRecorder {
    var instances: [FixtureMonitoringProxy] = []
    var holdStart = false

    func makeProxy() -> FixtureMonitoringProxy {
        let proxy = FixtureMonitoringProxy()
        proxy.holdStart = holdStart
        instances.append(proxy)
        return proxy
    }
}

@MainActor
private final class FixtureMonitoringProxy: MonitoringProxy {
    var starts = 0
    var stops = 0
    var holdStart = false
    var holdStop = false
    var startContinuation: CheckedContinuation<Void, Never>?
    var stopContinuation: CheckedContinuation<Void, Never>?

    func start() async throws {
        starts += 1
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
    }
    func stop() async {
        stops += 1
        if holdStop { await withCheckedContinuation { stopContinuation = $0 } }
    }
    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
        holdStart = false
    }
    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
        holdStop = false
    }
}

@MainActor
private struct CoordinatorContext {
    let settings: AppSettings
    let store: MetricsStore
    let proxies: ProxyRecorder
    let coordinator: MonitoringCoordinator
    let client: FixtureBackendClient
    let defaults: UserDefaults
    let suite: String

    func close() async {
        await coordinator.stop()
        removeDefaults()
    }
    func removeDefaults() { defaults.removePersistentDomain(forName: suite) }
}
