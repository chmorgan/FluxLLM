import AppKit
import Observation
import QuartzCore
import SwiftUI

/// An isolated, opt-in drawing experiment. Backends share the native window,
/// geometry, colors, and frame requests; the explicitly named unhosted control
/// removes only the hosting view. No app model, telemetry store, popover, or
/// production dashboard is constructed.
@MainActor
public final class DrawingProbeSession {
    enum Backend: String, CaseIterable {
        case imageRenderer = "image-renderer"
        case canvas
        case coreGraphics = "core-graphics"
        case coreGraphicsUnhosted = "core-graphics-unhosted"
        case bitmapLayer = "bitmap-layer"
    }

    enum Primitive: String, CaseIterable {
        case empty, line, text
        case solidFill = "solid-fill"
        case linearGradient = "linear-gradient"
        case radialGradient = "radial-gradient"
        case clippedLine = "clipped-line"
        case layerLine = "layer-line"
        case withCGLine = "with-cg-line"
        case chartPath = "chart-path"
    }

    public enum ProbeError: Error, CustomStringConvertible {
        case invalidBackend(String)
        case invalidPrimitive(String)
        case invalidLifecycle
        case invalidFrameCount
        case windowNotVisible
        case drawTimedOut
        case drawingResourcesStillLive
        case bitmapFailure(String)

        public var description: String {
            switch self {
            case .invalidBackend(let value): return "Unknown drawing backend: \(value)"
            case .invalidPrimitive(let value): return "Unknown drawing primitive: \(value)"
            case .invalidLifecycle: return "Drawing probe command is out of lifecycle order"
            case .invalidFrameCount: return "Drawing probe frames must be between 1 and 300"
            case .windowNotVisible: return "Drawing probe window is not visibly onscreen"
            case .drawTimedOut:
                return "Drawing probe did not execute the requested drawing callback"
            case .drawingResourcesStillLive:
                return "Drawing probe retained native drawing resources after close"
            case .bitmapFailure(let reason): return "Drawing probe bitmap path failed: \(reason)"
            }
        }
    }

    static let contentSize = CGSize(width: 664, height: 357)
    let backend: Backend
    let primitive: Primitive
    private let state = DrawingProbeState()
    private var window: NSWindow?
    private var host: NSHostingView<DrawingProbeRoot>?
    private var unhostedView: DrawingProbeCGView?
    private weak var releasedWindow: NSWindow?
    private weak var releasedHost: NSHostingView<DrawingProbeRoot>?
    private weak var releasedContentView: NSView?
    private var started = false
    private var closed = false
    private var lastWindowNumber = -1
    private var lastBackingScale: CGFloat = 0
    private var lastContentSize = DrawingProbeSession.contentSize

    public init(backend: String, primitive: String) throws {
        guard let selectedBackend = Backend(rawValue: backend) else {
            throw ProbeError.invalidBackend(backend)
        }
        guard let selectedPrimitive = Primitive(rawValue: primitive) else {
            throw ProbeError.invalidPrimitive(primitive)
        }
        self.backend = selectedBackend
        self.primitive = selectedPrimitive
    }

