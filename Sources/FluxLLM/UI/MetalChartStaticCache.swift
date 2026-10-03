import Foundation
import Metal

/// Rasterizes an immutable chart publication once, then copies its exact stored
/// pixels while effects animate. The cache has no CPU readback or GPU wait.
@MainActor
final class MetalChartStaticCache {
    enum CacheError: Error, CustomStringConvertible {
        case deviceUnavailable, shaderFunctionUnavailable, textureAllocationFailed
        case pipelineCreation(String)
        case unsupportedTarget, differentCommandQueue
        case encoderUnavailable, capacityExceeded, commandExecutionFailed

        var description: String {
            switch self {
            case .deviceUnavailable: "Metal device unavailable for chart texture cache"
            case .shaderFunctionUnavailable: "Chart texture cache shader unavailable"
            case .textureAllocationFailed: "Chart texture cache allocation failed"
            case .pipelineCreation(let reason): "Chart texture cache pipeline failed: \(reason)"
            case .unsupportedTarget:
                "Chart texture cache requires a same-device BGRA8Unorm 2D render target"
            case .differentCommandQueue:
                "Chart texture cache commands must use one ordered command queue"
            case .encoderUnavailable: "Chart texture cache render encoder unavailable"
            case .capacityExceeded: "Chart texture cache resource capacity exceeded"
            case .commandExecutionFailed: "A chart texture cache command failed on the GPU"
            }
        }
    }

    struct Statistics {
        let rasterizations: UInt64
        let composites: UInt64
        let textureAllocations: UInt64
        let retainedBytes: Int
        let retainedTextureVersions: Int
        let inFlightFrames: Int
    }

    static let maximumFramesInFlight = 3
    static let maximumRetainedTextureVersions = 3
    static let maximumTextureBytes = 32 * 1_024 * 1_024
    static let maximumRetainedBytes = maximumRetainedTextureVersions * maximumTextureBytes

    private struct Key: Equatable {
        let scene: ObjectIdentifier
        let revision: UInt64
        let width: Int
        let height: Int
        let pointSize: CGSize
    }

    private final class CachedImage: @unchecked Sendable {
        let texture: any MTLTexture
        let key: Key
        // Retaining the publication prevents object identity reuse.
        let scene: MetalFullChartScene
        var bytes: Int { texture.allocatedSize }

        init(texture: any MTLTexture, key: Key, scene: MetalFullChartScene) {
            self.texture = texture
            self.key = key
            self.scene = scene
        }
    }

    let device: any MTLDevice
    private let pipeline: any MTLRenderPipelineState
    private let leases = FrameLeases()
    private var queue: (any MTLCommandQueue)?
    private var current: CachedImage?
    private var rasterizations: UInt64 = 0
    private var composites: UInt64 = 0
    private var textureAllocations: UInt64 = 0

