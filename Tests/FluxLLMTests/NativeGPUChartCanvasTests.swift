import AppKit
import Observation
import SwiftUI
import XCTest

@testable import FluxLLM

/// These offscreen ImageRenderer checks establish drawing fidelity and
/// invalidation only. They are not evidence of live on-screen GPU execution.
@MainActor
final class NativeGPUChartCanvasTests: XCTestCase {
    func testDefaultSurfaceDrawsWithNormalModeAndDiagnosticsDisabled() throws {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        XCTAssertFalse(diagnostics.isEnabled)
        XCTAssertEqual(diagnostics.mode, .normal)
        XCTAssertTrue(diagnostics.mode.usesNativeGPUCanvas)
        let initial = diagnostics.snapshot() as NSDictionary
        let size = CGSize(width: 120, height: 80)
        for scale in [CGFloat(1), 2] {
            var environment = EnvironmentValues()
            environment.displayScale = scale
            environment.colorScheme = .dark
            var drawingCalls = 0
            let actual = try render(
                ChartDrawingSurface { context, size in
                    drawingCalls += 1
                    self.artwork(&context, size)
                }.environment(\.self, environment), size: size, scale: scale)
            let expected = try render(
                Canvas(renderer: artwork).environment(\.self, environment), size: size, scale: scale
            )
            XCTAssertGreaterThan(
                drawingCalls, 0, "The production surface must draw without a diagnostic token")
            XCTAssertGreaterThan(bytes(actual).filter { $0 > 0 }.count, 500)
            assertPixels(actual, match: expected)
        }
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
    }

    func testDirectCanvasPreservesPathsGradientBlurTextOrientationAndTransparency() throws {
        let size = CGSize(width: 120, height: 80)
        for scale in [CGFloat(1), 2] {
            var environment = EnvironmentValues()
            environment.displayScale = scale
            environment.colorScheme = .dark
            let actual = try render(
                NativeGPUChartCanvas(renderer: artwork).environment(\.self, environment),
                size: size, scale: scale)
            let expected = try render(
                Canvas(renderer: artwork).environment(\.self, environment), size: size, scale: scale
            )
            assertPixels(actual, match: expected)
            XCTAssertGreaterThan(bytes(actual).filter { $0 > 0 }.count, 500)
            let pixels = bytes(actual)
            let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
            XCTAssertTrue(
                alpha.contains(0), "The drawing group must preserve transparent surroundings")
            XCTAssertTrue(alpha.contains { $0 > 0 && $0 < 255 })
        }
    }

    func testCroppedNativeSurfaceRecomposesWithTheSameChartOrigin() throws {
        let size = CGSize(width: 90, height: 60)
        let crop = CGRect(x: 20, y: 15, width: 50, height: 35)
        let drawing: ChartCanvas.Drawing = { context, _ in
            context.fill(Path(CGRect(x: 25, y: 20, width: 8, height: 6)), with: .color(.red))
            context.fill(
                Path(ellipseIn: CGRect(x: 43, y: 31, width: 14, height: 14)),
                with: .radialGradient(
                    Gradient(colors: [.cyan, .cyan.opacity(0)]),
                    center: CGPoint(x: 50, y: 38), startRadius: 0, endRadius: 7))
        }
        for scale in [CGFloat(1), 2] {
            var environment = EnvironmentValues()
            environment.displayScale = scale
            let cropped = try render(
                NativeGPUChartCanvas(drawingBounds: crop, renderer: drawing)
                    .environment(\.self, environment), size: crop.size, scale: scale)
            let actual = try bitmap(size: size, scale: scale)
            actual.draw(
                try XCTUnwrap(cropped.makeImage()),
                in: CGRect(
                    x: crop.minX, y: size.height - crop.maxY, width: crop.width, height: crop.height
                ))
            let expected = try render(
                Canvas(renderer: drawing).environment(\.self, environment), size: size, scale: scale
            )
            assertPixels(actual, match: expected)
        }
    }

