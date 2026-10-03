import Dispatch
import Metal
import XCTest

@testable import FluxLLM

/// Offscreen readback is test-only. These compare the cache with the existing
/// Metal renderer, independently of that renderer's separate Canvas fidelity gate.
@MainActor
final class MetalChartStaticCacheTests: XCTestCase {
    private typealias Cache = MetalChartStaticCache
    private typealias Renderer = MetalFullChartRenderer
    private typealias Scene = MetalFullChartScene
    private let size = CGSize(width: 96, height: 80)

    func testMissingMetalDeviceIsExplicitlyUnavailable() {
        XCTAssertThrowsError(try Cache(device: nil))
    }

    func testCacheCopiesExactDirectPixelsAtOneAndTwoTimesScale() throws {
        let context = try makeContext()
        let scene = detailedScene()
        try context.renderer.update(scene: scene)
        for scale in [1, 2] {
            let directTarget = try texture(context.device, scale: scale)
            let cachedTarget = try texture(context.device, scale: scale)
            let direct = try read(context, target: directTarget) { command in
                try context.renderer.encodeStatic(
                    into: command, target: directTarget, pointSize: scene.size)
            }
            let cached = try read(context, target: cachedTarget) { command in
                XCTAssertTrue(
                    try context.cache.encode(
                        into: command, target: cachedTarget,
                        renderer: context.renderer, scene: scene, revision: 0))
            }
            XCTAssertEqual(
                cached, direct, "The copy must preserve every stored channel at scale \(scale)")
            XCTAssertTrue(cached.contains { $0 != 0 })
            XCTAssertEqual(pixel(cached, x: 10, y: 12, scale: scale), [255, 0, 0, 255])
            XCTAssertEqual(pixel(cached, x: 77, y: 64, scale: scale), [0, 0, 255, 255])
            XCTAssertEqual(
                pixel(cached, x: 10, y: 72, scale: scale), [0, 0, 0, 0], "Reject vertical inversion"
            )
            let overlap = pixel(cached, x: 42, y: 16, scale: scale)
            for (actual, expected) in zip(overlap, [64, 0, 128, 191]) {
                XCTAssertLessThanOrEqual(
                    abs(actual - expected), 1, "Premultiplied channels must not be multiplied again"
                )
            }
            let hit = try read(context, target: cachedTarget) { command in
                XCTAssertFalse(
                    try context.cache.encode(
                        into: command, target: cachedTarget,
                        renderer: context.renderer, scene: scene, revision: 0))
            }
            XCTAssertEqual(hit, direct)
        }
        XCTAssertEqual(context.cache.statistics.rasterizations, 2)
        XCTAssertEqual(context.cache.statistics.composites, 4)
    }

    func testPublicationRevisionIdentitySizeAndRemoveAllInvalidateTheRaster() throws {
        let context = try makeContext()
        let first = solidScene(SIMD4(1, 0, 0, 1))
        let target = try texture(context.device)
        func draw(_ scene: Scene, revision: UInt64, to target: any MTLTexture) throws -> Bool {
            var rasterized = false
            _ = try read(context, target: target) { command in
                rasterized = try context.cache.encode(
                    into: command, target: target,
                    renderer: context.renderer, scene: scene, revision: revision)
            }
            return rasterized
        }
        XCTAssertTrue(try draw(first, revision: 0, to: target))
        for _ in 0..<4 { XCTAssertFalse(try draw(first, revision: 0, to: target)) }
        XCTAssertEqual(
            context.renderer.statistics.encodedFrames, 1,
            "Animation copies do not invoke the expensive renderer")
        XCTAssertEqual(context.cache.statistics.textureAllocations, 1)
        XCTAssertTrue(try draw(first, revision: 1, to: target))
        XCTAssertEqual(
            context.cache.statistics.textureAllocations, 1,
            "Completed same-size texture storage is reused")
        let equalNewPublication = solidScene(SIMD4(1, 0, 0, 1))
        XCTAssertTrue(try draw(equalNewPublication, revision: 1, to: target))
        let logicalResize = Scene(size: CGSize(width: 48, height: 40), primitives: first.primitives)
        XCTAssertTrue(try draw(logicalResize, revision: 1, to: target))
        let larger = try texture(context.device, scale: 2)
        XCTAssertTrue(try draw(logicalResize, revision: 1, to: larger))
        XCTAssertEqual(context.cache.statistics.rasterizations, 5)
        XCTAssertEqual(context.cache.statistics.textureAllocations, 2)
        XCTAssertEqual(context.cache.statistics.retainedTextureVersions, 1)
        XCTAssertGreaterThan(context.cache.statistics.retainedBytes, 0)
        context.cache.removeAll()
        XCTAssertEqual(context.cache.statistics.retainedBytes, 0)
        XCTAssertTrue(try draw(logicalResize, revision: 1, to: larger))
        XCTAssertEqual(context.cache.statistics.rasterizations, 6)
    }

