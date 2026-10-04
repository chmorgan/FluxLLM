import AppKit
import Observation
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class DashboardFrozenScalarsTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testCompleteSnapshotPreservesUnknownAndNativeBackendLabels() throws {
        let store = MetricsStore(clock: { self.origin })
        let interval = DateInterval(start: origin.addingTimeInterval(-60), end: origin)
        let unknown = try DashboardFrozenScalars.capture(store: store, interval: interval)
        XCTAssertNil(unknown.backendKind)
        XCTAssertEqual(unknown.providerTitle, "LLM monitor")
        XCTAssertEqual(unknown.modelLabel, "—")
        XCTAssertEqual(unknown.rateLabel, BackendPresentation.rateLabel(store: store))
        XCTAssertEqual(unknown.gpuLabel, GPUActivityPresentation.valueLabel(nil))
        XCTAssertEqual(unknown.gpuHelp, store.gpuAvailabilityMessage)
        XCTAssertEqual(unknown.statusTitle, BackendPresentation.statusTitle(store: store))
        XCTAssertEqual(unknown.statusTone, .blue)
        XCTAssertNil(unknown.configurationPrompt)
        XCTAssertEqual(unknown.observationScope, "Waiting for backend")
        XCTAssertEqual(unknown.fingerprint.count, 64)
        XCTAssertEqual(
            unknown, try DashboardFrozenScalars.capture(store: store, interval: interval))

        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: origin, model: "Native model", currentTPS: 12.5,
                basis: .serverAggregate, runningRequests: 2, queuedRequests: 3,
                outputTokens: 345, promptTokens: 67), epoch: epoch)
        store.sample(at: origin)
        let native = try DashboardFrozenScalars.capture(
            store: store, interval: interval, omittedRequestCount: 4)
        XCTAssertEqual(native.modelLabel, "Native model")
        XCTAssertEqual(native.requestCountLabel, "2 active · 3 queued")
        XCTAssertEqual(native.backendOutputTokensLabel, "345")
        XCTAssertEqual(native.backendPromptTokensLabel, "67")
        XCTAssertEqual(native.statusTone, .throughput)
        XCTAssertEqual(native.cardFooterLabel, "Server metrics · 4 older rails omitted")
        XCTAssertEqual(
            native.throughputHelp,
            "Total token throughput across requests reported by this backend.")
        XCTAssertNotEqual(native.fingerprint, unknown.fingerprint)
        XCTAssertThrowsError(
            try DashboardFrozenScalars.capture(
                store: store, interval: DateInterval(start: origin, duration: 0)))
    }

    func testFrozenReceiptDoesNotObserveOrFreezeAuthoritativeStore() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeFrozenScalars)
        let store = makeOllamaStore()
        let state = DashboardPresentationState()
        let window = makeReceiptWindow(state: state, store: store)
        defer { finish(state, window: window, store: store) }
        let capture = try state.prepareFrozenScalars(store: store, compact: false)
        try state.freezeScalars(capture)
        let changes = FrozenScalarObservationCount()
        withObservationTracking {
            _ = state.frozenScalars?.modelLabel
            _ = state.frozenScalars?.rateLabel
            _ = state.frozenScalars?.usage
            _ = state.frozenScalars?.fingerprint
        } onChange: {
            changes.increment()
        }
        let priorPublication = store.chartPresentation.publicationID
        mutate(store)
        XCTAssertEqual(store.currentModel, "Changed model")
        XCTAssertEqual(store.outputTokens, 999)
        XCTAssertEqual(store.usageSummary(in: allHistory).outputTokens, 999)
        XCTAssertEqual(store.systemGPUUtilizationPercent, 83)
        XCTAssertNotEqual(store.chartPresentation.publicationID, priorPublication)
        XCTAssertEqual(state.frozenScalars, capture)
        XCTAssertEqual(changes.value, 0)
        let fresh = try DashboardFrozenScalars.capture(store: store, interval: capture.interval)
        XCTAssertNotEqual(fresh.fingerprint, capture.fingerprint)
        state.releaseFrozenScalars()
        XCTAssertEqual(changes.value, 1)
    }

    func testHiddenReopenAndEpochInvalidateReceiptsAndLateFrames() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeFrozenScalars)
        let store = makeOllamaStore()
        let state = DashboardPresentationState()
        let window = makeReceiptWindow(state: state, store: store)
        defer { finish(state, window: window, store: store) }
        let epoch = store.monitoringEpoch
        let oldGeneration = state.scalarFrameGeneration
        let oldFrames = state.scalarPerformanceFrames
        try state.freezeScalars(state.prepareFrozenScalars(store: store, compact: false))
        state.setActive(false, store: store)
        XCTAssertNil(state.frozenScalars)
        XCTAssertTrue(state.scalarPerformanceFrames.isEmpty)
        state.recordScalarPerformanceFrames(oldFrames, generation: oldGeneration, epoch: epoch)
        XCTAssertTrue(state.scalarPerformanceFrames.isEmpty)
        XCTAssertEqual(scalarCounter("current_frozen_owners"), 0)
        XCTAssertEqual(scalarOwnerCount(), 0)

        state.setActive(true, store: store)
        state.recordScalarPerformanceFrames(oldFrames, generation: oldGeneration, epoch: epoch)
        XCTAssertTrue(
            state.scalarPerformanceFrames.isEmpty, "A prior lifetime cannot seed a reopened host")
        XCTAssertThrowsError(try state.prepareFrozenScalars(store: store, compact: false))
        state.recordScalarPerformanceFrames(
            oldFrames, generation: state.scalarFrameGeneration, epoch: epoch)
        try state.freezeScalars(state.prepareFrozenScalars(store: store, compact: false))
        let reopenedGeneration = state.scalarFrameGeneration
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        state.synchronize(with: store)
        XCTAssertNil(state.frozenScalars)
        XCTAssertTrue(state.scalarPerformanceFrames.isEmpty)
        state.recordScalarPerformanceFrames(oldFrames, generation: reopenedGeneration, epoch: epoch)
        XCTAssertTrue(state.scalarPerformanceFrames.isEmpty)
        XCTAssertEqual(scalarCounter("current_frozen_owners"), 0)
        XCTAssertEqual(scalarCounter("freezes_captured"), 2)
        XCTAssertEqual(scalarCounter("freezes_released"), 2)
    }

    func testCaptureRequiresExplicitModeCompleteGeometryAndRejectsDuplicates() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .normal)
        let store = makeOllamaStore()
        let state = DashboardPresentationState()
        let window = makeReceiptWindow(state: state, store: store)
        XCTAssertThrowsError(try state.prepareFrozenScalars(store: store, compact: false))
        state.setActive(false, store: store)
        window.close()
        try PerformanceGraphicsDiagnostics.shared.disable()
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeFrozenScalars)
        state.setActive(true, store: store)
        state.bindScalarPerformanceWindow(window, role: "dashboard")
        defer { finish(state, window: window, store: store) }
        state.recordScalarPerformanceFrames(
            ["activity-chart": CGRect(x: 0, y: 0, width: 10, height: 10)],
            generation: state.scalarFrameGeneration, epoch: store.monitoringEpoch)
        XCTAssertThrowsError(try state.prepareFrozenScalars(store: store, compact: false))
        state.recordScalarPerformanceFrames(
            receiptFrames, generation: state.scalarFrameGeneration,
            epoch: store.monitoringEpoch)
        let capture = try state.prepareFrozenScalars(store: store, compact: false)
        try state.freezeScalars(capture)
        XCTAssertThrowsError(try state.freezeScalars(capture))
        XCTAssertEqual(state.frozenScalars, capture)
        XCTAssertEqual(scalarCounter("freezes_captured"), 1)
    }

    func testActualNativeScalarPixelsAndChartGeometryRemainHeldWhileChartDataChanges() throws {
        for compact in [false, true] {
            try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeFrozenScalars)
            let store = makeOllamaStore()
            let state = DashboardPresentationState()
            var host: FrozenScalarNativeHost? = FrozenScalarNativeHost(
                store: store, state: state, compact: compact)
            do {
                try host!.settle()
                let initialFrames = state.scalarPerformanceFrames
                let scalarKeys =
                    compact
                    ? ["dashboard-header", "throughput-value", "gpu-value", "statistics-row"]
                    : [
                        "dashboard-header", "throughput-value", "gpu-value", "statistics-row",
                        "dashboard-footer",
                    ]
                let before = try scalarKeys.map {
                    try host!.pixels(in: XCTUnwrap(initialFrames[$0]))
                }
                let chartBefore = store.chartPresentation.publicationID
                try state.freezeScalars(state.prepareFrozenScalars(store: store, compact: compact))
                try host!.settle()
                let afterFreeze = try scalarKeys.map {
                    try host!.pixels(in: XCTUnwrap(state.scalarPerformanceFrames[$0]))
                }
                XCTAssertEqual(
                    before, afterFreeze,
                    "Explicit holding must preserve the actual native scalar pixels")
                mutate(store)
                try host!.settle()
                let afterMutation = try scalarKeys.map {
                    try host!.pixels(in: XCTUnwrap(state.scalarPerformanceFrames[$0]))
                }
                XCTAssertEqual(
                    before, afterMutation, "Frozen scalar leaves leaked changing telemetry")
                XCTAssertNotEqual(store.chartPresentation.publicationID, chartBefore)
                for key in compact
                    ? ["activity-chart", "main-activity-plot"]
                    : ["activity-chart", "main-activity-plot", "request-rail-band"]
                {
                    XCTAssertEqual(
                        state.scalarPerformanceFrames[key], initialFrames[key],
                        "\(key) changed geometry")
                }
                XCTAssertEqual(store.outputTokens, 999)
                XCTAssertEqual(state.frozenScalars?.modelLabel, "Initial model")
            } catch {
                host?.close()
                host = nil
                try? PerformanceGraphicsDiagnostics.shared.disable()
                throw error
            }
            host?.close()
            host = nil
            drain()
            try PerformanceGraphicsDiagnostics.shared.disable()
        }
    }

    func testPublicFreezeCommandRejectsNormalAndHiddenPresentations() throws {
        _ = NSApplication.shared
        let store = makeOllamaStore()
        let suite = "FluxLLM.frozen-scalars-command.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let controller = MenuBarController(
            metricsStore: store,
            coordinator: MonitoringCoordinator(settings: settings, store: store), settings: settings
        )
        defer {
            controller.stop()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .normal)
        XCTAssertThrowsError(try controller.performanceFreezeScalarPresentation())
        try PerformanceGraphicsDiagnostics.shared.disable()
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeFrozenScalars)
        controller.start()
        XCTAssertThrowsError(try controller.performanceFreezeScalarPresentation()) { error in
            guard case DashboardScalarFreezeError.invalid(let message) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("Both native presentations"))
        }
        store.apply(.began(GenerationRequest(startedAt: origin)), epoch: store.monitoringEpoch)
        XCTAssertThrowsError(try controller.performanceFreezeScalarPresentation()) { error in
            guard case DashboardScalarFreezeError.invalid(let message) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("idle"))
        }
        XCTAssertEqual(scalarCounter("freezes_captured"), 0)
    }

    func testTwoOwnerInstallationAndSecondOwnerRejectionRollback() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeFrozenScalars)
        let store = makeOllamaStore()
        let dashboard = DashboardPresentationState()
        let popover = DashboardPresentationState()
        let dashboardWindow = makeReceiptWindow(state: dashboard, store: store)
        let popoverWindow = makeReceiptWindow(state: popover, store: store, compact: true)
        defer {
            dashboard.setActive(false, store: store)
            popover.setActive(false, store: store)
            dashboardWindow.close()
            popoverWindow.close()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        let full = try dashboard.prepareFrozenScalars(store: store, compact: false)
        let compact = try popover.prepareFrozenScalars(store: store, compact: true)
        try MenuBarController.installFrozenScalarPresentations(
            dashboard: (dashboard, full), popover: (popover, compact))
        XCTAssertEqual(scalarCounter("current_frozen_owners"), 2)
        XCTAssertEqual(dashboard.frozenScalars, full)
        XCTAssertEqual(popover.frozenScalars, compact)
        dashboard.setActive(false, store: store)
        popover.setActive(false, store: store)
        dashboard.setActive(true, store: store)
        popover.setActive(true, store: store)
        for state in [dashboard, popover] {
            state.recordScalarPerformanceFrames(
                receiptFrames, generation: state.scalarFrameGeneration,
                epoch: store.monitoringEpoch)
        }
        let retryFull = try dashboard.prepareFrozenScalars(store: store, compact: false)
        let retryCompact = try popover.prepareFrozenScalars(store: store, compact: true)
        // The second receipt becomes unavailable after both were prepared.
        popover.setActive(false, store: store)
        XCTAssertThrowsError(
            try MenuBarController.installFrozenScalarPresentations(
                dashboard: (dashboard, retryFull), popover: (popover, retryCompact)))
        XCTAssertNil(dashboard.frozenScalars)
        XCTAssertNil(popover.frozenScalars)
        XCTAssertEqual(scalarCounter("current_frozen_owners"), 0)
        XCTAssertEqual(scalarOwnerCount(), 0)
        XCTAssertEqual(scalarCounter("freezes_captured"), 3)
        XCTAssertEqual(scalarCounter("freezes_released"), 3)
    }

    func testMalformedCurrentGeometryCannotReuseEarlierPositiveReceipt() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeFrozenScalars)
        let store = makeOllamaStore()
        let state = DashboardPresentationState()
        let window = makeReceiptWindow(state: state, store: store)
        defer { finish(state, window: window, store: store) }
        for rectangle in [
            CGRect(x: 0, y: 0, width: -1, height: 10),
            CGRect(x: 0, y: 0, width: 1, height: 0),
            CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 10),
            CGRect(
                x: CGFloat.greatestFiniteMagnitude, y: 0,
                width: CGFloat.greatestFiniteMagnitude, height: 10),
        ] {
            state.recordScalarPerformanceFrames(
                receiptFrames, generation: state.scalarFrameGeneration,
                epoch: store.monitoringEpoch)
            var invalid = receiptFrames
            invalid["main-activity-plot"] = rectangle
            state.recordScalarPerformanceFrames(
                invalid, generation: state.scalarFrameGeneration,
                epoch: store.monitoringEpoch)
            XCTAssertTrue(state.scalarPerformanceFrames.isEmpty)
            XCTAssertThrowsError(try state.prepareFrozenScalars(store: store, compact: false))
        }
        XCTAssertGreaterThan(
            (PerformanceGraphicsDiagnostics.shared.snapshot()["invalid_events"] as? NSNumber)?
                .uint64Value ?? 0, 0)
    }

    private var receiptFrames: [String: CGRect] {
        [
            "activity-chart": CGRect(x: 18, y: 120, width: 700, height: 280),
            "main-activity-plot": CGRect(x: 40, y: 130, width: 650, height: 180),
            "request-rail-band": CGRect(x: 40, y: 330, width: 650, height: 50),
        ]
    }
    private var allHistory: DateInterval {
        DateInterval(start: origin.addingTimeInterval(-60), end: origin.addingTimeInterval(60))
    }
    private func makeOllamaStore() -> MetricsStore {
        let store = MetricsStore(clock: { self.origin })
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        store.applyBackendSample(
            BackendSample(kind: .ollama, timestamp: origin, model: "Initial model"),
            epoch: store.monitoringEpoch)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        store.setChartPresentationDemand(true, consumer: .popover)
        store.sample(at: origin)
        return store
    }
    private func mutate(_ store: MetricsStore) {
        let request = GenerationRequest(
            model: "Changed model", startedAt: origin.addingTimeInterval(0.1))
        store.apply(.began(request), epoch: store.monitoringEpoch)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    model: "Changed model", outputTokens: 999, liveTPS: 432.1, elapsed: 1.4,
                    timestamp: origin.addingTimeInterval(1.5))), epoch: store.monitoringEpoch)
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: origin.addingTimeInterval(1.5),
                activityPercent: 83, source: "test GPU", scope: .system),
            epoch: store.monitoringEpoch)
        store.sample(at: origin.addingTimeInterval(2))
    }
    private func makeReceiptWindow(
        state: DashboardPresentationState, store: MetricsStore, compact: Bool = false
    ) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: -2000, y: -2000, width: 740, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        state.setActive(true, store: store)
        state.bindScalarPerformanceWindow(window, role: compact ? "popover" : "dashboard")
        state.recordScalarPerformanceFrames(
            receiptFrames, generation: state.scalarFrameGeneration,
            epoch: store.monitoringEpoch)
        return window
    }
    private func finish(_ state: DashboardPresentationState, window: NSWindow, store: MetricsStore)
    {
        state.setActive(false, store: store)
        window.close()
        try? PerformanceGraphicsDiagnostics.shared.disable()
    }
    private func scalarCounter(_ key: String) -> UInt64 {
        let counters =
            PerformanceGraphicsDiagnostics.shared.snapshot()["scalar_presentation"]
            as? [String: Any]
        let value = counters?[key] as? NSNumber
        XCTAssertNotNil(value, "Missing diagnostic key \(key)")
        return value?.uint64Value ?? .max
    }
    private func scalarOwnerCount() -> Int {
        let counters =
            PerformanceGraphicsDiagnostics.shared.snapshot()["scalar_presentation"]
            as? [String: Any]
        let owners = counters?["presentation_owners"] as? [String: Any]
        XCTAssertNotNil(owners)
        return owners?.count ?? .max
    }
    private func drain() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}

