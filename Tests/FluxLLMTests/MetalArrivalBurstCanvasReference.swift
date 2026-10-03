import CoreGraphics
import Foundation
import SwiftUI
import XCTest

@testable import FluxLLM

/// The original Canvas arrival effect, kept independent of the Metal renderer's
/// primitive construction, shading, timing helpers, and coordinate conversion.
@MainActor
enum MetalArrivalBurstCanvasReference {
    struct Burst {
        let profile: RequestRailEffectProfile
        let age: TimeInterval
        let center: CGPoint
        let color: Color
    }

    struct Twinkle {
        let twinkle: RequestRailTwinkle
        let placement: RequestRailTwinkle.Placement
        let age: TimeInterval
        let color: Color
    }

    enum Element {
        case burst(Burst)
        case twinkle(Twinkle)
    }

    static func render(
        _ bursts: [Burst], size: CGSize, scale: CGFloat, background: Color? = nil
    ) throws -> CGContext {
        try render(
            elements: bursts.map { .burst($0) }, size: size, scale: scale, background: background)
    }

    static func render(
        elements: [Element], size: CGSize, scale: CGFloat, background: Color? = nil
    ) throws -> CGContext {
        let context = try bitmap(size: size, scale: scale)
        let renderer = ImageRenderer(
            content: Canvas { graphics, _ in
                if let background {
                    graphics.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
                }
                for element in elements {
                    switch element {
                    case .burst(let burst):
                        drawBurst(
                            burst.profile, age: burst.age, duration: burst.profile.burstDuration,
                            scale: 1, at: burst.center, color: burst.color, in: &graphics)
                    case .twinkle(let twinkle):
                        drawTwinkle(twinkle, in: &graphics)
                    }
                }
            })
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        renderer.render(rasterizationScale: scale) { _, draw in draw(context) }
        return context
    }

    /// Coordinates are in Canvas's logical coordinate space. Bitmap rows retain
    /// ImageRenderer's native orientation; this oracle performs no readback flip.
    static func renderCalibration(size: CGSize, scale: CGFloat) throws -> CGContext {
        let context = try bitmap(size: size, scale: scale)
        let renderer = ImageRenderer(
            content: Canvas { graphics, _ in
                graphics.fill(
                    Path(CGRect(x: 7, y: 11, width: 9, height: 13)),
                    with: .color(Color(.sRGB, red: 1, green: 0, blue: 0)))
                graphics.fill(
                    Path(CGRect(x: 75, y: 61, width: 11, height: 9)),
                    with: .color(Color(.sRGB, red: 0, green: 0, blue: 1)))
                graphics.fill(
                    Path(CGRect(x: 39, y: 27, width: 15, height: 11)),
                    with: .color(Color(.sRGB, red: 0.1, green: 0.7, blue: 0.3, opacity: 0.5)))
            })
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        renderer.render(rasterizationScale: scale) { _, draw in draw(context) }
        return context
    }

    private static func bitmap(size: CGSize, scale: CGFloat) throws -> CGContext {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        return context
    }

