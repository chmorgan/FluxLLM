import Combine
import SwiftUI

/// Uses the native SwiftUI renderer in normal operation while preserving the
/// diagnostic controls. Both paths receive the same drawing closure and crop.
struct ChartDrawingSurface: View {
    let role: PerformanceGraphicsDiagnostics.Role
    let revision: AnyHashable?
    let drawingBounds: CGRect?
    let drawing: ChartCanvas.Drawing

    init(
        role: PerformanceGraphicsDiagnostics.Role = .staticChart,
        revision: AnyHashable? = nil, drawingBounds: CGRect? = nil,
        renderer: @escaping ChartCanvas.Drawing
    ) {
        self.role = role
        self.revision = revision
        self.drawingBounds = drawingBounds
        drawing = renderer
    }

    var body: some View {
        if PerformanceGraphicsDiagnostics.shared.mode.usesNativeGPUCanvas {
            NativeGPUChartCanvas(
                role: role, revision: revision, drawingBounds: drawingBounds,
                renderer: drawing)
        } else {
            ChartCanvas(
                role: role, revision: revision, drawingBounds: drawingBounds,
                renderer: drawing)
        }
    }
}

/// Direct on-screen Canvas, with an optional diagnostic omission of its drawing
/// group. This path never constructs ImageRenderer, a CGContext, or a CPU bitmap. A live
/// native capture must still establish actual GPU execution; the view structure
/// and its draw counter alone do not measure GPU utilization.
struct NativeGPUChartCanvas: View {
    let role: PerformanceGraphicsDiagnostics.Role
    let revision: AnyHashable?
    let drawingBounds: CGRect?
    let drawing: ChartCanvas.Drawing
    let ungrouped: Bool
    @Environment(\.self) private var environment
    @StateObject private var owner = NativeGPUChartCanvasOwner()

    init(
        role: PerformanceGraphicsDiagnostics.Role = .staticChart,
        revision: AnyHashable? = nil, drawingBounds: CGRect? = nil,
        ungrouped: Bool? = nil,
        renderer: @escaping ChartCanvas.Drawing
    ) {
        self.role = role
        self.revision = revision
        self.drawingBounds = drawingBounds
        drawing = renderer
        self.ungrouped =
            ungrouped ?? PerformanceGraphicsDiagnostics.shared.mode.usesUngroupedNativeCanvas
    }

    var body: some View {
        let drawingEnvironment = DrawingEnvironment(environment)
        let prepared = owner.prepareDrawing(
            role: role, revision: revision, drawingBounds: drawingBounds,
            environment: drawingEnvironment, drawing: drawing,
            holdStatic: PerformanceGraphicsDiagnostics.shared.mode.usesHeldStaticChart)
        return Content(
            role: role, revision: prepared.revision, drawingBounds: drawingBounds,
            drawing: drawing, ungrouped: ungrouped, environment: environment,
            drawingEnvironment: drawingEnvironment, owner: owner,
            heldGeneration: prepared.heldGeneration,
            presentationGeneration: owner.presentationGeneration
        )
        .equatable()
    }

    /// The explicit revision covers immutable chart data and custom environment
    /// keys. Common drawing environment changes always invalidate the content,
    /// just as they do in ChartCanvas's existing native view.
    struct DrawingEnvironment: Equatable {
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

    private struct Content: View, @preconcurrency Equatable {
        let role: PerformanceGraphicsDiagnostics.Role
        let revision: AnyHashable?
        let drawingBounds: CGRect?
        let drawing: ChartCanvas.Drawing
        let ungrouped: Bool
        let environment: EnvironmentValues
        let drawingEnvironment: DrawingEnvironment
        let owner: NativeGPUChartCanvasOwner
        let heldGeneration: UInt64?
        let presentationGeneration: UInt64

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard let revision = lhs.revision else { return false }
            return rhs.revision == revision && lhs.role == rhs.role
                && lhs.drawingBounds == rhs.drawingBounds
                && lhs.ungrouped == rhs.ungrouped
                && lhs.drawingEnvironment == rhs.drawingEnvironment
                && lhs.owner === rhs.owner
                && lhs.heldGeneration == rhs.heldGeneration
                && lhs.presentationGeneration == rhs.presentationGeneration
        }

