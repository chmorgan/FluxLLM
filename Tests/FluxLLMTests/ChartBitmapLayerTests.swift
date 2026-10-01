import AppKit
import Observation
import QuartzCore
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class ChartBitmapLayerTests: XCTestCase {
    func testImageAndPresentedLayerMatchCanvasIncludingGradientBlurTextAndOrientation() throws {
        try withCandidate {
            let size = CGSize(width: 120, height: 80)
            for scale in [CGFloat(1), 2] {
                var environment = EnvironmentValues()
                environment.displayScale = scale
                environment.colorScheme = .dark
                let view = makeView(size: size, environment: environment, drawing: artwork)
                defer { view.clearContent() }
                XCTAssertTrue(view.wantsUpdateLayer)
                XCTAssertFalse(view.isFlipped)
                XCTAssertFalse(view.canDrawSubviewsIntoLayer)
                XCTAssertNil(view.layer?.contents, "Preparation must not render hidden charts")
                view.updateLayer()
                let image = try layerImage(view)
                XCTAssertEqual(image.width, Int(size.width * scale))
                XCTAssertEqual(image.height, Int(size.height * scale))
                let expected = try reference(size: size, environment: environment, drawing: artwork)
                let raw = try bitmap(size: size, scale: scale)
                raw.draw(image, in: CGRect(origin: .zero, size: size))
                assertPixels(bytes(raw), match: bytes(expected), maximumMeanError: 0.05)

                // A correct CGImage alone does not prove that native layer
                // presentation preserves orientation, scale, or transparency.
                let presented = try bitmap(size: size, scale: scale)
                try XCTUnwrap(view.layer).render(in: presented)
                assertPixels(bytes(presented), match: bytes(expected), maximumMeanError: 0.5)
                XCTAssertGreaterThan(bytes(presented).filter { $0 > 0 }.count, 500)
                XCTAssertEqual(counter("layer_bitmap_native_draws"), 0)
                XCTAssertEqual(counter("layer_bitmap_failures"), 0)
                XCTAssertEqual(counter("current_bitmap_bytes"), 0)
                XCTAssertEqual(
                    counter("current_layer_image_bytes"), UInt64(image.bytesPerRow * image.height))
            }
        }
    }

    func testFractionalDimensionsPreserveNativePixelScaleWithoutStretching() throws {
        try withCandidate {
            let size = CGSize(width: 120.25, height: 80.75)
            let drawing: ChartCanvas.Drawing = { context, _ in
                context.fill(Path(CGRect(x: 3, y: 5, width: 13, height: 9)), with: .color(.red))
                context.fill(Path(CGRect(x: 99, y: 60, width: 11, height: 7)), with: .color(.blue))
                context.fill(Path(CGRect(x: 45, y: 19, width: 1, height: 41)), with: .color(.white))
                context.fill(Path(CGRect(x: 48, y: 38, width: 53, height: 1)), with: .color(.green))
            }
            for scale in [CGFloat(1), 1.5, 2] {
                var environment = EnvironmentValues()
                environment.displayScale = scale
                let view = makeView(size: size, environment: environment, drawing: drawing)
                defer { view.clearContent() }
                view.updateLayer()
                let presented = try bitmap(size: size, scale: scale)
                try XCTUnwrap(view.layer).render(in: presented)
                let expected = try reference(size: size, environment: environment, drawing: drawing)
                assertPixels(bytes(presented), match: bytes(expected), maximumMeanError: 0.75)
                XCTAssertEqual(view.layer?.contentsScale, scale)
                XCTAssertEqual(view.layer?.contentsGravity, .bottomLeft)
            }
        }
    }

    func testCropOriginSurvivesLayerPresentationAndRecomposition() throws {
        try withCandidate {
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
                let view = makeView(size: crop.size, environment: environment, drawing: drawing)
                defer { view.clearContent() }
                view.update(
                    drawing: drawing, environment: environment,
                    revision: AnyHashable(1), drawingBounds: crop)
                view.updateLayer()
                let actual = try bitmap(size: size, scale: scale)
                actual.translateBy(x: crop.minX, y: size.height - crop.maxY)
                try XCTUnwrap(view.layer).render(in: actual)
                let expected = try reference(size: size, environment: environment, drawing: drawing)
                assertPixels(bytes(actual), match: bytes(expected), maximumMeanError: 0.5)

                let before = try layerImage(view)
                view.update(
                    drawing: drawing, environment: environment,
                    revision: AnyHashable(1),
                    drawingBounds: crop.offsetBy(dx: 4, dy: 3))
                view.updateLayer()
                let after = try layerImage(view)
                XCTAssertFalse(before === after, "A moved same-size crop must replace its image")
            }
        }
    }

    func testRevisionAndObservedContentInvalidateThenSettleWithoutNativeDrawing() throws {
        try withCandidate {
            let state = LayerDrawingState()
            let size = CGSize(width: 20, height: 12)
            var draws = 0
            let drawing: ChartCanvas.Drawing = { context, size in
                draws += 1
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(state.highlighted ? .white : .black))
            }
            let view = makeView(size: size, drawing: drawing)
            defer { view.clearContent() }
            view.update(drawing: drawing, environment: .init(), revision: AnyHashable(1))
            view.updateLayer()
            let first = try layerImage(view)
            view.displayRequests = 0
            for _ in 0..<10 {
                view.update(drawing: drawing, environment: .init(), revision: AnyHashable(1))
            }
            XCTAssertEqual(view.displayRequests, 0)
            state.highlighted = true
            let deadline = Date().addingTimeInterval(0.5)
            while view.displayRequests == 0 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            XCTAssertGreaterThan(view.displayRequests, 0)
            view.updateLayer()
            XCTAssertFalse(first === (try layerImage(view)))
            view.displayRequests = 0
            let settledDraws = draws
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(view.displayRequests, 0)
            XCTAssertEqual(draws, settledDraws)
            view.update(drawing: drawing, environment: .init(), revision: AnyHashable(2))
            XCTAssertGreaterThan(view.displayRequests, 0)
            view.clearContent()
            view.displayRequests = 0
            state.highlighted = false
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(view.displayRequests, 0)
            XCTAssertNil(view.layer?.contents)
        }
    }

    func testEnvironmentAndResizeReplaceImageAndEmptyDrawingClearsOldPixels() throws {
        try withCandidate {
            let size = CGSize(width: 20, height: 12)
            var environment = EnvironmentValues()
            environment.displayScale = 1
            environment.colorScheme = .light
            var observed: EnvironmentValues?
            let drawing: ChartCanvas.Drawing = { context, size in
                observed = context.environment
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary))
            }
            let view = makeView(size: size, environment: environment, drawing: drawing)
            defer { view.clearContent() }
            view.update(drawing: drawing, environment: environment, revision: AnyHashable(1))
            view.updateLayer()
            let first = try layerImage(view)
            environment.displayScale = 2
            environment.colorScheme = .dark
            environment.locale = Locale(identifier: "fr_FR")
            view.update(drawing: drawing, environment: environment, revision: AnyHashable(1))
            view.setFrameSize(CGSize(width: 30, height: 15))
            view.updateLayer()
            let second = try layerImage(view)
            XCTAssertFalse(first === second)
            XCTAssertEqual(second.width, 60)
            XCTAssertEqual(second.height, 30)
            XCTAssertEqual(observed?.colorScheme, .dark)
            XCTAssertEqual(observed?.locale.identifier, "fr_FR")
            view.update(drawing: { _, _ in }, environment: environment, revision: AnyHashable(2))
            view.updateLayer()
            let empty = try layerImage(view)
            let emptyPixels = try bitmap(size: view.bounds.size, scale: 2)
            emptyPixels.draw(empty, in: view.bounds)
            XCTAssertTrue(
                bytes(emptyPixels).allSatisfy { $0 == 0 },
                "Expired content must not survive in new pixels")
            view.setFrameSize(.zero)
            XCTAssertNil(
                view.layer?.contents,
                "Zero-size views must release their retained image immediately")
            XCTAssertEqual(counter("current_layer_image_bytes"), 0)
        }
    }

    func testTeardownReleasesRendererPayloadImageAndAccounting() throws {
        try withCandidate {
            final class Payload {}
            weak var payload: Payload?
            let view = TrackingView(frame: CGRect(x: 0, y: 0, width: 20, height: 12))
            autoreleasepool {
                let data = Payload()
                payload = data
                view.update(
                    drawing: { [data] _, _ in withExtendedLifetime(data) {} }, environment: .init())
                view.updateLayer()
            }
            XCTAssertNotNil(payload)
            XCTAssertGreaterThan(counter("current_layer_image_bytes"), 0)
            view.clearContent()
            XCTAssertNil(payload)
            XCTAssertNil(view.layer?.contents)
            XCTAssertEqual(counter("current_layer_image_bytes"), 0)
            XCTAssertEqual(counter("current_bitmap_bytes"), 0)
            XCTAssertEqual(counter("live_renderers"), 0)
            XCTAssertEqual(counter("live_canvases"), 0)
            let presentations = counter("layer_bitmap_presentations")
            view.updateLayer()
            XCTAssertEqual(counter("layer_bitmap_presentations"), presentations)
        }
    }

    func testInvalidAllocationClearsPriorImageAndNativeFallbackIsRejected() throws {
        try withCandidate {
            let view = makeView(size: CGSize(width: 20, height: 12)) { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.red))
            }
            defer { view.clearContent() }
            view.updateLayer()
            XCTAssertNotNil(view.layer?.contents)
            let presentations = counter("layer_bitmap_presentations")
            view.setFrameSize(CGSize(width: 4_096, height: 4_096))
            view.updateLayer()
            XCTAssertNil(view.layer?.contents)
            XCTAssertEqual(counter("layer_bitmap_presentations"), presentations)
            XCTAssertEqual(counter("layer_bitmap_failures"), 1)
            XCTAssertEqual(counter("current_layer_image_bytes"), 0)
            view.setFrameSize(CGSize(width: 20, height: 12))
            view.updateLayer()
            XCTAssertNotNil(view.layer?.contents)
            let priorFallback = counter("layer_bitmap_native_draws")
            view.draw(view.bounds)
            XCTAssertEqual(counter("layer_bitmap_native_draws"), priorFallback + 1)
            XCTAssertNil(
                view.layer?.contents, "A rejected native callback must not leave stale pixels")
        }
    }

    func testChangingRoleReleasesOldImageAndRedrawsEvenWithStableRevision() throws {
        try withCandidate {
            let view = makeView(size: CGSize(width: 20, height: 12)) { _, _ in }
            defer { view.clearContent() }
            let drawing: ChartCanvas.Drawing = { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.red))
            }
            view.update(
                drawing: drawing, environment: .init(), revision: AnyHashable(1), role: .cursor)
            view.updateLayer()
            XCTAssertNotNil(view.layer?.contents)
            view.displayRequests = 0
            view.update(
                drawing: drawing, environment: .init(), revision: AnyHashable(1), role: .railBars)
            XCTAssertNil(view.layer?.contents)
            XCTAssertEqual(counter("current_layer_image_bytes"), 0)
            XCTAssertGreaterThan(view.displayRequests, 0)
            view.updateLayer()
            XCTAssertNotNil(view.layer?.contents)
            XCTAssertEqual(counter("current_layer_image_bytes"), 20 * 12 * 4)
            XCTAssertEqual(counter("invalid_events"), 0)
        }
    }

    func testAllocationLayoutRejectsInvalidAndOverflowingGeometryBeforeAllocation() {
        let maximum = ChartCanvas.BitmapLayout.maximumBytes
        let admitted = ChartCanvas.BitmapLayout.make(
            size: CGSize(width: 2_048, height: 4_096), scale: 1)
        XCTAssertEqual(admitted?.byteCount, maximum)
        XCTAssertNil(
            ChartCanvas.BitmapLayout.make(size: CGSize(width: 2_049, height: 4_096), scale: 1))
        let invalidSizes = [
            CGSize.zero, CGSize(width: -1, height: 20), CGSize(width: CGFloat.infinity, height: 1),
            CGSize(width: CGFloat.nan, height: 1),
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: 2),
            CGSize(width: CGFloat(Int.max / 2), height: 8),
            CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude),
        ]
        for size in invalidSizes {
            XCTAssertNil(ChartCanvas.BitmapLayout.make(size: size, scale: 1))
        }
        for scale in [CGFloat.zero, -1, .nan, .infinity, .greatestFiniteMagnitude] {
            XCTAssertNil(
                ChartCanvas.BitmapLayout.make(size: CGSize(width: 2, height: 2), scale: scale))
        }
        let fractional = ChartCanvas.BitmapLayout.make(
            size: CGSize(width: 10.25, height: 5.25), scale: 2)
        XCTAssertEqual(fractional?.width, 21)
        XCTAssertEqual(fractional?.height, 11)
        XCTAssertEqual(fractional?.byteCount, 21 * 11 * 4)
    }

    private func withCandidate(_ operation: () throws -> Void) throws {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        try diagnostics.enable(mode: .bitmapLayerDestination)
        defer { XCTAssertNoThrow(try diagnostics.disable()) }
        try operation()
    }

    private func makeView(
        size: CGSize, environment: EnvironmentValues = .init(),
        drawing: @escaping ChartCanvas.Drawing
    ) -> TrackingView {
        let view = TrackingView(frame: CGRect(origin: .zero, size: size))
        view.update(drawing: drawing, environment: environment)
        return view
    }

    private func layerImage(_ view: ChartCanvas.DrawingView) throws -> CGImage {
        let value = try XCTUnwrap(view.layer?.contents)
        XCTAssertEqual(CFGetTypeID(value as CFTypeRef), CGImage.typeID)
        return value as! CGImage
    }

    private func counter(_ key: String) -> UInt64 {
        PerformanceGraphicsDiagnostics.shared.snapshot()[key] as? UInt64 ?? 0
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

    private func reference(
        size: CGSize, environment: EnvironmentValues, drawing: @escaping ChartCanvas.Drawing
    ) throws -> CGContext {
        let context = try bitmap(size: size, scale: environment.displayScale)
        context.clip(to: CGRect(origin: .zero, size: size))
        let renderer = ImageRenderer(
            content: Canvas(renderer: drawing).environment(\.self, environment))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = environment.displayScale
        renderer.render(rasterizationScale: environment.displayScale) { _, draw in draw(context) }
        return context
    }

    private func bytes(_ context: CGContext) -> [UInt8] {
        Array(
            UnsafeBufferPointer(
                start: context.data!.assumingMemoryBound(to: UInt8.self),
                count: context.bytesPerRow * context.height))
    }

    private func assertPixels(
        _ actual: [UInt8], match expected: [UInt8], maximumMeanError: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        let totalError = zip(actual, expected).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        XCTAssertLessThanOrEqual(
            Double(totalError) / Double(max(1, expected.count)),
            maximumMeanError, file: file, line: line)
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

    private final class TrackingView: ChartCanvas.DrawingView {
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

@MainActor @Observable
private final class LayerDrawingState {
    var highlighted = false
}
