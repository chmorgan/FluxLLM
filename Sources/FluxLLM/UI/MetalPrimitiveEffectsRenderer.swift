import Foundation
import Metal
import simd

/// Experimental lifecycle primitives. Immutable episode descriptors are retained;
/// a GPU dispatch evaluates each particle once and builds ordered, bounded quads.
/// Channel strokes are unioned into three maximum-blended coverage masks. Forks
/// retain their own source-over order and scan only their three local segments.
/// No production frame reads GPU storage, waits, or rebuilds paths on the CPU.
@MainActor
final class MetalPrimitiveEffectsRenderer {
    typealias Effect = MetalFullChartEffectsRenderer.Effect
    typealias Twinkle = MetalFullChartEffectsRenderer.Twinkle
    typealias Element = MetalFullChartEffectsRenderer.Element
    typealias EncodedContent = MetalFullChartEffectsRenderer.EncodedContent
    struct Statistics {
        let descriptorUploads: UInt64
        let encodedFrames: UInt64
        let inFlightFrames: Int
        let retainedDescriptorBuffers: Int
        let retainedDescriptorBytes: Int
        let retainedFrameBytes: Int
        let elementCount: Int
        let renderDraws: UInt64
        let computeDispatches: UInt64
        let maskPasses: UInt64
        let retainedMaskBytes: Int
    }
    enum RendererError: Error {
        case deviceUnavailable, shaderUnavailable, allocationFailed, invalidInput
        case capacityExceeded, unsupportedTarget, encoderUnavailable, tooManyFramesInFlight
    }
    static let maximumEffects = 64
    static let maximumTwinkles = 2
    static let maximumFramesInFlight = 3
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    private static let maximumPrimitives = 267  // two 13-part bursts, 240 forks, channel
    // Lightning frame + five float4 rows per primitive + two indirect draw records.
    private static let lightningBytes = (3 + 242 + 240 * 4) * MemoryLayout<SIMD4<Float>>.stride
    private static let frameStride = lightningBytes + maximumPrimitives * 80 + 32
    private static let primitiveDrawOffset = lightningBytes + maximumPrimitives * 80
    private static let maskDrawOffset = primitiveDrawOffset + 16
    static let maximumMaskBytes = 32 * 1024 * 1024
    let device: any MTLDevice
    private let pipeline: any MTLRenderPipelineState
    private let computePipeline: any MTLComputePipelineState
    private let maskPipeline: any MTLRenderPipelineState
    private let leases = FrameLeases()
    private var elements: [Element] = []
    private var hasCompletionDescriptors = false
    private var descriptors: (any MTLBuffer)?
    private var offsets: (any MTLBuffer)?
    private var descriptorUploads: UInt64 = 0
    private var encodedFrames: UInt64 = 0
    private var renderDraws: UInt64 = 0
    private var computeDispatches: UInt64 = 0
    private var maskPasses: UInt64 = 0

