import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class BackendPresentationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testAppliedFaultReplacesStaleHealthyDiscoveryAndExplainsTheReason() throws {
        let store = session()
        store.setDetections([
            DetectedBackend(
                kind: .unsloth, baseURL: endpoint(), detail: "Worker ready at last scan")
        ])
        store.updateConnection(.needsConfiguration, message: "The worker API key was rejected.")

        let rows = BackendPresentation.settingsConnections(store: store)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(row.isApplied)
        XCTAssertEqual(row.status, "Configure")
        XCTAssertEqual(row.tone, .warning)
        XCTAssertEqual(row.symbol, "exclamationmark.circle")
        XCTAssertEqual(row.detail, "The worker API key was rejected.")
        XCTAssertEqual(
            BackendPresentation.configurationPrompt(store: store),
            "Choose an LLM system in Settings.")
    }

    func testHealthyRescanRetainsTheCurrentMonitoringFault() throws {
        let store = session()
        let reason = "The inference worker is restarting. Monitoring will retry."
        store.updateConnection(.unavailable, message: reason)
        for detail in ["Found a loaded model", "Worker ready"] {
            store.setDetections([
                DetectedBackend(kind: .unsloth, baseURL: endpoint(), detail: detail)
            ])
            let row = try XCTUnwrap(BackendPresentation.settingsConnections(store: store).first)
            XCTAssertEqual(row.status, "Unavailable")
            XCTAssertEqual(row.detail, reason)
            XCTAssertEqual(row.tone, .warning)
            XCTAssertEqual(store.connectionState, .unavailable)
            XCTAssertEqual(store.connectionMessage, reason)
        }
    }

    func testDifferentPortAndKindRemainDiscoveryRowsBesideTheAppliedFault() throws {
        let store = session()
        let otherEndpoint = endpoint(port: 8888)
        store.updateConnection(
            .needsConfiguration, message: "No Studio is running at this address.")
        store.setDetections([
            DetectedBackend(kind: .unsloth, baseURL: otherEndpoint, detail: "Loaded model"),
            DetectedBackend(kind: .vllm, baseURL: endpoint()),
        ])

        let rows = BackendPresentation.settingsConnections(store: store)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.filter(\.isApplied).count, 1)
        let applied = try XCTUnwrap(rows.first)
        XCTAssertEqual(applied.kind, .unsloth)
        XCTAssertEqual(applied.endpoint, endpoint())
        XCTAssertEqual(applied.status, "Configure")
        let scanned = try XCTUnwrap(rows.first { $0.endpoint == otherEndpoint })
        XCTAssertFalse(scanned.isApplied)
        XCTAssertEqual(scanned.status, "Ready")
        XCTAssertEqual(scanned.detail, "Loaded model")
        XCTAssertEqual(scanned.tone, .ready)
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.kind == .vllm }).isApplied)
    }

    func testCanonicalLocalhostAliasesMatchOnlyTheLiveAppliedRow() throws {
        let store = session()
        store.updateConnection(.connecting, message: "Waiting for the worker to become ready.")
        for address in [
            "http://LOCALHOST:9000/", "http://localhost.:9000", "http://127.0.0.1:9000",
        ] {
            let scannedEndpoint = try XCTUnwrap(URL(string: address))
            store.setDetections([DetectedBackend(kind: .unsloth, baseURL: scannedEndpoint)])
            let rows = BackendPresentation.settingsConnections(store: store)
            XCTAssertEqual(rows.count, 1, address)
            let row = try XCTUnwrap(rows.first)
            XCTAssertTrue(row.isApplied)
            XCTAssertEqual(row.endpoint, endpoint())
            XCTAssertEqual(row.status, "Connecting")
            XCTAssertEqual(row.tone, .pending)
            XCTAssertEqual(row.detail, "Waiting for the worker to become ready.")
        }
    }

    func testAutomaticResolvedEndpointUsesTheActualTargetInsteadOfTheDefaultAddress() throws {
        let store = session()
        let defaultEndpoint = try XCTUnwrap(URL(string: BackendKind.unsloth.defaultEndpoint))
        store.setDetections([
            DetectedBackend(kind: .unsloth, baseURL: defaultEndpoint),
            DetectedBackend(kind: .unsloth, baseURL: endpoint()),
        ])
        store.applyBackendSample(
            BackendSample(kind: .unsloth, timestamp: origin, runningRequests: 0, queuedRequests: 0),
            epoch: store.monitoringEpoch)

        let rows = BackendPresentation.settingsConnections(store: store)
        XCTAssertEqual(rows.count, 2)
        let applied = try XCTUnwrap(rows.first)
        XCTAssertTrue(applied.isApplied)
        XCTAssertEqual(applied.endpoint.port, 9000)
        XCTAssertEqual(applied.status, "Idle")
        let scanned = try XCTUnwrap(rows.last)
        XCTAssertFalse(scanned.isApplied)
        XCTAssertEqual(scanned.endpoint, defaultEndpoint)
    }

    func testUnappliedEndpointCredentialAndSelectionDraftsDoNotChangeLiveRows() throws {
        let suite = "FluxLLM.backend-presentation-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let store = session()
        store.updateConnection(.needsConfiguration, message: "The current worker key was rejected.")
        let appliedRows = BackendPresentation.settingsConnections(store: store)

        settings.backendEndpoints[.unsloth] = "http://127.0.0.1:9001"
        settings.unslothWorkerAPIKey = "unapplied-worker-key"
        settings.unslothMonitorToken = "unapplied-studio-token"
        settings.backendSelection = .vllm

        XCTAssertEqual(BackendPresentation.settingsConnections(store: store), appliedRows)
        XCTAssertEqual(store.backendEndpoint, endpoint())
        XCTAssertEqual(store.backendKind, .unsloth)
        XCTAssertEqual(store.connectionState, .needsConfiguration)
    }

    func testGenuineConfigureFaultsKeepTheirSpecificReasonsWithoutDiscovery() throws {
        for reason in [
            "This endpoint is vLLM, but Unsloth is selected.",
            "The worker API key was rejected.",
            "Start llama.cpp with --metrics to enable monitoring.",
        ] {
            let store = session()
            store.updateConnection(.needsConfiguration, message: reason)
            let row = try XCTUnwrap(BackendPresentation.settingsConnections(store: store).first)
            XCTAssertTrue(row.isApplied)
            XCTAssertEqual(row.status, "Configure")
            XCTAssertEqual(row.detail, reason)
            XCTAssertEqual(row.tone, .warning)
        }
        let store = session()
        store.updateConnection(.needsConfiguration, message: " \n ")
        XCTAssertEqual(
            BackendPresentation.settingsConnections(store: store).first?.detail,
            "Choose an LLM system in Settings.")
    }

    func testAppliedEndpointIsSanitizedAndChangesOrClearsWithItsSession() throws {
        let store = session()
        let privateEndpoint = try XCTUnwrap(
            URL(string: "http://user:private-key@localhost:9001/?token=secret#private-fragment"))
        store.beginBackendSession(kind: .unsloth, epoch: UUID(), endpoint: privateEndpoint)
        let row = try XCTUnwrap(BackendPresentation.settingsConnections(store: store).first)
        XCTAssertEqual(row.endpoint.absoluteString, "http://localhost:9001/")
        XCTAssertNil(row.endpoint.user)
        XCTAssertNil(row.endpoint.password)
        XCTAssertNil(row.endpoint.query)
        XCTAssertNil(row.endpoint.fragment)
        XCTAssertNotEqual(row.endpoint.port, endpoint().port)

        store.beginBackendSession(kind: .vllm, epoch: UUID())
        XCTAssertNil(store.backendEndpoint)
        XCTAssertTrue(BackendPresentation.settingsConnections(store: store).isEmpty)
        store.beginBackendSession(kind: .unsloth, epoch: UUID(), endpoint: endpoint())
        store.beginBackendSession(kind: nil, epoch: UUID(), endpoint: endpoint())
        XCTAssertNil(store.backendEndpoint)
        XCTAssertTrue(BackendPresentation.settingsConnections(store: store).isEmpty)
    }

    private func session() -> MetricsStore {
        let store = MetricsStore(clock: { self.origin })
        store.beginBackendSession(kind: .unsloth, epoch: UUID(), endpoint: endpoint())
        return store
    }

    private func endpoint(port: Int = 9000) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }
}
