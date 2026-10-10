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

    func testUnchangedOllamaApplyPreservesActiveRequestAndProxy() async throws {
        let context = try makeContext(detections: [.ollama])
        context.settings.backendSelection = .ollama
        await context.coordinator.start()
        let epoch = context.store.monitoringEpoch
        let request = GenerationRequest(model: "ongoing")
        context.store.apply(.began(request), epoch: epoch)
        context.store.sample(at: request.startedAt)
        let history = context.store.tpsHistory
        let proxy = try XCTUnwrap(context.proxies.instances.first)

        try await context.coordinator.applySettings()

        XCTAssertEqual(context.store.monitoringEpoch, epoch)
        XCTAssertEqual(context.store.activeGeneration?.id, request.id)
        XCTAssertTrue(context.store.isBackendActive)
        XCTAssertEqual(context.store.requestLanes.map(\.id), [request.id])
        XCTAssertEqual(context.store.tpsHistory, history)
        XCTAssertEqual(proxy.starts, 1)
        XCTAssertEqual(proxy.stops, 0)
        let resets = await context.client.resetCount
        XCTAssertEqual(resets, 1)
        await context.close()
    }

    func testUnchangedAutomaticApplyPreservesHistoryAndRecoversWithoutRediscovery() async throws {
        let context = try makeContext(detections: [.vllm], pollInterval: .milliseconds(10))
        await context.coordinator.start()
        context.store.sample()
        let epoch = context.store.monitoringEpoch
        let history = context.store.tpsHistory
        await context.client.setDetections([])
        context.store.updateConnection(.unavailable, message: "Temporary connection loss")

        try await context.coordinator.applySettings()

        XCTAssertEqual(context.store.monitoringEpoch, epoch)
        XCTAssertEqual(context.store.tpsHistory, history)
        XCTAssertEqual(context.coordinator.selectedConfiguration?.kind, .vllm)
        try await eventually { context.store.connectionState == .ready }
        XCTAssertEqual(context.store.monitoringEpoch, epoch)
        let resets = await context.client.resetCount
        XCTAssertEqual(resets, 1)
        await context.close()
    }

    func testEquivalentNativeEndpointAndUnrelatedSettingsDoNotRestartCollector() async throws {
        let context = try makeContext(detections: [.vllm])
        context.settings.backendSelection = .vllm
        await context.coordinator.start()
        let epoch = context.store.monitoringEpoch
        context.settings.backendEndpoints[.vllm] = " HTTP://LOCALHOST:8000/ "
        context.settings.proxyPort = 12035
        context.settings.llamaCppModel = "unused-model"
        context.settings.showMenuBarLogo.toggle()

        try await context.coordinator.applySettings()

        XCTAssertEqual(context.store.monitoringEpoch, epoch)
        let resets = await context.client.resetCount
        XCTAssertEqual(resets, 1)
        await context.close()
    }

    func testAutomaticFailedDiscoveryPreservesOnlyUnchangedActiveTarget() async throws {
        let context = try makeContext(detections: [.vllm], pollInterval: .milliseconds(10))
        await context.coordinator.start()
        context.store.sample()
        let epoch = context.store.monitoringEpoch
        let history = context.store.tpsHistory
        context.settings.llamaCppModel = "unused-model"
        context.settings.proxyPort = 12035
        await context.client.setDetections([])
        context.store.updateConnection(.unavailable, message: "Temporary connection loss")

        try await context.coordinator.applySettings()

        XCTAssertTrue(context.store.detectedBackends.isEmpty)
        XCTAssertEqual(context.store.monitoringEpoch, epoch)
        XCTAssertEqual(context.store.tpsHistory, history)
        XCTAssertEqual(context.coordinator.selectedConfiguration?.kind, .vllm)
        try await eventually { context.store.connectionState == .ready }
        XCTAssertEqual(context.store.monitoringEpoch, epoch)
        let resets = await context.client.resetCount
        XCTAssertEqual(resets, 1)

        context.settings.backendEndpoints[.vllm] = "http://127.0.0.1:9001"
        try await context.coordinator.applySettings()
        XCTAssertNotEqual(context.store.monitoringEpoch, epoch)
        XCTAssertNil(context.coordinator.selectedConfiguration)
        XCTAssertEqual(context.store.connectionState, .needsConfiguration)
        let changedResets = await context.client.resetCount
        XCTAssertEqual(changedResets, 2)
        await context.close()
    }

    func testChangedNativeEndpointRestartsAndRejectsOldSamples() async throws {
        let context = try makeContext(detections: [.vllm])
        context.settings.backendSelection = .vllm
        await context.coordinator.start()
        let epoch = context.store.monitoringEpoch
        context.settings.backendEndpoints[.vllm] = "http://127.0.0.1:9001"

        try await context.coordinator.applySettings()

        XCTAssertNotEqual(context.store.monitoringEpoch, epoch)
        XCTAssertEqual(context.coordinator.selectedConfiguration?.baseURL.port, 9001)
        context.store.applyBackendSample(BackendSample(kind: .vllm, currentTPS: 999), epoch: epoch)
        XCTAssertEqual(context.store.currentTPS, 42)
        let resets = await context.client.resetCount
        XCTAssertEqual(resets, 2)
        await context.close()
    }

    func testChangingLlamaModelAndOllamaProxyPortRestartsTheirCollectors() async throws {
        let native = try makeContext(detections: [.llamaCpp])
        native.settings.backendSelection = .llamaCpp
        await native.coordinator.start()
        let nativeEpoch = native.store.monitoringEpoch
        native.settings.llamaCppModel = "new-model"
        try await native.coordinator.applySettings()
        XCTAssertNotEqual(native.store.monitoringEpoch, nativeEpoch)
        XCTAssertEqual(native.coordinator.selectedConfiguration?.model, "new-model")
        let nativeResets = await native.client.resetCount
        XCTAssertEqual(nativeResets, 2)
        await native.close()

        let ollama = try makeContext(detections: [.ollama])
        ollama.settings.backendSelection = .ollama
        await ollama.coordinator.start()
        let ollamaEpoch = ollama.store.monitoringEpoch
        let oldProxy = try XCTUnwrap(ollama.proxies.instances.first)
        ollama.settings.proxyPort = 12035
        try await ollama.coordinator.applySettings()
        XCTAssertNotEqual(ollama.store.monitoringEpoch, ollamaEpoch)
        XCTAssertEqual(oldProxy.stops, 1)
        XCTAssertEqual(ollama.proxies.instances.count, 2)
        XCTAssertEqual(ollama.coordinator.selectedConfiguration?.proxyPort, 12035)
        await ollama.close()
    }

    func testApplyUsesCapturedDraftWhileDiscoveryIsSuspended() async throws {
        let context = try makeContext(detections: [.ollama, .vllm])
        context.settings.backendSelection = .ollama
        await context.coordinator.start()
        let proxy = try XCTUnwrap(context.proxies.instances.first)
        context.settings.backendSelection = .vllm
        await context.client.holdNextDiscovery()
        let applying = Task { try await context.coordinator.applySettings() }
        try await eventually { await context.client.isDiscoveryHeld }
        XCTAssertEqual(proxy.stops, 0)
        context.settings.backendSelection = .llamaCpp
        context.settings.backendEndpoints[.vllm] = "http://127.0.0.1:9001"
        await context.client.releaseDiscovery()
        try await applying.value

        XCTAssertEqual(context.coordinator.selectedConfiguration?.kind, .vllm)
        XCTAssertEqual(context.coordinator.selectedConfiguration?.baseURL.port, 8000)
        XCTAssertEqual(proxy.stops, 1)
        await context.close()
    }

    func testSupersededApplyDuringDiscoveryKeepsOriginalCollector() async throws {
        let context = try makeContext(detections: [.ollama, .vllm])
        context.settings.backendSelection = .ollama
        await context.coordinator.start()
        let epoch = context.store.monitoringEpoch
        let proxy = try XCTUnwrap(context.proxies.instances.first)
        context.settings.backendSelection = .vllm
        await context.client.holdNextDiscovery()
        let first = Task { try await context.coordinator.applySettings() }
        try await eventually { await context.client.isDiscoveryHeld }
        context.settings.backendSelection = .ollama
        var latestStarted = false
        let latest = Task { @MainActor in
            latestStarted = true
            try await context.coordinator.applySettings()
        }
        try await eventually { latestStarted }
        await context.client.releaseDiscovery()
        do {
            try await first.value
            XCTFail("The superseded Apply must be cancelled")
        } catch is CancellationError {}
        try await latest.value

        XCTAssertEqual(context.store.monitoringEpoch, epoch)
        XCTAssertEqual(context.coordinator.selectedConfiguration?.kind, .ollama)
        XCTAssertEqual(proxy.stops, 0)
        XCTAssertEqual(proxy.starts, 1)
        XCTAssertFalse(context.coordinator.isApplying)
        let resets = await context.client.resetCount
        XCTAssertEqual(resets, 1)
        await context.close()
    }

    func testShutdownDuringApplyDiscoveryCannotPublishNewSession() async throws {
        let context = try makeContext(detections: [.ollama, .vllm])
        context.settings.backendSelection = .ollama
        await context.coordinator.start()
        let proxy = try XCTUnwrap(context.proxies.instances.first)
        context.settings.backendSelection = .vllm
        await context.client.holdNextDiscovery()
        let applying = Task { try await context.coordinator.applySettings() }
        try await eventually { await context.client.isDiscoveryHeld }
        var shutdownStarted = false
        let stopping = Task { @MainActor in
            shutdownStarted = true
            await context.coordinator.stop()
        }
        try await eventually { shutdownStarted }
        await context.client.releaseDiscovery()
        do {
            try await applying.value
            XCTFail("Shutdown must cancel Apply")
        } catch is CancellationError {}
        await stopping.value

        XCTAssertNil(context.coordinator.selectedConfiguration)
        XCTAssertNil(context.store.backendKind)
        XCTAssertEqual(proxy.stops, 1)
        let resets = await context.client.resetCount
        XCTAssertEqual(resets, 1)
        context.removeDefaults()
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
        XCTAssertEqual(context.coordinator.detectionURLs().count, 4)
        context.settings.backendEndpoints[.vllm] = "https://inference.example/service"
        let urls = context.coordinator.detectionURLs()
        XCTAssertEqual(urls.count, 5)
        XCTAssertTrue(urls.contains { $0.absoluteString == "https://inference.example/service" })
        context.removeDefaults()
    }

    private func makeContext(
        detections: [BackendKind], pollInterval: Duration = .seconds(60)
    ) throws -> CoordinatorContext {
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
            pollInterval: pollInterval, discoveryInterval: .seconds(60))
        return CoordinatorContext(
            settings: settings, store: store, proxies: proxies,
            coordinator: coordinator, client: client, defaults: defaults, suite: suite)
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Coordinator did not reach the expected lifecycle point")
                throw CancellationError()
            }
            await Task.yield()
        }
    }
}

private actor FixtureBackendClient: BackendClientProtocol {
    private var detections: [DetectedBackend]
    private(set) var resetCount = 0
    private var holdDiscovery = false
    private var discoveryContinuation: CheckedContinuation<Void, Never>?
    var isDiscoveryHeld: Bool { discoveryContinuation != nil }

    init(detections: [BackendKind]) {
        self.detections = detections.map {
            DetectedBackend(kind: $0, baseURL: URL(string: $0.defaultEndpoint)!)
        }
    }

    func detect(at baseURL: URL) async throws -> DetectedBackend? {
        detections.first { $0.baseURL.port == baseURL.port }
    }

    func setDetections(_ kinds: [BackendKind]) {
        detections = kinds.map {
            DetectedBackend(kind: $0, baseURL: URL(string: $0.defaultEndpoint)!)
        }
    }

    func holdNextDiscovery() { holdDiscovery = true }

    func discoverLocalBackends(configurations: [BackendConfiguration]) async -> [DetectedBackend] {
        if holdDiscovery {
            holdDiscovery = false
            await withCheckedContinuation { discoveryContinuation = $0 }
        }
        return []
    }

    func releaseDiscovery() {
        discoveryContinuation?.resume()
        discoveryContinuation = nil
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
