import Foundation

/// Bounded, optional work counters for the explicitly controlled app. Pixel
/// areas describe requested canvas backing, not measured GPU memory or work.
@MainActor
public final class PerformanceGraphicsDiagnostics {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case normal
        case directHost = "direct-host"
        case emptyDrawing = "empty-drawing"
        case noRenderer = "no-renderer"
        case bitmapDestination = "bitmap-destination"
        case bitmapLayerDestination = "bitmap-layer-destination"
        case bitmapLayerBGRA = "bitmap-layer-bgra"
        case bitmapLayerNoDecorations = "bitmap-layer-no-decorations"
        case nativeGPUCanvas = "native-gpu-canvas"
        case nativeGPUCoalescedScalars = "native-gpu-coalesced-scalars"
        case nativeGPURetainedTwinkles = "native-gpu-retained-twinkles"
        case nativeGPUOptimized = "native-gpu-optimized"
        case runtimeNoLifecycle = "runtime-no-lifecycle"
        case runtimeHistoryOrder = "runtime-history-order"
        case runtimeChartPreparation = "runtime-chart-preparation"
        case runtimeOptimized = "runtime-optimized"
        case runtimeSharedPreparation = "runtime-shared-preparation"
        case runtimeStableDecorationHosts = "runtime-stable-decoration-hosts"
        case runtimeStreamWrites = "runtime-stream-writes"
        case runtimeNextOptimized = "runtime-next-optimized"
        case runtimeCanvasClock = "runtime-canvas-clock"
        case runtimeStreamCanvasClock = "runtime-stream-canvas-clock"
        case runtimeOrderedPublication = "runtime-ordered-publication"
        case runtimeDirectToolPlot = "runtime-direct-tool-plot"
        case runtimeUngroupedCanvas = "runtime-ungrouped-canvas"
        case runtimeNoArrivalEffects = "runtime-no-arrival-effects"
        case runtimeCompactToolPaths = "runtime-compact-tool-paths"
        case noBlur = "no-blur"
        case cpuGlow = "cpu-glow"
        case noGradients = "no-gradients"
        case noGradientsOrBlur = "no-gradients-or-blur"

        var omitsGradients: Bool {
            self == .noGradients || self == .noGradientsOrBlur
        }

        var usesBitmapLayerDestination: Bool {
            self == .bitmapLayerDestination || self == .bitmapLayerBGRA
                || self == .bitmapLayerNoDecorations
        }

        var usesBGRA: Bool { self == .bitmapLayerBGRA }

        var omitsRailDecorations: Bool { self == .bitmapLayerNoDecorations }

        var usesNativeGPUCanvas: Bool {
            self == .normal || self == .nativeGPUCanvas || self == .nativeGPUCoalescedScalars
                || self == .nativeGPURetainedTwinkles || self == .nativeGPUOptimized
                || isRuntimeControl
        }

        var usesCoalescedScalarPresentation: Bool {
            self == .normal || self == .nativeGPUCoalescedScalars || self == .nativeGPUOptimized
                || isRuntimeControl
        }

        var usesRetainedTwinkles: Bool {
            self == .normal || self == .nativeGPURetainedTwinkles || self == .nativeGPUOptimized
                || isRuntimeControl
        }

        var isRuntimeControl: Bool {
            switch self {
            case .runtimeNoLifecycle, .runtimeHistoryOrder, .runtimeChartPreparation,
                .runtimeOptimized,
                .runtimeSharedPreparation, .runtimeStableDecorationHosts, .runtimeStreamWrites,
                .runtimeNextOptimized, .runtimeCanvasClock, .runtimeStreamCanvasClock,
                .runtimeOrderedPublication, .runtimeDirectToolPlot, .runtimeUngroupedCanvas,
                .runtimeNoArrivalEffects, .runtimeCompactToolPaths:
                true
            default:
                false
            }
        }

        var omitsLifecycleEffects: Bool { self == .runtimeNoLifecycle }
        var omitsArrivalEffects: Bool { self == .runtimeNoArrivalEffects }

        var usesSharedChartPreparation: Bool {
            self == .runtimeSharedPreparation || self == .runtimeNextOptimized
        }

        var usesStableDecorationHosts: Bool {
            self == .runtimeStableDecorationHosts || self == .runtimeNextOptimized
        }

        var usesOrderedChartPublication: Bool {
            self == .normal || usesSharedChartPreparation || self == .runtimeOrderedPublication
                || self == .runtimeDirectToolPlot
                || self == .runtimeUngroupedCanvas
                || self == .runtimeNoArrivalEffects
                || self == .runtimeCompactToolPaths
        }

