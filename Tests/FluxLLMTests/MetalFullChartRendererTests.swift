import AppKit
import Dispatch
import Metal
import XCTest

@testable import FluxLLM

/// Offscreen functional checks, not a GPU-utilization or Canvas-fidelity gate.
/// A missing Metal device is explicitly unavailable, never a passing blank image.
@MainActor
final class MetalFullChartRendererTests: XCTestCase {
    private typealias Renderer = MetalFullChartRenderer
    private typealias Effects = MetalFullChartEffectsRenderer
    private typealias Scene = MetalFullChartScene
    private let size = CGSize(width: 96, height: 80)
    private let red = SIMD4<Float>(1, 0, 0, 1)
    private let blue = SIMD4<Float>(0, 0, 1, 1)

    func testUnavailableDeviceFailsExplicitly() {
        XCTAssertThrowsError(try Renderer(device: nil))
        XCTAssertThrowsError(try Effects(device: nil))
    }

    func testStaticPublicationIsRetainedAndInvalidReplacementPreservesIt() throws {
        let renderer = try makeRenderer()
        let scene = rectangleScene(color: red)
        try renderer.update(scene: scene)
        let initial = renderer.statistics
        XCTAssertGreaterThan(initial.retainedBytes, 0)
        XCTAssertGreaterThan(initial.vertexCount, 0)
        XCTAssertEqual(initial.retainedSceneVersions, 1)
        XCTAssertLessThanOrEqual(initial.retainedBytes, Renderer.maximumSceneBytes)
        for _ in 0..<8 { try renderer.update(scene: scene) }
        XCTAssertEqual(renderer.statistics.uploadCount, initial.uploadCount)
        XCTAssertEqual(renderer.statistics.uploadedBytes, initial.uploadedBytes)

        let invalid = [
            Scene(size: .zero, primitives: []),
            Scene(
                size: size,
                primitives: [
                    .init(
                        shape: .polyline([.zero, CGPoint(x: CGFloat.nan, y: 2)]),
                        paint: .solid(red), stroke: .init(width: 1))
                ]),
            Scene(
                size: size,
                primitives: [
                    .init(
                        shape: .ellipse(CGRect(x: 10, y: 10, width: 8, height: 8)),
                        paint: .solid(SIMD4<Float>(1, 0, 0, 2)))
                ]),
            Scene(
                size: size,
                primitives: [
                    .init(
                        shape: .polyline([.zero, CGPoint(x: 8, y: 8)]),
                        paint: .solid(red), stroke: .init(width: 1, dash: [4, 0]))
                ]),
        ]
        for replacement in invalid {
            XCTAssertThrowsError(try renderer.update(scene: replacement))
            XCTAssertEqual(renderer.statistics.uploadCount, initial.uploadCount)
            XCTAssertEqual(renderer.statistics.retainedBytes, initial.retainedBytes)
            XCTAssertEqual(renderer.statistics.primitiveCount, initial.primitiveCount)
        }
        let image = try render(renderer, scale: 1)
        assertPixel(image, x: 18, y: 18, rgba: [255, 0, 0, 255])
        try renderer.update(scene: rectangleScene(color: blue))
        XCTAssertEqual(renderer.statistics.uploadCount, initial.uploadCount + 1)
        XCTAssertEqual(renderer.statistics.retainedSceneVersions, 1)
        assertPixel(try render(renderer, scale: 1), x: 18, y: 18, rgba: [0, 0, 255, 255])
    }

