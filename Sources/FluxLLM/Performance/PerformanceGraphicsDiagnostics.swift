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
        case noBlur = "no-blur"
        case cpuGlow = "cpu-glow"
        case noGradients = "no-gradients"
        case noGradientsOrBlur = "no-gradients-or-blur"

        var omitsGradients: Bool {
            self == .noGradients || self == .noGradientsOrBlur
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

    init() {}

    /// Must be selected before native views are created. Keeping live tokens
    /// across a mode change would make lifecycle and backing comparisons false.
    public func enable(mode: Mode = .normal) throws {
        guard canvases.isEmpty else { throw ConfigurationError.liveCanvases }
        reset()
        self.mode = mode
        isEnabled = true
    }

    public func disable() throws {
        guard canvases.isEmpty else { throw ConfigurationError.liveCanvases }
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
        total.destroyed += 1
        total.live -= 1
        total.pixelArea -= canvas.pixelArea
        total.bitmapBytes -= canvas.bitmapBytes
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
        [
            "enabled": isEnabled, "mode": mode.rawValue,
            "invalid_events": invalidEvents,
            "cpu_glow_fallbacks": cpuGlowFallbacks,
            "gradient_substitutions": gradientSubstitutions,
            "live_canvases": total.live, "peak_live_canvases": total.peakLive,
            "live_renderers": total.liveRenderers,
            "peak_live_renderers": total.peakLiveRenderers,
            "current_pixel_area": total.pixelArea, "peak_pixel_area": total.peakPixelArea,
            "current_bitmap_bytes": total.bitmapBytes,
            "peak_bitmap_bytes": total.peakBitmapBytes,
            "roles": Dictionary(
                uniqueKeysWithValues: Role.allCases.map {
                    ($0.rawValue, (roles[$0] ?? Counters()).snapshot)
                }),
        ]
    }
}
