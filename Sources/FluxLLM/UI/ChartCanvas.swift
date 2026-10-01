import AppKit
import Combine
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

        override var isOpaque: Bool { false }
        // ImageRenderer maps SwiftUI's top-left coordinates into Quartz itself.
        override var isFlipped: Bool { false }

        func update(
            drawing: @escaping Drawing, environment: EnvironmentValues,
            revision: AnyHashable? = nil, drawingBounds: CGRect? = nil,
            role: PerformanceGraphicsDiagnostics.Role = .staticChart
        ) {
            let diagnostics = PerformanceGraphicsDiagnostics.shared
            if diagnosticRole != role {
                diagnostics.canvasDestroyed(diagnosticID)
                diagnosticID = diagnostics.canvasCreated(role: role)
                diagnosticRole = role
                if renderer != nil { diagnostics.rendererCreated(diagnosticID) }
            }
            diagnostics.canvasUpdated(diagnosticID)
            let drawingEnvironment = DrawingEnvironment(environment)
            let mode = diagnostics.mode
            if let revision, self.revision == revision,
                self.drawingEnvironment == drawingEnvironment,
                self.drawingBounds == drawingBounds, self.mode == mode, content != nil
            {
                return
            }
            self.revision = revision
            self.drawingEnvironment = drawingEnvironment
            self.drawingBounds = drawingBounds
            self.mode = mode
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

        override func draw(_ dirtyRect: NSRect) {
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

            let renderer: ImageRenderer<Content>
            if let existing = self.renderer {
                renderer = existing
            } else {
                // Hosting/layout and updates while hidden never create a renderer.
                renderer = ImageRenderer(content: content)
                renderer.isObservationEnabled = true
                self.renderer = renderer
                diagnostics.rendererCreated(diagnosticID)
                rendererObservation = renderer.objectWillChange.sink { [weak self] in
                    // NSView coalesces display invalidations. The weak subscription
                    // also covers observable values read only inside the Canvas.
                    guard let self, !self.isDrawing, self.content != nil else { return }
                    self.needsDisplay = true
                }
            }
            let scale = drawingScale
            let proposedSize = ProposedViewSize(size)
            if renderer.proposedSize != proposedSize { renderer.proposedSize = proposedSize }
            if renderer.scale != scale { renderer.scale = scale }
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