    func testOffscreenStaticShapesGradientsClippingAndDashesAtBothScales() throws {
        let renderer = try makeRenderer()
        let scene = Scene(
            size: size,
            primitives: [
                .init(
                    shape: .polygon(rectangle(CGRect(x: 4, y: 6, width: 18, height: 14))),
                    paint: .solid(red)),
                .init(
                    shape: .ellipse(CGRect(x: 66, y: 50, width: 14, height: 18)),
                    paint: .solid(blue)),
                .init(
                    shape: .roundedRect(CGRect(x: 34, y: 8, width: 20, height: 14), radius: 6),
                    paint: .solid(SIMD4<Float>(0, 1, 0, 1))),
                .init(
                    shape: .polyline([CGPoint(x: 6, y: 40), CGPoint(x: 42, y: 40)]),
                    paint: .solid(red), stroke: .init(width: 2)),
                .init(
                    shape: .polyline([CGPoint(x: 6, y: 62), CGPoint(x: 44, y: 62)]),
                    paint: .solid(red), stroke: .init(width: 2, dash: [6, 6])),
                .init(
                    shape: .ellipse(CGRect(x: 60, y: 10, width: 28, height: 24)),
                    paint: .solid(SIMD4<Float>(1, 0, 1, 1)),
                    clip: .init(rect: CGRect(x: 68, y: 16, width: 6, height: 8), radius: 1)),
                .init(
                    shape: .polygon(rectangle(CGRect(x: 32, y: 48, width: 20, height: 12))),
                    paint: .linear(
                        start: CGPoint(x: 32, y: 48), end: CGPoint(x: 52, y: 48),
                        stops: [.init(location: 0, color: red), .init(location: 1, color: blue)])),
            ])
        try renderer.update(scene: scene)
        let uploaded = renderer.statistics.uploadCount
        for scale in [1, 2] {
            let image = try render(renderer, scale: scale)
            XCTAssertGreaterThan(image.visiblePixelCount, 0)
            assertPixel(image, x: 10, y: 12, rgba: [255, 0, 0, 255])
            assertPixel(image, x: 73, y: 59, rgba: [0, 0, 255, 255])
            assertPixel(image, x: 44, y: 15, rgba: [0, 255, 0, 255])
            assertPixel(image, x: 34, y: 8, rgba: [0, 0, 0, 0])
            assertPixel(image, x: 12, y: 40, rgba: [255, 0, 0, 255])
            assertPixel(image, x: 8, y: 62, rgba: [255, 0, 0, 255])
            assertPixel(image, x: 15, y: 62, rgba: [0, 0, 0, 0])
            assertPixel(image, x: 21, y: 62, rgba: [255, 0, 0, 255])
            assertPixel(image, x: 70, y: 20, rgba: [255, 0, 255, 255])
            assertPixel(image, x: 80, y: 20, rgba: [0, 0, 0, 0])
            assertPixel(
                image, x: 10, y: 72, rgba: [0, 0, 0, 0],
                message: "Asymmetric probes reject flipped coordinates")
            let left = image.pixel(x: 34, y: 54)
            let right = image.pixel(x: 49, y: 54)
            XCTAssertGreaterThan(left[0], left[2])
            XCTAssertGreaterThan(right[2], right[0])
            XCTAssertEqual(left[3], 255)
            XCTAssertEqual(right[3], 255)
        }
        XCTAssertEqual(
            renderer.statistics.uploadCount, uploaded,
            "Changing drawable scale must reuse published geometry")
        XCTAssertEqual(
            renderer.statistics.drawCalls, 2, "Each retained static frame is one ordered draw")
        XCTAssertEqual(renderer.statistics.inFlightFrames, 0)
    }

    func testPremultipliedSourceOverOrderIsObservable() throws {
        let renderer = try makeRenderer()
        let shape = Scene.Shape.roundedRect(CGRect(x: 8, y: 8, width: 24, height: 24), radius: 0)
        let a = Scene.Primitive(shape: shape, paint: .solid(SIMD4<Float>(1, 0, 0, 0.5)))
        let b = Scene.Primitive(shape: shape, paint: .solid(SIMD4<Float>(0, 0, 1, 0.5)))
        try renderer.update(scene: Scene(size: size, primitives: [a, b]))
        assertPixel(
            try render(renderer, scale: 1), x: 18, y: 18, rgba: [64, 0, 128, 191], tolerance: 2)
        try renderer.update(scene: Scene(size: size, primitives: [b, a]))
        assertPixel(
            try render(renderer, scale: 1), x: 18, y: 18, rgba: [128, 0, 64, 191], tolerance: 2)
    }

