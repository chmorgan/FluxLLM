import AppKit
import Observation
import SwiftUI
import XCTest

@testable import FluxLLM
@testable import FluxLLMPerformanceSupport

@MainActor
private final class DrawingProbeObservationNotice {
    var notified = false
}

@MainActor
final class DrawingProbeSessionTests: XCTestCase {
    func testConfigurationRejectsUnknownInputsBeforeConstructingUI() throws {
        XCTAssertThrowsError(try DrawingProbeSession(backend: "imageRenderer", primitive: "line"))
        XCTAssertThrowsError(try DrawingProbeSession(backend: "canvas", primitive: "all"))
        for backend in DrawingProbeSession.Backend.allCases {
            for primitive in DrawingProbeSession.Primitive.allCases {
                let session = try DrawingProbeSession(
                    backend: backend.rawValue, primitive: primitive.rawValue)
                let snapshot = session.snapshot()
                XCTAssertEqual(snapshot["schema_version"] as? Int, 1)
                XCTAssertEqual(snapshot["backend"] as? String, backend.rawValue)
                XCTAssertEqual(snapshot["primitive"] as? String, primitive.rawValue)
                XCTAssertEqual(
                    snapshot["uses_swiftui_host"] as? Bool,
                    backend != .coreGraphicsUnhosted)
                XCTAssertEqual(snapshot["started"] as? Bool, false)
                XCTAssertEqual(snapshot["window_visible"] as? Bool, false)
                XCTAssertEqual(snapshot["draw_enabled"] as? Bool, false)
                XCTAssertEqual(snapshot["draw_calls"] as? UInt64, 0)
                XCTAssertEqual(snapshot["nonempty_draw_calls"] as? UInt64, 0)
                XCTAssertEqual(snapshot["requested_frames"] as? UInt64, 0)
                XCTAssertEqual(snapshot["content_width_points"] as? CGFloat, 664)
                XCTAssertEqual(snapshot["content_height_points"] as? CGFloat, 357)
            }
        }
    }

    func testClosedAndUnstartedSessionsRejectDrawingAndCloseIsIdempotent() async throws {
        let session = try DrawingProbeSession(backend: "core-graphics", primitive: "line")
        do {
            try await session.drawOnce()
            XCTFail("An unstarted session must not draw")
        } catch DrawingProbeSession.ProbeError.invalidLifecycle {}
        try await session.close()
        try await session.close()
        XCTAssertEqual(session.snapshot()["closed"] as? Bool, true)
        do {
            try await session.start()
            XCTFail("A closed session must not create native windows")
        } catch DrawingProbeSession.ProbeError.invalidLifecycle {}
        do {
            try await session.redraw(count: 100)
            XCTFail("A closed session must not draw")
        } catch DrawingProbeSession.ProbeError.invalidLifecycle {}
    }

    func testCallbacksCountDistinctFramesAndDuplicatesWithoutObservationFeedback() {
        let state = DrawingProbeState()
        let notice = DrawingProbeObservationNotice()
        withObservationTracking {
            _ = state.enabled
            _ = state.revision
            _ = state.drawCalls
            _ = state.nonemptyDrawCalls
            _ = state.acknowledgedRevision
        } onChange: {
            MainActor.assumeIsolated { notice.notified = true }
        }
        state.didDraw(revision: 0, nonempty: false)
        state.didDraw(revision: 0, nonempty: false)
        for revision in 1...101 {
            state.didDraw(revision: UInt64(revision), nonempty: true)
        }
        state.didDraw(revision: 100, nonempty: true)
        XCTAssertEqual(state.drawCalls, 104)
        XCTAssertEqual(state.nonemptyDrawCalls, 102)
        XCTAssertEqual(state.acknowledgedFrames, 101)
        XCTAssertEqual(state.acknowledgedRevision, 101)
        XCTAssertEqual(state.duplicateDrawCalls, 2)
        XCTAssertFalse(
            notice.notified, "Actual-draw accounting must not schedule another SwiftUI update")
    }

    func testSharedGeometryIsBoundedAndAsymmetric() {
        XCTAssertEqual(
            DrawingProbeArtwork.line.boundingBoxOfPath,
            CGRect(x: 32, y: 72, width: 600, height: 213))
        let bounds = DrawingProbeArtwork.chartPath.boundingBoxOfPath
        XCTAssertEqual(bounds.minX, 32, accuracy: 0.0001)
        XCTAssertEqual(bounds.maxX, 632, accuracy: 0.0001)
        XCTAssertGreaterThan(bounds.minY, 24)
        XCTAssertLessThan(bounds.maxY, 333)
        var elements = 0
        DrawingProbeArtwork.chartPath.applyWithBlock { _ in elements += 1 }
        XCTAssertEqual(elements, 256)
        XCTAssertTrue(DrawingProbeCGView(frame: .zero).isFlipped)
    }