private final class FrozenScalarObservationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Retained AppKit host. Cache actual displayed scalar pixels, excluding the
/// live chart and effects; this is rendering fidelity, not a GPU benchmark.
@MainActor
private final class FrozenScalarNativeHost {
    private var hosting: NSHostingController<AnyView>?
    private let window: NSWindow
    private let state: DashboardPresentationState
    private let store: MetricsStore
    private let size: CGSize

    init(store: MetricsStore, state: DashboardPresentationState, compact: Bool) {
        _ = NSApplication.shared
        self.store = store
        self.state = state
        size = compact ? CGSize(width: 360, height: 550) : CGSize(width: 740, height: 700)
        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -2000, y: -2000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        state.setActive(true, store: store)
        state.bindScalarPerformanceWindow(window, role: compact ? "popover" : "dashboard")
        let host = NSHostingController(
            rootView: AnyView(
                DashboardView(isCompact: compact, presentation: state).environment(store)
                    .environment(\.colorScheme, .light)))
        host.sizingOptions = []
        let container = NSViewController()
        container.view = NSView(frame: CGRect(origin: .zero, size: size))
        container.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])
        window.contentViewController = container
        window.setContentSize(size)
        hosting = host
    }

    func settle() throws {
        let host = try XCTUnwrap(hosting)
        for _ in 0..<5 {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            host.view.needsLayout = true
            host.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(host.view.bounds.size, size)
        XCTAssertNotNil(state.scalarPerformanceFrames["main-activity-plot"])
    }

    func pixels(in frame: CGRect) throws -> Data {
        let view = try XCTUnwrap(hosting?.view)
        let region = frame.integral.intersection(view.bounds)
        XCTAssertFalse(region.isEmpty)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: region))
        view.cacheDisplay(in: region, to: bitmap)
        XCTAssertEqual(bitmap.bitsPerSample, 8)
        let pointer = try XCTUnwrap(bitmap.bitmapData)
        let rowWidth = bitmap.pixelsWide * bitmap.samplesPerPixel
        var pixels = Data()
        for row in 0..<bitmap.pixelsHigh {
            pixels.append(pointer.advanced(by: row * bitmap.bytesPerRow), count: rowWidth)
        }
        XCTAssertGreaterThan(
            Set(pixels).count, 4, "The native scalar image must contain rendered content")
        return pixels
    }

    func close() {
        state.setActive(false, store: store)
        window.contentViewController = nil
        hosting = nil
        window.close()
    }
}
