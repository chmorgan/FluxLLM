import AppKit
import Observation
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class DashboardHeldUsageTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testNativeUsagePixelsInitiallyMatchAndOnlyUsageStaysHeld() throws {
        for size in [CGSize(width: 740, height: 700), CGSize(width: 360, height: 950)] {
            try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeHeldUsage)
            let store = makeStore()
            let full = HeldUsageNativeHost(store: store, compact: false, size: size)
            let compact = HeldUsageNativeHost(
                store: store, compact: true, size: CGSize(width: 360, height: 550))
            defer {
                full.close()
                compact.close()
                drain()
                try? PerformanceGraphicsDiagnostics.shared.disable()
            }
            try full.settle()
            try compact.settle()
            let frames = full.state.scalarPerformanceFrames
            let before = try full.pixels(in: XCTUnwrap(frames["statistics-row"]))
            let held = try full.state.prepareHeldUsage(store: store)
            try full.state.holdUsage(held, store: store)
            try full.settle()
            try compact.settle()
            XCTAssertEqual(
                try full.pixels(
                    in: XCTUnwrap(full.state.scalarPerformanceFrames["statistics-row"])), before)
            XCTAssertNil(compact.state.heldUsage)
            XCTAssertNil(full.state.frozenScalars)
            XCTAssertNil(compact.state.frozenScalars)
            let publication = store.chartPresentation.publicationID
            let requests = stream(store)
            try full.settle()
            try compact.settle()
            XCTAssertEqual(full.state.heldUsage, held)
            XCTAssertEqual(
                try full.pixels(
                    in: XCTUnwrap(full.state.scalarPerformanceFrames["statistics-row"])), before,
                "Actual usage values and their active badge must stay held")
            XCTAssertEqual(store.usageSummary(in: allHistory).outputTokens, 54)
            XCTAssertEqual(store.liveScalars.usage.activeRequests, 2)
            XCTAssertNotEqual(store.chartPresentation.publicationID, publication)
            let fullValues = try presented(full.state)
            let compactValues = try presented(compact.state)
            XCTAssertEqual(
                (fullValues["dashboard_usage"]?["values"] as? NSDictionary),
                held.values as NSDictionary)
            XCTAssertEqual(fullValues["header"]?["model"] as? String, "Live second")
            XCTAssertEqual(fullValues["header"]?["status"] as? String, "Active")
            XCTAssertEqual(fullValues["header"]?["activity"] as? String, "2 requests in flight")
            XCTAssertEqual(fullValues["metrics"]?["rate"] as? String, "400.0")
            XCTAssertEqual(fullValues["metrics"]?["gpu"] as? String, "83")
            XCTAssertEqual(compactValues["compact_details"]?["response"] as? String, "~20")
            for key in [
                "activity-chart", "main-activity-plot", "request-rail-band", "statistics-row",
            ] {
                XCTAssertEqual(
                    full.state.scalarPerformanceFrames[key], frames[key], "\(key) shifted")
            }
            finish(store, request: requests.1.id, tokens: 30, prompt: 4, at: 1.7)
            finish(store, request: requests.0.id, tokens: 15, prompt: 2, at: 1.8)
            store.sample(at: date(2))
            try full.settle()
            try compact.settle()
            XCTAssertEqual(store.usageSummary(in: allHistory).outputTokens, 69)
            XCTAssertEqual(
                try presented(compact.state)["compact_details"]?["response"] as? String, "30")
            XCTAssertEqual(try presented(full.state)["header"]?["status"] as? String, "Idle")
            XCTAssertEqual(
                try full.pixels(
                    in: XCTUnwrap(full.state.scalarPerformanceFrames["statistics-row"])), before)
            let owners = try XCTUnwrap(heldNamespace()["owners"] as? [String: Any])
            XCTAssertEqual(Set(owners.keys), [full.state.scalarPerformanceOwnerID.uuidString])
        }
    }

    func testNormalAndHeldModeInitiallyRenderIdenticalScalarPixelsAndGeometry() throws {
        let normal = try captureInitial(mode: .normal)
        let candidate = try captureInitial(mode: .runtimeHeldUsage)
        XCTAssertEqual(candidate.frames, normal.frames)
        XCTAssertEqual(candidate.pixels, normal.pixels)
    }

    func testNativeUsageAccessibilityParityWhenSwiftUIExposesItsTree() throws {
        let label = "FluxLLM accessibility sentinel"
        let sentinel = HeldUsageNativeHost(
            store: makeStore(), compact: false,
            size: CGSize(width: 300, height: 100),
            rootView: AnyView(Text(label).accessibilityLabel(label)))
        defer { sentinel.close() }
        try sentinel.settle(requireUsageFrame: false)
        _ = try sentinel.pixels(in: CGRect(x: 0, y: 0, width: 300, height: 100))
        let exposed = sentinel.accessibilityText()
        let debug = sentinel.accessibilityDebug
        sentinel.close()
        drain()
        guard !exposed.isEmpty else {
            throw XCTSkip(
                "Independent SwiftUI Text sentinel exposes no native AX tree in this XCTest host; AX parity is unavailable. \(debug)"
            )
        }
        XCTAssertTrue(exposed.contains(where: { $0.contains(label) }), debug)
        let normal = try captureAccessibility(mode: .normal)
        let held = try captureAccessibility(mode: .runtimeHeldUsage)
        XCTAssertEqual(held, normal)
    }

    func testPreparedReceiptCannotSurviveStoreEpochScopeOrLifetimeChanges() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeHeldUsage)
        let store = makeStore()
        let dashboard = DashboardPresentationState()
        let popover = DashboardPresentationState()
        let fullWindow = receiptWindow(state: dashboard, store: store, compact: false)
        let compactWindow = receiptWindow(state: popover, store: store, compact: true)
        defer {
            dashboard.setActive(false, store: store)
            popover.setActive(false, store: store)
            fullWindow.close()
            compactWindow.close()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        let old = try dashboard.prepareHeldUsage(store: store)
        let epoch = store.monitoringEpoch
        let generation = dashboard.scalarFrameGeneration
        let frames = dashboard.scalarPerformanceFrames
        dashboard.setActive(false, store: store)
        dashboard.setActive(true, store: store)
        dashboard.recordScalarPerformanceFrames(frames, generation: generation, epoch: epoch)
        XCTAssertTrue(dashboard.scalarPerformanceFrames.isEmpty)
        dashboard.recordScalarPerformanceFrames(
            frames, generation: dashboard.scalarFrameGeneration, epoch: epoch)
        XCTAssertThrowsError(
            try dashboard.holdUsage(old, store: store),
            "An identical old receipt must not reattach to a reopened lifetime")
        let reopened = try dashboard.prepareHeldUsage(store: store)
        store.usageScope = .today
        XCTAssertThrowsError(try dashboard.holdUsage(reopened, store: store))
        store.usageScope = .sinceLaunch
        let beforeEpoch = try dashboard.prepareHeldUsage(store: store)
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        XCTAssertThrowsError(
            try dashboard.holdUsage(beforeEpoch, store: store),
            "Actual store epoch must reject a receipt before any SwiftUI synchronize callback")
        XCTAssertNil(dashboard.heldUsage)
        dashboard.synchronize(with: store)
        dashboard.recordScalarPerformanceFrames(frames, generation: generation, epoch: epoch)
        XCTAssertTrue(dashboard.scalarPerformanceFrames.isEmpty)
        XCTAssertEqual(heldCounter("current_owners"), 0)
    }

    func testHoldAdmissionRejectsGeometryInvalidationAndTrafficAfterPreparation() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeHeldUsage)
        let store = makeStore()
        let dashboard = DashboardPresentationState()
        let popover = DashboardPresentationState()
        let fullWindow = receiptWindow(state: dashboard, store: store, compact: false)
        let compactWindow = receiptWindow(state: popover, store: store, compact: true)
        defer {
            dashboard.setActive(false, store: store)
            popover.setActive(false, store: store)
            fullWindow.close()
            compactWindow.close()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        let beforeGeometry = try dashboard.prepareHeldUsage(store: store)
        var bad = dashboard.scalarPerformanceFrames
        bad["main-activity-plot"] = CGRect(x: 0, y: 0, width: -1, height: 1)
        dashboard.recordScalarPerformanceFrames(
            bad, generation: dashboard.scalarFrameGeneration, epoch: store.monitoringEpoch)
        XCTAssertTrue(dashboard.scalarPerformanceFrames.isEmpty)
        XCTAssertThrowsError(try dashboard.holdUsage(beforeGeometry, store: store))
        dashboard.recordScalarPerformanceFrames(
            receiptFrames, generation: dashboard.scalarFrameGeneration, epoch: store.monitoringEpoch
        )
        let beforeTraffic = try dashboard.prepareHeldUsage(store: store)
        store.apply(.began(GenerationRequest(startedAt: date(0.1))))
        XCTAssertThrowsError(try dashboard.holdUsage(beforeTraffic, store: store))
        XCTAssertNil(dashboard.heldUsage)
        XCTAssertEqual(heldCounter("captures"), 0)
    }

    func testClosingAndEpochReleaseHeldUsageButLeaveAuthoritativePickerScopeLive() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeHeldUsage)
        let store = makeStore()
        let dashboard = DashboardPresentationState()
        let popover = DashboardPresentationState()
        let fullWindow = receiptWindow(state: dashboard, store: store, compact: false)
        let compactWindow = receiptWindow(state: popover, store: store, compact: true)
        defer {
            dashboard.setActive(false, store: store)
            popover.setActive(false, store: store)
            fullWindow.close()
            compactWindow.close()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        let initial = try dashboard.prepareHeldUsage(store: store)
        try dashboard.holdUsage(initial, store: store)
        store.usageScope = .today
        XCTAssertEqual(store.usageScope, .today)
        XCTAssertTrue(store.liveScalars.usageScopeHelp.hasPrefix("Requests completed today"))
        XCTAssertEqual(
            dashboard.heldUsage?.scope, .sinceLaunch,
            "Only the diagnostic summary keeps its captured accounting scope")
        dashboard.setActive(false, store: store)
        XCTAssertNil(dashboard.heldUsage)
        XCTAssertEqual(heldCounter("releases"), 1)
        dashboard.setActive(true, store: store)
        dashboard.recordScalarPerformanceFrames(
            receiptFrames, generation: dashboard.scalarFrameGeneration, epoch: store.monitoringEpoch
        )
        try dashboard.holdUsage(dashboard.prepareHeldUsage(store: store), store: store)
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        dashboard.synchronize(with: store)
        XCTAssertNil(dashboard.heldUsage)
        XCTAssertEqual(heldCounter("captures"), 2)
        XCTAssertEqual(heldCounter("releases"), 2)
        XCTAssertEqual(heldCounter("current_owners"), 0)
    }

    func testPublicCommandRejectsNormalHiddenAndActivePresentations() throws {
        _ = NSApplication.shared
        let store = makeStore()
        let suite = "FluxLLM.held-usage-command.\(UUID().uuidString)"
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
        XCTAssertThrowsError(try controller.performanceFreezeUsagePresentation())
        try PerformanceGraphicsDiagnostics.shared.disable()
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeHeldUsage)
        controller.start()
        XCTAssertThrowsError(try controller.performanceFreezeUsagePresentation()) { error in
            guard case DashboardScalarFreezeError.invalid(let message) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(message.contains("Both native presentations"))
        }
        store.apply(.began(GenerationRequest(startedAt: origin)))
        XCTAssertThrowsError(try controller.performanceFreezeUsagePresentation()) { error in
            guard case DashboardScalarFreezeError.invalid(let message) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(message.contains("idle"))
        }
        XCTAssertEqual(heldCounter("captures"), 0)
    }

    private struct InitialCapture {
        let frames: [String: CGRect]
        let pixels: Data
    }
    private func captureInitial(mode: PerformanceGraphicsDiagnostics.Mode) throws -> InitialCapture
    {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: mode)
        let store = makeStore()
        let full = HeldUsageNativeHost(
            store: store, compact: false, size: CGSize(width: 740, height: 700))
        let compact = HeldUsageNativeHost(
            store: store, compact: true, size: CGSize(width: 360, height: 550))
        defer {
            full.close()
            compact.close()
            drain()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        try full.settle()
        try compact.settle()
        if mode.usesHeldUsagePresentation {
            try full.state.holdUsage(full.state.prepareHeldUsage(store: store), store: store)
            try full.settle()
        }
        return try InitialCapture(
            frames: full.state.scalarPerformanceFrames,
            pixels: full.pixels(in: XCTUnwrap(full.state.scalarPerformanceFrames["statistics-row"]))
        )
    }
    private func captureAccessibility(mode: PerformanceGraphicsDiagnostics.Mode) throws -> [String]
    {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: mode)
        let store = makeStore()
        let full = HeldUsageNativeHost(
            store: store, compact: false, size: CGSize(width: 740, height: 700))
        let compact = HeldUsageNativeHost(
            store: store, compact: true, size: CGSize(width: 360, height: 550))
        defer {
            full.close()
            compact.close()
            drain()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        try full.settle()
        try compact.settle()
        let before = full.accessibilityText()
        XCTAssertTrue(
            before.contains(where: { $0.contains("Input tokens") }), full.accessibilityDebug)
        XCTAssertTrue(
            before.contains(where: { $0.contains("Output tokens") }), full.accessibilityDebug)
        if mode.usesHeldUsagePresentation {
            try full.state.holdUsage(full.state.prepareHeldUsage(store: store), store: store)
            try full.settle()
            let after = full.accessibilityText()
            XCTAssertEqual(
                after, before, "Holding identical values must preserve the native AX tree")
            return after
        }
        return before
    }
    private var receiptFrames: [String: CGRect] {
        [
            "activity-chart": CGRect(x: 18, y: 120, width: 700, height: 280),
            "main-activity-plot": CGRect(x: 40, y: 130, width: 650, height: 180),
            "request-rail-band": CGRect(x: 40, y: 330, width: 650, height: 50),
            "statistics-row": CGRect(x: 20, y: 500, width: 700, height: 80),
        ]
    }
    private func receiptWindow(
        state: DashboardPresentationState, store: MetricsStore, compact: Bool
    ) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: -2000, y: -2000, width: 740, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        state.setActive(true, store: store)
        state.bindScalarPerformanceWindow(window, role: compact ? "popover" : "dashboard")
        state.recordScalarPerformanceFrames(
            receiptFrames, generation: state.scalarFrameGeneration, epoch: store.monitoringEpoch)
        return window
    }
    private func makeStore() -> MetricsStore {
        let store = MetricsStore(clock: { self.origin })
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        store.setChartPresentationDemand(true, consumer: .dashboard)
        store.setChartPresentationDemand(true, consumer: .popover)
        store.applyBackendSample(
            BackendSample(kind: .ollama, timestamp: origin, model: "Initial model"),
            epoch: store.monitoringEpoch)
        let old = GenerationRequest(model: "Initial model", startedAt: date(-1))
        store.apply(.began(old))
        finish(store, request: old.id, tokens: 24, prompt: 6, at: 0)
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: origin, activityPercent: 37.6,
                source: "usage-test GPU", scope: .system), epoch: store.monitoringEpoch)
        store.sample(at: origin)
        return store
    }
    private func stream(_ store: MetricsStore) -> (GenerationRequest, GenerationRequest) {
        let first = GenerationRequest(model: "Live first", startedAt: date(0.1))
        let second = GenerationRequest(model: "Live second", startedAt: date(0.2))
        store.apply(.began(first))
        store.apply(.began(second))
        for (request, count) in [(first, 10), (second, 20)] {
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: count, liveTPS: 200, elapsed: 1.2, timestamp: date(1.4))))
        }
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: date(1.4), activityPercent: 83,
                source: "usage-test GPU", scope: .system), epoch: store.monitoringEpoch)
        store.sample(at: date(1.5))
        return (first, second)
    }
    private func finish(
        _ store: MetricsStore, request: UUID, tokens: Int, prompt: Int, at offset: Double
    ) {
        store.apply(
            .updated(
                requestID: request,
                snapshot: GenerationSnapshot(
                    outputTokens: tokens,
                    promptTokens: prompt, isEstimated: false, finished: true,
                    timestamp: date(offset))))
    }
    private var allHistory: DateInterval { DateInterval(start: date(-60), end: date(60)) }
    private func date(_ offset: Double) -> Date { origin.addingTimeInterval(offset) }
    private func heldNamespace() -> [String: Any] {
        PerformanceGraphicsDiagnostics.shared.snapshot()["held_usage"] as? [String: Any] ?? [:]
    }
    private func heldCounter(_ key: String) -> UInt64 {
        (heldNamespace()[key] as? NSNumber)?.uint64Value ?? .max
    }
    private func presented(_ state: DashboardPresentationState) throws -> [String: [String: Any]] {
        let scalar = try XCTUnwrap(
            PerformanceGraphicsDiagnostics.shared.snapshot()["scalar_presentation"]
                as? [String: Any])
        let owners = try XCTUnwrap(scalar["presentation_owners"] as? [String: [String: Any]])
        return try XCTUnwrap(
            owners[state.scalarPerformanceOwnerID.uuidString]?["presented_values"]
                as? [String: [String: Any]])
    }
    private func drain() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}

