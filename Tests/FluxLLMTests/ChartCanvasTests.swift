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

    func testStableRevisionSkipsUpdatesAndChangedRevisionReplacesPixels() throws {
        let size = CGSize(width: 20, height: 12)
        let environment = EnvironmentValues()
        let view = DisplayTrackingView(frame: CGRect(origin: .zero, size: size))
        let red: ChartCanvas.Drawing = { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.red))
        }
        view.update(drawing: red, environment: environment, revision: AnyHashable(1))
        let first = try bitmap(size: size)
        draw(view, into: first)
        view.displayRequests = 0

        for _ in 0..<20 {
            view.update(drawing: red, environment: environment, revision: AnyHashable(1))
        }
        XCTAssertEqual(
            view.displayRequests, 0, "Equivalent parent updates must not redraw the chart")

        view.update(
            drawing: { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.blue))
            }, environment: environment, revision: AnyHashable(2))
        XCTAssertGreaterThan(view.displayRequests, 0)
        let next = try bitmap(size: size)
        draw(view, into: next)
        XCTAssertNotEqual(
            bytes(first), bytes(next), "A new publication must replace retained pixels")
    }

    func testUnversionedDrawingAlwaysAcceptsReplacement() {
        let size = CGSize(width: 20, height: 12)
        let view = DisplayTrackingView(frame: CGRect(origin: .zero, size: size))
        let environment = EnvironmentValues()
        let revisions: [AnyHashable?] = [AnyHashable(1), nil, nil]
        for revision in revisions {
            view.displayRequests = 0
            view.update(drawing: { _, _ in }, environment: environment, revision: revision)
            XCTAssertGreaterThan(
                view.displayRequests, 0, "A nil revision cannot promise identical pixels")
        }
    }

    func testDrawingEnvironmentChangesInvalidateAnUnchangedRevision() {
        var baseline = EnvironmentValues()
        baseline.colorScheme = .light
        baseline.displayScale = 1
        baseline.layoutDirection = .leftToRight
        baseline.locale = Locale(identifier: "en_US")
        baseline.timeZone = TimeZone(secondsFromGMT: 0)!
        baseline.calendar = Calendar(identifier: .gregorian)
        baseline.dynamicTypeSize = .medium
        baseline.font = .system(size: 12)
        baseline.legibilityWeight = .regular
        let changes: [(String, (inout EnvironmentValues) -> Void)] = [
            ("color scheme", { $0.colorScheme = .dark }),
            ("display scale", { $0.displayScale = 2 }),
            ("layout direction", { $0.layoutDirection = .rightToLeft }),
            ("locale", { $0.locale = Locale(identifier: "fr_FR") }),
            ("time zone", { $0.timeZone = TimeZone(secondsFromGMT: 7_200)! }),
            ("calendar", { $0.calendar = Calendar(identifier: .buddhist) }),
            ("dynamic type", { $0.dynamicTypeSize = .accessibility1 }),
            ("font", { $0.font = .system(size: 18, weight: .bold) }),
            ("legibility", { $0.legibilityWeight = .bold }),
        ]
        for (name, change) in changes {
            let view = DisplayTrackingView(frame: CGRect(x: 0, y: 0, width: 20, height: 12))
            view.update(drawing: { _, _ in }, environment: baseline, revision: AnyHashable(1))
            var changed = baseline
            change(&changed)
            view.displayRequests = 0
            view.update(drawing: { _, _ in }, environment: changed, revision: AnyHashable(1))
            XCTAssertGreaterThan(view.displayRequests, 0, "Changed \(name) must invalidate drawing")
            view.displayRequests = 0
            view.update(drawing: { _, _ in }, environment: changed, revision: AnyHashable(1))
            XCTAssertEqual(
                view.displayRequests, 0, "The new \(name) must become the retained environment")
        }
    }

    func testEnvironmentChangeWithStableRevisionReachesRenderedPixels() throws {
        let size = CGSize(width: 20, height: 12)
        let view = DisplayTrackingView(frame: CGRect(origin: .zero, size: size))
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        let drawing: ChartCanvas.Drawing = { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary))
        }
        view.update(drawing: drawing, environment: environment, revision: AnyHashable(1))
        let light = try bitmap(size: size)
        draw(view, into: light)
        environment.colorScheme = .dark
        view.update(drawing: drawing, environment: environment, revision: AnyHashable(1))
        let dark = try bitmap(size: size)
        draw(view, into: dark)
        XCTAssertGreaterThan(rgbSum(dark), rgbSum(light) + 10_000)
    }

    func testRevisionReuseRetainsOnlyAcceptedImmutableChartData() {
        final class ChartData {}
        let view = DisplayTrackingView(frame: CGRect(x: 0, y: 0, width: 20, height: 12))
        let environment = EnvironmentValues()
        weak var accepted: ChartData?
        weak var skipped: ChartData?
        weak var replacement: ChartData?
        autoreleasepool {
            let data = ChartData()
            accepted = data
            view.update(
                drawing: { [data] _, _ in withExtendedLifetime(data) {} },
                environment: environment, revision: AnyHashable(1))
        }
        autoreleasepool {
            let data = ChartData()
            skipped = data
            view.update(
                drawing: { [data] _, _ in withExtendedLifetime(data) {} },
                environment: environment, revision: AnyHashable(1))
        }
        XCTAssertNotNil(accepted, "An unchanged revision retains its accepted immutable drawing")
        XCTAssertNil(skipped, "Skipped parent updates must not retain additional chart payloads")
        autoreleasepool {
            let data = ChartData()
            replacement = data
            view.update(
                drawing: { [data] _, _ in withExtendedLifetime(data) {} },
                environment: environment, revision: AnyHashable(2))
        }
        XCTAssertNil(accepted, "A new revision replaces the previous prepared chart payload")
        XCTAssertNotNil(replacement)
        ChartCanvas.dismantleNSView(view, coordinator: ())
        XCTAssertNil(replacement)
        view.displayRequests = 0
        view.update(drawing: { _, _ in }, environment: environment, revision: AnyHashable(2))
        XCTAssertGreaterThan(
            view.displayRequests, 0, "Dismantling must also clear revision reuse state")
    }

    func testChangedCropOriginInvalidatesTheSameRevision() throws {
        let size = CGSize(width: 40, height: 24)
        let view = DisplayTrackingView(frame: CGRect(origin: .zero, size: size))
        let environment = EnvironmentValues()
        let drawing: ChartCanvas.Drawing = { context, _ in
            context.fill(Path(CGRect(x: 15, y: 12, width: 8, height: 6)), with: .color(.red))
        }
        view.update(
            drawing: drawing, environment: environment, revision: AnyHashable(1),
            drawingBounds: CGRect(origin: .zero, size: size))
        let first = try bitmap(size: size)
        draw(view, into: first)
        view.displayRequests = 0
        view.update(
            drawing: drawing, environment: environment, revision: AnyHashable(1),
            drawingBounds: CGRect(origin: CGPoint(x: 10, y: 5), size: size))
        XCTAssertGreaterThan(view.displayRequests, 0, "Moving a same-sized crop changes its pixels")
        let shifted = try bitmap(size: size)
        draw(view, into: shifted)
        XCTAssertNotEqual(bytes(first), bytes(shifted))
    }

    func testCroppedSurfacesRecomposeToTheFullChartAtBothDisplayScales() throws {
        let size = CGSize(width: 220, height: 260)
        let rail = CGRect(x: 60, y: 90, width: 100, height: 84)
        let cursorX: CGFloat = 110
        let decoration: ChartCanvas.Drawing = { context, _ in
            context.fill(
                Path(
                    ellipseIn: CGRect(x: rail.minX - 30, y: rail.minY - 30, width: 60, height: 60)),
                with: .radialGradient(
                    Gradient(colors: [.white, .cyan.opacity(0)]),
                    center: rail.origin, startRadius: 0, endRadius: 30))
            var spark = Path()
            spark.move(to: CGPoint(x: rail.maxX - 5, y: rail.maxY - 5))
            spark.addLine(to: CGPoint(x: rail.maxX + 35, y: rail.maxY + 20))
            context.stroke(
                spark, with: .color(.orange),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        let cursor: ChartCanvas.Drawing = { context, _ in
            var line = Path()
            line.move(to: CGPoint(x: cursorX, y: 5))
            line.addLine(to: CGPoint(x: cursorX, y: size.height - 8))
            context.stroke(line, with: .color(.white.opacity(0.55)), lineWidth: 0.8)
            context.fill(
                Path(ellipseIn: CGRect(x: cursorX - 6, y: 30, width: 12, height: 12)),
                with: .color(.cyan.opacity(0.3)))
        }
        let layers: [(CGRect, ChartCanvas.Drawing)] = [
            (ChartSurfaceBounds.decorations(rail: rail, plotSize: size), decoration),
            (ChartSurfaceBounds.cursor(x: cursorX, plotSize: size), cursor),
        ]
        for scale in [CGFloat(1), 2] {
            var environment = EnvironmentValues()
            environment.displayScale = scale
            environment.colorScheme = .dark
            let full = try bitmap(size: size, scale: scale)
            let recomposed = try bitmap(size: size, scale: scale)
            for (crop, drawing) in layers {
                let baseline = makeView(size: size, drawing: drawing, environment: environment)
                draw(baseline, into: full)

                let cropped = DisplayTrackingView(frame: CGRect(origin: .zero, size: crop.size))
                var localSize: CGSize?
                cropped.update(
                    drawing: { context, proposed in
                        localSize = proposed
                        drawing(&context, proposed)
                    }, environment: environment, revision: AnyHashable(1), drawingBounds: crop)
                let pixels = try bitmap(size: crop.size, scale: scale)
                draw(cropped, into: pixels)
                XCTAssertEqual(localSize, crop.size)
                let image = try XCTUnwrap(pixels.makeImage())
                // The crop uses SwiftUI's top-left coordinates; CGContext's
                // destination rectangle is measured from its bottom-left.
                recomposed.draw(
                    image,
                    in: CGRect(
                        x: crop.minX, y: size.height - crop.maxY,
                        width: crop.width, height: crop.height))
            }
            let maximumDifference =
                zip(bytes(full), bytes(recomposed))
                .map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(
                maximumDifference, 1, "Cropping must preserve pixels at \(scale)×")
            XCTAssertGreaterThan(bytes(recomposed).filter { $0 > 0 }.count, 100)
        }
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