    func testCoreGraphicsDrawingPreservesCallerStateAndEmptyDoesNoWork() throws {
        let context = try bitmap(scale: 1, topLeft: true)
        context.translateBy(x: 2, y: 3)
        context.clip(to: CGRect(x: 0, y: 0, width: 640, height: 340))
        let transform = context.ctm
        let clipping = context.boundingBoxOfClipPath
        DrawingProbeArtwork.draw(.empty, in: context)
        XCTAssertTrue(bytes(context).allSatisfy { $0 == 0 })
        for primitive in DrawingProbeSession.Primitive.allCases {
            DrawingProbeArtwork.draw(primitive, in: context)
            XCTAssertEqual(context.ctm, transform, "\(primitive) must preserve caller transform")
            XCTAssertEqual(
                context.boundingBoxOfClipPath, clipping,
                "\(primitive) must preserve caller clipping")
        }
        XCTAssertGreaterThan(bytes(context).filter { $0 > 0 }.count, 100)
    }

    func testSwiftUIAndNativePathsShareOrientationAndClippingAtBothScales() throws {
        for scale in [CGFloat(1), 2] {
            for primitive in [
                DrawingProbeSession.Primitive.line, .clippedLine, .layerLine,
                .withCGLine, .chartPath, .solidFill, .linearGradient, .radialGradient,
            ] {
                let direct = try bitmap(scale: scale, topLeft: true)
                DrawingProbeArtwork.draw(primitive, in: direct)
                let rendered = try bitmap(scale: scale, topLeft: false)
                let renderer = ImageRenderer(
                    content: Canvas { context, _ in
                        DrawingProbeArtwork.draw(primitive, in: &context)
                    }.environment(\.colorScheme, .light))
                renderer.proposedSize = ProposedViewSize(DrawingProbeSession.contentSize)
                renderer.scale = scale
                renderer.render(rasterizationScale: scale) { _, draw in draw(rendered) }
                let directBounds = try alphaBounds(direct)
                let renderedBounds = try alphaBounds(rendered)
                XCTAssertEqual(
                    directBounds.minX, renderedBounds.minX, accuracy: 2,
                    "\(primitive) at \(scale)x")
                XCTAssertEqual(
                    directBounds.minY, renderedBounds.minY, accuracy: 2,
                    "\(primitive) at \(scale)x")
                XCTAssertEqual(
                    directBounds.maxX, renderedBounds.maxX, accuracy: 2,
                    "\(primitive) at \(scale)x")
                XCTAssertEqual(
                    directBounds.maxY, renderedBounds.maxY, accuracy: 2,
                    "\(primitive) at \(scale)x")
                // The diagonal's asymmetric end points make reflection visible.
                let directPixels = bytes(direct)
                let renderedPixels = bytes(rendered)
                let alphaError = stride(from: 3, to: directPixels.count, by: 4).reduce(0) {
                    $0 + abs(Int(directPixels[$1]) - Int(renderedPixels[$1]))
                }
                let coverage = stride(from: 3, to: directPixels.count, by: 4).reduce(0) {
                    $0 + Int(directPixels[$1])
                }
                XCTAssertLessThan(
                    Double(alphaError) / Double(coverage), 0.06,
                    "\(primitive) orientation/geometry differs at \(scale)x")
            }
        }
    }

    func testNativeCanvasReleasesCounterOwnerWhenDetached() {
        weak var reference: DrawingProbeState?
        autoreleasepool {
            let state = DrawingProbeState()
            reference = state
            let view = DrawingProbeCGView(frame: .zero)
            view.state = state
            view.state = nil
        }
        XCTAssertNil(reference)
    }

    func testBitmapLayoutRejectsInvalidAndOversizedAllocations() throws {
        let size = DrawingProbeSession.contentSize
        for scale in [CGFloat(1), 2] {
            let layout = try DrawingProbeBitmap.layout(size: size, scale: scale)
            XCTAssertEqual(layout.width, Int(664 * scale))
            XCTAssertEqual(layout.height, Int(357 * scale))
            XCTAssertEqual(layout.bytesPerRow, layout.width * 4)
            XCTAssertEqual(layout.byteCount, layout.width * layout.height * 4)
            XCTAssertLessThanOrEqual(layout.byteCount, DrawingProbeBitmap.maximumBytes)
        }
        for invalidScale in [CGFloat(0), -1, .nan, .infinity, 8, .greatestFiniteMagnitude] {
            XCTAssertThrowsError(try DrawingProbeBitmap.layout(size: size, scale: invalidScale))
        }
        for invalidSize in [
            CGSize.zero, CGSize(width: -1, height: 10),
            CGSize(width: 10, height: -.infinity),
            CGSize(width: CGFloat.nan, height: 10),
            CGSize(width: 665, height: 357),
            CGSize(width: 664, height: 358),
        ] {
            XCTAssertThrowsError(try DrawingProbeBitmap.layout(size: invalidSize, scale: 1))
        }
        let mismatched = DrawingProbeBitmap.Layout(
            width: 1, height: 1, bytesPerRow: 4, byteCount: 4)
        XCTAssertThrowsError(
            try DrawingProbeBitmap.render(
                primitive: .line, size: size, scale: 1, layout: mismatched))
    }