@MainActor
private final class HeldUsageNativeHost {
    private static var finishedApplicationLaunch = false
    let state = DashboardPresentationState()
    private let store: MetricsStore
    private let size: CGSize
    private let window: NSWindow
    private var hosting: NSHostingController<AnyView>?
    private(set) var accessibilityDebug = "Accessibility tree has not been read"

    init(store: MetricsStore, compact: Bool, size: CGSize, rootView: AnyView? = nil) {
        _ = NSApplication.shared
        self.store = store
        self.size = size
        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -2000, y: -2000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        state.setActive(true, store: store)
        state.bindScalarPerformanceWindow(window, role: compact ? "popover" : "dashboard")
        let host = NSHostingController(
            rootView: rootView
                ?? AnyView(
                    DashboardView(isCompact: compact, presentation: state)
                        .environment(store).environment(\.colorScheme, .light)))
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
    func settle(requireUsageFrame: Bool = true) throws {
        let host = try XCTUnwrap(hosting)
        for _ in 0..<5 {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            host.view.needsLayout = true
            host.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(host.view.bounds.size, size)
        if requireUsageFrame {
            XCTAssertNotNil(state.scalarPerformanceFrames["statistics-row"])
        } else {
            XCTAssertTrue(state.scalarPerformanceFrames.isEmpty)
        }
    }
    func pixels(in frame: CGRect) throws -> Data {
        let view = try XCTUnwrap(hosting?.view)
        let region = frame.integral.intersection(view.bounds)
        XCTAssertFalse(region.isEmpty)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: region))
        view.cacheDisplay(in: region, to: bitmap)
        XCTAssertEqual(bitmap.bitsPerSample, 8)
        let pointer = try XCTUnwrap(bitmap.bitmapData)
        var result = Data()
        for row in 0..<bitmap.pixelsHigh {
            result.append(
                pointer.advanced(by: row * bitmap.bytesPerRow),
                count: bitmap.pixelsWide * bitmap.samplesPerPixel)
        }
        XCTAssertGreaterThan(Set(result).count, 4)
        return result
    }
    func accessibilityText() -> [String] {
        guard let view = hosting?.view else { return [] }
        // Bitmap rendering works in an offscreen window, but SwiftUI omits its
        // accessibility children while the window is entirely occluded. Show
        // the same host briefly with its usage row onscreen, then restore both
        // the native frame and visibility after querying the actual AX tree.
        let originalFrame = window.frame
        let wasVisible = window.isVisible
        let hadFrameReceipt = !state.scalarPerformanceFrames.isEmpty
        let application = NSApplication.shared
        let originalPolicy = application.activationPolicy()
        XCTAssertTrue(application.setActivationPolicy(.accessory))
        if !Self.finishedApplicationLaunch {
            application.finishLaunching()
            Self.finishedApplicationLaunch = true
        }
        application.activate()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            accessibilityDebug = "No native screen is available for accessibility presentation"
            XCTFail(accessibilityDebug)
            _ = application.setActivationPolicy(originalPolicy)
            return []
        }
        let usageFrame = state.scalarPerformanceFrames["statistics-row"] ?? view.bounds
        let usageInWindow = view.convert(usageFrame, to: nil)
        window.setFrameOrigin(
            CGPoint(
                x: screen.visibleFrame.midX - usageInWindow.midX,
                y: screen.visibleFrame.midY - usageInWindow.midY))
        window.orderFrontRegardless()
        for _ in 0..<10 {
            while let event = application.nextEvent(
                matching: .any, until: Date(), inMode: .default, dequeue: true)
            {
                application.sendEvent(event)
            }
            application.updateWindows()
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        state.refreshScalarPerformanceNativeFrame()
        defer {
            window.setFrame(originalFrame, display: false)
            if !wasVisible { window.orderOut(nil) }
            state.refreshScalarPerformanceNativeFrame()
            XCTAssertEqual(window.frame, originalFrame)
            if hadFrameReceipt {
                XCTAssertEqual(state.scalarPerformanceFrames["native-window"], originalFrame)
            } else {
                XCTAssertTrue(state.scalarPerformanceFrames.isEmpty)
            }
            XCTAssertTrue(application.setActivationPolicy(originalPolicy))
        }
        XCTAssertTrue(
            window.isVisible && window.occlusionState.contains(.visible),
            "Native accessibility fixture must be onscreen and unoccluded; frame=\(window.frame), occlusion=\(window.occlusionState.rawValue)"
        )
        var result: [String] = []
        var nodes: [String] = []
        var seen: Set<ObjectIdentifier> = []
        func visit(_ object: Any, depth: Int) {
            guard depth < 24, seen.count < 512, let node = object as? NSObject else { return }
            let id = ObjectIdentifier(node)
            guard seen.insert(id).inserted else { return }
            // SwiftUI can vend Objective-C accessibility proxies that implement
            // the SDK's getters without adopting its complete formal protocol.
            // Query the actual declared selectors rather than dropping a node
            // solely because an NSAccessibilityProtocol cast fails.
            func read(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                guard node.responds(to: selector) else { return nil }
                return node.perform(selector)?.takeUnretainedValue()
            }
            func text(_ value: Any?) -> String {
                if let value = value as? String { return value }
                if let value = value as? NSAttributedString { return value.string }
                if let value = value as? NSNumber { return value.stringValue }
                return ""
            }
            let label = text(read("accessibilityLabel"))
            let value = text(read("accessibilityValue"))
            let identifier = text(read("accessibilityIdentifier"))
            let children = read("accessibilityChildren") as? [Any] ?? []
            let navigationChildren = read("accessibilityChildrenInNavigationOrder") as? [Any] ?? []
            if nodes.count < 64 {
                nodes.append(
                    "depth=\(depth) type=\(NSStringFromClass(type(of: node))) protocol=\(node is NSAccessibilityProtocol) children=\(children.count) navigationChildren=\(navigationChildren.count) id=\(identifier.prefix(120)) label=\(label.prefix(120)) value=\(value.prefix(120))"
                )
            }
            if !label.isEmpty || !value.isEmpty || !identifier.isEmpty {
                result.append("\(identifier)|\(label)|\(value)")
            }
            for child in children { visit(child, depth: depth + 1) }
            for child in navigationChildren { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        if let container = window.contentView { visit(container, depth: 0) }
        visit(view, depth: 0)
        if let exposedHost = NSAccessibility.unignoredDescendant(of: view) {
            visit(exposedHost, depth: 0)
        }
        // Public hit testing may materialize lazy SwiftUI accessibility nodes.
        for fraction in [0.125, 0.375, 0.625, 0.875] {
            let point = CGPoint(
                x: usageFrame.minX + usageFrame.width * fraction, y: usageFrame.midY)
            let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
            if let hit = view.accessibilityHitTest(screenPoint) { visit(hit, depth: 0) }
        }
        accessibilityDebug =
            "applicationActive=\(NSApplication.shared.isActive), activationPolicy=\(NSApplication.shared.activationPolicy().rawValue), windowVisible=\(window.isVisible), occlusion=\(window.occlusionState.rawValue), frame=\(window.frame), bounds=\(view.bounds), usage=\(usageInWindow), visited=\(seen.count)\n"
            + nodes.joined(separator: "\n")
        return result.sorted()
    }
    func close() {
        state.setActive(false, store: store)
        window.contentViewController = nil
        hosting = nil
        window.close()
    }
}