    func testStableRevisionRetainsDrawingAndChangedRevisionReplacesPixels() throws {
        let size = CGSize(width: 20, height: 12)
        let first = NativeGPUChartCanvas(revision: AnyHashable(1), renderer: solid(.red))
        let renderer = ImageRenderer(content: first)
        renderer.isObservationEnabled = true
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1
        let original = try render(renderer, size: size, scale: 1)
        renderer.content = NativeGPUChartCanvas(revision: AnyHashable(1), renderer: solid(.blue))
        let unchanged = try render(renderer, size: size, scale: 1)
        assertPixels(unchanged, match: original)
        renderer.content = NativeGPUChartCanvas(revision: AnyHashable(2), renderer: solid(.blue))
        let changed = try render(renderer, size: size, scale: 1)
        XCTAssertNotEqual(bytes(changed), bytes(original))
        let expected = try render(Canvas(renderer: solid(.blue)), size: size, scale: 1)
        assertPixels(changed, match: expected)
    }

    func testUnversionedDrawingAndCropChangesInvalidateContent() throws {
        let size = CGSize(width: 30, height: 20)
        let drawing: ChartCanvas.Drawing = { context, _ in
            context.fill(Path(CGRect(x: 12, y: 10, width: 6, height: 4)), with: .color(.white))
        }
        let renderer = ImageRenderer(
            content: NativeGPUChartCanvas(
                revision: AnyHashable(1), drawingBounds: CGRect(origin: .zero, size: size),
                renderer: drawing))
        renderer.proposedSize = ProposedViewSize(size)
        let first = try render(renderer, size: size, scale: 1)
        renderer.content = NativeGPUChartCanvas(
            revision: AnyHashable(1),
            drawingBounds: CGRect(origin: CGPoint(x: 5, y: 3), size: size), renderer: drawing)
        let cropped = try render(renderer, size: size, scale: 1)
        XCTAssertNotEqual(bytes(cropped), bytes(first))
        renderer.content = NativeGPUChartCanvas(renderer: solid(.red))
        let red = try render(renderer, size: size, scale: 1)
        renderer.content = NativeGPUChartCanvas(renderer: solid(.blue))
        let blue = try render(renderer, size: size, scale: 1)
        XCTAssertNotEqual(bytes(red), bytes(blue))
    }