    func testPolygonInteriorIsCorrectWhenTileReferenceWouldLieOnAnEdge() throws {
        let renderer = try makeRenderer()
        try renderer.update(
            scene: Scene(
                size: size,
                primitives: [
                    .init(
                        shape: .polygon([.zero, CGPoint(x: 16, y: 32), CGPoint(x: 0, y: 32)]),
                        paint: .solid(red)),
                    .init(
                        shape: .polygon([
                            CGPoint(x: 32, y: 8), CGPoint(x: 64, y: 72), CGPoint(x: 32, y: 72),
                        ]),
                        paint: .solid(blue)),
                ]))
        for scale in [1, 2] {
            let image = try render(renderer, scale: scale)
            assertPixel(image, x: 4, y: 24, rgba: [255, 0, 0, 255])
            assertPixel(image, x: 12, y: 8, rgba: [0, 0, 0, 0])
            assertPixel(image, x: 40, y: 56, rgba: [0, 0, 255, 255])
            assertPixel(image, x: 58, y: 16, rgba: [0, 0, 0, 0])
        }
    }

    func testRemovingSceneClearsPreviouslyRenderedPixelsWithoutRetainingGeometry() throws {
        let renderer = try makeRenderer()
        let texture = try makeTexture(renderer.device, scale: 1)
        try renderer.update(scene: rectangleScene(color: red))
        XCTAssertGreaterThan(try render(renderer, texture: texture, scale: 1).visiblePixelCount, 0)
        renderer.removeAll()
        let cleared = try render(renderer, texture: texture, scale: 1)
        XCTAssertEqual(cleared.visiblePixelCount, 0)
        XCTAssertEqual(renderer.statistics.primitiveCount, 0)
        XCTAssertEqual(renderer.statistics.retainedBytes, 0)
        XCTAssertEqual(renderer.statistics.retainedSceneVersions, 0)
    }

    func testSubmittedStaticVersionsRemainBoundedAndReleaseAfterCompletion() throws {
        let renderer = try makeRenderer()
        let queue = try XCTUnwrap(renderer.device.makeCommandQueue())
        let texture = try makeTexture(renderer.device, scale: 1)
        var pending: [any MTLCommandBuffer] = []
        defer { for command in pending where command.status == .notEnqueued { command.commit() } }
        for index in 0..<Renderer.maximumFramesInFlight {
            try renderer.update(scene: rectangleScene(color: index.isMultiple(of: 2) ? red : blue))
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            try renderer.encode(into: command, target: texture, pointSize: size)
            pending.append(command)
        }
        XCTAssertEqual(renderer.statistics.inFlightFrames, Renderer.maximumFramesInFlight)
        XCTAssertEqual(
            renderer.statistics.retainedSceneVersions, Renderer.maximumRetainedSceneVersions)
        XCTAssertLessThanOrEqual(renderer.statistics.retainedBytes, Renderer.maximumRetainedBytes)
        let before = renderer.statistics
        XCTAssertThrowsError(try renderer.update(scene: rectangleScene(color: red)))
        XCTAssertEqual(renderer.statistics.uploadCount, before.uploadCount)
        let excess = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertThrowsError(try renderer.encode(into: excess, target: texture, pointSize: size))
        XCTAssertEqual(renderer.statistics.encodedFrames, before.encodedFrames)
        renderer.removeAll()
        XCTAssertGreaterThan(
            renderer.statistics.retainedBytes, 0, "Submitted commands own their immutable geometry")
        for command in pending { try complete(command, retaining: renderer, texture: texture) }
        XCTAssertEqual(renderer.statistics.inFlightFrames, 0)
        XCTAssertEqual(renderer.statistics.retainedSceneVersions, 0)
        XCTAssertEqual(renderer.statistics.retainedBytes, 0)
    }

