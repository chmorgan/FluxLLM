import Accelerate
import CoreGraphics
import Foundation

/// Diagnostic CPU implementation of the series glow. An owner supplies immutable
/// paths for the lifetime of one geometry publication; no telemetry or rendered
/// frames are retained across publications. All calls belong to the drawing thread.
final class SeriesGlowRasterCache {
    struct ID: Hashable {
        let series: Int
        let segment: Int
    }

    struct Mask {
        let image: CGImage
        let rect: CGRect
        var byteCount: Int { image.bytesPerRow * image.height }
    }

    struct Statistics {
        let cachedBytes: Int
        let cachedEntries: Int
        let rasterizedMasks: Int
        let cacheHits: Int
        let peakScratchBytes: Int
    }

    enum RasterError: Error, Equatable {
        case invalidInput
        case oversizedSurface
        case scratchLimit
        case allocationFailed
        case convolution(Int)
    }

    private struct Key: Hashable {
        let id: ID
        let scale: CGFloat
        let radius: CGFloat
        let left: Int
        let top: Int
        let right: Int
        let bottom: Int
    }

    private let maximumCachedBytes: Int
    private let maximumScratchBytes: Int
    private let tilePixelSize: Int
    private let sigmaMultiplier: Double
    private var entries: [Key: [Mask]] = [:]
    private var cachedBytes = 0
    private var rasterizedMasks = 0
    private var cacheHits = 0
    private var peakScratchBytes = 0

    var statistics: Statistics {
        Statistics(
            cachedBytes: cachedBytes, cachedEntries: entries.count,
            rasterizedMasks: rasterizedMasks, cacheHits: cacheHits,
            peakScratchBytes: peakScratchBytes)
    }

    init(
        maximumCachedBytes: Int = 4 * 1_024 * 1_024,
        maximumScratchBytes: Int = 2 * 1_024 * 1_024,
        tilePixelSize: Int = 256, sigmaMultiplier: Double = 1
    ) {
        self.maximumCachedBytes = max(0, maximumCachedBytes)
        self.maximumScratchBytes = max(0, maximumScratchBytes)
        self.tilePixelSize = min(max(1, tilePixelSize), 1_024)
        self.sigmaMultiplier = sigmaMultiplier
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        cachedBytes = 0
    }

    /// The requested blur radius is kept explicit: the diagnostic's initial
    /// radius-to-sigma mapping must be calibrated against the original renderer
    /// before this implementation can become the normal production path.
    func forEachMask(
        id: ID, path: CGPath, radius: CGFloat, scale: CGFloat, clipBounds: CGRect,
        _ draw: (Mask) -> Void
    ) throws {
        guard radius.isFinite, radius > 0, scale.isFinite, scale > 0,
            sigmaMultiplier.isFinite, sigmaMultiplier > 0,
            valid(clipBounds)
        else { throw RasterError.invalidInput }
        let sigma = Double(radius * scale) * sigmaMultiplier
        // Covers the app's 2.5/3pt glow at native display scales while refusing
        // pathological inputs before integer conversion or buffer allocation.
        guard sigma.isFinite, sigma > 0, sigma <= 32, scale <= 8 else {
            throw RasterError.oversizedSurface
        }
        if path.isEmpty { return }
        let pathBounds = path.boundingBoxOfPath
        guard pathBounds.origin.x.isFinite, pathBounds.origin.y.isFinite,
            pathBounds.size.width.isFinite, pathBounds.size.height.isFinite
        else { throw RasterError.invalidInput }
        let halo = max(1, Int(ceil(4 * sigma)))
        let margin = 3.5 + CGFloat(halo) / scale
        let output = pathBounds.insetBy(dx: -margin, dy: -margin).intersection(clipBounds)
        guard !output.isNull, !output.isEmpty else { return }
        let limits = [
            floor(output.minX * scale), floor(output.minY * scale),
            ceil(output.maxX * scale), ceil(output.maxY * scale),
        ]
        guard limits.allSatisfy({ $0.isFinite && abs($0) <= 100_000_000 }) else {
            throw RasterError.oversizedSurface
        }
        let key = Key(
            id: id, scale: scale, radius: radius,
            left: Int(limits[0]), top: Int(limits[1]),
            right: Int(limits[2]), bottom: Int(limits[3]))
        let width = key.right - key.left
        let height = key.bottom - key.top
        guard width > 0, height > 0,
            width <= 16_384, height <= 16_384,
            width * height <= 16 * 1_024 * 1_024
        else { throw RasterError.oversizedSurface }
        if let cached = entries[key] {
            cacheHits += 1
            cached.forEach(draw)
            return
        }

        let kernel = gaussianKernel(sigma: sigma, radius: halo)
        var tileSize = tilePixelSize
        // Source/destination include convolution halos. Admission counts their
        // bytes, the packed output image, and vImage's queried temporary space.
        while tileSize > 1 && estimatedScratch(tile: tileSize, halo: halo) > maximumScratchBytes {
            tileSize /= 2
        }
        guard estimatedScratch(tile: tileSize, halo: halo) <= maximumScratchBytes else {
            throw RasterError.scratchLimit
        }
        let outputBytes = width * height
        let shouldCache = entries.count < 128 && outputBytes <= maximumCachedBytes - cachedBytes
        var retained: [Mask] = []
        for top in stride(from: key.top, to: key.bottom, by: tileSize) {
            for left in stride(from: key.left, to: key.right, by: tileSize) {
                let mask = try rasterize(
                    path: path, left: left, top: top,
                    width: min(tileSize, key.right - left),
                    height: min(tileSize, key.bottom - top),
                    halo: halo, scale: scale, kernel: kernel)
                if shouldCache { retained.append(mask) }
                draw(mask)
            }
        }
        if shouldCache {
            entries[key] = retained
            cachedBytes += retained.reduce(0) { $0 + $1.byteCount }
        }
    }