    // Copies of the pre-optimization RequestRailEffectProfile timing formulas.
    // Do not share these helpers with the implementation under test.
    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    private static func envelope(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return 0 }
        let fade = clamp((p - 0.1) / 0.9)
        return min(1, p / 0.04) * (1 - fade) * (1 - fade) * (1 + 2 * fade)
    }

    // Intentionally retains every original drawBurst operation and its order.
    private static func drawBurst(
        _ profile: RequestRailEffectProfile, age: TimeInterval, duration: TimeInterval,
        scale: Double, at point: CGPoint, color: Color, in context: inout GraphicsContext
    ) {
        let p = age / duration
        guard p > 0, p < 1 else { return }
        let strength = envelope(p)
        let expansion = 1 - pow(1 - p, 3)
        let size = profile.size * scale
        let halo: Double = profile.family == .fireflies ? 20 : profile.family == .arcs ? 18 : 14
        var glow = context
        glow.translateBy(x: point.x, y: point.y)
        glow.rotate(by: .radians(profile.angle))
        glow.scaleBy(x: 1, y: 0.76)
        drawGlow(
            at: .zero, radius: (9 + halo * expansion) * size, strength: strength * 0.92,
            color: color, in: &glow)

        if profile.family == .arcs {
            for index in 0..<3 {
                let radius = (7 + 12 * expansion + Double(index) * 1.6) * size
                let angle = profile.angle + Double(index) * 2.2
                var arc = Path()
                arc.addArc(
                    center: point, radius: radius, startAngle: .radians(angle),
                    endAngle: .radians(angle + 0.4 + profile.particles[index].stretch * 0.48),
                    clockwise: false)
                context.stroke(
                    arc, with: .color(color.opacity(strength)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        } else {
            for particle in profile.particles {
                let q = clamp((p - particle.delay) / particle.life)
                let brightness = envelope(q) * 0.92
                guard brightness > 0 else { continue }
                let travel = 1 - pow(1 - q, 2)
                let distance = (4 + particle.distance * travel) * size
                let position = CGPoint(
                    x: point.x + cos(particle.angle) * distance,
                    y: point.y + sin(particle.angle) * distance)
                if profile.family == .fireflies {
                    drawGlow(
                        at: position, radius: particle.size * 3, strength: brightness * 0.8,
                        color: color, in: &context)
                    context.fill(
                        circle(at: position, radius: particle.size * (1 - 0.4 * q)),
                        with: .color(.white.opacity(brightness)))
                } else {
                    let length = particle.length * (1 - 0.5 * q)
                    var spark = Path()
                    spark.move(to: position)
                    spark.addLine(
                        to: CGPoint(
                            x: position.x + cos(particle.angle) * length,
                            y: position.y + sin(particle.angle) * length))
                    context.stroke(
                        spark, with: .color(.white.opacity(brightness)),
                        style: StrokeStyle(lineWidth: particle.size * 0.75, lineCap: .round))
                }
            }
        }
        drawGlow(at: point, radius: 8 * size, strength: strength, color: color, in: &context)
        let core =
            profile.family == .fireflies
            ? circle(at: point, radius: (2 + 1.3 * strength) * size)
            : star(at: point, size: (4.5 + 3.5 * strength) * size, angle: profile.angle)
        context.fill(core, with: .color(.white.opacity(strength)))
    }

    /// Independent copy of the original glint drawing, including its own timing,
    /// shape construction, and clip. The prepared twinkle supplies only data.
    private static func drawTwinkle(_ fixture: Twinkle, in context: inout GraphicsContext) {
        let twinkle = fixture.twinkle
        let placement = fixture.placement
        guard twinkle.duration.isFinite, twinkle.duration > 0,
            twinkle.size.isFinite, twinkle.size > 0, twinkle.angle.isFinite
        else { return }
        let p = fixture.age / twinkle.duration
        guard p > 0, p < 1 else { return }
        let strength = pow(sin(.pi * p), 2)
        let scale = CGFloat(0.7 + 0.3 * strength)
        let size = CGFloat(twinkle.size) * scale
        var clipped = context
        clipped.clip(
            to: Path(
                roundedRect: placement.bar, cornerRadius: placement.cornerRadius, style: .circular))
        clipped.fill(
            Path(
                ellipseIn: CGRect(
                    x: placement.center.x - size * 2.1, y: placement.bar.minY,
                    width: size * 4.2, height: placement.bar.height)),
            with: .color(fixture.color.opacity(strength * 0.32)))
        let mark =
            twinkle.star
            ? star(at: placement.center, size: size, angle: twinkle.angle)
            : circle(at: placement.center, radius: size * 0.56)
        clipped.fill(mark, with: .color(.white.opacity(strength)))
    }

    private static func drawGlow(
        at point: CGPoint, radius: CGFloat, strength: Double, color: Color,
        in context: inout GraphicsContext
    ) {
        context.fill(
            circle(at: point, radius: radius),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(strength), location: 0),
                    .init(color: .white.opacity(strength), location: 0.18),
                    .init(color: color.opacity(strength * 0.95), location: 0.4),
                    .init(color: color.opacity(0), location: 1),
                ]), center: point, startRadius: 0, endRadius: radius))
    }

    private static func circle(at point: CGPoint, radius: CGFloat) -> Path {
        Path(
            ellipseIn: CGRect(
                x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func star(at point: CGPoint, size: CGFloat, angle: Double) -> Path {
        let inset = size * 0.24
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -size))
        path.addQuadCurve(to: CGPoint(x: size, y: 0), control: CGPoint(x: inset, y: -inset))
        path.addQuadCurve(to: CGPoint(x: 0, y: size), control: CGPoint(x: inset, y: inset))
        path.addQuadCurve(to: CGPoint(x: -size, y: 0), control: CGPoint(x: -inset, y: inset))
        path.addQuadCurve(to: CGPoint(x: 0, y: -size), control: CGPoint(x: -inset, y: -inset))
        path.closeSubpath()
        return path.applying(
            CGAffineTransform(rotationAngle: angle).concatenating(
                CGAffineTransform(translationX: point.x, y: point.y)))
    }
}
