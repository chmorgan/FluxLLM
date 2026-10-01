import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Keeps Canvas drawing semantics while rendering through Core Graphics. A native
/// on-screen Canvas initializes a much larger renderer than these small charts need.
struct ChartCanvas: NSViewRepresentable {
    typealias Drawing = (inout GraphicsContext, CGSize) -> Void

    let drawing: Drawing
    let role: PerformanceGraphicsDiagnostics.Role
    let revision: AnyHashable?
    /// Crop in the original chart coordinate system. The caller sizes and
    /// positions the native view to this rect; drawing keeps its original origin.
    let drawingBounds: CGRect?

    init(
        role: PerformanceGraphicsDiagnostics.Role = .staticChart,
        revision: AnyHashable? = nil, drawingBounds: CGRect? = nil,
        renderer: @escaping Drawing
    ) {
        self.role = role
        self.revision = revision
        self.drawingBounds = drawingBounds
        drawing = renderer
    }

    func makeNSView(context: Context) -> DrawingView {
        let view = DrawingView(frame: .zero)
        view.update(
            drawing: drawing, environment: context.environment, revision: revision,
            drawingBounds: drawingBounds, role: role)
        return view
    }

    func updateNSView(_ view: DrawingView, context: Context) {
        view.update(
            drawing: drawing, environment: context.environment, revision: revision,
            drawingBounds: drawingBounds, role: role)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DrawingView, context: Context)
        -> CGSize?
    {
        // Canvas expands to the proposed size and has a small ideal size when an
        // axis is unspecified. No content rendering is needed to answer layout.
        let size = proposal.replacingUnspecifiedDimensions()
        guard size.width.isFinite, size.height.isFinite else { return nil }
        return CGSize(width: max(0, size.width), height: max(0, size.height))
    }

    static func dismantleNSView(_ view: DrawingView, coordinator: ()) {
        view.clearContent()
    }

    private struct Content: View {
        let drawing: Drawing
        let environment: EnvironmentValues
        let drawingBounds: CGRect?
        let empty: Bool

        var body: some View {
            Canvas { context, size in
                guard !empty else { return }
                if let drawingBounds {
                    context.translateBy(x: -drawingBounds.minX, y: -drawingBounds.minY)
                }
                drawing(&context, size)
            }
            .environment(\.self, environment)
        }
    }

    /// The caller's revision covers immutable chart data and custom environment
    /// dependencies. Common drawing environment changes always invalidate it.
    private struct DrawingEnvironment: Equatable {
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
        let scale: CGFloat
        let reduceMotion: Bool
        let reduceTransparency: Bool
        let differentiateWithoutColor: Bool
        let invertColors: Bool
        let layoutDirection: LayoutDirection
        let locale: Locale
        let timeZone: TimeZone
        let calendar: Calendar
        let dynamicTypeSize: DynamicTypeSize
        let font: Font?
        let legibilityWeight: LegibilityWeight?

        init(_ environment: EnvironmentValues) {
            colorScheme = environment.colorScheme
            contrast = environment.colorSchemeContrast
            scale = environment.displayScale
            reduceMotion = environment.accessibilityReduceMotion
            reduceTransparency = environment.accessibilityReduceTransparency
            differentiateWithoutColor = environment.accessibilityDifferentiateWithoutColor
            invertColors = environment.accessibilityInvertColors
            layoutDirection = environment.layoutDirection
            locale = environment.locale
            timeZone = environment.timeZone
            calendar = environment.calendar
            dynamicTypeSize = environment.dynamicTypeSize
            font = environment.font
            legibilityWeight = environment.legibilityWeight
        }
    }

    /// A single CPU drawing buffer is admitted only after all arithmetic is
    /// checked. The retained CGImage may share this storage; Core Animation can
    /// also retain earlier images until its transactions retire.
    struct BitmapLayout: Equatable {
        static let maximumBytes = 32 * 1_024 * 1_024
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let byteCount: Int

        static func make(size: CGSize, scale: CGFloat) -> Self? {
            guard size.width.isFinite, size.height.isFinite, scale.isFinite,
                size.width > 0, size.height > 0, scale > 0,
                let width = Int(exactly: ceil(size.width * scale)),
                let height = Int(exactly: ceil(size.height * scale)),
                width > 0, height > 0
            else { return nil }
            let row = width.multipliedReportingOverflow(by: 4)
            guard !row.overflow else { return nil }
            let total = row.partialValue.multipliedReportingOverflow(by: height)
            guard !total.overflow, total.partialValue <= maximumBytes else { return nil }
            return Self(
                width: width, height: height,
                bytesPerRow: row.partialValue, byteCount: total.partialValue)
        }
    }

