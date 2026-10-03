import Foundation
import Metal
import simd

/// Retains the static chart as immutable GPU geometry. Publication changes build
/// spatial tiles once; animation frames only submit the retained buffers. Each
/// tile evaluates the union of nearby segments, so translucent line joins do not
/// darken from overlapping capsules. Primitive order remains the scene's order.
@MainActor
final class MetalFullChartRenderer {
    enum RendererError: Error, CustomStringConvertible {
        case deviceUnavailable, shaderFunctionUnavailable, bufferAllocationFailed
        case pipelineCreation(String)
        case invalidInput(String)
        case capacityExceeded
        case unsupportedTarget, encoderUnavailable, tooManyFramesInFlight

        var description: String {
            switch self {
            case .deviceUnavailable: "Metal device unavailable"
            case .shaderFunctionUnavailable: "Full chart shader entry point unavailable"
            case .bufferAllocationFailed: "Full chart buffer allocation failed"
            case .pipelineCreation(let reason): "Full chart pipeline creation failed: \(reason)"
            case .invalidInput(let reason): "Invalid full chart scene: \(reason)"
            case .capacityExceeded: "Full chart retained geometry capacity exceeded"
            case .unsupportedTarget:
                "Full chart target must be a same-device, single-sample BGRA8Unorm render texture"
            case .encoderUnavailable: "Full chart render encoder unavailable"
            case .tooManyFramesInFlight: "Full chart frame capacity exceeded"
            }
        }
    }

    struct Statistics {
        let uploadCount: UInt64
        let uploadedBytes: UInt64
        let encodedFrames: UInt64
        let drawCalls: UInt64
        let inFlightFrames: Int
        let retainedSceneVersions: Int
        let retainedBytes: Int
        let primitiveCount: Int
        let vertexCount: Int
    }

    static let maximumFramesInFlight = 3
    static let maximumRetainedSceneVersions = 3
    static let maximumSceneBytes = 8 * 1_024 * 1_024
    static let maximumRetainedBytes = maximumRetainedSceneVersions * maximumSceneBytes
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    private static let tileSize: Float = 32
    private static let styleStride = 10
    private static let maximumPrimitives = 16_384
    private static let maximumSegments = 65_536
    private static let maximumContainmentTests = 16_000_000

    private struct Vertex {
        var point: SIMD2<Float>
        var style: UInt32
        var tile: UInt32
    }

    private final class Geometry: @unchecked Sendable {
        let vertices: any MTLBuffer
        let styles: any MTLBuffer
        let tiles: any MTLBuffer
        let edges: any MTLBuffer
        let vertexCount: Int
        let primitiveCount: Int
        var bytes: Int { vertices.length + styles.length + tiles.length + edges.length }

        init(
            vertices: any MTLBuffer, styles: any MTLBuffer, tiles: any MTLBuffer,
            edges: any MTLBuffer, vertexCount: Int, primitiveCount: Int
        ) {
            self.vertices = vertices
            self.styles = styles
            self.tiles = tiles
            self.edges = edges
            self.vertexCount = vertexCount
            self.primitiveCount = primitiveCount
        }
    }

    let device: any MTLDevice
    private let pipeline: any MTLRenderPipelineState
    private let leases = FrameLeases()
    private var sceneIdentity: ObjectIdentifier?
    // Retain the scene to prevent an allocator reusing its identity while cached.
    private var retainedScene: MetalFullChartScene?
    private var geometry: Geometry?
    private var uploadCount: UInt64 = 0
    private var uploadedBytes: UInt64 = 0
    private var encodedFrames: UInt64 = 0
    private var drawCalls: UInt64 = 0

