import Combine
import SwiftUI

/// Selects an opt-in native SwiftUI renderer without changing the normal chart
/// path. Both implementations receive the same drawing closure and crop.
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
        if PerformanceGraphicsDiagnostics.shared.mode == .nativeGPUCanvas {
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

/// Direct on-screen Canvas with a native drawing group. Production code in this
/// path never constructs ImageRenderer, a CGContext, or a CPU bitmap. A live
/// native capture must still establish actual GPU execution; the view structure
/// and its draw counter alone do not measure GPU utilization.
struct NativeGPUChartCanvas: View {
    let role: PerformanceGraphicsDiagnostics.Role
    let revision: AnyHashable?
    let drawingBounds: CGRect?
    let drawing: ChartCanvas.Drawing
    @Environment(\.self) private var environment
    @StateObject private var owner = NativeGPUChartCanvasOwner()

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
        Content(
            role: role, revision: revision, drawingBounds: drawingBounds,
            drawing: drawing, environment: environment,
            drawingEnvironment: DrawingEnvironment(environment), owner: owner,
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
        let environment: EnvironmentValues
        let drawingEnvironment: DrawingEnvironment
        let owner: NativeGPUChartCanvasOwner
        let presentationGeneration: UInt64

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard let revision = lhs.revision else { return false }
            return rhs.revision == revision && lhs.role == rhs.role
                && lhs.drawingBounds == rhs.drawingBounds
                && lhs.drawingEnvironment == rhs.drawingEnvironment
                && lhs.owner === rhs.owner
                && lhs.presentationGeneration == rhs.presentationGeneration
        }

        var body: some View {
            // This is update accounting, not a rendered frame. The only frame
            // counter is inside the real Canvas callback below.
            owner.contentUpdated(role: role)
            return Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) {
                context, size in
                guard
                    owner.beginDraw(
                        role: role, size: size, scale: environment.displayScale,
                        generation: presentationGeneration)
                else {
                    return
                }
                if let drawingBounds {
                    context.translateBy(x: -drawingBounds.minX, y: -drawingBounds.minY)
                }
                drawing(&context, size)
                owner.didDraw(generation: presentationGeneration)
            }
            .environment(\.self, environment)
            .drawingGroup(opaque: false, colorMode: .nonLinear)
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

    init(diagnostics: PerformanceGraphicsDiagnostics = .shared) {
        self.diagnostics = diagnostics
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