    /// Waits for the empty/gated renderer to actually draw in a visible window.
    /// Its allocations are deliberately included in the before-drawing sample.
    public func start() async throws {
        guard !started, !closed else { throw ProbeError.invalidLifecycle }
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .normal)
        started = true
        openWindow()
        do {
            try await waitUntilVisible()
            try await waitForDraw(revision: 0)
            lastContentSize = window?.contentView?.bounds.size ?? Self.contentSize
        } catch {
            try? await close()
            throw error
        }
    }

    // Locals must leave scope before asynchronous failure cleanup verifies
    // weak release of the native window and its content.
    private func openWindow() {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "FluxLLM Drawing Probe"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        window.isOpaque = true
        let contentFrame = CGRect(origin: .zero, size: Self.contentSize)
        if backend == .coreGraphicsUnhosted {
            let view = DrawingProbeCGView(frame: contentFrame)
            view.primitive = primitive
            view.state = state
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            unhostedView = view
        } else {
            let host = NSHostingView(
                rootView: DrawingProbeRoot(
                    backend: backend, primitive: primitive, state: state))
            host.frame = contentFrame
            window.contentView = host
            self.host = host
        }
        window.setContentSize(Self.contentSize)
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        lastWindowNumber = window.windowNumber
        lastBackingScale = window.backingScaleFactor
    }

    public func drawOnce() async throws {
        guard started, !closed, !state.enabled else { throw ProbeError.invalidLifecycle }
        try requireVisibility()
        state.enabled = true
        try await requestFrame()
    }

    /// Repeats identical geometry while explicitly invalidating each backend.
    /// Frame requests run at most 30 Hz; each must receive a real draw callback.
    public func redraw(count: Int) async throws {
        guard started, !closed, state.enabled else { throw ProbeError.invalidLifecycle }
        guard (1...300).contains(count) else { throw ProbeError.invalidFrameCount }
        let clock = ContinuousClock()
        var nextFrame = clock.now
        for _ in 0..<count {
            try await clock.sleep(until: nextFrame, tolerance: .milliseconds(1))
            try requireVisibility()
            let frameStarted = clock.now
            try await requestFrame()
            nextFrame = frameStarted.advanced(by: .nanoseconds(33_333_334))
        }
    }

    public func close() async throws {
        guard !closed else { return }
        closed = true
        guard started else { return }
        state.enabled = false
        releasedWindow = window
        releasedHost = host
        releasedContentView = window?.contentView
        unhostedView?.enabled = false
        unhostedView?.state = nil
        window?.orderOut(nil)
        window?.contentView = nil
        host = nil
        unhostedView = nil
        window?.close()
        window = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            let counters = PerformanceGraphicsDiagnostics.shared.snapshot()
            guard let liveCanvases = counters["live_canvases"] as? UInt64,
                let liveRenderers = counters["live_renderers"] as? UInt64
            else { throw ProbeError.drawingResourcesStillLive }
            if liveCanvases == 0, liveRenderers == 0,
                releasedWindow == nil, releasedHost == nil, releasedContentView == nil,
                state.bitmapScratchBytes == 0, state.bitmapImageBytes == 0
            {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        throw ProbeError.drawingResourcesStillLive
    }

    public func snapshot() -> [String: Any] {
        [
            "schema_version": 1,
            "backend": backend.rawValue,
            "primitive": primitive.rawValue,
            "uses_swiftui_host": backend != .coreGraphicsUnhosted,
            "window_visible": isWindowVisible,
            "window_number": window?.windowNumber ?? lastWindowNumber,
            "draw_enabled": state.enabled,
            "draw_calls": state.drawCalls,
            "nonempty_draw_calls": state.nonemptyDrawCalls,
            "requested_frames": state.requestedFrames,
            "revision": state.revision,
            "acknowledged_revision": state.acknowledgedRevision,
            "acknowledged_frames": state.acknowledgedFrames,
            "duplicate_draw_calls": state.duplicateDrawCalls,
            "content_width_points": window?.contentView?.bounds.width ?? lastContentSize.width,
            "content_height_points": window?.contentView?.bounds.height ?? lastContentSize.height,
            "backing_scale": window?.backingScaleFactor ?? lastBackingScale,
            "graphics_diagnostics": PerformanceGraphicsDiagnostics.shared.snapshot(),
            "started": started,
            "closed": closed,
            "released_window_live": releasedWindow != nil,
            "released_host_live": releasedHost != nil,
            "released_content_live": releasedContentView != nil,
            "bitmap_update_layer_calls": state.bitmapUpdateLayerCalls,
            "bitmap_unexpected_native_draw_calls": state.bitmapUnexpectedDrawCalls,
            "bitmap_failures": state.bitmapFailures,
            "bitmap_current_requested_scratch_bytes": state.bitmapScratchBytes,
            "bitmap_peak_requested_scratch_bytes": state.bitmapPeakScratchBytes,
            "bitmap_current_requested_image_bytes": state.bitmapImageBytes,
            "bitmap_peak_requested_image_bytes": state.bitmapPeakImageBytes,
            "bitmap_images_created": state.bitmapImagesCreated,
            "bitmap_storage_caveat":
                "Requested CPU bitmap and current layer image sizes, not actual graphics memory; Core Animation may retain earlier images until transactions retire",
            "text_comparison":
                "SwiftUI Text versus AppKit attributed-text drawing; identical string, system font size, color, and top-left anchor; glyph rasterization may differ",
        ]
    }

    private var isWindowVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
    }

    private func requireVisibility() throws {
        guard isWindowVisible else { throw ProbeError.windowNotVisible }
    }

    private func waitUntilVisible() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !isWindowVisible {
            guard ContinuousClock.now < deadline else { throw ProbeError.windowNotVisible }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func requestFrame() async throws {
        state.requestedFrames += 1
        state.revision += 1
        if let unhostedView {
            unhostedView.enabled = state.enabled
            unhostedView.revision = state.revision
            unhostedView.needsDisplay = true
        }
        try await waitForDraw(revision: state.revision)
    }

    private func waitForDraw(revision: UInt64) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while state.acknowledgedRevision < Int64(revision) {
            if let error = state.bitmapError { throw ProbeError.bitmapFailure(error) }
            try requireVisibility()
            guard ContinuousClock.now < deadline else { throw ProbeError.drawTimedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
        if let error = state.bitmapError { throw ProbeError.bitmapFailure(error) }
        try requireVisibility()
    }
}

@MainActor
@Observable
final class DrawingProbeState {
    var enabled = false
    var revision: UInt64 = 0
    @ObservationIgnored var drawCalls: UInt64 = 0
    @ObservationIgnored var nonemptyDrawCalls: UInt64 = 0
    @ObservationIgnored var requestedFrames: UInt64 = 0
    @ObservationIgnored var acknowledgedRevision: Int64 = -1
    @ObservationIgnored var acknowledgedFrames: UInt64 = 0
    @ObservationIgnored var duplicateDrawCalls: UInt64 = 0
    @ObservationIgnored var bitmapUpdateLayerCalls: UInt64 = 0
    @ObservationIgnored var bitmapUnexpectedDrawCalls: UInt64 = 0
    @ObservationIgnored var bitmapFailures: UInt64 = 0
    @ObservationIgnored var bitmapError: String?
    @ObservationIgnored var bitmapScratchBytes: UInt64 = 0
    @ObservationIgnored var bitmapPeakScratchBytes: UInt64 = 0
    @ObservationIgnored var bitmapImageBytes: UInt64 = 0
    @ObservationIgnored var bitmapPeakImageBytes: UInt64 = 0
    @ObservationIgnored var bitmapImagesCreated: UInt64 = 0

    func didDraw(revision: UInt64, nonempty: Bool) {
        drawCalls += 1
        if nonempty { nonemptyDrawCalls += 1 }
        if Int64(revision) <= acknowledgedRevision {
            duplicateDrawCalls += 1
        } else {
            acknowledgedRevision = Int64(revision)
            if revision > 0 { acknowledgedFrames += 1 }
        }
    }
}

private struct DrawingProbeRoot: View {
    let backend: DrawingProbeSession.Backend
    let primitive: DrawingProbeSession.Primitive
    let state: DrawingProbeState

    var body: some View {
        let enabled = state.enabled
        let revision = state.revision
        let drawing: ChartCanvas.Drawing = { context, _ in
            if enabled { DrawingProbeArtwork.draw(primitive, in: &context) }
            state.didDraw(revision: revision, nonempty: enabled && primitive != .empty)
        }
        Group {
            switch backend {
            case .imageRenderer:
                ChartCanvas(revision: AnyHashable(revision), renderer: drawing)
            case .canvas:
                Canvas(opaque: false, rendersAsynchronously: false, renderer: drawing)
            case .coreGraphics, .coreGraphicsUnhosted:
                DrawingProbeCGCanvas(
                    primitive: primitive, enabled: enabled, revision: revision, state: state)
            case .bitmapLayer:
                DrawingProbeBitmapCanvas(
                    primitive: primitive, enabled: enabled, revision: revision, state: state)
            }
        }
        .frame(
            width: DrawingProbeSession.contentSize.width,
            height: DrawingProbeSession.contentSize.height
        )
        .environment(\.colorScheme, .light)
    }
}

private struct DrawingProbeCGCanvas: NSViewRepresentable {
    let primitive: DrawingProbeSession.Primitive
    let enabled: Bool
    let revision: UInt64
    let state: DrawingProbeState

    func makeNSView(context: Context) -> DrawingProbeCGView {
        let view = DrawingProbeCGView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DrawingProbeCGView, context: Context) {
        view.primitive = primitive
        view.enabled = enabled
        view.revision = revision
        view.state = state
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: DrawingProbeCGView, coordinator: ()) {
        view.state = nil
    }
}

@MainActor
final class DrawingProbeCGView: NSView {
    var primitive: DrawingProbeSession.Primitive = .empty
    var enabled = false
    var revision: UInt64 = 0
    var state: DrawingProbeState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if enabled { DrawingProbeArtwork.draw(primitive, in: context) }
        state?.didDraw(revision: revision, nonempty: enabled && primitive != .empty)
    }
}

