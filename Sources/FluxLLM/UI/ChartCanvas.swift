import AppKit
import Combine
import SwiftUI

/// Keeps Canvas drawing semantics while rendering through Core Graphics. A native
/// on-screen Canvas initializes a much larger renderer than these small charts need.
struct ChartCanvas: NSViewRepresentable {
    typealias Drawing = (inout GraphicsContext, CGSize) -> Void

    let drawing: Drawing

    init(renderer: @escaping Drawing) {
        drawing = renderer
    }

    func makeNSView(context: Context) -> DrawingView {
        let view = DrawingView(frame: .zero)
        view.update(drawing: drawing, environment: context.environment)
        return view
    }

    func updateNSView(_ view: DrawingView, context: Context) {
        view.update(drawing: drawing, environment: context.environment)
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

        var body: some View {
            Canvas(renderer: drawing)
                .environment(\.self, environment)
        }
    }

    @MainActor
    class DrawingView: NSView {
        private var content: Content?
        private var renderer: ImageRenderer<Content>?
        private var rendererObservation: AnyCancellable?
        private var isDrawing = false

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

        func update(drawing: @escaping Drawing, environment: EnvironmentValues) {
            let content = Content(drawing: drawing, environment: environment)
            self.content = content
            renderer?.content = content
            needsDisplay = true
        }

        func clearContent() {
            rendererObservation?.cancel()
            rendererObservation = nil
            renderer = nil
            content = nil
            needsDisplay = true
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed { needsDisplay = true }
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
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
                rendererObservation = renderer.objectWillChange.sink { [weak self] in
                    // NSView coalesces display invalidations. The weak subscription
                    // also covers observable values read only inside the Canvas.
                    guard let self, !self.isDrawing, self.content != nil else { return }
                    self.needsDisplay = true
                }
            }
            let requestedScale = window?.backingScaleFactor ?? content.environment.displayScale
            let scale = requestedScale.isFinite && requestedScale > 0 ? requestedScale : 1
            let proposedSize = ProposedViewSize(size)
            if renderer.proposedSize != proposedSize { renderer.proposedSize = proposedSize }
            if renderer.scale != scale { renderer.scale = scale }
            context.translateBy(x: bounds.minX, y: bounds.minY)
            renderer.render(rasterizationScale: scale) { _, render in
                render(context)
            }
        }
    }
}