    func testEmptyPublicationReplacesPreviouslyVisibleAndTransparentPixels() throws {
        let context = try makeContext()
        let target = try texture(context.device)
        let populated = try read(context, target: target) { command in
            try context.cache.encode(
                into: command, target: target, renderer: context.renderer,
                scene: detailedScene(), revision: 0)
        }
        XCTAssertTrue(populated.contains { $0 != 0 })
        let empty = Scene(size: size, primitives: [])
        for iteration in 0..<2 {
            let cleared = try read(context, target: target) { command in
                XCTAssertEqual(
                    try context.cache.encode(
                        into: command, target: target,
                        renderer: context.renderer, scene: empty, revision: 1), iteration == 0)
            }
            XCTAssertTrue(
                cleared.allSatisfy { $0 == 0 }, "Empty cache copies must overwrite old pixels")
        }
        XCTAssertEqual(context.cache.statistics.rasterizations, 2)
        XCTAssertEqual(context.cache.statistics.textureAllocations, 1)
    }

    func testInvalidSceneAndCrossQueuePreservePreviouslyCachedPublication() throws {
        let context = try makeContext()
        let scene = solidScene(SIMD4(1, 0, 0, 1))
        let target = try texture(context.device)
        let before = try read(context, target: target) { command in
            try context.cache.encode(
                into: command, target: target, renderer: context.renderer,
                scene: scene, revision: 1)
        }
        let invalid = Scene(size: .zero, primitives: [])
        let rejected = try XCTUnwrap(context.queue.makeCommandBuffer())
        XCTAssertThrowsError(
            try context.cache.encode(
                into: rejected, target: target,
                renderer: context.renderer, scene: invalid, revision: 2))
        let otherQueue = try XCTUnwrap(context.device.makeCommandQueue())
        let wrongQueue = try XCTUnwrap(otherQueue.makeCommandBuffer())
        XCTAssertThrowsError(
            try context.cache.encode(
                into: wrongQueue, target: target,
                renderer: context.renderer, scene: scene, revision: 1)
        ) { error in
            guard case Cache.CacheError.differentCommandQueue = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertEqual(context.cache.statistics.inFlightFrames, 0)
        let after = try read(context, target: target) { command in
            XCTAssertFalse(
                try context.cache.encode(
                    into: command, target: target,
                    renderer: context.renderer, scene: scene, revision: 1))
        }
        XCTAssertEqual(after, before)
        XCTAssertEqual(context.cache.statistics.rasterizations, 1)
    }

    func testQueuedPublicationsRetainDistinctImagesAndStayWithinCapacity() throws {
        let context = try makeContext()
        let colors: [SIMD4<Float>] = [SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1)]
        var commands: [any MTLCommandBuffer] = []
        var targets: [any MTLTexture] = []
        var buffers: [any MTLBuffer] = []
        defer { for command in commands where command.status == .notEnqueued { command.commit() } }
        for index in 0..<Cache.maximumFramesInFlight {
            let target = try texture(context.device)
            let command = try XCTUnwrap(context.queue.makeCommandBuffer())
            commands.append(command)
            targets.append(target)
            XCTAssertTrue(
                try context.cache.encode(
                    into: command, target: target,
                    renderer: context.renderer, scene: solidScene(colors[index]),
                    revision: UInt64(index)))
            buffers.append(try encodeReadback(context.device, command: command, target: target))
        }
        XCTAssertEqual(context.cache.statistics.inFlightFrames, 3)
        XCTAssertEqual(context.cache.statistics.retainedTextureVersions, 3)
        XCTAssertLessThanOrEqual(context.cache.statistics.retainedBytes, Cache.maximumRetainedBytes)
        let excess = try XCTUnwrap(context.queue.makeCommandBuffer())
        XCTAssertThrowsError(
            try context.cache.encode(
                into: excess, target: targets[0],
                renderer: context.renderer, scene: solidScene(colors[0]), revision: 4))
        XCTAssertEqual(context.cache.statistics.rasterizations, 3)
        context.cache.removeAll()
        context.renderer.removeAll()
        XCTAssertEqual(
            context.cache.statistics.retainedTextureVersions, 3,
            "GPU commands own their pending images")
        for command in commands { try complete(command) }
        for index in colors.indices {
            let rgba = rgba(buffers[index], target: targets[index])
            let expected = [
                Int(colors[index].x * 255), Int(colors[index].y * 255), Int(colors[index].z * 255),
                255,
            ]
            XCTAssertEqual(
                pixel(rgba, x: 12, y: 12, scale: 1), expected,
                "Later publications must not overwrite textures used by earlier queued frames")
        }
        XCTAssertEqual(context.cache.statistics.inFlightFrames, 0)
        XCTAssertEqual(context.cache.statistics.retainedTextureVersions, 0)
        XCTAssertEqual(context.cache.statistics.retainedBytes, 0)
    }