        var body: some View {
            // This is update accounting, not a rendered frame. The only frame
            // counter is inside the real Canvas callback below.
            owner.contentUpdated(role: role)
            let canvas = Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false)
            {
                context, size in
                guard
                    owner.beginDraw(
                        role: role, size: size, scale: environment.displayScale,
                        generation: presentationGeneration)
                else {
                    return
                }
                let renderer: ChartCanvas.Drawing
                if let heldGeneration {
                    guard let retained = owner.heldDrawing(for: size, generation: heldGeneration)
                    else {
                        return
                    }
                    renderer = retained
                } else {
                    renderer = drawing
                }
                if let drawingBounds {
                    context.translateBy(x: -drawingBounds.minX, y: -drawingBounds.minY)
                }
                renderer(&context, size)
                PerformancePresentationCounters.shared.record(
                    ungrouped ? .ungroupedNativeCanvasDraws : .groupedNativeCanvasDraws)
                owner.didDraw(generation: presentationGeneration)
            }
            .environment(\.self, environment)
            return Group {
                if ungrouped {
                    canvas
                } else {
                    canvas.drawingGroup(opaque: false, colorMode: .nonLinear)
                }
            }
            .onAppear { owner.appeared(role: role) }
            .onDisappear { owner.disappeared() }
        }
    }
}

/// Canvas can render before onAppear. After disappearance, stale callbacks must
/// not recreate live tokens; reappearance invalidates once to render fresh pixels.
@MainActor
final class NativeGPUChartCanvasOwner: ObservableObject {
    @Published private(set) var presentationGeneration: UInt64 = 0
    private let diagnostics: PerformanceGraphicsDiagnostics
    private var id: UInt64?
    private var role: PerformanceGraphicsDiagnostics.Role?
    private var hidden = false
    private var stopped = false
    private struct HeldDrawingKey: Equatable {
        let bounds: CGRect?
        let environment: NativeGPUChartCanvas.DrawingEnvironment
    }
    private struct HeldDrawingRevision: Hashable {
        let generation: UInt64
    }
    private let held = HeldStaticChartDrawing<HeldDrawingKey, ChartCanvas.Drawing>()

    struct PreparedDrawing {
        let revision: AnyHashable?
        let heldGeneration: UInt64?
    }

