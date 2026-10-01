import AppKit
import CoreGraphics
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class SeriesGlowRasterCacheTests: XCTestCase {
    private typealias Cache = SeriesGlowRasterCache
    private let size = CGSize(width: 160, height: 100)

    func testMasksUseBoundedGrayscaleCoverageAndKeepTheStrokeHalo() throws {
        for scale in [CGFloat(1), 2] {
            let cache = Cache()
            let masks = try masks(cache, path: horizontalPath(), radius: 3, scale: scale)
            XCTAssertFalse(masks.isEmpty)
            for mask in masks {
                XCTAssertFalse(mask.image.isMask)
                XCTAssertEqual(mask.image.colorSpace?.model, .monochrome)
                XCTAssertEqual(mask.image.alphaInfo, .none)
                XCTAssertEqual(mask.image.bitsPerComponent, 8)
                XCTAssertEqual(mask.image.bitsPerPixel, 8)
                XCTAssertEqual(mask.byteCount, mask.image.bytesPerRow * mask.image.height)
                XCTAssertEqual(CGFloat(mask.image.width), mask.rect.width * scale, accuracy: 0.001)
                XCTAssertEqual(
                    CGFloat(mask.image.height), mask.rect.height * scale, accuracy: 0.001)
                XCTAssertEqual(
                    mask.rect.minX * scale, (mask.rect.minX * scale).rounded(), accuracy: 0.001)
                XCTAssertEqual(
                    mask.rect.minY * scale, (mask.rect.minY * scale).rounded(), accuracy: 0.001)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(mask.rect))
            }
            let rendered = try composite(masks, scale: scale)
            XCTAssertGreaterThan(alpha(rendered, x: 80, y: 50, scale: scale), 128)
            XCTAssertGreaterThan(
                alpha(rendered, x: 80, y: 58, scale: scale), 0,
                "The halo must extend beyond the 7-point source stroke")
            XCTAssertEqual(alpha(rendered, x: 80, y: 10, scale: scale), 0)
            XCTAssertLessThanOrEqual(cache.statistics.cachedBytes, 4 * 1_024 * 1_024)
            XCTAssertLessThanOrEqual(cache.statistics.peakScratchBytes, 2 * 1_024 * 1_024)
        }
    }

    func testIdenticalInputsReuseMasksWhileScaleRadiusClipAndIdentityInvalidate() throws {
        let cache = Cache()
        let path = horizontalPath()
        let id = Cache.ID(series: 0, segment: 0)
        let first = try masks(cache, id: id, path: path, radius: 3, scale: 1)
        let initial = cache.statistics
        XCTAssertGreaterThan(initial.rasterizedMasks, 0)
        let repeated = try masks(cache, id: id, path: path, radius: 3, scale: 1)
        XCTAssertEqual(cache.statistics.rasterizedMasks, initial.rasterizedMasks)
        XCTAssertGreaterThan(cache.statistics.cacheHits, initial.cacheHits)
        XCTAssertEqual(first.map(\.rect), repeated.map(\.rect))
        XCTAssertEqual(bytes(try composite(first)), bytes(try composite(repeated)))

        let variations: [(Cache.ID, CGFloat, CGFloat, CGRect)] = [
            (id, 2.5, 1, CGRect(origin: .zero, size: size)),
            (id, 3, 2, CGRect(origin: .zero, size: size)),
            (id, 3, 1, CGRect(x: 20, y: 25, width: 110, height: 50)),
            (Cache.ID(series: 0, segment: 1), 3, 1, CGRect(origin: .zero, size: size)),
            (Cache.ID(series: 1, segment: 0), 3, 1, CGRect(origin: .zero, size: size)),
        ]
        for (identity, radius, scale, clip) in variations {
            let before = cache.statistics.rasterizedMasks
            let result = try masks(
                cache, id: identity, path: path, radius: radius, scale: scale, clip: clip)
            XCTAssertFalse(result.isEmpty)
            XCTAssertGreaterThan(cache.statistics.rasterizedMasks, before)
            let after = cache.statistics.rasterizedMasks
            _ = try masks(cache, id: identity, path: path, radius: radius, scale: scale, clip: clip)
            XCTAssertEqual(cache.statistics.rasterizedMasks, after)
        }
    }

    func testCacheAndScratchBudgetsDoNotDropDrawing() throws {
        let cache = Cache(maximumCachedBytes: 4_096, maximumScratchBytes: 65_536, tilePixelSize: 32)
        var delivered = 0
        for index in 0..<6 {
            let output = try masks(
                cache, id: Cache.ID(series: 0, segment: index), path: curvedPath(), radius: 3,
                scale: 2)
            delivered += output.count
            XCTAssertFalse(output.isEmpty)
            XCTAssertGreaterThan(
                bytes(try composite(output, scale: 2)).filter { $0 > 0 }.count, 100)
            XCTAssertLessThanOrEqual(cache.statistics.cachedBytes, 4_096)
            XCTAssertLessThanOrEqual(cache.statistics.peakScratchBytes, 65_536)
        }
        XCTAssertGreaterThan(
            delivered, 6, "The small surface budget should exercise multiple tiles")
        XCTAssertGreaterThan(cache.statistics.peakScratchBytes, 0)

        let uncached = Cache(maximumCachedBytes: 0, maximumScratchBytes: 65_536, tilePixelSize: 32)
        let first = try masks(uncached, path: curvedPath(), radius: 3, scale: 1)
        let count = uncached.statistics.rasterizedMasks
        let second = try masks(uncached, path: curvedPath(), radius: 3, scale: 1)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(bytes(try composite(first)), bytes(try composite(second)))
        XCTAssertEqual(uncached.statistics.cachedBytes, 0)
        XCTAssertEqual(uncached.statistics.cachedEntries, 0)
        XCTAssertGreaterThan(uncached.statistics.rasterizedMasks, count)
    }

    func testTiledAndUntiledRenderingAgreeAcrossTileSeams() throws {
        let clip = CGRect(x: 7, y: 9, width: 146, height: 82)
        for scale in [CGFloat(1), 2] {
            for radius in [CGFloat(2.5), 3] {
                let tiled = Cache(tilePixelSize: 32)
                let untiled = Cache(tilePixelSize: 512)
                let small = try masks(
                    tiled, path: curvedPath(), radius: radius, scale: scale, clip: clip)
                let large = try masks(
                    untiled, path: curvedPath(), radius: radius, scale: scale, clip: clip)
                XCTAssertGreaterThan(small.count, large.count)
                let actual = bytes(try composite(small, scale: scale))
                let expected = bytes(try composite(large, scale: scale))
                let differences = zip(actual, expected).map { abs(Int($0) - Int($1)) }
                XCTAssertLessThanOrEqual(
                    differences.max() ?? 0, 1,
                    "Tile seams must not change coverage at \(scale)×, radius \(radius)")
                XCTAssertGreaterThan(actual.filter { $0 > 0 }.count, 100)
            }
        }
    }

    func testHandedOffImagesSurviveEvictionScratchReuseAndCacheRelease() throws {
        var cache: Cache? = Cache(maximumCachedBytes: 4_096, tilePixelSize: 32)
        weak var owner = cache
        let retained = try masks(try XCTUnwrap(cache), path: curvedPath(), radius: 3, scale: 1)
        let original = bytes(try composite(retained))
        let historical = try XCTUnwrap(cache).statistics.rasterizedMasks
        cache?.removeAll()
        XCTAssertEqual(cache?.statistics.cachedBytes, 0)
        XCTAssertEqual(cache?.statistics.cachedEntries, 0)
        XCTAssertEqual(cache?.statistics.rasterizedMasks, historical)
        for index in 1...6 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 10, y: 12 + index * 9))
            path.addLine(to: CGPoint(x: 145, y: 22 + index * 7))
            _ = try masks(
                try XCTUnwrap(cache), id: Cache.ID(series: 1, segment: index),
                path: path, radius: 2.5, scale: 1)
        }
        XCTAssertEqual(
            bytes(try composite(retained)), original,
            "Delivered images must own immutable data rather than alias reusable scratch")
        cache = nil
        XCTAssertNil(owner, "A delivered mask must not retain the entire cache")
        XCTAssertEqual(bytes(try composite(retained)), original)
    }

    func testMaskPolarityOrientationAndCompositionStateAtNonzeroOrigin() throws {
        let samples: [UInt8] = [0, 64, 128, 255, 255, 128, 0, 64, 64, 255, 128, 0]
        let image = try grayImage(samples, width: 4, height: 3)
        let mask = Cache.Mask(image: image, rect: CGRect(x: 3, y: 4, width: 4, height: 3))
        let color = try XCTUnwrap(
            CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 0, 0, 0.5]))
        for scale in [CGFloat(1), 2] {
            let actual = try bitmap(
                size: CGSize(width: 14, height: 12), scale: scale, topLeft: true)
            let expected = try bitmap(
                size: CGSize(width: 14, height: 12), scale: scale, topLeft: true)
            for context in [actual, expected] {
                context.translateBy(x: 1, y: 2)
                context.setAlpha(0.5)
            }
            let transform = actual.ctm
            let clipping = actual.boundingBoxOfClipPath
            Cache.composite(mask, color: color, in: actual)
            XCTAssertEqual(actual.ctm, transform)
            XCTAssertEqual(actual.boundingBoxOfClipPath, clipping)
            for row in 0..<3 {
                for column in 0..<4 {
                    let coverage = CGFloat(samples[row * 4 + column]) / 255
                    expected.setFillColor(try XCTUnwrap(color.copy(alpha: coverage * color.alpha)))
                    expected.fill(CGRect(x: 3 + column, y: 4 + row, width: 1, height: 1))
                }
            }
            // A later fill outside the mask also detects leaked clipping/alpha.
            for context in [actual, expected] {
                context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
                context.fill(CGRect(x: 9, y: 1, width: 2, height: 2))
            }
            let actualPixels = bytes(actual)
            let expectedPixels = bytes(expected)
            let differences = zip(actualPixels, expectedPixels).map { abs(Int($0) - Int($1)) }
            let channelMaximums = (0..<4).map { channel in
                stride(from: channel, to: differences.count, by: 4).map { differences[$0] }.max()
                    ?? 0
            }
            let mismatches = stride(from: 0, to: actualPixels.count, by: 4).compactMap {
                offset -> String? in
                let actualPixel = Array(actualPixels[offset..<(offset + 4)])
                let expectedPixel = Array(expectedPixels[offset..<(offset + 4)])
                guard actualPixel != expectedPixel else { return nil }
                return "pixel \(offset / 4): \(actualPixel) vs \(expectedPixel)"
            }
            XCTAssertLessThanOrEqual(
                differences.max() ?? 0, 1,
                "0/64/128/255 coverage must retain polarity, row order and inherited alpha; scale \(scale); max RGBA \(channelMaximums); \(mismatches.prefix(12))"
            )
            XCTAssertGreaterThan(bytes(actual).filter { $0 > 0 }.count, 10)
        }
    }

    func testGaussianGlowMatchesThePreviousSwiftUIBlurAtBothDisplayScales() throws {
        // These are acceptance tolerances, not calibration to the implementation.
        // A different Gaussian mapping should fail with profiles useful for diagnosis.
        for scale in [CGFloat(1), 2] {
            for radius in [CGFloat(2.5), 3] {
                let cases: [(String, CGPath, Color)] = [
                    ("horizontal opaque", horizontalPath(), .white),
                    ("curve opaque", curvedPath(), .white),
                    (
                        "horizontal dark-theme tint", horizontalPath(),
                        Color(red: 0.4, green: 0.88, blue: 1).opacity(0.35)
                    ),
                    (
                        "horizontal light-theme tint", horizontalPath(),
                        Color(red: 0.55, green: 0.33, blue: 0.83).opacity(0.24)
                    ),
                ]
                for (name, path, tint) in cases {
                    let old = try render(size: size, scale: scale) { context, _ in
                        context.drawLayer { glow in
                            glow.addFilter(.blur(radius: radius))
                            glow.stroke(
                                Path(path), with: .color(tint),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                        }
                    }
                    let cache = Cache()
                    let masks = try masks(cache, path: path, radius: radius, scale: scale)
                    let nativeTint = tint.resolve(in: EnvironmentValues()).cgColor
                    let replacement = try render(size: size, scale: scale) { context, _ in
                        context.withCGContext { native in
                            for mask in masks {
                                Cache.composite(mask, color: nativeTint, in: native)
                            }
                        }
                    }
                    assertReferenceMatch(
                        replacement, old, label: "\(name), radius \(radius), scale \(scale)",
                        scale: scale)
                }
            }
        }
    }

    private func assertReferenceMatch(
        _ actual: CGContext, _ expected: CGContext, label: String, scale: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let a = bytes(actual)
        let b = bytes(expected)
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        let alphaPairs = stride(from: 3, to: min(a.count, b.count), by: 4).map {
            (Int(a[$0]), Int(b[$0]))
        }
        let visible = alphaPairs.filter { $0.0 > 1 || $0.1 > 1 }
        let maximum = visible.map { abs($0.0 - $0.1) }.max() ?? 0
        let maximumComponent = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
        let rms = sqrt(
            visible.reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) } / Double(max(visible.count, 1))
        )
        let actualMass = alphaPairs.reduce(0) { $0 + $1.0 }
        let expectedMass = alphaPairs.reduce(0) { $0 + $1.1 }
        let massError = abs(Double(actualMass - expectedMass)) / Double(max(expectedMass, 1))
        let column = min(actual.width - 1, Int(80 * scale))
        let actualProfile = (0..<actual.height).map {
            Int(a[$0 * actual.bytesPerRow + column * 4 + 3])
        }
        let expectedProfile = (0..<expected.height).map {
            Int(b[$0 * expected.bytesPerRow + column * 4 + 3])
        }
        let detail =
            "\(label); maxAlpha=\(maximum), maxRGBA=\(maximumComponent), RMS=\(rms), massError=\(massError); oldColumn=\(expectedProfile); newColumn=\(actualProfile)"
        XCTAssertFalse(visible.isEmpty, detail, file: file, line: line)
        XCTAssertLessThanOrEqual(maximum, 6, detail, file: file, line: line)
        XCTAssertLessThanOrEqual(maximumComponent, 6, detail, file: file, line: line)
        XCTAssertLessThanOrEqual(rms, 1.5, detail, file: file, line: line)
        XCTAssertLessThanOrEqual(massError, 0.02, detail, file: file, line: line)
    }

    private func horizontalPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 30, y: 50))
        path.addLine(to: CGPoint(x: 130, y: 50))
        return path
    }

    private func curvedPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 12.25, y: 75.5))
        path.addCurve(
            to: CGPoint(x: 95.75, y: 24.25),
            control1: CGPoint(x: 36.5, y: 8.25), control2: CGPoint(x: 67.25, y: 93.75))
        path.addLine(to: CGPoint(x: 145.5, y: 79.25))
        return path
    }

    private func masks(
        _ cache: Cache, id: Cache.ID = .init(series: 0, segment: 0), path: CGPath,
        radius: CGFloat, scale: CGFloat, clip: CGRect? = nil
    ) throws -> [Cache.Mask] {
        var result: [Cache.Mask] = []
        try cache.forEachMask(
            id: id, path: path, radius: radius, scale: scale,
            clipBounds: clip ?? CGRect(origin: .zero, size: size)
        ) { result.append($0) }
        return result
    }

    private func composite(_ masks: [Cache.Mask], scale: CGFloat = 1) throws -> CGContext {
        let context = try bitmap(size: size, scale: scale, topLeft: true)
        for mask in masks { Cache.composite(mask, color: CGColor(gray: 1, alpha: 1), in: context) }
        return context
    }

    private func render(
        size: CGSize, scale: CGFloat, drawing: @escaping (inout GraphicsContext, CGSize) -> Void
    ) throws -> CGContext {
        let context = try bitmap(size: size, scale: scale, topLeft: false)
        let renderer = ImageRenderer(
            content: Canvas(renderer: drawing).frame(width: size.width, height: size.height))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        renderer.render(rasterizationScale: scale) { _, draw in draw(context) }
        return context
    }

    private func bitmap(size: CGSize, scale: CGFloat, topLeft: Bool) throws -> CGContext {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        if topLeft {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        return context
    }

    private func grayImage(_ samples: [UInt8], width: Int, height: Int) throws -> CGImage {
        XCTAssertEqual(samples.count, width * height)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(samples) as CFData))
        return try XCTUnwrap(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func bytes(_ context: CGContext) -> [UInt8] {
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: context.bytesPerRow * context.height))
    }

    private func alpha(_ context: CGContext, x: CGFloat, y: CGFloat, scale: CGFloat) -> Int {
        let pixelX = min(context.width - 1, max(0, Int(x * scale)))
        let pixelY = min(context.height - 1, max(0, Int(y * scale)))
        return Int(bytes(context)[pixelY * context.bytesPerRow + pixelX * 4 + 3])
    }
}