    func testQueuedCacheHitsReadOneRasterAfterItsFirstSubmission() throws {
        let context = try makeContext()
        let scene = detailedScene()
        var commands: [any MTLCommandBuffer] = []
        var targets: [any MTLTexture] = []
        var buffers: [any MTLBuffer] = []
        defer { for command in commands where command.status == .notEnqueued { command.commit() } }
        for index in 0..<Cache.maximumFramesInFlight {
            let command = try XCTUnwrap(context.queue.makeCommandBuffer())
            let target = try texture(context.device)
            commands.append(command)
            targets.append(target)
            XCTAssertEqual(
                try context.cache.encode(
                    into: command, target: target,
                    renderer: context.renderer, scene: scene, revision: 0), index == 0)
            buffers.append(try encodeReadback(context.device, command: command, target: target))
        }
        XCTAssertEqual(context.cache.statistics.rasterizations, 1)
        XCTAssertEqual(context.cache.statistics.textureAllocations, 1)
        XCTAssertEqual(context.cache.statistics.retainedTextureVersions, 1)
        for command in commands { try complete(command) }
        let first = rgba(buffers[0], target: targets[0])
        XCTAssertTrue(first.contains { $0 != 0 })
        for index in 1..<commands.count {
            XCTAssertEqual(rgba(buffers[index], target: targets[index]), first)
        }
        XCTAssertEqual(context.cache.statistics.inFlightFrames, 0)
    }

    private struct Context {
        let device: any MTLDevice
        let queue: any MTLCommandQueue
        let renderer: Renderer
        let cache: Cache
    }

    private enum Failure: Error {
        case completionTimedOut
        case commandFailed(String)
    }