    func testEveryArrivalFamilyDrawsAndExpiresWithoutReuploading() throws {
        let renderer = try makeEffects()
        var seeds: [String: UInt64] = [:]
        for seed in UInt64(0)..<128 {
            let profile = RequestRailEffectProfile(
                seed: seed, requestDuration: 0, completion: false)
            let family: String
            switch profile.family {
            case .fireflies: family = "fireflies"
            case .sparks: family = "sparks"
            case .arcs: family = "arcs"
            }
            if seeds[family] == nil { seeds[family] = seed }
        }
        XCTAssertEqual(seeds.count, 3, "Fixture must exercise fireflies, sparks and arcs")
        for seed in seeds.values.sorted() {
            let effect = effect(seed: seed, completion: false)
            try renderer.update(elements: [.effect(effect)])
            let uploaded = renderer.statistics.descriptorUploads
            for scale in [1, 2] {
                let active = try render(
                    renderer, at: effect.startTime + effect.profile.burstDuration * 0.25,
                    scale: scale)
                XCTAssertGreaterThan(
                    active.image.visiblePixelCount, 0, "Arrival seed \(seed), scale \(scale)")
                XCTAssertEqual(active.content.arrivalBursts, 1)
                XCTAssertEqual(active.content.completionEffects, 0)
                XCTAssertEqual(active.content.twinkles, 0)
                for time in [
                    effect.startTime - 0.01,
                    effect.startTime + effect.profile.visibleDuration + 0.01,
                ] {
                    let inactive = try render(renderer, at: time, scale: scale)
                    XCTAssertEqual(inactive.image.visiblePixelCount, 0)
                    XCTAssertEqual(inactive.content.arrivalBursts, 0)
                }
            }
            XCTAssertEqual(
                renderer.statistics.descriptorUploads, uploaded,
                "Advancing animation time must reuse immutable descriptors")
            XCTAssertEqual(renderer.statistics.inFlightFrames, 0)
        }
    }

    func testCompletionFlashLightningAndOptionalFinalBurstHaveActualPixels() throws {
        let renderer = try makeEffects()
        for explodes in [false, true] {
            let seed = try XCTUnwrap(
                (UInt64(0)..<128).first {
                    RequestRailEffectProfile(seed: $0, requestDuration: 12, completion: true)
                        .explodes == explodes
                })
            let fixture = effect(seed: seed, completion: true)
            try renderer.update(elements: [.effect(fixture)])
            var ages = [0.12, fixture.profile.surgeDelay + fixture.profile.surgeDuration * 0.5]
            if explodes {
                ages.append(
                    fixture.profile.surgeDelay + fixture.profile.surgeDuration + fixture.profile
                        .burstDuration * 0.25)
            }
            for scale in [1, 2] {
                for age in ages {
                    let active = try render(renderer, at: fixture.startTime + age, scale: scale)
                    XCTAssertGreaterThan(
                        active.image.visiblePixelCount, 0,
                        "Completion explode=\(explodes), age=\(age), scale=\(scale)")
                    XCTAssertEqual(active.content.completionEffects, 1)
                    XCTAssertEqual(active.content.arrivalBursts, 0)
                }
                let before = try render(renderer, at: fixture.startTime - 0.01, scale: scale)
                let after = try render(
                    renderer, at: fixture.startTime + fixture.profile.visibleDuration + 0.01,
                    scale: scale)
                XCTAssertEqual(before.image.visiblePixelCount, 0)
                XCTAssertEqual(after.image.visiblePixelCount, 0)
                XCTAssertEqual(before.content.completionEffects, 0)
                XCTAssertEqual(after.content.completionEffects, 0)
            }
        }
    }

