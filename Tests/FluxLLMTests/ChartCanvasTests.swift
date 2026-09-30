import AppKit
import Observation
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class ChartCanvasTests: XCTestCase {
    func testNativeDrawingMatchesCanvasPathsGradientsBlurTextAndOrientation() throws {
        let size = CGSize(width: 120, height: 80)
        let drawing: ChartCanvas.Drawing = { context, size in
            // Asymmetric corners catch a vertical or horizontal reflection.
            context.fill(
                Path(CGRect(x: 3, y: 5, width: 13, height: 9)),
                with: .color(Color(red: 1, green: 0, blue: 0)))
            context.fill(
                Path(CGRect(x: size.width - 18, y: size.height - 16, width: 11, height: 7)),
                with: .color(Color(red: 0, green: 0, blue: 1)))
            var trace = Path()
            trace.move(to: CGPoint(x: 15, y: 52))
            trace.addQuadCurve(
                to: CGPoint(x: size.width - 10, y: 28), control: CGPoint(x: 55, y: 16))
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 3))
                glow.stroke(trace, with: .color(.cyan.opacity(0.35)), lineWidth: 7)
            }
            context.stroke(
                trace, with: .color(.cyan),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3]))
            context.fill(
                Path(ellipseIn: CGRect(x: 34, y: 53, width: 18, height: 18)),
                with: .radialGradient(
                    Gradient(colors: [.white, .orange.opacity(0)]),
                    center: CGPoint(x: 43, y: 62), startRadius: 0, endRadius: 9))
            context.draw(
                Text("Requests +2").font(.system(size: 9)).foregroundColor(.secondary),
                at: CGPoint(x: 69, y: 12))
        }

        for scale in [CGFloat(1), 2] {
            var environment = EnvironmentValues()
            environment.colorScheme = .dark
            environment.displayScale = scale
            let view = makeView(size: size, drawing: drawing, environment: environment)
            let actual = try bitmap(size: size, scale: scale)
            draw(view, into: actual)

            let expected = try bitmap(size: size, scale: scale)
            let reference = ImageRenderer(
                content: Canvas(renderer: drawing).environment(\.self, environment))
            reference.proposedSize = ProposedViewSize(size)
            reference.scale = scale
            reference.render(rasterizationScale: scale) { _, render in render(expected) }

            let actualBytes = bytes(actual)
            let expectedBytes = bytes(expected)
            XCTAssertEqual(actualBytes.count, expectedBytes.count)
            let maximumDifference =
                zip(actualBytes, expectedBytes)
                .map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(maximumDifference, 1)
            XCTAssertGreaterThan(actualBytes.filter { $0 > 0 }.count, 500)
            XCTAssertFalse(view.isFlipped)
            XCTAssertFalse(view.isOpaque)
        }
    }

    func testEnvironmentReachesCanvasAndChangesResolvedColors() throws {
        let size = CGSize(width: 12, height: 10)
        var environment = EnvironmentValues()
        environment.displayScale = 2
        environment.locale = Locale(identifier: "fr_FR")
        environment.timeZone = TimeZone(secondsFromGMT: 7_200)!
        environment.layoutDirection = .rightToLeft
        environment[CanvasTestEnvironmentKey.self] = "chart-environment"
        var observed: EnvironmentValues?
        let drawing: ChartCanvas.Drawing = { context, size in
            observed = context.environment
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary))
        }
        environment.colorScheme = .light
        let view = makeView(size: size, drawing: drawing, environment: environment)
        let light = try bitmap(size: size, scale: 2)
        draw(view, into: light)
        let values = try XCTUnwrap(observed)
        XCTAssertEqual(values.locale.identifier, "fr_FR")
        XCTAssertEqual(values.timeZone.secondsFromGMT(), 7_200)
        XCTAssertEqual(values.layoutDirection, .rightToLeft)
        XCTAssertEqual(values.displayScale, 2)
        XCTAssertEqual(values[CanvasTestEnvironmentKey.self], "chart-environment")
        XCTAssertEqual(values.colorSchemeContrast, environment.colorSchemeContrast)
        XCTAssertEqual(
            values.accessibilityReduceTransparency, environment.accessibilityReduceTransparency)

        environment.colorScheme = .dark
        view.update(drawing: drawing, environment: environment)
        let dark = try bitmap(size: size, scale: 2)
        draw(view, into: dark)
        XCTAssertEqual(observed?.colorScheme, .dark)
        XCTAssertGreaterThan(rgbSum(dark), rgbSum(light) + 10_000)
    }

    func testPreparingAndResizingWithoutDrawingDoesNotInvokeChartWork() throws {
        var sizes: [CGSize] = []
        let view = makeView(size: CGSize(width: 40, height: 20)) { _, size in sizes.append(size) }
        view.setFrameSize(CGSize(width: 90, height: 50))
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(sizes.isEmpty)
        XCTAssertNil(view.window)

        draw(view, into: try bitmap(size: view.bounds.size))
        XCTAssertEqual(sizes.last, CGSize(width: 90, height: 50))
        view.displayRequests = 0
        view.setFrameSize(CGSize(width: 55, height: 35))
        XCTAssertGreaterThan(view.displayRequests, 0, "Resizing must request a native redraw")
        draw(view, into: try bitmap(size: view.bounds.size))
        XCTAssertEqual(sizes.last, CGSize(width: 55, height: 35))

        let count = sizes.count
        view.setFrameSize(.zero)
        draw(view, into: try bitmap(size: CGSize(width: 1, height: 1)))
        XCTAssertEqual(sizes.count, count)
    }

    func testOffscreenLayersCompositeWithoutErasingEarlierDrawing() throws {
        let size = CGSize(width: 20, height: 12)
        let base = makeView(size: size) { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(red: 0, green: 0, blue: 1)))
        }
        let overlay = makeView(size: size) { _, _ in }
        let surface = try bitmap(size: size)
        draw(base, into: surface)
        let basePixels = bytes(surface)
        XCTAssertGreaterThan(basePixels.filter { $0 > 0 }.count, 0)

        draw(overlay, into: surface)
        XCTAssertEqual(bytes(surface), basePixels, "An empty overlay must preserve the base chart")

        overlay.update(
            drawing: { context, _ in
                context.fill(
                    Path(CGRect(x: 4, y: 3, width: 12, height: 6)),
                    with: .color(.white.opacity(0.5)))
            }, environment: EnvironmentValues())
        draw(overlay, into: surface)
        let composite = bytes(surface)
        XCTAssertNotEqual(composite, basePixels)
        // Interior and exterior samples avoid antialiasing at rectangle edges.
        let outside = (1 * surface.width + 1) * 4
        let inside = (6 * surface.width + 10) * 4
        XCTAssertEqual(
            Array(composite[outside..<(outside + 4)]), Array(basePixels[outside..<(outside + 4)]))
        XCTAssertGreaterThan(composite[inside], basePixels[inside])
        XCTAssertGreaterThan(composite[inside + 1], basePixels[inside + 1])
        XCTAssertEqual(composite[inside + 3], 255, "Source-over preserves the opaque base alpha")

        // A new offscreen composition starts from its owner's fresh target.
        // An empty view cannot remove its previous pixels from a shared target.
        overlay.update(drawing: { _, _ in }, environment: EnvironmentValues())
        let nextFrame = try bitmap(size: size)
        draw(base, into: nextFrame)
        draw(overlay, into: nextFrame)
        XCTAssertEqual(
            bytes(nextFrame), basePixels, "A recomposed frame must contain no expired overlay")

        ChartCanvas.dismantleNSView(overlay, coordinator: ())
        draw(overlay, into: surface)
        XCTAssertEqual(
            bytes(surface), composite, "A dismantled view must not erase siblings either")
    }

    func testObservedContentInvalidatesWithoutReplacingClosureAndThenSettles() throws {
        let state = CanvasDrawingState()
        let size = CGSize(width: 16, height: 12)
        var draws = 0
        let view = makeView(size: size) { context, size in
            draws += 1
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(state.highlighted ? .white : .black))
        }
        let surface = try bitmap(size: size)
        draw(view, into: surface)
        let initial = rgbSum(surface)
        view.displayRequests = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(view.displayRequests, 0, "A settled draw must not schedule itself again")

        state.highlighted = true
        let deadline = Date().addingTimeInterval(0.5)
        while view.displayRequests == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertGreaterThan(
            view.displayRequests, 0, "Changes read inside Canvas must reach the native view")
        view.displayRequests = 0
        draw(view, into: surface)
        XCTAssertGreaterThan(rgbSum(surface), initial + 10_000)
        let settledDraws = draws
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(view.displayRequests, 0)
        XCTAssertEqual(draws, settledDraws)

        ChartCanvas.dismantleNSView(view, coordinator: ())
        view.displayRequests = 0
        state.highlighted = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(view.displayRequests, 0, "Detached renderer invalidations must be canceled")
    }

    func testReplacingPreparedContentAndDismantlingReleaseCapturedChartData() throws {
        final class ChartData {}
        weak var preparedData: ChartData?
        weak var renderedData: ChartData?
        let size = CGSize(width: 20, height: 12)
        let view = ChartCanvas.DrawingView(frame: CGRect(origin: .zero, size: size))
        autoreleasepool {
            let data = ChartData()
            preparedData = data
            view.update(
                drawing: { [data] _, _ in withExtendedLifetime(data) {} }, environment: .init())
        }
        XCTAssertNotNil(preparedData)
        view.update(drawing: { _, _ in }, environment: .init())
        XCTAssertNil(preparedData, "Only the latest prepared chart closure should be retained")

        let surface = try bitmap(size: size)
        autoreleasepool {
            let data = ChartData()
            renderedData = data
            view.update(
                drawing: { [data] _, _ in withExtendedLifetime(data) {} }, environment: .init())
            draw(view, into: surface)
        }
        XCTAssertNotNil(renderedData)
        autoreleasepool {
            ChartCanvas.dismantleNSView(view, coordinator: ())
        }
        XCTAssertNil(renderedData, "Removing a surface must release its renderer and chart payload")
    }

    private func makeView(
        size: CGSize, drawing: @escaping ChartCanvas.Drawing,
        environment: EnvironmentValues = EnvironmentValues()
    ) -> DisplayTrackingView {
        let view = DisplayTrackingView(frame: CGRect(origin: .zero, size: size))
        view.update(drawing: drawing, environment: environment)
        return view
    }

    private func bitmap(size: CGSize, scale: CGFloat = 1) throws -> CGContext {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
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

    private func draw(_ view: ChartCanvas.DrawingView, into context: CGContext) {
        // Use AppKit's bitmap destination and preserve the caller's pixels and
        // transform, so multiple chart layers share one offscreen canvas.
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self),
            let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: context.width, pixelsHigh: context.height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bitmapFormat: .thirtyTwoBitBigEndian,
                bytesPerRow: context.bytesPerRow, bitsPerPixel: 32),
            representation.bytesPerRow == context.bytesPerRow,
            let bitmapPixels = representation.bitmapData,
            let graphics = NSGraphicsContext(bitmapImageRep: representation)
        else {
            XCTFail("Could not create a real offscreen drawing context")
            return
        }
        let byteCount = context.bytesPerRow * context.height
        bitmapPixels.update(from: pixels, count: byteCount)
        graphics.cgContext.concatenate(graphics.cgContext.ctm.inverted())
        graphics.cgContext.concatenate(context.ctm)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        view.draw(view.bounds)
        graphics.flushGraphics()
        pixels.update(from: bitmapPixels, count: byteCount)
    }

    private func bytes(_ context: CGContext) -> [UInt8] {
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: context.bytesPerRow * context.height))
    }

    private func rgbSum(_ context: CGContext) -> Int {
        bytes(context).enumerated().reduce(0) { sum, component in
            sum + (component.offset % 4 == 3 ? 0 : Int(component.element))
        }
    }

    /// AppKit does not retain a dirty-region flag for these unattached views.
    /// Observe the actual redraw requests while preserving native setter behavior;
    /// resource/visibility behavior is exercised by the separate native benchmark.
    private final class DisplayTrackingView: ChartCanvas.DrawingView {
        var displayRequests = 0

        override var needsDisplay: Bool {
            get { super.needsDisplay }
            set {
                if newValue { displayRequests += 1 }
                super.needsDisplay = newValue
            }
        }
    }
}

private struct CanvasTestEnvironmentKey: EnvironmentKey {
    static let defaultValue = "default-environment"
}

@MainActor @Observable
private final class CanvasDrawingState {
    var highlighted = false
}
