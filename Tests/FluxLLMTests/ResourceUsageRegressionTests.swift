import AppKit
import Darwin
import Foundation
import XCTest

@testable import FluxLLM

/// Opt-in, isolated-process reproduction. The runner supplies a separate mock
/// upstream/load-driver process; no inference or client buffering occurs here.
@MainActor
final class ResourceUsageRegressionTests: XCTestCase {
    func testSyntheticAppResourceUsage() throws {
        guard ProcessInfo.processInfo.environment["FLUXLLM_PERF_ENABLED"] == "1" else {
            throw XCTSkip("Run the prebuilt test through scripts/run_performance_checks.py")
        }
        // A bare XCTest async run loop does not dispatch AppKit window events.
        // Run the native application loop so visibility, animation and rendering
        // follow the shipping app's lifecycle without a synthetic polling timer.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let completion = ResourceTestCompletion()
        let workload = Task { @MainActor in
            do { try await runSyntheticAppResourceUsage() } catch { completion.error = error }
            completion.finished = true
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
            {
                NSApp.postEvent(event, atStart: false)
            }
        }
        NSApp.run()
        withExtendedLifetime(workload) {}
        try resourceRequire(
            completion.finished, "The native application loop exited before measurement completed")
        if let error = completion.error { throw error }
    }