    private func makeContext() throws -> Context {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("A Metal device is required for actual raster comparison")
        }
        return try Context(
            device: device, queue: XCTUnwrap(device.makeCommandQueue()),
            renderer: Renderer(device: device), cache: Cache(device: device))
    }

    private func solidScene(_ color: SIMD4<Float>) -> Scene {
        Scene(
            size: size,
            primitives: [
                .init(
                    shape: .roundedRect(CGRect(x: 4, y: 6, width: 20, height: 20), radius: 3),
                    paint: .solid(color))
            ])
    }

    private func detailedScene() -> Scene {
        Scene(
            size: size,
            primitives: [
                .init(
                    shape: .roundedRect(CGRect(x: 4, y: 6, width: 20, height: 20), radius: 3),
                    paint: .solid(SIMD4(1, 0, 0, 1))),
                .init(
                    shape: .ellipse(CGRect(x: 70, y: 56, width: 14, height: 16)),
                    paint: .solid(SIMD4(0, 0, 1, 1))),
                .init(
                    shape: .roundedRect(CGRect(x: 32, y: 8, width: 24, height: 20), radius: 2),
                    paint: .solid(SIMD4(1, 0, 0, 0.5))),
                .init(
                    shape: .roundedRect(CGRect(x: 32, y: 8, width: 24, height: 20), radius: 2),
                    paint: .solid(SIMD4(0, 0, 1, 0.5))),
                .init(
                    shape: .polyline([
                        CGPoint(x: 6, y: 38), CGPoint(x: 30, y: 44), CGPoint(x: 58, y: 36),
                    ]),
                    paint: .solid(SIMD4(1, 0.4, 0, 0.6)), stroke: .init(width: 2, blurRadius: 3)),
                .init(
                    shape: .polyline([CGPoint(x: 6, y: 54), CGPoint(x: 56, y: 54)]),
                    paint: .solid(SIMD4(0, 1, 0, 0.7)), stroke: .init(width: 2, dash: [4, 3])),
                .init(
                    shape: .ellipse(CGRect(x: 62, y: 4, width: 26, height: 28)),
                    paint: .linear(
                        start: CGPoint(x: 62, y: 4), end: CGPoint(x: 88, y: 24),
                        stops: [
                            .init(location: 0, color: SIMD4(0.9, 0.2, 1, 0.3)),
                            .init(location: 1, color: SIMD4(0.1, 0.8, 1, 0.8)),
                        ]),
                    clip: .init(rect: CGRect(x: 64, y: 8, width: 18, height: 16), radius: 3)),
            ])
    }

    private func texture(_ device: any MTLDevice, scale: Int = 1) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width) * scale, height: Int(size.height) * scale, mipmapped: false)
        descriptor.storageMode = .private
        // The destination is never sampled, matching a framebuffer-only drawable.
        descriptor.usage = [.renderTarget]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func read(
        _ context: Context, target: any MTLTexture,
        encode: (any MTLCommandBuffer) throws -> Void
    ) throws -> [UInt8] {
        let command = try XCTUnwrap(context.queue.makeCommandBuffer())
        defer { if command.status == .notEnqueued { command.commit() } }
        try encode(command)
        let buffer = try encodeReadback(context.device, command: command, target: target)
        try complete(command)
        return rgba(buffer, target: target)
    }

    private func encodeReadback(
        _ device: any MTLDevice, command: any MTLCommandBuffer,
        target: any MTLTexture
    ) throws -> any MTLBuffer {
        let rowBytes = (target.width * 4 + 255) / 256 * 256
        let buffer = try XCTUnwrap(
            device.makeBuffer(length: rowBytes * target.height, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: target.width, height: target.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * target.height)
        blit.endEncoding()
        return buffer
    }

    private func complete(_ command: any MTLCommandBuffer) throws {
        let semaphore = DispatchSemaphore(value: 0)
        command.addCompletedHandler { _ in semaphore.signal() }
        command.commit()
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw Failure.completionTimedOut
        }
        guard command.status == .completed, command.error == nil else {
            throw Failure.commandFailed(String(describing: command.error))
        }
    }

    private func rgba(_ buffer: any MTLBuffer, target: any MTLTexture) -> [UInt8] {
        let rowBytes = (target.width * 4 + 255) / 256 * 256
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var result = [UInt8](repeating: 0, count: target.width * target.height * 4)
        for y in 0..<target.height {
            for x in 0..<target.width {
                let input = y * rowBytes + x * 4
                let output = (y * target.width + x) * 4
                result[output] = source[input + 2]
                result[output + 1] = source[input + 1]
                result[output + 2] = source[input]
                result[output + 3] = source[input + 3]
            }
        }
        return result
    }

    private func pixel(_ rgba: [UInt8], x: Int, y: Int, scale: Int) -> [Int] {
        let offset = ((y * scale) * Int(size.width) * scale + x * scale) * 4
        return rgba[offset..<(offset + 4)].map(Int.init)
    }
}
