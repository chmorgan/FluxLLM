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
        XCTAssertEqual(settings.lastAutomaticBackendID, "unsloth|http://127.0.0.1:9000")
        XCTAssertEqual(store.connectionState, .ready)
        XCTAssertEqual(store.currentModel, "Synthetic/Unsloth")
        XCTAssertEqual(store.currentTPS, 24)
        XCTAssertEqual(store.throughputBasis, .serverReportedAverage)
        XCTAssertNil(store.inferenceGPUPercent)
        XCTAssertFalse(store.chartPresentation.supportsToolActivity)
        await coordinator.rescan()
        XCTAssertEqual(store.historySource, "unsloth|http://127.0.0.1:9000|")
        await coordinator.stop()
        XCTAssertNil(coordinator.selectedConfiguration)
        XCTAssertNil(defaults.data(forKey: "appSettings"))
    }

    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) throws {
        let suite = "com.cmorgan.FluxLLM.unsloth-settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppSettings(defaults: defaults), defaults)
    }
}

private actor UnslothCoordinatorClient: BackendClientProtocol {
    private let studio = URL(string: "http://127.0.0.1:9000")!
    func discoverLocalBackends() async -> [DetectedBackend] {
        [DetectedBackend(kind: .unsloth, baseURL: studio)]
    }
    func detect(at baseURL: URL) async throws -> DetectedBackend? { nil }
    func sample(_ configuration: BackendConfiguration) async throws -> BackendSample {
        BackendSample(
            kind: configuration.kind, model: "Synthetic/Unsloth", currentTPS: 24,
            basis: .serverReportedAverage, runningRequests: 1, queuedRequests: 0,
            outputTokens: 80, promptTokens: 32)
    }
}

@MainActor
private final class UnslothUnexpectedProxy: MonitoringProxy {
    func start() async throws { XCTFail("A native backend must never start a proxy") }
    func stop() async {}
}