    func testSessionFixturePreservesDimensionsAndCreatesNoHistoryFiles() throws {
        let endingAt = Date(timeIntervalSince1970: 1_800_000_000)
        let source = "ollama|http://127.0.0.1:11434|"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SessionFixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let seeded = ResourceHistoryFixture.makeSessionHistory(source: source, endingAt: endingAt)
        let clock = ResourceWorkloadClock(now: endingAt.addingTimeInterval(-3600))
        let store = MetricsStore(
            clock: { clock.now }, historyDirectory: directory,
            usageHistory: seeded.usage, chartArchive: seeded.archive)
        store.setChartPresentationDemand(false, consumer: .dashboard)
        store.beginBackendSession(kind: .ollama, epoch: UUID(), sourceID: source)
        ResourceHistoryFixture.seedRawHistory(store: store, endingAt: endingAt) { clock.fixed = $0 }
        store.usageScope = .selectedPeriod
        let interval = DateInterval(
            start: endingAt.addingTimeInterval(-8 * 86400), end: endingAt.addingTimeInterval(1))
        let actual = store.usageSummary(in: interval)
        XCTAssertEqual(actual.requests, 19_256)
        XCTAssertEqual(actual.toolCalls, 19_256)
        XCTAssertEqual(actual.inputTokens, 19_256 * 32)
        XCTAssertEqual(actual.outputTokens, 19_000 * 128 + 256 * 520)
        XCTAssertEqual(actual.activeRequests, 0)
        XCTAssertFalse(actual.isPartial)
        XCTAssertEqual(seeded.usage.toolEvents(source: source, interval: interval).count, 38_512)
        let expectedTimes = (0..<7_201).map {
            endingAt.addingTimeInterval(-3600 + Double($0) * 0.5)
        }
        XCTAssertEqual(store.tpsHistory.map(\.timestamp), expectedTimes)
        XCTAssertEqual(store.systemGPUHistory.map(\.timestamp), expectedTimes)
        XCTAssertEqual(store.toolObservationHistory.map(\.timestamp), expectedTimes)
        XCTAssertEqual(store.systemGPUHistory.map(\.value), Array(repeating: 42.0, count: 7_201))
        XCTAssertEqual(store.throughputSampleCount, 7_201)
        XCTAssertEqual(store.systemGPUSampleCount, 7_201)
        XCTAssertEqual(store.toolObservationSampleCount, 7_201)
        XCTAssertEqual(store.toolActivityEvents.count, 512)
        XCTAssertGreaterThanOrEqual(store.archivedThroughputBucketCount, 200)
        let archived = seeded.archive.history(
            source: source, before: expectedTimes[0], now: endingAt)
        XCTAssertEqual(
            store.archivedThroughputBucketCount, archived.throughput.reduce(0) { $0 + $1.count })
        XCTAssertEqual(
            store.chartPresentation.archive, .empty,
            "Hidden setup must not retain presentation arrays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func runSyntheticAppResourceUsage() async throws {
        let environment = ProcessInfo.processInfo.environment
        let scenario = try ResourceScenario(environment: environment)
        executionTimeAllowance =
            Double(scenario.cycles) * (scenario.duration_seconds + scenario.settle_seconds) + 120
        resourceLog("Starting \(scenario.ui)/\(scenario.history)/\(scenario.activity)")
        let upstream = try XCTUnwrap(
            environment["FLUXLLM_PERF_UPSTREAM"].flatMap(URL.init(string:)))
        try resourceRequire(
            upstream.scheme == "http" && upstream.host == "127.0.0.1",
            "The performance upstream must be an isolated loopback fixture")
        let resultPath = try XCTUnwrap(environment["FLUXLLM_PERF_RESULT"])
        let parent =
            environment["FLUXLLM_PERF_TMPDIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory
        let directory = parent.appendingPathComponent(
            "history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let defaultsName = "FluxLLM.Performance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let settings = AppSettings(defaults: defaults)
        settings.backendSelection = .ollama
        settings.ollamaHost = "127.0.0.1"
        settings.ollamaPort = try XCTUnwrap(upstream.port)
        let source = "ollama|\(upstream.absoluteString)|"
        let rawEnd = Date()
        let clock = ResourceWorkloadClock(now: rawEnd.addingTimeInterval(-3600))
        let seeded =
            scenario.history == "populated"
            ? ResourceHistoryFixture.makeSessionHistory(source: source, endingAt: rawEnd) : nil
        let usage = seeded?.usage ?? UsageHistory(now: rawEnd)
        let archive = seeded?.archive ?? ChartHistoryArchive(now: rawEnd)
        let store = MetricsStore(clock: { clock.now }, usageHistory: usage, chartArchive: archive)
        let proxyHolder = ResourceProxyHolder()
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store,
            client: FixtureOnlyBackendClient(upstream: upstream, clock: clock),
            gpuMonitor: ResourceWorkloadGPU(clock: clock),
            proxyFactory: { configuration, epoch in
                let proxy = ProxyManager(
                    listenPort: 0, ollamaHost: "127.0.0.1",
                    ollamaPort: configuration.baseURL.port!, metricsStore: store, eventEpoch: epoch)
                proxyHolder.proxy = proxy
                return proxy
            })
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let controller = MenuBarController(
            metricsStore: store, coordinator: coordinator, settings: settings)
        let control = ResourceFixtureControl(upstream: upstream)
        do {
            resourceLog("Starting production coordinator")
            await coordinator.start()
            resourceLog("Production coordinator started")
            try resourceRequire(
                store.historySource == source, "Fixture source did not match the selected backend")
            try resourceRequire(store.connectionState == .ready, "Synthetic upstream was not ready")
            let port = try XCTUnwrap(proxyHolder.proxy?.boundPort)
            if scenario.history == "populated" {
                ResourceHistoryFixture.seedRawHistory(store: store, endingAt: rawEnd) {
                    clock.fixed = $0
                }
                resourceLog("Raw history seeded")
                try resourceRequire(
                    store.throughputSampleCount == MetricsStore.maxHistorySamples,
                    "Populated fixture did not fill the retained raw history")
                try resourceRequire(
                    store.systemGPUSampleCount == MetricsStore.maxHistorySamples
                        && store.toolObservationSampleCount == MetricsStore.maxHistorySamples,
                    "Populated fixture lost GPU/tool observation history")
                store.usageScope = .selectedPeriod
                let seeded = store.usageSummary(
                    in: DateInterval(
                        start: rawEnd.addingTimeInterval(-8 * 86400),
                        end: rawEnd.addingTimeInterval(1)))
                let requestCount =
                    ResourceHistoryFixture.persistentRequestCount
                    + ResourceHistoryFixture.rawRequestCount
                try resourceRequire(
                    seeded.requests == requestCount && seeded.toolCalls == requestCount
                        && seeded.inputTokens == requestCount * 32
                        && seeded.outputTokens == ResourceHistoryFixture.persistentRequestCount
                            * ResourceHistoryFixture.persistentOutputTokens
                            + ResourceHistoryFixture.rawRequestCount
                            * ResourceHistoryFixture.rawRequestOutputTokens,
                    "Populated usage history is incomplete; reduced work cannot pass")
                try resourceRequire(
                    store.toolActivityEvents.count == ResourceHistoryFixture.rawToolEventCount
                        && store.archivedThroughputBucketCount >= 200,
                    "Populated tool events or older chart archive are incomplete")
                store.usageScope = .sinceLaunch
            }
            clock.useWallClock()
            // Fixture construction is outside this legacy test-host measurement.
            // The separate actual-app collector records launch/setup resources.
            controller.start()
            store.startSampling()
            try await Task.sleep(for: .seconds(2))

            let probe = ProcessResourceProbe()
            var phases: [[String: Any]] = []
            var validatedRequests = 0
            var validatedChunks = 0
            var validatedTools = 0
            var validatedResults = 0
            let measuredPhasesStartedAt = Date()
            for cycle in 1...scenario.cycles {
                resourceLog("Preparing UI for cycle \(cycle)")
                try await prepareUI(scenario.ui, controller: controller)
                resourceLog("UI ready for cycle \(cycle)")
                let before = store.usageSummary(in: DateInterval(start: rawEnd, duration: 86400))
                let cycleStartedAt = Date()
                let phase = try await measurePhase(
                    name: "workload", cycle: cycle, seconds: scenario.duration_seconds,
                    probe: probe, store: store, ui: scenario.ui,
                    expectsLiveGeneration: scenario.activity != "idle",
                    start: {
                        if scenario.activity != "idle" {
                            try await control.start(
                                proxyPort: port, seconds: scenario.duration_seconds,
                                rate: scenario.activity == "ordinary" ? 40 : 200, cycle: cycle)
                        }
                    },
                    finished: {
                        scenario.activity == "idle" ? true : !(try await control.status()).running
                    })
                phases.append(phase)
                if scenario.activity != "idle" {
                    let status = try await control.status()
                    try resourceRequire(status.error == nil, status.error ?? "Fixture failed")
                    try resourceRequire(
                        status.forwarding_verified, "Incremental byte/record forwarding failed")
                    try resourceRequire(
                        status.completed_requests == 2,
                        "The two overlapping requests did not finish")
                    try resourceRequire(
                        status.received_chunks == status.expected_chunks,
                        "Stream fragments were lost")
                    try await waitForCondition("Final telemetry did not reach the store") {
                        store.usageSummary(in: DateInterval(start: rawEnd, duration: 86400))
                            .activeRequests == 0
                    }
                    let after = store.usageSummary(in: DateInterval(start: rawEnd, duration: 86400))
                    try resourceRequire(
                        after.requests - before.requests == status.completed_requests,
                        "Request totals disagree with the synthetic workload")
                    try resourceRequire(
                        after.outputTokens - before.outputTokens == status.expected_output_tokens,
                        "Authoritative output counts were not preserved")
                    try resourceRequire(
                        (after.inputTokens ?? 0) - (before.inputTokens ?? 0)
                            == status.expected_prompt_tokens,
                        "Authoritative input counts were not preserved")
                    try resourceRequire(
                        after.toolCalls - before.toolCalls == status.tool_calls,
                        "Tool calls were lost or counted twice")
                    let submittedResults = store.toolActivityEvents.filter {
                        $0.kind == .resultSubmission && $0.timestamp >= cycleStartedAt
                    }.count
                    try resourceRequire(
                        submittedResults == status.tool_results && submittedResults == 2,
                        "Tool result submissions were not preserved")
                    validatedRequests += status.completed_requests
                    validatedChunks += status.received_chunks
                    validatedTools += status.tool_calls
                    validatedResults += submittedResults
                } else {
                    let after = store.usageSummary(in: DateInterval(start: rawEnd, duration: 86400))
                    try resourceRequire(after == before, "Idle monitoring changed usage totals")
                }
                phases.append(
                    try await measurePhase(
                        name: "settled", cycle: cycle, seconds: scenario.settle_seconds,
                        probe: probe, store: store, ui: scenario.ui))
            }

            let measuredPhasesEndedAt = Date()
            store.stopSampling()
            controller.stop()
            let interval = DateInterval(
                start: rawEnd.addingTimeInterval(-8 * 86400),
                end: measuredPhasesEndedAt.addingTimeInterval(1))
            store.usageScope = .selectedPeriod
            let expectedSession = store.usageSummary(in: interval)
            let seedResults =
                scenario.history == "populated"
                ? ResourceHistoryFixture.persistentRequestCount
                    + ResourceHistoryFixture.rawRequestCount : 0
            try resourceRequire(
                expectedSession.requests == seedResults + validatedRequests,
                "Session history lost completed requests")
            try resourceRequire(
                expectedSession.toolCalls == seedResults + validatedTools,
                "Session history lost tool calls")
            try validateSessionHistory(
                usage: usage, archive: archive, source: source, interval: interval,
                expectedUsage: expectedSession, expectedResults: seedResults + validatedResults,
                measuredFrom: measuredPhasesStartedAt, measuredThrough: measuredPhasesEndedAt)
            await coordinator.stop()
            try resourceRequire(
                usage.summary(
                    scope: .selectedPeriod, source: source, interval: interval, now: Date())
                    == expectedSession,
                "Stopping monitoring changed completed session usage")
            try resourceRequire(
                try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                "Session history unexpectedly wrote files")
            let nextSession = UsageHistory(directory: directory, now: Date())
            try resourceRequire(
                nextSession.summary(
                    scope: .sinceLaunch, source: source, interval: interval, now: Date()
                ).requests == 0,
                "A new session unexpectedly inherited usage")
            let report: [String: Any] = [
                "schema_version": 1, "scenario": scenario.json,
                "environment": resourceEnvironment(), "phases": phases,
                "validation": [
                    "passed": true, "requests": validatedRequests, "chunks": validatedChunks,
                    "tool_calls": validatedTools, "tool_results": validatedResults,
                    "session_history_verified": true, "history_files_absent": true,
                ],
                "test_bundle_path": Bundle(for: ResourceUsageRegressionTests.self).bundleURL.path,
                "measurement_notes": [
                    ProcessResourceProbe.gpuMeasurementCaveat,
                    "CPU includes the test host and observer. Observer read-window CPU also includes concurrent app work; never subtract it.",
                    "Peak footprint is sampled at about 1 Hz, augmented by any new kernel lifetime high-water mark during the phase.",
                    "Mock upstream and network consumer run in a separate process. System GPU polling is real; chart GPU values are fixed synthetic data.",
                ],
            ]
            try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
            )
            .write(to: URL(fileURLWithPath: resultPath), options: .atomic)
        } catch {
            resourceLog("Failed with \(String(reflecting: type(of: error))): \(error)")
            controller.stop()
            store.stopSampling()
            await coordinator.stop()
            throw error
        }
    }

    private func validateSessionHistory(
        usage: UsageHistory, archive: ChartHistoryArchive, source: String, interval: DateInterval,
        expectedUsage: UsageSummary, expectedResults: Int,
        measuredFrom: Date, measuredThrough: Date
    ) throws {
        let summary = usage.summary(
            scope: .selectedPeriod, source: source, interval: interval, now: measuredThrough)
        try resourceRequire(
            summary == expectedUsage, "Session usage differs from the measured workload")
        try resourceRequire(
            usage.toolEvents(source: source, interval: interval)
                .filter { $0.kind == .resultSubmission }.count == expectedResults,
            "Session history lost tool result submissions")
        let retained = archive.history(
            source: source, before: measuredThrough.addingTimeInterval(1), now: measuredThrough)
        let oldestAllowed = max(measuredFrom, measuredThrough.addingTimeInterval(-5))
        for (name, series) in [
            ("throughput", retained.throughput), ("GPU", retained.systemGPU),
            ("tool observation", retained.toolObservation),
        ] {
            let latest = series.flatMap { $0 }.map(\.end).max()
            try resourceRequire(
                latest.map { $0 > measuredFrom && $0 >= oldestAllowed } == true,
                "The in-memory \(name) archive did not collect recent measured samples")
        }
    }

    private func prepareUI(_ mode: String, controller: MenuBarController) async throws {
        if mode == "never-opened" { return }
        // Preserve the production popover delegate so actual visibility gates
        // control chart hosts throughout the same native paths used by the app.
        let popover = try XCTUnwrap(
            Mirror(reflecting: controller).children.first { $0.label == "popover" }?.value
                as? NSPopover)
        controller.performanceSetPopoverVisible(true)
        try await waitForCondition("Popover did not finish opening", timeout: 10) {
            popover.isShown
                && popover.contentViewController?.view.window?.occlusionState.contains(.visible)
                    == true
        }
        controller.performanceSetPopoverVisible(false)
        try await waitForCondition("Popover did not release its host after closing", timeout: 10) {
            !popover.isShown && popover.contentViewController == nil
        }
        controller.performanceSetDashboardVisible(true)
        try await waitForCondition("Dashboard did not become visible", timeout: 10) {
            NSApp.windows.contains {
                $0 is DashboardWindow && $0.isVisible && $0.occlusionState.contains(.visible)
            }
        }
        let window = try XCTUnwrap(NSApp.windows.compactMap { $0 as? DashboardWindow }.first)
        try resourceRequire(
            window.isVisible && window.occlusionState.contains(.visible),
            "A visible dashboard requires an unobscured logged-in desktop")
        if mode == "closed" {
            controller.performanceSetDashboardVisible(false)
            try await waitForCondition("Dashboard did not close", timeout: 10) { !window.isVisible }
            try resourceRequire(
                !window.isVisible && !popover.isShown, "The retained UI is still visible")
        }
    }

    private func measurePhase(
        name: String, cycle: Int, seconds: Double, probe: ProcessResourceProbe,
        store: MetricsStore, ui: String, expectsLiveGeneration: Bool = false,
        start: () async throws -> Void = {}, finished: () async throws -> Bool = { true }
    ) async throws -> [String: Any] {
        let first = try await probe.sample()
        var last = first
        var footprintPeak = first.physicalFootprintBytes
        var gpuSeconds = 0.0
        var gpuUnavailable: String?
        var publication = store.chartPresentation.publicationID
        var publicationCount = 0
        var sampleCount = 0
        var previousLiveTokens = 0
        var lastLiveProgressAt = first.uptimeSeconds
        var liveProgressCount = 0
        try await start()
        resourceLog("\(name) cycle \(cycle) started")
        while true {
            try await Task.sleep(for: .seconds(1))
            let next = try await probe.sample()
            footprintPeak = max(footprintPeak, next.physicalFootprintBytes)
            if next.lifetimePeakPhysicalFootprintBytes > first.lifetimePeakPhysicalFootprintBytes {
                footprintPeak = max(footprintPeak, next.lifetimePeakPhysicalFootprintBytes)
            }
            if let execution = next.gpu.executionSeconds {
                gpuSeconds += execution
            } else {
                gpuUnavailable = next.gpu.unavailableReason ?? "GPU measurement unavailable"
            }
            last = next
            sampleCount += 1
            let elapsed = last.uptimeSeconds - first.uptimeSeconds
            if expectsLiveGeneration, elapsed < seconds - 2 {
                let liveLanes = store.requestLanes.filter { !$0.terminal && $0.endedAt == nil }
                let tokens = liveLanes.reduce(0) { $0 + $1.outputTokens }
                if tokens > previousLiveTokens {
                    liveProgressCount += 1
                    lastLiveProgressAt = last.uptimeSeconds
                }
                previousLiveTokens = tokens
                if elapsed >= 5 {
                    try resourceRequire(
                        liveLanes.count == 2 && store.rateIsAvailable && store.currentTPS > 0
                            && last.uptimeSeconds - lastLiveProgressAt <= 5,
                        "Live telemetry stalled or was discarded while forwarding continued")
                }
            }
            if store.chartPresentation.publicationID != publication {
                publicationCount += 1
                publication = store.chartPresentation.publicationID
            }
            try resourceRequire(
                store.throughputSampleCount <= MetricsStore.maxHistorySamples,
                "Raw history exceeded its retention cap")
            let dashboard = NSApp.windows.compactMap { $0 as? DashboardWindow }.first
            if ui == "visible" {
                try resourceRequire(
                    dashboard?.isVisible == true
                        && dashboard?.occlusionState.contains(.visible) == true,
                    "Dashboard became hidden/occluded during a visible measurement")
            } else {
                try resourceRequire(
                    dashboard?.isVisible != true,
                    "Dashboard became visible during a hidden measurement")
            }
            // An excessively delayed final sample can dilute CPU/GPU averages.
            // Reject it even when the external workload has already completed.
            try resourceRequire(
                elapsed <= seconds + 5, "Measurement exceeded its allowed phase duration")
            if elapsed >= seconds, try await finished() { break }
        }
        if ui == "visible" {
            try resourceRequire(
                publicationCount >= max(1, Int(seconds / 3)),
                "Visible chart publication stalled; skipped work cannot pass resource checks")
        } else {
            try resourceRequire(
                publicationCount == 0, "A hidden surface continued publishing charts")
        }
        if expectsLiveGeneration {
            try resourceRequire(
                liveProgressCount >= Int(seconds / 3), "Insufficient live telemetry progress")
        }
        let elapsed = last.uptimeSeconds - first.uptimeSeconds
        resourceLog(
            "\(name) cycle \(cycle): \(String(format: "%.1f", elapsed))s, \(publicationCount) chart publications observed"
        )
        return [
            "name": name, "cycle": cycle, "elapsed_seconds": elapsed,
            "cpu_seconds": last.cpuSeconds - first.cpuSeconds,
            "physical_footprint_start_bytes": first.physicalFootprintBytes,
            "physical_footprint_end_bytes": last.physicalFootprintBytes,
            "physical_footprint_peak_bytes": footprintPeak,
            "lifetime_peak_footprint_bytes": last.lifetimePeakPhysicalFootprintBytes,
            "gpu_seconds": gpuUnavailable == nil ? (gpuSeconds as Any) : NSNull(),
            "gpu_unavailable_reason": gpuUnavailable.map { $0 as Any } ?? NSNull(),
            "disk_write_bytes": last.diskBytesWritten - first.diskBytesWritten,
            "logical_write_bytes": last.logicalBytesWritten - first.logicalBytesWritten,
            "interrupt_wakeups": last.interruptWakeups - first.interruptWakeups,
            "package_idle_wakeups": last.packageIdleWakeups - first.packageIdleWakeups,
            "observer_cpu_seconds": last.observerCPUSeconds - first.observerCPUSeconds,
            "observer_elapsed_seconds": last.observerElapsedSeconds - first.observerElapsedSeconds,
            "resource_samples": sampleCount, "chart_publications_observed": publicationCount,
            "live_progress_observations": liveProgressCount,
        ]
    }
}

// Preserve the field names in the performance JSON protocol.
// swift-format-ignore: AlwaysUseLowerCamelCase
private struct ResourceScenario: Decodable {
    let ui: String
    let history: String
    let activity: String
    let duration_seconds: Double
    let cycles: Int
    let settle_seconds: Double