    init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw CacheError.deviceUnavailable }
        self.device = device
        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = false
            let library = try device.makeLibrary(source: Self.shader, options: options)
            guard let vertex = library.makeFunction(name: "cachedChartVertex"),
                let fragment = library.makeFunction(name: "cachedChartFragment")
            else {
                throw CacheError.shaderFunctionUnavailable
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "FluxLLM cached static chart pixels"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = MetalFullChartRenderer.pixelFormat
            // Pixels already contain premultiplied source-over composition.
            // Replacement, including transparent pixels, must not blend again.
            descriptor.colorAttachments[0].isBlendingEnabled = false
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch let error as CacheError {
            throw error
        } catch {
            throw CacheError.pipelineCreation(String(describing: error))
        }
    }

    var statistics: Statistics {
        let retained = leases.snapshot(including: current)
        return Statistics(
            rasterizations: rasterizations, composites: composites,
            textureAllocations: textureAllocations, retainedBytes: retained.bytes,
            retainedTextureVersions: retained.versions, inFlightFrames: retained.frames)
    }

    /// Commands must be committed in call order on the same queue, including
    /// commands for which this method throws after encoding has begun. The
    /// native host owns that queue and commits each frame immediately. Metal's
    /// tracked texture hazards order later reads after publication rasterization.
    /// The returned flag records a static rasterization rather than a pixel copy.
    @discardableResult
    func encode(
        into commandBuffer: any MTLCommandBuffer, target: any MTLTexture,
        renderer: MetalFullChartRenderer, scene: MetalFullChartScene,
        revision: UInt64
    ) throws -> Bool {
        guard commandBuffer.device.registryID == device.registryID,
            renderer.device.registryID == device.registryID,
            target.device.registryID == device.registryID,
            target.pixelFormat == MetalFullChartRenderer.pixelFormat,
            target.textureType == .type2D, target.sampleCount == 1,
            target.width > 0, target.height > 0,
            target.width <= 16_384, target.height <= 16_384,
            target.usage.contains(.renderTarget)
        else { throw CacheError.unsupportedTarget }
        if let queue, ObjectIdentifier(queue) != ObjectIdentifier(commandBuffer.commandQueue) {
            throw CacheError.differentCommandQueue
        }
        guard !leases.hasFailedCommand else { throw CacheError.commandExecutionFailed }
        guard leases.snapshot(including: current).frames < Self.maximumFramesInFlight else {
            throw CacheError.capacityExceeded
        }
        let key = Key(
            scene: ObjectIdentifier(scene), revision: revision,
            width: target.width, height: target.height, pointSize: scene.size)
        let rasterized = current?.key != key
        let image: CachedImage
        if rasterized {
            // Validate/build the publication before changing the last cached
            // image. Invalid input keeps that image available for the old key.
            try renderer.update(scene: scene)
            let texture: any MTLTexture
            if let previous = current, previous.texture.width == target.width,
                previous.texture.height == target.height, !leases.contains(previous)
            {
                texture = previous.texture
            } else {
                let minimumBytes = target.width * target.height * 4
                let retained = leases.snapshot(including: current)
                guard minimumBytes <= Self.maximumTextureBytes,
                    retained.versions < Self.maximumRetainedTextureVersions,
                    minimumBytes <= Self.maximumRetainedBytes - retained.bytes
                else {
                    throw CacheError.capacityExceeded
                }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: MetalFullChartRenderer.pixelFormat,
                    width: target.width, height: target.height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.hazardTrackingMode = .tracked
                let allocationBytes = device.heapTextureSizeAndAlign(descriptor: descriptor).size
                guard allocationBytes <= Self.maximumTextureBytes,
                    allocationBytes <= Self.maximumRetainedBytes - retained.bytes
                else {
                    throw CacheError.capacityExceeded
                }
                guard let replacement = device.makeTexture(descriptor: descriptor) else {
                    throw CacheError.textureAllocationFailed
                }
                guard replacement.allocatedSize <= Self.maximumTextureBytes,
                    replacement.allocatedSize <= Self.maximumRetainedBytes - retained.bytes
                else {
                    throw CacheError.capacityExceeded
                }
                replacement.label = "FluxLLM retained static chart raster"
                texture = replacement
                textureAllocations &+= 1
            }
            image = CachedImage(texture: texture, key: key, scene: scene)
        } else {
            image = current!
        }
        guard let lease = leases.begin(image, limit: Self.maximumFramesInFlight) else {
            throw CacheError.capacityExceeded
        }
        let leases = leases
        commandBuffer.addCompletedHandler { command in
            leases.finish(lease, failed: command.status != .completed || command.error != nil)
        }
        queue = commandBuffer.commandQueue
        do {
            if rasterized {
                try renderer.encodeStatic(
                    into: commandBuffer, target: image.texture, pointSize: scene.size)
                current = image
                rasterizations &+= 1
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw CacheError.encoderUnavailable
            }
            encoder.label = "FluxLLM copy cached static chart pixels"
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(image.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            composites &+= 1
            return rasterized
        } catch {
            // The caller commits any work already encoded. Do not subsequently
            // reuse an image after an incomplete render/composite operation.
            current = nil
            throw error
        }
    }

    /// In-flight commands retain their images until GPU completion. The next
    /// encode is a cache miss, even when the same publication is supplied again.
    /// GPU failure remains terminal for this cache; the host must replace it.
    func removeAll() {
        current = nil
        queue = nil
    }

    private final class FrameLeases: @unchecked Sendable {
        private let lock = NSLock()
        private var nextID: UInt64 = 0
        private var active: [UInt64: CachedImage] = [:]
        private var failed = false

        var hasFailedCommand: Bool {
            lock.lock()
            defer { lock.unlock() }
            return failed
        }

        func contains(_ image: CachedImage) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return active.values.contains { $0 === image }
        }

        func begin(_ image: CachedImage, limit: Int) -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            guard active.count < limit else { return nil }
            nextID &+= 1
            active[nextID] = image
            return nextID
        }

        func finish(_ id: UInt64, failed: Bool) {
            lock.lock()
            defer { lock.unlock() }
            active.removeValue(forKey: id)
            self.failed = self.failed || failed
        }

        func snapshot(including current: CachedImage?) -> (frames: Int, versions: Int, bytes: Int) {
            lock.lock()
            defer { lock.unlock() }
            var textures: [ObjectIdentifier: any MTLTexture] = [:]
            for image in active.values { textures[ObjectIdentifier(image.texture)] = image.texture }
            if let current { textures[ObjectIdentifier(current.texture)] = current.texture }
            return (
                active.count, textures.count, textures.values.reduce(0) { $0 + $1.allocatedSize }
            )
        }
    }

    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 cachedChartVertex(uint vertexID [[vertex_id]]) {
            const float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
            return float4(positions[vertexID], 0, 1);
        }
        fragment float4 cachedChartFragment(float4 position [[position]],
                                           texture2d<float, access::read> cached [[texture(0)]]) {
            // Raster position and texture coordinates share a top-left origin.
            // Integer reads preserve all BGRA8 channel values and premultiplication.
            return cached.read(uint2(position.xy));
        }
        """
}
