import Foundation

/// Bounded, optional counters for the production rendering path. Requested
/// canvas backing and drawing callbacks are not measured GPU memory or time.
@MainActor
public final class PerformanceGraphicsDiagnostics {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case normal
    }

    public enum Role: String, CaseIterable, Sendable {
        case staticChart = "static_chart"
        case cursor
        case railBars = "rail_bars"
        case railDecorations = "rail_decorations"
    }

    public enum ConfigurationError: Error {
        case liveCanvases
        case liveScalarPresentations
    }

    enum ScalarLeaf: String, CaseIterable, Sendable {
        case header, metrics, details
        case cardFooter = "card_footer"
        case appFooter = "app_footer"
    }

    final class LayoutCounters: @unchecked Sendable {
        struct Snapshot: Sendable {
            var sizeCalls: UInt64 = 0
            var placeCalls: UInt64 = 0
            var childMeasurements: UInt64 = 0
            var invalidEvents: UInt64 = 0
        }

        private let lock = NSLock()
        private var enabled = false
        private var counters = Snapshot()

        func recordSize() {
            record(\.sizeCalls, by: 1)
        }

        func recordPlace() {
            record(\.placeCalls, by: 1)
        }

        func recordChildMeasurements(_ count: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard enabled else { return }
            guard let count = UInt64(exactly: count) else {
                recordInvalidEvent()
                return
            }
            increment(\.childMeasurements, by: count)
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return counters
        }

        fileprivate func reset(enabled: Bool) {
            lock.lock()
            defer { lock.unlock() }
            self.enabled = enabled
            counters = Snapshot()
        }

        private func record(_ field: WritableKeyPath<Snapshot, UInt64>, by amount: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            guard enabled else { return }
            increment(field, by: amount)
        }

        // The caller owns the lock for both additions and invalid events.
        private func increment(_ field: WritableKeyPath<Snapshot, UInt64>, by amount: UInt64) {
            let next = counters[keyPath: field].addingReportingOverflow(amount)
            guard !next.overflow else {
                recordInvalidEvent()
                return
            }
            counters[keyPath: field] = next.partialValue
        }

        private func recordInvalidEvent() {
            if counters.invalidEvents < UInt64.max { counters.invalidEvents += 1 }
        }
    }

    static let maximumScalarPresentationOwners = 2
    static let maximumScalarFrameAnchors = 16
    public static let shared = PerformanceGraphicsDiagnostics()
    public private(set) var mode: Mode = .normal
    public private(set) var isEnabled = false

    private struct Canvas {
        let role: Role
        var pixelArea: UInt64 = 0
        var currentWidth: Double = 0
        var currentHeight: Double = 0
        var currentScale: Double = 0
        var scalarStaticDraws: UInt64 = 0
    }

    private struct ScalarPresentationOwner {
        var role: String? = nil
        var frames: [String: CGRect] = [:]
        var leafBodyUpdates: [ScalarLeaf: UInt64] = [:]
        var presentedValues: [String: [String: Any]] = [:]
    }

    private var scalarLeafBodyUpdates: [ScalarLeaf: UInt64] = [:]
    private var scalarPresentationOwners: [UUID: ScalarPresentationOwner] = [:]
    private var dashboardLayoutCounters: LayoutCounters?
    private var scalarInstrumentationEnabled: Bool { isEnabled }
    var layoutCountersForPresentation: LayoutCounters? {
        isEnabled ? dashboardLayoutCounters : nil
    }

    private struct Counters {
        var created: UInt64 = 0
        var destroyed: UInt64 = 0
        var live: UInt64 = 0
        var peakLive: UInt64 = 0
        var updates: UInt64 = 0
        var draws: UInt64 = 0
        var skippedDraws: UInt64 = 0
        var pixelArea: UInt64 = 0
        var peakPixelArea: UInt64 = 0
        var maxWidth: Double = 0
        var maxHeight: Double = 0
        var maxScale: Double = 0

        var snapshot: [String: Any] {
            [
                "created": created, "destroyed": destroyed,
                "live": live, "peak_live": peakLive, "updates": updates,
                "renderer_creations": UInt64(0),
                "renderer_updates": UInt64(0),
                "renderer_destructions": UInt64(0),
                "live_renderers": UInt64(0), "peak_live_renderers": UInt64(0),
                "draws": draws, "skipped_draws": skippedDraws,
                "drawing_update_attempts": UInt64(0),
                "drawing_updates_applied": UInt64(0),
                "drawing_updates_held": UInt64(0),
                "drawing_hold_resets": UInt64(0),
                "current_pixel_area": pixelArea, "peak_pixel_area": peakPixelArea,
                "current_bitmap_bytes": UInt64(0), "peak_bitmap_bytes": UInt64(0),
                "current_layer_image_bytes": UInt64(0),
                "peak_layer_image_bytes": UInt64(0),
                "max_width_points": maxWidth, "max_height_points": maxHeight,
                "max_scale": maxScale,
            ]
        }
    }

    private var nextID: UInt64 = 0
    private var canvases: [UInt64: Canvas] = [:]
    private var roles: [Role: Counters] = [:]
    private var total = Counters()
    private var invalidEvents: UInt64 = 0
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

    /// Enabling and resetting must happen outside live view lifetimes.
    public func enable(mode: Mode = .normal) throws {
        try requireNoLiveOwners()
        reset()
        self.mode = mode
        isEnabled = true
        let counters = LayoutCounters()
        counters.reset(enabled: true)
        dashboardLayoutCounters = counters
    }

    public func disable() throws {
        try requireNoLiveOwners()
        reset()
        isEnabled = false
    }

    private func requireNoLiveOwners() throws {
        guard canvases.isEmpty, twinkleHosts.isEmpty else { throw ConfigurationError.liveCanvases }
        guard scalarPresentationOwners.isEmpty else {
            throw ConfigurationError.liveScalarPresentations
        }
    }

    private func reset() {
        roles = Dictionary(uniqueKeysWithValues: Role.allCases.map { ($0, Counters()) })
        total = Counters()
        invalidEvents = 0
        nativeGPUCanvasDraws = 0
        scalarPresentationPublications = 0
        twinkleCounters = TwinkleCounters()
        scalarLeafBodyUpdates.removeAll(keepingCapacity: false)
        scalarPresentationOwners.removeAll(keepingCapacity: false)
        dashboardLayoutCounters?.reset(enabled: false)
        dashboardLayoutCounters = nil
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
        roles[canvas.role]!.destroyed += 1
        roles[canvas.role]!.live -= 1
        roles[canvas.role]!.pixelArea -= canvas.pixelArea
        total.destroyed += 1
        total.live -= 1
        total.pixelArea -= canvas.pixelArea
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
        if scalarInstrumentationEnabled {
            canvases[id]!.currentWidth = width
            canvases[id]!.currentHeight = height
            canvases[id]!.currentScale = scale
        }
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

    public func canvasUpdated(_ id: UInt64?) {
        guard let (_, canvas) = registered(id) else { return }
        roles[canvas.role]!.updates += 1
    }

    public func canvasDrawn(_ id: UInt64?) {
        guard let (_, canvas) = registered(id) else { return }
        roles[canvas.role]!.draws += 1
    }

    public func nativeGPUCanvasDrawn(_ id: UInt64?) {
        guard isEnabled,
            let (id, canvas) = registered(id)
        else { return }
        let next = nativeGPUCanvasDraws.addingReportingOverflow(1)
        let nextRole = roles[canvas.role]!.draws.addingReportingOverflow(1)
        let observesStatic = scalarInstrumentationEnabled && canvas.role == .staticChart
        let nextCanvas = canvas.scalarStaticDraws.addingReportingOverflow(observesStatic ? 1 : 0)
        guard !next.overflow, !nextRole.overflow, !nextCanvas.overflow else {
            invalidEvents += 1
            return
        }
        nativeGPUCanvasDraws = next.partialValue
        roles[canvas.role]!.draws = nextRole.partialValue
        if observesStatic { canvases[id]!.scalarStaticDraws = nextCanvas.partialValue }
    }

    func retainedTwinkleHostCreated() -> UInt64? {
        guard isEnabled else { return nil }
        nextID += 1
        twinkleHosts[nextID] = []
        twinkleCounters.hostsCreated += 1
        twinkleCounters.peakHosts = max(twinkleCounters.peakHosts, twinkleCounters.liveHosts)
        return nextID
    }

    func scalarPresentationPublished() {
        guard isEnabled else { return }
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
        guard isEnabled, let id else { return }
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
        guard isEnabled, let id else { return }
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

    private func registered(_ id: UInt64?) -> (UInt64, Canvas)? {
        guard isEnabled, let id else { return nil }
        guard let canvas = canvases[id] else {
            invalidEvents += 1
            return nil
        }
        return (id, canvas)
    }

    func recordScalarLeafBody(_ leaf: ScalarLeaf, owner: UUID) {
        guard scalarInstrumentationEnabled else { return }
        guard
            scalarPresentationOwners[owner] != nil
                || scalarPresentationOwners.count < Self.maximumScalarPresentationOwners
        else {
            invalidEvents += 1
            return
        }
        let total = scalarLeafBodyUpdates[leaf, default: 0].addingReportingOverflow(1)
        let previous = scalarPresentationOwners[owner]?.leafBodyUpdates[leaf] ?? 0
        let local = previous.addingReportingOverflow(1)
        guard !total.overflow, !local.overflow else {
            invalidEvents += 1
            return
        }
        var receipt = scalarPresentationOwners[owner] ?? ScalarPresentationOwner()
        receipt.leafBodyUpdates[leaf] = local.partialValue
        scalarPresentationOwners[owner] = receipt
        scalarLeafBodyUpdates[leaf] = total.partialValue
    }

    func recordScalarPresentedValues(
        _ leaf: ScalarLeaf, owner: UUID, compact: Bool, values: [String: Any]
    ) {
        guard scalarInstrumentationEnabled else { return }
        guard var receipt = scalarPresentationOwners[owner] else {
            invalidEvents += 1
            return
        }
        let key: String
        let expected: Set<String>
        switch leaf {
        case .header:
            key = "header"
            expected = ["status", "model", "activity"]
        case .metrics:
            key = "metrics"
            expected = ["rate", "gpu"]
        case .details where compact:
            key = "compact_details"
            expected = ["response"]
        case .details:
            key = "dashboard_usage"
            expected = ["scope", "values"]
        default:
            invalidEvents += 1
            return
        }
        let valid: Bool
        if key == "dashboard_usage" {
            let countKeys: Set<String> = [
                "unknown_input_requests", "output_tokens", "tool_calls", "requests",
                "active_requests",
            ]
            if let scope = values["scope"] as? String, UsageScope(rawValue: scope) != nil,
                let usage = values["values"] as? [String: Any],
                Set(usage.keys)
                    == countKeys.union(["input_tokens", "output_is_estimated", "is_partial"])
            {
                valid =
                    countKeys.allSatisfy { (usage[$0] as? Int).map { $0 >= 0 } ?? false }
                    && (usage["input_tokens"] is NSNull
                        || (usage["input_tokens"] as? Int).map { $0 >= 0 } == true)
                    && usage["output_is_estimated"] is Bool && usage["is_partial"] is Bool
            } else {
                valid = false
            }
        } else {
            valid = values.values.allSatisfy({ value in
                if let text = value as? String { return text.utf8.count <= 4096 }
                return key == "header" && value is NSNull
            })
        }
        guard Set(values.keys) == expected, valid
        else {
            invalidEvents += 1
            return
        }
        receipt.presentedValues[key] = values
        scalarPresentationOwners[owner] = receipt
    }

    func recordDashboardLayoutSize() {
        dashboardLayoutCounters?.recordSize()
    }

    func recordDashboardLayoutPlace() {
        dashboardLayoutCounters?.recordPlace()
    }

    func recordDashboardLayoutChildMeasurements(_ count: Int) {
        dashboardLayoutCounters?.recordChildMeasurements(count)
    }

    @discardableResult
    func performanceScalarFramesUpdated(owner: UUID, role: String, frames: [String: CGRect]) -> Bool
    {
        guard scalarInstrumentationEnabled else { return false }
        guard validScalarRole(role), validScalarFrames(frames),
            scalarPresentationOwners[owner] != nil
                || scalarPresentationOwners.count < Self.maximumScalarPresentationOwners,
            !scalarPresentationOwners.contains(where: { $0.key != owner && $0.value.role == role }),
            scalarPresentationOwners[owner]?.role.map({ $0 == role }) ?? true
        else {
            invalidEvents += 1
            return false
        }
        var receipt = scalarPresentationOwners[owner] ?? ScalarPresentationOwner()
        receipt.role = role
        receipt.frames = frames
        scalarPresentationOwners[owner] = receipt
        return true
    }

    private func validScalarRole(_ role: String) -> Bool {
        role == "dashboard" || role == "popover"
    }

    private func validScalarFrames(_ frames: [String: CGRect]) -> Bool {
        !frames.isEmpty && frames.count <= Self.maximumScalarFrameAnchors
            && frames.allSatisfy { name, rect in
                !name.isEmpty && name.utf8.count <= 64
                    && rect.origin.x.isFinite && rect.origin.y.isFinite
                    && rect.size.width.isFinite && rect.size.height.isFinite
                    && rect.maxX.isFinite && rect.maxY.isFinite
                    && rect.size.width > 0 && rect.size.height > 0
            }
    }

    private func scalarFramesSnapshot(_ frames: [String: CGRect]) -> [String: [String: Double]] {
        frames.mapValues { rect in
            [
                "x": Double(rect.origin.x), "y": Double(rect.origin.y),
                "width": Double(rect.size.width), "height": Double(rect.size.height),
            ]
        }
    }

    private func scalarLeavesSnapshot(_ counts: [ScalarLeaf: UInt64]) -> [String: UInt64] {
        Dictionary(
            uniqueKeysWithValues: ScalarLeaf.allCases.map { ($0.rawValue, counts[$0, default: 0]) })
    }

    func performanceScalarPresentationReleased(owner: UUID) {
        guard isEnabled else { return }
        scalarPresentationOwners.removeValue(forKey: owner)
    }

    private func scalarPresentationSnapshot(layout: LayoutCounters.Snapshot) -> [String: Any] {
        let live = Dictionary(
            uniqueKeysWithValues: scalarPresentationOwners.map { id, receipt in
                (
                    id.uuidString,
                    [
                        "role": receipt.role as Any? ?? NSNull(),
                        "current_frames": scalarFramesSnapshot(receipt.frames),
                        "leaf_body_updates": scalarLeavesSnapshot(receipt.leafBodyUpdates),
                        "presented_values": receipt.presentedValues,
                    ] as [String: Any]
                )
            })
        return [
            "leaf_body_updates": scalarLeavesSnapshot(scalarLeafBodyUpdates),
            "layout_size_calls": layout.sizeCalls, "layout_place_calls": layout.placeCalls,
            "layout_child_measurements": layout.childMeasurements,
            "freezes_captured": UInt64(0), "freezes_released": UInt64(0),
            "current_frozen_owners": UInt64(0), "peak_frozen_owners": UInt64(0),
            "frozen_owners": [String: Any](), "presentation_owners": live,
        ]
    }

    /// Historical readers expect these inventories. Removed mechanisms are
    /// explicitly absent; zero work does not substitute for CPU/GPU measurements.
    private static func zeroCounters(_ names: [String]) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, 0) })
    }

    public func snapshot() -> [String: Any] {
        let layout = dashboardLayoutCounters?.snapshot() ?? LayoutCounters.Snapshot()
        let invalid = invalidEvents.addingReportingOverflow(layout.invalidEvents)
        var result: [String: Any] = [
            "enabled": isEnabled, "mode": mode.rawValue,
            "frozen_scalar_presentation_enabled": false,
            "scalar_instrumentation_enabled": scalarInstrumentationEnabled,
            "scalar_presentation": scalarPresentationSnapshot(layout: layout),
            "held_usage_enabled": false,
            "held_usage": [
                "enabled": false, "monitoring_epoch": NSNull(),
                "captures": UInt64(0), "releases": UInt64(0), "current_owners": UInt64(0),
                "peak_owners": UInt64(0), "owners": [String: Any](),
            ] as [String: Any],
            "retained_usage_fields": false,
            "retained_usage": (["enabled": false, "owners": [String: Any]()] as [String: Any])
                .merging(
                    Self.zeroCounters([
                        "hosts_created", "hosts_destroyed", "current_owners", "peak_owners",
                        "value_apply_attempts", "value_applies", "value_apply_skips",
                    ]).mapValues { $0 as Any },
                    uniquingKeysWith: { _, new in new }),
            "native_canvas_frames": scalarInstrumentationEnabled
                ? Dictionary(
                    uniqueKeysWithValues: canvases.filter { $0.value.role == .staticChart }.map {
                        id, canvas in
                        (
                            String(id),
                            [
                                "role": canvas.role.rawValue, "width": canvas.currentWidth,
                                "height": canvas.currentHeight, "scale": canvas.currentScale,
                            ] as [String: Any]
                        )
                    }) : [:],
            "native_canvas_draws": scalarInstrumentationEnabled
                ? Dictionary(
                    uniqueKeysWithValues: canvases.filter { $0.value.role == .staticChart }.map {
                        (String($0.key), $0.value.scalarStaticDraws)
                    }) : [:],
            "holds_static_chart_drawing": false,
            "metal_full_chart_enabled": false,
            "metal_static_cache_enabled": false,
            "metal_full_chart": Self.zeroCounters([
                "hosts_created", "hosts_destroyed", "live_hosts", "peak_hosts", "geometry_uploads",
                "submissions", "failures", "frames_skipped", "static_frames", "arrival_frames",
                "completion_frames", "twinkle_frames", "current_buffer_bytes", "peak_buffer_bytes",
                "static_rasterizations", "static_cache_composites", "effect_clock_ticks",
                "current_texture_bytes", "peak_texture_bytes", "static_scene_revisions",
                "scene_initial_revisions", "scene_publication_revisions", "scene_scale_revisions",
                "scene_layout_revisions", "scene_appearance_revisions", "scene_rail_revisions",
                "scene_unclassified_revisions", "static_surface_invalidations",
            ]),
            "metal_primitive_effects_enabled": false,
            "metal_primitive_effects": Self.zeroCounters([
                "hosts_created", "hosts_destroyed", "live_hosts", "peak_hosts",
                "descriptor_uploads", "submissions", "clears", "arrival_frames",
                "completion_frames", "twinkle_frames", "frames_skipped", "failures", "fallbacks",
                "current_buffer_bytes", "peak_buffer_bytes",
            ]),
            "batched_telemetry_delivery_enabled": false,
            "batched_telemetry": Self.zeroCounters([
                "compact_states_enqueued", "snapshots_materialized", "batches_applied",
                "events_applied", "projection_refreshes",
            ]),
            "atomic_chart_scale_enabled": false,
            "atomic_chart_scale": [
                "resolutions": UInt64(0),
                "scale_changes": UInt64(0),
                "cache_hits": UInt64(0),
            ],
            "completed_lane_cache_enabled": false,
            "completed_lane_cache": [
                "builds": UInt64(0),
                "hits": UInt64(0),
                "visited_records": UInt64(0),
                "current_entries": UInt64(0),
                "peak_entries": UInt64(0),
            ],
            "rail_geometry_cache_enabled": false,
            "rail_geometry_cache": [
                "builds": UInt64(0), "hits": UInt64(0),
                "current_entries": UInt64(0),
                "peak_entries": UInt64(0),
                "current_caches": UInt64(0),
                "peak_caches": UInt64(0),
                "max_entries_per_cache": UInt64(24),
            ],
            "rail_geometry_cache_used": false,
            "invalid_events": invalid.overflow ? UInt64.max : invalid.partialValue,
            "cpu_glow_fallbacks": UInt64(0),
            "gradient_substitutions": UInt64(0),
            "layer_bitmap_presentations": UInt64(0),
            "layer_bitmap_failures": UInt64(0),
            "layer_bitmap_native_draws": UInt64(0),
            "native_gpu_canvas_draws": nativeGPUCanvasDraws,
            "scalar_presentation_publications": scalarPresentationPublications,
            "retained_twinkles": twinkleCounters.snapshot,
            "live_canvases": total.live, "peak_live_canvases": total.peakLive,
            "live_renderers": UInt64(0),
            "peak_live_renderers": UInt64(0),
            "current_pixel_area": total.pixelArea, "peak_pixel_area": total.peakPixelArea,
            "current_bitmap_bytes": UInt64(0),
            "peak_bitmap_bytes": UInt64(0),
            "current_layer_image_bytes": UInt64(0),
            "peak_layer_image_bytes": UInt64(0),
            "roles": Dictionary(
                uniqueKeysWithValues: Role.allCases.map {
                    ($0.rawValue, (roles[$0] ?? Counters()).snapshot)
                }),
        ]
        if isEnabled {
            result["native_gpu_backend"] = "swiftui-canvas-drawing-group"
            result["scalar_presentation_coalesced"] = true
            result["retained_twinkles_enabled"] = true
            result["incremental_history_ordering"] = true
            result["optimized_chart_preparation"] = true
            result["lifecycle_effects_enabled"] = true
            result["shared_chart_preparation"] = false
            result["stable_decoration_hosts"] = false
            result["unpromised_stream_body_writes"] = true
            result["canvas_frame_clock"] = true
            result["ordered_chart_publication"] = true
            result["direct_tool_plot"] = false
            result["ungrouped_native_canvas"] = false
            result["arrival_effects_enabled"] = true
            result["compact_tool_paths_enabled"] = false
            result["deferred_tool_geometry_enabled"] = false
            result["chart_publication_interval_seconds"] = TimeInterval(1)
            result["metal_arrival_bursts_enabled"] = false
            result["arrival_backend"] = "canvas"
        }
        if isEnabled {
            result["retained_twinkle_backend"] = "core-animation-shape-layers"
        }
        return result
    }
}
