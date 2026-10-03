import Foundation
import Metal
import simd

/// Retained full-chart effects. Immutable profiles are uploaded only when receipts,
/// geometry, or glints change. Both lightning evaluation and particle motion run
/// on the GPU; encoding a frame supplies only its time and viewport.
@MainActor
final class MetalFullChartEffectsRenderer {
    struct Effect: Equatable {
        let id: RequestRailLifecycleEffects.Key
        let startTime: TimeInterval
        let profile: RequestRailEffectProfile
        let rect: CGRect
        let cornerRadius: CGFloat
        let color: SIMD4<Float>
    }
    struct Twinkle: Equatable {
        let twinkle: RequestRailTwinkle
        let placement: RequestRailTwinkle.Placement
        let startTime: TimeInterval
        let color: SIMD4<Float>
    }
    enum Element: Equatable {
        case effect(Effect)
        case twinkle(Twinkle)
    }
    struct EncodedContent {
        let arrivalBursts: Int
        let completionEffects: Int
        let twinkles: Int
        var frameStorageChanged = false
    }
    struct Statistics {
        let descriptorUploads: UInt64
        let encodedFrames: UInt64
        let inFlightFrames: Int
        let retainedDescriptorBuffers: Int
        let retainedDescriptorBytes: Int
        let retainedFrameBytes: Int
        let elementCount: Int
    }
    enum RendererError: Error {
        case deviceUnavailable, shaderUnavailable, allocationFailed, invalidInput
        case capacityExceeded, unsupportedTarget, encoderUnavailable, tooManyFramesInFlight
    }
    static let maximumEffects = 64
    static let maximumTwinkles = 2
    static let maximumFramesInFlight = 3
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    // Three header rows, 242 channel points, and 240 four-point forks.
    private static let frameStride = (3 + 242 + 240 * 4) * MemoryLayout<SIMD4<Float>>.stride
    let device: any MTLDevice
    private let pipeline: any MTLRenderPipelineState
    private let computePipeline: any MTLComputePipelineState
    private let leases = FrameLeases()
    private var elements: [Element] = []
    private var hasCompletionDescriptors = false
    private var descriptors: (any MTLBuffer)?
    private var offsets: (any MTLBuffer)?
    private var descriptorUploads: UInt64 = 0
    private var encodedFrames: UInt64 = 0

