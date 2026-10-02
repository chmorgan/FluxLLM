import Foundation
import SwiftUI

/// One prepared glint. Its timestamp location and identity survive chart updates;
/// the owner decides when visibility and accessibility permit presentation.
struct RequestRailTwinkle: Equatable, Identifiable {
    struct ID: Hashable {
        let requestID: UUID
        let startedAt: Date
    }

    struct Placement: Equatable {
        let center: CGPoint
        let bar: CGRect
        let cornerRadius: CGFloat
    }

    struct Appearance: Equatable {
        let strength: Double
        let scale: CGFloat
    }

    let requestID: UUID
    let startedAt: Date
    let duration: TimeInterval
    let location: Date
    let size: Double
    let angle: Double
    let star: Bool

    var id: ID { ID(requestID: requestID, startedAt: startedAt) }
    var endsAt: Date { startedAt.addingTimeInterval(duration) }

    func placement(
        segment: RequestRailGeometry.Segment, now: Date, duration: TimeInterval, rail: CGRect
    ) -> Placement? {
        let bar = segment.rect
        guard Self.valid(rail), Self.valid(bar), duration.isFinite, duration > 0,
            now.timeIntervalSinceReferenceDate.isFinite,
            location.timeIntervalSinceReferenceDate.isFinite
        else { return nil }
        let x =
            rail.minX
            + location.timeIntervalSince(now.addingTimeInterval(-duration)) / duration * rail.width
        // The original drawing omits a glint whose center has left its request,
        // even if part of its sprite would still overlap the bar's clip.
        guard x.isFinite, x >= bar.minX, x <= bar.maxX else { return nil }
        return Placement(
            center: CGPoint(x: x, y: bar.midY), bar: bar, cornerRadius: segment.cornerRadius)
    }

    func appearance(at timestamp: Date) -> Appearance? {
        guard duration.isFinite, duration > 0 else { return nil }
        let p = timestamp.timeIntervalSince(startedAt) / duration
        guard p > 0, p < 1 else { return nil }
        let strength = pow(sin(.pi * p), 2)
        return Appearance(strength: strength, scale: CGFloat(0.7 + 0.3 * strength))
    }

    func markPath(at point: CGPoint, scale: CGFloat = 1) -> Path {
        guard point.x.isFinite, point.y.isFinite, size.isFinite, size > 0,
            angle.isFinite, scale.isFinite, scale > 0
        else { return Path() }
        let size = CGFloat(self.size) * scale
        if !star {
            let radius = size * 0.56
            return Path(
                ellipseIn: CGRect(
                    x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            )
        }
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

    func draw(
        segment: RequestRailGeometry.Segment, now: Date, duration: TimeInterval, rail: CGRect,
        timestamp: Date, color: Color, in context: inout GraphicsContext
    ) {
        guard let placement = placement(segment: segment, now: now, duration: duration, rail: rail),
            let appearance = appearance(at: timestamp), size.isFinite, size > 0, angle.isFinite
        else { return }
        let size = CGFloat(self.size) * appearance.scale
        var clipped = context
        clipped.clip(
            to: Path(
                roundedRect: placement.bar, cornerRadius: placement.cornerRadius, style: .circular))
        clipped.fill(
            Path(
                ellipseIn: CGRect(
                    x: placement.center.x - size * 2.1, y: placement.bar.minY,
                    width: size * 4.2, height: placement.bar.height)),
            with: .color(color.opacity(appearance.strength * 0.32)))
        clipped.fill(
            markPath(at: placement.center, scale: appearance.scale),
            with: .color(.white.opacity(appearance.strength)))
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
