import AppKit
import Observation
import SwiftUI
import XCTest

@testable import FluxLLM

/// Native presentation checks. These render the original scalar value receipt
/// and the live projection through AppKit; no performance claim comes from them.
@MainActor
final class DashboardLiveScalarViewTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testNativePixelsAndGeometryMatchLegacyScalarReceiptAcrossDashboardSizes() throws {
        let cases: [(Bool, CGSize, BackendKind)] = [
            (true, CGSize(width: 360, height: 550), .ollama),
            (false, CGSize(width: 740, height: 700), .ollama),
            (false, CGSize(width: 360, height: 950), .ollama),
            (false, DashboardSizingPolicy.minimumContentSize(forWidth: 740), .ollama),
            (false, CGSize(width: 1100, height: 900), .vllm),
        ]
        for (compact, size, backend) in cases {
            let reference = try captureDashboard(
                compact: compact, size: size, backend: backend,
                mode: .runtimeFrozenScalars, freeze: true)
            let projected = try captureDashboard(
                compact: compact, size: size, backend: backend,
                mode: .normal, freeze: false)
            XCTAssertEqual(projected.frames, reference.frames, "Layout changed at \(size)")
            XCTAssertEqual(
                projected.pixels, reference.pixels,
                "Projected labels must match the independently captured legacy values at \(size)")
        }
    }

    func testChartOnlyPublicationDoesNotRebuildStableScalarLeaves() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .normal)
        let store = makeStore(.vllm)
        let state = DashboardPresentationState()
        let host = LiveScalarDashboardHost(
            store: store, state: state, compact: false,
            size: CGSize(width: 740, height: 700))
        defer {
            host.close()
            drain()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        try host.settle()
        // Warm the first chart reconciliation before measuring runtime work.
        // The unchanged prior native bundle also rebuilds these leaves on its
        // first publication in a cold process; startup is measured separately.
        store.sample(at: origin.addingTimeInterval(1))
        try host.settle()
        let before = try leafCounts(state)
        let frames = state.scalarPerformanceFrames
        let values = try presentedValues(state)
        try host.settle()
        XCTAssertEqual(try leafCounts(state), before, "The no-update control must remain quiet")
        for second in 2...4 {
            let publication = store.chartPresentation.publicationID
            store.sample(at: origin.addingTimeInterval(TimeInterval(second)))
            try host.settle()
            XCTAssertNotEqual(store.chartPresentation.publicationID, publication)
            XCTAssertEqual(
                try leafCounts(state), before,
                "A changing chart timestamp must not become a scalar-child input")
            XCTAssertEqual(state.scalarPerformanceFrames, frames)
            XCTAssertEqual(
                try presentedValues(state), values,
                "Actual rendered scalar witnesses must remain unchanged")
        }
    }

    func testGPUReadingsAndUsageChangesDoNotFanOutToUnrelatedNativeLeaves() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .normal)
        let store = makeStore(.ollama)
        let fullState = DashboardPresentationState()
        let compactState = DashboardPresentationState()
        let full = LiveScalarDashboardHost(
            store: store, state: fullState, compact: false,
            size: CGSize(width: 740, height: 700))
        let compact = LiveScalarDashboardHost(
            store: store, state: compactState, compact: true,
            size: CGSize(width: 360, height: 550))
        defer {
            full.close()
            compact.close()
            drain()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        try full.settle()
        try compact.settle()
        let beforeFull = try leafCounts(fullState)
        let beforeCompact = try leafCounts(compactState)
        let publication = store.chartPresentation.publicationID
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: origin.addingTimeInterval(0.7),
                activityPercent: 37.7, source: "scalar-test GPU", scope: .system),
            epoch: store.monitoringEpoch)
        try full.settle()
        try compact.settle()
        XCTAssertEqual(store.liveScalars.gpuLabel, "38")
        XCTAssertEqual(store.chartPresentation.publicationID, publication)
        XCTAssertEqual(
            try leafCounts(fullState), beforeFull,
            "Same displayed GPU percentage must not publish its raw timestamp")
        XCTAssertEqual(try leafCounts(compactState), beforeCompact)

        store.applyGPUSample(
            GPUActivitySample(
                timestamp: origin.addingTimeInterval(0.8),
                source: "scalar-test GPU", unavailableReason: "Changed availability explanation",
                scope: .system),
            epoch: store.monitoringEpoch)
        try full.settle()
        try compact.settle()
        let gpuFull = try leafCounts(fullState)
        let gpuCompact = try leafCounts(compactState)
        for (before, after) in [(beforeFull, gpuFull), (beforeCompact, gpuCompact)] {
            XCTAssertEqual(after["header"], before["header"])
            XCTAssertEqual(after["details"], before["details"])
            XCTAssertGreaterThan(try XCTUnwrap(after["metrics"]), try XCTUnwrap(before["metrics"]))
        }
        store.usageScope = .today
        try full.settle()
        try compact.settle()
        let usageFull = try leafCounts(fullState)
        let usageCompact = try leafCounts(compactState)
        XCTAssertGreaterThan(try XCTUnwrap(usageFull["details"]), try XCTUnwrap(gpuFull["details"]))
        XCTAssertEqual(
            usageCompact["details"], gpuCompact["details"],
            "Compact latest-response tokens must not observe unrelated usage totals or scope")
        XCTAssertEqual(usageCompact["header"], gpuCompact["header"])
        XCTAssertEqual(usageCompact["metrics"], gpuCompact["metrics"])
    }

    func testEqualChildRemainsLiveForEnvironmentStoreReplacementAndObservedValues() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .normal)
        let first = makeStore(.vllm)
        let second = makeStore(.vllm, rate: 32.7)
        let context = ScalarParentContext(store: first, leaf: .metrics)
        let host = LiveScalarLeafHost(context: context)
        defer {
            host.close()
            drain()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        try host.settle()
        let firstPixels = try host.pixels()
        let firstCounts = try leafCounts(context.presentation)
        context.parentTick += 1
        try host.settle()
        XCTAssertEqual(
            try leafCounts(context.presentation), firstCounts,
            "Equal immutable child inputs should skip a forced parent update")
        context.store = second
        try host.settle()
        XCTAssertNotEqual(
            try host.pixels(), firstPixels,
            "An equal child must consume the replacement environment store")
        let replacedCounts = try leafCounts(context.presentation)
        XCTAssertGreaterThan(
            try XCTUnwrap(replacedCounts["metrics"]), try XCTUnwrap(firstCounts["metrics"]))
        let replacementPixels = try host.pixels()
        first.applyGPUSample(
            GPUActivitySample(
                timestamp: origin.addingTimeInterval(0.7),
                activityPercent: 91, source: "scalar-test GPU", scope: .system),
            epoch: first.monitoringEpoch)
        try host.settle()
        let retiredCounts = try leafCounts(context.presentation)
        // A previously registered Observation dependency can consume one final
        // callback after replacement. It must retire, never render old values,
        // and never keep invalidating this leaf on subsequent old-store events.
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(retiredCounts["metrics"]),
            try XCTUnwrap(replacedCounts["metrics"]) + 1)
        XCTAssertEqual(try host.pixels(), replacementPixels)
        for (offset, value) in [(0.72, 61.0), (0.74, 42.0)] {
            first.applyGPUSample(
                GPUActivitySample(
                    timestamp: origin.addingTimeInterval(offset),
                    activityPercent: value, source: "retired scalar-test GPU", scope: .system),
                epoch: first.monitoringEpoch)
            try host.settle()
            XCTAssertEqual(
                try leafCounts(context.presentation), retiredCounts,
                "A retired environment store must stop invalidating the replacement leaf")
            XCTAssertEqual(
                try host.pixels(), replacementPixels,
                "Old-store values must never replace the current environment's labels")
        }
        second.applyGPUSample(
            GPUActivitySample(
                timestamp: origin.addingTimeInterval(0.8),
                activityPercent: 83, source: "scalar-test GPU", scope: .system),
            epoch: second.monitoringEpoch)
        try host.settle()
        let beforeSchemePixels = try host.pixels()
        let beforeSchemeCounts = try leafCounts(context.presentation)
        XCTAssertNotEqual(beforeSchemePixels, replacementPixels)
        XCTAssertGreaterThan(
            try XCTUnwrap(beforeSchemeCounts["metrics"]),
            try XCTUnwrap(retiredCounts["metrics"]),
            "The replacement environment store must still invalidate its leaf")
        context.scheme = .dark
        try host.settle()
        XCTAssertNotEqual(try host.pixels(), beforeSchemePixels)
        XCTAssertGreaterThan(
            try XCTUnwrap(leafCounts(context.presentation)["metrics"]),
            try XCTUnwrap(beforeSchemeCounts["metrics"]))
    }

    func testMutableActionCallbacksRemainObservedInsideEqualHeader() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .normal)
        let store = MetricsStore(clock: { self.origin })
        store.updateConnection(.needsConfiguration, at: origin)
        let context = ScalarParentContext(store: store, leaf: .header)
        let host = LiveScalarLeafHost(context: context)
        defer {
            host.close()
            drain()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        try host.settle()
        let before = try leafCounts(context.presentation)
        var received = 0
        context.actions.onShowSettings = { received = 7 }
        try host.settle()
        XCTAssertGreaterThan(
            try XCTUnwrap(leafCounts(context.presentation)["header"]),
            try XCTUnwrap(before["header"]),
            "A changed same-object callback must update the native button")
        context.actions.perform(.settings)
        XCTAssertEqual(received, 7)
    }

    func testEqualityIncludesEveryStoredRenderingInputAndReferenceIdentity() {
        let context = ScalarParentContext(store: makeStore(.vllm), leaf: .metrics)
        let base = context.child
        XCTAssertEqual(base, context.child)
        context.leaf = .header
        XCTAssertNotEqual(base, context.child)
        context.leaf = .metrics
        context.compact = true
        XCTAssertNotEqual(base, context.child)
        context.compact = false
        context.narrow = true
        XCTAssertNotEqual(base, context.child)
        context.narrow = false
        context.density = .condensed
        XCTAssertNotEqual(base, context.child)
        context.density = .roomy
        context.omittedRequestCount = 4
        XCTAssertNotEqual(base, context.child)
        context.omittedRequestCount = 0
        context.mode = .nativeGPUCanvas
        XCTAssertNotEqual(base, context.child)
        context.mode = .normal
        context.legacyUsageInterval = DateInterval(start: origin, duration: 60)
        XCTAssertNotEqual(base, context.child)
        context.legacyUsageInterval = nil
        context.actions = MenuActions()
        XCTAssertNotEqual(base, context.child)
        context.actions = base.actions
        context.presentation = DashboardPresentationState()
        XCTAssertNotEqual(base, context.child)
    }

    private struct DashboardCapture {
        let frames: [String: CGRect]
        let pixels: [Data]
    }

    private func captureDashboard(
        compact: Bool, size: CGSize, backend: BackendKind,
        mode: PerformanceGraphicsDiagnostics.Mode, freeze: Bool
    ) throws -> DashboardCapture {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: mode)
        let store = makeStore(backend)
        let state = DashboardPresentationState()
        let host = LiveScalarDashboardHost(store: store, state: state, compact: compact, size: size)
        defer {
            host.close()
            drain()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        try host.settle()
        if freeze {
            // This receipt still uses the original raw BackendPresentation/GPU
            // helpers and coalesced accounting; it does not read liveScalars.
            try state.freezeScalars(state.prepareFrozenScalars(store: store, compact: compact))
            try host.settle()
        }
        let keys =
            compact
            ? ["dashboard-header", "throughput-value", "gpu-value", "statistics-row"]
            : [
                "dashboard-header", "throughput-value", "gpu-value", "statistics-row",
                "dashboard-footer",
            ]
        let frames = state.scalarPerformanceFrames.filter { $0.key != "native-window" }
        let pixels = try keys.map { key in
            let context =
                "\(key), compact=\(compact), size=\(size), backend=\(backend), mode=\(mode)"
            return try host.pixels(
                in: XCTUnwrap(frames[key], "Missing native scalar anchor: \(context)"),
                context: context)
        }
        return DashboardCapture(frames: frames, pixels: pixels)
    }

    private func makeStore(_ kind: BackendKind, rate: Double = 17.3) -> MetricsStore {
        let store = MetricsStore(clock: { self.origin })
        store.beginBackendSession(kind: kind, epoch: UUID())
        store.setChartPresentationDemand(true, consumer: .dashboard)
        store.setChartPresentationDemand(true, consumer: .popover)
        store.applyBackendSample(
            BackendSample(
                kind: kind, timestamp: origin, model: "Scalar model",
                currentTPS: rate, basis: .serverAggregate, runningRequests: 2, queuedRequests: 1,
                outputTokens: 123, promptTokens: 45), epoch: store.monitoringEpoch)
        if kind == .ollama {
            let request = GenerationRequest(
                model: "Scalar model", startedAt: origin.addingTimeInterval(-1))
            store.apply(.began(request), epoch: store.monitoringEpoch)
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        model: "Scalar model", outputTokens: 24, promptTokens: 6,
                        isEstimated: false,
                        liveTPS: 17.3, finished: true, elapsed: 1, timestamp: origin)),
                epoch: store.monitoringEpoch)
        }
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: origin, activityPercent: 37.6,
                source: "scalar-test GPU", scope: .system), epoch: store.monitoringEpoch)
        store.sample(at: origin)
        return store
    }

    private func leafCounts(_ state: DashboardPresentationState) throws -> [String: UInt64] {
        let scalar = try XCTUnwrap(
            PerformanceGraphicsDiagnostics.shared.snapshot()["scalar_presentation"]
                as? [String: Any])
        let owners = try XCTUnwrap(scalar["presentation_owners"] as? [String: [String: Any]])
        let owner = try XCTUnwrap(owners[state.scalarPerformanceOwnerID.uuidString])
        let counts = try XCTUnwrap(owner["leaf_body_updates"] as? [String: NSNumber])
        return counts.mapValues(\.uint64Value)
    }

    private func presentedValues(_ state: DashboardPresentationState) throws -> NSDictionary {
        let scalar = try XCTUnwrap(
            PerformanceGraphicsDiagnostics.shared.snapshot()["scalar_presentation"]
                as? [String: Any])
        let owners = try XCTUnwrap(scalar["presentation_owners"] as? [String: [String: Any]])
        let owner = try XCTUnwrap(owners[state.scalarPerformanceOwnerID.uuidString])
        return try XCTUnwrap(owner["presented_values"] as? NSDictionary)
    }

    private func drain() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}