    init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RendererError.deviceUnavailable }
        self.device = device
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: Self.shader, options: options)
        guard let vertex = library.makeFunction(name: "fullEffectsVertex"),
            let fragment = library.makeFunction(name: "fullEffectsFragment"),
            let compute = library.makeFunction(name: "fullEffectsLightning")
        else {
            throw RendererError.shaderUnavailable
        }
        computePipeline = try device.makeComputePipelineState(function: compute)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "FluxLLM retained full chart effects"
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
    }

    var statistics: Statistics {
        let snapshot = leases.snapshot(descriptors: descriptors, offsets: offsets)
        return Statistics(
            descriptorUploads: descriptorUploads, encodedFrames: encodedFrames,
            inFlightFrames: snapshot.frames, retainedDescriptorBuffers: snapshot.buffers,
            retainedDescriptorBytes: snapshot.bytes, retainedFrameBytes: snapshot.frameBytes,
            elementCount: elements.count)
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

    /// No drawable acquisition, readback, waits, path building, or presentation.
    /// Successful encodes must be committed by the caller, including on later error.
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
        guard
            let lease = try leases.begin(
                device: device, descriptors: descriptors, offsets: offsets,
                frameBytes: max(1, elements.count) * Self.frameStride,
                limit: Self.maximumFramesInFlight)
        else { throw RendererError.tooManyFramesInFlight }
        content.frameStorageChanged = lease.storageChanged
        // Register immediately: callers commit even if a later encoder fails.
        let leases = leases
        commandBuffer.addCompletedHandler { _ in leases.finish(lease.id) }
        let uniform = [
            SIMD4<Float>(
                Float(pointSize.width), Float(pointSize.height), Float(origin.x), Float(origin.y)),
            SIMD4<Float>(Float(elapsedTime), Float(elements.count), 0, 0),
        ]
        if let descriptors, let offsets, hasCompletionDescriptors {
            guard let compute = commandBuffer.makeComputeCommandEncoder() else {
                throw RendererError.encoderUnavailable
            }
            compute.label = "FluxLLM GPU lightning evaluation"
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
        encoder.label = "FluxLLM full chart effects pass"
        if let descriptors, let offsets, !elements.isEmpty {
            encoder.setRenderPipelineState(pipeline)
            for index in [0, 1, 2, 3] {
                if index == 1 { continue }
                let buffer = index == 0 ? descriptors : index == 2 ? offsets : lease.frame
                encoder.setVertexBuffer(buffer, offset: 0, index: index)
                encoder.setFragmentBuffer(buffer, offset: 0, index: index)
            }
            uniform.withUnsafeBytes {
                encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1)
                encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1)
            }
            // Per-element order: initial burst, lightning, delayed burst. Glints
            // occupy the first instance only, in the host's segment order.
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: 6,
                instanceCount: elements.count * 3)
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
            let storageChanged: Bool
        }
        private struct Lease {
            let descriptors: (any MTLBuffer)?
            let offsets: (any MTLBuffer)?
            let slot: Int
        }
        private let lock = NSLock()
        private var nextID: UInt64 = 0
        private var active: [UInt64: Lease] = [:]
        private var frames: [Int: any MTLBuffer] = [:]
        private var discardOnFinish = false

        func begin(
            device: any MTLDevice, descriptors: (any MTLBuffer)?, offsets: (any MTLBuffer)?,
            frameBytes: Int, limit: Int
        ) throws -> Ticket? {
            lock.lock()
            defer { lock.unlock() }
            let busy = Set(active.values.map(\.slot))
            guard let slot = (0..<limit).first(where: { !busy.contains($0) }) else { return nil }
            let storageChanged = frames[slot] == nil || frames[slot]!.length < frameBytes
            if storageChanged {
                guard
                    let buffer = device.makeBuffer(length: frameBytes, options: .storageModePrivate)
                else {
                    throw RendererError.allocationFailed
                }
                buffer.label = "FluxLLM bounded GPU lightning frame \(slot)"
                frames[slot] = buffer
            }
            discardOnFinish = false
            nextID &+= 1
            active[nextID] = Lease(descriptors: descriptors, offsets: offsets, slot: slot)
            return Ticket(id: nextID, frame: frames[slot]!, storageChanged: storageChanged)
        }
        func finish(_ id: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            if let lease = active.removeValue(forKey: id), discardOnFinish {
                frames.removeValue(forKey: lease.slot)
            }
        }
        func discardUnusedFrames() {
            lock.lock()
            defer { lock.unlock() }
            discardOnFinish = true
            let busy = Set(active.values.map(\.slot))
            frames = frames.filter { busy.contains($0.key) }
        }
        func snapshot(descriptors: (any MTLBuffer)?, offsets: (any MTLBuffer)?)
            -> (frames: Int, buffers: Int, bytes: Int, frameBytes: Int)
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
            return (
                active.count, unique.count, unique.values.reduce(0) { $0 + $1.length },
                frames.values.reduce(0) { $0 + $1.length }
            )
        }
    }

    private static let shader = #"""
        #include <metal_stdlib>
        using namespace metal;
        struct Uniforms { float4 viewport; float4 time; };
        struct LightningFrame {
            float4 info;
            float4 bounds;
            float4 head;
            float4 points[242];
            float4 forks[960];
        };
        struct VertexOut {
            float4 position [[position]];
            float2 point;
            uint element [[flat]];
            uint part [[flat]];
        };

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
        kernel void fullEffectsLightning(device const float4 *data [[buffer(0)]],
                                         constant Uniforms &u [[buffer(1)]],
                                         device const uint *offsets [[buffer(2)]],
                                         device LightningFrame *frames [[buffer(3)]],
                                         uint id [[thread_position_in_grid]]) {
            if(id>=uint(u.time.y)) return;
            device LightningFrame &frame=frames[id];
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
            frame.info=float4(brightness,recharge,float(pointCount),float(forkCount));
            frame.bounds=float4(low,high); frame.head=float4(head,0,0);
        }

        vertex VertexOut fullEffectsVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                          device const float4 *data [[buffer(0)]],
                                          constant Uniforms &u [[buffer(1)]],
                                          device const uint *offsets [[buffer(2)]],
                                          device const LightningFrame *frames [[buffer(3)]]) {
            const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
            uint element=instanceID/3, part=instanceID%3, offset=offsets[element];
            float4 frame=data[offset], style=data[offset+1];
            float2 center=frame.xy, extent=float2(46.0f);
            bool completion=style.w>1.5f, twinkle=style.w>0.5f&&!completion;
            bool visible=true;
            float age=u.time.x-frame.z;
            if(completion) {
                if(part==0) visible=age>0.0f&&age<0.24f;
                else if(part==1) {
                    float4 timing=data[offset+14];
                    visible=age>timing.x&&age<timing.x+timing.y+0.15f;
                    if(visible) {
                        float4 bounds=frames[element].bounds;
                        center=(bounds.xy+bounds.zw)*0.5f; extent=max(float2(0), (bounds.zw-bounds.xy)*0.5f);
                        visible=frames[element].info.z>=2.0f;
                    }
                } else {
                    float start=data[offset+14].x+data[offset+14].y;
                    visible=data[offset+15].y>0.5f&&age>start&&age<start+frame.w;
                }
            } else {
                visible=part==0&&age>0.0f&&age<frame.w;
                if(twinkle) {
                    float4 bar=data[offset+3];
                    center.y=bar.y+bar.w*0.5f;
                    extent=float2(style.y*2.1f+1.0f,bar.w*0.5f+1.0f);
                }
            }
            float2 point=center+corners[vertexID]*extent;
            float2 normalized=(point-u.viewport.zw)/u.viewport.xy;
            VertexOut out;
            out.position=visible ? float4(normalized.x*2.0f-1.0f,1.0f-normalized.y*2.0f,0,1) : float4(2,2,0,1);
            out.point=point; out.element=element; out.part=part;
            return out;
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
        float4 lightning(float2 point,device const LightningFrame &frame,float4 color,float4 rect) {
            uint count=uint(frame.info.z), forks=uint(frame.info.w);
            if(count<2) return float4(0);
            float brightness=frame.info.x,recharge=frame.info.y;
            float4 result=float4(0);
            for(uint i=0;i<forks;++i) {
                device const float4 *points=frame.forks+i*4;
                float energy=points[0].z;
                float outer=coverage(polylineDistance(point,points,4,2.2f,10.0f,false));
                result=over(result,solid(color,brightness*energy*0.65f,outer));
                float inner=coverage(polylineDistance(point,points,4,0.65f,10.0f,false));
                result=over(result,solid(float4(1),brightness*energy*0.86f,inner));
            }
            float glowMask=coverage(polylineDistance(point,frame.points,count,5.5f+recharge*1.5f,2.0f,true));
            result=over(result,solid(color,brightness*(0.22f+recharge*0.16f),glowMask));
            float colorMask=coverage(polylineDistance(point,frame.points,count,2.8f,2.0f,false));
            result=over(result,solid(color,brightness*0.9f,colorMask));
            float whiteMask=coverage(polylineDistance(point,frame.points,count,1.15f+recharge*0.4f,2.0f,false));
            result=over(result,solid(float4(1),brightness,whiteMask));
            result=over(result,solid(float4(1),brightness,coverage(length(point-frame.head.xy)-0.7f)));
            float2 clipCenter=float2(rect.x+rect.z*0.5f,rect.y+rect.w*0.5f);
            float mask=coverage(boxDistance(point-clipCenter,float2(rect.z*0.5f+7.0f,6.5f)));
            return result*mask;
        }
        float4 burst(float2 point,float p,float scale,float4 style,float4 color,
                     device const float4 *data,uint offset) {
            if(p<=0.0f||p>=1.0f) return float4(0);
            float4 result=float4(0);
            float strength=envelope(p);
            float expansion=1.0f-pow(1.0f-p,3.0f);
            float size=style.y*scale;
            uint family=uint(style.x);
            float halo=family==0 ? 20.0f : family==2 ? 18.0f : 14.0f;
            float2 ellipse=unrotate(point,style.z); ellipse.y/=0.76f;
            result=over(result,glow(ellipse,(9.0f+halo*expansion)*size,strength*0.92f,color));
            if(family==2) {
                for(uint i=0;i<3;++i) {
                    float radius=(7.0f+12.0f*expansion+float(i)*1.6f)*size;
                    float angle=style.z+float(i)*2.2f;
                    float span=0.4f+data[offset+4+i*2].z*0.48f;
                    float mask=coverage(arcDistance(point,radius,angle,span)-0.75f);
                    result=over(result,solid(color,strength,mask));
                }
            } else {
                uint count=family==0 ? 4 : 5;
                for(uint i=0;i<count;++i) {
                    float4 particle=data[offset+3+i*2], timing=data[offset+4+i*2];
                    float q=clamp((p-timing.x)/timing.y,0.0f,1.0f);
                    float brightness=envelope(q)*0.92f;
                    float travel=1.0f-(1.0f-q)*(1.0f-q);
                    float2 direction=float2(cos(particle.x),sin(particle.x));
                    float2 center=direction*((4.0f+particle.y*travel)*size);
                    if(family==0) {
                        result=over(result,glow(point-center,particle.w*3.0f,brightness*0.8f,color));
                        float mask=coverage(length(point-center)-particle.w*(1.0f-0.4f*q));
                        result=over(result,solid(float4(1),brightness,mask));
                    } else {
                        float length=particle.z*(1.0f-0.5f*q);
                        float mask=coverage(lineDistance(point,center,center+direction*length)-particle.w*0.375f);
                        result=over(result,solid(float4(1),brightness,mask));
                    }
                }
            }
            result=over(result,glow(point,8.0f*size,strength,color));
            float core=family==0 ? coverage(length(point)-(2.0f+1.3f*strength)*size)
                                : coverage(starDistance(point,(4.5f+3.5f*strength)*size,style.z));
            return over(result,solid(float4(1),strength,core));
        }
        fragment float4 fullEffectsFragment(VertexOut in [[stage_in]],
                                            device const float4 *data [[buffer(0)]],
                                            constant Uniforms &u [[buffer(1)]],
                                            device const uint *offsets [[buffer(2)]],
                                            device const LightningFrame *frames [[buffer(3)]]) {
            uint offset=offsets[in.element];
            float4 frame=data[offset],style=data[offset+1],color=data[offset+2];
            float age=u.time.x-frame.z;
            if(style.w>1.5f) {
                if(in.part==1) return lightning(in.point,frames[in.element],color,data[offset+13]);
                if(in.part==0) return burst(in.point-frame.xy,age/0.24f,0.5f,style,color,data,offset);
                float start=data[offset+14].x+data[offset+14].y;
                return burst(in.point-frame.xy,(age-start)/frame.w,1.12f,style,color,data,offset);
            }
            float p=age/frame.w;
            if(p<=0.0f||p>=1.0f) return float4(0);
            float2 point=in.point-frame.xy;
            if(style.w>0.5f) {
                float strength=sin(M_PI_F*p); strength*=strength;
                float size=style.y*(0.7f+0.3f*strength);
                float4 bar=data[offset+3];
                float clip=coverage(roundedRectangle(in.point,bar,data[offset+4].x));
                float2 ellipsePoint=float2(point.x/(size*2.1f),(in.point.y-(bar.y+bar.w*0.5f))/(bar.w*0.5f));
                float ellipse=coverage((length(ellipsePoint)-1.0f)*min(size*2.1f,bar.w*0.5f));
                float4 result=solid(color,strength*0.32f,ellipse*clip);
                float mark=style.x>0.5f?coverage(starDistance(point,size,style.z)):coverage(length(point)-size*0.56f);
                return over(result,solid(float4(1),strength,mark*clip));
            }
            return burst(point,p,1.0f,style,color,data,offset);
        }
        """#
}
