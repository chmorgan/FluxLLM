import AppKit
import Foundation
import ServiceManagement

/// Owns the real app components for an explicitly requested isolated resource
/// run. The upstream is external; telemetry, timers, UI and persistence retain
/// their production paths and run inside the measured executable.
@MainActor
public final class PerformanceApplicationSession {
    public let store: MetricsStore
    public let coordinator: MonitoringCoordinator
    public let menuBarController: MenuBarController
    public let settings: AppSettings
    public let historyDirectory: URL
    public let preferencesSuite: String
    public let historyKind: String
    public let proxyPort: Int

    private let clock: PerformanceWorkloadClock
    private let defaults: UserDefaults
    private let rawEnd: Date
    private var stopped = false

    private init(
        store: MetricsStore, coordinator: MonitoringCoordinator,
        controller: MenuBarController, settings: AppSettings,
        historyDirectory: URL, preferencesSuite: String,
        historyKind: String, proxyPort: Int, clock: PerformanceWorkloadClock,
        defaults: UserDefaults, rawEnd: Date
    ) {
        self.store = store
        self.coordinator = coordinator
        self.menuBarController = controller
        self.settings = settings
        self.historyDirectory = historyDirectory
        self.preferencesSuite = preferencesSuite
        self.historyKind = historyKind
        self.proxyPort = proxyPort
        self.clock = clock
        self.defaults = defaults
        self.rawEnd = rawEnd
    }

    public static func start(
        upstream: URL, historyDirectory: URL, preferencesSuite: String,
        populated: Bool
    ) async throws -> PerformanceApplicationSession {
        guard upstream.scheme == "http", upstream.host == "127.0.0.1",
            let upstreamPort = upstream.port, (1...65535).contains(upstreamPort)
        else { throw PerformanceSessionError.invalid("A numeric loopback fixture is required") }
        guard let defaults = UserDefaults(suiteName: preferencesSuite),
            defaults.persistentDomain(forName: preferencesSuite) == nil
        else { throw PerformanceSessionError.invalid("Performance preferences must be new") }
        let settings = AppSettings(defaults: defaults)
        settings.backendSelection = .ollama
        settings.ollamaHost = "127.0.0.1"
        settings.ollamaPort = upstreamPort
        let source = "ollama|\(upstream.absoluteString)|"
        if populated {
            // The external helper constructs legacy fixture files before this
            // process launches. Only production loading and live ingestion
            // belong to the app's measured resource use.
            guard
                ["usage-history.json", "chart-history.json"].allSatisfy({
                    FileManager.default.fileExists(
                        atPath: historyDirectory.appendingPathComponent($0).path)
                })
            else {
                throw PerformanceSessionError.invalid(
                    "Populated history must be prepared by the external helper")
            }
        }
        let rawEnd = Date()
        let clock = PerformanceWorkloadClock(
            now: rawEnd.addingTimeInterval(-MetricsStore.chartWindow))
        let store = MetricsStore(clock: { clock.now }, historyDirectory: historyDirectory)
        await store.prepareHistory()
        let proxyHolder = PerformanceProxyHolder()
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store,
            client: PerformanceBackendClient(upstream: upstream, clock: clock),
            gpuMonitor: PerformanceWorkloadGPU(clock: clock),
            proxyFactory: { configuration, epoch in
                let proxy = ProxyManager(
                    listenPort: 0, ollamaHost: "127.0.0.1",
                    ollamaPort: configuration.baseURL.port!, metricsStore: store,
                    eventEpoch: epoch)
                proxyHolder.proxy = proxy
                return proxy
            })
        let controller = MenuBarController(
            metricsStore: store, coordinator: coordinator, settings: settings,
            launchAtLogin: LaunchAtLoginController(service: PerformanceLoginService()))
        await coordinator.start()
        guard store.connectionState == .ready, store.historySource == source,
            let proxyPort = proxyHolder.proxy?.boundPort
        else {
            await coordinator.stop()
            throw PerformanceSessionError.invalid("The isolated fixture failed to become ready")
        }
        if populated {
            PerformanceHistoryFixture.seedRawHistory(store: store, endingAt: rawEnd) {
                clock.fixed = $0
            }
            store.usageScope = .selectedPeriod
            let seeded = store.usageSummary(
                in: DateInterval(
                    start: rawEnd.addingTimeInterval(-8 * 86400), end: rawEnd.addingTimeInterval(1))
            )
            let requests =
                PerformanceHistoryFixture.persistentRequestCount
                + PerformanceHistoryFixture.rawRequestCount
            let valid =
                store.tpsHistory.count == MetricsStore.maxHistorySamples
                && store.systemGPUHistory.count == MetricsStore.maxHistorySamples
                && store.toolObservationHistory.count == MetricsStore.maxHistorySamples
                && seeded.requests == requests && seeded.toolCalls == requests
                && seeded.inputTokens == requests * 32
                && seeded.outputTokens == PerformanceHistoryFixture.persistentRequestCount
                    * PerformanceHistoryFixture.persistentOutputTokens
                    + PerformanceHistoryFixture.rawRequestCount
                    * PerformanceHistoryFixture.rawRequestOutputTokens
                && store.toolActivityEvents.count == PerformanceHistoryFixture.rawToolEventCount
                && store.chartPresentation.archive.throughput.reduce(0, { $0 + $1.count }) >= 200
            store.usageScope = .sinceLaunch
            guard valid else {
                await coordinator.stop()
                throw PerformanceSessionError.invalid("The populated fixture lost required history")
            }
        }
        clock.fixed = nil
        await store.flushHistory()
        guard store.historyPersistenceError == nil else {
            await coordinator.stop()
            throw PerformanceSessionError.invalid("Fixture persistence failed")
        }
        PerformancePresentationCounters.shared.enable()
        controller.start()
        store.startSampling()
        return PerformanceApplicationSession(
            store: store, coordinator: coordinator, controller: controller,
            settings: settings, historyDirectory: historyDirectory,
            preferencesSuite: preferencesSuite, historyKind: populated ? "populated" : "fresh",
            proxyPort: proxyPort, clock: clock, defaults: defaults, rawEnd: rawEnd)
    }

    /// Compact scalar snapshots avoid copying chart histories over the pipe.
    public func snapshot() -> [String: Any] {
        let usage = store.usageSummary(in: DateInterval(start: rawEnd, duration: 86400))
        let visibility = menuBarController.performanceVisibility
        let counters = PerformancePresentationCounters.shared.snapshot()
        return [
            "requests": usage.requests,
            "completed_requests": usage.requests - usage.activeRequests,
            "output_tokens": usage.outputTokens,
            "prompt_tokens": usage.inputTokens ?? 0,
            "tool_calls": usage.toolCalls,
            // Seeded chart events age out during a run. Count only workload
            // results so expiry of that older fixture cannot subtract usage.
            "tool_results": store.toolActivityEvents.reduce(0) {
                $0 + ($1.kind == .resultSubmission && $1.timestamp >= rawEnd ? 1 : 0)
            },
            "active_requests": usage.activeRequests,
            "partial_output_tokens": store.outputTokens,
            "current_tps": store.currentTPS,
            "dashboard_visible": visibility.dashboard,
            "popover_visible": visibility.popover,
            "chart_publication_id": store.chartPresentation.publicationID.uuidString,
            "status_updates": counters["status_updates"] as Any? ?? NSNull(),
            "chart_preparations": counters["chart_preparations"] as Any? ?? NSNull(),
            "canvas_draws": counters["canvas_draws"] as Any? ?? NSNull(),
            "metal_frames": counters["metal_frames"] as Any? ?? NSNull(),
            "raw_samples": store.tpsHistory.count,
            "archive_buckets": store.chartPresentation.archive.throughput.reduce(0) {
                $0 + $1.count
            },
            "connection_state": store.connectionState.rawValue,
            "proxy_state": String(describing: store.proxyState),
            "history": historyKind,
            "seed_persistent_requests": historyKind == "populated"
                ? PerformanceHistoryFixture.persistentRequestCount : 0,
            "seed_raw_requests": historyKind == "populated"
                ? PerformanceHistoryFixture.rawRequestCount : 0,
            "seed_tool_events": historyKind == "populated"
                ? PerformanceHistoryFixture.persistentToolEventCount
                    + PerformanceHistoryFixture.rawToolEventCount : 0,
            "history_verified": true,
            "history_persistence_error": store.historyPersistenceError as Any? ?? NSNull(),
            "logging_enabled": NSNull(),
        ]
    }

    public func stop(progress: ((String) -> Void)? = nil) async {
        guard !stopped else { return }
        stopped = true
        progress?("menu_stop")
        menuBarController.stop()
        await menuBarController.waitForPendingActions()
        progress?("coordinator_stop")
        await coordinator.stop()
        store.stopSampling()
        progress?("history_flush")
        await store.flushHistory()
        progress?("session_stopped")
    }
}