    init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RendererError.deviceUnavailable }
        self.device = device
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: Self.shader, options: options)
        guard let vertex = library.makeFunction(name: "fullEffectsVertex"),
            let fragment = library.makeFunction(name: "fullEffectsFragment"),
            let compute = library.makeFunction(name: "primitiveEffectsFrame"),
            let maskVertex = library.makeFunction(name: "primitiveChannelVertex"),
            let maskFragment = library.makeFunction(name: "primitiveChannelFragment")
        else {
            throw RendererError.shaderUnavailable
        }
        computePipeline = try device.makeComputePipelineState(function: compute)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "FluxLLM bounded lifecycle primitives"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = Self.pixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let masks = MTLRenderPipelineDescriptor()
        masks.label = "FluxLLM lightning channel coverage union"
        masks.vertexFunction = maskVertex
        masks.fragmentFunction = maskFragment
        masks.inputPrimitiveTopology = .triangle
        for index in 0..<3 {
            let attachment = masks.colorAttachments[index]!
            attachment.pixelFormat = .r8Unorm
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .max
            attachment.alphaBlendOperation = .max
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }
        maskPipeline = try device.makeRenderPipelineState(descriptor: masks)
    }

    var statistics: Statistics {
        let snapshot = leases.snapshot(descriptors: descriptors, offsets: offsets)
        return Statistics(
            descriptorUploads: descriptorUploads, encodedFrames: encodedFrames,
            inFlightFrames: snapshot.frames, retainedDescriptorBuffers: snapshot.buffers,
            retainedDescriptorBytes: snapshot.bytes, retainedFrameBytes: snapshot.frameBytes,
            elementCount: elements.count, renderDraws: renderDraws,
            computeDispatches: computeDispatches, maskPasses: maskPasses,
            retainedMaskBytes: snapshot.maskBytes)
    }

    /// Atomic publication: a rejected descriptor leaves the last valid scene intact.
    func update(elements newElements: [Element]) throws {
        guard newElements != elements else { return }
        guard newElements.count <= Self.maximumEffects + Self.maximumTwinkles else {
            throw RendererError.capacityExceeded
        }
        var packed: [SIMD4<Float>] = []
        var starts: [UInt32] = []
        var effectIDs: Set<RequestRailLifecycleEffects.Key> = []
        var twinkleIDs: Set<RequestRailTwinkle.ID> = []
        for element in newElements {
            starts.append(UInt32(packed.count))
            switch element {
            case .effect(let effect):
                guard effectIDs.insert(effect.id).inserted,
                    effectIDs.count <= Self.maximumEffects
                else { throw RendererError.invalidInput }
                try Self.append(effect, to: &packed)
            case .twinkle(let twinkle):
                guard twinkleIDs.insert(twinkle.twinkle.id).inserted,
                    twinkleIDs.count <= Self.maximumTwinkles
                else { throw RendererError.invalidInput }
                try Self.append(twinkle, to: &packed)
            }
        }
        guard !packed.isEmpty else {
            removeAll()
            return
        }
        let buffer = packed.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        let offsets = starts.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        guard let buffer, let offsets else { throw RendererError.allocationFailed }
        buffer.label = "FluxLLM immutable full chart effect descriptors"
        offsets.label = "FluxLLM full chart effect offsets"
        descriptors = buffer
        self.offsets = offsets
        elements = newElements
        hasCompletionDescriptors = newElements.contains {
            if case .effect(let effect) = $0 { return effect.profile.completion }
            return false
        }
        descriptorUploads &+= 1
    }

    func removeAll() {
        elements.removeAll(keepingCapacity: false)
        hasCompletionDescriptors = false
        descriptors = nil
        offsets = nil
        leases.discardUnusedFrames()
    }

    /// Encodes GPU frame preparation, one batched mask pass, then ordered effects.
    /// A successfully leased command must be committed even if a later encoder fails.
    @discardableResult
    func encode(
        into commandBuffer: any MTLCommandBuffer, target: any MTLTexture,
        elapsedTime: TimeInterval, pointSize: CGSize, origin: CGPoint = .zero,
        clear: Bool = false
    ) throws -> EncodedContent {
        guard target.device.registryID == device.registryID,
            commandBuffer.device.registryID == device.registryID,
            target.pixelFormat == Self.pixelFormat, target.textureType == .type2D,
            target.sampleCount == 1, target.width > 0, target.height > 0,
            target.usage.contains(.renderTarget)
        else { throw RendererError.unsupportedTarget }
        guard Self.validTime(elapsedTime), Self.finite(pointSize.width),
            Self.finite(pointSize.height),
            pointSize.width > 0, pointSize.height > 0,
            Self.finite(origin.x), Self.finite(origin.y)
        else { throw RendererError.invalidInput }
        var content = encodedContent(at: elapsedTime)
        if elements.isEmpty && !clear { return content }
        let scaleY = Double(target.height) / pointSize.height
        guard scaleY.isFinite, scaleY > 0, scaleY * 16 <= Double(Int.max) else {
            throw RendererError.invalidInput
        }
        let maskHeight = max(1, Int(ceil(scaleY * 16)))
        let maskCount = max(1, elements.count)
        guard target.width <= Self.maximumMaskBytes / maskHeight / maskCount / 3 else {
            throw RendererError.capacityExceeded
        }
        guard
            let lease = try leases.begin(
                device: device, descriptors: descriptors, offsets: offsets,
                frameBytes: maskCount * Self.frameStride,
                maskWidth: target.width, maskHeight: maskHeight, maskCount: maskCount,
                needsMasks: hasCompletionDescriptors, limit: Self.maximumFramesInFlight
            )
        else { throw RendererError.tooManyFramesInFlight }
        content.frameStorageChanged = lease.storageChanged
        let leases = leases
        let ticket = lease.id
        commandBuffer.addCompletedHandler { _ in leases.finish(ticket) }
        let uniform = [
            SIMD4<Float>(
                Float(pointSize.width), Float(pointSize.height), Float(origin.x), Float(origin.y)),
            SIMD4<Float>(
                Float(elapsedTime), Float(elements.count), Float(pointSize.width),
                Float(Double(maskHeight) / scaleY)),
            SIMD4<Float>(
                Float(target.width) / Float(pointSize.width),
                Float(target.height) / Float(pointSize.height), 0, 0),
        ]
        if let descriptors, let offsets, !elements.isEmpty {
            guard let compute = commandBuffer.makeComputeCommandEncoder() else {
                throw RendererError.encoderUnavailable
            }
            compute.label = "FluxLLM GPU lifecycle primitive preparation"
            compute.setComputePipelineState(computePipeline)
            compute.setBuffer(descriptors, offset: 0, index: 0)
            compute.setBuffer(offsets, offset: 0, index: 2)
            compute.setBuffer(lease.frame, offset: 0, index: 3)
            uniform.withUnsafeBytes {
                compute.setBytes($0.baseAddress!, length: $0.count, index: 1)
            }
            compute.dispatchThreads(
                MTLSize(width: elements.count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: min(elements.count, computePipeline.threadExecutionWidth), height: 1,
                    depth: 1))
            compute.endEncoding()
            computeDispatches &+= 1
            if hasCompletionDescriptors {
                let maskPass = MTLRenderPassDescriptor()
                maskPass.renderTargetArrayLength = elements.count
                for index in 0..<3 {
                    let attachment = maskPass.colorAttachments[index]!
                    attachment.texture = lease.masks[index]
                    attachment.loadAction = .clear
                    attachment.storeAction = .store
                    attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
                }
                guard let maskEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: maskPass)
                else {
                    throw RendererError.encoderUnavailable
                }
                maskEncoder.label = "FluxLLM batched channel segment coverage union"
                maskEncoder.setRenderPipelineState(maskPipeline)
                maskEncoder.setVertexBuffer(lease.frame, offset: 0, index: 3)
                maskEncoder.setFragmentBuffer(lease.frame, offset: 0, index: 3)
                uniform.withUnsafeBytes {
                    maskEncoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                    maskEncoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
                }
                for (index, element) in elements.enumerated() {
                    guard case .effect(let effect) = element, effect.profile.completion else {
                        continue
                    }
                    maskEncoder.drawPrimitives(
                        type: .triangle, indirectBuffer: lease.frame,
                        indirectBufferOffset: index * Self.frameStride + Self.maskDrawOffset)
                    renderDraws &+= 1
                }
                maskEncoder.endEncoding()
                maskPasses &+= 1
            }
        }
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = clear ? .clear : .load
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RendererError.encoderUnavailable
        }
        encoder.label = "FluxLLM ordered bounded lifecycle quads"
        if let descriptors, let offsets, !elements.isEmpty {
            encoder.setRenderPipelineState(pipeline)
            for index in [0, 2, 3] {
                let buffer = index == 0 ? descriptors : index == 2 ? offsets : lease.frame
                encoder.setVertexBuffer(buffer, offset: 0, index: index)
                encoder.setFragmentBuffer(buffer, offset: 0, index: index)
            }
            for (index, texture) in lease.masks.enumerated() {
                encoder.setFragmentTexture(texture, index: index)
            }
            uniform.withUnsafeBytes {
                encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
            }
            for index in elements.indices {
                encoder.drawPrimitives(
                    type: .triangle, indirectBuffer: lease.frame,
                    indirectBufferOffset: index * Self.frameStride + Self.primitiveDrawOffset)
                renderDraws &+= 1
            }
        }
        encoder.endEncoding()
        encodedFrames &+= 1
        return content
    }

    private func encodedContent(at time: TimeInterval) -> EncodedContent {
        var arrivals = 0
        var completions = 0
        var twinkles = 0
        for element in elements {
            switch element {
            case .effect(let effect):
                let age = time - effect.startTime
                guard age >= 0, age < effect.profile.visibleDuration else { continue }
                if effect.profile.completion { completions += 1 } else { arrivals += 1 }
            case .twinkle(let twinkle):
                let age = time - twinkle.startTime
                if age > 0, age < twinkle.twinkle.duration { twinkles += 1 }
            }
        }
        return EncodedContent(
            arrivalBursts: arrivals, completionEffects: completions, twinkles: twinkles)
    }

    private static func finite<T: BinaryFloatingPoint>(_ value: T) -> Bool {
        value.isFinite && Float(value).isFinite
    }
    private static func validTime(_ value: TimeInterval) -> Bool {
        finite(value) && abs(value) <= 86_400
    }
    private static func validColor(_ color: SIMD4<Float>) -> Bool {
        (0..<4).allSatisfy { color[$0].isFinite && (0...1).contains(color[$0]) }
    }
    private static func validRect(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy {
            finite($0)
        }
            && rect.width > 0 && rect.height > 0
    }

    private static func append(_ effect: Effect, to packed: inout [SIMD4<Float>]) throws {
        let profile = effect.profile
        let count = profile.family == .fireflies ? 4 : 5
        guard effect.id.completion == profile.completion, validTime(effect.startTime),
            validRect(effect.rect), finite(effect.cornerRadius), effect.cornerRadius >= 0,
            validColor(effect.color), profile.particles.count == count,
            finite(profile.burstDuration), profile.burstDuration > 0, profile.burstDuration <= 1,
            finite(profile.size), (0.9...1.1).contains(profile.size), finite(profile.angle)
        else {
            throw RendererError.invalidInput
        }
        let family: Float = profile.family == .fireflies ? 0 : profile.family == .sparks ? 1 : 2
        let x = profile.completion ? effect.rect.maxX : effect.rect.minX + effect.cornerRadius
        packed.append(
            SIMD4(
                Float(x), Float(effect.rect.midY), Float(effect.startTime),
                Float(profile.burstDuration)))
        packed.append(
            SIMD4(family, Float(profile.size), Float(profile.angle), profile.completion ? 2 : 0))
        packed.append(effect.color)
        for particle in profile.particles {
            guard
                [
                    particle.angle, particle.distance, particle.length, particle.size,
                    particle.delay, particle.life, particle.stretch,
                ].allSatisfy({ finite($0) }),
                particle.life > 0, particle.size > 0
            else { throw RendererError.invalidInput }
            packed.append(
                SIMD4(
                    Float(particle.angle), Float(particle.distance), Float(particle.length),
                    Float(particle.size)))
            packed.append(
                SIMD4(Float(particle.delay), Float(particle.life), Float(particle.stretch), 0))
        }
        if count == 4 {
            packed.append(.zero)
            packed.append(.zero)
        }
        guard profile.completion else { return }
        guard
            [
                profile.surgeDuration, profile.surgeDelay, profile.direction, profile.bend,
                profile.trail,
            ].allSatisfy({ finite($0) }),
            profile.surgeDuration > 0, profile.channel.count == 256,
            profile.crackles.count == 32, profile.flashAt.count == 2,
            profile.flashAt.allSatisfy({ finite($0) })
        else { throw RendererError.invalidInput }
        let routeLength = Double(RequestRailPerimeter(rect: effect.rect).length)
        guard finite(routeLength), routeLength > 0 else { throw RendererError.invalidInput }
        let channelCount = max(8, min(240, Int(ceil(routeLength / 6.5))))
        let total = profile.channel.prefix(channelCount).reduce(0) { $0 + $1.weight }
        guard finite(total), total > 0 else { throw RendererError.invalidInput }
        packed.append(
            SIMD4(
                Float(effect.rect.minX), Float(effect.rect.minY), Float(effect.rect.width),
                Float(effect.rect.height)))
        packed.append(
            SIMD4(
                Float(profile.surgeDelay), Float(profile.surgeDuration), Float(profile.direction),
                Float(profile.bend)))
        packed.append(
            SIMD4(
                Float(profile.trail), profile.explodes ? 1 : 0, Float(channelCount),
                Float(profile.flashAt[0])))
        let channelOffset = packed.count + 1
        let crackleOffset = channelOffset + channelCount * 2
        packed.append(
            SIMD4(
                Float(profile.flashAt[1]), Float(channelOffset), Float(crackleOffset),
                Float(profile.crackles.count)))
        var sum = 0.0
        for channel in profile.channel.prefix(channelCount) {
            guard
                [channel.weight, channel.offset, channel.reach, channel.depth, channel.kink]
                    .allSatisfy({ finite($0) }),
                channel.weight > 0
            else { throw RendererError.invalidInput }
            sum += channel.weight
            packed.append(
                SIMD4(
                    Float(routeLength * sum / total), Float(channel.offset), Float(channel.reach),
                    Float(channel.depth)))
            packed.append(SIMD4(Float(channel.kink), 0, 0, 0))
        }
        for crackle in profile.crackles {
            guard finite(crackle.at), finite(crackle.brightness), crackle.offsets.count == 256,
                crackle.forks.count == 256
            else { throw RendererError.invalidInput }
            packed.append(SIMD4(Float(crackle.at), Float(crackle.brightness), 0, 0))
            for index in stride(from: 0, to: channelCount, by: 2) {
                let next = min(index + 1, channelCount - 1)
                let values = SIMD4<Float>(
                    Float(crackle.offsets[index]), Float(crackle.forks[index]),
                    Float(crackle.offsets[next]), Float(crackle.forks[next]))
                guard (0..<4).allSatisfy({ values[$0].isFinite }) else {
                    throw RendererError.invalidInput
                }
                packed.append(values)
            }
        }
    }

    private static func append(_ input: Twinkle, to packed: inout [SIMD4<Float>]) throws {
        let twinkle = input.twinkle
        let placement = input.placement
        let bar = placement.bar
        guard validTime(input.startTime), validColor(input.color), validRect(bar),
            finite(placement.center.x), finite(placement.center.y),
            finite(placement.cornerRadius), placement.cornerRadius >= 0,
            finite(twinkle.duration), twinkle.duration > 0, twinkle.duration <= 1,
            finite(twinkle.size), twinkle.size > 0, twinkle.size <= 3.3,
            finite(twinkle.angle)
        else { throw RendererError.invalidInput }
        packed.append(
            SIMD4(
                Float(placement.center.x), Float(placement.center.y), Float(input.startTime),
                Float(twinkle.duration)))
        packed.append(SIMD4(twinkle.star ? 1 : 0, Float(twinkle.size), Float(twinkle.angle), 1))
        packed.append(input.color)
        packed.append(SIMD4(Float(bar.minX), Float(bar.minY), Float(bar.width), Float(bar.height)))
        packed.append(SIMD4(Float(placement.cornerRadius), 0, 0, 0))
        for _ in 0..<8 { packed.append(.zero) }
    }

    private final class FrameLeases: @unchecked Sendable {
        struct Ticket {
            let id: UInt64
            let frame: any MTLBuffer
            let masks: [any MTLTexture]
            let storageChanged: Bool
        }
        private struct Storage {
            let frame: any MTLBuffer
            let masks: [any MTLTexture]
        }
        private struct Lease {
            let descriptors: (any MTLBuffer)?
            let offsets: (any MTLBuffer)?
            let slot: Int
        }
        private let lock = NSLock()
        private var nextID: UInt64 = 0
        private var active: [UInt64: Lease] = [:]
        private var storage: [Int: Storage] = [:]
        private var discardOnFinish = false

        func begin(
            device: any MTLDevice, descriptors: (any MTLBuffer)?, offsets: (any MTLBuffer)?,
            frameBytes: Int, maskWidth: Int, maskHeight: Int, maskCount: Int,
            needsMasks: Bool, limit: Int
        ) throws -> Ticket? {
            lock.lock()
            defer { lock.unlock() }
            let busy = Set(active.values.map(\.slot))
            guard let slot = (0..<limit).first(where: { !busy.contains($0) }) else { return nil }
            let previous = storage[slot]
            var changed = previous == nil || previous!.frame.length < frameBytes
            let frame: any MTLBuffer
            if changed {
                guard
                    let buffer = device.makeBuffer(length: frameBytes, options: .storageModePrivate)
                else {
                    throw RendererError.allocationFailed
                }
                buffer.label = "FluxLLM bounded GPU lifecycle frame \(slot)"
                frame = buffer
            } else {
                frame = previous!.frame
            }
            var masks = previous?.masks ?? []
            if masks.count != 3
                || (needsMasks
                    && (masks[0].width != maskWidth || masks[0].height != maskHeight
                        || masks[0].arrayLength != maskCount))
            {
                let descriptor = MTLTextureDescriptor()
                descriptor.textureType = .type2DArray
                descriptor.pixelFormat = .r8Unorm
                descriptor.width = needsMasks ? maskWidth : 1
                descriptor.height = needsMasks ? maskHeight : 1
                descriptor.arrayLength = needsMasks ? maskCount : 1
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                masks = try (0..<3).map { index in
                    guard let texture = device.makeTexture(descriptor: descriptor) else {
                        throw RendererError.allocationFailed
                    }
                    texture.label = "FluxLLM channel coverage \(slot):\(index)"
                    return texture
                }
                changed = true
            }
            storage[slot] = Storage(frame: frame, masks: masks)
            discardOnFinish = false
            nextID &+= 1
            active[nextID] = Lease(descriptors: descriptors, offsets: offsets, slot: slot)
            return Ticket(id: nextID, frame: frame, masks: masks, storageChanged: changed)
        }
        func finish(_ id: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            if let lease = active.removeValue(forKey: id), discardOnFinish {
                storage.removeValue(forKey: lease.slot)
            }
        }
        func discardUnusedFrames() {
            lock.lock()
            defer { lock.unlock() }
            discardOnFinish = true
            let busy = Set(active.values.map(\.slot))
            storage = storage.filter { busy.contains($0.key) }
        }
        func snapshot(descriptors: (any MTLBuffer)?, offsets: (any MTLBuffer)?)
            -> (frames: Int, buffers: Int, bytes: Int, frameBytes: Int, maskBytes: Int)
        {
            lock.lock()
            defer { lock.unlock() }
            var unique: [ObjectIdentifier: any MTLBuffer] = [:]
            for buffer in [descriptors, offsets] {
                if let buffer { unique[ObjectIdentifier(buffer)] = buffer }
            }
            for lease in active.values {
                for buffer in [lease.descriptors, lease.offsets] {
                    if let buffer { unique[ObjectIdentifier(buffer)] = buffer }
                }
            }
            let maskBytes = storage.values.reduce(0) { result, item in
                result + item.masks.reduce(0) { $0 + $1.allocatedSize }
            }
            return (
                active.count, unique.count, unique.values.reduce(0) { $0 + $1.length },
                storage.values.reduce(maskBytes) { $0 + $1.frame.length }, maskBytes
            )
        }
    }

    private static let shader = #"""
        #include <metal_stdlib>
        using namespace metal;
        struct Uniforms { float4 viewport; float4 time; float4 scale; };
        struct LightningFrame {
            float4 info;
            float4 bounds;
            float4 head;
            float4 points[242];
            float4 forks[960];
        };
        constant uint PrimitiveCount=267;
        struct Primitive { float4 bounds; float4 shape; float4 extra; float4 state; float4 color; };
        struct EffectFrame {
            LightningFrame lightning;
            Primitive primitives[267];
            uint4 draws;
            uint4 maskDraws;
        };
        struct VertexOut {
            float4 position [[position]];
            float2 point;
            uint element [[flat]];
            uint primitive [[flat]];
        };
        struct MaskVertex {
            float4 position [[position]];
            float2 point;
            uint element [[flat]];
            uint segment [[flat]];
            uint layer [[render_target_array_index]];
        };
        struct ChannelMasks { float4 glow [[color(0)]]; float4 color [[color(1)]]; float4 white [[color(2)]]; };

        float smoothUnit(float value) { float p=clamp(value,0.0f,1.0f); return p*p*(3.0f-2.0f*p); }
        float perimeterLength(float4 rect) {
            float r=min(rect.z,rect.w)*0.5f;
            return 2.0f*(rect.z+rect.w-4.0f*r)+2.0f*M_PI_F*r;
        }
        float2 routePoint(float4 rect,float distance) {
            float r=min(rect.z,rect.w)*0.5f;
            float length=perimeterLength(rect);
            float d=fmod(fmod(distance,length)+length,length);
            float vertical=rect.w-2.0f*r, horizontal=rect.z-2.0f*r;
            float halfVertical=vertical*0.5f, arc=M_PI_F*r*0.5f;
            float right=rect.x+rect.z, bottom=rect.y+rect.w;
            if(d<halfVertical) return float2(right,rect.y+rect.w*0.5f+d);
            d-=halfVertical;
            if(d<arc) { float a=d/r; return float2(right-r,bottom-r)+r*float2(cos(a),sin(a)); }
            d-=arc;
            if(d<horizontal) return float2(right-r-d,bottom);
            d-=horizontal;
            if(d<arc) { float a=M_PI_F*0.5f+d/r; return float2(rect.x+r,bottom-r)+r*float2(cos(a),sin(a)); }
            d-=arc;
            if(d<vertical) return float2(rect.x,bottom-r-d);
            d-=vertical;
            if(d<arc) { float a=M_PI_F+d/r; return float2(rect.x+r,rect.y+r)+r*float2(cos(a),sin(a)); }
            d-=arc;
            if(d<horizontal) return float2(rect.x+r+d,rect.y);
            d-=horizontal;
            if(d<arc) { float a=M_PI_F*1.5f+d/r; return float2(right-r,rect.y+r)+r*float2(cos(a),sin(a)); }
            d-=arc;
            return float2(right,rect.y+r+d);
        }
        float2 offsetPoint(float4 rect,float direction,float position,float offset) {
            float d=direction*position;
            float2 point=routePoint(rect,d);
            float2 tangent=routePoint(rect,d+0.12f)-routePoint(rect,d-0.12f);
            tangent/=max(0.0001f,length(tangent));
            return point+float2(tangent.y,-tangent.x)*offset;
        }
        float2 crackleValues(device const float4 *data,uint base,uint index) {
            float4 value=data[base+1+index/2];
            return index%2==0 ? value.xy : value.zw;
        }
        void evaluateLightning(device const float4 *data,constant Uniforms &u,
                               device const uint *offsets,device EffectFrame *frames,uint id) {
            if(id>=uint(u.time.y)) return;
            device LightningFrame &frame=frames[id].lightning;
            frame.info=float4(0); frame.bounds=float4(0); frame.head=float4(0);
            uint o=offsets[id];
            if(data[o+1].w<1.5f) return;
            float age=u.time.x-data[o].z-data[o+14].x;
            float4 timing=data[o+14], settings=data[o+15], indexes=data[o+16], rect=data[o+13];
            if(age<=0.0f || age>=timing.y+0.15f) return;
            float p=clamp(age/timing.y,0.0f,1.0f);
            float progress=p+timing.w*sin(2.0f*M_PI_F*p);
            float settle=smoothUnit((age-timing.y)/0.15f);
            float strength=min(1.0f,age/0.05f)*(1.0f-settle);
            float routeLength=perimeterLength(rect), distance=routeLength*progress;
            float tail=min(min(96.0f,routeLength*(0.31f+settings.x)),distance)*(1.0f-settle);
            uint count=uint(settings.z), stride=1+(count+1)/2;
            uint crackle=uint(indexes.z), channel=uint(indexes.y), crackleCount=uint(indexes.w);
            float sampleTime=min(age,timing.y);
            uint current=0;
            for(uint i=1;i<crackleCount;++i) { if(data[crackle+i*stride].x<=sampleTime) current=i; else break; }
            uint previous=current>0?current-1:0;
            uint currentBase=crackle+current*stride, previousBase=crackle+previous*stride;
            float blend=smoothUnit((sampleTime-data[currentBase].x)/0.018f);
            float brightness=strength*(0.7f+0.3f*mix(data[previousBase].y,data[currentBase].y,blend));
            float a=(p-settings.w)/0.036f, b=(p-indexes.x)/0.036f;
            float recharge=max(exp(-a*a),exp(-b*b));
            uint pointCount=0, forkCount=0;
            frame.points[pointCount++]=float4(offsetPoint(rect,timing.z,distance-tail,0),0,0);
            for(uint i=0;i<count;++i) {
                float4 item=data[channel+i*2];
                float position=item.x;
                if(position<=distance-tail || position>=distance) continue;
                float2 state=mix(crackleValues(data,previousBase,i),crackleValues(data,currentBase,i),blend);
                float offset=(item.y*0.3f+state.x*0.7f)*(1.0f-settle);
                float2 knot=offsetPoint(rect,timing.z,position,offset);
                frame.points[pointCount++]=float4(knot,0,0);
                float energy=clamp((state.y-0.46f)/0.54f,0.0f,1.0f);
                if(energy<=0.0f || distance-position<2.0f) continue;
                float reach=min(min(item.z,routeLength*0.16f),distance-position);
                float depth=item.w, kink=data[channel+i*2+1].x;
                uint f=forkCount++*4;
                frame.forks[f]=float4(knot,energy,0);
                frame.forks[f+1]=float4(offsetPoint(rect,timing.z,position+reach*0.3f,-depth*0.42f+kink*0.5f),energy,0);
                frame.forks[f+2]=float4(offsetPoint(rect,timing.z,position+reach*0.63f,-depth*0.76f-kink*0.3f),energy,0);
                frame.forks[f+3]=float4(offsetPoint(rect,timing.z,position+reach,-depth),energy,0);
            }
            float2 head=routePoint(rect,timing.z*distance);
            frame.points[pointCount++]=float4(head,0,0);
            float2 low=head, high=head;
            for(uint i=0;i<pointCount;++i) { low=min(low,frame.points[i].xy); high=max(high,frame.points[i].xy); }
            for(uint i=0;i<forkCount*4;++i) { low=min(low,frame.forks[i].xy); high=max(high,frame.forks[i].xy); }
            // Miter limit ten for narrow fork strokes, two for the channel. The clip
            // below is the same 13-point strip as the Canvas oracle.
            low-=12.0f; high+=12.0f;
            low=max(low,float2(rect.x-7.0f,rect.y+rect.w*0.5f-6.5f));
            high=min(high,float2(rect.x+rect.z+7.0f,rect.y+rect.w*0.5f+6.5f));
            // Align mask texels with the destination pixel grid, including a cropped origin.
            low=u.viewport.zw+floor((low-u.viewport.zw)*u.scale.xy)/u.scale.xy;
            frame.info=float4(brightness,recharge,float(pointCount),float(forkCount));
            frame.bounds=float4(low,high); frame.head=float4(head,0,0);
        }

        float envelope(float p) {
            if (p <= 0.0f || p >= 1.0f) return 0.0f;
            float fade = clamp((p - 0.1f) / 0.9f, 0.0f, 1.0f);
            return min(1.0f, p / 0.04f) * (1.0f-fade) * (1.0f-fade) * (1.0f+2.0f*fade);
        }
        float coverage(float distance) {
            return clamp(0.5f - distance / max(fwidth(distance), 0.000001f), 0.0f, 1.0f);
        }
        float4 over(float4 destination, float4 source) {
            return source + destination * (1.0f - source.a);
        }
        float4 solid(float4 color, float opacity, float mask) {
            float alpha = color.a * opacity * mask;
            return float4(color.rgb * alpha, alpha);
        }
        float2 unrotate(float2 point, float angle) {
            float c = cos(angle), s = sin(angle);
            return float2(c*point.x+s*point.y, -s*point.x+c*point.y);
        }
        float lineDistance(float2 point, float2 a, float2 b) {
            float2 v = b-a;
            float t = clamp(dot(point-a,v) / max(dot(v,v), 0.000001f), 0.0f, 1.0f);
            return length(point-(a+v*t));
        }
        float roundedRectangle(float2 point, float4 rect, float radius) {
            float2 halfSize = rect.zw * 0.5f;
            radius = min(radius, min(halfSize.x, halfSize.y));
            float2 q = abs(point-(rect.xy+halfSize)) - (halfSize-radius);
            return length(max(q,0.0f)) + min(max(q.x,q.y),0.0f) - radius;
        }
        // Nearest point on the original quadratic star quadrant. The shape is
        // reflected into the first quadrant, never replaced by a diamond/polygon.
        float starDistance(float2 point, float size, float angle) {
            float2 p = abs(unrotate(point, angle)) / size;
            float2 a = float2(0,1), b = float2(0.24f,0.24f), c = float2(1,0);
            float t = clamp(p.x / max(p.x+p.y,0.000001f),0.0f,1.0f);
            float2 second = 2.0f*(a-2.0f*b+c);
            for (uint i=0; i<8; ++i) {
                float2 q = (1-t)*(1-t)*a + 2*(1-t)*t*b + t*t*c;
                float2 first = 2*((1-t)*(b-a)+t*(c-b));
                float denominator = dot(first,first)+dot(q-p,second);
                if (abs(denominator)>0.000001f)
                    t=clamp(t-dot(q-p,first)/denominator,0.0f,1.0f);
            }
            float2 q = (1-t)*(1-t)*a + 2*(1-t)*t*b + t*t*c;
            float2 first = 2*((1-t)*(b-a)+t*(c-b));
            float sign = dot(p-q,float2(-first.y,first.x)) >= 0 ? 1.0f : -1.0f;
            return length(p-q)*size*sign;
        }
        float arcDistance(float2 point, float radius, float start, float span) {
            float2 p=unrotate(point,start);
            float angle=atan2(p.y,p.x);
            if(angle<0) angle+=2.0f*M_PI_F;
            if(angle<=span) return abs(length(p)-radius);
            return min(length(p-float2(radius,0)),length(p-radius*float2(cos(span),sin(span))));
        }
        float4 glow(float2 point, float radius, float strength, float4 color) {
            float distance=length(point);
            float mask=coverage(distance-radius);
            float t=clamp(distance/radius,0.0f,1.0f);
            float4 stop;
            if(t<=0.18f) stop=float4(1,1,1,1);
            else if(t<=0.4f) stop=mix(float4(1,1,1,1),float4(color.rgb,color.a*0.95f),(t-0.18f)/0.22f);
            else stop=float4(color.rgb,color.a*0.95f*(1.0f-(t-0.4f)/0.6f));
            return solid(stop,strength,mask);
        }


        float boxDistance(float2 p,float2 halfSize) {
            float2 d=abs(p)-halfSize;
            return length(max(d,0.0f))+min(max(d.x,d.y),0.0f);
        }
        float segmentStroke(float2 p,float2 a,float2 b,float halfWidth) {
            float2 d=b-a; float len=length(d);
            if(len<0.00001f) return length(p-a)-halfWidth;
            float2 axis=d/len, local=p-(a+b)*0.5f;
            return boxDistance(float2(dot(local,axis),dot(local,float2(-axis.y,axis.x))),float2(len*0.5f,halfWidth));
        }
        float triangleDistance(float2 p,float2 a,float2 b,float2 c) {
            float2 e0=b-a,e1=c-b,e2=a-c,v0=p-a,v1=p-b,v2=p-c;
            float2 q0=v0-e0*clamp(dot(v0,e0)/max(dot(e0,e0),0.000001f),0.0f,1.0f);
            float2 q1=v1-e1*clamp(dot(v1,e1)/max(dot(e1,e1),0.000001f),0.0f,1.0f);
            float2 q2=v2-e2*clamp(dot(v2,e2)/max(dot(e2,e2),0.000001f),0.0f,1.0f);
            float orient=e0.x*e2.y-e0.y*e2.x;
            float s=orient>=0.0f?1.0f:-1.0f;
            float2 d=min(min(float2(dot(q0,q0),s*(v0.x*e0.y-v0.y*e0.x)),
                             float2(dot(q1,q1),s*(v1.x*e1.y-v1.y*e1.x))),
                             float2(dot(q2,q2),s*(v2.x*e2.y-v2.y*e2.x)));
            return -sqrt(d.x)*(d.y>=0.0f?1.0f:-1.0f);
        }
        float joinDistance(float2 p,float2 a,float2 b,float2 c,float halfWidth,float miterLimit,bool roundJoin) {
            if(roundJoin) return length(p-b)-halfWidth;
            float2 d0=b-a,d1=c-b;
            if(length(d0)<0.00001f||length(d1)<0.00001f) return INFINITY;
            d0=normalize(d0); d1=normalize(d1);
            float turn=d0.x*d1.y-d0.y*d1.x;
            if(abs(turn)<0.00001f) return INFINITY;
            float side=turn>0.0f?-1.0f:1.0f;
            float2 n0=float2(-d0.y,d0.x)*side, n1=float2(-d1.y,d1.x)*side;
            float2 outer0=b+n0*halfWidth, outer1=b+n1*halfWidth;
            float2 sum=n0+n1;
            float denominator=dot(sum,n1);
            float2 tip=b+sum*(halfWidth/max(denominator,0.000001f));
            float distance=triangleDistance(p,b,outer0,outer1);
            if(length(tip-b)<=halfWidth*miterLimit)
                distance=min(distance,triangleDistance(p,outer0,tip,outer1));
            return distance;
        }
        float polylineDistance(float2 p,device const float4 *points,uint count,float width,float limit,bool roundJoin) {
            float distance=INFINITY, halfWidth=width*0.5f;
            for(uint i=1;i<count;++i) {
                distance=min(distance,segmentStroke(p,points[i-1].xy,points[i].xy,halfWidth));
                if(i+1<count) distance=min(distance,joinDistance(p,points[i-1].xy,points[i].xy,points[i+1].xy,halfWidth,limit,roundJoin));
            }
            return distance;
        }
        float2 rotateAxis(float2 point,float2 axis) {
            return float2(dot(point,axis),dot(point,float2(-axis.y,axis.x)));
        }
        float starAxisDistance(float2 point,float size,float2 axis) {
            float2 p=abs(rotateAxis(point,axis))/size;
            float2 a=float2(0,1),b=float2(0.24f,0.24f),c=float2(1,0);
            float t=clamp(p.x/max(p.x+p.y,0.000001f),0.0f,1.0f);
            float2 second=2.0f*(a-2.0f*b+c);
            for(uint i=0;i<8;++i) {
                float2 q=(1-t)*(1-t)*a+2*(1-t)*t*b+t*t*c;
                float2 first=2*((1-t)*(b-a)+t*(c-b));
                float denominator=dot(first,first)+dot(q-p,second);
                if(abs(denominator)>0.000001f) t=clamp(t-dot(q-p,first)/denominator,0.0f,1.0f);
            }
            float2 q=(1-t)*(1-t)*a+2*(1-t)*t*b+t*t*c;
            float2 first=2*((1-t)*(b-a)+t*(c-b));
            float sign=dot(p-q,float2(-first.y,first.x))>=0?1.0f:-1.0f;
            return length(p-q)*size*sign;
        }
        Primitive primitive(float type,float4 bounds,float4 shape,float4 extra,
                            float opacity,float detail,float4 color) {
            Primitive p;
            p.bounds=bounds; p.shape=shape; p.extra=extra;
            p.state=float4(type,opacity,0,detail); p.color=color;
            return p;
        }
        float4 boundsAt(float2 center,float2 extent) {
            return float4(center-extent-1.0f,center+extent+1.0f);
        }
        void appendPrimitive(device EffectFrame &frame,thread uint &count,Primitive p,float4 clip) {
            p.bounds.xy=max(p.bounds.xy,clip.xy);
            p.bounds.zw=min(p.bounds.zw,clip.zw);
            if(count>=PrimitiveCount || p.state.y<=0 || any(p.bounds.xy>=p.bounds.zw)) return;
            frame.primitives[count++]=p;
        }
        void prepareBurst(device EffectFrame &frame,thread uint &count,float p,float scale,
                          device const float4 *data,uint offset) {
            if(p<=0 || p>=1) return;
            float4 source=data[offset],style=data[offset+1],color=data[offset+2];
            float2 center=source.xy,axis=float2(cos(style.z),sin(style.z));
            float4 clip=float4(center-46.0f,center+46.0f);
            float strength=envelope(p),expansion=1.0f-pow(1.0f-p,3.0f),size=style.y*scale;
            uint family=uint(style.x);
            float halo=family==0?20.0f:family==2?18.0f:14.0f;
            float radius=(9.0f+halo*expansion)*size;
            float2 extent=radius*sqrt(float2(axis.x*axis.x+0.76f*0.76f*axis.y*axis.y,
                                           axis.y*axis.y+0.76f*0.76f*axis.x*axis.x));
            appendPrimitive(frame,count,primitive(2,boundsAt(center,extent),float4(center,radius,0),
                            float4(axis,0.76f,0),strength*0.92f,0,color),clip);
            if(family==2) {
                for(uint i=0;i<3;++i) {
                    float r=(7.0f+12.0f*expansion+float(i)*1.6f)*size;
                    float angle=style.z+float(i)*2.2f;
                    float span=0.4f+data[offset+4+i*2].z*0.48f;
                    float2 start=float2(cos(angle),sin(angle));
                    float2 end=float2(cos(span),sin(span));
                    // Tight sector bounds, including extremal angles, evaluated once.
                    float2 low=center+start*r,high=low;
                    for(uint j=1;j<=16;++j) {
                        float a=angle+span*float(j)/16.0f;
                        float2 q=center+r*float2(cos(a),sin(a));
                        low=min(low,q); high=max(high,q);
                    }
                    float4 bounds=float4(low-1.75f,high+1.75f);
                    appendPrimitive(frame,count,primitive(5,bounds,float4(center,r,0.75f),
                                    float4(start,end),strength,0,color),clip);
                }
            } else {
                uint particleCount=family==0?4:5;
                for(uint i=0;i<particleCount;++i) {
                    float4 descriptor=data[offset+3+i*2],timing=data[offset+4+i*2];
                    float q=clamp((p-timing.x)/timing.y,0.0f,1.0f);
                    float brightness=envelope(q)*0.92f;
                    if(brightness<=0) continue;
                    float travel=1.0f-(1.0f-q)*(1.0f-q);
                    float2 direction=float2(cos(descriptor.x),sin(descriptor.x));
                    float2 location=center+direction*((4.0f+descriptor.y*travel)*size);
                    if(family==0) {
                        float r=descriptor.w*3.0f;
                        appendPrimitive(frame,count,primitive(1,boundsAt(location,float2(r)),float4(location,r,0),
                                        float4(0),brightness*0.8f,0,color),clip);
                        r=descriptor.w*(1.0f-0.4f*q);
                        appendPrimitive(frame,count,primitive(3,boundsAt(location,float2(r)),float4(location,r,0),
                                        float4(0),brightness,0,float4(1)),clip);
                    } else {
                        float2 end=location+direction*(descriptor.z*(1.0f-0.5f*q));
                        float halfWidth=descriptor.w*0.375f;
                        float4 bounds=float4(min(location,end)-halfWidth-1.0f,max(location,end)+halfWidth+1.0f);
                        appendPrimitive(frame,count,primitive(4,bounds,float4(location,end),float4(halfWidth,0,0,0),
                                        brightness,0,float4(1)),clip);
                    }
                }
            }
            float r=8.0f*size;
            appendPrimitive(frame,count,primitive(1,boundsAt(center,float2(r)),float4(center,r,0),float4(0),
                            strength,0,color),clip);
            r=(family==0?2.0f+1.3f*strength:4.5f+3.5f*strength)*size;
            appendPrimitive(frame,count,primitive(family==0?3:6,boundsAt(center,float2(r)),float4(center,r,0),
                            float4(axis,0,0),strength,0,float4(1)),clip);
        }
        kernel void primitiveEffectsFrame(device const float4 *data [[buffer(0)]],
                                          constant Uniforms &u [[buffer(1)]],
                                          device const uint *offsets [[buffer(2)]],
                                          device EffectFrame *frames [[buffer(3)]],
                                          uint id [[thread_position_in_grid]]) {
            if(id>=uint(u.time.y)) return;
            evaluateLightning(data,u,offsets,frames,id);
            device EffectFrame &output=frames[id];
            uint offset=offsets[id],count=0;
            float4 source=data[offset],style=data[offset+1],color=data[offset+2];
            float age=u.time.x-source.z;
            bool completion=style.w>1.5f,twinkle=style.w>0.5f&&!completion;
            if(completion) {
                prepareBurst(output,count,age/0.24f,0.5f,data,offset);
                device LightningFrame &lightning=output.lightning;
                if(lightning.info.z>=2) {
                    float4 rect=data[offset+13];
                    float4 clip=float4(rect.x-7.0f,rect.y+rect.w*0.5f-6.5f,
                                       rect.x+rect.z+7.0f,rect.y+rect.w*0.5f+6.5f);
                    for(uint fork=0;fork<uint(lightning.info.w);++fork) {
                        uint base=fork*4;
                        float2 low=lightning.forks[base].xy,high=low;
                        for(uint j=1;j<4;++j) {
                            low=min(low,lightning.forks[base+j].xy);
                            high=max(high,lightning.forks[base+j].xy);
                        }
                        appendPrimitive(output,count,primitive(9,float4(low-12.0f,high+12.0f),float4(0),float4(0),
                                        lightning.info.x,float(fork),color),clip);
                    }
                    appendPrimitive(output,count,primitive(10,lightning.bounds,float4(0),float4(0),
                                    lightning.info.x,0,color),clip);
                }
                float start=data[offset+14].x+data[offset+14].y;
                if(data[offset+15].y>0.5f) prepareBurst(output,count,(age-start)/source.w,1.12f,data,offset);
            } else if(twinkle) {
                float p=age/source.w;
                if(p>0 && p<1) {
                    float strength=sin(M_PI_F*p); strength*=strength;
                    float size=style.y*(0.7f+0.3f*strength);
                    float4 bar=data[offset+3];
                    float2 center=float2(source.x,bar.y+bar.w*0.5f);
                    float4 clip=boundsAt(center,float2(style.y*2.1f,bar.w*0.5f));
                    float2 extent=float2(size*2.1f,bar.w*0.5f);
                    appendPrimitive(output,count,primitive(7,boundsAt(center,extent),float4(center,extent),float4(0),
                                    strength*0.32f,1,color),clip);
                    float2 axis=float2(cos(style.z),sin(style.z));
                    float r=style.x>0.5f?size:size*0.56f;
                    appendPrimitive(output,count,primitive(style.x>0.5f?6:3,boundsAt(source.xy,float2(r)),
                                    float4(source.xy,r,0),float4(axis,0,0),strength,1,float4(1)),clip);
                }
            } else prepareBurst(output,count,age/source.w,1.0f,data,offset);
            output.draws=uint4(6,count,0,id*PrimitiveCount);
            uint segments=uint(output.lightning.info.z);
            output.maskDraws=uint4(6,segments>=2?segments-1:0,0,id*241);
        }
        vertex VertexOut fullEffectsVertex(uint vertexID [[vertex_id]],uint instanceID [[instance_id]],
                                          constant Uniforms &u [[buffer(1)]],
                                          device const EffectFrame *frames [[buffer(3)]]) {
            const float2 corners[6]={float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1)};
            uint element=instanceID/PrimitiveCount,index=instanceID%PrimitiveCount;
            float4 bounds=frames[element].primitives[index].bounds;
            float2 point=mix(bounds.xy,bounds.zw,corners[vertexID]);
            float2 normalized=(point-u.viewport.zw)/u.viewport.xy;
            VertexOut out;
            out.position=float4(normalized.x*2.0f-1.0f,1.0f-normalized.y*2.0f,0,1);
            out.point=point; out.element=element; out.primitive=index;
            return out;
        }
        vertex MaskVertex primitiveChannelVertex(uint vertexID [[vertex_id]],uint instanceID [[instance_id]],
                                                constant Uniforms &u [[buffer(1)]],
                                                device const EffectFrame *frames [[buffer(3)]]) {
            const float2 corners[6]={float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1)};
            uint element=instanceID/241,segment=instanceID%241;
            device const LightningFrame &frame=frames[element].lightning;
            float2 a=frame.points[segment].xy,b=frame.points[segment+1].xy;
            // Covers the widest round glow and two-limit channel miters, plus AA.
            float2 low=min(a,b)-5.0f,high=max(a,b)+5.0f;
            if(segment+2<uint(frame.info.z)) {
                low=min(low,frame.points[segment+1].xy-5.0f);
                high=max(high,frame.points[segment+1].xy+5.0f);
            }
            float2 point=mix(low,high,corners[vertexID]);
            float2 normalized=(point-frame.bounds.xy)/u.time.zw;
            MaskVertex out;
            out.position=float4(normalized.x*2.0f-1.0f,1.0f-normalized.y*2.0f,0,1);
            out.point=point; out.element=element; out.segment=segment; out.layer=element;
            return out;
        }
        float channelSegmentDistance(float2 point,device const LightningFrame &frame,uint segment,
                                     float width,bool roundJoin) {
            float2 a=frame.points[segment].xy,b=frame.points[segment+1].xy;
            float halfWidth=width*0.5f;
            float distance=segmentStroke(point,a,b,halfWidth);
            if(segment+2<uint(frame.info.z))
                distance=min(distance,joinDistance(point,a,b,frame.points[segment+2].xy,halfWidth,2.0f,roundJoin));
            return distance;
        }
        fragment ChannelMasks primitiveChannelFragment(MaskVertex in [[stage_in]],
                                                        constant Uniforms &u [[buffer(1)]],
                                                        device const EffectFrame *frames [[buffer(3)]]) {
            device const LightningFrame &frame=frames[in.element].lightning;
            // Raster position gives exact texel centers; interpolation changes with viewport width.
            float2 point=in.position.xy/u.scale.xy+frame.bounds.xy;
            ChannelMasks result;
            result.glow=float4(coverage(channelSegmentDistance(point,frame,in.segment,5.5f+frame.info.y*1.5f,true)));
            result.color=float4(coverage(channelSegmentDistance(point,frame,in.segment,2.8f,false)));
            result.white=float4(coverage(channelSegmentDistance(point,frame,in.segment,1.15f+frame.info.y*0.4f,false)));
            return result;
        }
        float clipping(float2 point,float4 rect) {
            float2 center=rect.xy+rect.zw*0.5f;
            return coverage(boxDistance(point-center,float2(rect.z*0.5f+7.0f,6.5f)));
        }
        // fwidth uses framebuffer-local 2x2 groups. An odd cropped origin changes
        // those groups even at the same global point. Evaluate the same neighboring
        // global pixel pair explicitly so drawing bounds cannot change edge opacity.
        float2 globalNeighbor(float2 point,float2 scale,bool horizontal) {
            float2 pixel=floor(point*scale);
            float2 odd=fmod(fmod(pixel,2.0f)+2.0f,2.0f);
            float2 step=(float2(1)-2.0f*odd)/scale;
            return point+(horizontal?float2(step.x,0):float2(0,step.y));
        }
        float pairCoverage(float distance,float xDistance,float yDistance) {
            float width=abs(xDistance-distance)+abs(yDistance-distance);
            return clamp(0.5f-distance/max(width,0.000001f),0.0f,1.0f);
        }
        float primitiveDistance(device const Primitive &p,float2 point) {
            uint type=uint(p.state.x);
            float2 local=point-p.shape.xy;
            if(type==1 || type==3) return length(local)-p.shape.z;
            if(type==2) {
                float2 rotated=rotateAxis(local,p.extra.xy); rotated.y/=p.extra.z;
                return length(rotated)-p.shape.z;
            }
            if(type==4) return lineDistance(point,p.shape.xy,p.shape.zw)-p.extra.x;
            if(type==5) {
                float2 rotated=rotateAxis(local,p.extra.xy);
                bool within=rotated.y>=0 && rotated.x*p.extra.w-rotated.y*p.extra.z>=0;
                float distance=within?abs(length(rotated)-p.shape.z):
                    min(length(rotated-float2(p.shape.z,0)),length(rotated-p.shape.z*p.extra.zw));
                return distance-p.shape.w;
            }
            if(type==6) return starAxisDistance(local,p.shape.z,p.extra.xy);
            if(type==7) return (length(local/p.shape.zw)-1.0f)*min(p.shape.z,p.shape.w);
            return INFINITY;
        }
        float primitiveCoverage(device const Primitive &p,float2 point,float2 xPoint,float2 yPoint) {
            return pairCoverage(primitiveDistance(p,point),primitiveDistance(p,xPoint),primitiveDistance(p,yPoint));
        }
        float stableClip(float2 point,float2 xPoint,float2 yPoint,float4 rect) {
            float2 center=rect.xy+rect.zw*0.5f;
            float2 halfSize=float2(rect.z*0.5f+7.0f,6.5f);
            return pairCoverage(boxDistance(point-center,halfSize),boxDistance(xPoint-center,halfSize),
                                boxDistance(yPoint-center,halfSize));
        }
        fragment float4 fullEffectsFragment(VertexOut in [[stage_in]],
                                            device const float4 *data [[buffer(0)]],
                                            constant Uniforms &u [[buffer(1)]],
                                            device const uint *offsets [[buffer(2)]],
                                            device const EffectFrame *frames [[buffer(3)]],
                                            texture2d_array<float> glowMask [[texture(0)]],
                                            texture2d_array<float> colorMask [[texture(1)]],
                                            texture2d_array<float> whiteMask [[texture(2)]]) {
            device const Primitive &p=frames[in.element].primitives[in.primitive];
            uint type=uint(p.state.x),offset=offsets[in.element];
            float2 point=in.position.xy/u.scale.xy+u.viewport.zw;
            float2 xPoint=globalNeighbor(point,u.scale.xy,true),yPoint=globalNeighbor(point,u.scale.xy,false);
            float strength=p.state.y;
            float4 result=float4(0);
            if(type==1 || type==2) {
                float distance=primitiveDistance(p,point)+p.shape.z;
                float t=clamp(distance/p.shape.z,0.0f,1.0f);
                float4 stop;
                if(t<=0.18f) stop=float4(1);
                else if(t<=0.4f) stop=mix(float4(1),float4(p.color.rgb,p.color.a*0.95f),(t-0.18f)/0.22f);
                else stop=float4(p.color.rgb,p.color.a*0.95f*(1.0f-(t-0.4f)/0.6f));
                result=solid(stop,strength,primitiveCoverage(p,point,xPoint,yPoint));
            } else if(type>=3 && type<=7) {
                result=solid(p.color,strength,primitiveCoverage(p,point,xPoint,yPoint));
            } else if(type==9) {
                device const LightningFrame &frame=frames[in.element].lightning;
                device const float4 *points=frame.forks+uint(p.state.w)*4;
                float energy=points[0].z;
                float outer=pairCoverage(polylineDistance(point,points,4,2.2f,10.0f,false),
                                         polylineDistance(xPoint,points,4,2.2f,10.0f,false),
                                         polylineDistance(yPoint,points,4,2.2f,10.0f,false));
                result=solid(p.color,strength*energy*0.65f,outer);
                float inner=pairCoverage(polylineDistance(point,points,4,0.65f,10.0f,false),
                                         polylineDistance(xPoint,points,4,0.65f,10.0f,false),
                                         polylineDistance(yPoint,points,4,0.65f,10.0f,false));
                result=over(result,solid(float4(1),strength*energy*0.86f,inner));
                return result*stableClip(point,xPoint,yPoint,data[offset+13]);
            } else if(type==10) {
                device const LightningFrame &frame=frames[in.element].lightning;
                constexpr sampler nearest(coord::normalized,filter::nearest,address::clamp_to_zero);
                float2 coordinate=(point-frame.bounds.xy)/u.time.zw;
                float glow=glowMask.sample(nearest,coordinate,in.element).r;
                float color=colorMask.sample(nearest,coordinate,in.element).r;
                float white=whiteMask.sample(nearest,coordinate,in.element).r;
                result=solid(p.color,strength*(0.22f+frame.info.y*0.16f),glow);
                result=over(result,solid(p.color,strength*0.9f,color));
                result=over(result,solid(float4(1),strength,white));
                float head=pairCoverage(length(point-frame.head.xy)-0.7f,length(xPoint-frame.head.xy)-0.7f,
                                        length(yPoint-frame.head.xy)-0.7f);
                result=over(result,solid(float4(1),strength,head));
                return result*stableClip(point,xPoint,yPoint,data[offset+13]);
            }
            if(p.state.w>0.5f) {
                float4 bar=data[offset+3]; float radius=data[offset+4].x;
                float clip=pairCoverage(roundedRectangle(point,bar,radius),roundedRectangle(xPoint,bar,radius),
                                        roundedRectangle(yPoint,bar,radius));
                result*=clip;
            }
            return result;
        }
        """#
}
