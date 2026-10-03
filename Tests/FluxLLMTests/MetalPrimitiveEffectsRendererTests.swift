import AppKit
import Dispatch
import Metal
import XCTest

@testable import FluxLLM

/// Functional GPU checks. Fidelity and CPU/GPU utilization have independent gates.
@MainActor
final class MetalPrimitiveEffectsRendererTests: XCTestCase {
    private typealias Renderer = MetalPrimitiveEffectsRenderer
    private let size = CGSize(width: 96, height: 80)

    func testMissingDeviceIsExplicitlyUnavailable() {
        XCTAssertThrowsError(try Renderer(device: nil))
    }

    func testArrivalFamiliesEvaluateOnGPUAndReuseDescriptorsAtBothScales() throws {
        let renderer = try makeRenderer()
        let seeds = familySeeds()
        XCTAssertEqual(seeds.count, 3)
        for seed in seeds {
            let fixture = effect(seed: seed, completion: false)
            try renderer.update(elements: [.effect(fixture)])
            let uploads = renderer.statistics.descriptorUploads
            for scale in [1, 2] {
                let before = renderer.statistics
                let active = try render(
                    renderer, at: 1 + fixture.profile.burstDuration * 0.3, scale: scale)
                XCTAssertGreaterThan(active.pixels.visibleCount, 0)
                XCTAssertEqual(active.content.arrivalBursts, 1)
                XCTAssertEqual(renderer.statistics.computeDispatches, before.computeDispatches + 1)
                XCTAssertEqual(renderer.statistics.renderDraws, before.renderDraws + 1)
                XCTAssertEqual(renderer.statistics.maskPasses, before.maskPasses)
                for age in [-0.01, fixture.profile.visibleDuration + 0.01] {
                    let inactive = try render(renderer, at: 1 + age, scale: scale)
                    XCTAssertEqual(inactive.pixels.visibleCount, 0)
                    XCTAssertEqual(inactive.content.arrivalBursts, 0)
                }
            }
            XCTAssertEqual(renderer.statistics.descriptorUploads, uploads)
            XCTAssertEqual(renderer.statistics.inFlightFrames, 0)
        }
    }

    func testCompletionStagesUseOneMaskPassAndRespectLightningClip() throws {
        let renderer = try makeRenderer()
        let seed = try XCTUnwrap(
            (UInt64(0)..<128).first {
                RequestRailEffectProfile(seed: $0, requestDuration: 12, completion: true).explodes
            })
        let fixture = effect(seed: seed, completion: true)
        try renderer.update(elements: [.effect(fixture)])
        let upload = renderer.statistics.descriptorUploads
        for scale in [1, 2] {
            for age in [
                0.12, fixture.profile.surgeDelay + fixture.profile.surgeDuration * 0.5,
                fixture.profile.surgeDelay + fixture.profile.surgeDuration + fixture.profile
                    .burstDuration * 0.3,
            ] {
                let before = renderer.statistics
                let active = try render(renderer, at: 1 + age, scale: scale)
                XCTAssertGreaterThan(active.pixels.visibleCount, 0)
                XCTAssertEqual(active.content.completionEffects, 1)
                XCTAssertEqual(renderer.statistics.computeDispatches, before.computeDispatches + 1)
                XCTAssertEqual(renderer.statistics.maskPasses, before.maskPasses + 1)
                XCTAssertEqual(renderer.statistics.renderDraws, before.renderDraws + 2)
            }
            // At this age the initial flash is over and the final burst has not begun.
            let lightning = try render(
                renderer, at: 1 + fixture.profile.surgeDelay + fixture.profile.surgeDuration * 0.5,
                scale: scale)
            for y in [25, 31, 49, 55] {
                XCTAssertEqual(
                    lightning.pixels.pixel(x: 52, y: y)[3], 0,
                    "Lightning must stay within the original 13-point strip")
            }
            let expired = try render(
                renderer, at: 1 + fixture.profile.visibleDuration + 0.01, scale: scale)
            XCTAssertEqual(expired.pixels.visibleCount, 0)
            XCTAssertEqual(expired.content.completionEffects, 0)
        }
        XCTAssertEqual(renderer.statistics.descriptorUploads, upload)
        XCTAssertGreaterThan(renderer.statistics.retainedMaskBytes, 0)
        XCTAssertGreaterThanOrEqual(
            renderer.statistics.retainedFrameBytes, renderer.statistics.retainedMaskBytes)
    }