    init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw RendererError.deviceUnavailable }
        self.device = device
        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = false
            let library = try device.makeLibrary(source: Self.shader, options: options)
            guard let vertex = library.makeFunction(name: "fullChartVertex"),
                let fragment = library.makeFunction(name: "fullChartFragment")
            else {
                throw RendererError.shaderFunctionUnavailable
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "FluxLLM retained full chart"
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
        } catch let error as RendererError {
            throw error
        } catch {
            throw RendererError.pipelineCreation(String(describing: error))
        }
    }

    var statistics: Statistics {
        let retained = leases.snapshot(including: geometry)
        return Statistics(
            uploadCount: uploadCount, uploadedBytes: uploadedBytes,
            encodedFrames: encodedFrames, drawCalls: drawCalls,
            inFlightFrames: retained.frames, retainedSceneVersions: retained.versions,
            retainedBytes: retained.bytes, primitiveCount: geometry?.primitiveCount ?? 0,
            vertexCount: geometry?.vertexCount ?? 0)
    }

    /// Identical scene objects do not rebuild or upload. Validation/allocation
    /// failures preserve the last valid scene. A publication cannot create a
    /// fourth retained version, even when all earlier versions are in flight.
    func update(scene: MetalFullChartScene) throws {
        guard ObjectIdentifier(scene) != sceneIdentity else { return }
        guard Self.valid(scene.size.width), Self.valid(scene.size.height),
            scene.size.width > 0, scene.size.height > 0,
            scene.size.width <= 32_768, scene.size.height <= 32_768,
            scene.primitives.count <= Self.maximumPrimitives
        else {
            throw RendererError.invalidInput("scene dimensions or primitive count")
        }
        let packed = try PackedScene(scene: scene)
        let replacement: Geometry?
        if packed.vertices.isEmpty {
            replacement = nil
        } else {
            guard leases.canReplaceCurrent(maximumVersions: Self.maximumRetainedSceneVersions)
            else {
                throw RendererError.capacityExceeded
            }
            func buffer<T>(_ values: [T], label: String) throws -> any MTLBuffer {
                let result = values.withUnsafeBytes { bytes in
                    device.makeBuffer(
                        bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
                }
                guard let result else { throw RendererError.bufferAllocationFailed }
                result.label = label
                return result
            }
            replacement = try Geometry(
                vertices: buffer(packed.vertices, label: "FluxLLM static chart tile vertices"),
                styles: buffer(packed.styles, label: "FluxLLM static chart styles"),
                tiles: buffer(packed.tiles, label: "FluxLLM static chart tiles"),
                edges: buffer(packed.edges, label: "FluxLLM static chart nearby edges"),
                vertexCount: packed.vertices.count, primitiveCount: scene.primitives.count)
        }
        geometry = replacement
        sceneIdentity = ObjectIdentifier(scene)
        retainedScene = scene
        uploadCount &+= 1
        uploadedBytes &+= UInt64(replacement?.bytes ?? 0)
    }

    func removeAll() {
        geometry = nil
        sceneIdentity = nil
        retainedScene = nil
    }

    func encodeStatic(
        into commandBuffer: any MTLCommandBuffer, target: any MTLTexture,
        pointSize: CGSize
    ) throws {
        try encode(into: commandBuffer, target: target, pointSize: pointSize)
    }

    /// Every successfully encoded command buffer must be committed by the
    /// caller. Completion releases resources synchronously; there are no waits,
    /// readbacks, drawable acquisition, or geometry changes in this method.
    func encode(
        into commandBuffer: any MTLCommandBuffer, target: any MTLTexture,
        pointSize: CGSize, clear: Bool = true
    ) throws {
        guard target.device.registryID == device.registryID,
            commandBuffer.device.registryID == device.registryID,
            target.pixelFormat == Self.pixelFormat, target.textureType == .type2D,
            target.sampleCount == 1, target.width > 0, target.height > 0,
            target.usage.contains(.renderTarget)
        else { throw RendererError.unsupportedTarget }
        guard Self.valid(pointSize.width), Self.valid(pointSize.height),
            pointSize.width > 0, pointSize.height > 0
        else {
            throw RendererError.invalidInput("frame dimensions")
        }
        guard let lease = leases.begin(geometry: geometry, limit: Self.maximumFramesInFlight) else {
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
        encoder.label = "FluxLLM retained full chart pass"
        if let geometry {
            var viewport = SIMD4<Float>(
                Float(pointSize.width), Float(pointSize.height),
                Float(target.width) / Float(pointSize.width),
                Float(target.height) / Float(pointSize.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(geometry.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setFragmentBuffer(geometry.styles, offset: 0, index: 0)
            encoder.setFragmentBuffer(geometry.tiles, offset: 0, index: 1)
            encoder.setFragmentBuffer(geometry.edges, offset: 0, index: 2)
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: geometry.vertexCount)
            drawCalls &+= 1
        }
        encoder.endEncoding()
        let leases = leases
        commandBuffer.addCompletedHandler { _ in leases.finish(lease) }
        encodedFrames &+= 1
    }

    private static func valid(_ value: CGFloat) -> Bool { value.isFinite && Float(value).isFinite }
    private static func valid(_ point: CGPoint) -> Bool {
        valid(point.x) && valid(point.y) && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000
    }
    private static func valid(_ rect: CGRect) -> Bool {
        valid(rect.origin) && valid(rect.width) && valid(rect.height)
            && rect.width >= 0 && rect.height >= 0
            && abs(rect.minX) <= 1_000_000 && abs(rect.minY) <= 1_000_000
            && abs(rect.maxX) <= 1_000_000 && abs(rect.maxY) <= 1_000_000
    }
    private static func colorValid(_ color: SIMD4<Float>) -> Bool {
        (0..<4).allSatisfy { color[$0].isFinite && (0...1).contains(color[$0]) }
    }

    @MainActor private struct PackedScene {
        var vertices: [Vertex] = []
        var styles: [SIMD4<Float>] = []
        // Index zero is a harmless placeholder for analytical shape quads.
        var tiles: [SIMD4<Float>] = [.zero, .zero]
        var edges: [SIMD4<Float>] = [.zero]
        var containmentTests = 0

        init(scene: MetalFullChartScene) throws {
            for primitive in scene.primitives { try append(primitive) }
            try checkCapacity()
        }

        var byteCount: Int {
            vertices.count * MemoryLayout<Vertex>.stride
                + (styles.count + tiles.count + edges.count) * MemoryLayout<SIMD4<Float>>.stride
        }

        func checkCapacity() throws {
            guard byteCount <= maximumSceneBytes else { throw RendererError.capacityExceeded }
        }

        mutating func quad(_ rect: SIMD4<Float>, style: UInt32, tile: UInt32) {
            let a = SIMD2(rect.x, rect.y)
            let b = SIMD2(rect.z, rect.y)
            let c = SIMD2(rect.x, rect.w)
            let d = SIMD2(rect.z, rect.w)
            for point in [a, b, c, c, b, d] {
                vertices.append(Vertex(point: point, style: style, tile: tile))
            }
        }

        mutating func append(_ primitive: MetalFullChartScene.Primitive) throws {
            let strokeWidth = Float(primitive.stroke?.width ?? 0)
            let blurRadius = Float(primitive.stroke?.blurRadius ?? 0)
            guard strokeWidth.isFinite, strokeWidth >= 0, strokeWidth <= 1_024,
                blurRadius.isFinite, blurRadius >= 0, blurRadius <= 128
            else {
                throw RendererError.invalidInput("stroke width or blur")
            }
            var style = Array(repeating: SIMD4<Float>.zero, count: styleStride)
            style[0] = SIMD4(0, strokeWidth, blurRadius, primitive.stroke == nil ? 0 : 1)
            style[9].y = primitive.stroke?.cap == .butt ? 1 : 0
            switch primitive.paint {
            case .solid(let color):
                guard colorValid(color) else { throw RendererError.invalidInput("paint color") }
                style[4] = color
                style[5] = color
                style[6] = color
            case .linear(let start, let end, let stops):
                guard valid(start), valid(end), (1...3).contains(stops.count),
                    stops.allSatisfy({
                        valid($0.location) && (0...1).contains($0.location) && colorValid($0.color)
                    }),
                    zip(stops, stops.dropFirst()).allSatisfy({ $0.location <= $1.location })
                else {
                    throw RendererError.invalidInput("gradient")
                }
                style[2].y = 1
                style[2].z = Float(stops.count)
                style[3] = SIMD4(Float(start.x), Float(start.y), Float(end.x), Float(end.y))
                for index in 0..<3 {
                    let stop = stops[min(index, stops.count - 1)]
                    style[4 + index] = stop.color
                    style[7][index] = Float(stop.location)
                }
            }
            if let clip = primitive.clip {
                guard valid(clip.rect), valid(clip.radius), clip.radius >= 0 else {
                    throw RendererError.invalidInput("rounded clipping rectangle")
                }
                style[2].w = 1
                style[8] = SIMD4(
                    Float(clip.rect.minX), Float(clip.rect.minY),
                    Float(clip.rect.width), Float(clip.rect.height))
                style[9].x = Float(clip.radius)
            }
            let styleIndex = UInt32(styles.count / styleStride)
            switch primitive.shape {
            case .polygon(let points), .polyline(let points):
                guard points.allSatisfy(valid), points.count <= maximumSegments else {
                    throw RendererError.invalidInput("path points")
                }
                let closed: Bool
                if case .polygon = primitive.shape { closed = true } else { closed = false }
                let filled = closed && primitive.stroke == nil
                style[0].x = filled ? 0 : 1
                styles.append(contentsOf: style)
                guard points.count >= (filled ? 3 : 2) else { return }
                let path = points.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
                var segments: [SIMD4<Float>] = []
                for index in 1..<path.count {
                    segments.append(
                        SIMD4(path[index - 1].x, path[index - 1].y, path[index].x, path[index].y))
                }
                if closed, path.first != path.last, let first = path.first, let last = path.last {
                    segments.append(SIMD4(last.x, last.y, first.x, first.y))
                }
                if !filled {
                    segments = try Self.dashed(segments, pattern: primitive.stroke?.dash ?? [])
                }
                try tiled(
                    segments: segments, filled: filled, style: styleIndex,
                    padding: (filled ? 0 : strokeWidth * 0.5) + blurRadius * 3 + 1.5)
            case .ellipse(let rect), .roundedRect(let rect, radius: _):
                guard valid(rect) else { throw RendererError.invalidInput("shape bounds") }
                guard rect.width > 0, rect.height > 0 else { return }
                style[1] = SIMD4(
                    Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height))
                if case .roundedRect(_, let radius) = primitive.shape {
                    guard valid(radius), radius >= 0 else {
                        throw RendererError.invalidInput("corner radius")
                    }
                    style[0].x = 3
                    style[2].x = Float(radius)
                } else {
                    style[0].x = 2
                }
                styles.append(contentsOf: style)
                let padding = strokeWidth * 0.5 + blurRadius * 3 + 1.5
                quad(
                    SIMD4(
                        Float(rect.minX) - padding, Float(rect.minY) - padding,
                        Float(rect.maxX) + padding, Float(rect.maxY) + padding), style: styleIndex,
                    tile: 0)
            }
            try checkCapacity()
        }

        private static func dashed(_ segments: [SIMD4<Float>], pattern source: [CGFloat]) throws
            -> [SIMD4<Float>]
        {
            guard !source.isEmpty else { return segments }
            guard source.count <= 128, source.allSatisfy({ valid($0) && $0 > 0 }) else {
                throw RendererError.invalidInput("dash pattern")
            }
            var pattern = source.map { Float($0) }
            if pattern.count % 2 != 0 { pattern += pattern }
            var result: [SIMD4<Float>] = []
            var index = 0
            var remaining = pattern[0]
            for segment in segments {
                let a = SIMD2(segment.x, segment.y)
                let b = SIMD2(segment.z, segment.w)
                let vector = b - a
                let length = simd_length(vector)
                guard length > 0 else { continue }
                var position: Float = 0
                while position < length {
                    let amount = min(remaining, length - position)
                    guard amount > 0, position + amount > position else {
                        throw RendererError.invalidInput("dash resolution")
                    }
                    if index % 2 == 0 {
                        let start = a + vector * (position / length)
                        let end = a + vector * ((position + amount) / length)
                        result.append(SIMD4(start.x, start.y, end.x, end.y))
                        guard result.count <= maximumSegments else {
                            throw RendererError.capacityExceeded
                        }
                    }
                    position += amount
                    remaining -= amount
                    if remaining <= 0.00001 {
                        index = (index + 1) % pattern.count
                        remaining = pattern[index]
                    }
                }
            }
            return result
        }

        private mutating func tiled(
            segments: [SIMD4<Float>], filled: Bool,
            style: UInt32, padding: Float
        ) throws {
            guard !segments.isEmpty else { return }
            var minX = Float.greatestFiniteMagnitude
            var minY = minX
            var maxX = -minX
            var maxY = -minX
            for edge in segments {
                minX = min(minX, min(edge.x, edge.z))
                minY = min(minY, min(edge.y, edge.w))
                maxX = max(maxX, max(edge.x, edge.z))
                maxY = max(maxY, max(edge.y, edge.w))
            }
            guard max(max(abs(minX), abs(minY)), max(abs(maxX), abs(maxY))) <= 1_000_000 else {
                throw RendererError.invalidInput("path coordinate magnitude")
            }
            let x0 = Int(floor((minX - padding) / tileSize))
            let y0 = Int(floor((minY - padding) / tileSize))
            let x1 = Int(floor((maxX + padding) / tileSize))
            let y1 = Int(floor((maxY + padding) / tileSize))
            let columns = x1 - x0 + 1
            let rows = y1 - y0 + 1
            guard columns > 0, rows > 0, columns <= 65_536 / rows else {
                throw RendererError.capacityExceeded
            }
            if filled {
                let work = columns * rows * segments.count
                guard work <= maximumContainmentTests - containmentTests else {
                    throw RendererError.capacityExceeded
                }
                containmentTests += work
            }
            var nearby: [Int: [Int]] = [:]
            var candidateCount = 0
            for (index, edge) in segments.enumerated() {
                let ex0 = max(x0, Int(floor((min(edge.x, edge.z) - padding) / tileSize)))
                let ex1 = min(x1, Int(floor((max(edge.x, edge.z) + padding) / tileSize)))
                let ey0 = max(y0, Int(floor((min(edge.y, edge.w) - padding) / tileSize)))
                let ey1 = min(y1, Int(floor((max(edge.y, edge.w) + padding) / tileSize)))
                for y in ey0...ey1 {
                    for x in ex0...ex1 {
                        candidateCount += 1
                        guard
                            candidateCount <= maximumSceneBytes / MemoryLayout<SIMD4<Float>>.stride
                        else {
                            throw RendererError.capacityExceeded
                        }
                        nearby[(y - y0) * columns + x - x0, default: []].append(index)
                    }
                }
            }
            // Stable tile ordering makes captured scene buffers reproducible.
            let indices = filled ? Array(0..<(columns * rows)) : nearby.keys.sorted()
            for index in indices {
                let x = x0 + index % columns
                let y = y0 + index / columns
                let origin = SIMD2(Float(x) * tileSize, Float(y) * tileSize)
                let candidates = nearby[index] ?? []
                let reference =
                    filled
                    ? try Self.referencePoint(
                        origin: origin, segments: segments,
                        candidates: candidates) : origin
                let inside = filled && Self.contains(reference, segments: segments)
                if candidates.isEmpty && !inside { continue }
                let tileIndex = UInt32(tiles.count / 2)
                tiles.append(
                    SIMD4(reference.x, reference.y, Float(edges.count), Float(candidates.count)))
                tiles.append(SIMD4(inside ? 1 : 0, 0, 0, 0))
                for candidate in candidates { edges.append(segments[candidate]) }
                quad(
                    SIMD4(origin.x, origin.y, origin.x + tileSize, origin.y + tileSize),
                    style: style, tile: tileIndex)
                try checkCapacity()
            }
        }

        private static func contains(_ point: SIMD2<Float>, segments: [SIMD4<Float>]) -> Bool {
            var inside = false
            for edge in segments where (edge.y > point.y) != (edge.w > point.y) {
                let crossingX = edge.x + (point.y - edge.y) * (edge.z - edge.x) / (edge.w - edge.y)
                if point.x < crossingX { inside.toggle() }
            }
            return inside
        }

        /// A boundary reference has an ambiguous inside state. Select a stable
        /// point clear of the local edges, including curves through tile corners.
        /// Admission is bounded even for pathological self-overlapping input.
        private static func referencePoint(
            origin: SIMD2<Float>, segments: [SIMD4<Float>],
            candidates: [Int]
        ) throws -> SIMD2<Float> {
            let clearance = max(0.001, max(abs(origin.x), abs(origin.y)) * Float.ulpOfOne * 4)
            for attempt in 0..<16 {
                let offset = SIMD2<Float>(
                    0.03125 + Float((attempt * 7) % 16) * 1.875,
                    0.0625 + Float((attempt * 11) % 16) * 1.875)
                let point = origin + offset
                let clear = candidates.allSatisfy { index in
                    let edge = segments[index]
                    let a = SIMD2(edge.x, edge.y)
                    let vector = SIMD2(edge.z, edge.w) - a
                    let amount = min(
                        1,
                        max(0, simd_dot(point - a, vector) / max(simd_dot(vector, vector), 1e-12)))
                    return simd_length(point - a - vector * amount) > clearance
                }
                if clear { return point }
            }
            throw RendererError.invalidInput("path has no unambiguous tile reference")
        }
    }

    private final class FrameLeases: @unchecked Sendable {
        private let lock = NSLock()
        private var nextID: UInt64 = 0
        private var active: [UInt64: Geometry?] = [:]

        func begin(geometry: Geometry?, limit: Int) -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            guard active.count < limit else { return nil }
            nextID &+= 1
            active.updateValue(geometry, forKey: nextID)
            return nextID
        }
        func finish(_ id: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            active.removeValue(forKey: id)
        }
        func canReplaceCurrent(maximumVersions: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let unique = Set(active.values.compactMap { $0.map(ObjectIdentifier.init) })
            return unique.count < maximumVersions
        }
        func snapshot(including current: Geometry?) -> (frames: Int, versions: Int, bytes: Int) {
            lock.lock()
            defer { lock.unlock() }
            var unique: [ObjectIdentifier: Geometry] = [:]
            if let current { unique[ObjectIdentifier(current)] = current }
            for item in active.values { if let item { unique[ObjectIdentifier(item)] = item } }
            return (active.count, unique.count, unique.values.reduce(0) { $0 + $1.bytes })
        }
    }

    private static let shader = #"""
        #include <metal_stdlib>
        using namespace metal;
        struct Input { float2 point; uint style; uint tile; };
        struct Output { float4 position [[position]]; float2 point; uint style [[flat]]; uint tile [[flat]]; };
        vertex Output fullChartVertex(uint id [[vertex_id]], device const Input *v [[buffer(0)]],
                                       constant float4 &viewport [[buffer(1)]]) {
            Output out;
            out.point = v[id].point; out.style = v[id].style; out.tile = v[id].tile;
            float2 p = out.point / viewport.xy;
            out.position = float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1);
            return out;
        }
        float cross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }
        float segmentDistance(float2 p, float4 edge) {
            float2 v = edge.zw - edge.xy;
            float t = clamp(dot(p - edge.xy, v) / max(dot(v, v), 1e-12f), 0.0f, 1.0f);
            return length(p - edge.xy - v * t);
        }
        float buttSegmentDistance(float2 p, float4 edge, float width) {
            float2 vector = edge.zw - edge.xy;
            float magnitude = length(vector);
            if (magnitude <= 1e-6f) return 1e5f;
            float2 tangent = vector / magnitude, delta = p - (edge.xy + edge.zw) * 0.5f;
            float2 q = abs(float2(dot(delta, tangent), cross2(tangent, delta)))
                       - float2(magnitude * 0.5f, width * 0.5f);
            return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f);
        }
        bool crosses(float2 reference, float2 point, float4 edge) {
            float2 ray = point - reference, a = edge.xy - reference, b = edge.zw - reference;
            float sideA = cross2(ray, a), sideB = cross2(ray, b);
            if ((sideA > 0) == (sideB > 0)) return false;
            float denominator = cross2(ray, edge.zw - edge.xy);
            if (abs(denominator) < 1e-12f) return false;
            float t = cross2(a, edge.zw - edge.xy) / denominator;
            return t > 0 && t <= 1;
        }
        float roundedDistance(float2 p, float4 rect, float radius) {
            float2 halfSize = rect.zw * 0.5f;
            radius = min(max(radius, 0.0f), min(halfSize.x, halfSize.y));
            float2 q = abs(p - rect.xy - halfSize) - halfSize + radius;
            return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - radius;
        }
        float ellipseDistance(float2 p, float4 rect) {
            float2 radius = max(rect.zw * 0.5f, 1e-5f);
            float2 q = p - rect.xy - radius;
            float k0 = length(q / radius), k1 = length(q / (radius * radius));
            return k1 > 1e-6f ? k0 * (k0 - 1) / k1 : -min(radius.x, radius.y);
        }
        float coverage(float d) { return clamp(0.5f - d / max(fwidth(d), 1e-5f), 0.0f, 1.0f); }
        // Gaussian edge falloff. The candidate retains the original blur radius;
        // image comparisons quantify differences from Canvas's raster convolution.
        float blurredCoverage(float d, float radius) {
            float x = d / max(radius * 1.41421356237f, 1e-5f);
            float t = 1.0f / (1.0f + 0.3275911f * abs(x));
            float erf = 1.0f - (((((1.061405429f * t - 1.453152027f) * t) + 1.421413741f) * t
                               - 0.284496736f) * t + 0.254829592f) * t * exp(-x*x);
            return 0.5f * (1.0f - (x < 0 ? -erf : erf));
        }
        fragment float4 fullChartFragment(Output in [[stage_in]], device const float4 *styles [[buffer(0)]],
                                           device const float4 *tiles [[buffer(1)]], device const float4 *edges [[buffer(2)]]) {
            uint base = in.style * 10;
            float4 mode = styles[base], shape = styles[base+1], options = styles[base+2];
            float distance = 1e5f;
            if (mode.x < 1.5f) {
                float4 tile = tiles[in.tile * 2];
                bool inside = tiles[in.tile * 2 + 1].x > 0.5f;
                uint begin = uint(tile.z), count = uint(tile.w);
                bool butt = mode.x > 0.5f && styles[base+9].y > 0.5f;
                for (uint i = 0; i < count; ++i) {
                    float4 edge = edges[begin+i];
                    distance = min(distance, butt ? buttSegmentDistance(in.point, edge, mode.y)
                                                   : segmentDistance(in.point, edge));
                    if (mode.x < 0.5f && crosses(tile.xy, in.point, edge)) inside = !inside;
                }
                if (mode.x < 0.5f) distance = inside ? -distance : distance;
                else if (!butt) distance -= mode.y * 0.5f;
            } else {
                distance = mode.x < 2.5f ? ellipseDistance(in.point, shape)
                                         : roundedDistance(in.point, shape, options.x);
                if (mode.w > 0.5f) distance = abs(distance) - mode.y * 0.5f;
            }
            float mask = coverage(distance);
            if (mode.z > 0) {
                mask = blurredCoverage(distance, mode.z);
                if (mode.w > 0.5f) mask -= blurredCoverage(distance + mode.y, mode.z);
            }
            if (options.w > 0.5f) mask *= coverage(roundedDistance(in.point, styles[base+8], styles[base+9].x));
            if (mask <= 0) return float4(0);
            float4 color = styles[base+4];
            if (options.y > 0.5f) {
                float4 endpoints = styles[base+3], stops = styles[base+7];
                float2 delta = endpoints.zw - endpoints.xy;
                float t = clamp(dot(in.point - endpoints.xy, delta) / max(dot(delta, delta), 1e-12f), 0.0f, 1.0f);
                if (t > stops.x && options.z > 1.5f) {
                    if (t <= stops.y || options.z < 2.5f)
                        color = mix(styles[base+4], styles[base+5], clamp((t-stops.x) / max(stops.y-stops.x, 1e-6f), 0.0f, 1.0f));
                    else color = mix(styles[base+5], styles[base+6], clamp((t-stops.y) / max(stops.z-stops.y, 1e-6f), 0.0f, 1.0f));
                }
            }
            float alpha = color.a * mask;
            return float4(color.rgb * alpha, alpha);
        }
        """#
}