    func testEnvironmentChangesReachPixelsWithAStableRevision() throws {
        let size = CGSize(width: 20, height: 12)
        var environment = EnvironmentValues()
        environment.displayScale = 1
        environment.colorScheme = .light
        var observed: EnvironmentValues?
        let drawing: ChartCanvas.Drawing = { context, size in
            observed = context.environment
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary))
        }
        let renderer = ImageRenderer(
            content: NativeGPUChartCanvas(
                revision: AnyHashable(1), renderer: drawing
            ).environment(\.self, environment))
        renderer.proposedSize = ProposedViewSize(size)
        let light = try render(renderer, size: size, scale: 1)
        environment.colorScheme = .dark
        environment.locale = Locale(identifier: "fr_FR")
        environment.layoutDirection = .rightToLeft
        renderer.content = NativeGPUChartCanvas(revision: AnyHashable(1), renderer: drawing)
            .environment(\.self, environment)
        let dark = try render(renderer, size: size, scale: 1)
        XCTAssertNotEqual(bytes(light), bytes(dark))
        XCTAssertEqual(observed?.colorScheme, .dark)
        XCTAssertEqual(observed?.locale.identifier, "fr_FR")
        XCTAssertEqual(observed?.layoutDirection, .rightToLeft)
    }

    func testObservedValuesInsideCanvasStillInvalidateAnUnchangedRevision() throws {
        let state = NativeGPUObservedState()
        let size = CGSize(width: 20, height: 12)
        let renderer = ImageRenderer(
            content: NativeGPUChartCanvas(revision: AnyHashable(1)) { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(state.highlighted ? .white : .black))
            })
        renderer.isObservationEnabled = true
        renderer.proposedSize = ProposedViewSize(size)
        let first = try render(renderer, size: size, scale: 1)
        state.highlighted = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let next = try render(renderer, size: size, scale: 1)
        XCTAssertNotEqual(bytes(first), bytes(next))
    }

    func testFrameClockChangesOnlyDrawingAndClearsWithoutReplayingStoppedTicks() throws {
        let clock = RequestRailFrameClock()
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let generation = clock.start(at: origin, monotonicTime: 0)
        defer { clock.stop() }
        let size = CGSize(width: 20, height: 12)
        var contentUpdates = 0
        var drawingCalls = 0
        func surface(isDrawing: Bool) -> NativeGPUFrameClockTestSurface {
            NativeGPUFrameClockTestSurface(
                clock: clock, origin: origin, isDrawing: isDrawing,
                contentUpdated: { contentUpdates += 1 },
                didDraw: { drawingCalls += 1 })
        }
        let renderer = ImageRenderer(content: surface(isDrawing: true))
        renderer.isObservationEnabled = true
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1
        let first = try render(renderer, size: size, scale: 1)
        let initialContentUpdates = contentUpdates
        XCTAssertGreaterThan(initialContentUpdates, 0)
        XCTAssertGreaterThan(drawingCalls, 0)

        XCTAssertTrue(
            clock.tick(
                generation: generation, at: origin.addingTimeInterval(0.5), monotonicTime: 0.5))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let next = try render(renderer, size: size, scale: 1)
        XCTAssertNotEqual(bytes(first), bytes(next))
        let expected = try render(Canvas(renderer: solid(.blue)), size: size, scale: 1)
        assertPixels(next, match: expected)
        XCTAssertEqual(
            contentUpdates, initialContentUpdates,
            "Reading the clock only inside Canvas must not rebuild its enclosing content")

        renderer.content = surface(isDrawing: false)
        clock.stop()
        let cleared = try render(renderer, size: size, scale: 1)
        XCTAssertTrue(bytes(cleared).allSatisfy { $0 == 0 })
        let callsAfterClear = drawingCalls
        let updatesAfterClear = contentUpdates
        XCTAssertFalse(
            clock.tick(generation: generation, at: origin.addingTimeInterval(1), monotonicTime: 1))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(drawingCalls, callsAfterClear)
        XCTAssertEqual(contentUpdates, updatesAfterClear)
    }

    func testOwnerDrawsAndReappearsWithoutDiagnosticRegistration() {
        let diagnostics = PerformanceGraphicsDiagnostics()
        XCTAssertFalse(diagnostics.isEnabled)
        XCTAssertEqual(diagnostics.mode, .normal)
        XCTAssertTrue(diagnostics.mode.usesNativeGPUCanvas)
        let initial = diagnostics.snapshot() as NSDictionary
        let owner = NativeGPUChartCanvasOwner(diagnostics: diagnostics)
        let size = CGSize(width: 20, height: 12)

        owner.contentUpdated(role: .staticChart)
        XCTAssertTrue(owner.beginDraw(role: .staticChart, size: size, scale: 2))
        owner.didDraw()
        owner.appeared(role: .staticChart)
        XCTAssertEqual(owner.presentationGeneration, 0)
        owner.disappeared()
        XCTAssertFalse(owner.beginDraw(role: .staticChart, size: size, scale: 2))
        owner.didDraw()

        owner.appeared(role: .staticChart)
        XCTAssertEqual(owner.presentationGeneration, 1)
        XCTAssertFalse(owner.beginDraw(role: .staticChart, size: size, scale: 2, generation: 0))
        owner.didDraw(generation: 0)
        XCTAssertTrue(owner.beginDraw(role: .staticChart, size: size, scale: 2, generation: 1))
        owner.didDraw(generation: 1)
        owner.contentUpdated(role: .cursor)
        XCTAssertTrue(owner.beginDraw(role: .cursor, size: size, scale: 1, generation: 1))
        owner.didDraw(generation: 1)

        owner.stop()
        owner.appeared(role: .staticChart)
        XCTAssertFalse(owner.beginDraw(role: .staticChart, size: size, scale: 2, generation: 1))
        owner.didDraw(generation: 1)
        XCTAssertEqual(
            diagnostics.snapshot() as NSDictionary, initial,
            "Rendering and visibility must work while diagnostic accounting remains disabled")
    }

    func testOwnerAccountsEarlyDrawVisibilityReappearanceRoleChangesAndFinalRelease() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .nativeGPUCanvas)
        let owner = NativeGPUChartCanvasOwner(diagnostics: diagnostics)
        let size = CGSize(width: 20, height: 12)
        owner.contentUpdated(role: .staticChart)
        XCTAssertEqual(counter("live_canvases", in: diagnostics), 0, "Preparation is lazy")
        XCTAssertTrue(owner.beginDraw(role: .staticChart, size: size, scale: 2))
        owner.didDraw()
        XCTAssertEqual(counter("native_gpu_canvas_draws", in: diagnostics), 1)
        XCTAssertEqual(counter("current_pixel_area", in: diagnostics), 20 * 12 * 4)
        owner.appeared(role: .staticChart)
        XCTAssertEqual(counter("live_canvases", in: diagnostics), 1)
        XCTAssertEqual(owner.presentationGeneration, 0)
        owner.disappeared()
        owner.disappeared()
        XCTAssertEqual(counter("live_canvases", in: diagnostics), 0)
        XCTAssertFalse(owner.beginDraw(role: .staticChart, size: size, scale: 2))
        owner.didDraw()
        XCTAssertEqual(
            counter("native_gpu_canvas_draws", in: diagnostics), 1,
            "A stale callback must not recreate hidden work")
        owner.appeared(role: .staticChart)
        XCTAssertEqual(owner.presentationGeneration, 1)
        XCTAssertFalse(owner.beginDraw(role: .staticChart, size: size, scale: 2, generation: 0))
        owner.didDraw(generation: 0)
        XCTAssertEqual(
            counter("native_gpu_canvas_draws", in: diagnostics), 1,
            "A closure captured before disappearance stays stale after reappearance")
        XCTAssertTrue(owner.beginDraw(role: .staticChart, size: size, scale: 2, generation: 1))
        owner.didDraw(generation: 1)
        owner.contentUpdated(role: .cursor)
        XCTAssertTrue(
            owner.beginDraw(
                role: .cursor, size: CGSize(width: 8, height: 12), scale: 1, generation: 1))
        owner.didDraw(generation: 1)
        XCTAssertEqual(counter("native_gpu_canvas_draws", in: diagnostics), 3)
        XCTAssertEqual(counter("live_canvases", in: diagnostics), 1)
        XCTAssertEqual(counter("current_pixel_area", in: diagnostics), 8 * 12)
        XCTAssertEqual(counter("live_renderers", in: diagnostics), 0)
        XCTAssertEqual(counter("peak_live_renderers", in: diagnostics), 0)
        XCTAssertEqual(counter("current_bitmap_bytes", in: diagnostics), 0)
        XCTAssertEqual(counter("peak_bitmap_bytes", in: diagnostics), 0)
        XCTAssertEqual(counter("invalid_events", in: diagnostics), 0)
        owner.stop()
        owner.appeared(role: .staticChart)
        XCTAssertFalse(owner.beginDraw(role: .staticChart, size: size, scale: 1))
        XCTAssertEqual(counter("live_canvases", in: diagnostics), 0)
        try diagnostics.disable()
    }

    func testOwnerRejectsEmptyOrInvalidGeometryAndDeinitReleasesItsToken() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .nativeGPUCanvas)
        var owner: NativeGPUChartCanvasOwner? = NativeGPUChartCanvasOwner(diagnostics: diagnostics)
        for size in [
            CGSize.zero, CGSize(width: -1, height: 10),
            CGSize(width: CGFloat.nan, height: 10), CGSize(width: 10, height: CGFloat.infinity),
        ] {
            XCTAssertFalse(owner!.beginDraw(role: .staticChart, size: size, scale: 1))
        }
        for scale in [CGFloat.zero, -1, .nan, .infinity] {
            XCTAssertFalse(
                owner!.beginDraw(
                    role: .staticChart, size: CGSize(width: 20, height: 10), scale: scale))
        }
        XCTAssertEqual(counter("live_canvases", in: diagnostics), 0)
        XCTAssertTrue(
            owner!.beginDraw(role: .staticChart, size: CGSize(width: 20, height: 10), scale: 1))
        owner!.didDraw()
        owner = nil
        XCTAssertEqual(counter("live_canvases", in: diagnostics), 0)
        XCTAssertEqual(counter("current_pixel_area", in: diagnostics), 0)
        XCTAssertEqual(counter("invalid_events", in: diagnostics), 0)
        try diagnostics.disable()
    }

    private func counter(_ key: String, in diagnostics: PerformanceGraphicsDiagnostics) -> UInt64 {
        diagnostics.snapshot()[key] as? UInt64 ?? 0
    }

    private func solid(_ color: Color) -> ChartCanvas.Drawing {
        { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color))
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, scale: CGFloat) throws -> CGContext {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        return try render(renderer, size: size, scale: scale)
    }

    private func render<V: View>(_ renderer: ImageRenderer<V>, size: CGSize, scale: CGFloat) throws
        -> CGContext
    {
        let result = try bitmap(size: size, scale: scale)
        renderer.render(rasterizationScale: scale) { _, draw in draw(result) }
        return result
    }

    private func bitmap(size: CGSize, scale: CGFloat) throws -> CGContext {
        let width = Int(ceil(size.width * scale))
        let height = Int(ceil(size.height * scale))
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        return context
    }

    private func bytes(_ context: CGContext) -> [UInt8] {
        Array(
            UnsafeBufferPointer(
                start: context.data!.assumingMemoryBound(to: UInt8.self),
                count: context.bytesPerRow * context.height))
    }

    private func assertPixels(
        _ actual: CGContext, match expected: CGContext,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let actualBytes = bytes(actual)
        let expectedBytes = bytes(expected)
        XCTAssertEqual(actualBytes.count, expectedBytes.count, file: file, line: line)
        let error = zip(actualBytes, expectedBytes).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        XCTAssertLessThanOrEqual(
            Double(error) / Double(max(1, expectedBytes.count)), 0.5,
            file: file, line: line)
    }

    private let artwork: ChartCanvas.Drawing = { context, size in
        context.fill(Path(CGRect(x: 3, y: 5, width: 13, height: 9)), with: .color(.red))
        context.fill(
            Path(CGRect(x: size.width - 18, y: size.height - 16, width: 11, height: 7)),
            with: .color(.blue))
        context.fill(
            Path(CGRect(x: 20, y: 28, width: 40, height: 12)),
            with: .linearGradient(
                Gradient(colors: [.cyan, .purple]),
                startPoint: CGPoint(x: 20, y: 28), endPoint: CGPoint(x: 60, y: 40)))
        var line = Path()
        line.move(to: CGPoint(x: 12, y: 53))
        line.addQuadCurve(to: CGPoint(x: 105, y: 35), control: CGPoint(x: 45, y: 18))
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 3))
            glow.stroke(line, with: .color(.cyan.opacity(0.35)), lineWidth: 7)
        }
        context.stroke(line, with: .color(.cyan), lineWidth: 2)
        context.fill(
            Path(ellipseIn: CGRect(x: 34, y: 53, width: 18, height: 18)),
            with: .radialGradient(
                Gradient(colors: [.white, .orange.opacity(0)]),
                center: CGPoint(x: 43, y: 62), startRadius: 0, endRadius: 9))
        context.draw(
            Text("Requests +2").font(.system(size: 9)).foregroundColor(.secondary),
            at: CGPoint(x: 74, y: 12))
    }
}

@MainActor @Observable
private final class NativeGPUObservedState {
    var highlighted = false
}

private struct NativeGPUFrameClockTestSurface: View {
    let clock: RequestRailFrameClock
    let origin: Date
    let isDrawing: Bool
    let contentUpdated: () -> Void
    let didDraw: () -> Void

    var body: some View {
        let _ = contentUpdated()
        return NativeGPUChartCanvas(revision: AnyHashable(isDrawing)) { context, size in
            didDraw()
            if isDrawing {
                let color: Color = clock.date.timeIntervalSince(origin) < 0.5 ? .red : .blue
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color))
            }
        }
    }
}
