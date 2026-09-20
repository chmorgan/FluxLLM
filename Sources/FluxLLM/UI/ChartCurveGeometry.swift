import Foundation

/// Monotone cubic geometry for rate histories. Each span stays within its two
/// readings, so smoothing cannot invent negative rates, peaks, or activity on a
/// zero plateau. Equal timestamps remain exact vertical transitions.
enum ChartCurveGeometry {
    struct Span: Equatable {
        let start: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint

        var isVertical: Bool { start.x == end.x }

        func value(at fraction: CGFloat) -> CGFloat {
            let position = min(max(fraction, 0), 1)
            let inverse = 1 - position
            return inverse * inverse * inverse * start.y
                + 3 * inverse * inverse * position * control1.y
                + 3 * inverse * position * position * control2.y
                + position * position * position * end.y
        }
    }

    static func spans(points: [CGPoint]) -> [Span] {
        var coordinates: [CGPoint] = []
        for point in points where point.x.isFinite && point.y.isFinite {
            guard coordinates.last.map({ point.x >= $0.x }) ?? true else { continue }
            if coordinates.last != point { coordinates.append(point) }
        }
        guard coordinates.count > 1 else { return [] }

        let slopes: [CGFloat?] = zip(coordinates, coordinates.dropFirst()).map { first, last in
            let width = last.x - first.x
            guard width > 0 else { return nil }
            let slope = (last.y - first.y) / width
            return slope.isFinite ? slope : nil
        }
        var tangents = coordinates.indices.map { index -> CGFloat in
            let left = index > 0 ? slopes[index - 1] : nil
            let right = index < slopes.count ? slopes[index] : nil
            // A repeated x is a discontinuous step, not a slope to smooth across.
            if index > 0 && left == nil || index < slopes.count && right == nil { return 0 }
            guard let left else { return right ?? 0 }
            guard let right else { return left }
            guard left != 0, right != 0, (left > 0) == (right > 0) else { return 0 }
            return left / 2 + right / 2
        }
        for index in slopes.indices {
            guard let slope = slopes[index], slope != 0 else {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let firstRatio = max(tangents[index] / slope, 0)
            let lastRatio = max(tangents[index + 1] / slope, 0)
            let length = hypot(firstRatio, lastRatio)
            if !length.isFinite {
                tangents[index] = 0
                tangents[index + 1] = 0
            } else if length > 3 {
                tangents[index] = 3 * (firstRatio / length) * slope
                tangents[index + 1] = 3 * (lastRatio / length) * slope
            }
        }

        return slopes.indices.map { index in
            let start = coordinates[index]
            let end = coordinates[index + 1]
            let third = (end.x - start.x) / 3
            let lower = min(start.y, end.y)
            let upper = max(start.y, end.y)
            let firstValue = start.y + tangents[index] * third
            let lastValue = end.y - tangents[index + 1] * third
            return Span(
                start: start,
                control1: CGPoint(x: start.x + third, y: min(max(firstValue, lower), upper)),
                control2: CGPoint(x: end.x - third, y: min(max(lastValue, lower), upper)),
                end: end)
        }
    }

    /// Shared hover markers follow the rendered curve rather than a nearby bin.
    /// At a vertical transition the newer value takes precedence.
    static func value(atX x: CGFloat, spans: [Span]) -> CGFloat? {
        guard x.isFinite,
            let span = spans.last(where: { $0.start.x <= x && x <= $0.end.x })
        else { return nil }
        guard !span.isVertical else { return span.end.y }
        return span.value(at: (x - span.start.x) / (span.end.x - span.start.x))
    }

    /// The tool track consists of exact horizontal bins with vertical edges.
    /// At a shared edge, the new bin is the one visible to its right.
    static func stepValue(atX x: CGFloat, points: [CGPoint]) -> CGFloat? {
        guard x.isFinite, let first = points.first, let last = points.last,
            first.x <= x, x <= last.x
        else { return nil }
        return points.last(where: { $0.x <= x })?.y
    }
}
