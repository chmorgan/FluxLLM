import Foundation
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class RequestRailTwinkleTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000017")!
    private let rail = CGRect(x: 16, y: 10, width: 128, height: 28)
    private let bar = CGRect(x: 16, y: 18, width: 128, height: 7)

    func testOverlappingGlintsOnOneRequestHaveDistinctStableIdentities() {
        let first = twinkle()
        let overlap = twinkle(start: 0.505, duration: 0.59)
        XCTAssertEqual(first.id, twinkle().id)
        XCTAssertNotEqual(first.id, overlap.id)
        XCTAssertEqual(Set([first.id, overlap.id]).count, 2)
        XCTAssertEqual(first.endsAt, origin.addingTimeInterval(0.5))
        XCTAssertEqual(overlap.endsAt.timeIntervalSince(origin), 1.095, accuracy: 0.000001)
        XCTAssertEqual(first, twinkle())
    }

    func testAppearanceUsesOriginalPhaseAndHasNoPixelsOutsideLifetime() throws {
        let glint = twinkle(duration: 0.5)
        for age in [-1.0, 0, 0.5, 1] {
            XCTAssertNil(glint.appearance(at: origin.addingTimeInterval(age)))
        }
        let quarter = try XCTUnwrap(glint.appearance(at: origin.addingTimeInterval(0.125)))
        XCTAssertEqual(quarter.strength, 0.5, accuracy: 0.000001)
        XCTAssertEqual(quarter.scale, 0.85, accuracy: 0.000001)
        let peak = try XCTUnwrap(glint.appearance(at: origin.addingTimeInterval(0.25)))
        XCTAssertEqual(peak.strength, 1, accuracy: 0.000001)
        XCTAssertEqual(peak.scale, 1, accuracy: 0.000001)
        let falling = try XCTUnwrap(glint.appearance(at: origin.addingTimeInterval(0.375)))
        XCTAssertEqual(falling.strength, quarter.strength, accuracy: 0.000001)
        XCTAssertEqual(falling.scale, quarter.scale, accuracy: 0.000001)
        XCTAssertEqual(glint.appearance(at: origin.addingTimeInterval(0.25)), peak)
        for invalid in [TimeInterval.zero, -1, .infinity, .nan] {
            XCTAssertNil(twinkle(duration: invalid).appearance(at: origin.addingTimeInterval(0.1)))
        }
    }

    func testTimestampLocationReprojectsWithoutChangingIdentityOrPhase() throws {
        let glint = twinkle(location: 15)
        let first = try XCTUnwrap(
            glint.placement(
                segment: segment(), now: origin.addingTimeInterval(30), duration: 30, rail: rail))
        XCTAssertEqual(first.center, CGPoint(x: 80, y: bar.midY))
        XCTAssertEqual(first.bar, bar)
        XCTAssertEqual(first.cornerRadius, 3.5)
        let movedRail = CGRect(x: 8, y: rail.minY, width: 256, height: rail.height)
        let movedBar = CGRect(x: 8, y: bar.minY, width: 256, height: bar.height)
        let resized = try XCTUnwrap(
            glint.placement(
                segment: segment(rect: movedBar), now: origin.addingTimeInterval(30),
                duration: 30, rail: movedRail))
        XCTAssertEqual(resized.center, CGPoint(x: 136, y: bar.midY))
        let later = try XCTUnwrap(
            glint.placement(
                segment: segment(), now: origin.addingTimeInterval(31), duration: 30, rail: rail))
        XCTAssertEqual(later.center.x, rail.minX + 14.0 / 30 * rail.width, accuracy: 0.000001)
        XCTAssertEqual(glint.id, twinkle(location: 15).id)
        XCTAssertEqual(
            glint.appearance(at: origin.addingTimeInterval(0.125)),
            twinkle(location: 15).appearance(at: origin.addingTimeInterval(0.125)))
    }

    func testPlacementRejectsCentersOutsideBarAndInvalidProjection() throws {
        for location in [0.0, 30] {
            XCTAssertNotNil(
                twinkle(location: location).placement(
                    segment: segment(), now: origin.addingTimeInterval(30), duration: 30, rail: rail
                ))
        }
        for location in [-0.01, 30.01] {
            XCTAssertNil(
                twinkle(location: location).placement(
                    segment: segment(), now: origin.addingTimeInterval(30), duration: 30, rail: rail
                ),
                "An overlapping sprite must disappear when its center leaves the bar")
        }
        let glint = twinkle()
        for invalidDuration in [TimeInterval.zero, -1, .nan, .infinity] {
            XCTAssertNil(
                glint.placement(
                    segment: segment(), now: origin, duration: invalidDuration, rail: rail))
        }
        for invalid in [
            CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 7),
            CGRect(x: CGFloat.nan, y: 0, width: 10, height: 7),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 7),
        ] {
            XCTAssertNil(
                glint.placement(
                    segment: segment(), now: origin, duration: 30, rail: invalid))
            XCTAssertNil(
                glint.placement(
                    segment: segment(rect: invalid), now: origin, duration: 30, rail: rail))
        }
        let shortBar = CGRect(x: 70, y: 18, width: 2, height: 7)
        let short = try XCTUnwrap(
            twinkle(location: (71 - 16) / 128 * 30).placement(
                segment: segment(rect: shortBar), now: origin.addingTimeInterval(30),
                duration: 30, rail: rail))
        XCTAssertEqual(short.cornerRadius, 1)
    }

    func testCanvasPixelsMatchIndependentLegacyEquationsAtBothScales() throws {
        let size = CGSize(width: 160, height: 48)
        let now = origin.addingTimeInterval(30)
        let color = Color(red: 0.12, green: 0.62, blue: 0.91)
        for scale in [CGFloat(1), 2] {
            for star in [false, true] {
                for location in [0.05, 15, 29.95] {
                    let glint = twinkle(location: location, star: star)
                    for age in [0.001, 0.125, 0.25, 0.499] {
                        let timestamp = origin.addingTimeInterval(age)
                        let actual = try render(size: size, scale: scale) { context, _ in
                            glint.draw(
                                segment: self.segment(), now: now, duration: 30, rail: self.rail,
                                timestamp: timestamp, color: color, in: &context)
                        }
                        let expected = try render(size: size, scale: scale) { context, _ in
                            self.legacyDraw(
                                glint, at: timestamp, now: now, color: color, in: &context)
                        }
                        XCTAssertEqual(actual.count, expected.count)
                        let differingBytes = zip(actual, expected).reduce(0) { count, pair in
                            count + (pair.0 == pair.1 ? 0 : 1)
                        }
                        XCTAssertEqual(
                            differingBytes, 0,
                            "Legacy pixels differ: scale=\(scale), star=\(star), location=\(location), age=\(age)"
                        )
                        if age == 0.25 {
                            XCTAssertTrue(
                                actual.contains { $0 > 0 }, "Peak twinkles must draw visible pixels"
                            )
                        }
                    }
                }
            }
        }
    }

    private func twinkle(
        start: TimeInterval = 0, duration: TimeInterval = 0.5,
        location: TimeInterval = 15, star: Bool = true
    ) -> RequestRailTwinkle {
        RequestRailTwinkle(
            requestID: requestID, startedAt: origin.addingTimeInterval(start), duration: duration,
            location: origin.addingTimeInterval(location), size: 3.1, angle: 0.47, star: star)
    }

    private func segment(rect: CGRect? = nil) -> RequestRailGeometry.Segment {
        RequestRailGeometry.Segment(
            lane: RequestLane(id: requestID, startedAt: origin, endedAt: nil),
            rect: rect ?? bar, isLive: true, track: 0)
    }

    /// Intentionally independent of placement, appearance and markPath: this is
    /// the pre-extraction Canvas algorithm, including clipping and blend order.
    private func legacyDraw(
        _ twinkle: RequestRailTwinkle, at timestamp: Date, now: Date, color: Color,
        in context: inout GraphicsContext
    ) {
        let p = timestamp.timeIntervalSince(twinkle.startedAt) / twinkle.duration
        guard p > 0, p < 1 else { return }
        let strength = pow(sin(.pi * p), 2)
        let size = CGFloat(twinkle.size * (0.7 + 0.3 * strength))
        let x =
            rail.minX + twinkle.location.timeIntervalSince(now.addingTimeInterval(-30)) / 30
            * rail.width
        guard x >= bar.minX, x <= bar.maxX else { return }
        let point = CGPoint(x: x, y: bar.midY)
        var clipped = context
        clipped.clip(to: Path(roundedRect: bar, cornerRadius: 3.5, style: .circular))
        clipped.fill(
            Path(
                ellipseIn: CGRect(
                    x: point.x - size * 2.1, y: bar.minY, width: size * 4.2, height: bar.height)),
            with: .color(color.opacity(strength * 0.32)))
        let mark: Path
        if twinkle.star {
            let inset = size * 0.24
            var path = Path()
            path.move(to: CGPoint(x: 0, y: -size))
            path.addQuadCurve(to: CGPoint(x: size, y: 0), control: CGPoint(x: inset, y: -inset))
            path.addQuadCurve(to: CGPoint(x: 0, y: size), control: CGPoint(x: inset, y: inset))
            path.addQuadCurve(to: CGPoint(x: -size, y: 0), control: CGPoint(x: -inset, y: inset))
            path.addQuadCurve(to: CGPoint(x: 0, y: -size), control: CGPoint(x: -inset, y: -inset))
            path.closeSubpath()
            mark = path.applying(
                CGAffineTransform(rotationAngle: twinkle.angle).concatenating(
                    CGAffineTransform(translationX: point.x, y: point.y)))
        } else {
            let radius = size * 0.56
            mark = Path(
                ellipseIn: CGRect(
                    x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            )
        }
        clipped.fill(mark, with: .color(.white.opacity(strength)))
    }

    private func render(
        size: CGSize, scale: CGFloat, drawing: @escaping (inout GraphicsContext, CGSize) -> Void
    ) throws -> [UInt8] {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        func bitmap() throws -> CGContext {
            let context = try XCTUnwrap(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue))
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            return context
        }
        var environment = EnvironmentValues()
        environment.displayScale = scale
        environment.colorScheme = .dark
        let context = try bitmap()
        let renderer = ImageRenderer(
            content: Canvas(renderer: drawing).environment(\.self, environment))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        renderer.render(rasterizationScale: scale) { _, render in render(context) }
        let image = try XCTUnwrap(context.makeImage())
        let normalized = try bitmap()
        normalized.draw(image, in: CGRect(origin: .zero, size: size))
        let bytes = try XCTUnwrap(normalized.data?.assumingMemoryBound(to: UInt8.self))
        return Array(UnsafeBufferPointer(start: bytes, count: normalized.bytesPerRow * height))
    }
}