    func testTwinklePixelsAreClippedTimedAndCompositedOverStaticContent() throws {
        let renderer = try makeEffects()
        for star in [false, true] {
            let fixture = twinkle(star: star)
            try renderer.update(elements: [.twinkle(fixture)])
            for scale in [1, 2] {
                let active = try render(renderer, at: fixture.startTime + 0.17, scale: scale)
                XCTAssertGreaterThan(active.image.visiblePixelCount, 0)
                XCTAssertEqual(active.content.twinkles, 1)
                assertPixel(
                    active.image, x: 70, y: 32, rgba: [0, 0, 0, 0],
                    message: "Glints cannot escape their rail clip")
                for time in [
                    fixture.startTime - 0.01, fixture.startTime + fixture.twinkle.duration + 0.01,
                ] {
                    let inactive = try render(renderer, at: time, scale: scale)
                    XCTAssertEqual(inactive.image.visiblePixelCount, 0)
                    XCTAssertEqual(inactive.content.twinkles, 0)
                }
            }
        }
        let base = try Renderer(device: renderer.device)
        try base.update(scene: rectangleScene(color: red))
        let target = try makeTexture(renderer.device, scale: 1)
        let layered = try readback(
            device: renderer.device, retaining: renderer, target: target, scale: 1
        ) { command in
            try base.encode(into: command, target: target, pointSize: size)
            try renderer.encode(
                into: command, target: target, elapsedTime: 1.17, pointSize: size, clear: false)
        }
        assertPixel(
            layered, x: 18, y: 18, rgba: [255, 0, 0, 255],
            message: "Effects must load the existing static chart")
        XCTAssertGreaterThan(layered.pixel(x: 70, y: 40)[3], 0)
    }

    func testEffectUpdatesAreAtomicBoundedAndOrderSensitive() throws {
        let renderer = try makeEffects()
        let a = effect(seed: 2, completion: false, index: 1, color: SIMD4(1, 0, 0, 0.6))
        let b = effect(seed: 2, completion: false, index: 2, color: SIMD4(0, 0, 1, 0.6))
        try renderer.update(elements: [.effect(a), .effect(b)])
        let initial = renderer.statistics
        for _ in 0..<8 { try renderer.update(elements: [.effect(a), .effect(b)]) }
        XCTAssertEqual(renderer.statistics.descriptorUploads, initial.descriptorUploads)
        let first = try render(renderer, at: 1.17, scale: 1).image
        try renderer.update(elements: [.effect(b), .effect(a)])
        let reversed = try render(renderer, at: 1.17, scale: 1).image
        XCTAssertNotEqual(
            first.rgba, reversed.rgba,
            "Overlapping effects must preserve publication source-over order")
        let beforeRejection = renderer.statistics
        XCTAssertThrowsError(try renderer.update(elements: [.effect(a), .effect(a)]))
        XCTAssertThrowsError(
            try renderer.update(elements: [
                .effect(effect(seed: 2, completion: false, startTime: .nan))
            ]))
        XCTAssertThrowsError(
            try renderer.update(
                elements: (0...Effects.maximumEffects).map {
                    .effect(effect(seed: UInt64($0), completion: false, index: $0))
                }))
        XCTAssertThrowsError(
            try renderer.update(
                elements: (0...Effects.maximumTwinkles).map {
                    .twinkle(twinkle(star: true, index: $0))
                }))
        XCTAssertEqual(renderer.statistics.descriptorUploads, beforeRejection.descriptorUploads)
        XCTAssertEqual(renderer.statistics.elementCount, 2)
        XCTAssertEqual(
            renderer.statistics.retainedDescriptorBytes, beforeRejection.retainedDescriptorBytes)
        XCTAssertEqual(try render(renderer, at: 1.17, scale: 1).image.rgba, reversed.rgba)
    }

