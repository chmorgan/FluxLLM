import AppKit
import SwiftUI
import XCTest

@testable import FluxLLM

/// Offscreen layout verifies content sizing and produces optional review images.
/// This does not exercise status-item clicks or operating-system popover placement.
@MainActor
final class DashboardLayoutTests: XCTestCase {
    func testCompactDashboardFitsContentAcrossActivityAndConfigurationStates() throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        for scheme in [ColorScheme.light, .dark] {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            let configure = MetricsStore()
            configure.updateConnection(.needsConfiguration, message: "Select a backend")
            let unavailable = makeStore(active: true, gpuAvailable: false)
            unavailable.updateConnection(.unavailable, message: "Backend not responding")
            let gpuStale = makeStore(active: true)
            gpuStale.sample(at: gpuStale.sampleDate.addingTimeInterval(6))
            let gpuHistoryExpired = makeStore(active: true)
            gpuHistoryExpired.sample(at: gpuHistoryExpired.sampleDate.addingTimeInterval(61))
            var heights: [String: CGFloat] = [:]
            for (name, store) in [
                ("active", makeStore(active: true)), ("idle", makeStore(active: false)),
                (
                    "long-model",
                    makeStore(
                        active: true, kind: .rapidMLX,
                        model: "mlx-community/Qwen3.8-27B-Instruct-Reasoning-Long-Context-8bit")
                ),
                ("unknown-model", makeStore(active: true, model: nil)),
                ("estimated", makeStore(active: true, basis: .estimated)),
                ("ollama-response", makeStore(active: true, kind: .ollama)),
                ("ollama-tools", makeStore(active: true, kind: .ollama, toolActivity: true)),
                ("ollama-awaiting-output", makeAwaitingOutputStore()),
                ("ollama-idle", makeIdleOllamaStore()),
                ("irregular", makeIrregularStore()),
                ("configure", configure), ("unavailable", unavailable),
                ("gpu-stale", gpuStale), ("gpu-history-expired", gpuHistoryExpired),
            ] {
                let view = NSHostingView(
                    rootView: DashboardView(isCompact: true).environment(store)
                        .environment(\.colorScheme, scheme)
                        .frame(width: DashboardView.compactWidth)
                        .background(Color(nsColor: .windowBackgroundColor)))
                view.appearance = appearance
                let size = view.fittingSize
                XCTAssertEqual(size.width, 360, accuracy: 1)
                XCTAssertGreaterThan(
                    size.height, 260, "Primary metrics and dashboard action must fit")
                XCTAssertLessThanOrEqual(
                    size.height, 490, "Compact surfaces must not reserve a dashboard-sized footer")
                heights[name] = size.height
                view.setFrameSize(size)
                view.layoutSubtreeIfNeeded()
                try renderIfRequested(
                    view, named: "dropdown-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
            XCTAssertEqual(
                try XCTUnwrap(heights["active"]), try XCTUnwrap(heights["idle"]), accuracy: 1,
                "The first request must fill existing metric rows without resizing the popover")
            XCTAssertEqual(
                try XCTUnwrap(heights["long-model"]), try XCTUnwrap(heights["active"]),
                accuracy: 1, "A long provider/model line must truncate without wrapping")
            XCTAssertEqual(
                try XCTUnwrap(heights["unknown-model"]), try XCTUnwrap(heights["active"]),
                accuracy: 1, "The model belongs in the header, without a duplicate details row")
            XCTAssertEqual(
                try XCTUnwrap(heights["ollama-response"]), try XCTUnwrap(heights["ollama-idle"]),
                accuracy: 1, "Ollama's first response must fill its existing statistics slot")
            XCTAssertEqual(
                try XCTUnwrap(heights["ollama-tools"]), try XCTUnwrap(heights["ollama-idle"]),
                accuracy: 1, "Tool events must use the already reserved chart legend and plot")
            XCTAssertEqual(
                try XCTUnwrap(heights["ollama-awaiting-output"]),
                try XCTUnwrap(heights["ollama-idle"]), accuracy: 1,
                "An open request with high GPU and zero output must fill existing chart slots")
            for name in ["irregular", "unavailable", "gpu-stale", "gpu-history-expired"] {
                XCTAssertEqual(
                    try XCTUnwrap(heights[name]), try XCTUnwrap(heights["active"]), accuracy: 1,
                    "A change in telemetry availability must not change the compact card layout")
            }
        }
    }

    func testDashboardAndBackendSettingsRenderAtTheirNativeWindowSizes() throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let store = makeStore(active: true)
        for scheme in [ColorScheme.light, .dark] {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            for (name, size, previewStore) in [
                ("minimum", DashboardSizingPolicy.minimumContentSize(forWidth: 740), store),
                ("narrow", DashboardSizingPolicy.minimumContentSize(forWidth: 360), store),
                ("narrowest", DashboardSizingPolicy.minimumContentSize(forWidth: 320), store),
                (
                    "stacked-boundary", DashboardSizingPolicy.minimumContentSize(forWidth: 519),
                    store
                ),
                ("wide-boundary", DashboardSizingPolicy.minimumContentSize(forWidth: 520), store),
                ("compressed", NSSize(width: 740, height: 632), store),
                ("active", DashboardView.preferredWindowSize, store),
                ("tall", NSSize(width: 740, height: 1100), store),
                ("wide", NSSize(width: 1100, height: 704), store),
                ("ollama-idle", DashboardView.preferredWindowSize, makeIdleOllamaStore()),
                (
                    "ollama-awaiting-output", DashboardView.preferredWindowSize,
                    makeAwaitingOutputStore()
                ),
                (
                    "ollama-active", DashboardView.preferredWindowSize,
                    makeStore(active: true, kind: .ollama)
                ),
                (
                    "ollama-tools", DashboardView.preferredWindowSize,
                    makeStore(active: true, kind: .ollama, toolActivity: true)
                ),
                (
                    "ollama-tools-minimum", DashboardSizingPolicy.minimumContentSize(forWidth: 740),
                    makeStore(active: true, kind: .ollama, toolActivity: true)
                ),
                (
                    "ollama-tools-compressed", NSSize(width: 740, height: 632),
                    makeStore(active: true, kind: .ollama, toolActivity: true)
                ),
                (
                    "ollama-tools-narrowest",
                    DashboardSizingPolicy.minimumContentSize(forWidth: 320),
                    makeStore(active: true, kind: .ollama, toolActivity: true)
                ),
                ("irregular", DashboardView.preferredWindowSize, makeIrregularStore()),
                (
                    "irregular-minimum", DashboardSizingPolicy.minimumContentSize(forWidth: 740),
                    makeIrregularStore()
                ),
                ("irregular-tall", NSSize(width: 740, height: 1100), makeIrregularStore()),
            ] {
                let dashboard = NSHostingView(
                    rootView: DashboardView().environment(previewStore).environment(
                        \.colorScheme, scheme
                    )
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor)))
                dashboard.appearance = appearance
                dashboard.setFrameSize(size)
                dashboard.layoutSubtreeIfNeeded()
                XCTAssertEqual(dashboard.fittingSize, size)
                try renderIfRequested(
                    dashboard, named: "dashboard-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }

        NSApp.appearance = NSAppearance(named: .aqua)
        let suite = "com.cmorgan.FluxLLM.layout-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        store.setDetections([
            DetectedBackend(kind: .vllm, baseURL: URL(string: "http://localhost:8000")!)
        ])
        for selection in [BackendSelection.ollama, .vllm, .automatic] {
            settings.backendSelection = selection
            let window = MenuBarController.makeSettingsWindow(
                settings: settings, store: store, onApply: {})
            window.appearance = NSAppearance(named: .aqua)
            window.updateConstraintsIfNeeded()
            window.layoutIfNeeded()
            let view = try XCTUnwrap(window.contentView)
            view.appearance = NSAppearance(named: .aqua)
            XCTAssertEqual(view.bounds.size, NSSize(width: 560, height: 680))
            window.close()

            // Offscreen material lacks a wallpaper. Composite onto the actual
            // appearance's neutral native background for review.
            let preview = NSHostingView(
                rootView: SettingsView(settings: settings, store: store)
                    .environment(\.colorScheme, .light).frame(width: 560, height: 680)
                    .background(Color(nsColor: .windowBackgroundColor)))
            preview.appearance = NSAppearance(named: .aqua)
            preview.setFrameSize(NSSize(width: 560, height: 680))
            preview.layoutSubtreeIfNeeded()
            try renderIfRequested(preview, named: "settings-\(selection.rawValue)")
        }
    }

    // SwiftUI accessibility contrast and Reduce Transparency are read-only
    // system preferences; NSHostingView normalizes explicit high-contrast
    // appearances in this offscreen harness. Validate these rendering paths
    // manually with the corresponding macOS settings enabled.

    func testLongHistoryAveragesRenderWithoutChangingRawSamples() throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let store = makeLongHistoryJitterStore()
        let rawThroughput = store.tpsHistory
        let rawGPU = store.systemGPUHistory
        let heldSnapshot = store.chartPresentation
        XCTAssertEqual(rawThroughput.count, 7201)
        XCTAssertEqual(rawGPU.count, 7201)
        XCTAssertEqual(heldSnapshot.throughput, rawThroughput)
        XCTAssertEqual(heldSnapshot.systemGPU, rawGPU)
        let firstRawSample = try XCTUnwrap(rawThroughput.first)
        let lastRawSample = try XCTUnwrap(rawThroughput.last)
        XCTAssertEqual(
            lastRawSample.timestamp.timeIntervalSince(firstRawSample.timestamp), 3600)
        let spikeTime = heldSnapshot.timestamp.addingTimeInterval(-86.5)
        XCTAssertEqual(rawThroughput.first { $0.timestamp == spikeTime }?.value, 150)
        XCTAssertEqual(rawGPU.first { $0.timestamp == spikeTime }?.value, 100)
        XCTAssertTrue(rawThroughput.contains { !$0.isAvailable })
        XCTAssertTrue(rawGPU.contains { !$0.isAvailable })
        XCTAssertTrue(rawThroughput.contains { $0.isAvailable && $0.value == 0 })
        XCTAssertTrue(rawGPU.contains { $0.isAvailable && $0.value == 0 })

        let size = DashboardView.preferredWindowSize
        for (name, range, scheme) in [
            ("jitter-5m-light", HistoryRange.fiveMinutes, ColorScheme.light),
            ("jitter-15m-dark", HistoryRange.fifteenMinutes, ColorScheme.dark),
            ("jitter-1h-light", HistoryRange.hour, ColorScheme.light),
            ("jitter-1h-dark", HistoryRange.hour, ColorScheme.dark),
        ] {
            store.historyRange = range
            XCTAssertEqual(store.chartHistoryDuration, range.duration(historyAge: 3600))
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            let dashboard = NSHostingView(
                rootView: DashboardView().environment(store).environment(\.colorScheme, scheme)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor)))
            dashboard.appearance = appearance
            dashboard.setFrameSize(size)
            dashboard.layoutSubtreeIfNeeded()
            XCTAssertEqual(dashboard.fittingSize, size)
            try renderIfRequested(dashboard, named: "dashboard-\(name)")
        }
        // Averaging belongs to display geometry. Selecting ranges or rendering
        // must not replace raw samples or lose the held snapshot's narrow spike.
        XCTAssertEqual(store.tpsHistory, rawThroughput)
        XCTAssertEqual(store.systemGPUHistory, rawGPU)
        XCTAssertEqual(store.chartPresentation, heldSnapshot)
    }

    private func makeIdleOllamaStore() -> MetricsStore {
        let store = MetricsStore()
        let epoch = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyBackendSample(BackendSample(kind: .ollama, timestamp: now), epoch: epoch)
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: now, activityPercent: 0, source: "macOS Device Utilization %",
                scope: .system), epoch: epoch)
        store.sample(at: now)
        return store
    }

    /// Reproduce the confusing but valid state: an open request with high GPU
    /// load and no returned tokens. Request activity supplies the missing context.
    private func makeAwaitingOutputStore() -> MetricsStore {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MetricsStore(clock: { now.addingTimeInterval(-60) })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.proxyState = .listening
        for index in 0...120 {
            let date = now.addingTimeInterval(Double(index - 120) / 2)
            store.applyBackendSample(
                BackendSample(kind: .ollama, timestamp: date, model: "Qwen3-8B"), epoch: epoch)
            if index == 84 {
                store.apply(
                    .began(GenerationRequest(model: "Qwen3-8B", startedAt: date)), epoch: epoch)
            }
            store.applyGPUSample(
                GPUActivitySample(
                    timestamp: date, activityPercent: index < 84 ? 0 : 98,
                    source: "macOS Device Utilization %", scope: .system), epoch: epoch)
            store.sample(at: date)
        }
        XCTAssertEqual(BackendPresentation.statusTitle(store: store), "Active")
        XCTAssertEqual(BackendPresentation.activityDetail(store: store), "Awaiting output · 18s")
        XCTAssertEqual(BackendPresentation.rateLabel(store: store), "0.0")
        XCTAssertEqual(store.systemGPUUtilizationPercent, 98)
        return store
    }

    /// Irregular load exposes stroke clutter that smooth demonstration waves hide.
    /// Includes a half-second spike, a real zero, a missing interval, and recovery.
    private func makeIrregularStore() -> MetricsStore {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MetricsStore(clock: { now.addingTimeInterval(-60) })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        let rates = [18.0, 21, 16, 27, 22, 19, 25, 17, 23, 20, 24, 18]
        let loads = [41.0, 74, 38, 66, 83, 47, 72, 53, 90, 61, 45, 78]
        for index in 0...120 {
            let date = now.addingTimeInterval(Double(index - 120) / 2)
            let isMissing = (68...73).contains(index)
            let isIdle = index < 12 || (96...100).contains(index)
            let rate: Double? =
                isMissing ? nil : (isIdle ? 0 : (index == 43 ? 82 : rates[index % rates.count]))
            let load: Double? =
                isMissing
                ? nil : (isIdle ? 0 : (index == 43 ? 100 : loads[(index / 2) % loads.count]))
            store.applyBackendSample(
                BackendSample(
                    kind: .vllm, timestamp: date, model: "Qwen3-8B",
                    currentTPS: rate, runningRequests: isIdle ? 0 : 1, queuedRequests: 0,
                    outputTokens: index * 10, promptTokens: 320), epoch: epoch)
            store.applyGPUSample(
                GPUActivitySample(
                    timestamp: date, activityPercent: load, source: "macOS Device Utilization %",
                    unavailableReason: isMissing ? "Waiting for a fresh sample." : nil,
                    scope: .system), epoch: epoch)
            store.sample(at: date)
        }
        return store
    }

    /// One shared hour of actual half-second sampling exercises bucket spacing
    /// above five seconds without mistaking valid long-range averages for gaps.
    /// Missing-interval metadata remains intact when display geometry uses zero.
    private func makeLongHistoryJitterStore() -> MetricsStore {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MetricsStore(clock: { now.addingTimeInterval(-3600) })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        for index in 0...7200 {
            let age = Double(7200 - index) / 2
            let date = now.addingTimeInterval(-age)
            let isMissing = (110...126).contains(age) || (1600...1680).contains(age)
            let isIdle = (45...60).contains(age) || (2300...2360).contains(age)
            let isSpike = age == 86.5
            let workload = Double((index / 1200) % 3)
            let alternating = index.isMultiple(of: 2) ? 1.0 : -1.0
            let jitteredRate = 24 + workload * 7 + 6 * sin(age / 80) + alternating * 11
            let jitteredGPU = 48 + workload * 8 + 10 * sin(age / 120) + alternating * 18
            let rate: Double? = isMissing ? nil : (isIdle ? 0 : (isSpike ? 150 : jitteredRate))
            let gpu: Double? = isMissing ? nil : (isIdle ? 0 : (isSpike ? 100 : jitteredGPU))
            store.applyBackendSample(
                BackendSample(
                    kind: .vllm, timestamp: date, model: "Qwen3-8B", currentTPS: rate,
                    runningRequests: isIdle ? 0 : 1, queuedRequests: 0,
                    outputTokens: index * 12, promptTokens: 320), epoch: epoch)
            store.applyGPUSample(
                GPUActivitySample(
                    timestamp: date, activityPercent: gpu, source: "macOS Device Utilization %",
                    unavailableReason: isMissing ? "Waiting for a fresh sample." : nil,
                    scope: .system), epoch: epoch)
            store.sample(at: date)
        }
        return store
    }

    private func makeStore(
        active: Bool, gpuAvailable: Bool = true, kind: BackendKind = .vllm,
        model: String? = "Qwen3-8B", basis: ThroughputBasis = .serverAggregate,
        toolActivity: Bool = false
    ) -> MetricsStore {
        let store = MetricsStore()
        let epoch = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.beginBackendSession(kind: kind, epoch: epoch)
        if toolActivity { store.proxyState = .listening }
        let request = GenerationRequest(model: model, startedAt: now.addingTimeInterval(-60))
        if kind == .ollama { store.apply(.began(request), epoch: epoch) }
        for index in 0..<121 {
            let date = now.addingTimeInterval(Double(index - 120) / 2)
            let rate = active ? 42 + 12 * sin(Double(index) / 7) + (index == 74 ? 35 : 0) : 0
            store.applyBackendSample(
                BackendSample(
                    kind: kind, timestamp: date, model: active ? model : nil,
                    currentTPS: rate, basis: basis, runningRequests: active ? 2 : 0,
                    queuedRequests: 0, outputTokens: active ? 24_810 + index : nil,
                    promptTokens: active ? 6_240 : nil), epoch: epoch)
            if kind == .ollama {
                if toolActivity, [24, 25, 26, 70, 71].contains(index) {
                    store.apply(
                        .toolActivity(
                            requestID: request.id,
                            events: [
                                ToolActivityEvent(
                                    kind: .call,
                                    name: index.isMultiple(of: 2) ? "read_file" : "search",
                                    timestamp: date)
                            ]), epoch: epoch)
                } else if toolActivity, [28, 74].contains(index) {
                    store.apply(
                        .toolActivity(
                            requestID: request.id,
                            events: [
                                ToolActivityEvent(
                                    kind: .resultSubmission, name: "read_file", timestamp: date)
                            ]), epoch: epoch)
                }
                store.apply(
                    .updated(
                        requestID: request.id,
                        snapshot: GenerationSnapshot(
                            model: model, outputTokens: index * 24, promptTokens: 120,
                            isEstimated: active, liveTPS: rate, authoritativeTPS: 42,
                            finished: !active, elapsed: Double(index) / 2, timestamp: date)),
                    epoch: epoch)
            }
            store.applyGPUSample(
                GPUActivitySample(
                    timestamp: date,
                    activityPercent: gpuAvailable
                        ? (active ? 35 + 14 * sin(Double(index) / 9) : 0) : nil,
                    source: "macOS Device Utilization %",
                    unavailableReason: gpuAvailable
                        ? nil : "System GPU counters are unavailable on this Mac.", scope: .system),
                epoch: epoch)
            store.sample(at: date)
        }
        if toolActivity {
            let prepared = DashboardChartPreparation().histories(
                snapshot: store.chartPresentation, duration: 60)
            XCTAssertGreaterThan(prepared.toolActivity?.peak ?? 0, 0)
            XCTAssertEqual(prepared.toolActivity?.resultMarkers.count, 2)
        }
        return store
    }

    private func renderIfRequested(_ view: NSView, named name: String) throws {
        guard ProcessInfo.processInfo.environment["FLUXLLM_RENDER_PREVIEWS"] == "1" else { return }
        // Native controls may commit their hosted layout on the next run-loop
        // turn, even though the SwiftUI root already has its final frame.
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let directory = URL(fileURLWithPath: "/private/tmp/fluxllm-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // SwiftUI's colorScheme alone does not set AppKit's drawing appearance.
        // Resolve dynamic native colors consistently and composite the hosted
        // view onto the same opaque background that its real window supplies.
        var result: Result<Void, Error>!
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            result = Result {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let opaque = try XCTUnwrap(
                    NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
                        pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: opaque))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.scaleBy(
                    x: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                    y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
                context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.cgContext.fill(view.bounds)
                bitmap.draw(in: view.bounds)
                NSGraphicsContext.restoreGraphicsState()
                let png = try XCTUnwrap(opaque.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
        try result.get()
    }
}