    init(environment: [String: String]) throws {
        guard let value = environment["FLUXLLM_PERF_SCENARIO"]?.data(using: .utf8) else {
            throw ResourceWorkloadError.invalid("Missing FLUXLLM_PERF_SCENARIO")
        }
        self = try JSONDecoder().decode(Self.self, from: value)
        try resourceRequire(
            ["never-opened", "visible", "closed"].contains(ui), "Unknown UI scenario")
        try resourceRequire(["fresh", "populated"].contains(history), "Unknown history scenario")
        try resourceRequire(
            ["idle", "ordinary", "high-rate"].contains(activity), "Unknown activity scenario")
        try resourceRequire(
            duration_seconds.isFinite && (65...600).contains(duration_seconds),
            "Duration must be 65–600 seconds")
        try resourceRequire((1...20).contains(cycles), "Cycles must be 1–20")
        try resourceRequire(
            settle_seconds.isFinite && (5...120).contains(settle_seconds),
            "Settle time must be 5–120 seconds")
    }

    var json: [String: Any] {
        [
            "ui": ui, "history": history, "activity": activity,
            "duration_seconds": duration_seconds,
            "cycles": cycles, "settle_seconds": settle_seconds,
        ]
    }
}

@MainActor
private final class ResourceWorkloadClock {
    var fixed: Date?
    var now: Date { fixed ?? Date() }
    init(now: Date) { fixed = now }
    func useWallClock() { fixed = nil }
}

@MainActor
private final class ResourceProxyHolder {
    var proxy: ProxyManager?
}

@MainActor
private final class ResourceTestCompletion {
    var finished = false
    var error: Error?
}

/// Discovery must never probe the user's real Ollama or saved endpoints. Actual
/// fixture HTTP requests still use the production bounded transport and parser.
private actor FixtureOnlyBackendClient: BackendClientProtocol {
    let upstream: URL
    let clock: ResourceWorkloadClock
    let client = HTTPBackendClient()
    init(upstream: URL, clock: ResourceWorkloadClock) {
        self.upstream = upstream
        self.clock = clock
    }
    func detect(at baseURL: URL) async throws -> DetectedBackend? {
        guard baseURL == upstream else { return nil }
        return try await client.detect(at: baseURL)
    }
    func sample(_ configuration: BackendConfiguration) async throws -> BackendSample {
        try resourceRequire(
            configuration.baseURL == upstream, "Attempted to poll a non-fixture backend")
        let value = try await client.sample(configuration)
        return await BackendSample(
            kind: .ollama, timestamp: clock.now, model: value.model,
            isReady: value.isReady, detail: value.detail)
    }
    func reset() async { await client.reset() }
}

/// Preserve production registry polling cost while keeping chart input independent
/// of other apps' GPU load. This value is never used as a resource measurement.
private actor ResourceWorkloadGPU: BackendGPUMonitoring {
    let clock: ResourceWorkloadClock
    let monitor = SystemGPUMonitor()
    init(clock: ResourceWorkloadClock) { self.clock = clock }
    func sample(_ configuration: BackendConfiguration?) async -> GPUActivitySample {
        _ = await monitor.sample(configuration)
        return await GPUActivitySample(
            timestamp: clock.now, activityPercent: 42,
            source: ResourceHistoryFixture.gpuSource, scope: .system)
    }
    func reset() async { await monitor.reset() }
}

// Preserve the field names in the performance JSON protocol.
// swift-format-ignore: AlwaysUseLowerCamelCase
private struct ResourceFixtureStatus: Decodable {
    let running: Bool
    let completed_requests: Int
    let expected_output_tokens: Int
    let expected_prompt_tokens: Int
    let tool_calls: Int
    let tool_results: Int
    let received_chunks: Int
    let expected_chunks: Int
    let forwarding_verified: Bool
    let error: String?
}

@MainActor
private final class ResourceFixtureControl {
    let upstream: URL
    let session = URLSession(configuration: .ephemeral)
    init(upstream: URL) { self.upstream = upstream }
    deinit { session.invalidateAndCancel() }
    func start(proxyPort: Int, seconds: Double, rate: Int, cycle: Int) async throws {
        var request = URLRequest(url: upstream.appendingPathComponent("control/start"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "proxy_url": "http://127.0.0.1:\(proxyPort)", "duration_seconds": seconds,
            "rate_hz": rate, "concurrency": 2, "cycle": cycle,
        ])
        _ = try await fetch(request)
    }
    func status() async throws -> ResourceFixtureStatus {
        try await JSONDecoder().decode(
            ResourceFixtureStatus.self,
            from: fetch(URLRequest(url: upstream.appendingPathComponent("control/status"))))
    }
    private func fetch(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        try resourceRequire(
            (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true,
            "The external fixture control request failed")
        return data
    }
}

private enum ResourceWorkloadError: Error {
    case invalid(String)
}

private func resourceRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw ResourceWorkloadError.invalid(message) }
}

private func resourceLog(_ message: String) {
    FileHandle.standardError.write(Data("Performance: \(message)\n".utf8))
}

@MainActor
private func resourceEnvironment() -> [String: String] {
    var size = 0
    var hardware = "unavailable"
    if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
        var buffer = [CChar](repeating: 0, count: size)
        if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 {
            hardware = String(
                decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
    #if DEBUG
        let configuration = "debug"
    #else
        let configuration = "release"
    #endif
    let display = NSScreen.screens.map {
        "\(Int($0.frame.width))x\(Int($0.frame.height))@\($0.backingScaleFactor)/\($0.maximumFramesPerSecond)Hz"
    }.joined(separator: ";")
    return [
        "os": ProcessInfo.processInfo.operatingSystemVersionString, "hardware": hardware,
        "build_configuration": configuration, "display": display.isEmpty ? "unavailable" : display,
        "gpu_method": ProcessResourceProbe.gpuMeasurementMethod, "workload_version": "1",
    ]
}