    func testEffectFrameAndDescriptorLeasesRemainBoundedUntilCompletion() throws {
        let renderer = try makeEffects()
        let queue = try XCTUnwrap(renderer.device.makeCommandQueue())
        let texture = try makeTexture(renderer.device, scale: 1)
        var pending: [any MTLCommandBuffer] = []
        defer { for command in pending where command.status == .notEnqueued { command.commit() } }
        for index in 0..<Effects.maximumFramesInFlight {
            try renderer.update(elements: [
                .effect(effect(seed: UInt64(index), completion: true, index: index))
            ])
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            // Retain even a partially encoded command so failure cleanup commits its resource lease.
            pending.append(command)
            try renderer.encode(
                into: command, target: texture, elapsedTime: 1.5, pointSize: size, clear: true)
        }
        XCTAssertEqual(renderer.statistics.inFlightFrames, Effects.maximumFramesInFlight)
        try renderer.update(elements: [.effect(effect(seed: 40, completion: true, index: 40))])
        XCTAssertLessThanOrEqual(
            renderer.statistics.retainedDescriptorBuffers, 2 * (Effects.maximumFramesInFlight + 1))
        // Production's published maximum: three slots × 66 descriptors × 1,205 float4 rows.
        XCTAssertLessThanOrEqual(renderer.statistics.retainedFrameBytes, 3_817_440)
        let extra = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertThrowsError(
            try renderer.encode(
                into: extra, target: texture, elapsedTime: 1.5, pointSize: size, clear: true))
        renderer.removeAll()
        XCTAssertEqual(renderer.statistics.elementCount, 0)
        XCTAssertGreaterThan(renderer.statistics.retainedDescriptorBytes, 0)
        XCTAssertGreaterThan(renderer.statistics.retainedFrameBytes, 0)
        for command in pending { try complete(command, retaining: renderer, texture: texture) }
        XCTAssertEqual(renderer.statistics.inFlightFrames, 0)
        XCTAssertEqual(renderer.statistics.retainedDescriptorBuffers, 0)
        XCTAssertEqual(renderer.statistics.retainedDescriptorBytes, 0)
        XCTAssertEqual(renderer.statistics.retainedFrameBytes, 0)
    }

    // MARK: - Bounded offscreen rendering and independent fixed-coordinate probes

    private struct Pixels {
        let width: Int
        let height: Int
        let scale: Int
        let rgba: [UInt8]

