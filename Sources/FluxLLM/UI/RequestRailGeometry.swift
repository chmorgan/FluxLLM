import CoreGraphics
import Foundation

/// Timestamp geometry for the fixed request tracks. Assignment owns reuse;
/// this projection never moves a request or stretches its lifetime to a pixel.
enum RequestRailGeometry {
    static let barHeight: CGFloat = 7
    static let trackPitch: CGFloat = 14
    static let bandHeight: CGFloat = 84

    struct Segment: Sendable, Equatable {
        let lane: RequestLane
        let rect: CGRect
        let isLive: Bool
        let track: Int

        var cornerRadius: CGFloat { min(rect.width, rect.height) / 2 }
    }

    struct OverflowSegment: Sendable, Equatable {
        let rect: CGRect
        /// Requests in the overflow tracks during this exact time interval.
        let count: Int
    }

    static func layout(
        lanes: [RequestLane], assignments: [UUID: RequestRailAssignment],
        now: Date, duration: TimeInterval, rect: CGRect
    ) -> [Segment] {
        guard validProjection(duration: duration, rect: rect) else { return [] }
        let cutoff = now.addingTimeInterval(-duration)
        return lanes.compactMap { lane in
            guard let assignment = assignments[lane.id],
                (0..<RequestRailState.individualTrackCount).contains(assignment.track),
                let interval = visibleInterval(lane, cutoff: cutoff, now: now)
            else { return nil }
            return Segment(
                lane: lane,
                rect: project(
                    interval, track: assignment.track, cutoff: cutoff,
                    duration: duration, rect: rect),
                isLive: lane.endedAt == nil, track: assignment.track)
        }
    }

    /// Hidden requests share the sixth track. Counts follow half-open request
    /// intervals, so a finish and a reuse at the same instant do not double count.
    static func overflow(
        lanes: [RequestLane], assignments: [UUID: RequestRailAssignment],
        now: Date, duration: TimeInterval, rect: CGRect
    ) -> [OverflowSegment] {
        guard validProjection(duration: duration, rect: rect) else { return [] }
        let cutoff = now.addingTimeInterval(-duration)
        var changes: [Date: Int] = [:]
        for lane in lanes {
            guard let assignment = assignments[lane.id],
                assignment.track >= RequestRailState.overflowTrack,
                let interval = visibleInterval(lane, cutoff: cutoff, now: now)
            else { continue }
            changes[interval.lowerBound, default: 0] += 1
            changes[interval.upperBound, default: 0] -= 1
        }

        var spans: [(interval: Range<Date>, count: Int)] = []
        var count = 0
        var previous: Date?
        for boundary in changes.keys.sorted() {
            if let previous, previous < boundary, count > 0 {
                if let last = spans.last, last.count == count,
                    last.interval.upperBound == previous
                {
                    spans[spans.count - 1].interval = last.interval.lowerBound..<boundary
                } else {
                    spans.append((previous..<boundary, count))
                }
            }
            count += changes[boundary, default: 0]
            previous = boundary
        }
        return spans.map {
            OverflowSegment(
                rect: project(
                    $0.interval, track: RequestRailState.overflowTrack, cutoff: cutoff,
                    duration: duration, rect: rect), count: $0.count)
        }
    }

    private static func visibleInterval(
        _ lane: RequestLane, cutoff: Date, now: Date
    ) -> Range<Date>? {
        let start = max(lane.startedAt, cutoff)
        let end = min(lane.endedAt ?? now, now)
        guard start.timeIntervalSinceReferenceDate.isFinite,
            end.timeIntervalSinceReferenceDate.isFinite, start < end
        else { return nil }
        return start..<end
    }

    private static func validProjection(duration: TimeInterval, rect: CGRect) -> Bool {
        duration.isFinite && duration > 0 && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    private static func project(
        _ interval: Range<Date>, track: Int, cutoff: Date,
        duration: TimeInterval, rect: CGRect
    ) -> CGRect {
        let left =
            rect.minX + CGFloat(interval.lowerBound.timeIntervalSince(cutoff) / duration)
            * rect.width
        let right =
            rect.minX + CGFloat(interval.upperBound.timeIntervalSince(cutoff) / duration)
            * rect.width
        return CGRect(
            x: left, y: rect.minY + CGFloat(track) * trackPitch + (trackPitch - barHeight) / 2,
            width: right - left, height: barHeight)
    }
}

/// Arc-length parameterization of the same rounded rectangle used by the bar.
/// Zero is its rightmost midpoint. Positive distance travels clockwise in chart
/// coordinates; negative distances and repeated circuits wrap continuously.
struct RequestRailPerimeter: Sendable {
    let length: CGFloat
    private let origin: CGPoint
    private let pieces: [Piece]

    private enum Shape: Sendable {
        case line(CGPoint, CGPoint)
        case arc(center: CGPoint, angle: CGFloat, radius: CGFloat)
    }

    private struct Piece: Sendable {
        let offset: CGFloat
        let length: CGFloat
        let shape: Shape
    }

    init(rect input: CGRect) {
        let rect = input.standardized
        guard rect.minX.isFinite, rect.minY.isFinite,
            rect.width.isFinite, rect.height.isFinite
        else {
            origin = .zero
            length = 0
            pieces = []
            return
        }
        let radius = min(rect.width, rect.height) / 2
        let start = CGPoint(x: rect.maxX, y: rect.midY)
        origin = start
        var cursor = start
        var result: [Piece] = []
        var total: CGFloat = 0

        func line(to end: CGPoint) {
            let size = hypot(end.x - cursor.x, end.y - cursor.y)
            if size > 0 {
                result.append(Piece(offset: total, length: size, shape: .line(cursor, end)))
            }
            total += size
            cursor = end
        }

        func arc(center: CGPoint, angle: CGFloat) {
            let size = .pi * radius / 2
            if size > 0 {
                result.append(
                    Piece(
                        offset: total, length: size,
                        shape: .arc(center: center, angle: angle, radius: radius)))
            }
            total += size
            cursor = CGPoint(
                x: center.x + radius * cos(angle + .pi / 2),
                y: center.y + radius * sin(angle + .pi / 2))
        }

        line(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        arc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), angle: 0)
        line(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        arc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), angle: .pi / 2)
        line(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        arc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), angle: .pi)
        line(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        arc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), angle: .pi * 1.5)
        line(to: start)
        length = total
        pieces = result
    }

    func point(at distance: CGFloat) -> CGPoint {
        guard length > 0, distance.isFinite else { return origin }
        let distance = (distance.truncatingRemainder(dividingBy: length) + length)
            .truncatingRemainder(dividingBy: length)
        guard let piece = pieces.first(where: { distance < $0.offset + $0.length }) ?? pieces.last
        else { return origin }
        let progress = min(1, max(0, (distance - piece.offset) / piece.length))
        switch piece.shape {
        case .line(let start, let end):
            return CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress)
        case .arc(let center, let angle, let radius):
            let angle = angle + progress * .pi / 2
            return CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle))
        }
    }
}
