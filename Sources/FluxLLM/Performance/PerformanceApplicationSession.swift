import AppKit
import Foundation
import ServiceManagement

/// Owns the real app components for an explicitly requested isolated resource
/// run. The upstream is external; telemetry, timers, UI and history retain
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
    public let fixtureManifest: PerformanceHistoryFixture.EquivalenceManifest
    public private(set) var shutdownError: String?

    private let clock: PerformanceWorkloadClock
    private let defaults: UserDefaults
    private let rawEnd: Date
    private let requestIdentity: PerformanceRequestIdentity
    private var stopped = false

    private init(
        store: MetricsStore, coordinator: MonitoringCoordinator,
        controller: MenuBarController, settings: AppSettings,
        historyDirectory: URL, preferencesSuite: String,
        historyKind: String, proxyPort: Int, clock: PerformanceWorkloadClock,
        defaults: UserDefaults, rawEnd: Date,
        fixtureManifest: PerformanceHistoryFixture.EquivalenceManifest,
        requestIdentity: PerformanceRequestIdentity
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
        self.fixtureManifest = fixtureManifest
        self.requestIdentity = requestIdentity
    }

    public static func start(
        upstream: URL, historyDirectory: URL, preferencesSuite: String,
        populated: Bool, fixtureEndingAt: Date? = nil,
        graphicsMode: PerformanceGraphicsDiagnostics.Mode = .normal,
        popoverAnimationsEnabled: Bool = true
    ) async throws -> PerformanceApplicationSession {
        guard upstream.scheme == "http", upstream.host == "127.0.0.1",
            let upstreamPort = upstream.port, (1...65535).contains(upstreamPort)
        else { throw PerformanceSessionError.invalid("A numeric loopback fixture is required") }
        guard let defaults = UserDefaults(suiteName: preferencesSuite),
            defaults.persistentDomain(forName: preferencesSuite) == nil
        else { throw PerformanceSessionError.invalid("Performance preferences must be new") }
        // Freeze the diagnostic mode before stores, native hosts or chart
        // canvases can be created. Ordinary launches never enable this path.
        try PerformanceGraphicsDiagnostics.shared.enable(mode: graphicsMode)
        if ProcessInfo.processInfo.environment["FLUXLLM_PERF_ARRIVAL_TIMING"] == "1" {
            PerformanceArrivalDiagnostics.shared.enable()
        }
        let settings = AppSettings(defaults: defaults)
        settings.backendSelection = .ollama
        settings.ollamaHost = "127.0.0.1"
        settings.ollamaPort = upstreamPort
        let source = "ollama|\(upstream.absoluteString)|"
        let rawEnd = fixtureEndingAt ?? Date()
        let clock = PerformanceWorkloadClock(
            now: populated ? rawEnd.addingTimeInterval(-MetricsStore.chartWindow) : rawEnd)
        let seeded =
            populated
            ? PerformanceHistoryFixture.makeSessionHistory(source: source, endingAt: rawEnd) : nil
        let store = MetricsStore(
            clock: { clock.now }, usageHistory: seeded?.usage, chartArchive: seeded?.archive)
        let proxyHolder = PerformanceProxyHolder()
        let requestIdentity = PerformanceRequestIdentity()
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store,
            client: PerformanceBackendClient(upstream: upstream, clock: clock),
            gpuMonitor: PerformanceWorkloadGPU(clock: clock),
            proxyFactory: { configuration, epoch in
                let proxy = ProxyManager(
                    listenPort: 0, ollamaHost: "127.0.0.1",
                    ollamaPort: configuration.baseURL.port!, metricsStore: store,
                    eventEpoch: epoch,
                    requestIDFactory: { requestIdentity.requestID(for: $0) })
                proxyHolder.proxy = proxy
                return proxy
            })
        let controller = MenuBarController(
            metricsStore: store, coordinator: coordinator, settings: settings,
            launchAtLogin: LaunchAtLoginController(service: PerformanceLoginService()),
            popoverAnimationsEnabled: popoverAnimationsEnabled)
        // Match AppDelegate: native hosts register their closed visibility
        // before monitoring or ingestion begins. Otherwise this standalone
        // store prepares thousands of snapshots that no app surface requests.
        PerformancePresentationCounters.shared.enable()
        controller.start()
        await coordinator.start()
        guard store.connectionState == .ready, store.historySource == source,
            let proxyPort = proxyHolder.proxy?.boundPort
        else {
            controller.stop()
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
                store.throughputSampleCount == MetricsStore.maxHistorySamples
                && store.systemGPUSampleCount == MetricsStore.maxHistorySamples
                && store.toolObservationSampleCount == MetricsStore.maxHistorySamples
                && seeded.requests == requests && seeded.toolCalls == requests
                && seeded.inputTokens == requests * 32
                && seeded.outputTokens == PerformanceHistoryFixture.persistentRequestCount
                    * PerformanceHistoryFixture.persistentOutputTokens
                    + PerformanceHistoryFixture.rawRequestCount
                    * PerformanceHistoryFixture.rawRequestOutputTokens
                && store.toolActivityEvents.count == PerformanceHistoryFixture.rawToolEventCount
                && store.archivedThroughputBucketCount >= 200
            store.usageScope = .sinceLaunch
            guard valid else {
                controller.stop()
                await coordinator.stop()
                throw PerformanceSessionError.invalid("The populated fixture lost required history")
            }
        }
        let manifest = PerformanceHistoryFixture.equivalenceManifest(
            store: store, endingAt: rawEnd, populated: populated)
        clock.fixed = nil
        // External preparation can take several seconds. Refresh fixture health
        // before wall-clock sampling, exactly as the next successful poll would.
        store.updateConnection(.ready, at: Date())
        store.startSampling()
        return PerformanceApplicationSession(
            store: store, coordinator: coordinator, controller: controller,
            settings: settings, historyDirectory: historyDirectory,
            preferencesSuite: preferencesSuite, historyKind: populated ? "populated" : "fresh",
            proxyPort: proxyPort, clock: clock, defaults: defaults, rawEnd: rawEnd,
            fixtureManifest: manifest, requestIdentity: requestIdentity)
    }

    /// Compact scalar snapshots avoid copying chart histories over the pipe.
    public func snapshot() -> [String: Any] {
        let usage = store.usageSummary(in: DateInterval(start: rawEnd, duration: 86400))
        let visibility = menuBarController.performanceVisibility
        let counters = PerformancePresentationCounters.shared.snapshot()
        return [
            "popover_lifecycle_policy": MenuBarController.performancePopoverLifecyclePolicy,
            "fixture_schema_version": PerformanceHistoryFixture.schemaVersion,
            "fixture_equivalence_sha256": fixtureManifest.sha256,
            "fixture_component_sha256": fixtureManifest.components,
            "synthetic_request_identity": requestIdentity.snapshot(),
            "synthetic_animation_policy": PerformanceAnimationRandomness.policy(
                deterministic: PerformanceGraphicsDiagnostics.shared.isEnabled),
            "arrival_diagnostics": PerformanceArrivalDiagnostics.shared.snapshot(),
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
            "optimized_chart_preparations": counters["optimized_chart_preparations"] as Any?
                ?? NSNull(),
            "shared_chart_normalization_builds": counters["shared_chart_normalization_builds"]
                as Any? ?? NSNull(),
            "shared_chart_preparations": counters["shared_chart_preparations"] as Any? ?? NSNull(),
            "streamed_bodies_without_promises": counters["streamed_bodies_without_promises"] as Any?
                ?? NSNull(),
            "rail_frame_clock_ticks": counters["rail_frame_clock_ticks"] as Any? ?? NSNull(),
            "rail_timeline_content_updates": counters["rail_timeline_content_updates"] as Any?
                ?? NSNull(),
            "ordered_chart_publication_queries": counters["ordered_chart_publication_queries"]
                as Any? ?? NSNull(),
            "chart_publication_full_sorts": counters["chart_publication_full_sorts"] as Any?
                ?? NSNull(),
            "direct_tool_plot_builds": counters["direct_tool_plot_builds"] as Any? ?? NSNull(),
            "legacy_tool_plot_builds": counters["legacy_tool_plot_builds"] as Any? ?? NSNull(),
            "unique_tool_trace_builds": counters["unique_tool_trace_builds"] as Any? ?? NSNull(),
            "reused_tool_trace_builds": counters["reused_tool_trace_builds"] as Any? ?? NSNull(),
            "ungrouped_native_canvas_draws": counters["ungrouped_native_canvas_draws"] as Any?
                ?? NSNull(),
            "grouped_native_canvas_draws": counters["grouped_native_canvas_draws"] as Any?
                ?? NSNull(),
            "suppressed_arrival_effects": counters["suppressed_arrival_effects"] as Any?
                ?? NSNull(),
            "tool_path_input_points": counters["tool_path_input_points"] as Any? ?? NSNull(),
            "tool_path_output_points": counters["tool_path_output_points"] as Any? ?? NSNull(),
            "metal_arrival_frames": counters["metal_arrival_frames"] as Any? ?? NSNull(),
            "metal_arrival_submissions": counters["metal_arrival_submissions"] as Any? ?? NSNull(),
            "metal_arrival_failures": counters["metal_arrival_failures"] as Any? ?? NSNull(),
            "history_tool_order_builds": counters["history_tool_order_builds"] as Any? ?? NSNull(),
            "history_completed_order_builds": counters["history_completed_order_builds"] as Any?
                ?? NSNull(),
            "history_tool_order_insertions": counters["history_tool_order_insertions"] as Any?
                ?? NSNull(),
            "history_completed_order_insertions": counters["history_completed_order_insertions"]
                as Any? ?? NSNull(),
            "canvas_draws": counters["canvas_draws"] as Any? ?? NSNull(),
            "metal_frames": counters["metal_frames"] as Any? ?? NSNull(),
            "graphics_diagnostics": PerformanceGraphicsDiagnostics.shared.snapshot(),
            "popover_animations_enabled": menuBarController.performancePopoverAnimationsEnabled,
            "raw_samples": store.throughputSampleCount,
            "archive_buckets": store.archivedThroughputBucketCount,
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
            "logging_enabled": store.diagnosticLogger.isEnabled,
            "logging_supported": true,
            "logging_error": store.diagnosticLogger.errorMessage as Any? ?? NSNull(),
            "logging_dropped_records": store.diagnosticLogger.droppedCount,
            "shutdown_error": shutdownError as Any? ?? NSNull(),
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
        progress?("logging_drain")
        do {
            try await store.diagnosticLogger.setEnabled(false)
        } catch {
            shutdownError =
                store.diagnosticLogger.errorMessage ?? "Diagnostic logging failed to close."
            progress?("logging_failed")
        }
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