        var visiblePixelCount: Int {
            stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 0 }.count
        }
        func pixel(x: Int, y: Int) -> [Int] {
            let offset = (y * scale * width + x * scale) * 4
            return (0..<4).map { Int(rgba[offset + $0]) }
        }
    }

    private final class CompletionResources: @unchecked Sendable {
        let renderer: AnyObject
        let texture: any MTLTexture
        let buffer: (any MTLBuffer)?
        init(renderer: AnyObject, texture: any MTLTexture, buffer: (any MTLBuffer)?) {
            self.renderer = renderer
            self.texture = texture
            self.buffer = buffer
        }
    }

    private enum RenderFailure: Error {
        case completionTimedOut
        case commandFailed(String)
    }

    private func makeRenderer() throws -> Renderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable; full-chart offscreen rendering was not evaluated")
        }
        return try Renderer(device: device)
    }

    private func makeEffects() throws -> Effects {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable; full-chart effects rendering was not evaluated")
        }
        return try Effects(device: device)
    }

    private func effect(
        seed: UInt64, completion: Bool, index: Int = 0, startTime: TimeInterval = 1,
        color: SIMD4<Float> = SIMD4(0, 0.87, 1, 1)
    ) -> Effects.Effect {
        let event = RequestRailEvent(
            requestID: UUID(
                uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            kind: completion ? .completion : .arrival,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), seed: seed)
        return Effects.Effect(
            id: RequestRailLifecycleEffects.Key(event), startTime: startTime,
            profile: RequestRailEffectProfile(
                seed: seed, requestDuration: 12, completion: completion),
            rect: CGRect(x: 24, y: 36, width: 56, height: 8), cornerRadius: 4, color: color)
    }

    private func twinkle(star: Bool, index: Int = 0) -> Effects.Twinkle {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let bar = CGRect(x: 24, y: 36, width: 56, height: 8)
        return Effects.Twinkle(
            twinkle: RequestRailTwinkle(
                requestID: UUID(
                    uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1))!,
                startedAt: date, duration: 0.4, location: date, size: 3.1, angle: 0.37, star: star),
            placement: .init(center: CGPoint(x: 70, y: 40), bar: bar, cornerRadius: 4),
            startTime: 1,
            color: SIMD4(1, 0.1, 0.5, 0.8))
    }

    private func rectangle(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    private func rectangleScene(color: SIMD4<Float>) -> Scene {
        Scene(
            size: size,
            primitives: [
                .init(
                    shape: .roundedRect(CGRect(x: 8, y: 8, width: 24, height: 24), radius: 3),
                    paint: .solid(color))
            ])
    }

    private func makeTexture(_ device: any MTLDevice, scale: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(size.width) * scale,
            height: Int(size.height) * scale, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func complete(
        _ command: any MTLCommandBuffer, retaining renderer: AnyObject,
        texture: any MTLTexture, buffer: (any MTLBuffer)? = nil
    ) throws {
        let completed = DispatchSemaphore(value: 0)
        let resources = CompletionResources(renderer: renderer, texture: texture, buffer: buffer)
        command.addCompletedHandler { _ in withExtendedLifetime(resources) { completed.signal() } }
        command.commit()
        guard completed.wait(timeout: .now() + 5) == .success else {
            throw RenderFailure.completionTimedOut
        }
        guard command.status == .completed, command.error == nil else {
            throw RenderFailure.commandFailed(String(describing: command.error))
        }
    }

    private func render(_ renderer: Renderer, texture: (any MTLTexture)? = nil, scale: Int) throws
        -> Pixels
    {
        let target = try texture ?? makeTexture(renderer.device, scale: scale)
        return try readback(
            device: renderer.device, retaining: renderer, target: target, scale: scale
        ) { command in
            try renderer.encode(into: command, target: target, pointSize: size)
        }
    }

    private func render(_ renderer: Effects, at time: TimeInterval, scale: Int)
        throws -> (image: Pixels, content: Effects.EncodedContent)
    {
        let target = try makeTexture(renderer.device, scale: scale)
        var content: Effects.EncodedContent?
        let image = try readback(
            device: renderer.device, retaining: renderer, target: target, scale: scale
        ) { command in
            content = try renderer.encode(
                into: command, target: target, elapsedTime: time, pointSize: size, clear: true)
        }
        return (image, try XCTUnwrap(content))
    }

    private func readback(
        device: any MTLDevice, retaining renderer: AnyObject,
        target: any MTLTexture, scale: Int,
        encode: (any MTLCommandBuffer) throws -> Void
    ) throws -> Pixels {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let rowBytes = (target.width * 4 + 255) / 256 * 256
        let buffer = try XCTUnwrap(
            device.makeBuffer(length: rowBytes * target.height, options: .storageModeShared))
        defer { if command.status == .notEnqueued { command.commit() } }
        try encode(command)
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: target, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: target.width, height: target.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * target.height)
        blit.endEncoding()
        try complete(command, retaining: renderer, texture: target, buffer: buffer)
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var rgba = [UInt8](repeating: 0, count: target.width * target.height * 4)
        for y in 0..<target.height {
            for x in 0..<target.width {
                let from = y * rowBytes + x * 4
                let to = (y * target.width + x) * 4
                rgba[to] = source[from + 2]
                rgba[to + 1] = source[from + 1]
                rgba[to + 2] = source[from]
                rgba[to + 3] = source[from + 3]
            }
        }
        return Pixels(width: target.width, height: target.height, scale: scale, rgba: rgba)
    }

    private func assertPixel(
        _ image: Pixels, x: Int, y: Int, rgba: [Int], tolerance: Int = 1,
        message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = image.pixel(x: x, y: y)
        for channel in 0..<4 {
            XCTAssertLessThanOrEqual(
                abs(actual[channel] - rgba[channel]), tolerance,
                "\(message) pixel (\(x), \(y)), scale \(image.scale), channel \(channel): \(actual)",
                file: file, line: line)
        }
    }
}
