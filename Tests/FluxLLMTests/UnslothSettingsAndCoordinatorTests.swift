import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class UnslothSettingsAndCoordinatorTests: XCTestCase {
    func testUnslothUsesStableStudioAddressAndDoesNotWritePreferences() throws {
        try withSettings { settings, defaults in
            settings.backendSelection = .unsloth
            let configuration = try settings.configuration(for: .unsloth)
            XCTAssertEqual(configuration.kind, .unsloth)
            XCTAssertEqual(configuration.baseURL.absoluteString, "http://127.0.0.1:8888")
            XCTAssertNil(configuration.model)
            settings.backendEndpoints[.unsloth] = "http://localhost:9000/"
            XCTAssertEqual(
                try settings.configuration(for: .unsloth).baseURL.absoluteString,
                "http://localhost:9000")
            XCTAssertNil(defaults.data(forKey: "appSettings"))
        }
    }

    func testStudioMonitorTokenIsOptionalSessionOnlyAndScopedToUnsloth() throws {
        try withSettings { settings, defaults in
            XCTAssertNil(settings.unslothMonitorToken)
            XCTAssertNil(try settings.configuration(for: .unsloth).studioMonitorToken)
            settings.unslothMonitorToken = "  fixture-monitor-token\n"
            XCTAssertEqual(
                try settings.configuration(for: .unsloth).studioMonitorToken,
                "fixture-monitor-token")
            for kind in BackendKind.allCases where kind != .unsloth {
                XCTAssertNil(try settings.configuration(for: kind).studioMonitorToken)
            }
            XCTAssertNil(defaults.data(forKey: "appSettings"))
            XCTAssertNil(AppSettings(defaults: defaults).unslothMonitorToken)
            settings.unslothMonitorToken = " \n "
            XCTAssertNil(try settings.configuration(for: .unsloth).studioMonitorToken)
        }
    }

    func testWorkerAPIKeyIsOptionalSessionOnlyAndSeparateFromStudioToken() throws {
        try withSettings { settings, defaults in
            XCTAssertNil(settings.unslothWorkerAPIKey)
            XCTAssertNil(try settings.configuration(for: .unsloth).workerAPIKey)
            settings.unslothWorkerAPIKey = "  fixture-worker-key\n"
            settings.unslothMonitorToken = "fixture-monitor-token"
            let configuration = try settings.configuration(for: .unsloth)
            XCTAssertEqual(configuration.workerAPIKey, "fixture-worker-key")
            XCTAssertEqual(configuration.studioMonitorToken, "fixture-monitor-token")
            for kind in BackendKind.allCases where kind != .unsloth {
                XCTAssertNil(try settings.configuration(for: kind).workerAPIKey)
                XCTAssertNil(try settings.configuration(for: kind).studioMonitorToken)
            }
            XCTAssertNil(defaults.data(forKey: "appSettings"))
            XCTAssertNil(AppSettings(defaults: defaults).unslothWorkerAPIKey)
            settings.unslothWorkerAPIKey = " \n "
            XCTAssertNil(try settings.configuration(for: .unsloth).workerAPIKey)
        }
    }

    func testWorkerAPIKeyIsNeverRestoredFromOrWrittenToSavedPreferences() throws {
        try withSettings { _, defaults in
            let saved = Data(
                """
                {"proxyPort":12035,"ollamaHost":"localhost","ollamaPort":11499,
                 "autoStartProxy":false,"unslothWorkerAPIKey":"saved-worker-key",
                 "unslothMonitorToken":"saved-monitor-token"}
                """.utf8)
            defaults.set(saved, forKey: "appSettings")
            let settings = AppSettings(defaults: defaults)
            XCTAssertNil(settings.unslothWorkerAPIKey)
            XCTAssertNil(settings.unslothMonitorToken)
            settings.unslothWorkerAPIKey = "session-worker-key"
            settings.unslothMonitorToken = "session-monitor-token"
            _ = try settings.configuration(for: .unsloth)
            XCTAssertEqual(defaults.data(forKey: "appSettings"), saved)
            let nextSession = AppSettings(defaults: defaults)
            XCTAssertNil(nextSession.unslothWorkerAPIKey)
            XCTAssertNil(nextSession.unslothMonitorToken)
        }
    }

    func testApplyingUnslothCredentialsPreservesManualBackendSettingsAndSavedPreferences() throws {
        for selection in [BackendSelection.vllm, .ollama] {
            try withSettings { settings, defaults in
                let saved = Data(
                    """
                    {"proxyPort":12035,"ollamaHost":"localhost","ollamaPort":11499,
                     "autoStartProxy":false}
                    """.utf8)
                defaults.set(saved, forKey: "appSettings")
                settings.backendSelection = selection
                settings.backendEndpoints[.vllm] = "http://localhost:9001"
                settings.backendEndpoints[.unsloth] = "http://localhost:9000"
                settings.ollamaHost = "127.0.0.1"
                settings.ollamaPort = 12034
                settings.proxyPort = 12035
                settings.llamaCppModel = "unchanged-model"
                let endpoints = settings.backendEndpoints

                try settings.applyUnslothCredentials(
                    workerAPIKey: " \tfixture-worker-key\r\n",
                    monitorToken: " \tfixture-monitor-token\r\n")

                XCTAssertEqual(settings.unslothWorkerAPIKey, "fixture-worker-key")
                XCTAssertEqual(settings.unslothMonitorToken, "fixture-monitor-token")
                XCTAssertEqual(settings.backendSelection, selection)
                XCTAssertEqual(settings.backendEndpoints, endpoints)
                XCTAssertEqual(settings.ollamaHost, "127.0.0.1")
                XCTAssertEqual(settings.ollamaPort, 12034)
                XCTAssertEqual(settings.proxyPort, 12035)
                XCTAssertEqual(settings.llamaCppModel, "unchanged-model")
                XCTAssertEqual(defaults.data(forKey: "appSettings"), saved)
                let nextSession = AppSettings(defaults: defaults)
                XCTAssertNil(nextSession.unslothWorkerAPIKey)
                XCTAssertNil(nextSession.unslothMonitorToken)
                let selected = try settings.configuration(for: XCTUnwrap(selection.kind))
                XCTAssertNil(selected.workerAPIKey)
                XCTAssertNil(selected.studioMonitorToken)
                let unsloth = try settings.configuration(for: .unsloth)
                XCTAssertEqual(unsloth.workerAPIKey, "fixture-worker-key")
                XCTAssertEqual(unsloth.studioMonitorToken, "fixture-monitor-token")
            }
        }
    }

    func testApplyingBlankUnslothCredentialsRestoresAutomaticWorkerAuthentication() throws {
        try withSettings { settings, defaults in
            settings.backendSelection = .vllm
            settings.unslothWorkerAPIKey = "existing-worker-key"
            settings.unslothMonitorToken = "existing-monitor-token"
            try settings.applyUnslothCredentials(workerAPIKey: " \t\r\n", monitorToken: " \t\r\n")
            XCTAssertNil(settings.unslothWorkerAPIKey)
            XCTAssertNil(settings.unslothMonitorToken)
            let configuration = try settings.configuration(for: .unsloth)
            XCTAssertNil(configuration.workerAPIKey)
            XCTAssertNil(configuration.studioMonitorToken)
            XCTAssertEqual(settings.backendSelection, .vllm)
            XCTAssertNil(defaults.data(forKey: "appSettings"))
        }
    }

    func testInvalidUnslothWorkerKeyDoesNotPartiallyReplaceSessionCredentials() throws {
        try withSettings { settings, defaults in
            settings.backendSelection = .ollama
            settings.unslothWorkerAPIKey = "existing-worker-key"
            settings.unslothMonitorToken = "existing-monitor-token"
            XCTAssertThrowsError(
                try settings.applyUnslothCredentials(
                    workerAPIKey: "invalid worker key", monitorToken: "replacement-monitor-token"))
            XCTAssertEqual(settings.unslothWorkerAPIKey, "existing-worker-key")
            XCTAssertEqual(settings.unslothMonitorToken, "existing-monitor-token")
            XCTAssertEqual(settings.backendSelection, .ollama)
            XCTAssertNil(defaults.data(forKey: "appSettings"))
        }
    }

    func testDetectedUnslothValidatesVisibleWorkerKeyWithoutChangingManualBackend() throws {
        try withSettings { settings, _ in
            for selection in [BackendSelection.vllm, .ollama] {
                let invalidKey = "invalid worker key"
                let error = try XCTUnwrap(
                    SettingsView.validationError(
                        selection: selection, proxyPort: "11435", ollamaHost: "localhost",
                        ollamaPort: "11434", endpoints: settings.backendEndpoints,
                        unslothWorkerAPIKey: invalidKey, unslothDetected: true))
                XCTAssertTrue(error.contains("worker API key"))
                XCTAssertFalse(error.contains(invalidKey))
                XCTAssertNil(
                    SettingsView.validationError(
                        selection: selection, proxyPort: "11435", ollamaHost: "localhost",
                        ollamaPort: "11434", endpoints: settings.backendEndpoints,
                        unslothWorkerAPIKey: invalidKey))
                XCTAssertNil(
                    SettingsView.validationError(
                        selection: selection, proxyPort: "11435", ollamaHost: "localhost",
                        ollamaPort: "11434", endpoints: settings.backendEndpoints,
                        unslothWorkerAPIKey: "fixture-worker-key", unslothDetected: true))
            }
        }
    }

    func testWorkerAPIKeyRejectsInvalidHeadersWithoutIncludingKeyInErrors() throws {
        try withSettings { settings, _ in
            let invalidKeys = [
                "fixture key", "fixture\tkey", "fixture\r\nkey", "fixture\0key",
                "fixture\u{7F}key", "fixture\u{A0}key", "fixture-\u{E9}-key",
                String(repeating: "x", count: 16_385),
            ]
            for key in invalidKeys {
                settings.unslothWorkerAPIKey = key
                XCTAssertThrowsError(try settings.configuration(for: .unsloth)) { error in
                    XCTAssertFalse(error.localizedDescription.contains(key))
                    XCTAssertFalse(error.localizedDescription.contains("fixture"))
                }
                for selection in [BackendSelection.unsloth, .automatic] {
                    let error = try XCTUnwrap(
                        SettingsView.validationError(
                            selection: selection, proxyPort: "11435", ollamaHost: "localhost",
                            ollamaPort: "11434", endpoints: settings.backendEndpoints,
                            unslothWorkerAPIKey: key))
                    XCTAssertFalse(error.contains(key))
                    XCTAssertFalse(error.contains("fixture"))
                }
                XCTAssertNoThrow(try settings.configuration(for: .vllm))
                XCTAssertNil(
                    SettingsView.validationError(
                        selection: .vllm, proxyPort: "unused", ollamaHost: "unused",
                        ollamaPort: "unused", endpoints: settings.backendEndpoints,
                        unslothWorkerAPIKey: key))
            }
        }
    }

    func testWorkerAPIKeyAcceptsPrintableASCIIBoundaryAndOuterWhitespace() throws {
        let maximumKey = String(repeating: "x", count: 16_384)
        XCTAssertEqual(try AppSettings.normalizedUnslothWorkerAPIKey(maximumKey), maximumKey)
        XCTAssertEqual(
            try AppSettings.normalizedUnslothWorkerAPIKey(" \tfixture-worker-key\r\n"),
            "fixture-worker-key")
        XCTAssertEqual(
            try AppSettings.normalizedUnslothWorkerAPIKey("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"),
            "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        XCTAssertNil(try AppSettings.normalizedUnslothWorkerAPIKey(nil))
        XCTAssertNil(try AppSettings.normalizedUnslothWorkerAPIKey(" \t\r\n"))
    }

    func testUnslothRejectsRemoteAndAPIPrefixAddresses() throws {
        try withSettings { settings, _ in
            for endpoint in [
                "https://remote.example", "http://127.0.0.2:8888",
                "http://127.0.0.1:8888/v1", "https://localhost:8888",
                "http://localhost.example:8888",
            ] {
                settings.backendEndpoints[.unsloth] = endpoint
                XCTAssertThrowsError(try settings.configuration(for: .unsloth), endpoint)
                XCTAssertNotNil(
                    SettingsView.validationError(
                        selection: .unsloth, proxyPort: "unused", ollamaHost: "unused",
                        ollamaPort: "unused", endpoints: [.unsloth: endpoint]), endpoint)
            }
            for endpoint in ["http://127.0.0.1:8888", "http://localhost:8888", "http://[::1]:8888"]
            {
                settings.backendEndpoints[.unsloth] = endpoint
                XCTAssertNoThrow(try settings.configuration(for: .unsloth), endpoint)
                XCTAssertNil(
                    SettingsView.validationError(
                        selection: .unsloth, proxyPort: "unused", ollamaHost: "unused",
                        ollamaPort: "unused", endpoints: [.unsloth: endpoint]), endpoint)
            }
        }
    }

    func testAutomaticDiscoverySelectsStudioAndNeverCreatesProxy() async throws {
        let suite = "com.cmorgan.FluxLLM.unsloth-coordinator.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.unslothMonitorToken = "session-only-monitor-token"
        settings.unslothWorkerAPIKey = "session-only-worker-key"
        let store = MetricsStore()
        let client = UnslothCoordinatorClient()
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store, client: client,
            gpuMonitor: UnavailableBackendGPUMonitor(),
            proxyFactory: { _, _ in
                XCTFail("Passive Unsloth monitoring must not create a proxy")
                return UnslothUnexpectedProxy()
            }, pollInterval: .seconds(60), discoveryInterval: .seconds(60))
        await coordinator.start()
        XCTAssertEqual(coordinator.selectedConfiguration?.kind, .unsloth)
        XCTAssertEqual(coordinator.selectedConfiguration?.baseURL.port, 9000)
        XCTAssertEqual(
            coordinator.selectedConfiguration?.studioMonitorToken, "session-only-monitor-token")
        XCTAssertEqual(coordinator.selectedConfiguration?.workerAPIKey, "session-only-worker-key")
        try await assertCredentialsForwardedBeforeSampling(
            client, probePort: 8888, samplePort: 9000)
        XCTAssertEqual(settings.lastAutomaticBackendID, "unsloth|http://127.0.0.1:9000")
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.currentModel, "Synthetic/Unsloth")
        XCTAssertEqual(store.currentTPS, 24)
        XCTAssertEqual(store.throughputBasis, .serverReportedAverage)
        XCTAssertNil(store.inferenceGPUPercent)
        XCTAssertFalse(store.chartPresentation.supportsToolActivity)
        await coordinator.rescan()
        XCTAssertEqual(store.historySource, "unsloth|http://127.0.0.1:9000|")
        let rescannedCalls = await client.calls
        let rescannedConfigurations: [[BackendConfiguration]] = rescannedCalls.compactMap {
            guard case .discovery(let configurations) = $0 else { return nil }
            return configurations
        }
        let activeConfiguration = try XCTUnwrap(
            rescannedConfigurations.last?.first(where: { $0.kind == .unsloth }))
        XCTAssertEqual(activeConfiguration.baseURL.port, 9000)
        XCTAssertEqual(activeConfiguration.workerAPIKey, "session-only-worker-key")
        await coordinator.stop()
        XCTAssertNil(coordinator.selectedConfiguration)
        XCTAssertNil(defaults.data(forKey: "appSettings"))
    }

    func testManualUnslothSelectionForwardsCredentialsToConfiguredProbeAndSampling() async throws {
        let suite = "com.cmorgan.FluxLLM.unsloth-manual-coordinator.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.backendSelection = .unsloth
        settings.backendEndpoints[.unsloth] = "http://127.0.0.1:9000"
        settings.unslothMonitorToken = "session-only-monitor-token"
        settings.unslothWorkerAPIKey = "session-only-worker-key"
        let store = MetricsStore()
        let client = UnslothCoordinatorClient()
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store, client: client,
            gpuMonitor: UnavailableBackendGPUMonitor(),
            proxyFactory: { _, _ in
                XCTFail("Passive Unsloth monitoring must not create a proxy")
                return UnslothUnexpectedProxy()
            }, pollInterval: .seconds(60), discoveryInterval: .seconds(60))
        await coordinator.start()
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(coordinator.selectedConfiguration?.workerAPIKey, "session-only-worker-key")
        try await assertCredentialsForwardedBeforeSampling(
            client, probePort: 9000, samplePort: 9000)
        await coordinator.stop()
        XCTAssertNil(defaults.data(forKey: "appSettings"))
    }

    func testUnchangedAndEquivalentUnslothApplyPreservesOngoingRequestAndPinnedChart() async throws
    {
        let suite = "com.cmorgan.FluxLLM.unsloth-continuity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let origin = Date(timeIntervalSince1970: 1000)
        var now = origin
        let store = MetricsStore(clock: { now })
        let client = UnslothCoordinatorClient(timestamp: origin, observesRequests: true)
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store, client: client,
            gpuMonitor: UnavailableBackendGPUMonitor(),
            pollInterval: .seconds(60), discoveryInterval: .seconds(60))
        await coordinator.start()
        store.setChartPresentationDemand(true, consumer: .dashboard)
        store.sample(at: now)
        let epoch = store.monitoringEpoch
        let requestID = try XCTUnwrap(store.requestLanes.first?.id)
        now = origin.addingTimeInterval(1)
        store.applyBackendSample(await client.progress(at: now, outputTokens: 104), epoch: epoch)
        store.sample(at: now)
        let pinned = DateInterval(start: origin, end: now)
        store.setChartPresentationViewport(.fixed(pinned), consumer: .dashboard)
        let history = store.tpsHistory
        let chart = store.chartPresentation
        let source = store.historySource
        XCTAssertFalse(history.isEmpty)
        XCTAssertTrue(store.isBackendActive)
        XCTAssertFalse(try XCTUnwrap(store.requestLanes.first).terminal)

        try await coordinator.applySettings()
        XCTAssertEqual(store.monitoringEpoch, epoch)
        XCTAssertEqual(store.requestLanes.map(\.id), [requestID])
        XCTAssertEqual(store.tpsHistory, history)
        XCTAssertEqual(store.chartPresentation, chart)
        XCTAssertEqual(store.historySource, source)
        XCTAssertTrue(store.isBackendActive)

        // Automatic selected port 9000 even though its saved discovery template uses 8888.
        settings.backendSelection = .unsloth
        settings.backendEndpoints[.unsloth] = " http://LOCALHOST:9000/ "
        settings.proxyPort = 12035
        settings.llamaCppModel = "unrelated-model"
        settings.showMenuBarLogo.toggle()
        try await coordinator.applySettings()
        XCTAssertEqual(store.monitoringEpoch, epoch)
        XCTAssertEqual(store.requestLanes.map(\.id), [requestID])
        XCTAssertEqual(store.tpsHistory, history)
        XCTAssertEqual(store.chartPresentation, chart)
        XCTAssertTrue(store.isBackendActive)

        // Returning to Automatic resolves discovery again, then keeps the same effective target.
        settings.backendSelection = .automatic
        try await coordinator.applySettings()
        XCTAssertEqual(store.monitoringEpoch, epoch)
        XCTAssertEqual(store.requestLanes.map(\.id), [requestID])
        XCTAssertEqual(store.tpsHistory, history)
        XCTAssertEqual(store.chartPresentation, chart)
        XCTAssertTrue(store.isBackendActive)
        let resets = await client.resetCount
        XCTAssertEqual(resets, 1)

        now = origin.addingTimeInterval(2)
        store.applyBackendSample(await client.progress(at: now, outputTokens: 128), epoch: epoch)
        store.sample(at: now)
        XCTAssertEqual(store.requestLanes.map(\.id), [requestID])
        XCTAssertEqual(store.requestLanes.first?.outputTokens, 128)
        XCTAssertFalse(try XCTUnwrap(store.requestLanes.first).terminal)
        XCTAssertTrue(store.isBackendActive)
        XCTAssertEqual(Array(store.tpsHistory.prefix(history.count)), history)
        XCTAssertTrue(store.chartPresentation.throughput.allSatisfy { $0.timestamp <= pinned.end })
        await coordinator.stop()
    }

    func testChangedAutomaticUnslothCredentialsRestartWithNewDiscoveryCredentials() async throws {
        let suite = "com.cmorgan.FluxLLM.unsloth-credential-apply.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.unslothWorkerAPIKey = "original-worker-key"
        let store = MetricsStore()
        let client = UnslothCoordinatorClient()
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store, client: client,
            gpuMonitor: UnavailableBackendGPUMonitor(),
            pollInterval: .seconds(60), discoveryInterval: .seconds(60))
        await coordinator.start()
        let initialEpoch = store.monitoringEpoch
        settings.unslothWorkerAPIKey = "replacement-worker-key"

        try await coordinator.applySettings()

        XCTAssertNotEqual(store.monitoringEpoch, initialEpoch)
        XCTAssertEqual(coordinator.selectedConfiguration?.baseURL.port, 9000)
        XCTAssertEqual(coordinator.selectedConfiguration?.workerAPIKey, "replacement-worker-key")
        let calls = await client.calls
        let configurations = try XCTUnwrap(
            calls.compactMap { call -> [BackendConfiguration]? in
                guard case .discovery(let configurations) = call else { return nil }
                return configurations
            }.last)
        let unsloth = configurations.filter { $0.kind == .unsloth }
        XCTAssertEqual(Set(unsloth.compactMap { $0.baseURL.port }), [8888, 9000])
        XCTAssertTrue(unsloth.allSatisfy { $0.workerAPIKey == "replacement-worker-key" })

        let workerEpoch = store.monitoringEpoch
        settings.unslothMonitorToken = "new-studio-token"
        try await coordinator.applySettings()
        XCTAssertNotEqual(store.monitoringEpoch, workerEpoch)
        XCTAssertEqual(coordinator.selectedConfiguration?.studioMonitorToken, "new-studio-token")
        let resets = await client.resetCount
        XCTAssertEqual(resets, 3)
        await coordinator.stop()
    }

    private func assertCredentialsForwardedBeforeSampling(
        _ client: UnslothCoordinatorClient, probePort: Int, samplePort: Int
    ) async throws {
        let calls = await client.calls
        let firstSampleIndex = try XCTUnwrap(
            calls.firstIndex {
                if case .sample = $0 { return true }
                return false
            })
        let earlierCalls = calls.prefix(firstSampleIndex)
        let discoveryConfigurations = earlierCalls.flatMap { call -> [BackendConfiguration] in
            guard case .discovery(let configurations) = call else { return [] }
            return configurations
        }
        let configuredProbes: [BackendConfiguration] = earlierCalls.compactMap {
            guard case .detect(let configuration) = $0 else { return nil }
            return configuration
        }
        let sampleConfigurations: [BackendConfiguration] = calls.compactMap {
            guard case .sample(let configuration) = $0 else { return nil }
            return configuration
        }
        for configurations in [discoveryConfigurations, configuredProbes] {
            let configuration = try XCTUnwrap(
                configurations.first { $0.kind == .unsloth && $0.baseURL.port == probePort })
            XCTAssertEqual(configuration.workerAPIKey, "session-only-worker-key")
            XCTAssertEqual(configuration.studioMonitorToken, "session-only-monitor-token")
        }
        let sample = try XCTUnwrap(sampleConfigurations.first)
        XCTAssertEqual(sample.kind, .unsloth)
        XCTAssertEqual(sample.baseURL.port, samplePort)
        XCTAssertEqual(sample.workerAPIKey, "session-only-worker-key")
        XCTAssertEqual(sample.studioMonitorToken, "session-only-monitor-token")
    }

    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) throws {
        let suite = "com.cmorgan.FluxLLM.unsloth-settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppSettings(defaults: defaults), defaults)
    }
}

