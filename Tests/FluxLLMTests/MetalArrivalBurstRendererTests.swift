import AppKit
import Dispatch
import Metal
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class MetalArrivalBurstRendererTests: XCTestCase {
    private typealias Renderer = MetalArrivalBurstRenderer
    private let size = CGSize(width: 112, height: 88)
    private let origin = CGPoint(x: 55.25, y: 43.375)
    private let colors: [SIMD4<Float>] = [
        SIMD4(0, 0.87, 1, 1), SIMD4(1, 0.08, 0.56, 0.55),
    ]

    func testUnavailableDeviceFailsExplicitly() {
        XCTAssertThrowsError(try Renderer(device: nil))
    }

    func testDescriptorUpdatesAreBoundedUnchangedInputsDoNotUploadAndInvalidUpdatesPreserveState()
        throws
    {
        let renderer = try makeRenderer()
        let bursts = (0..<Renderer.maximumBursts).map { burst(seed: UInt64($0), index: $0) }
        try renderer.update(bursts: bursts)
        let populated = renderer.statistics
        XCTAssertEqual(populated.elementCount, bursts.count)
        XCTAssertEqual(populated.descriptorUploads, 1)
        XCTAssertEqual(populated.retainedDescriptorBuffers, 1)
        XCTAssertGreaterThan(populated.retainedDescriptorBytes, 0)
        XCTAssertEqual(populated.encodedFrames, 0)
        XCTAssertEqual(populated.inFlightFrames, 0)
        for _ in 0..<8 { try renderer.update(bursts: bursts) }
        XCTAssertEqual(renderer.statistics.descriptorUploads, populated.descriptorUploads)
        XCTAssertEqual(
            renderer.statistics.retainedDescriptorBytes, populated.retainedDescriptorBytes)

        XCTAssertThrowsError(
            try renderer.update(
                bursts: bursts + [
                    burst(seed: UInt64(Renderer.maximumBursts), index: Renderer.maximumBursts)
                ]))
        XCTAssertThrowsError(try renderer.update(bursts: [burst(seed: 0, startTime: .nan)]))
        XCTAssertThrowsError(
            try renderer.update(bursts: [burst(seed: 0, point: CGPoint(x: CGFloat.infinity, y: 0))])
        )
        XCTAssertThrowsError(
            try renderer.update(bursts: [burst(seed: 0, color: SIMD4(0, 1, 0, 2))]))
        XCTAssertEqual(renderer.statistics.elementCount, populated.elementCount)
        XCTAssertEqual(renderer.statistics.descriptorUploads, populated.descriptorUploads)
        XCTAssertEqual(
            renderer.statistics.retainedDescriptorBytes, populated.retainedDescriptorBytes)
        for index in 0..<12 {
            try renderer.update(bursts: [burst(seed: UInt64(index + 30), index: index)])
            XCTAssertEqual(
                renderer.statistics.retainedDescriptorBuffers, 1,
                "Replacing unsubmitted descriptors must release the previous allocation")
            XCTAssertLessThanOrEqual(
                renderer.statistics.retainedDescriptorBytes, populated.retainedDescriptorBytes)
        }
        renderer.removeAll()
        XCTAssertEqual(renderer.statistics.elementCount, 0)
        XCTAssertEqual(renderer.statistics.retainedDescriptorBuffers, 0)
        XCTAssertEqual(renderer.statistics.retainedDescriptorBytes, 0)
    }

    func testIdleRendererAndItsDescriptorStorageReleaseWithTheOwner() throws {
        weak var released: Renderer?
        do {
            let renderer = try makeRenderer()
            try renderer.update(bursts: [burst(seed: 2)])
            XCTAssertGreaterThan(renderer.statistics.retainedDescriptorBytes, 0)
            released = renderer
        }
        XCTAssertNil(released, "Descriptor ownership must not retain its renderer")
    }

    func testOrderedMixedPublicationsRejectDuplicateAndExcessTwinklesWithoutChangingState() throws {
        let renderer = try makeRenderer()
        let first = Renderer.Element.burst(burst(seed: 1))
        let glint = Renderer.Element.twinkle(twinkle(index: 1, star: true, atLeftEdge: true))
        let second = Renderer.Element.burst(burst(seed: 2, index: 2))
        try renderer.update(elements: [first, glint, second])
        let original = renderer.statistics
        try renderer.update(elements: [first, glint, second])
        XCTAssertEqual(renderer.statistics.descriptorUploads, original.descriptorUploads)
        try renderer.update(elements: [second, glint, first])
        XCTAssertEqual(
            renderer.statistics.descriptorUploads, original.descriptorUploads + 1,
            "A different source-over order is a distinct immutable publication")
        XCTAssertThrowsError(try renderer.update(elements: [glint, glint]))
        let tooMany = (0...Renderer.maximumTwinkles).map {
            Renderer.Element.twinkle(twinkle(index: $0, star: true, atLeftEdge: true))
        }
        XCTAssertThrowsError(try renderer.update(elements: tooMany))
        XCTAssertEqual(renderer.statistics.elementCount, 3)
        XCTAssertEqual(renderer.statistics.descriptorUploads, original.descriptorUploads + 1)
        XCTAssertEqual(renderer.statistics.retainedDescriptorBuffers, 1)
        try renderer.update(elements: [])
        XCTAssertEqual(renderer.statistics.retainedDescriptorBytes, 0)
    }

    func testNativeReadbackCalibrationOptIn() throws {
        let gate = try nativeGate(name: "calibration")
        let renderer = try makeRenderer(gate: gate)
        var results: [[String: Any]] = []
        for scale in [CGFloat(1), 2] {
            results.append(try calibration(renderer, scale: scale, gate: gate))
        }
        try gate.writeSummary(status: "passed", cases: results, device: renderer.device.name)
    }

    func testNativeBurstFidelityAgainstIndependentCanvasOptIn() throws {
        let gate = try nativeGate(name: "burst-fidelity")
        let renderer = try makeRenderer(gate: gate)
        for scale in [CGFloat(1), 2] { _ = try calibration(renderer, scale: scale, gate: gate) }
        let seeds = try familySeeds()
        var results: [[String: Any]] = []
        for scale in [CGFloat(1), 2] {
            for (family, seed) in seeds {
                let profile = RequestRailEffectProfile(
                    seed: seed, requestDuration: 0, completion: false)
                for progress in [0.025, 0.25, 0.70, 0.94] {
                    for (colorIndex, color) in colors.enumerated() {
                        let fixture = burst(seed: seed, color: color)
                        let elapsed = profile.burstDuration * progress
                        let label = "\(family)-seed\(seed)-p\(progress)-c\(colorIndex)-s\(scale)"
                        results.append(
                            try compare(
                                [fixture], elapsed: elapsed, renderer: renderer,
                                scale: scale, label: label, gate: gate))
                    }
                }
            }
            let first = burst(seed: seeds[0].1, index: 1, color: colors[0])
            let second = burst(
                seed: seeds[1].1, index: 2, startTime: 0.035,
                point: CGPoint(x: origin.x + 5.5, y: origin.y - 2.25), color: colors[1])
            for (order, fixtures) in [[first, second], [second, first]].enumerated() {
                results.append(
                    try compare(
                        fixtures, elapsed: 0.17, renderer: renderer,
                        scale: scale, label: "overlap-order\(order)-s\(scale)", gate: gate))
            }
            for star in [false, true] {
                let glint = twinkle(index: 3, star: star, atLeftEdge: !star)
                results.append(
                    try compareElements(
                        [.twinkle(glint)], elapsed: 0.17, renderer: renderer, scale: scale,
                        label: "clipped-glint-star\(star)-s\(scale)", gate: gate))
                for (order, elements) in [
                    [Renderer.Element.burst(first), .twinkle(glint), .burst(second)],
                    [.burst(second), .twinkle(glint), .burst(first)],
                ].enumerated() {
                    results.append(
                        try compareElements(
                            elements, elapsed: 0.17, renderer: renderer, scale: scale,
                            label: "mixed-order\(order)-star\(star)-s\(scale)", gate: gate))
                }
            }
        }
        let boundary = burst(seed: seeds[2].1)
        for elapsed in [
            -0.01, 0, boundary.profile.burstDuration, boundary.profile.burstDuration + 0.01,
        ] {
            results.append(
                try compare(
                    [boundary], elapsed: elapsed, renderer: renderer,
                    scale: 1, label: "inactive-age\(elapsed)", gate: gate,
                    requiresVisiblePixels: false))
        }
        let failed = results.filter { ($0["within_gate"] as? Bool) != true }.count
        try gate.writeSummary(
            status: failed == 0 ? "passed" : "failed",
            cases: results, device: renderer.device.name)
        XCTAssertEqual(
            failed, 0, "Strict arrival fidelity failed; evidence: \(gate.directory.path)")
    }

    func testNativeFrameBudgetRetainsSubmittedDescriptorsUntilCompletionOptIn() throws {
        let gate = try nativeGate(name: "resources")
        let renderer = try makeRenderer(gate: gate)
        let texture = try makeTexture(renderer.device, scale: 1)
        var pending: [any MTLCommandBuffer] = []
        defer {
            // Even a failed assertion must not leave an encoded command's
            // resource lease permanently waiting for an uncommitted buffer.
            for command in pending where command.status == .notEnqueued { command.commit() }
        }
        for index in 0..<Renderer.maximumFramesInFlight {
            try renderer.update(bursts: [burst(seed: UInt64(index), index: index)])
            let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
            try renderer.encode(into: command, target: texture, elapsedTime: 0.17, pointSize: size)
            pending.append(command)
        }
        XCTAssertEqual(renderer.statistics.inFlightFrames, Renderer.maximumFramesInFlight)
        XCTAssertEqual(renderer.statistics.encodedFrames, UInt64(Renderer.maximumFramesInFlight))
        try renderer.update(bursts: [burst(seed: 9, index: 9)])
        XCTAssertLessThanOrEqual(
            renderer.statistics.retainedDescriptorBuffers, Renderer.maximumDescriptorBuffers)
        XCTAssertGreaterThan(renderer.statistics.retainedDescriptorBytes, 0)
        let rejected = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        XCTAssertThrowsError(
            try renderer.encode(
                into: rejected, target: texture,
                elapsedTime: 0.17, pointSize: size))
        XCTAssertEqual(renderer.statistics.encodedFrames, UInt64(Renderer.maximumFramesInFlight))
        renderer.removeAll()
        XCTAssertEqual(renderer.statistics.elementCount, 0)
        XCTAssertEqual(renderer.statistics.inFlightFrames, Renderer.maximumFramesInFlight)
        XCTAssertGreaterThan(
            renderer.statistics.retainedDescriptorBuffers, 0,
            "Submitted work must retain its descriptors after the current scene is removed")
        for command in pending { try complete(command, retaining: renderer, texture: texture) }
        XCTAssertEqual(renderer.statistics.inFlightFrames, 0)
        XCTAssertEqual(renderer.statistics.retainedDescriptorBuffers, 0)
        XCTAssertEqual(renderer.statistics.retainedDescriptorBytes, 0)
        try gate.writeSummary(status: "passed", cases: [], device: renderer.device.name)
    }

    private func familySeeds() throws -> [(String, UInt64)] {
        var seeds: [String: UInt64] = [:]
        for seed in UInt64(0)..<128 {
            let profile = RequestRailEffectProfile(
                seed: seed, requestDuration: 0, completion: false)
            let name = familyName(profile.family)
            if seeds[name] == nil { seeds[name] = seed }
        }
        return try ["fireflies", "sparks", "arcs"].map { ($0, try XCTUnwrap(seeds[$0])) }
    }

    private func familyName(_ family: RequestRailEffectProfile.Family) -> String {
        switch family {
        case .fireflies: "fireflies"
        case .sparks: "sparks"
        case .arcs: "arcs"
        }
    }

    private func burst(
        seed: UInt64, index: Int = 0, startTime: TimeInterval = 0,
        point: CGPoint? = nil, color: SIMD4<Float>? = nil
    ) -> Renderer.Burst {
        let event = RequestRailEvent(
            requestID: UUID(
                uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            kind: .arrival, startedAt: Date(timeIntervalSince1970: 1_800_000_000), seed: seed)
        return Renderer.Burst(
            id: RequestRailLifecycleEffects.Key(event), startTime: startTime,
            profile: RequestRailEffectProfile(seed: seed, requestDuration: 0, completion: false),
            origin: point ?? origin, color: color ?? colors[0])
    }

    private func makeRenderer(gate: NativeGate? = nil) throws -> Renderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            try gate?.writeSummary(status: "unavailable", cases: [], device: nil)
            throw XCTSkip("Metal is unavailable; native arrival fidelity was not evaluated.")
        }
        return try Renderer(device: device)
    }

    private func twinkle(index: Int, star: Bool, atLeftEdge: Bool) -> Renderer.Twinkle {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let bar = CGRect(x: origin.x - 8, y: origin.y - 3.5, width: 16, height: 7)
        return Renderer.Twinkle(
            twinkle: RequestRailTwinkle(
                requestID: UUID(
                    uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1))!,
                startedAt: date, duration: 0.4, location: date, size: 3.1, angle: 0.37, star: star),
            placement: .init(
                center: CGPoint(x: atLeftEdge ? bar.minX + 0.25 : bar.maxX - 0.25, y: bar.midY),
                bar: bar, cornerRadius: 3.5),
            startTime: 0.015, color: colors[1])
    }

    private func compare(
        _ bursts: [Renderer.Burst], elapsed: TimeInterval, renderer: Renderer,
        scale: CGFloat, label: String, gate: NativeGate, requiresVisiblePixels: Bool = true
    ) throws -> [String: Any] {
        var result = try compareElements(
            bursts.map(Renderer.Element.burst), elapsed: elapsed,
            renderer: renderer, scale: scale, label: label, gate: gate,
            requiresVisiblePixels: requiresVisiblePixels)
        result["bursts"] = bursts.map { burst in
            [
                "seed": String(burst.id.seed), "family": familyName(burst.profile.family),
                "start_time": burst.startTime, "duration": burst.profile.burstDuration,
                "origin": [Double(burst.origin.x), Double(burst.origin.y)],
                "srgb_rgba": [burst.color.x, burst.color.y, burst.color.z, burst.color.w].map(
                    Double.init),
            ] as [String: Any]
        }
        return result
    }

    private func compareElements(
        _ elements: [Renderer.Element], elapsed: TimeInterval, renderer: Renderer,
        scale: CGFloat, label: String, gate: NativeGate, requiresVisiblePixels: Bool = true
    ) throws -> [String: Any] {
        try renderer.update(elements: elements)
        let before = renderer.statistics
        let actual = try render(renderer, scale: scale, label: label) { command, texture in
            try renderer.encode(
                into: command, target: texture, elapsedTime: elapsed, pointSize: size)
        }
        XCTAssertEqual(
            renderer.statistics.descriptorUploads, before.descriptorUploads,
            "Frame-time animation must not rebuild immutable descriptors")
        XCTAssertEqual(renderer.statistics.encodedFrames, before.encodedFrames + 1)
        XCTAssertEqual(renderer.statistics.inFlightFrames, 0)
        let expected = try MetalArrivalBurstCanvasReference.render(
            elements: elements.map { element in
                switch element {
                case .burst(let burst):
                    return .burst(
                        .init(
                            profile: burst.profile, age: elapsed - burst.startTime,
                            center: burst.origin, color: canvasColor(burst.color)))
                case .twinkle(let glint):
                    return .twinkle(
                        .init(
                            twinkle: glint.twinkle, placement: glint.placement,
                            age: elapsed - glint.startTime, color: canvasColor(glint.color)))
                }
            }, size: size, scale: scale)
        var result = try pixelComparison(actual, expected: expected, label: label, gate: gate)
        result["scale"] = Double(scale)
        result["elapsed_seconds"] = elapsed
        result["element_order"] = elements.map { element in
            switch element {
            case .burst(let burst): "burst-seed\(burst.id.seed)"
            case .twinkle(let glint): "twinkle-star\(glint.twinkle.star)"
            }
        }
        if requiresVisiblePixels {
            XCTAssertGreaterThan(result["actual_nonzero_alpha_pixels"] as? Int ?? 0, 0, label)
            XCTAssertGreaterThan(result["expected_nonzero_alpha_pixels"] as? Int ?? 0, 0, label)
        } else {
            XCTAssertEqual(result["actual_nonzero_alpha_pixels"] as? Int, 0, label)
            XCTAssertEqual(result["expected_nonzero_alpha_pixels"] as? Int, 0, label)
        }
        return result
    }

    private func canvasColor(_ color: SIMD4<Float>) -> Color {
        Color(
            .sRGB, red: Double(color.x), green: Double(color.y),
            blue: Double(color.z), opacity: Double(color.w))
    }

    // MARK: - Independent readback calibration

    private struct CalibrationVertex {
        var point: SIMD2<Float>
        var color: SIMD4<Float>
    }

    private func calibration(_ renderer: Renderer, scale: CGFloat, gate: NativeGate) throws
        -> [String: Any]
    {
        do {
            return try calibrationFrame(renderer, scale: scale, gate: gate)
        } catch {
            try gate.writeFailureSummaryIfAbsent(error: error, device: renderer.device.name)
            throw error
        }
    }

    private func calibrationFrame(_ renderer: Renderer, scale: CGFloat, gate: NativeGate) throws
        -> [String: Any]
    {
        let source = """
            #include <metal_stdlib>
            using namespace metal;
            struct Input { float2 point; float4 color; };
            struct Output { float4 position [[position]]; float4 color; };
            vertex Output calibrationVertex(uint id [[vertex_id]], constant Input *vertices [[buffer(0)]],
                                            constant float2 &size [[buffer(1)]]) {
                Input v = vertices[id];
                return {float4(v.point.x / size.x * 2 - 1, 1 - v.point.y / size.y * 2, 0, 1), v.color};
            }
            fragment float4 calibrationFragment(Output in [[stage_in]]) { return in.color; }
            """
        let library = try renderer.device.makeLibrary(source: source, options: nil)
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
                vertices.append(
                    CalibrationVertex(point: SIMD2(Float(point.x), Float(point.y)), color: color))
            }
        }
        let label = "calibration-s\(scale)"
        let actual = try render(renderer, scale: scale, label: label) { command, texture in
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
        var result = try pixelComparison(actual, expected: expected, label: label, gate: gate)
        var samples: [[String: Any]] = []
        var fixtureVerified = true
        // Independently check both producers against the fixture's fixed
        // upper-left coordinates. Comparing only the two images would allow
        // two matching coordinate mistakes to pass.
        for (producer, context) in [("metal", actual), ("canvas", expected)] {
            for (point, color) in [
                (CGPoint(x: 11, y: 17), [255, 0, 0, 255]),
                (CGPoint(x: 80, y: 65), [0, 0, 255, 255]),
                (CGPoint(x: 45, y: 32), [13, 89, 38, 128]),
                (CGPoint(x: 11, y: 70), [0, 0, 0, 0]),
                (CGPoint(x: 80, y: 22), [0, 0, 0, 0]),
            ] {
                let actualPixel = try pixel(context, at: point, scale: scale)
                samples.append([
                    "producer": producer, "point": [point.x, point.y],
                    "expected_rgba": color, "actual_rgba": actualPixel,
                ])
                for channel in 0..<4 {
                    let difference = abs(actualPixel[channel] - color[channel])
                    fixtureVerified = fixtureVerified && difference <= 1
                    XCTAssertLessThanOrEqual(
                        difference, 1,
                        "Calibration \(producer) channel/orientation/premultiplication: \(label), \(point)"
                    )
                }
            }
        }
        let logicalCoverage: CGFloat = 381  // 117 red + 99 blue + 165 green point squares.
        let expectedCoverage = Int(logicalCoverage * scale * scale)
        for key in ["actual_nonzero_alpha_pixels", "expected_nonzero_alpha_pixels"] {
            fixtureVerified = fixtureVerified && (result[key] as? Int == expectedCoverage)
            XCTAssertEqual(
                result[key] as? Int, expectedCoverage, "Calibration coverage: \(label), \(key)")
        }
        result["fixture_samples"] = samples
        result["fixture_verified"] = fixtureVerified
        guard result["within_gate"] as? Bool == true, fixtureVerified else {
            try gate.writeSummary(
                status: "failed", cases: [result], device: renderer.device.name,
                error: "Asymmetric native readback calibration failed")
            throw GateError.failed("Native readback calibration failed; \(gate.directory.path)")
        }
        return result
    }

    // MARK: - Metal execution and fixed-format readback

    private func makeTexture(_ device: any MTLDevice, scale: CGFloat) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(size.width * scale),
            height: Int(size.height * scale), mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private final class CompletionResources: @unchecked Sendable {
        let renderer: Renderer
        let texture: any MTLTexture
        let buffer: (any MTLBuffer)?
        init(renderer: Renderer, texture: any MTLTexture, buffer: (any MTLBuffer)? = nil) {
            self.renderer = renderer
            self.texture = texture
            self.buffer = buffer
        }
    }

    private func complete(
        _ command: any MTLCommandBuffer, retaining renderer: Renderer,
        texture: any MTLTexture, buffer: (any MTLBuffer)? = nil
    ) throws {
        let complete = DispatchSemaphore(value: 0)
        let resources = CompletionResources(renderer: renderer, texture: texture, buffer: buffer)
        command.addCompletedHandler { _ in withExtendedLifetime(resources) { complete.signal() } }
        command.commit()
        guard complete.wait(timeout: .now() + 5) == .success else {
            throw GateError.failed(
                "Metal completion timed out after five seconds: \(command.label ?? "unlabeled")")
        }
        guard command.status == .completed, command.error == nil else {
            throw GateError.failed(
                "Metal failed: status=\(command.status.rawValue), error=\(String(describing: command.error))"
            )
        }
    }

    private func render(
        _ renderer: Renderer, scale: CGFloat, label: String,
        encode: (any MTLCommandBuffer, any MTLTexture) throws -> Void
    ) throws -> CGContext {
        let texture = try makeTexture(renderer.device, scale: scale)
        let rowBytes = (texture.width * 4 + 255) / 256 * 256
        let buffer = try XCTUnwrap(
            renderer.device.makeBuffer(
                length: rowBytes * texture.height, options: .storageModeShared))
        let command = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        command.label = label
        defer {
            // Release a renderer lease even when test readback setup fails
            // after the production renderer successfully encoded its pass.
            if command.status == .notEnqueued { command.commit() }
        }
        try encode(command, texture)
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        try complete(command, retaining: renderer, texture: texture, buffer: buffer)
        let context = try bitmap(width: texture.width, height: texture.height)
        let target = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        for y in 0..<texture.height {
            for x in 0..<texture.width {
                // Metal texture rows and this ImageRenderer CGContext both
                // store the fixture's upper-left row first. Keep the row index;
                // asymmetric red/blue/transparent samples independently verify
                // this fixed mapping in both producers at 1x and 2x.
                let from = y * rowBytes + x * 4
                let to = y * context.bytesPerRow + x * 4
                target[to] = source[from + 2]
                target[to + 1] = source[from + 1]
                target[to + 2] = source[from]
                target[to + 3] = source[from + 3]
            }
        }
        return context
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
    }

    private func pixel(_ context: CGContext, at point: CGPoint, scale: CGFloat) throws -> [Int] {
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = Int(point.y * scale) * context.bytesPerRow + Int(point.x * scale) * 4
        return (0..<4).map { Int(bytes[offset + $0]) }
    }

    private func pixelComparison(
        _ actual: CGContext, expected: CGContext, label: String, gate: NativeGate
    ) throws -> [String: Any] {
        guard actual.width == expected.width, actual.height == expected.height else {
            throw GateError.failed("Mismatched fidelity image dimensions")
        }
        let a = try XCTUnwrap(actual.data).assumingMemoryBound(to: UInt8.self)
        let b = try XCTUnwrap(expected.data).assumingMemoryBound(to: UInt8.self)
        var maximum = [Int](repeating: 0, count: 4)
        var sums = [UInt64](repeating: 0, count: 4)
        var differingPixels = 0
        var actualVisible = 0
        var expectedVisible = 0
        var firstDifference: [Int]?
        for y in 0..<actual.height {
            for x in 0..<actual.width {
                let ai = y * actual.bytesPerRow + x * 4
                let bi = y * expected.bytesPerRow + x * 4
                if a[ai + 3] > 0 { actualVisible += 1 }
                if b[bi + 3] > 0 { expectedVisible += 1 }
                var differs = false
                for channel in 0..<4 {
                    let difference = abs(Int(a[ai + channel]) - Int(b[bi + channel]))
                    maximum[channel] = max(maximum[channel], difference)
                    sums[channel] += UInt64(difference)
                    differs = differs || difference > 0
                }
                if differs {
                    differingPixels += 1
                    if firstDifference == nil { firstDifference = [x, y] }
                }
            }
        }
        let withinGate = maximum.allSatisfy { $0 <= 2 }
        let result: [String: Any] = [
            "label": label, "width": actual.width, "height": actual.height,
            "maximum_rgba_difference": maximum, "absolute_rgba_difference_sums": sums,
            "differing_pixels": differingPixels,
            "first_difference_xy": firstDifference as Any? ?? NSNull(),
            "actual_nonzero_alpha_pixels": actualVisible,
            "expected_nonzero_alpha_pixels": expectedVisible,
            "maximum_allowed_channel_difference": 2, "within_gate": withinGate,
            "format": "sRGB encoded premultiplied RGBA8",
            "row_order": "upper-left row first; direct Metal-to-Canvas row mapping",
        ]
        if !withinGate {
            try gate.save(actual, name: "\(label)-metal.png")
            try gate.save(expected, name: "\(label)-canvas.png")
            try gate.write(result, name: "\(label)-metrics.json")
        }
        XCTAssertTrue(
            withinGate, "\(label): max RGBA=\(maximum), strict gate=2; \(gate.directory.path)")
        return result
    }

    // MARK: - Explicit, ignored native diagnostic output

    private enum GateError: Error { case failed(String) }

    private struct NativeGate {
        let directory: URL
        func write(_ value: [String: Any], name: String) throws {
            try JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys]
            )
            .write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
        }
        func writeSummary(
            status: String, cases: [[String: Any]], device: String?, error: String? = nil
        ) throws {
            try write(
                [
                    "schema_version": 1, "status": status, "cases": cases,
                    "device": device as Any? ?? NSNull(), "maximum_allowed_channel_difference": 2,
                    "error": error as Any? ?? NSNull(),
                    "scope":
                        "Offscreen Metal arrival rendering against independent Canvas; not live GPU utilization or CPU acceptance",
                ],
                name: "result.json")
        }
        func writeFailureSummaryIfAbsent(error: any Error, device: String?) throws {
            guard
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("result.json").path)
            else { return }
            try writeSummary(
                status: "failed", cases: [], device: device, error: String(describing: error))
        }
        func save(_ context: CGContext, name: String) throws {
            let image = try XCTUnwrap(context.makeImage())
            let representation = NSBitmapImageRep(cgImage: image)
            let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
        }
    }

    private func nativeGate(name: String) throws -> NativeGate {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLUXLLM_METAL_ARRIVAL_FIDELITY"] == "1" else {
            throw XCTSkip(
                "Set FLUXLLM_METAL_ARRIVAL_FIDELITY=1 and FLUXLLM_METAL_ARRIVAL_FIDELITY_OUTPUT to run the native gate."
            )
        }
        guard let raw = environment["FLUXLLM_METAL_ARRIVAL_FIDELITY_OUTPUT"], !raw.isEmpty else {
            throw GateError.failed(
                "Native fidelity requires an explicit FLUXLLM_METAL_ARRIVAL_FIDELITY_OUTPUT directory."
            )
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ignored = repository.appendingPathComponent(".performance-results", isDirectory: true)
            .resolvingSymlinksInPath()
        let requested =
            (raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw, isDirectory: true)
            : repository.appendingPathComponent(raw, isDirectory: true)).standardizedFileURL
            .resolvingSymlinksInPath()
        guard requested.path == ignored.path || requested.path.hasPrefix(ignored.path + "/") else {
            throw GateError.failed(
                "Native fidelity output must be inside the repository's ignored .performance-results directory."
            )
        }
        let directory = requested.appendingPathComponent(
            "\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("FLUXLLM_METAL_ARRIVAL_FIDELITY_OUTPUT=\(directory.path)")
        return NativeGate(directory: directory)
    }
}