        var usesDirectToolPlot: Bool { self == .runtimeDirectToolPlot }

        var usesCompactToolPaths: Bool { self == .runtimeCompactToolPaths }

        var usesUngroupedNativeCanvas: Bool { self == .runtimeUngroupedCanvas }

        var usesUnpromisedStreamBodyWrites: Bool {
            self == .normal || self == .runtimeStreamWrites || self == .runtimeNextOptimized
                || self == .runtimeStreamCanvasClock || self == .runtimeOrderedPublication
                || self == .runtimeDirectToolPlot
                || self == .runtimeUngroupedCanvas
                || self == .runtimeNoArrivalEffects
                || self == .runtimeCompactToolPaths
        }

        var usesCanvasFrameClock: Bool {
            self == .normal || self == .runtimeCanvasClock || self == .runtimeStreamCanvasClock
                || self == .runtimeOrderedPublication
                || self == .runtimeDirectToolPlot
                || self == .runtimeUngroupedCanvas
                || self == .runtimeNoArrivalEffects
                || self == .runtimeCompactToolPaths
        }

        var usesIncrementalHistoryOrdering: Bool {
            self == .normal || self == .runtimeHistoryOrder || self == .runtimeOptimized
                || self == .runtimeNoLifecycle
                || usesSharedChartPreparation || usesStableDecorationHosts
                || usesUnpromisedStreamBodyWrites
                || usesCanvasFrameClock
        }

