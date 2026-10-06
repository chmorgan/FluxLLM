import Foundation
import XCTest

@testable import FluxLLM

/// Deterministic network-work regression guards for the production passive
/// monitor. These are not CPU/GPU measurements: the native performance runner
/// owns those, with its synthetic driver outside the measured process tree.
@MainActor
final class UnslothMonitoringPerformanceTests: XCTestCase {
    private let studio = URL(string: "http://127.0.0.1:8888")!
    private let workerURL = URL(string: "http://127.0.0.1:54234")!

    func testTwoMinutesOfSyntheticOneHzScrapesReuseFingerprintAndModel() async throws {
        let fixture = UnslothScrapeFixture(workerPorts: [54234])
        let discovery = UnslothScrapeDiscovery([server(workerURL: workerURL, workerStart: 10)])
        let normal = HTTPBackendClient(transport: { try await fixture.send($0) })
        let client = UnslothBackendClient(normal: normal, discovery: discovery)
        let configuration = BackendConfiguration(kind: .unsloth, baseURL: studio)
        let store = MetricsStore()
        let epoch = UUID()
        store.beginBackendSession(kind: .unsloth, epoch: epoch)

        // 120 deterministic polls model two minutes at the production 1 Hz
        // cadence without making an ordinary test suite wait two minutes.
        for second in 0..<120 {
            let active = (20..<80).contains(second)
            await fixture.set(running: active ? 1 : 0, output: second >= 80 ? 120 : 0)
            let sample = try await client.sample(configuration)
            store.applyBackendSample(sample, epoch: epoch)
            XCTAssertEqual(store.currentTPS, active ? 25 : 0)
            XCTAssertEqual(store.isBackendActive, active)
            XCTAssertEqual(sample.basis, .serverReportedAverage)
            XCTAssertNil(
                store.activeGeneration, "Server-level telemetry must not invent request history")
        }
        let requests = await fixture.requests
        XCTAssertEqual(
            requests.filter { $0.url?.port == 54234 && $0.url?.path == "/props" }.count, 1)
        XCTAssertEqual(
            requests.filter { $0.url?.port == 54234 && $0.url?.path == "/metrics" }.count, 121,
            "One fingerprint probe plus one metrics fetch per poll; no repeated discovery HTTP work"
        )
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertTrue(
            requests.allSatisfy {
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains(URLQueryItem(name: "autoload", value: "false")) == true
            })
        XCTAssertEqual(store.backendOutputTokens, 120)
        XCTAssertEqual(store.lastMeasuredTPS, 25)
        XCTAssertNil(store.inferenceGPUPercent)
    }

