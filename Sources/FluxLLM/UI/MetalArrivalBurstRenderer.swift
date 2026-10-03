import Foundation
import Metal
import simd

/// Diagnostic arrival renderer shared by the native host and offscreen fidelity
/// tests. The shader evaluates animation from immutable descriptors and one time
/// uniform; Swift never reconstructs particles for individual frames.
///
/// Coordinates are chart points with an upper-left origin. Colors and the
/// bgra8Unorm target contain nonlinear sRGB components; output is premultiplied.
/// This explicit candidate contract must pass the independent Canvas pixel gate
/// before it can replace the existing renderer.
@MainActor
final class MetalArrivalBurstRenderer {
    struct Burst: Equatable {
        let id: RequestRailLifecycleEffects.Key
        let startTime: TimeInterval
        let profile: RequestRailEffectProfile
        let origin: CGPoint
        let color: SIMD4<Float>
    }

    struct Twinkle: Equatable {
        let twinkle: RequestRailTwinkle
        let placement: RequestRailTwinkle.Placement
        let startTime: TimeInterval
        let color: SIMD4<Float>
    }

    /// Element order is significant: each request's burst precedes its glints,
    /// before the following request's burst. Do not sort by primitive kind.
    enum Element: Equatable {
        case burst(Burst)
        case twinkle(Twinkle)
    }

    enum RendererError: Error, CustomStringConvertible {
        case deviceUnavailable
        case commandQueueUnavailable
        case shaderFunctionUnavailable
        case pipelineCreation(String)
        case bufferAllocationFailed
        case invalidInput(String)
        case capacityExceeded
        case unsupportedTarget
        case encoderUnavailable
        case tooManyFramesInFlight

        var description: String {
            switch self {
            case .deviceUnavailable: "Metal device unavailable"
            case .commandQueueUnavailable: "Metal command queue unavailable"
            case .shaderFunctionUnavailable: "Arrival shader entry point unavailable"
            case .pipelineCreation(let reason): "Arrival pipeline creation failed: \(reason)"
            case .bufferAllocationFailed: "Arrival descriptor allocation failed"
            case .invalidInput(let reason): "Invalid arrival input: \(reason)"
            case .capacityExceeded: "Arrival descriptor capacity exceeded"
            case .unsupportedTarget:
                "Arrival target must be a same-device, single-sample BGRA8Unorm render texture"
            case .encoderUnavailable: "Arrival render encoder unavailable"
            case .tooManyFramesInFlight: "Arrival frame capacity exceeded"
            }
        }
    }

    struct Statistics {
        let descriptorUploads: UInt64
        let encodedFrames: UInt64
        let inFlightFrames: Int
        let retainedDescriptorBuffers: Int
        let retainedDescriptorBytes: Int
        let elementCount: Int
    }

    // Sequential receipts can share a reused track. Bound receipts separately
    // from the five simultaneously occupied request tracks.
    static let maximumBursts = 64
    static let maximumTwinkles = 2
    static let maximumFramesInFlight = 3
    // Three submitted frames can retain distinct immutable buffers, plus the
    // latest publication. Unsubmitted intermediate publications are released.
    static let maximumDescriptorBuffers = maximumFramesInFlight + 1
    static let descriptorStride = 13 * MemoryLayout<SIMD4<Float>>.stride
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let leases = FrameLeases()
    private var elements: [Element] = []
    private var descriptorBuffer: (any MTLBuffer)?
    private var descriptorUploads: UInt64 = 0
    private var encodedFrames: UInt64 = 0