    /// DeviceGray images without alpha are documented CGContext alpha masks:
    /// sample 0 is transparent and sample 255 is fully covered. CGImageMask has
    /// the opposite polarity and is deliberately not used here.
    static func composite(_ mask: Mask, color: CGColor, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .none
        // The caller uses SwiftUI's top-left chart coordinates. Place the
        // upright CGImage in a locally bottom-left coordinate system.
        context.translateBy(x: mask.rect.minX, y: mask.rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: mask.rect.size)
        context.clip(to: local, mask: mask.image)
        context.setFillColor(color)
        context.fill(local)
    }

    private func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }

    private func estimatedScratch(tile: Int, halo: Int) -> Int {
        let side = tile + 2 * halo
        return side * side * 2 + tile * tile
    }

    private func gaussianKernel(sigma: Double, radius: Int) -> [Float] {
        let weights = (-radius...radius).map { offset in
            let normalized = Double(offset) / sigma
            return exp(-0.5 * normalized * normalized)
        }
        let total = weights.reduce(0, +)
        return weights.map { Float($0 / total) }
    }

    private func rasterize(
        path: CGPath, left: Int, top: Int, width: Int, height: Int,
        halo: Int, scale: CGFloat, kernel: [Float]
    ) throws -> Mask {
        let inputWidth = width + 2 * halo
        let inputHeight = height + 2 * halo
        let planeBytes = inputWidth * inputHeight
        let outputBytes = width * height
        let fixedBytes = planeBytes * 2 + outputBytes
        guard fixedBytes <= maximumScratchBytes else { throw RasterError.scratchLimit }
        guard let source = calloc(planeBytes, 1) else { throw RasterError.allocationFailed }
        defer { free(source) }
        guard let destination = calloc(planeBytes, 1) else { throw RasterError.allocationFailed }
        defer { free(destination) }
        guard
            let raster = CGContext(
                data: source, width: inputWidth, height: inputHeight, bitsPerComponent: 8,
                bytesPerRow: inputWidth, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw RasterError.allocationFailed }
        raster.setAllowsAntialiasing(true)
        raster.setShouldAntialias(true)
        raster.translateBy(x: -CGFloat(left - halo), y: CGFloat(top - halo + inputHeight))
        raster.scaleBy(x: scale, y: -scale)
        raster.setStrokeColor(gray: 1, alpha: 1)
        raster.setLineWidth(7)
        raster.setLineCap(.round)
        raster.setLineJoin(.round)
        raster.addPath(path)
        raster.strokePath()

        var sourceBuffer = vImage_Buffer(
            data: source, height: vImagePixelCount(inputHeight),
            width: vImagePixelCount(inputWidth), rowBytes: inputWidth)
        var destinationBuffer = vImage_Buffer(
            data: destination, height: vImagePixelCount(inputHeight),
            width: vImagePixelCount(inputWidth), rowBytes: inputWidth)
        let flags = vImage_Flags(kvImageBackgroundColorFill | kvImageDoNotTile)
        let scratchBytes = kernel.withUnsafeBufferPointer { coefficients in
            vImageSepConvolve_Planar8(
                &sourceBuffer, &destinationBuffer, nil, 0, 0,
                coefficients.baseAddress!, UInt32(coefficients.count),
                coefficients.baseAddress!, UInt32(coefficients.count),
                0, 0, flags | vImage_Flags(kvImageGetTempBufferSize))
        }
        guard scratchBytes >= 0 else { throw RasterError.convolution(Int(scratchBytes)) }
        guard scratchBytes <= maximumScratchBytes - fixedBytes else {
            throw RasterError.scratchLimit
        }
        guard let scratch = malloc(max(1, Int(scratchBytes))) else {
            throw RasterError.allocationFailed
        }
        defer { free(scratch) }
        peakScratchBytes = max(peakScratchBytes, fixedBytes + Int(scratchBytes))
        let error = kernel.withUnsafeBufferPointer { coefficients in
            vImageSepConvolve_Planar8(
                &sourceBuffer, &destinationBuffer, scratch, 0, 0,
                coefficients.baseAddress!, UInt32(coefficients.count),
                coefficients.baseAddress!, UInt32(coefficients.count), 0, 0, flags)
        }
        guard error == kvImageNoError else { throw RasterError.convolution(Int(error)) }

        guard let packed = malloc(outputBytes) else { throw RasterError.allocationFailed }
        var ownsPacked = true
        defer { if ownsPacked { free(packed) } }
        for row in 0..<height {
            memcpy(
                packed.advanced(by: row * width),
                destination.advanced(by: (row + halo) * inputWidth + halo), width)
        }
        guard
            let provider = CGDataProvider(
                dataInfo: nil, data: packed, size: outputBytes,
                releaseData: { _, bytes, _ in free(UnsafeMutableRawPointer(mutating: bytes)) })
        else { throw RasterError.allocationFailed }
        ownsPacked = false
        guard
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw RasterError.allocationFailed }
        rasterizedMasks += 1
        return Mask(
            image: image,
            rect: CGRect(
                x: CGFloat(left) / scale, y: CGFloat(top) / scale,
                width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }
}