    func testCoordinatorTracksIdleActiveUnloadAndNewWorkerWithoutOpeningProxy() async throws {
        let fixture = UnslothScrapeFixture(workerPorts: [54234, 54235])
        let discovery = UnslothScrapeDiscovery([server(workerURL: workerURL, workerStart: 10)])
        let suite = "FluxLLM.unsloth-performance.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.backendSelection = .unsloth
        settings.backendEndpoints[.unsloth] = studio.absoluteString
        let store = MetricsStore()
        let recorder = UnslothProxyCreationRecorder()
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store,
            client: UnslothBackendClient(
                normal: HTTPBackendClient(transport: { try await fixture.send($0) }),
                discovery: discovery),
            gpuMonitor: UnavailableBackendGPUMonitor(),
            proxyFactory: { _, _ in recorder.makeProxy() },
            pollInterval: .milliseconds(10), discoveryInterval: .milliseconds(10),
            gpuInterval: .seconds(60))
        await coordinator.start()
        do {
            XCTAssertEqual(store.connectionState, .ready)
            XCTAssertFalse(store.isBackendActive)
            await fixture.set(running: 1, output: 0)
            try await eventually { store.isBackendActive && store.currentTPS == 25 }
            await fixture.set(running: 0, output: 120)
            try await eventually { !store.isBackendActive && store.backendOutputTokens == 120 }
            XCTAssertEqual(store.currentTPS, 0)
            XCTAssertEqual(store.lastMeasuredTPS, 25)

            await discovery.replace([server(workerURL: nil, workerStart: nil)])
            try await eventually { store.connectionState == .needsConfiguration }
            XCTAssertTrue(store.connectionMessage?.contains("Load a GGUF model") == true)
            XCTAssertTrue(store.connectionMessage?.contains("Unsloth Studio") == true)
            XCTAssertFalse(store.isBackendActive)
            let oldWorkerRequests = await fixture.count(port: 54234)

            await fixture.set(running: 0, output: 0, model: "Fixture/unsloth-second")
            await discovery.replace([
                server(workerURL: URL(string: "http://127.0.0.1:54235")!, workerStart: 20)
            ])
            await coordinator.rescan()
            // Rescan refreshes discovery without interrupting a session. The
            // explicit refresh starts its poll now, avoiding the intentional
            // outage backoff at the test's two-second eventual-state deadline.
            try await coordinator.applySettings()
            try await eventually {
                store.connectionState == .ready && store.currentModel == "Fixture/unsloth-second"
                    && store.backendOutputTokens == 0
            }
            let remainingOldRequests = await fixture.count(port: 54234)
            XCTAssertEqual(remainingOldRequests, oldWorkerRequests)
            await fixture.set(running: 1, output: 0)
            try await eventually { store.isBackendActive }
            XCTAssertNil(store.activeGeneration)
            XCTAssertEqual(recorder.creations, 0)
            let propsRequests = await fixture.requests.filter {
                $0.url?.path == "/props" && [54234, 54235].contains($0.url?.port ?? 0)
            }
            XCTAssertEqual(
                propsRequests.count, 2, "Fetch model once for each verified worker identity")
        } catch {
            await coordinator.stop()
            throw error
        }
        await coordinator.stop()
        let stoppedCount = await fixture.requests.count
        try await Task.sleep(for: .milliseconds(30))
        let afterStopCount = await fixture.requests.count
        XCTAssertEqual(afterStopCount, stoppedCount)
        XCTAssertEqual(recorder.creations, 0)
    }

    private func server(workerURL: URL?, workerStart: UInt64?) -> UnslothServer {
        UnslothServer(
            studioURL: studio, workerURL: workerURL,
            studioIdentity: GPUProcessIdentity(pid: 10, startTimeMicroseconds: 1),
            workerIdentity: workerStart.map {
                GPUProcessIdentity(pid: 11, startTimeMicroseconds: $0)
            })
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Unsloth monitor did not reach the expected native lifecycle state")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor UnslothScrapeDiscovery: UnslothDiscovering {
    private var values: [UnslothServer]
    init(_ values: [UnslothServer]) { self.values = values }
    func servers() -> [UnslothServer] { values }
    func replace(_ values: [UnslothServer]) { self.values = values }
}

private actor UnslothScrapeFixture {
    private let workerPorts: Set<Int>
    private var running = 0
    private var output = 0
    private var model = "Fixture/unsloth-synthetic"
    private(set) var requests: [URLRequest] = []

    init(workerPorts: Set<Int>) { self.workerPorts = workerPorts }

    func set(running: Int, output: Int, model: String? = nil) {
        self.running = running
        self.output = output
        if let model { self.model = model }
    }

    func count(port: Int) -> Int { requests.filter { $0.url?.port == port }.count }

    func send(_ request: URLRequest) throws -> BackendHTTPResponse {
        requests.append(request)
        guard let url = request.url, workerPorts.contains(url.port ?? 0) else {
            return BackendHTTPResponse(statusCode: 404, data: Data())
        }
        switch url.path {
        case "/metrics":
            return BackendHTTPResponse(
                statusCode: 200,
                data: Data(
                    """
                    llamacpp:requests_processing \(running)
                    llamacpp:requests_deferred 0
                    llamacpp:tokens_predicted_total \(output)
                    llamacpp:prompt_tokens_total \(output > 0 ? 12 : 0)
                    llamacpp:predicted_tokens_seconds 25
                    """.utf8))
        case "/props":
            return BackendHTTPResponse(
                statusCode: 200,
                data: try JSONSerialization.data(withJSONObject: [
                    "default_generation_settings": [:], "total_slots": 4,
                    "model_alias": model, "endpoint_metrics": true,
                ]))
        default:
            return BackendHTTPResponse(statusCode: 404, data: Data())
        }
    }
}

@MainActor
private final class UnslothProxyCreationRecorder {
    private(set) var creations = 0
    func makeProxy() -> any MonitoringProxy {
        creations += 1
        return UnslothUnexpectedProxy()
    }
}

@MainActor
private final class UnslothUnexpectedProxy: MonitoringProxy {
    func start() async throws { XCTFail("Passive Unsloth monitoring opened a proxy") }
    func stop() async {}
}
