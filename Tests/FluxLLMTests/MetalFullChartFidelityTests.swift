import AppKit
import Dispatch
import Metal
import SwiftUI
import XCTest

@testable import FluxLLM

/// Native fidelity is deliberately independent of resource qualification. A
/// mismatch writes all evidence and fails this opt-in test; it does not prevent
/// the performance runner from collecting CPU and GPU measurements separately.
@MainActor
final class MetalFullChartFidelityTests: XCTestCase {
    private typealias Scene = MetalFullChartScene
    private typealias Renderer = MetalFullChartRenderer
    private let size = CGSize(width: 360, height: 290)
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testStaticChartAgainstIndependentCanvasOptIn() throws {
        let gate = try nativeGate()
        var results: [[String: Any]] = []
        var deviceName: String?
        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                try gate.summary(
                    status: "unavailable", cases: [], device: nil,
                    error: "Metal device unavailable")
                throw XCTSkip("Metal unavailable; full-chart fidelity was not evaluated")
            }
            deviceName = device.name
            let renderer = try Renderer(device: device)
            for scale in [CGFloat(1), 2] {
                results.append(try calibrate(renderer, scale: scale, gate: gate))
            }
            for scale in [CGFloat(1), 2] {
                for compact in [false, true] {
                    for contrast in [false, true] {
                        for dark in [false, true] {
                            let fixture = Fixture(
                                size: size, origin: origin,
                                compact: compact, contrast: contrast, dark: dark)
                            let scene = Scene.make(
                                frame: fixture.frame, lanes: fixture.lanes,
                                laneColors: fixture.colors, segments: fixture.segments,
                                overflow: fixture.overflow, style: fixture.style)
                            let label =
                                "chart-compact\(compact)-contrast\(contrast)-dark\(dark)-s\(Int(scale))"
                            try renderer.update(scene: scene)
                            let before = renderer.statistics
                            let actual = try render(renderer, scale: scale) { command, texture in
                                try renderer.encode(
                                    into: command, target: texture, pointSize: self.size)
                            }
                            let expected = try canvas(scale: scale) { context in
                                Self.drawReference(fixture, in: &context)
                            }
                            var result = try comparison(
                                actual, expected: expected, label: label, gate: gate)
                            result["scale"] = scale
                            result["compact"] = compact
                            result["increased_contrast"] = contrast
                            result["dark"] = dark
                            result["scene_primitive_count"] = scene.primitives.count
                            result["retained_bytes"] = renderer.statistics.retainedBytes
                            result["unchanged_uploads_during_frame"] =
                                renderer.statistics.uploadCount == before.uploadCount
                            result["in_flight_after_completion"] =
                                renderer.statistics.inFlightFrames
                            results.append(result)
                        }
                    }
                }
                results.append(try compareCursor(renderer, scale: scale, gate: gate))
                results.append(try comparePrimitiveEdges(renderer, scale: scale, gate: gate))
            }
            let failed = results.filter { ($0["within_gate"] as? Bool) != true }.count
            try gate.summary(
                status: failed == 0 ? "passed" : "failed", cases: results,
                device: device.name, error: nil)
            XCTAssertEqual(
                failed, 0, "Static chart strict pixel gate failed; evidence: \(gate.directory.path)"
            )
        } catch {
            try gate.failureIfAbsent(error, cases: results, device: deviceName)
            throw error
        }
    }

    /// Inputs are shared, drawing operations are not. The reference uses the
    /// original cubic Paths, Canvas blur, gradients, dash and rounded clipping;
    /// it never reads candidate primitives, flattening, tiles or shader helpers.
    private struct Fixture {
        let frame: LuminousChartGeometryCache.Frame
        let lanes: [RequestLane]
        let colors: [UUID: SIMD4<Float>]
        let segments: [RequestRailGeometry.Segment]
        let overflow: [RequestRailGeometry.OverflowSegment]
        let style: Scene.Style

        init(size: CGSize, origin: Date, compact: Bool, contrast: Bool, dark: Bool) {
            let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            let now = origin.addingTimeInterval(120)
            let observations: [TimeSeriesPoint] = (0...60).map { index in
                let value =
                    index < 15
                    ? Double(index * 3)
                    : index < 35
                        ? Double(75 - index)
                        : index < 50 ? Double(index - 30) : Double(100 - index)
                return .init(
                    timestamp: origin.addingTimeInterval(60 + Double(index)),
                    value: value, isAvailable: index != 23 && index != 24)
            }
            let generated = ChartDisplayHistory(samples: observations, now: now, duration: 60)
            let gpu = ChartDisplayHistory(
                samples: observations.map {
                    .init(
                        timestamp: $0.timestamp, value: 100 - $0.value, isAvailable: $0.isAvailable)
                }, now: now, duration: 60)
            let tools: [UUID: ToolActivityHistory] = Dictionary(
                uniqueKeysWithValues: [first, second].enumerated().map { index, id in
                    (
                        id,
                        ToolActivityHistory(
                            events: [
                                .init(
                                    kind: .call,
                                    timestamp: origin.addingTimeInterval(75 + Double(index)),
                                    requestID: id),
                                .init(
                                    kind: .call,
                                    timestamp: origin.addingTimeInterval(115 + Double(index)),
                                    requestID: id),
                                .init(
                                    kind: .resultSubmission,
                                    timestamp: origin.addingTimeInterval(116 + Double(index)),
                                    requestID: id),
                            ], observations: observations, now: now, duration: 60)
                    )
                })
            frame = LuminousChartGeometryCache().frame(
                for: .init(
                    publicationID: UUID(), now: now, duration: 60, size: size,
                    compact: compact, hasTools: true, tokenUpperBound: 100, toolUpperBound: 120),
                throughput: generated, gpu: gpu, requestTools: tools)
            lanes = [
                .init(id: first, startedAt: origin.addingTimeInterval(72.35)),
                .init(
                    id: second, startedAt: origin.addingTimeInterval(94.1),
                    endedAt: origin.addingTimeInterval(116.65)),
            ]
            colors = [first: SIMD4(0.95, 0.28, 0.12, 1), second: SIMD4(0.3, 0.6, 0.95, 1)]
            segments = RequestRailGeometry.layout(
                lanes: lanes,
                assignments: [
                    first: .init(track: 0, colorIndex: 0),
                    second: .init(track: 1, colorIndex: 1),
                ],
                now: now, duration: 60, rect: frame.layout.lanes)
            overflow =
                compact
                ? []
                : [
                    .init(
                        rect: CGRect(
                            x: frame.layout.lanes.minX + 105.35,
                            y: frame.layout.lanes.minY + 73.5, width: 93.4, height: 7), count: 9)
                ]
            style = .init(
                generatedColor: SIMD4(0.05, 0.86, 0.67, 1),
                deviceColor: SIMD4(0.38, 0.35, 0.98, 1),
                backgroundColor: dark ? SIMD4(0.12, 0.12, 0.14, 1) : SIMD4(0.95, 0.95, 0.96, 1),
                primaryColor: dark ? SIMD4(1, 1, 1, 1) : SIMD4(0, 0, 0, 1),
                secondaryColor: dark ? SIMD4(1, 1, 1, 0.55) : SIMD4(0, 0, 0, 0.55),
                compact: compact, hasEffects: !contrast,
                increasedContrast: contrast, isDark: dark)
        }
    }

    private static func drawReference(_ fixture: Fixture, in context: inout GraphicsContext) {
        let layout = fixture.frame.layout
        let style = fixture.style
        var grid = Path()
        for fraction in [0.0, 0.5, 1.0] {
            let y = layout.main.minY + fraction * layout.main.height
            grid.move(to: CGPoint(x: layout.main.minX, y: y))
            grid.addLine(to: CGPoint(x: layout.main.maxX, y: y))
        }
        grid.move(to: CGPoint(x: layout.tools.minX, y: layout.tools.maxY))
        grid.addLine(to: CGPoint(x: layout.tools.maxX, y: layout.tools.maxY))
        context.stroke(
            grid,
            with: .color(color(style.primaryColor).opacity(style.increasedContrast ? 0.3 : 0.1)),
            lineWidth: 0.6)
        referenceSeries(
            fixture.frame.device, color: color(style.deviceColor), fillOpacity: 0.14,
            rect: layout.main, style: style, in: &context)
        referenceSeries(
            fixture.frame.generated, color: color(style.generatedColor), fillOpacity: 0.25,
            rect: layout.main, style: style, in: &context)
        referenceEndpoint(
            fixture.frame.generatedEndpoint, color: color(style.generatedColor), style: style,
            in: &context)
        referenceEndpoint(
            fixture.frame.deviceEndpoint, color: color(style.deviceColor), style: style,
            in: &context)
        for lane in fixture.lanes {
            guard let track = fixture.frame.requestTools[lane.id],
                let rgba = fixture.colors[lane.id]
            else { continue }
            for segment in track.segments {
                context.stroke(
                    segment.trace, with: .color(color(rgba)),
                    style: StrokeStyle(
                        lineWidth: style.increasedContrast ? 2.2 : 1.6, lineCap: .round,
                        lineJoin: .round, dash: [4, 3]))
            }
            for diamond in track.resultDiamonds { context.fill(diamond, with: .color(color(rgba))) }
        }
        guard !style.compact else { return }
        for segment in fixture.segments {
            let bar = segment.rect
            let tint = color(fixture.colors[segment.lane.id]!)
            let shape = Path(roundedRect: bar, cornerRadius: segment.cornerRadius, style: .circular)
            if style.increasedContrast {
                context.fill(shape, with: .color(tint))
            } else {
                context.fill(
                    shape,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: tint.opacity(0.42), location: 0),
                            .init(color: tint.opacity(segment.isLive ? 1 : 0.83), location: 0.5),
                            .init(color: tint.opacity(segment.isLive ? 1 : 0.88), location: 1),
                        ]), startPoint: CGPoint(x: bar.minX, y: bar.midY),
                        endPoint: CGPoint(x: bar.maxX, y: bar.midY)))
            }
            if segment.isLive {
                var head = context
                head.clip(to: shape)
                let point = CGPoint(x: bar.maxX - segment.cornerRadius, y: bar.midY)
                head.fill(circle(point, 3.5), with: .color(tint))
                head.fill(circle(point, 1.2), with: .color(.white))
            }
        }
        for overflow in fixture.overflow {
            context.fill(
                Path(
                    roundedRect: overflow.rect, cornerRadius: min(3.5, overflow.rect.width / 2),
                    style: .circular),
                with: .color(
                    color(style.secondaryColor).opacity(style.increasedContrast ? 0.8 : 0.3)))
        }
        // Labels are now SwiftUI overlays and intentionally outside both images.
    }

    private static func referenceSeries(
        _ segments: [LuminousChartGeometryCache.Segment], color: Color, fillOpacity: Double,
        rect: CGRect, style: Scene.Style, in context: inout GraphicsContext
    ) {
        for segment in segments {
            guard let first = segment.points.first else { continue }
            if style.hasEffects, let area = segment.area {
                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: color.opacity(fillOpacity), location: 0),
                            .init(color: color.opacity(0.01), location: 1),
                        ]), startPoint: CGPoint(x: 0, y: rect.minY),
                        endPoint: CGPoint(x: 0, y: rect.maxY)))
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: style.compact ? 2.5 : 3))
                    glow.stroke(
                        segment.trace, with: .color(color.opacity(style.isDark ? 0.35 : 0.24)),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                }
            }
            context.stroke(
                segment.trace, with: .color(color),
                style: StrokeStyle(
                    lineWidth: style.increasedContrast ? 2.8 : (style.compact ? 2.2 : 2.7),
                    lineCap: .round, lineJoin: .round))
            if segment.points.count == 1 {
                referenceEndpoint(first, color: color, style: style, in: &context)
            }
        }
    }

    private static func referenceEndpoint(
        _ point: CGPoint?, color: Color, style: Scene.Style,
        in context: inout GraphicsContext
    ) {
        guard let point else { return }
        if style.hasEffects { context.fill(circle(point, 6), with: .color(color.opacity(0.13))) }
        context.fill(circle(point, 2.5), with: .color(Self.color(style.backgroundColor)))
        context.stroke(circle(point, 2.5), with: .color(color), lineWidth: 1.7)
    }

    private func compareCursor(_ renderer: Renderer, scale: CGFloat, gate: Gate) throws -> [String:
        Any]
    {
        let fixture = Fixture(
            size: size, origin: origin, compact: false, contrast: false, dark: true)
        let x: CGFloat = 245.375
        let scene = Scene.cursor(frame: fixture.frame, x: x, style: fixture.style)
        try renderer.update(scene: scene)
        let actual = try render(renderer, scale: scale) {
            try renderer.encode(into: $0, target: $1, pointSize: self.size)
        }
        let expected = try canvas(scale: scale) { context in
            var path = Path()
            path.move(to: CGPoint(x: x, y: fixture.frame.layout.main.minY))
            path.addLine(to: CGPoint(x: x, y: fixture.frame.layout.tools.maxY))
            context.stroke(
                path, with: .color(Self.color(fixture.style.secondaryColor).opacity(0.55)),
                lineWidth: 0.8)
            for (segments, rgba) in [
                (fixture.frame.generated, fixture.style.generatedColor),
                (fixture.frame.device, fixture.style.deviceColor),
            ] {
                if let y = segments.reversed().lazy.compactMap({ $0.inspectedY(atX: x) }).first {
                    Self.referenceEndpoint(
                        CGPoint(x: x, y: y), color: Self.color(rgba),
                        style: fixture.style, in: &context)
                }
            }
        }
        return try comparison(
            actual, expected: expected, label: "cursor-s\(Int(scale))", gate: gate)
    }

    private func comparePrimitiveEdges(_ renderer: Renderer, scale: CGFloat, gate: Gate) throws
        -> [String: Any]
    {
        let tint = SIMD4<Float>(0.8, 0.2, 0.6, 0.55)
        let points = [
            CGPoint(x: 40.25, y: 45.5), CGPoint(x: 68.375, y: 52.125),
            CGPoint(x: 68.375, y: 73.75), CGPoint(x: 92.5, y: 73.75),
        ]
        let bar = CGRect(x: 118.25, y: 46.375, width: 35.5, height: 7)
        let marker = CGRect(x: 140.5, y: 45.375, width: 19.25, height: 11.5)
        let scene = Scene(
            size: size,
            primitives: [
                .init(
                    shape: .polyline(points), paint: .solid(tint),
                    stroke: .init(width: 2.2, dash: [4, 3])),
                .init(
                    shape: .ellipse(marker), paint: .solid(tint),
                    clip: .init(rect: bar, radius: 3.5)),
                .init(
                    shape: .ellipse(CGRect(x: 180.25, y: 40.5, width: 5, height: 5)),
                    paint: .solid(tint), stroke: .init(width: 1.7)),
            ])
        try renderer.update(scene: scene)
        let actual = try render(renderer, scale: scale) {
            try renderer.encode(into: $0, target: $1, pointSize: self.size)
        }
        let expected = try canvas(scale: scale) { context in
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path, with: .color(Self.color(tint)),
                style: StrokeStyle(
                    lineWidth: 2.2, lineCap: .round, lineJoin: .round, dash: [4, 3]))
            var clipped = context
            clipped.clip(to: Path(roundedRect: bar, cornerRadius: 3.5, style: .circular))
            clipped.fill(Path(ellipseIn: marker), with: .color(Self.color(tint)))
            context.stroke(
                Path(ellipseIn: CGRect(x: 180.25, y: 40.5, width: 5, height: 5)),
                with: .color(Self.color(tint)), lineWidth: 1.7)
        }
        return try comparison(
            actual, expected: expected, label: "fractional-dash-clip-ring-s\(Int(scale))",
            gate: gate)
    }

    private static func color(_ rgba: SIMD4<Float>) -> Color {
        Color(
            .sRGB, red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z),
            opacity: Double(rgba.w))
    }
    private static func circle(_ point: CGPoint, _ radius: CGFloat) -> Path {
        Path(
            ellipseIn: CGRect(
                x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    // MARK: Independent Metal and Canvas channel/orientation calibration

    private struct CalibrationVertex {
        let point: SIMD2<Float>
        let color: SIMD4<Float>
    }

    private func calibrate(_ renderer: Renderer, scale: CGFloat, gate: Gate) throws -> [String: Any]
    {
        let library = try renderer.device.makeLibrary(
            source: """
                #include <metal_stdlib>
                using namespace metal;
                struct Input { float2 point; float4 color; };
                struct Output { float4 position [[position]]; float4 color; };
                vertex Output calibrationVertex(uint id [[vertex_id]], constant Input *v [[buffer(0)]],
                                                constant float2 &size [[buffer(1)]]) {
                    return { float4(v[id].point.x / size.x * 2 - 1, 1 - v[id].point.y / size.y * 2, 0, 1), v[id].color };
                }
                fragment float4 calibrationFragment(Output in [[stage_in]]) { return in.color; }
                """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "calibrationVertex"))
        descriptor.fragmentFunction = try XCTUnwrap(
            library.makeFunction(name: "calibrationFragment"))
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try renderer.device.makeRenderPipelineState(descriptor: descriptor)
        var vertices: [CalibrationVertex] = []
        for (rect, color) in [
            (CGRect(x: 7, y: 11, width: 9, height: 13), SIMD4<Float>(1, 0, 0, 1)),
            (CGRect(x: 75, y: 61, width: 11, height: 9), SIMD4<Float>(0, 0, 1, 1)),
            (CGRect(x: 39, y: 27, width: 15, height: 11), SIMD4<Float>(0.05, 0.35, 0.15, 0.5)),
        ] {
            for point in [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
            ] {
                vertices.append(.init(point: SIMD2(Float(point.x), Float(point.y)), color: color))
            }
        }
        let actual = try render(renderer, scale: scale) { command, texture in
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            vertices.withUnsafeBytes {
                encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            }
            var pointSize = SIMD2(Float(size.width), Float(size.height))
            encoder.setVertexBytes(&pointSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()
        }
        let expected = try MetalArrivalBurstCanvasReference.renderCalibration(
            size: size, scale: scale)
        var result = try comparison(
            actual, expected: expected, label: "calibration-s\(Int(scale))", gate: gate)
        var verified = true
        var samples: [[String: Any]] = []
        for (name, context) in [("metal", actual), ("canvas", expected)] {
            for (point, expectedRGBA) in [
                (CGPoint(x: 11, y: 17), [255, 0, 0, 255]),
                (CGPoint(x: 80, y: 65), [0, 0, 255, 255]),
                (CGPoint(x: 45, y: 32), [13, 89, 38, 128]),
                (CGPoint(x: 11, y: 70), [0, 0, 0, 0]),
                (CGPoint(x: 80, y: 22), [0, 0, 0, 0]),
            ] {
                let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                let offset = Int(point.y * scale) * context.bytesPerRow + Int(point.x * scale) * 4
                let rgba = (0..<4).map { Int(bytes[offset + $0]) }
                verified = verified && zip(rgba, expectedRGBA).allSatisfy { abs($0 - $1) <= 1 }
                samples.append([
                    "producer": name, "xy": [point.x, point.y],
                    "expected_rgba": expectedRGBA, "actual_rgba": rgba,
                ])
            }
        }
        let coverage = Int(381 * scale * scale)
        verified =
            verified && (result["actual_nonzero_alpha_pixels"] as? Int == coverage)
            && (result["expected_nonzero_alpha_pixels"] as? Int == coverage)
        result["fixture_samples"] = samples
        result["fixture_verified"] = verified
        guard verified, result["within_gate"] as? Bool == true else {
            try gate.summary(
                status: "calibration_failed", cases: [result], device: renderer.device.name,
                error:
                    "Asymmetric independent channel, row, premultiplication or coverage calibration failed"
            )
            throw Failure.failed("Full-chart native readback calibration failed")
        }
        return result
    }

    // MARK: Bounded execution and unmodified premultiplied readback

    private final class Resources: @unchecked Sendable {
        let renderer: Renderer
        let texture: any MTLTexture
        let buffer: any MTLBuffer
        init(_ renderer: Renderer, _ texture: any MTLTexture, _ buffer: any MTLBuffer) {
            self.renderer = renderer
            self.texture = texture
            self.buffer = buffer
        }
    }

    private func render(
        _ renderer: Renderer, scale: CGFloat,
        encode: (any MTLCommandBuffer, any MTLTexture) throws -> Void
    ) throws -> CGContext {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(size.width * scale),
            height: Int(size.height * scale), mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let rowBytes = (texture.width * 4 + 255) / 256 * 256
        let buffer = try XCTUnwrap(
            renderer.device.makeBuffer(
                length: rowBytes * texture.height, options: .storageModeShared))
        let queue = try XCTUnwrap(renderer.device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        defer { if command.status == .notEnqueued { command.commit() } }
        try encode(command, texture)
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        let complete = DispatchSemaphore(value: 0)
        let resources = Resources(renderer, texture, buffer)
        command.addCompletedHandler { _ in withExtendedLifetime(resources) { complete.signal() } }
        command.commit()
        guard complete.wait(timeout: .now() + 5) == .success else {
            throw Failure.failed("GPU completion timeout")
        }
        guard command.status == .completed, command.error == nil else {
            throw Failure.failed("GPU command failed: \(String(describing: command.error))")
        }
        let result = try bitmap(width: texture.width, height: texture.height)
        let target = try XCTUnwrap(result.data).assumingMemoryBound(to: UInt8.self)
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        for y in 0..<texture.height {
            for x in 0..<texture.width {
                let from = y * rowBytes + x * 4
                let to = y * result.bytesPerRow + x * 4
                target[to] = source[from + 2]
                target[to + 1] = source[from + 1]
                target[to + 2] = source[from]
                target[to + 3] = source[from + 3]
            }
        }
        return result
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
    }

    private func canvas(scale: CGFloat, drawing: @escaping (inout GraphicsContext) -> Void) throws
        -> CGContext
    {
        let context = try bitmap(width: Int(size.width * scale), height: Int(size.height * scale))
        context.clear(
            CGRect(
                origin: .zero,
                size: CGSize(width: CGFloat(context.width), height: CGFloat(context.height))))
        context.scaleBy(x: scale, y: scale)
        let renderer = ImageRenderer(content: Canvas { context, _ in drawing(&context) })
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        renderer.render(rasterizationScale: scale) { _, draw in draw(context) }
        return context
    }

    private func comparison(
        _ actual: CGContext, expected: CGContext,
        label: String, gate: Gate
    ) throws -> [String: Any] {
        guard actual.width == expected.width, actual.height == expected.height else {
            throw Failure.failed("Mismatched fidelity dimensions")
        }
        let a = try XCTUnwrap(actual.data).assumingMemoryBound(to: UInt8.self)
        let b = try XCTUnwrap(expected.data).assumingMemoryBound(to: UInt8.self)
        let differenceImage = try bitmap(width: actual.width, height: actual.height)
        let difference = try XCTUnwrap(differenceImage.data).assumingMemoryBound(to: UInt8.self)
        var maximum = [Int](repeating: 0, count: 4)
        var sums = [UInt64](repeating: 0, count: 4)
        var differing = 0
        var actualVisible = 0
        var expectedVisible = 0
        for y in 0..<actual.height {
            for x in 0..<actual.width {
                let ai = y * actual.bytesPerRow + x * 4
                let bi = y * expected.bytesPerRow + x * 4
                let di = y * differenceImage.bytesPerRow + x * 4
                if a[ai + 3] > 0 { actualVisible += 1 }
                if b[bi + 3] > 0 { expectedVisible += 1 }
                var different = false
                for channel in 0..<4 {
                    let delta = abs(Int(a[ai + channel]) - Int(b[bi + channel]))
                    maximum[channel] = max(maximum[channel], delta)
                    sums[channel] += UInt64(delta)
                    different = different || delta > 0
                    difference[di + channel] = UInt8(delta)
                }
                difference[di + 3] = 255
                if different { differing += 1 }
            }
        }
        let visible = actualVisible > 0 && expectedVisible > 0
        let result: [String: Any] = [
            "label": label, "width": actual.width, "height": actual.height,
            "maximum_rgba_difference": maximum, "absolute_rgba_difference_sums": sums,
            "differing_pixels": differing, "actual_nonzero_alpha_pixels": actualVisible,
            "expected_nonzero_alpha_pixels": expectedVisible, "visible_content_verified": visible,
            "maximum_allowed_channel_difference": 2,
            "within_gate": visible && maximum.allSatisfy { $0 <= 2 },
            "format": "sRGB encoded premultiplied RGBA8",
            "row_order": "upper-left row first, direct calibrated mapping",
        ]
        try gate.save(actual, name: "\(label)-metal.png")
        try gate.save(expected, name: "\(label)-canvas.png")
        try gate.save(differenceImage, name: "\(label)-absolute-difference.png")
        try gate.write(result, name: "\(label)-metrics.json")
        return result
    }

    private enum Failure: Error { case failed(String) }
    private struct Gate {
        let directory: URL
        func write(_ value: [String: Any], name: String) throws {
            try JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys]
            )
            .write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
        }
        func summary(status: String, cases: [[String: Any]], device: String?, error: String?) throws
        {
            try write(
                [
                    "schema_version": 1, "status": status, "cases": cases,
                    "device": device as Any? ?? NSNull(), "error": error as Any? ?? NSNull(),
                    "maximum_allowed_channel_difference": 2,
                    "scope":
                        "Static full chart and cursor against original Canvas operations; excludes SwiftUI text and animated lifecycle effects; not resource acceptance",
                ],
                name: "result.json")
        }
        func failureIfAbsent(_ error: any Error, cases: [[String: Any]], device: String?) throws {
            if !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("result.json").path)
            {
                try summary(
                    status: "failed", cases: cases, device: device, error: String(describing: error)
                )
            }
        }
        func save(_ context: CGContext, name: String) throws {
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
        }
    }

    private func nativeGate() throws -> Gate {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLUXLLM_FULL_METAL_FIDELITY"] == "1" else {
            throw XCTSkip(
                "Set FLUXLLM_FULL_METAL_FIDELITY=1 and FLUXLLM_FULL_METAL_FIDELITY_OUTPUT for the native pixel gate"
            )
        }
        guard let path = environment["FLUXLLM_FULL_METAL_FIDELITY_OUTPUT"], !path.isEmpty else {
            throw Failure.failed("Explicit FLUXLLM_FULL_METAL_FIDELITY_OUTPUT is required")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ignored = repository.appendingPathComponent(".performance-results", isDirectory: true)
            .resolvingSymlinksInPath()
        let requested =
            (path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : repository.appendingPathComponent(path, isDirectory: true)).standardizedFileURL
            .resolvingSymlinksInPath()
        guard requested.path == ignored.path || requested.path.hasPrefix(ignored.path + "/") else {
            throw Failure.failed(
                "Native pixel results must be under the ignored .performance-results directory")
        }
        let directory = requested.appendingPathComponent(
            "static-chart-fidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("FLUXLLM_FULL_METAL_FIDELITY_OUTPUT=\(directory.path)")
        return Gate(directory: directory)
    }
}
