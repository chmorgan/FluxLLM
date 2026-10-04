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
        case runtimeDeferredToolGeometry = "runtime-deferred-tool-geometry"
        case runtimeDeferredToolGeometry2Hz = "runtime-deferred-tool-geometry-2hz"
        case runtimeMetalArrivalBursts = "runtime-metal-arrival-bursts"
        case runtimeMetalFullChart = "runtime-metal-full-chart"
        case runtimeMetalCachedChart = "runtime-metal-cached-chart"
        case runtimeMetalPrimitiveEffects = "runtime-metal-primitive-effects"
        case runtimeTelemetryBatch = "runtime-telemetry-batch"
        case runtimeAtomicChartScale = "runtime-atomic-chart-scale"
        case runtimeEfficientEffects = "runtime-efficient-effects"
        case runtimeCompletedLaneCache = "runtime-completed-lane-cache"
        case runtimeCachedRailGeometry = "runtime-cached-rail-geometry"
        case runtimeReuseCaches = "runtime-reuse-caches"
        case runtimeHeldStaticChart = "runtime-held-static-chart"
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
            !usesMetalFullChart
                && (self == .normal || self == .nativeGPUCanvas
                    || self == .nativeGPUCoalescedScalars
                    || self == .nativeGPURetainedTwinkles || self == .nativeGPUOptimized
                    || isRuntimeControl)
        }

        var usesCoalescedScalarPresentation: Bool {
            self == .normal || self == .nativeGPUCoalescedScalars || self == .nativeGPUOptimized
                || isRuntimeControl
        }

        var usesRetainedTwinkles: Bool {
            cachesMetalStaticChart
                || (!usesMetalFullChart
                    && (self == .normal || self == .nativeGPURetainedTwinkles
                        || self == .nativeGPUOptimized
                        || isRuntimeControl))
        }

        var isRuntimeControl: Bool {
            switch self {
            case .runtimeNoLifecycle, .runtimeHistoryOrder, .runtimeChartPreparation,
                .runtimeOptimized,
                .runtimeSharedPreparation, .runtimeStableDecorationHosts, .runtimeStreamWrites,
                .runtimeNextOptimized, .runtimeCanvasClock, .runtimeStreamCanvasClock,
                .runtimeOrderedPublication, .runtimeDirectToolPlot, .runtimeUngroupedCanvas,
                .runtimeNoArrivalEffects, .runtimeCompactToolPaths, .runtimeDeferredToolGeometry,
                .runtimeDeferredToolGeometry2Hz, .runtimeMetalArrivalBursts, .runtimeMetalFullChart,
                .runtimeMetalCachedChart, .runtimeMetalPrimitiveEffects, .runtimeTelemetryBatch,
                .runtimeAtomicChartScale, .runtimeEfficientEffects, .runtimeCompletedLaneCache,
                .runtimeCachedRailGeometry, .runtimeReuseCaches, .runtimeHeldStaticChart:
                true
            default:
                false
            }
        }

        var omitsLifecycleEffects: Bool { self == .runtimeNoLifecycle }
        var omitsArrivalEffects: Bool { self == .runtimeNoArrivalEffects }
        var usesMetalArrivalBursts: Bool { self == .runtimeMetalArrivalBursts }
        var usesMetalFullChart: Bool {
            self == .runtimeMetalFullChart || self == .runtimeMetalCachedChart
        }
        var cachesMetalStaticChart: Bool { self == .runtimeMetalCachedChart }
        var usesMetalPrimitiveEffects: Bool {
            self == .runtimeMetalPrimitiveEffects || self == .runtimeEfficientEffects
        }
        var usesBatchedTelemetryDelivery: Bool {
            self == .runtimeTelemetryBatch || self == .runtimeEfficientEffects
        }
        var usesAtomicChartScale: Bool {
            self == .runtimeAtomicChartScale || self == .runtimeEfficientEffects
        }
        var usesCompletedLaneCache: Bool {
            self == .runtimeCompletedLaneCache || self == .runtimeReuseCaches
        }
        var usesCachedRailGeometry: Bool {
            self == .runtimeCachedRailGeometry || self == .runtimeReuseCaches
        }
        /// Causal diagnostic only: the displayed static chart intentionally stops updating.
        var usesHeldStaticChart: Bool { self == .runtimeHeldStaticChart }

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
                || usesDeferredToolGeometry
                || usesMetalArrivalBursts
                || usesMetalFullChart
                || usesMetalPrimitiveEffects || usesBatchedTelemetryDelivery || usesAtomicChartScale
                || usesCompletedLaneCache || usesCachedRailGeometry
                || usesHeldStaticChart
        }

        var usesDirectToolPlot: Bool { self == .runtimeDirectToolPlot }

        var usesCompactToolPaths: Bool { self == .runtimeCompactToolPaths }

        var usesDeferredToolGeometry: Bool {
            self == .runtimeDeferredToolGeometry || self == .runtimeDeferredToolGeometry2Hz
        }

        /// Chart data publication is independent of metrics sampling and the
        /// animation frame clock. Keep the faster cadence diagnostic-only until measured.
        var chartPublicationIntervalSeconds: TimeInterval {
            self == .runtimeDeferredToolGeometry2Hz ? 0.5 : 1
        }

        var usesUngroupedNativeCanvas: Bool { self == .runtimeUngroupedCanvas }

        var usesUnpromisedStreamBodyWrites: Bool {
            self == .normal || self == .runtimeStreamWrites || self == .runtimeNextOptimized
                || self == .runtimeStreamCanvasClock || self == .runtimeOrderedPublication
                || self == .runtimeDirectToolPlot
                || self == .runtimeUngroupedCanvas
                || self == .runtimeNoArrivalEffects
                || self == .runtimeCompactToolPaths
                || usesDeferredToolGeometry
                || usesMetalArrivalBursts
                || usesMetalFullChart
                || usesMetalPrimitiveEffects || usesBatchedTelemetryDelivery || usesAtomicChartScale
                || usesCompletedLaneCache || usesCachedRailGeometry
                || usesHeldStaticChart
        }

        var usesCanvasFrameClock: Bool {
            self == .normal || self == .runtimeCanvasClock || self == .runtimeStreamCanvasClock
                || self == .runtimeOrderedPublication
                || self == .runtimeDirectToolPlot
                || self == .runtimeUngroupedCanvas
                || self == .runtimeNoArrivalEffects
                || self == .runtimeCompactToolPaths
                || usesDeferredToolGeometry
                || usesMetalArrivalBursts
                || usesMetalPrimitiveEffects || usesBatchedTelemetryDelivery || usesAtomicChartScale
                || usesCompletedLaneCache || usesCachedRailGeometry
                || usesHeldStaticChart
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
        var drawingUpdateAttempts: UInt64 = 0
        var drawingUpdatesApplied: UInt64 = 0
        var drawingUpdatesHeld: UInt64 = 0
        var drawingHoldResets: UInt64 = 0
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
                "drawing_update_attempts": drawingUpdateAttempts,
                "drawing_updates_applied": drawingUpdatesApplied,
                "drawing_updates_held": drawingUpdatesHeld,
                "drawing_hold_resets": drawingHoldResets,
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
    private struct MetalFullChartHost {
        var bufferBytes: UInt64 = 0
        var textureBytes: UInt64 = 0
    }

    private var metalFullChartHosts: [UInt64: MetalFullChartHost] = [:]
    private var metalFullChartCounters = MetalFullChartCounters()
    private var metalPrimitiveEffectsHosts: [UInt64: UInt64] = [:]
    private var metalPrimitiveEffectsCounters = MetalPrimitiveEffectsCounters()
    private var batchedTelemetryCounters = BatchedTelemetryCounters()
    private var atomicChartScaleResolutions: UInt64 = 0
    private var atomicChartScaleChanges: UInt64 = 0
    private var atomicChartScaleCacheHits: UInt64 = 0
    private var completedLaneCacheBuilds: UInt64 = 0
    private var completedLaneCacheHits: UInt64 = 0
    private var completedLaneCacheVisitedRecords: UInt64 = 0
    private var completedLaneCacheEntries: UInt64 = 0
    private var completedLaneCachePeakEntries: UInt64 = 0
    private var railGeometryCacheBuilds: UInt64 = 0
    private var railGeometryCacheHits: UInt64 = 0
    private var railGeometryCacheEntries: UInt64 = 0
    private var railGeometryCachePeakEntries: UInt64 = 0
    private var railGeometryCacheOwners: [UUID: UInt64] = [:]
    private var railGeometryCachePeakOwners: UInt64 = 0

    private struct MetalPrimitiveEffectsCounters {
        var hostsCreated: UInt64 = 0
        var hostsDestroyed: UInt64 = 0
        var liveHosts: UInt64 = 0
        var peakHosts: UInt64 = 0
        var descriptorUploads: UInt64 = 0
        var submissions: UInt64 = 0
        var clears: UInt64 = 0
        var arrivalFrames: UInt64 = 0
        var completionFrames: UInt64 = 0
        var twinkleFrames: UInt64 = 0
        var framesSkipped: UInt64 = 0
        var failures: UInt64 = 0
        var fallbacks: UInt64 = 0
        var currentBufferBytes: UInt64 = 0
        var peakBufferBytes: UInt64 = 0

        var snapshot: [String: UInt64] {
            [
                "hosts_created": hostsCreated, "hosts_destroyed": hostsDestroyed,
                "live_hosts": liveHosts, "peak_hosts": peakHosts,
                "descriptor_uploads": descriptorUploads, "submissions": submissions,
                "clears": clears,
                "arrival_frames": arrivalFrames, "completion_frames": completionFrames,
                "twinkle_frames": twinkleFrames, "frames_skipped": framesSkipped,
                "failures": failures, "fallbacks": fallbacks,
                "current_buffer_bytes": currentBufferBytes, "peak_buffer_bytes": peakBufferBytes,
            ]
        }
    }

    private struct BatchedTelemetryCounters {
        var compactStatesEnqueued: UInt64 = 0
        var snapshotsMaterialized: UInt64 = 0
        var batchesApplied: UInt64 = 0
        var eventsApplied: UInt64 = 0
        var projectionRefreshes: UInt64 = 0

        var snapshot: [String: UInt64] {
            [
                "compact_states_enqueued": compactStatesEnqueued,
                "snapshots_materialized": snapshotsMaterialized,
                "batches_applied": batchesApplied, "events_applied": eventsApplied,
                "projection_refreshes": projectionRefreshes,
            ]
        }
    }

    private struct MetalFullChartCounters {
        var hostsCreated: UInt64 = 0
        var hostsDestroyed: UInt64 = 0
        var liveHosts: UInt64 = 0
        var peakHosts: UInt64 = 0
        var geometryUploads: UInt64 = 0
        var submissions: UInt64 = 0
        var failures: UInt64 = 0
        var framesSkipped: UInt64 = 0
        var staticFrames: UInt64 = 0
        var arrivalFrames: UInt64 = 0
        var completionFrames: UInt64 = 0
        var twinkleFrames: UInt64 = 0
        var currentBufferBytes: UInt64 = 0
        var peakBufferBytes: UInt64 = 0
        var staticRasterizations: UInt64 = 0
        var staticCacheComposites: UInt64 = 0
        var effectClockTicks: UInt64 = 0
        var currentTextureBytes: UInt64 = 0
        var peakTextureBytes: UInt64 = 0
        var staticSceneRevisions: UInt64 = 0
        var sceneInitialRevisions: UInt64 = 0
        var scenePublicationRevisions: UInt64 = 0
        var sceneScaleRevisions: UInt64 = 0
        var sceneLayoutRevisions: UInt64 = 0
        var sceneAppearanceRevisions: UInt64 = 0
        var sceneRailRevisions: UInt64 = 0
        var sceneUnclassifiedRevisions: UInt64 = 0
        var staticSurfaceInvalidations: UInt64 = 0

        var snapshot: [String: UInt64] {
            [
                "hosts_created": hostsCreated,
                "hosts_destroyed": hostsDestroyed,
                "live_hosts": liveHosts,
                "peak_hosts": peakHosts,
                "geometry_uploads": geometryUploads,
                "submissions": submissions,
                "failures": failures,
                "frames_skipped": framesSkipped,
                "static_frames": staticFrames,
                "arrival_frames": arrivalFrames,
                "completion_frames": completionFrames,
                "twinkle_frames": twinkleFrames,
                "current_buffer_bytes": currentBufferBytes,
                "peak_buffer_bytes": peakBufferBytes,
                "static_rasterizations": staticRasterizations,
                "static_cache_composites": staticCacheComposites,
                "effect_clock_ticks": effectClockTicks,
                "current_texture_bytes": currentTextureBytes,
                "peak_texture_bytes": peakTextureBytes,
                "static_scene_revisions": staticSceneRevisions,
                "scene_initial_revisions": sceneInitialRevisions,
                "scene_publication_revisions": scenePublicationRevisions,
                "scene_scale_revisions": sceneScaleRevisions,
                "scene_layout_revisions": sceneLayoutRevisions,
                "scene_appearance_revisions": sceneAppearanceRevisions,
                "scene_rail_revisions": sceneRailRevisions,
                "scene_unclassified_revisions": sceneUnclassifiedRevisions,
                "static_surface_invalidations": staticSurfaceInvalidations,
            ]
        }
    }

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
        guard canvases.isEmpty, twinkleHosts.isEmpty, metalFullChartHosts.isEmpty,
            metalPrimitiveEffectsHosts.isEmpty
        else { throw ConfigurationError.liveCanvases }
        reset()
        self.mode = mode
        isEnabled = true
    }

    public func disable() throws {
        guard canvases.isEmpty, twinkleHosts.isEmpty, metalFullChartHosts.isEmpty,
            metalPrimitiveEffectsHosts.isEmpty
        else { throw ConfigurationError.liveCanvases }
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
        metalFullChartCounters = MetalFullChartCounters()
        metalPrimitiveEffectsCounters = MetalPrimitiveEffectsCounters()
        batchedTelemetryCounters = BatchedTelemetryCounters()
        atomicChartScaleResolutions = 0
        atomicChartScaleChanges = 0
        atomicChartScaleCacheHits = 0
        completedLaneCacheBuilds = 0
        completedLaneCacheHits = 0
        completedLaneCacheVisitedRecords = 0
        completedLaneCacheEntries = 0
        completedLaneCachePeakEntries = 0
        railGeometryCacheBuilds = 0
        railGeometryCacheHits = 0
        railGeometryCacheEntries = 0
        railGeometryCachePeakEntries = 0
        railGeometryCacheOwners.removeAll(keepingCapacity: false)
        railGeometryCachePeakOwners = 0
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

    /// Counts requested publications separately from actual Canvas callbacks.
    /// The held control must prove that data preparation continued while drawing stopped.
    func staticChartDrawingRequested(applied: Bool, reset: Bool) {
        guard isEnabled, mode.usesHeldStaticChart else { return }
        var counters = roles[.staticChart, default: Counters()]
        let attempts = counters.drawingUpdateAttempts.addingReportingOverflow(1)
        let appliedCount = counters.drawingUpdatesApplied.addingReportingOverflow(applied ? 1 : 0)
        let heldCount = counters.drawingUpdatesHeld.addingReportingOverflow(applied ? 0 : 1)
        let resets = counters.drawingHoldResets.addingReportingOverflow(reset ? 1 : 0)
        guard !attempts.overflow, !appliedCount.overflow, !heldCount.overflow, !resets.overflow
        else {
            invalidEvents += 1
            return
        }
        counters.drawingUpdateAttempts = attempts.partialValue
        counters.drawingUpdatesApplied = appliedCount.partialValue
        counters.drawingUpdatesHeld = heldCount.partialValue
        counters.drawingHoldResets = resets.partialValue
        roles[.staticChart] = counters
    }

    func staticChartDrawingReset() {
        guard isEnabled, mode.usesHeldStaticChart else { return }
        let next = roles[.staticChart, default: Counters()].drawingHoldResets
            .addingReportingOverflow(1)
        guard !next.overflow else {
            invalidEvents += 1
            return
        }
        roles[.staticChart, default: Counters()].drawingHoldResets = next.partialValue
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

    /// Executed-work evidence only, never a substitute for measured GPU time.
    /// Buffer bytes describe retained renderer geometry/descriptor allocations;
    /// drawable textures, driver allocations and physical GPU memory are excluded.
    func metalFullChartHostCreated() -> UInt64? {
        guard isEnabled, mode.usesMetalFullChart else { return nil }
        nextID += 1
        metalFullChartHosts[nextID] = MetalFullChartHost()
        metalFullChartCounters.hostsCreated += 1
        metalFullChartCounters.liveHosts += 1
        metalFullChartCounters.peakHosts = max(
            metalFullChartCounters.peakHosts, UInt64(metalFullChartHosts.count))
        return nextID
    }

    func metalFullChartHostDestroyed(_ id: UInt64?) {
        guard let id, isEnabled, mode.usesMetalFullChart else { return }
        guard let host = metalFullChartHosts.removeValue(forKey: id) else {
            invalidEvents += 1
            return
        }
        metalFullChartCounters.hostsDestroyed += 1
        metalFullChartCounters.liveHosts -= 1
        metalFullChartCounters.currentBufferBytes -= host.bufferBytes
        metalFullChartCounters.currentTextureBytes -= host.textureBytes
    }

    func metalFullChartGeometryUploaded(_ id: UInt64?, bytes: UInt64) {
        guard metalFullChartBuffersRetained(id, bytes: bytes) else { return }
        metalFullChartCounters.geometryUploads += 1
    }

    /// Refresh accounting when a renderer lazily allocates reusable frame
    /// scratch buffers; this is not evidence of another geometry upload.
    @discardableResult
    func metalFullChartBuffersRetained(_ id: UInt64?, bytes: UInt64) -> Bool {
        guard let id, isEnabled, mode.usesMetalFullChart else { return false }
        guard var host = metalFullChartHosts[id] else {
            invalidEvents += 1
            return false
        }
        let total = metalFullChartCounters.currentBufferBytes - host.bufferBytes
        let next = total.addingReportingOverflow(bytes)
        guard !next.overflow else {
            invalidEvents += 1
            return false
        }
        host.bufferBytes = bytes
        metalFullChartHosts[id] = host
        metalFullChartCounters.currentBufferBytes = next.partialValue
        metalFullChartCounters.peakBufferBytes = max(
            metalFullChartCounters.peakBufferBytes, next.partialValue)
        return true
    }

    /// Count a successfully encoded cache composite, optionally preceded by a
    /// new static rasterization. These are execution counters, not GPU timings.
    func metalFullChartStaticCacheUsed(_ id: UInt64?, rasterized: Bool, bytes: UInt64) {
        guard metalFullChartTexturesRetained(id, bytes: bytes) else { return }
        metalFullChartCounters.staticCacheComposites += 1
        if rasterized { metalFullChartCounters.staticRasterizations += 1 }
    }

    /// Distinguish continuous effect-clock callbacks from paused, on-demand
    /// publication draws in the cached-chart experiment.
    func metalFullChartEffectClockTick(_ id: UInt64?) {
        guard let id, isEnabled, mode.cachesMetalStaticChart else { return }
        guard metalFullChartHosts[id] != nil else {
            invalidEvents += 1
            return
        }
        metalFullChartCounters.effectClockTicks += 1
    }

    /// A static scene can change independently of chart data preparation.
    /// Count each rebuilt scene once and retain all applicable causes; cause
    /// counts overlap when a single revision changes multiple inputs.
    func metalFullChartSceneRevised(
        initial: Bool, publication: Bool, scale: Bool, layout: Bool, appearance: Bool, rails: Bool
    ) {
        guard isEnabled, mode.cachesMetalStaticChart else { return }
        metalFullChartCounters.staticSceneRevisions += 1
        if initial { metalFullChartCounters.sceneInitialRevisions += 1 }
        if publication { metalFullChartCounters.scenePublicationRevisions += 1 }
        if scale { metalFullChartCounters.sceneScaleRevisions += 1 }
        if layout { metalFullChartCounters.sceneLayoutRevisions += 1 }
        if appearance { metalFullChartCounters.sceneAppearanceRevisions += 1 }
        if rails { metalFullChartCounters.sceneRailRevisions += 1 }
        if !initial && !publication && !scale && !layout && !appearance && !rails {
            metalFullChartCounters.sceneUnclassifiedRevisions += 1
        }
    }

    /// Drawable-size or backing-scale changes invalidate the cached pixels
    /// even when the immutable chart scene itself remains unchanged.
    func metalFullChartSurfaceInvalidated(_ id: UInt64?) {
        guard let id, isEnabled, mode.cachesMetalStaticChart else { return }
        guard metalFullChartHosts[id] != nil else {
            invalidEvents += 1
            return
        }
        metalFullChartCounters.staticSurfaceInvalidations += 1
    }

    /// Cache texture accounting stays separate from geometry buffers and
    /// excludes drawables and driver allocations. Include textures retained by
    /// in-flight frames until they drain; zero means the last texture lease
    /// has been released, even when no frame is encoded at that time.
    @discardableResult
    func metalFullChartTexturesRetained(_ id: UInt64?, bytes: UInt64) -> Bool {
        guard let id, isEnabled, mode.cachesMetalStaticChart else { return false }
        guard var host = metalFullChartHosts[id] else {
            invalidEvents += 1
            return false
        }
        let total = metalFullChartCounters.currentTextureBytes - host.textureBytes
        let next = total.addingReportingOverflow(bytes)
        guard !next.overflow else {
            invalidEvents += 1
            return false
        }
        host.textureBytes = bytes
        metalFullChartHosts[id] = host
        metalFullChartCounters.currentTextureBytes = next.partialValue
        metalFullChartCounters.peakTextureBytes = max(
            metalFullChartCounters.peakTextureBytes, next.partialValue)
        return true
    }

    func metalFullChartFrameSubmitted(
        _ id: UInt64?, staticChart: Bool, arrival: Bool, completion: Bool, twinkle: Bool
    ) {
        guard let id, isEnabled, mode.usesMetalFullChart else { return }
        guard metalFullChartHosts[id] != nil else {
            invalidEvents += 1
            return
        }
        metalFullChartCounters.submissions += 1
        if staticChart { metalFullChartCounters.staticFrames += 1 }
        if arrival { metalFullChartCounters.arrivalFrames += 1 }
        if completion { metalFullChartCounters.completionFrames += 1 }
        if twinkle { metalFullChartCounters.twinkleFrames += 1 }
    }

    func metalFullChartFrameSkipped(_ id: UInt64?) {
        guard let id, isEnabled, mode.usesMetalFullChart else { return }
        guard metalFullChartHosts[id] != nil else {
            invalidEvents += 1
            return
        }
        metalFullChartCounters.framesSkipped += 1
    }

    func metalFullChartFailure(_ id: UInt64? = nil) {
        guard isEnabled, mode.usesMetalFullChart else { return }
        if let id, metalFullChartHosts[id] == nil { invalidEvents += 1 }
        metalFullChartCounters.failures += 1
    }

    /// The effects-only surface owns no static chart pixels. Counts describe
    /// submitted work and retained descriptor buffers, never GPU execution time.
    func metalPrimitiveEffectsHostCreated() -> UInt64? {
        guard isEnabled, mode.usesMetalPrimitiveEffects else { return nil }
        nextID += 1
        metalPrimitiveEffectsHosts[nextID] = 0
        metalPrimitiveEffectsCounters.hostsCreated += 1
        metalPrimitiveEffectsCounters.liveHosts += 1
        metalPrimitiveEffectsCounters.peakHosts = max(
            metalPrimitiveEffectsCounters.peakHosts, metalPrimitiveEffectsCounters.liveHosts)
        return nextID
    }

    func metalPrimitiveEffectsHostDestroyed(_ id: UInt64?) {
        guard let id, isEnabled, mode.usesMetalPrimitiveEffects else { return }
        guard let bytes = metalPrimitiveEffectsHosts.removeValue(forKey: id) else {
            invalidEvents += 1
            return
        }
        metalPrimitiveEffectsCounters.hostsDestroyed += 1
        metalPrimitiveEffectsCounters.liveHosts -= 1
        metalPrimitiveEffectsCounters.currentBufferBytes -= bytes
    }

    @discardableResult
    func metalPrimitiveEffectsBuffersRetained(_ id: UInt64?, bytes: UInt64) -> Bool {
        guard let id, isEnabled, mode.usesMetalPrimitiveEffects else { return false }
        guard let previous = metalPrimitiveEffectsHosts[id] else {
            invalidEvents += 1
            return false
        }
        let next = (metalPrimitiveEffectsCounters.currentBufferBytes - previous)
            .addingReportingOverflow(bytes)
        guard !next.overflow else {
            invalidEvents += 1
            return false
        }
        metalPrimitiveEffectsHosts[id] = bytes
        metalPrimitiveEffectsCounters.currentBufferBytes = next.partialValue
        metalPrimitiveEffectsCounters.peakBufferBytes = max(
            metalPrimitiveEffectsCounters.peakBufferBytes, next.partialValue)
        return true
    }

    func metalPrimitiveEffectsDescriptorsUploaded(_ id: UInt64?, bytes: UInt64) {
        guard metalPrimitiveEffectsBuffersRetained(id, bytes: bytes) else { return }
        metalPrimitiveEffectsCounters.descriptorUploads += 1
    }

    func metalPrimitiveEffectsFrameSubmitted(
        _ id: UInt64?, arrival: Bool, completion: Bool, twinkle: Bool, clear: Bool
    ) {
        guard let id, isEnabled, mode.usesMetalPrimitiveEffects else { return }
        guard metalPrimitiveEffectsHosts[id] != nil else {
            invalidEvents += 1
            return
        }
        guard !clear || (!arrival && !completion && !twinkle) else {
            invalidEvents += 1
            return
        }
        metalPrimitiveEffectsCounters.submissions += 1
        if clear { metalPrimitiveEffectsCounters.clears += 1 }
        if arrival { metalPrimitiveEffectsCounters.arrivalFrames += 1 }
        if completion { metalPrimitiveEffectsCounters.completionFrames += 1 }
        if twinkle { metalPrimitiveEffectsCounters.twinkleFrames += 1 }
    }

    func metalPrimitiveEffectsFrameSkipped(_ id: UInt64?) {
        guard let id, isEnabled, mode.usesMetalPrimitiveEffects else { return }
        guard metalPrimitiveEffectsHosts[id] != nil else {
            invalidEvents += 1
            return
        }
        metalPrimitiveEffectsCounters.framesSkipped += 1
    }

    func metalPrimitiveEffectsFailure(_ id: UInt64? = nil) {
        guard isEnabled, mode.usesMetalPrimitiveEffects else { return }
        if let id, metalPrimitiveEffectsHosts[id] == nil { invalidEvents += 1 }
        metalPrimitiveEffectsCounters.failures += 1
    }

    func metalPrimitiveEffectsFallback() {
        guard isEnabled, mode.usesMetalPrimitiveEffects else { return }
        metalPrimitiveEffectsCounters.fallbacks += 1
    }

    func batchedTelemetryStateEnqueued(count: Int = 1) {
        addBatchedTelemetryCount(count, to: \.compactStatesEnqueued)
    }

    func batchedTelemetrySnapshotMaterialized(count: Int = 1) {
        addBatchedTelemetryCount(count, to: \.snapshotsMaterialized)
    }

    func batchedTelemetryBatchApplied(eventCount: Int) {
        guard isEnabled, mode.usesBatchedTelemetryDelivery else { return }
        guard eventCount > 0 else {
            invalidEvents += 1
            return
        }
        addBatchedTelemetryCount(1, to: \.batchesApplied)
        addBatchedTelemetryCount(eventCount, to: \.eventsApplied)
    }

    func batchedTelemetryProjectionRefreshed() {
        addBatchedTelemetryCount(1, to: \.projectionRefreshes)
    }

    private func addBatchedTelemetryCount(
        _ count: Int, to keyPath: WritableKeyPath<BatchedTelemetryCounters, UInt64>
    ) {
        guard isEnabled, mode.usesBatchedTelemetryDelivery else { return }
        guard let count = UInt64(exactly: count) else {
            invalidEvents += 1
            return
        }
        let next = batchedTelemetryCounters[keyPath: keyPath].addingReportingOverflow(count)
        guard !next.overflow else {
            invalidEvents += 1
            return
        }
        batchedTelemetryCounters[keyPath: keyPath] = next.partialValue
    }

    func recordAtomicChartScaleResolution(changed: Bool) {
        guard isEnabled, mode.usesAtomicChartScale else { return }
        atomicChartScaleResolutions += 1
        if changed { atomicChartScaleChanges += 1 }
    }

    func recordAtomicChartScaleCacheHit() {
        guard isEnabled, mode.usesAtomicChartScale else { return }
        atomicChartScaleCacheHits += 1
    }

    /// Absolute history counters are sampled at existing publication/cleanup
    /// boundaries. Reading diagnostics never queries or rebuilds history.
    func completedLaneCachePrepared(
        builds: UInt64, hits: UInt64, visitedRecords: UInt64, entries: Int
    ) {
        guard isEnabled, mode.usesCompletedLaneCache else { return }
        guard let entries = UInt64(exactly: entries), entries <= 20_000,
            builds >= completedLaneCacheBuilds, hits >= completedLaneCacheHits,
            visitedRecords >= completedLaneCacheVisitedRecords
        else {
            invalidEvents += 1
            return
        }
        completedLaneCacheBuilds = builds
        completedLaneCacheHits = hits
        completedLaneCacheVisitedRecords = visitedRecords
        completedLaneCacheEntries = entries
        completedLaneCachePeakEntries = max(completedLaneCachePeakEntries, entries)
    }

    func recordRailGeometryCacheBuild(owner: UUID, entries: Int) {
        guard isEnabled, mode.usesCachedRailGeometry else { return }
        guard updateRailGeometryCacheEntries(owner: owner, count: entries), entries > 0 else {
            return
        }
        let next = railGeometryCacheBuilds.addingReportingOverflow(1)
        guard !next.overflow else {
            invalidEvents += 1
            return
        }
        railGeometryCacheBuilds = next.partialValue
    }

    func recordRailGeometryCacheHit(owner: UUID) {
        guard isEnabled, mode.usesCachedRailGeometry else { return }
        guard railGeometryCacheOwners[owner] != nil else {
            invalidEvents += 1
            return
        }
        let next = railGeometryCacheHits.addingReportingOverflow(1)
        guard !next.overflow else {
            invalidEvents += 1
            return
        }
        railGeometryCacheHits = next.partialValue
    }

    func recordRailGeometryCacheEntries(owner: UUID, _ count: Int) {
        guard isEnabled, mode.usesCachedRailGeometry else { return }
        _ = updateRailGeometryCacheEntries(owner: owner, count: count)
    }

    private func updateRailGeometryCacheEntries(owner: UUID, count: Int) -> Bool {
        guard let entries = UInt64(exactly: count), entries <= 24 else {
            invalidEvents += 1
            return false
        }
        let retained = railGeometryCacheEntries - (railGeometryCacheOwners[owner] ?? 0)
        let next = retained.addingReportingOverflow(entries)
        guard !next.overflow else {
            invalidEvents += 1
            return false
        }
        if entries == 0 {
            railGeometryCacheOwners.removeValue(forKey: owner)
        } else {
            railGeometryCacheOwners[owner] = entries
        }
        railGeometryCacheEntries = next.partialValue
        railGeometryCachePeakEntries = max(railGeometryCachePeakEntries, railGeometryCacheEntries)
        railGeometryCachePeakOwners = max(
            railGeometryCachePeakOwners, UInt64(railGeometryCacheOwners.count))
        return true
    }

    public func snapshot() -> [String: Any] {
        var result: [String: Any] = [
            "enabled": isEnabled, "mode": mode.rawValue,
            "holds_static_chart_drawing": mode.usesHeldStaticChart,
            "metal_full_chart_enabled": isEnabled && mode.usesMetalFullChart,
            "metal_static_cache_enabled": isEnabled && mode.cachesMetalStaticChart,
            "metal_full_chart": metalFullChartCounters.snapshot,
            "metal_primitive_effects_enabled": isEnabled && mode.usesMetalPrimitiveEffects,
            "metal_primitive_effects": metalPrimitiveEffectsCounters.snapshot,
            "batched_telemetry_delivery_enabled": isEnabled && mode.usesBatchedTelemetryDelivery,
            "batched_telemetry": batchedTelemetryCounters.snapshot,
            "atomic_chart_scale_enabled": isEnabled && mode.usesAtomicChartScale,
            "atomic_chart_scale": [
                "resolutions": atomicChartScaleResolutions,
                "scale_changes": atomicChartScaleChanges,
                "cache_hits": atomicChartScaleCacheHits,
            ],
            "completed_lane_cache_enabled": isEnabled && mode.usesCompletedLaneCache,
            "completed_lane_cache": [
                "builds": completedLaneCacheBuilds,
                "hits": completedLaneCacheHits,
                "visited_records": completedLaneCacheVisitedRecords,
                "current_entries": completedLaneCacheEntries,
                "peak_entries": completedLaneCachePeakEntries,
            ],
            "rail_geometry_cache_enabled": isEnabled && mode.usesCachedRailGeometry,
            "rail_geometry_cache": [
                "builds": railGeometryCacheBuilds, "hits": railGeometryCacheHits,
                "current_entries": railGeometryCacheEntries,
                "peak_entries": railGeometryCachePeakEntries,
                "current_caches": UInt64(railGeometryCacheOwners.count),
                "peak_caches": railGeometryCachePeakOwners,
                "max_entries_per_cache": UInt64(24),
            ],
            "rail_geometry_cache_used": railGeometryCacheBuilds > 0,
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
        if isEnabled, mode.usesNativeGPUCanvas || mode.usesMetalFullChart {
            result["native_gpu_backend"] =
                mode.usesMetalFullChart
                ? "metal-persistent-chart"
                : (mode.usesUngroupedNativeCanvas
                    ? "swiftui-canvas" : "swiftui-canvas-drawing-group")
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
            result["deferred_tool_geometry_enabled"] = mode.usesDeferredToolGeometry
            result["chart_publication_interval_seconds"] = mode.chartPublicationIntervalSeconds
            result["metal_arrival_bursts_enabled"] = mode.usesMetalArrivalBursts
            result["arrival_backend"] =
                mode.usesMetalFullChart
                ? "metal-full-chart-shader"
                : (mode.usesMetalPrimitiveEffects
                    ? "metal-primitive-effects"
                    : (mode.usesMetalArrivalBursts ? "metal-shader" : "canvas"))
        }
        if isEnabled, mode.usesRetainedTwinkles {
            result["retained_twinkle_backend"] = "core-animation-shape-layers"
        }
        return result
    }
}