    init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RendererError.deviceUnavailable }
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }
        self.device = device
        commandQueue = queue
        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = false
            let library = try device.makeLibrary(source: Self.shader, options: options)
            guard let vertex = library.makeFunction(name: "arrivalVertex"),
                let fragment = library.makeFunction(name: "arrivalFragment")
            else {
                throw RendererError.shaderFunctionUnavailable
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "FluxLLM arrival burst diagnostic"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = Self.pixelFormat
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch let error as RendererError {
            throw error
        } catch {
            throw RendererError.pipelineCreation(String(describing: error))
        }
    }

    var statistics: Statistics {
        let retained = leases.snapshot(including: descriptorBuffer)
        return Statistics(
            descriptorUploads: descriptorUploads, encodedFrames: encodedFrames,
            inFlightFrames: retained.frames, retainedDescriptorBuffers: retained.buffers,
            retainedDescriptorBytes: retained.bytes, elementCount: elements.count)
    }

    func update(bursts: [Burst]) throws {
        try update(elements: bursts.map(Element.burst))
    }

    /// Equal publications are a no-op. Invalid publications leave the previous
    /// valid state intact. Buffer contents never change after submission.
    func update(elements newElements: [Element]) throws {
        if newElements == elements { return }
        var packed: [SIMD4<Float>] = []
        guard newElements.count <= Self.maximumBursts + Self.maximumTwinkles else {
            throw RendererError.capacityExceeded
        }
        packed.reserveCapacity(newElements.count * 13)
        var burstIDs: Set<RequestRailLifecycleEffects.Key> = []
        var twinkleIDs: Set<RequestRailTwinkle.ID> = []
        for element in newElements {
            switch element {
            case .burst(let burst):
                guard burstIDs.insert(burst.id).inserted else {
                    throw RendererError.invalidInput("duplicate burst identity")
                }
                guard burstIDs.count <= Self.maximumBursts else {
                    throw RendererError.capacityExceeded
                }
                try Self.append(burst, to: &packed)
            case .twinkle(let twinkle):
                guard twinkleIDs.insert(twinkle.twinkle.id).inserted else {
                    throw RendererError.invalidInput("duplicate twinkle identity")
                }
                guard twinkleIDs.count <= Self.maximumTwinkles else {
                    throw RendererError.capacityExceeded
                }
                try Self.append(twinkle, to: &packed)
            }
        }
        guard !packed.isEmpty else {
            removeAll()
            return
        }
        let buffer = packed.withUnsafeBytes { bytes in
            device.makeBuffer(
                bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }
        guard let buffer else { throw RendererError.bufferAllocationFailed }
        buffer.label = "FluxLLM immutable arrival descriptors"
        descriptorBuffer = buffer
        elements = newElements
        descriptorUploads &+= 1
    }

    func removeAll() {
        elements = []
        descriptorBuffer = nil
    }

    /// Encodes into the caller's target; no readback, waits, drawable acquisition,
    /// or presentation occurs here. Every successfully encoded command buffer
    /// must be committed. The caller checks its completion status/error. Capacity
    /// exhaustion is explicit, never a blocking wait or unbounded frame queue.
    func encode(
        into commandBuffer: any MTLCommandBuffer, target: any MTLTexture,
        elapsedTime: TimeInterval, pointSize: CGSize, origin: CGPoint = .zero,
        clear: Bool = true
    ) throws {
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
        else {
            throw RendererError.invalidInput("nonfinite or empty frame geometry/time")
        }
        guard let lease = leases.begin(buffer: descriptorBuffer, limit: Self.maximumFramesInFlight)
        else {
            throw RendererError.tooManyFramesInFlight
        }
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = clear ? .clear : .load
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            leases.finish(lease)
            throw RendererError.encoderUnavailable
        }
        encoder.label = "FluxLLM arrival burst pass"
        if let descriptorBuffer, !elements.isEmpty {
            let uniform = [
                SIMD4<Float>(
                    Float(pointSize.width), Float(pointSize.height), Float(origin.x),
                    Float(origin.y)),
                SIMD4<Float>(Float(elapsedTime), 0, 0, 0),
            ]
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(descriptorBuffer, offset: 0, index: 0)
            encoder.setFragmentBuffer(descriptorBuffer, offset: 0, index: 0)
            uniform.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            }
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: elements.count)
        }
        encoder.endEncoding()
        let leases = leases
        commandBuffer.addCompletedHandler { _ in leases.finish(lease) }
        encodedFrames &+= 1
    }

    private static func finite<T: BinaryFloatingPoint>(_ value: T) -> Bool {
        value.isFinite && Float(value).isFinite
    }

    // Hosts use a nearby double-precision anchor, avoiding epoch-sized Floats.
    private static func validTime(_ value: TimeInterval) -> Bool {
        value.isFinite && abs(value) <= 86_400
    }

    private static func validColor(_ color: SIMD4<Float>) -> Bool {
        (0..<4).allSatisfy { color[$0].isFinite && (0...1).contains(color[$0]) }
    }

    private static func append(_ burst: Burst, to packed: inout [SIMD4<Float>]) throws {
        let profile = burst.profile
        let count = profile.family == .fireflies ? 4 : 5
        guard !profile.completion, !burst.id.completion, validTime(burst.startTime),
            finite(burst.origin.x), finite(burst.origin.y), validColor(burst.color),
            profile.particles.count == count,
            profile.burstDuration.isFinite, profile.burstDuration > 0,
            profile.burstDuration <= 1, profile.size.isFinite, (0.9...1.1).contains(profile.size),
            finite(profile.angle)
        else { throw RendererError.invalidInput("invalid arrival descriptor") }
        let family: Float = profile.family == .fireflies ? 0 : profile.family == .sparks ? 1 : 2
        packed.append(
            SIMD4(
                Float(burst.origin.x), Float(burst.origin.y), Float(burst.startTime),
                Float(profile.burstDuration)))
        packed.append(SIMD4(family, Float(profile.size), Float(profile.angle), 0))
        packed.append(burst.color)
        for particle in profile.particles {
            guard
                [
                    particle.angle, particle.distance, particle.length, particle.size,
                    particle.delay, particle.life, particle.stretch,
                ].allSatisfy({ finite($0) }),
                particle.life > 0, particle.size > 0
            else {
                throw RendererError.invalidInput("invalid arrival particle")
            }
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
    }

    private static func append(_ input: Twinkle, to packed: inout [SIMD4<Float>]) throws {
        let twinkle = input.twinkle
        let placement = input.placement
        let bar = placement.bar
        guard validTime(input.startTime), validColor(input.color),
            finite(placement.center.x), finite(placement.center.y),
            finite(bar.minX), finite(bar.minY), finite(bar.width), finite(bar.height),
            bar.width > 0, bar.height > 0, finite(placement.cornerRadius),
            placement.cornerRadius >= 0,
            finite(twinkle.duration), twinkle.duration > 0, twinkle.duration <= 1,
            finite(twinkle.size), twinkle.size > 0, twinkle.size <= 3.3,
            finite(twinkle.angle)
        else { throw RendererError.invalidInput("invalid twinkle descriptor") }
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

    /// The completion handler releases its lease synchronously under this lock;
    /// no main-actor task can delay resource cleanup after GPU completion.
    private final class FrameLeases: @unchecked Sendable {
        private struct Lease { let buffer: (any MTLBuffer)? }
        private let lock = NSLock()
        private var nextID: UInt64 = 0
        private var active: [UInt64: Lease] = [:]

        func begin(buffer: (any MTLBuffer)?, limit: Int) -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            guard active.count < limit else { return nil }
            nextID &+= 1
            active[nextID] = Lease(buffer: buffer)
            return nextID
        }

        func finish(_ id: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            active.removeValue(forKey: id)
        }

        func snapshot(including current: (any MTLBuffer)?) -> (
            frames: Int, buffers: Int, bytes: Int
        ) {
            lock.lock()
            defer { lock.unlock() }
            var unique: [ObjectIdentifier: any MTLBuffer] = [:]
            if let current { unique[ObjectIdentifier(current)] = current }
            for lease in active.values {
                if let buffer = lease.buffer { unique[ObjectIdentifier(buffer)] = buffer }
            }
            return (active.count, unique.count, unique.values.reduce(0) { $0 + $1.length })
        }
    }

    private static let shader = #"""
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms { float4 viewport; float4 time; };
        struct VertexOut {
            float4 position [[position]];
            float2 point;
            uint element [[flat]];
        };

        vertex VertexOut arrivalVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                      device const float4 *data [[buffer(0)]],
                                      constant Uniforms &u [[buffer(1)]]) {
            const float2 corners[6] = {float2(-1,-1), float2(1,-1), float2(-1,1),
                                       float2(-1,1), float2(1,-1), float2(1,1)};
            float4 frame = data[instanceID * 13], style = data[instanceID * 13 + 1];
            float2 center = frame.xy, extent = float2(42.0f);
            if (style.w > 0.5f) {
                float4 bar = data[instanceID * 13 + 3];
                center.y = bar.y + bar.w * 0.5f;
                extent = float2(style.y * 2.1f + 1.0f, bar.w * 0.5f + 1.0f);
            }
            float2 point = center + corners[vertexID] * extent;
            VertexOut out;
            float2 normalized = (point - u.viewport.zw) / u.viewport.xy;
            out.position = float4(normalized.x * 2.0f - 1.0f, 1.0f - normalized.y * 2.0f, 0, 1);
            out.point = point;
            out.element = instanceID;
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

        fragment float4 arrivalFragment(VertexOut in [[stage_in]],
                                        device const float4 *data [[buffer(0)]],
                                        constant Uniforms &u [[buffer(1)]]) {
            uint offset=in.element*13;
            float4 frame=data[offset], style=data[offset+1], color=data[offset+2];
            float p=(u.time.x-frame.z)/frame.w;
            if(p<=0.0f || p>=1.0f) return float4(0);
            float2 point=in.point-frame.xy;
            float4 result=float4(0);
            if(style.w>0.5f) {
                float strength=sin(M_PI_F*p); strength*=strength;
                float size=style.y*(0.7f+0.3f*strength);
                float4 bar=data[offset+3];
                float clip=coverage(roundedRectangle(in.point,bar,data[offset+4].x));
                float2 ellipsePoint=float2(point.x/(size*2.1f),
                                          (in.point.y-(bar.y+bar.w*0.5f))/(bar.w*0.5f));
                float ellipse=coverage((length(ellipsePoint)-1.0f)*min(size*2.1f,bar.w*0.5f));
                result=over(result,solid(color,strength*0.32f,ellipse*clip));
                float mark=style.x>0.5f ? coverage(starDistance(point,size,style.z))
                                       : coverage(length(point)-size*0.56f);
                return over(result,solid(float4(1),strength,mark*clip));
            }
            float strength=envelope(p);
            float expansion=1.0f-pow(1.0f-p,3.0f);
            float size=style.y;
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
        """#
}