    @MainActor
    class DrawingView: NSView {
        private var content: Content?
        private var renderer: ImageRenderer<Content>?
        private var rendererObservation: AnyCancellable?
        private var isDrawing = false
        private var revision: AnyHashable?
        private var drawingEnvironment: DrawingEnvironment?
        private var drawingBounds: CGRect?
        private var diagnosticID: UInt64?
        private var diagnosticRole: PerformanceGraphicsDiagnostics.Role?
        private var mode: PerformanceGraphicsDiagnostics.Mode = .normal

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // AppKit manages this transparent backing, including clearing it
            // when a previously drawn cursor or effect disappears.
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        required init?(coder: NSCoder) { return nil }

        override var wantsUpdateLayer: Bool { mode == .bitmapLayerDestination }
        override var isOpaque: Bool { false }
        // ImageRenderer maps SwiftUI's top-left coordinates into Quartz itself.
        override var isFlipped: Bool { false }

        func update(
            drawing: @escaping Drawing, environment: EnvironmentValues,
            revision: AnyHashable? = nil, drawingBounds: CGRect? = nil,
            role: PerformanceGraphicsDiagnostics.Role = .staticChart
        ) {
            let diagnostics = PerformanceGraphicsDiagnostics.shared
            let roleChanged = diagnosticRole != role
            if roleChanged {
                clearLayerBitmap()
                diagnostics.canvasDestroyed(diagnosticID)
                diagnosticID = diagnostics.canvasCreated(role: role)
                diagnosticRole = role
                if renderer != nil { diagnostics.rendererCreated(diagnosticID) }
            }
            diagnostics.canvasUpdated(diagnosticID)
            let drawingEnvironment = DrawingEnvironment(environment)
            let mode = diagnostics.mode
            if !roleChanged, let revision, self.revision == revision,
                self.drawingEnvironment == drawingEnvironment,
                self.drawingBounds == drawingBounds, self.mode == mode, content != nil
            {
                return
            }
            self.revision = revision
            self.drawingEnvironment = drawingEnvironment
            self.drawingBounds = drawingBounds
            self.mode = mode
            if mode == .bitmapLayerDestination {
                // Keep AppKit from flattening this view into an ancestor's
                // native drawing context: this mode supplies finished pixels.
                canDrawSubviewsIntoLayer = false
            }
            let content = Content(
                drawing: drawing, environment: environment,
                drawingBounds: drawingBounds, empty: mode == .emptyDrawing)
            self.content = content
            if let renderer {
                renderer.content = content
                diagnostics.rendererUpdated(diagnosticID)
            }
            recordGeometry()
            needsDisplay = true
        }

        func clearContent() {
            clearLayerBitmap()
            rendererObservation?.cancel()
            rendererObservation = nil
            if renderer != nil {
                PerformanceGraphicsDiagnostics.shared.rendererDestroyed(diagnosticID)
            }
            renderer = nil
            content = nil
            revision = nil
            drawingEnvironment = nil
            PerformanceGraphicsDiagnostics.shared.canvasDestroyed(diagnosticID)
            diagnosticID = nil
            diagnosticRole = nil
            needsDisplay = true
        }

        deinit {
            // NSView ownership is main-thread confined, including dismantling.
            // This fallback also covers an owner releasing an unattached view.
            let id = diagnosticID
            MainActor.assumeIsolated {
                PerformanceGraphicsDiagnostics.shared.canvasDestroyed(id)
            }
        }

        private var drawingScale: CGFloat {
            let requested = window?.backingScaleFactor ?? content?.environment.displayScale ?? 1
            return requested.isFinite && requested > 0 ? requested : 1
        }