private enum UnslothCoordinatorCall: Sendable {
    case discovery([BackendConfiguration])
    case detect(BackendConfiguration)
    case sample(BackendConfiguration)
}

private actor UnslothCoordinatorClient: BackendClientProtocol {
    private let studio = URL(string: "http://127.0.0.1:9000")!
    private let timestamp: Date?
    private let observesRequests: Bool
    private var sourceEpoch = UUID()
    private(set) var resetCount = 0
    private(set) var calls: [UnslothCoordinatorCall] = []

    init(timestamp: Date? = nil, observesRequests: Bool = false) {
        self.timestamp = timestamp
        self.observesRequests = observesRequests
    }

    func reset() {
        resetCount += 1
        sourceEpoch = UUID()
    }

    func discoverLocalBackends() async -> [DetectedBackend] {
        [DetectedBackend(kind: .unsloth, baseURL: studio)]
    }
    func discoverLocalBackends(configurations: [BackendConfiguration]) async -> [DetectedBackend] {
        calls.append(.discovery(configurations))
        return await discoverLocalBackends()
    }
    func detect(at baseURL: URL) async throws -> DetectedBackend? { nil }
    func detect(_ configuration: BackendConfiguration) async throws -> DetectedBackend? {
        calls.append(.detect(configuration))
        return nil
    }
    func sample(_ configuration: BackendConfiguration) async throws -> BackendSample {
        calls.append(.sample(configuration))
        return BackendSample(
            kind: configuration.kind, timestamp: timestamp ?? Date(),
            model: "Synthetic/Unsloth", currentTPS: 24,
            basis: .serverReportedAverage,
            nativeRequests: observesRequests ? requestSnapshot(outputTokens: 80) : nil,
            runningRequests: 1, queuedRequests: 0,
            outputTokens: 80, promptTokens: 32)
    }

    func progress(at timestamp: Date, outputTokens: Int) -> BackendSample {
        BackendSample(
            kind: .unsloth, timestamp: timestamp, model: "Synthetic/Unsloth", currentTPS: 24,
            basis: .serverReportedAverage,
            nativeRequests: requestSnapshot(outputTokens: outputTokens),
            runningRequests: 1, queuedRequests: 0, outputTokens: outputTokens, promptTokens: 32)
    }

    private func requestSnapshot(outputTokens: Int) -> NativeRequestSnapshot {
        NativeRequestSnapshot(
            sourceEpoch: sourceEpoch, source: .slotPolling,
            requests: [
                NativeRequestObservation(
                    id: "ongoing-unsloth", outputTokens: outputTokens, liveTPS: 24)
            ])
    }
}

@MainActor
private final class UnslothUnexpectedProxy: MonitoringProxy {
    func start() async throws { XCTFail("A native backend must never start a proxy") }
    func stop() async {}
}