    func testCroppedOriginProducesTheSamePixelsAsFullViewportAtBothScales() throws {
        let renderer = try makeRenderer()
        let fixture = effect(seed: 2, completion: true)
        try renderer.update(elements: [.effect(fixture), .twinkle(twinkle(star: true))])
        let origin = CGPoint(x: 13, y: 17)
        let croppedSize = CGSize(width: 70, height: 50)
        let ages = [0.12, fixture.profile.surgeDelay + fixture.profile.surgeDuration * 0.5]
        for scale in [1, 2] {
            for age in ages {
                let full = try render(renderer, at: 1 + age, scale: scale).pixels
                let crop = try render(
                    renderer, at: 1 + age, scale: scale, pointSize: croppedSize, origin: origin
                ).pixels
                for y in 0..<crop.height {
                    for x in 0..<crop.width {
                        let croppedPixel = crop.pixelAtPhysical(x: x, y: y)
                        let fullPixel = full.pixelAtPhysical(
                            x: x + Int(origin.x) * scale, y: y + Int(origin.y) * scale)
                        for channel in 0..<4 {
                            XCTAssertLessThanOrEqual(
                                abs(croppedPixel[channel] - fullPixel[channel]), 1,
                                "Origin changed global pixel (\(x), \(y)), channel \(channel), scale \(scale)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testTwinkleClipTimingAndSourceOverOrderingAreObservable() throws {
        let renderer = try makeRenderer()
        for star in [false, true] {
            let fixture = twinkle(star: star)
            try renderer.update(elements: [.twinkle(fixture)])
            for scale in [1, 2] {
                let active = try render(renderer, at: 1.17, scale: scale)
                XCTAssertGreaterThan(active.pixels.visibleCount, 0)
                XCTAssertEqual(active.content.twinkles, 1)
                XCTAssertEqual(active.pixels.pixel(x: 70, y: 32)[3], 0)
                XCTAssertEqual(active.pixels.pixel(x: 70, y: 48)[3], 0)
                for time in [0.99, 1.41] {
                    let inactive = try render(renderer, at: time, scale: scale)
                    XCTAssertEqual(inactive.pixels.visibleCount, 0)
                    XCTAssertEqual(inactive.content.twinkles, 0)
                }
            }
        }
        let a = effect(seed: 2, completion: false, index: 1, color: SIMD4(1, 0, 0, 0.6))
        let b = effect(seed: 2, completion: false, index: 2, color: SIMD4(0, 0, 1, 0.6))
        try renderer.update(elements: [.effect(a), .effect(b)])
        let ordered = try render(renderer, at: 1.17, scale: 1).pixels
        try renderer.update(elements: [.effect(b), .effect(a)])
        let reversed = try render(renderer, at: 1.17, scale: 1).pixels
        XCTAssertNotEqual(ordered.rgba, reversed.rgba)
        XCTAssertGreaterThan(ordered.visibleCount, 0)
    }

    func testInvalidReplacementKeepsThePublishedSceneAndResources() throws {
        let renderer = try makeRenderer()
        let fixture = effect(seed: 2, completion: true)
        try renderer.update(elements: [.effect(fixture)])
        let expected = try render(renderer, at: 1.4, scale: 1).pixels
        let before = renderer.statistics
        for _ in 0..<8 { try renderer.update(elements: [.effect(fixture)]) }
        XCTAssertEqual(renderer.statistics.descriptorUploads, before.descriptorUploads)
        XCTAssertThrowsError(try renderer.update(elements: [.effect(fixture), .effect(fixture)]))
        XCTAssertThrowsError(
            try renderer.update(elements: [
                .effect(effect(seed: 2, completion: false, startTime: .nan))
            ]))
        XCTAssertThrowsError(
            try renderer.update(
                elements: (0...Renderer.maximumEffects).map {
                    .effect(effect(seed: UInt64($0), completion: false, index: $0))
                }))
        XCTAssertThrowsError(
            try renderer.update(
                elements: (0...Renderer.maximumTwinkles).map {
                    .twinkle(twinkle(star: true, index: $0))
                }))
        XCTAssertEqual(renderer.statistics.descriptorUploads, before.descriptorUploads)
        XCTAssertEqual(renderer.statistics.retainedDescriptorBytes, before.retainedDescriptorBytes)
        XCTAssertEqual(renderer.statistics.elementCount, 1)
        XCTAssertEqual(try render(renderer, at: 1.4, scale: 1).pixels.rgba, expected.rgba)
    }

    func testThreeOutstandingFramesRetainStorageAndReleaseItAfterRemoval() throws {
        let renderer = try makeRenderer()
        let queue = try XCTUnwrap(renderer.device.makeCommandQueue())
        let texture = try makeTexture(renderer.device, pointSize: size, scale: 1)
        var pending: [any MTLCommandBuffer] = []
        defer { for command in pending where command.status == .notEnqueued { command.commit() } }
        for index in 0..<Renderer.maximumFramesInFlight {
            try renderer.update(elements: [
                .effect(effect(seed: UInt64(index), completion: true, index: index))
            ])
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            pending.append(command)
            try renderer.encode(
                into: command, target: texture, elapsedTime: 1.4, pointSize: size, clear: true)
        }
        XCTAssertEqual(renderer.statistics.inFlightFrames, 3)
        XCTAssertGreaterThan(renderer.statistics.retainedMaskBytes, 0)
        XCTAssertLessThanOrEqual(renderer.statistics.retainedDescriptorBuffers, 6)
        let before = renderer.statistics
        let excess = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertThrowsError(
            try renderer.encode(
                into: excess, target: texture, elapsedTime: 1.4, pointSize: size, clear: true))
        XCTAssertEqual(renderer.statistics.encodedFrames, before.encodedFrames)
        renderer.removeAll()
        XCTAssertEqual(renderer.statistics.elementCount, 0)
        XCTAssertGreaterThan(renderer.statistics.retainedDescriptorBytes, 0)
        XCTAssertGreaterThan(renderer.statistics.retainedFrameBytes, 0)
        for command in pending { try complete(command, retaining: renderer, texture: texture) }
        XCTAssertEqual(renderer.statistics.inFlightFrames, 0)
        XCTAssertEqual(renderer.statistics.retainedDescriptorBytes, 0)
        XCTAssertEqual(renderer.statistics.retainedFrameBytes, 0)
        XCTAssertEqual(renderer.statistics.retainedMaskBytes, 0)
    }

    func testClearAndLoadActionsRespectTheExistingTarget() throws {
        let renderer = try makeRenderer()
        let fixture = effect(seed: 2, completion: false)
        try renderer.update(elements: [.effect(fixture)])
        let target = try makeTexture(renderer.device, pointSize: size, scale: 1)
        let active = try readback(renderer, target: target, scale: 1) { command in
            try renderer.encode(
                into: command, target: target, elapsedTime: 1.17, pointSize: size, clear: true)
        }
        XCTAssertGreaterThan(active.visibleCount, 0)
        renderer.removeAll()
        let retained = try readback(renderer, target: target, scale: 1) { command in
            try renderer.encode(
                into: command, target: target, elapsedTime: 2, pointSize: size, clear: false)
        }
        XCTAssertEqual(retained.rgba, active.rgba)
        let cleared = try readback(renderer, target: target, scale: 1) { command in
            try renderer.encode(
                into: command, target: target, elapsedTime: 2, pointSize: size, clear: true)
        }
        XCTAssertEqual(cleared.visibleCount, 0)
        renderer.removeAll()
        XCTAssertEqual(renderer.statistics.retainedFrameBytes, 0)
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let scale: Int
        let rgba: [UInt8]
        var visibleCount: Int {
            stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 0 }.count
        }
        func pixel(x: Int, y: Int) -> [Int] { pixelAtPhysical(x: x * scale, y: y * scale) }
        func pixelAtPhysical(x: Int, y: Int) -> [Int] {
            let offset = (y * width + x) * 4
            return (0..<4).map { Int(rgba[offset + $0]) }
        }
    }
    private final class Resources: @unchecked Sendable {
        let renderer: AnyObject
        let texture: any MTLTexture
        let buffer: (any MTLBuffer)?
        init(_ renderer: AnyObject, _ texture: any MTLTexture, _ buffer: (any MTLBuffer)?) {
            self.renderer = renderer
            self.texture = texture
            self.buffer = buffer
        }
    }
    private enum Failure: Error {
        case timeout
        case commandFailed(String)
    }
    private func makeRenderer() throws -> Renderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable; primitive effects were not evaluated")
        }
        return try Renderer(device: device)
    }
    private func familySeeds() -> [UInt64] {
        var seen: Set<String> = []
        return (UInt64(0)..<128).filter { seed in
            let family = String(
                describing: RequestRailEffectProfile(
                    seed: seed, requestDuration: 12, completion: false
                ).family)
            return seen.insert(family).inserted
        }
    }
    private func effect(
        seed: UInt64, completion: Bool, index: Int = 0, startTime: TimeInterval = 1,
        color: SIMD4<Float> = SIMD4(0, 0.87, 1, 1)
    ) -> Renderer.Effect {
        let event = RequestRailEvent(
            requestID: UUID(
                uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            kind: completion ? .completion : .arrival,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), seed: seed)
        return Renderer.Effect(
            id: .init(event), startTime: startTime,
            profile: .init(seed: seed, requestDuration: 12, completion: completion),
            rect: CGRect(x: 24, y: 36, width: 56, height: 8), cornerRadius: 4, color: color)
    }
    private func twinkle(star: Bool, index: Int = 0) -> Renderer.Twinkle {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let bar = CGRect(x: 24, y: 36, width: 56, height: 8)
        return Renderer.Twinkle(
            twinkle: .init(
                requestID: UUID(
                    uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1))!,
                startedAt: date, duration: 0.4, location: date, size: 3.1, angle: 0.37, star: star),
            placement: .init(center: CGPoint(x: 70, y: 40), bar: bar, cornerRadius: 4),
            startTime: 1,
            color: SIMD4(1, 0.1, 0.5, 0.8))
    }
    private func makeTexture(_ device: any MTLDevice, pointSize: CGSize, scale: Int) throws
        -> any MTLTexture
    {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(pointSize.width) * scale, height: Int(pointSize.height) * scale,
            mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }
    private func complete(
        _ command: any MTLCommandBuffer, retaining renderer: AnyObject,
        texture: any MTLTexture, buffer: (any MTLBuffer)? = nil
    ) throws {
        let completion = DispatchSemaphore(value: 0)
        let resources = Resources(renderer, texture, buffer)
        command.addCompletedHandler { _ in withExtendedLifetime(resources) { completion.signal() } }
        command.commit()
        guard completion.wait(timeout: .now() + 5) == .success else { throw Failure.timeout }
        guard command.status == .completed, command.error == nil else {
            throw Failure.commandFailed(String(describing: command.error))
        }
    }
    private func render(
        _ renderer: Renderer, at time: TimeInterval, scale: Int,
        pointSize: CGSize? = nil, origin: CGPoint = .zero
    )
        throws -> (pixels: Pixels, content: Renderer.EncodedContent)
    {
        let pointSize = pointSize ?? size
        let target = try makeTexture(renderer.device, pointSize: pointSize, scale: scale)
        var content: Renderer.EncodedContent?
        let pixels = try readback(renderer, target: target, scale: scale) { command in
            content = try renderer.encode(
                into: command, target: target, elapsedTime: time,
                pointSize: pointSize, origin: origin, clear: true)
        }
        return (pixels, try XCTUnwrap(content))
    }
    private func readback(
        _ renderer: Renderer, target: any MTLTexture, scale: Int,
        encode: (any MTLCommandBuffer) throws -> Void
    ) throws -> Pixels {
        let queue = try XCTUnwrap(renderer.device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let rowBytes = (target.width * 4 + 255) / 256 * 256
        let buffer = try XCTUnwrap(
            renderer.device.makeBuffer(
                length: rowBytes * target.height, options: .storageModeShared))
        defer { if command.status == .notEnqueued { command.commit() } }
        try encode(command)
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: target.width, height: target.height, depth: 1),
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
}