        private func recordGeometry() {
            PerformanceGraphicsDiagnostics.shared.canvasGeometry(
                diagnosticID, width: Double(bounds.width), height: Double(bounds.height),
                scale: Double(drawingScale))
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed {
                if mode == .bitmapLayerDestination,
                    newSize.width <= 0 || newSize.height <= 0
                {
                    clearLayerBitmap()
                }
                recordGeometry()
                needsDisplay = true
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            recordGeometry()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            recordGeometry()
            needsDisplay = true
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            drawingEnvironment = nil
            needsDisplay = true
        }

        /// Build the producer only when a real draw is requested. Both
        /// destinations retain the same observation and revision semantics.
        private func drawingRenderer(for content: Content, size: CGSize, scale: CGFloat)
            -> ImageRenderer<Content>
        {
            let renderer: ImageRenderer<Content>
            if let existing = self.renderer {
                renderer = existing
            } else {
                renderer = ImageRenderer(content: content)
                renderer.isObservationEnabled = true
                self.renderer = renderer
                PerformanceGraphicsDiagnostics.shared.rendererCreated(diagnosticID)
                rendererObservation = renderer.objectWillChange.sink { [weak self] in
                    guard let self, !self.isDrawing, self.content != nil else { return }
                    self.needsDisplay = true
                }
            }
            let proposedSize = ProposedViewSize(size)
            if renderer.proposedSize != proposedSize { renderer.proposedSize = proposedSize }
            if renderer.scale != scale { renderer.scale = scale }
            return renderer
        }

        private func clearLayerBitmap() {
            guard mode == .bitmapLayerDestination else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = nil
            CATransaction.commit()
            PerformanceGraphicsDiagnostics.shared.layerBitmapCleared(diagnosticID)
        }

        override func updateLayer() {
            guard mode == .bitmapLayerDestination else { return }
            let diagnostics = PerformanceGraphicsDiagnostics.shared
            let size = bounds.size
            guard let content, size.width != 0, size.height != 0
            else {
                clearLayerBitmap()
                return
            }
            let scale = drawingScale
            guard let layer,
                let layout = BitmapLayout.make(size: size, scale: scale),
                let bitmap = CGContext(
                    data: nil, width: layout.width, height: layout.height,
                    bitsPerComponent: 8, bytesPerRow: layout.bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue)
            else {
                diagnostics.recordLayerBitmapFailure()
                clearLayerBitmap()
                return
            }
            recordGeometry()
            diagnostics.bitmapBytes(diagnosticID, bytes: UInt64(layout.byteCount))
            defer { diagnostics.bitmapBytes(diagnosticID, bytes: 0) }
            isDrawing = true
            defer { isDrawing = false }
            let renderer = drawingRenderer(for: content, size: size, scale: scale)
            bitmap.clear(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
            bitmap.scaleBy(x: scale, y: scale)
            var rendered = false
            renderer.render(rasterizationScale: scale) { _, render in
                render(bitmap)
                rendered = true
            }
            guard rendered, let image = bitmap.makeImage() else {
                diagnostics.recordLayerBitmapFailure()
                clearLayerBitmap()
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = scale
            // Integral pixel buffers can extend by less than one pixel past a
            // fractional view size. Anchor rather than stretch the image, and
            // clip that extra right/top edge to preserve chart coordinates.
            layer.contentsGravity = .bottomLeft
            layer.masksToBounds = true
            layer.contents = image
            CATransaction.commit()
            diagnostics.layerBitmapPresented(diagnosticID, imageBytes: UInt64(layout.byteCount))
            diagnostics.canvasDrawn(diagnosticID)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard mode != .bitmapLayerDestination else {
                // A native fallback would invalidate the destination experiment.
                PerformanceGraphicsDiagnostics.shared.recordLayerBitmapNativeDraw()
                clearLayerBitmap()
                return
            }
            let size = bounds.size
            guard size.width.isFinite, size.height.isFinite,
                size.width > 0, size.height > 0,
                let graphics = NSGraphicsContext.current
            else { return }
            let context = graphics.cgContext
            context.saveGState()
            defer { context.restoreGState() }
            // AppKit clears the native backing before drawing. Never clear this
            // destination: capture and printing may share it with sibling views.
            guard let content else { return }
            let diagnostics = PerformanceGraphicsDiagnostics.shared
            recordGeometry()
            guard mode != .noRenderer else {
                diagnostics.drawSkipped(diagnosticID)
                return
            }
            isDrawing = true
            defer { isDrawing = false }

            let scale = drawingScale
            let renderer = drawingRenderer(for: content, size: size, scale: scale)
            context.translateBy(x: bounds.minX, y: bounds.minY)
            if mode == .bitmapDestination {
                // Diagnostic-only destination A/B: preserve the producer and
                // native destination, inserting one bounded temporary bitmap.
                let width = ceil(size.width * scale)
                let height = ceil(size.height * scale)
                guard width > 0, height > 0, width <= 16_384, height <= 16_384,
                    width * height * 4 <= 32 * 1_024 * 1_024,
                    let bitmap = CGContext(
                        data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                        bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                            | CGBitmapInfo.byteOrder32Big.rawValue)
                else {
                    diagnostics.drawSkipped(diagnosticID)
                    return
                }
                diagnostics.bitmapBytes(diagnosticID, bytes: UInt64(width * height * 4))
                defer { diagnostics.bitmapBytes(diagnosticID, bytes: 0) }
                bitmap.clear(CGRect(x: 0, y: 0, width: width, height: height))
                bitmap.scaleBy(x: scale, y: scale)
                renderer.render(rasterizationScale: scale) { _, render in render(bitmap) }
                if let image = bitmap.makeImage() {
                    context.draw(
                        image, in: CGRect(x: 0, y: 0, width: width / scale, height: height / scale))
                }
            } else {
                renderer.render(rasterizationScale: scale) { _, render in render(context) }
            }
            diagnostics.canvasDrawn(diagnosticID)
        }
    }
}