    init(diagnostics: PerformanceGraphicsDiagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    /// This diagnostic holds only the static pixels. The dashboard still
    /// prepares each publication and all animated roles keep their ordinary
    /// updates. The retained payload is never observable and starts at the
    /// first actual draw, after initial layout has supplied usable geometry.
    func prepareDrawing(
        role: PerformanceGraphicsDiagnostics.Role, revision: AnyHashable?,
        drawingBounds: CGRect?, environment: NativeGPUChartCanvas.DrawingEnvironment,
        drawing: @escaping ChartCanvas.Drawing, holdStatic: Bool
    ) -> PreparedDrawing {
        guard !stopped, !hidden, holdStatic, role == .staticChart else {
            held.reset()
            return PreparedDrawing(revision: revision, heldGeneration: nil)
        }
        let request = held.request(
            key: HeldDrawingKey(bounds: drawingBounds, environment: environment), drawing: drawing)
        diagnostics.staticChartDrawingRequested(
            applied: request.applied, reset: request.resetForKey)
        return PreparedDrawing(
            revision: AnyHashable(HeldDrawingRevision(generation: request.generation)),
            heldGeneration: request.generation)
    }

    func heldDrawing(for size: CGSize, generation: UInt64) -> ChartCanvas.Drawing? {
        guard !stopped, !hidden,
            let result = held.drawing(for: size, generation: generation)
        else { return nil }
        if result.resetForSize { diagnostics.staticChartDrawingReset() }
        return result.drawing
    }

    func contentUpdated(role: PerformanceGraphicsDiagnostics.Role) {
        guard !stopped, !hidden else { return }
        if id != nil {
            register(role: role)
            diagnostics.canvasUpdated(id)
        }
    }

    func appeared(role: PerformanceGraphicsDiagnostics.Role) {
        guard !stopped else { return }
        let reappearing = hidden
        hidden = false
        register(role: role)
        if reappearing { presentationGeneration &+= 1 }
    }

    func beginDraw(
        role: PerformanceGraphicsDiagnostics.Role, size: CGSize, scale: CGFloat,
        generation: UInt64 = 0
    ) -> Bool {
        guard !stopped, !hidden, generation == presentationGeneration,
            size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 0, scale.isFinite, scale > 0
        else { return false }
        register(role: role)
        diagnostics.canvasGeometry(
            id, width: Double(size.width), height: Double(size.height),
            scale: Double(scale))
        return true
    }

    func didDraw(generation: UInt64 = 0) {
        guard !stopped, !hidden, generation == presentationGeneration else { return }
        // The method atomically records both the dedicated native draw and its
        // role's ordinary draw count. It never records an ImageRenderer instance.
        diagnostics.nativeGPUCanvasDrawn(id)
    }

    func disappeared() {
        hidden = true
        held.reset()
        releaseRegistration()
    }

    func stop() {
        stopped = true
        disappeared()
    }

    private func register(role: PerformanceGraphicsDiagnostics.Role) {
        if self.role != role { releaseRegistration() }
        guard id == nil else { return }
        self.role = role
        id = diagnostics.canvasCreated(role: role)
        diagnostics.canvasUpdated(id)
    }

    private func releaseRegistration() {
        diagnostics.canvasDestroyed(id)
        id = nil
        role = nil
    }

    deinit {
        let diagnostics = diagnostics
        let id = id
        MainActor.assumeIsolated { diagnostics.canvasDestroyed(id) }
    }
}

/// Bounded storage for the held-static diagnostic. Request payloads remain
/// current so a changed size can safely render current geometry. Equal-key
/// requests keep the first drawn payload until a real drawing dependency
/// changes; no timer, view update, or image allocation is introduced.
@MainActor
final class HeldStaticChartDrawing<Key: Equatable, Drawing> {
    struct RequestResult {
        let generation: UInt64
        let applied: Bool
        let resetForKey: Bool
    }

    struct DrawResult {
        let drawing: Drawing
        let resetForSize: Bool
    }

    private struct Payload {
        let key: Key
        let drawing: Drawing
    }

    private var latest: Payload?
    private var retained: Payload?
    private var drawnSize: CGSize?
    private var generation: UInt64 = 0

    func request(key: Key, drawing: Drawing) -> RequestResult {
        let changedKey = latest.map { $0.key != key } ?? true
        let resetForKey = changedKey && retained != nil
        if changedKey {
            generation &+= 1
            retained = nil
            drawnSize = nil
        }
        latest = Payload(key: key, drawing: drawing)
        return RequestResult(
            generation: generation, applied: retained == nil, resetForKey: resetForKey)
    }

    func drawing(for size: CGSize, generation expected: UInt64) -> DrawResult? {
        guard expected == generation, let latest,
            size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0
        else { return nil }
        let resetForSize = drawnSize.map { $0 != size } ?? false
        if retained == nil || resetForSize {
            retained = latest
            drawnSize = size
        }
        return DrawResult(drawing: retained!.drawing, resetForSize: resetForSize)
    }

    func reset() {
        guard latest != nil || retained != nil else { return }
        latest = nil
        retained = nil
        drawnSize = nil
        generation &+= 1
    }
}