@MainActor
private final class PerformanceWorkloadClock {
    var fixed: Date?
    var now: Date { fixed ?? Date() }
    init(now: Date) { fixed = now }
}

@MainActor
private final class PerformanceProxyHolder {
    var proxy: ProxyManager?
}

private actor PerformanceBackendClient: BackendClientProtocol {
    let upstream: URL
    let clock: PerformanceWorkloadClock
    let client = HTTPBackendClient()
    init(upstream: URL, clock: PerformanceWorkloadClock) {
        self.upstream = upstream
        self.clock = clock
    }
    func detect(at baseURL: URL) async throws -> DetectedBackend? {
        guard baseURL == upstream else { return nil }
        return try await client.detect(at: baseURL)
    }
    func sample(_ configuration: BackendConfiguration) async throws -> BackendSample {
        guard configuration.baseURL == upstream else {
            throw PerformanceSessionError.invalid("Attempted to poll a non-fixture backend")
        }
        let value = try await client.sample(configuration)
        return await BackendSample(
            kind: .ollama, timestamp: clock.now, model: value.model,
            isReady: value.isReady, detail: value.detail)
    }
    func reset() async { await client.reset() }
}

/// Retain the production GPU registry polling cost while using fixed chart
/// values. These fixture values are never process GPU resource measurements.
private actor PerformanceWorkloadGPU: BackendGPUMonitoring {
    let clock: PerformanceWorkloadClock
    let monitor = SystemGPUMonitor()
    init(clock: PerformanceWorkloadClock) { self.clock = clock }
    func sample(_ configuration: BackendConfiguration?) async -> GPUActivitySample {
        _ = await monitor.sample(configuration)
        return await GPUActivitySample(
            timestamp: clock.now, activityPercent: PerformanceHistoryFixture.gpuPercent,
            source: PerformanceHistoryFixture.gpuSource, scope: .system)
    }
    func reset() async { await monitor.reset() }
}

@MainActor
private final class PerformanceLoginService: LaunchAtLoginService {
    var status: SMAppService.Status { .notRegistered }
    func register() throws {
        throw PerformanceSessionError.invalid("Login items are disabled in performance mode")
    }
    func unregister() async throws {
        throw PerformanceSessionError.invalid("Login items are disabled in performance mode")
    }
    func openSystemSettings() {}
}

private enum PerformanceSessionError: Error {
    case invalid(String)
}