    func testCPUImageMatchesNativeCoreGraphicsPixelsAtBothScales() throws {
        for scale in [CGFloat(1), 2] {
            let size = DrawingProbeSession.contentSize
            let layout = try DrawingProbeBitmap.layout(size: size, scale: scale)
            for primitive in [
                DrawingProbeSession.Primitive.empty, .line, .clippedLine,
                .chartPath, .solidFill, .linearGradient, .radialGradient,
            ] {
                let image = try DrawingProbeBitmap.render(
                    primitive: primitive, size: size, scale: scale, layout: layout)
                XCTAssertEqual(image.width, layout.width)
                XCTAssertEqual(image.height, layout.height)
                let reference = try bitmap(scale: scale, topLeft: true)
                DrawingProbeArtwork.draw(primitive, in: reference)
                let provider = try XCTUnwrap(image.dataProvider)
                let data = try XCTUnwrap(provider.data) as Data
                XCTAssertEqual(Array(data), bytes(reference), "\(primitive) at \(scale)x")
            }
        }
    }

    func testBitmapLayerGateAcknowledgmentPixelsAndRelease() throws {
        let state = DrawingProbeState()
        let view = DrawingProbeBitmapView(
            frame: CGRect(
                origin: .zero,
                size: DrawingProbeSession.contentSize))
        view.state = state
        view.primitive = .line
        XCTAssertTrue(view.wantsUpdateLayer)
        XCTAssertFalse(view.canDrawSubviewsIntoLayer)
        XCTAssertEqual(view.layerContentsRedrawPolicy, .onSetNeedsDisplay)
        view.updateLayer()
        XCTAssertEqual(state.acknowledgedRevision, 0)
        XCTAssertEqual(state.bitmapUpdateLayerCalls, 1)
        XCTAssertEqual(state.bitmapImagesCreated, 0)
        XCTAssertEqual(state.bitmapPeakScratchBytes, 0)
        XCTAssertNil(view.layer?.contents)

        view.enabled = true
        view.revision = 1
        view.updateLayer()
        XCTAssertEqual(state.acknowledgedRevision, 1)
        XCTAssertEqual(state.bitmapImagesCreated, 1)
        XCTAssertEqual(state.nonemptyDrawCalls, 1)
        XCTAssertEqual(state.bitmapScratchBytes, 0)
        XCTAssertEqual(state.bitmapImageBytes, 664 * 357 * 4)
        XCTAssertEqual(view.layer?.contentsScale, 1)
        let contents = try XCTUnwrap(view.layer?.contents)
        XCTAssertEqual(CFGetTypeID(contents as CFTypeRef), CGImage.typeID)
        XCTAssertEqual(state.bitmapUnexpectedDrawCalls, 0)
        XCTAssertEqual(state.bitmapFailures, 0)

        view.clearContent()
        XCTAssertNil(view.layer?.contents)
        XCTAssertNil(view.state)
        XCTAssertEqual(state.bitmapImageBytes, 0)
        XCTAssertEqual(state.bitmapScratchBytes, 0)
        let calls = state.drawCalls
        view.updateLayer()
        XCTAssertEqual(state.drawCalls, calls, "A detached view cannot acknowledge more frames")
    }

    func testBitmapRejectsNativeContextFallbackWithoutAcknowledgingDraw() {
        let state = DrawingProbeState()
        let view = DrawingProbeBitmapView(frame: .zero)
        view.state = state
        view.draw(.zero)
        XCTAssertEqual(state.bitmapUnexpectedDrawCalls, 1)
        XCTAssertEqual(state.bitmapFailures, 1)
        XCTAssertNotNil(state.bitmapError)
        XCTAssertEqual(state.acknowledgedRevision, -1)
        view.clearContent()
    }

    func testBitmapRejectsInvalidGeometryWithoutAcknowledgingFrame() {
        let state = DrawingProbeState()
        let view = DrawingProbeBitmapView(frame: .zero)
        view.state = state
        view.enabled = true
        view.revision = 1
        view.updateLayer()
        XCTAssertEqual(state.bitmapFailures, 1)
        XCTAssertEqual(state.bitmapImagesCreated, 0)
        XCTAssertEqual(state.acknowledgedRevision, -1)
        XCTAssertNil(view.layer?.contents)
        view.clearContent()
    }

    private func bitmap(scale: CGFloat, topLeft: Bool) throws -> CGContext {
        let size = DrawingProbeSession.contentSize
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        if topLeft {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        return context
    }

    private func bytes(_ context: CGContext) -> [UInt8] {
        Array(
            UnsafeBufferPointer(
                start: context.data!.assumingMemoryBound(to: UInt8.self),
                count: context.bytesPerRow * context.height))
    }

    private func alphaBounds(_ context: CGContext) throws -> CGRect {
        let pixels = bytes(context)
        var minX = context.width
        var maxX = -1
        var minY = context.height
        var maxY = -1
        for y in 0..<context.height {
            for x in 0..<context.width where pixels[y * context.bytesPerRow + x * 4 + 3] > 8 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            throw NSError(
                domain: "DrawingProbeSessionTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected visible drawing pixels"])
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