@Observable
@MainActor
private final class ScalarParentContext {
    var store: MetricsStore
    var actions = MenuActions()
    var presentation = DashboardPresentationState()
    var leaf: PerformanceGraphicsDiagnostics.ScalarLeaf
    var compact = false
    var narrow = false
    var density = DashboardHeightPolicy.roomy
    var omittedRequestCount = 0
    var mode = PerformanceGraphicsDiagnostics.Mode.normal
    var legacyUsageInterval: DateInterval?
    var parentTick = 0
    var scheme = ColorScheme.light

    init(store: MetricsStore, leaf: PerformanceGraphicsDiagnostics.ScalarLeaf) {
        self.store = store
        self.leaf = leaf
    }
    var child: DashboardScalarView {
        DashboardScalarView(
            actions: actions, presentation: presentation, leaf: leaf,
            isCompact: compact, narrow: narrow, density: density,
            omittedRequestCount: omittedRequestCount, scalarMode: mode,
            legacyUsageInterval: legacyUsageInterval)
    }
}

private struct ScalarParentProbe: View {
    let context: ScalarParentContext
    var body: some View {
        let _ = context.parentTick
        return context.child.equatable().environment(context.store)
            .environment(\.colorScheme, context.scheme)
    }
}

@MainActor
private final class LiveScalarLeafHost {
    private var hosting: NSHostingController<ScalarParentProbe>?
    private let context: ScalarParentContext
    private let window: NSWindow
    init(context: ScalarParentContext) {
        _ = NSApplication.shared
        self.context = context
        window = NSWindow(
            contentRect: CGRect(x: -2000, y: -2000, width: 700, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        context.presentation.setActive(true, store: context.store)
        let host = NSHostingController(rootView: ScalarParentProbe(context: context))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(CGSize(width: 700, height: 160))
        hosting = host
    }
    func settle() throws {
        let host = try XCTUnwrap(hosting)
        for _ in 0..<5 {
            window.layoutIfNeeded()
            host.view.needsLayout = true
            host.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
    func pixels() throws -> Data {
        let view = try XCTUnwrap(hosting?.view)
        return try scalarPixels(view, in: view.bounds)
    }
    func close() {
        context.presentation.setActive(false, store: context.store)
        window.contentViewController = nil
        hosting = nil
        window.close()
    }
}

@MainActor
private final class LiveScalarDashboardHost {
    private var hosting: NSHostingController<AnyView>?
    private let window: NSWindow
    private let state: DashboardPresentationState
    private let store: MetricsStore
    private let size: CGSize
    init(store: MetricsStore, state: DashboardPresentationState, compact: Bool, size: CGSize) {
        _ = NSApplication.shared
        self.store = store
        self.state = state
        self.size = size
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
    func pixels(in frame: CGRect, context: String) throws -> Data {
        try scalarPixels(XCTUnwrap(hosting?.view), in: frame, context: context)
    }
    func close() {
        state.setActive(false, store: store)
        window.contentViewController = nil
        hosting = nil
        window.close()
    }
}

@MainActor
private func scalarPixels(_ view: NSView, in frame: CGRect, context: String = "scalar leaf") throws
    -> Data
{
    let crop = frame.integral.intersection(view.bounds)
    let message =
        "Native scalar crop: \(context); anchor=\(frame), host bounds=\(view.bounds), crop=\(crop)"
    let region = try XCTUnwrap(crop.isEmpty ? nil : crop, message)
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: region), message)
    view.cacheDisplay(in: region, to: bitmap)
    XCTAssertEqual(bitmap.bitsPerSample, 8)
    let pointer = try XCTUnwrap(bitmap.bitmapData)
    let rowWidth = bitmap.pixelsWide * bitmap.samplesPerPixel
    var pixels = Data()
    for row in 0..<bitmap.pixelsHigh {
        pixels.append(pointer.advanced(by: row * bitmap.bytesPerRow), count: rowWidth)
    }
    XCTAssertGreaterThan(
        Set(pixels).count, 4, "The native image must contain actual scalar content")
    return pixels
}