private struct DrawingProbeBitmapCanvas: NSViewRepresentable {
    let primitive: DrawingProbeSession.Primitive
    let enabled: Bool
    let revision: UInt64
    let state: DrawingProbeState

    func makeNSView(context: Context) -> DrawingProbeBitmapView {
        let view = DrawingProbeBitmapView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DrawingProbeBitmapView, context: Context) {
        view.primitive = primitive
        view.enabled = enabled
        view.revision = revision
        view.state = state
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: DrawingProbeBitmapView, coordinator: ()) {
        view.clearContent()
    }
}

/// This backend supplies finished pixels to Core Animation. Drawing the image
/// into AppKit's native CGContext would reintroduce the destination under test.
@MainActor
final class DrawingProbeBitmapView: NSView {
    var primitive: DrawingProbeSession.Primitive = .empty
    var enabled = false
    var revision: UInt64 = 0
    var state: DrawingProbeState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        canDrawSubviewsIntoLayer = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        let state = state
        MainActor.assumeIsolated {
            state?.bitmapImageBytes = 0
            state?.bitmapScratchBytes = 0
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func updateLayer() {
        guard let state else { return }
        state.bitmapUpdateLayerCalls += 1
        guard let layer else {
            recordFailure("AppKit did not provide the bitmap destination layer")
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard enabled else {
            layer.contents = nil
            state.bitmapImageBytes = 0
            state.didDraw(revision: revision, nonempty: false)
            return
        }
        do {
            let scale = window?.backingScaleFactor ?? 1
            let layout = try DrawingProbeBitmap.layout(size: bounds.size, scale: scale)
            state.bitmapScratchBytes = UInt64(layout.byteCount)
            state.bitmapPeakScratchBytes = max(
                state.bitmapPeakScratchBytes, state.bitmapScratchBytes)
            defer { state.bitmapScratchBytes = 0 }
            let image = try DrawingProbeBitmap.render(
                primitive: primitive, size: bounds.size, scale: scale, layout: layout)
            layer.contentsScale = scale
            layer.contentsGravity = .resize
            layer.contents = image
            state.bitmapImageBytes = UInt64(layout.byteCount)
            state.bitmapPeakImageBytes = max(state.bitmapPeakImageBytes, state.bitmapImageBytes)
            state.bitmapImagesCreated += 1
            state.didDraw(revision: revision, nonempty: primitive != .empty)
        } catch {
            recordFailure(String(describing: error))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // This experiment must not silently fall back to native CGContext work.
        state?.bitmapUnexpectedDrawCalls += 1
        recordFailure("AppKit used draw(_:) instead of updateLayer()")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    func clearContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = nil
        CATransaction.commit()
        state?.bitmapImageBytes = 0
        state?.bitmapScratchBytes = 0
        state = nil
    }

    private func recordFailure(_ description: String) {
        state?.bitmapFailures += 1
        state?.bitmapError = description
    }
}

@MainActor
enum DrawingProbeBitmap {
    static let maximumBytes = 32 * 1_024 * 1_024

    struct Layout: Equatable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let byteCount: Int
    }

    enum BitmapError: Error {
        case invalidGeometry
        case exceedsLimit
        case allocationFailed
        case imageCreationFailed
    }

    static func layout(size: CGSize, scale: CGFloat) throws -> Layout {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
            size.width > 0, size.height > 0, scale > 0,
            size.width <= DrawingProbeSession.contentSize.width,
            size.height <= DrawingProbeSession.contentSize.height,
            let width = Int(exactly: ceil(size.width * scale)),
            let height = Int(exactly: ceil(size.height * scale)),
            width > 0, height > 0
        else { throw BitmapError.invalidGeometry }
        let row = width.multipliedReportingOverflow(by: 4)
        guard !row.overflow else { throw BitmapError.exceedsLimit }
        let total = row.partialValue.multipliedReportingOverflow(by: height)
        guard !total.overflow, total.partialValue <= maximumBytes else {
            throw BitmapError.exceedsLimit
        }
        return Layout(
            width: width, height: height,
            bytesPerRow: row.partialValue, byteCount: total.partialValue)
    }

    static func render(
        primitive: DrawingProbeSession.Primitive, size: CGSize, scale: CGFloat,
        layout: Layout
    ) throws -> CGImage {
        // Revalidate so an unchecked caller cannot bypass the allocation cap.
        guard layout == (try self.layout(size: size, scale: scale)) else {
            throw BitmapError.invalidGeometry
        }
        guard
            let context = CGContext(
                data: nil, width: layout.width, height: layout.height,
                bitsPerComponent: 8, bytesPerRow: layout.bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw BitmapError.allocationFailed }
        context.clear(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        DrawingProbeArtwork.draw(primitive, in: context)
        guard let image = context.makeImage() else { throw BitmapError.imageCreationFailed }
        return image
    }
}

/// Frozen top-left geometry shared by SwiftUI and Core Graphics. These are
/// individual operation probes, not a second implementation of the chart.
@MainActor
enum DrawingProbeArtwork {
    static let color = Color(red: 0.10, green: 0.42, blue: 0.82)
    static let cgColor = CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0.10, 0.42, 0.82, 1])!
    static let fillBounds = CGRect(x: 32, y: 24, width: 600, height: 309)
    static let clipBounds = CGRect(x: 180, y: 60, width: 240, height: 180)
    static let line: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 32, y: 72))
        path.addLine(to: CGPoint(x: 632, y: 285))
        return path.copy()!
    }()
    static let chartPath: CGPath = {
        let path = CGMutablePath()
        for index in 0..<256 {
            let t = Double(index) / 255
            let point = CGPoint(
                x: 32 + 600 * t,
                y: 180 + 90 * sin(t * 4 * .pi) + 28 * sin(t * 13 * .pi))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path.copy()!
    }()

    static func draw(_ primitive: DrawingProbeSession.Primitive, in context: inout GraphicsContext)
    {
        switch primitive {
        case .empty: break
        case .line, .chartPath:
            context.stroke(
                Path(primitive == .line ? line : chartPath), with: .color(color), lineWidth: 3)
        case .solidFill:
            context.fill(Path(fillBounds), with: .color(color))
        case .linearGradient:
            context.fill(
                Path(fillBounds),
                with: .linearGradient(
                    Gradient(colors: [color, color.opacity(0)]),
                    startPoint: CGPoint(x: 32, y: 24), endPoint: CGPoint(x: 632, y: 333)))
        case .radialGradient:
            context.fill(
                Path(fillBounds),
                with: .radialGradient(
                    Gradient(colors: [color, color.opacity(0)]),
                    center: CGPoint(x: 332, y: 178), startRadius: 0, endRadius: 150))
        case .text:
            context.draw(
                Text("FluxLLM Requests 123 Tokens 4567")
                    .font(.system(size: 16)).foregroundColor(color),
                at: CGPoint(x: 32, y: 72), anchor: .topLeading)
        case .clippedLine:
            context.clip(to: Path(clipBounds))
            context.stroke(Path(line), with: .color(color), lineWidth: 3)
        case .layerLine:
            context.drawLayer { layer in
                layer.stroke(Path(line), with: .color(color), lineWidth: 3)
            }
        case .withCGLine:
            context.withCGContext { drawLine(in: $0) }
        }
    }

    static func draw(_ primitive: DrawingProbeSession.Primitive, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        switch primitive {
        case .empty: break
        case .line, .withCGLine:
            drawLine(in: context)
        case .chartPath:
            context.setStrokeColor(cgColor)
            context.setLineWidth(3)
            context.addPath(chartPath)
            context.strokePath()
        case .solidFill:
            context.setFillColor(cgColor)
            context.fill(fillBounds)
        case .linearGradient, .radialGradient:
            context.clip(to: fillBounds)
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [cgColor, cgColor.copy(alpha: 0)!] as CFArray,
                locations: [0, 1])!
            if primitive == .linearGradient {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 32, y: 24), end: CGPoint(x: 632, y: 333),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else {
                context.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: 332, y: 178), startRadius: 0,
                    endCenter: CGPoint(x: 332, y: 178), endRadius: 150,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        case .text:
            // NSAttributedString uses the native font engine. The same nominal
            // string/font/position is compared, not promised pixel equivalence.
            let text = NSAttributedString(
                string: "FluxLLM Requests 123 Tokens 4567",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: NSColor(cgColor: cgColor)!,
                ])
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            defer { NSGraphicsContext.current = previous }
            text.draw(at: CGPoint(x: 32, y: 72))
        case .clippedLine:
            context.clip(to: clipBounds)
            drawLine(in: context)
        case .layerLine:
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawLine(in: context)
            context.endTransparencyLayer()
        }
    }

    static func drawLine(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(cgColor)
        context.setLineWidth(3)
        context.addPath(line)
        context.strokePath()
    }
}
