import XCTest

@testable import FluxLLM

@MainActor
final class MenuBarExtraViewTests: XCTestCase {
    func testAppTitleIsFluxLLM() {
        XCTAssertEqual(MenuBarExtraView.appTitle, "FluxLLM")
        XCTAssertEqual(MenuBarController.appTitle, "FluxLLM")
    }

    func testQuitTitle() {
        XCTAssertEqual(MenuBarExtraView.quitTitle, "Quit FluxLLM")
    }

    func testViewInstantiates() {
        XCTAssertNoThrow(MenuBarExtraView())
    }

    func testTpsLabelFormatsToOneDecimal() {
        XCTAssertEqual(MenuBarExtraView.tpsLabel(tps: 31.7), "TPS: 31.7")
        XCTAssertEqual(MenuBarExtraView.tpsLabel(tps: 0), "TPS: 0.0")
        XCTAssertEqual(MenuBarExtraView.tpsLabel(tps: 12.34), "TPS: 12.3")
    }

    func testStatusLineShowsActiveThenIdleWithoutRequestLifecycleDetails() {
        let store = MetricsStore()
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        store.updateConnection(.ready)
        let request = GenerationRequest(model: "llama3")
        store.apply(.began(request))
        XCTAssertEqual(MenuBarExtraView.statusLine(store: store), "Active")
        store.apply(.cancelled(requestID: request.id))
        XCTAssertEqual(MenuBarExtraView.statusLine(store: store), "Idle")
    }

    func testStatusLinePrioritizesConnectionConfiguration() {
        let store = MetricsStore()
        XCTAssertEqual(MenuBarExtraView.statusLine(store: store), "Connecting")
        store.updateConnection(.needsConfiguration)
        XCTAssertEqual(MenuBarExtraView.statusLine(store: store), "Configure")
        store.updateConnection(.unavailable)
        XCTAssertEqual(MenuBarExtraView.statusLine(store: store), "Unavailable")
        XCTAssertEqual(MenuBarExtraView.statusLine(store: nil), "Configure")
    }

    func testSelectionWarningIdentifiesDifferentDetectedSystem() {
        let detected = [
            DetectedBackend(kind: .vllm, baseURL: URL(string: "http://localhost:8000")!)
        ]
        XCTAssertEqual(
            BackendPresentation.selectionWarning(selection: .ollama, detected: detected),
            "vLLM detected; Ollama is selected.")
        XCTAssertNil(BackendPresentation.selectionWarning(selection: .vllm, detected: detected))
        XCTAssertNil(
            BackendPresentation.selectionWarning(selection: .automatic, detected: detected))
    }

    func testRatesUsePlainNumbersAndPreserveAvailabilityAndMeasurementBasis() {
        for basis in [ThroughputBasis.estimated, .serverAggregate] {
            let store = MetricsStore()
            let epoch = UUID()
            store.beginBackendSession(kind: .vllm, epoch: epoch)
            XCTAssertEqual(BackendPresentation.rateLabel(store: store), "—")
            store.applyBackendSample(
                BackendSample(
                    kind: .vllm, currentTPS: 42.54, basis: basis, runningRequests: 1),
                epoch: epoch)
            store.sample()
            XCTAssertEqual(BackendPresentation.rateLabel(store: store), "42.5")
            XCTAssertEqual(
                StatusItemPresentation.compactTPS(
                    tps: store.displayTPS ?? 0, active: store.displayTPS != nil), "43 t/s")
            XCTAssertEqual(store.displayRateIsEstimated, basis == .estimated)
            XCTAssertEqual(
                StatusItemPresentation.accessibilitySummary(store: store)
                    .contains("Approximately"), basis == .estimated)
            XCTAssertEqual(MenuBarExtraView.statusLine(store: store), "Active")
            store.applyBackendSample(
                BackendSample(kind: .vllm, currentTPS: 0, runningRequests: 0, queuedRequests: 0),
                epoch: epoch)
            XCTAssertEqual(BackendPresentation.rateLabel(store: store), "0.0")
            XCTAssertEqual(MenuBarExtraView.statusLine(store: store), "Idle")
        }
    }
}