        var usesOptimizedChartPreparation: Bool {
            self == .normal || self == .runtimeChartPreparation || self == .runtimeOptimized
                || self == .runtimeNoLifecycle
                || usesSharedChartPreparation || usesStableDecorationHosts
                || usesUnpromisedStreamBodyWrites
                || usesCanvasFrameClock
        }
    }

    public enum Role: String, CaseIterable, Sendable {
        case staticChart = "static_chart"
        case cursor
        case railBars = "rail_bars"
        case railDecorations = "rail_decorations"
    }

    public enum ConfigurationError: Error {
        case liveCanvases
    }

    public static let shared = PerformanceGraphicsDiagnostics()
    public private(set) var mode: Mode = .normal
    public private(set) var isEnabled = false

    private struct Canvas {
        let role: Role
        var pixelArea: UInt64 = 0
        var bitmapBytes: UInt64 = 0
        var layerImageBytes: UInt64 = 0
        var hasRenderer = false
    }

    private struct Counters {
        var created: UInt64 = 0
        var destroyed: UInt64 = 0
        var live: UInt64 = 0
        var peakLive: UInt64 = 0
        var updates: UInt64 = 0
        var rendererCreations: UInt64 = 0
        var rendererUpdates: UInt64 = 0
        var rendererDestructions: UInt64 = 0
        var liveRenderers: UInt64 = 0
        var peakLiveRenderers: UInt64 = 0
        var draws: UInt64 = 0
        var skippedDraws: UInt64 = 0
        var pixelArea: UInt64 = 0
        var peakPixelArea: UInt64 = 0
        var bitmapBytes: UInt64 = 0
        var peakBitmapBytes: UInt64 = 0
        var layerImageBytes: UInt64 = 0
        var peakLayerImageBytes: UInt64 = 0
        var maxWidth: Double = 0
        var maxHeight: Double = 0
        var maxScale: Double = 0

        var snapshot: [String: Any] {
            [
                "created": created, "destroyed": destroyed,
                "live": live, "peak_live": peakLive, "updates": updates,
                "renderer_creations": rendererCreations,
                "renderer_updates": rendererUpdates,
                "renderer_destructions": rendererDestructions,
                "live_renderers": liveRenderers, "peak_live_renderers": peakLiveRenderers,
                "draws": draws, "skipped_draws": skippedDraws,
                "current_pixel_area": pixelArea, "peak_pixel_area": peakPixelArea,
                "current_bitmap_bytes": bitmapBytes, "peak_bitmap_bytes": peakBitmapBytes,
                "current_layer_image_bytes": layerImageBytes,
                "peak_layer_image_bytes": peakLayerImageBytes,
                "max_width_points": maxWidth, "max_height_points": maxHeight,
                "max_scale": maxScale,
            ]
        }
    }

    private var nextID: UInt64 = 0
    // Only live views are retained; historical data has a fixed four-role size.
    private var canvases: [UInt64: Canvas] = [:]
    private var roles: [Role: Counters] = [:]
    private var total = Counters()
    private var invalidEvents: UInt64 = 0
    private var cpuGlowFallbacks: UInt64 = 0
    private var gradientSubstitutions: UInt64 = 0
    private var layerBitmapPresentations: UInt64 = 0
    private var layerBitmapFailures: UInt64 = 0
    private var layerBitmapNativeDraws: UInt64 = 0
    private var nativeGPUCanvasDraws: UInt64 = 0
    private var scalarPresentationPublications: UInt64 = 0
    private var twinkleHosts: [UInt64: Set<AnyHashable>] = [:]
    private var twinkleCounters = TwinkleCounters()

    private struct TwinkleCounters {
        var hostsCreated: UInt64 = 0
        var hostsDestroyed: UInt64 = 0
        var peakHosts: UInt64 = 0
        var instancesCreated: UInt64 = 0
        var instancesDestroyed: UInt64 = 0
        var peakInstances: UInt64 = 0
        var animationStarts: UInt64 = 0

        var liveHosts: UInt64 { hostsCreated - hostsDestroyed }
        var liveInstances: UInt64 { instancesCreated - instancesDestroyed }

        var snapshot: [String: UInt64] {
            [
                "hosts_created": hostsCreated, "hosts_destroyed": hostsDestroyed,
                "live_hosts": liveHosts, "peak_hosts": peakHosts,
                "instances_created": instancesCreated, "instances_destroyed": instancesDestroyed,
                "live_instances": liveInstances, "peak_instances": peakInstances,
                "animation_starts": animationStarts,
            ]
        }
    }

    init() {}

    /// Must be selected before native views are created. Keeping live tokens
    /// across a mode change would make lifecycle and backing comparisons false.
    public func enable(mode: Mode = .normal) throws {
        guard canvases.isEmpty, twinkleHosts.isEmpty else { throw ConfigurationError.liveCanvases }
        reset()
        self.mode = mode
        isEnabled = true
    }

    public func disable() throws {
        guard canvases.isEmpty, twinkleHosts.isEmpty else { throw ConfigurationError.liveCanvases }
        reset()
        mode = .normal
        isEnabled = false
    }

    private func reset() {
        roles = Dictionary(uniqueKeysWithValues: Role.allCases.map { ($0, Counters()) })
        total = Counters()
        invalidEvents = 0
        cpuGlowFallbacks = 0
        gradientSubstitutions = 0
        layerBitmapPresentations = 0
        layerBitmapFailures = 0
        layerBitmapNativeDraws = 0
        nativeGPUCanvasDraws = 0
        scalarPresentationPublications = 0
        twinkleCounters = TwinkleCounters()
    }

    public func canvasCreated(role: Role) -> UInt64? {
        guard isEnabled else { return nil }
        nextID += 1
        canvases[nextID] = Canvas(role: role)
        roles[role, default: Counters()].created += 1
        roles[role]!.live += 1
        roles[role]!.peakLive = max(roles[role]!.peakLive, roles[role]!.live)
        total.created += 1
        total.live += 1
        total.peakLive = max(total.peakLive, total.live)
        return nextID
    }

    public func canvasDestroyed(_ id: UInt64?) {
        guard let (id, canvas) = registered(id) else { return }
        if canvas.hasRenderer { rendererDestroyed(id) }
        roles[canvas.role]!.destroyed += 1
        roles[canvas.role]!.live -= 1
        roles[canvas.role]!.pixelArea -= canvas.pixelArea
        roles[canvas.role]!.bitmapBytes -= canvas.bitmapBytes
        roles[canvas.role]!.layerImageBytes -= canvas.layerImageBytes
        total.destroyed += 1
        total.live -= 1
        total.pixelArea -= canvas.pixelArea
        total.bitmapBytes -= canvas.bitmapBytes
        total.layerImageBytes -= canvas.layerImageBytes
        canvases.removeValue(forKey: id)
    }

    public func canvasGeometry(_ id: UInt64?, width: Double, height: Double, scale: Double) {
        guard let (id, canvas) = registered(id) else { return }
        guard width.isFinite, height.isFinite, scale.isFinite,
            width >= 0, height >= 0, scale > 0,
            let pixelWidth = UInt64(exactly: ceil(width * scale)),
            let pixelHeight = UInt64(exactly: ceil(height * scale))
        else {
            invalidEvents += 1
            return
        }
        let area = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !area.overflow else {
            invalidEvents += 1
            return
        }
        let next = (total.pixelArea - canvas.pixelArea).addingReportingOverflow(area.partialValue)
        guard !next.overflow else {
            invalidEvents += 1
            return
        }
        canvases[id]!.pixelArea = area.partialValue
        var role = roles[canvas.role]!
        role.pixelArea = role.pixelArea - canvas.pixelArea + area.partialValue
        role.peakPixelArea = max(role.peakPixelArea, role.pixelArea)
        role.maxWidth = max(role.maxWidth, width)
        role.maxHeight = max(role.maxHeight, height)
        role.maxScale = max(role.maxScale, scale)
        roles[canvas.role] = role
        total.pixelArea = next.partialValue
        total.peakPixelArea = max(total.peakPixelArea, total.pixelArea)
    }

    public func bitmapBytes(_ id: UInt64?, bytes: UInt64) {
        guard let (id, canvas) = registered(id) else { return }
        let next = (total.bitmapBytes - canvas.bitmapBytes).addingReportingOverflow(bytes)
        guard !next.overflow else {
            invalidEvents += 1
            return
        }
        canvases[id]!.bitmapBytes = bytes
        roles[canvas.role]!.bitmapBytes =
            roles[canvas.role]!.bitmapBytes - canvas.bitmapBytes + bytes
        roles[canvas.role]!.peakBitmapBytes = max(
            roles[canvas.role]!.peakBitmapBytes, roles[canvas.role]!.bitmapBytes)
        total.bitmapBytes = next.partialValue
        total.peakBitmapBytes = max(total.peakBitmapBytes, total.bitmapBytes)
    }

    /// Requested bytes for the image currently owned by a canvas's layer.
    /// This is separate from CPU scratch buffers and does not measure Core
    /// Animation's retained copies, allocation pools, or GPU memory.
    public func layerBitmapPresented(_ id: UInt64?, imageBytes: UInt64) {
        guard isEnabled, mode.usesBitmapLayerDestination,
            let (id, canvas) = registered(id)
        else { return }
        let next = (total.layerImageBytes - canvas.layerImageBytes)
            .addingReportingOverflow(imageBytes)
        let nextRole = (roles[canvas.role]!.layerImageBytes - canvas.layerImageBytes)
            .addingReportingOverflow(imageBytes)
        let presentations = layerBitmapPresentations.addingReportingOverflow(1)
        guard !next.overflow, !nextRole.overflow, !presentations.overflow
        else {
            invalidEvents += 1
            return
        }

        canvases[id]!.layerImageBytes = imageBytes
        roles[canvas.role]!.layerImageBytes = nextRole.partialValue
        roles[canvas.role]!.peakLayerImageBytes = max(
            roles[canvas.role]!.peakLayerImageBytes, nextRole.partialValue)
        total.layerImageBytes = next.partialValue
        total.peakLayerImageBytes = max(total.peakLayerImageBytes, next.partialValue)
        layerBitmapPresentations = presentations.partialValue
    }

    public func layerBitmapCleared(_ id: UInt64?) {
        guard isEnabled, mode.usesBitmapLayerDestination,
            let (id, canvas) = registered(id)
        else { return }
        roles[canvas.role]!.layerImageBytes -= canvas.layerImageBytes
        total.layerImageBytes -= canvas.layerImageBytes
        canvases[id]!.layerImageBytes = 0
    }

    /// An allocation or rendering failure makes this candidate run invalid.
    public func recordLayerBitmapFailure() {
        guard isEnabled, mode.usesBitmapLayerDestination else { return }
        let next = layerBitmapFailures.addingReportingOverflow(1)
        guard !next.overflow else {
            invalidEvents += 1
            return
        }
        layerBitmapFailures = next.partialValue
    }

    /// Records unexpected entry into native window drawing for this candidate.
    public func recordLayerBitmapNativeDraw() {
        guard isEnabled, mode.usesBitmapLayerDestination else { return }
        let next = layerBitmapNativeDraws.addingReportingOverflow(1)
        guard !next.overflow else {
            invalidEvents += 1
            return
        }
        layerBitmapNativeDraws = next.partialValue
    }

    public func canvasUpdated(_ id: UInt64?) {
        guard let (_, canvas) = registered(id) else { return }
        roles[canvas.role]!.updates += 1
    }

    public func rendererCreated(_ id: UInt64?) {
        guard let (id, canvas) = registered(id) else { return }
        guard !canvas.hasRenderer else {
            invalidEvents += 1
            return
        }
        canvases[id]!.hasRenderer = true
        roles[canvas.role]!.rendererCreations += 1
        roles[canvas.role]!.liveRenderers += 1
        roles[canvas.role]!.peakLiveRenderers = max(
            roles[canvas.role]!.peakLiveRenderers, roles[canvas.role]!.liveRenderers)
        total.liveRenderers += 1
        total.peakLiveRenderers = max(total.peakLiveRenderers, total.liveRenderers)
    }

    public func rendererUpdated(_ id: UInt64?) {
        guard let (_, canvas) = registered(id) else { return }
        guard canvas.hasRenderer else {
            invalidEvents += 1
            return
        }
        roles[canvas.role]!.rendererUpdates += 1
    }

    public func rendererDestroyed(_ id: UInt64?) {
        guard let (id, canvas) = registered(id) else { return }
        guard canvas.hasRenderer else {
            invalidEvents += 1
            return
        }
        canvases[id]!.hasRenderer = false
        roles[canvas.role]!.rendererDestructions += 1
        roles[canvas.role]!.liveRenderers -= 1
        total.liveRenderers -= 1
    }

    public func canvasDrawn(_ id: UInt64?) {
        guard let (_, canvas) = registered(id) else { return }
        roles[canvas.role]!.draws += 1
    }

    /// Records an actual SwiftUI Canvas drawing callback for the controlled
    /// drawing-group backend. This counts CPU callbacks, not GPU executions or
    /// GPU time. Call instead of canvasDrawn so role and backend totals agree.
    public func nativeGPUCanvasDrawn(_ id: UInt64?) {
        guard isEnabled, mode.usesNativeGPUCanvas,
            let (_, canvas) = registered(id)
        else { return }
        let next = nativeGPUCanvasDraws.addingReportingOverflow(1)
        let nextRole = roles[canvas.role]!.draws.addingReportingOverflow(1)
        guard !next.overflow, !nextRole.overflow else {
            invalidEvents += 1
            return
        }
        nativeGPUCanvasDraws = next.partialValue
        roles[canvas.role]!.draws = nextRole.partialValue
    }

    /// Bounded lifecycle evidence for retained Core Animation shapes. These
    /// count installed animations, never displayed frames or GPU execution time.
    func retainedTwinkleHostCreated() -> UInt64? {
        guard isEnabled, mode.usesRetainedTwinkles else { return nil }
        nextID += 1
        twinkleHosts[nextID] = []
        twinkleCounters.hostsCreated += 1
        twinkleCounters.peakHosts = max(twinkleCounters.peakHosts, twinkleCounters.liveHosts)
        return nextID
    }

    func scalarPresentationPublished() {
        guard isEnabled, mode.usesCoalescedScalarPresentation else { return }
        let next = scalarPresentationPublications.addingReportingOverflow(1)
        guard !next.overflow else {
            invalidEvents += 1
            return
        }
        scalarPresentationPublications = next.partialValue
    }

    func retainedTwinkleHostUpdated(
        _ id: UInt64?, instances: Set<AnyHashable>, animationsStarted: UInt64
    ) {
        guard isEnabled, mode.usesRetainedTwinkles, let id else { return }
        guard let previous = twinkleHosts[id], instances.count <= 2 else {
            invalidEvents += 1
            return
        }
        let created = twinkleCounters.instancesCreated.addingReportingOverflow(
            UInt64(instances.subtracting(previous).count))
        let destroyed = twinkleCounters.instancesDestroyed.addingReportingOverflow(
            UInt64(previous.subtracting(instances).count))
        let animations = twinkleCounters.animationStarts.addingReportingOverflow(animationsStarted)
        guard !created.overflow, !destroyed.overflow, !animations.overflow else {
            invalidEvents += 1
            return
        }
        twinkleHosts[id] = instances
        twinkleCounters.instancesCreated = created.partialValue
        twinkleCounters.instancesDestroyed = destroyed.partialValue
        twinkleCounters.animationStarts = animations.partialValue
        twinkleCounters.peakInstances = max(
            twinkleCounters.peakInstances, twinkleCounters.liveInstances)
    }

    func retainedTwinkleHostDestroyed(_ id: UInt64?) {
        guard isEnabled, mode.usesRetainedTwinkles, let id else { return }
        guard let instances = twinkleHosts.removeValue(forKey: id) else {
            invalidEvents += 1
            return
        }
        twinkleCounters.hostsDestroyed += 1
        twinkleCounters.instancesDestroyed += UInt64(instances.count)
    }

    public func drawSkipped(_ id: UInt64?) {
        guard let (_, canvas) = registered(id) else { return }
        roles[canvas.role]!.skippedDraws += 1
    }

    /// Any fallback makes a cpu-glow attribution run ineligible: it contains
    /// work from the original filtered renderer as well as the candidate.
    public func recordCPUGlowFallback() {
        guard isEnabled, mode == .cpuGlow else { return }
        cpuGlowFallbacks += 1
    }

    /// Confirms the diagnostic replaced an executed gradient with a solid fill.
    /// Both gradient controls preserve chart geometry and animation schedules.
    /// Only the combined control also omits the existing filtered series glow.
    public func recordGradientSubstitution() {
        guard isEnabled, mode.omitsGradients else { return }
        gradientSubstitutions += 1
    }

    private func registered(_ id: UInt64?) -> (UInt64, Canvas)? {
        guard isEnabled, let id else { return nil }
        guard let canvas = canvases[id] else {
            invalidEvents += 1
            return nil
        }
        return (id, canvas)
    }

    public func snapshot() -> [String: Any] {
        var result: [String: Any] = [
            "enabled": isEnabled, "mode": mode.rawValue,
            "invalid_events": invalidEvents,
            "cpu_glow_fallbacks": cpuGlowFallbacks,
            "gradient_substitutions": gradientSubstitutions,
            "layer_bitmap_presentations": layerBitmapPresentations,
            "layer_bitmap_failures": layerBitmapFailures,
            "layer_bitmap_native_draws": layerBitmapNativeDraws,
            "native_gpu_canvas_draws": nativeGPUCanvasDraws,
            "scalar_presentation_publications": scalarPresentationPublications,
            "retained_twinkles": twinkleCounters.snapshot,
            "live_canvases": total.live, "peak_live_canvases": total.peakLive,
            "live_renderers": total.liveRenderers,
            "peak_live_renderers": total.peakLiveRenderers,
            "current_pixel_area": total.pixelArea, "peak_pixel_area": total.peakPixelArea,
            "current_bitmap_bytes": total.bitmapBytes,
            "peak_bitmap_bytes": total.peakBitmapBytes,
            "current_layer_image_bytes": total.layerImageBytes,
            "peak_layer_image_bytes": total.peakLayerImageBytes,
            "roles": Dictionary(
                uniqueKeysWithValues: Role.allCases.map {
                    ($0.rawValue, (roles[$0] ?? Counters()).snapshot)
                }),
        ]
        if isEnabled, mode.usesBitmapLayerDestination {
            result["layer_bitmap_pixel_format"] =
                mode.usesBGRA
                ? "bgra8-premultiplied-first" : "rgba8-premultiplied-last"
            result["layer_bitmap_color_space"] = "device-rgb"
            result["rail_decorations_enabled"] = !mode.omitsRailDecorations
        }
        if isEnabled, mode.usesNativeGPUCanvas {
            result["native_gpu_backend"] =
                mode.usesUngroupedNativeCanvas
                ? "swiftui-canvas" : "swiftui-canvas-drawing-group"
            result["scalar_presentation_coalesced"] = mode.usesCoalescedScalarPresentation
            result["retained_twinkles_enabled"] = mode.usesRetainedTwinkles
            result["incremental_history_ordering"] = mode.usesIncrementalHistoryOrdering
            result["optimized_chart_preparation"] = mode.usesOptimizedChartPreparation
            result["lifecycle_effects_enabled"] = !mode.omitsLifecycleEffects
            result["shared_chart_preparation"] = mode.usesSharedChartPreparation
            result["stable_decoration_hosts"] = mode.usesStableDecorationHosts
            result["unpromised_stream_body_writes"] = mode.usesUnpromisedStreamBodyWrites
            result["canvas_frame_clock"] = mode.usesCanvasFrameClock
            result["ordered_chart_publication"] = mode.usesOrderedChartPublication
            result["direct_tool_plot"] = mode.usesDirectToolPlot
            result["ungrouped_native_canvas"] = mode.usesUngroupedNativeCanvas
            result["arrival_effects_enabled"] =
                !mode.omitsLifecycleEffects && !mode.omitsArrivalEffects
            result["compact_tool_paths_enabled"] = mode.usesCompactToolPaths
        }
        if isEnabled, mode.usesRetainedTwinkles {
            result["retained_twinkle_backend"] = "core-animation-shape-layers"
        }
        return result
    }
}
