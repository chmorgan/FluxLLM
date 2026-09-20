import CoreGraphics
import Foundation

enum ChartInspectionTarget: Equatable {
    case plot
    case request(UUID)
    case overflow
    case tools
}

struct ChartInspectionSelection: Equatable {
    let timestamp: Date
    let target: ChartInspectionTarget
}

/// Hit testing follows the same timestamp projection and reusable tracks as the chart.
enum ChartInspectionGeometry {
    static func selection(
        at location: CGPoint, now: Date, duration: TimeInterval,
        main: CGRect, rails: CGRect, tools: CGRect, lanes: [RequestLane],
        assignments: [UUID: RequestRailAssignment]
    ) -> ChartInspectionSelection? {
        guard location.x.isFinite, location.y.isFinite,
            now.timeIntervalSinceReferenceDate.isFinite,
            duration.isFinite, duration > 0,
            now.addingTimeInterval(-duration).timeIntervalSinceReferenceDate.isFinite
        else { return nil }

        if contains(location, in: main) {
            return ChartInspectionSelection(
                timestamp: timestamp(at: location.x, in: main, now: now, duration: duration),
                target: .plot)
        }
        if contains(location, in: tools) {
            return ChartInspectionSelection(
                timestamp: timestamp(at: location.x, in: tools, now: now, duration: duration),
                target: .tools)
        }
        guard contains(location, in: rails) else { return nil }
        let verticalOffset = location.y - rails.minY
        guard
            verticalOffset < CGFloat(RequestRailState.overflowTrack + 1)
                * RequestRailGeometry.trackPitch
        else { return nil }
        let track = Int(verticalOffset / RequestRailGeometry.trackPitch)
        let time = timestamp(at: location.x, in: rails, now: now, duration: duration)
        let active = activeLanes(at: time, now: now, lanes: lanes)
        if track == RequestRailState.overflowTrack {
            guard
                active.contains(where: {
                    (assignments[$0.id]?.track ?? -1) >= RequestRailState.overflowTrack
                })
            else { return nil }
            return ChartInspectionSelection(timestamp: time, target: .overflow)
        }
        // The entire 14-point stripe is a forgiving target for its 7-point bar.
        // Selecting the latest start also makes malformed overlapping assignments deterministic.
        let request = active.filter { assignments[$0.id]?.track == track }.max {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard let request else { return nil }
        return ChartInspectionSelection(timestamp: time, target: .request(request.id))
    }

    static func activeLanes(
        at timestamp: Date, now: Date, lanes: [RequestLane]
    ) -> [RequestLane] {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite,
            now.timeIntervalSinceReferenceDate.isFinite, timestamp <= now
        else { return [] }
        return lanes.filter { lane in
            guard lane.startedAt.timeIntervalSinceReferenceDate.isFinite,
                lane.startedAt <= timestamp
            else { return false }
            guard let end = lane.endedAt else { return true }
            return end.timeIntervalSinceReferenceDate.isFinite
                && end > lane.startedAt && timestamp < end
        }
    }

    /// Keeps a fitting card inside the visible bounds, preferring a quadrant with
    /// ten points of pointer clearance. Callers must constrain oversized card content;
    /// an oversized dimension is anchored at the corresponding bounds origin.
    static func cardOrigin(pointer: CGPoint, cardSize: CGSize, bounds: CGRect) -> CGPoint {
        let fallback = CGPoint(
            x: bounds.origin.x.isFinite ? bounds.origin.x : 0,
            y: bounds.origin.y.isFinite ? bounds.origin.y : 0)
        guard valid(bounds), pointer.x.isFinite, pointer.y.isFinite,
            cardSize.width.isFinite, cardSize.height.isFinite,
            cardSize.width >= 0, cardSize.height >= 0
        else { return fallback }
        let gap: CGFloat = 10
        let right = pointer.x + gap
        let left = pointer.x - gap - cardSize.width
        let above = pointer.y - gap - cardSize.height
        let below = pointer.y + gap
        let candidates = [
            CGPoint(x: right, y: above), CGPoint(x: left, y: above),
            CGPoint(x: right, y: below), CGPoint(x: left, y: below),
        ]
        let maxX = max(bounds.minX, bounds.maxX - cardSize.width)
        let maxY = max(bounds.minY, bounds.maxY - cardSize.height)
        func clamped(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(maxX, max(bounds.minX, point.x)),
                y: min(maxY, max(bounds.minY, point.y)))
        }
        if let fitting = candidates.first(where: { clamped($0) == $0 }) { return fitting }

        // When no quadrant fits, retain the largest available distance from the pointer.
        var best = clamped(candidates[0])
        var bestDistance = clearance(pointer, origin: best, size: cardSize)
        for candidate in candidates.dropFirst().map(clamped) {
            let distance = clearance(pointer, origin: candidate, size: cardSize)
            if distance > bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }

    private static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        valid(rect) && point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y < rect.maxY
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }

    private static func timestamp(
        at x: CGFloat, in rect: CGRect, now: Date, duration: TimeInterval
    ) -> Date {
        let fraction = min(1, max(0, Double((x - rect.minX) / rect.width)))
        return now.addingTimeInterval((fraction - 1) * duration)
    }

    private static func clearance(_ point: CGPoint, origin: CGPoint, size: CGSize) -> CGFloat {
        let dx = max(origin.x - point.x, max(0, point.x - origin.x - size.width))
        let dy = max(origin.y - point.y, max(0, point.y - origin.y - size.height))
        return hypot(dx, dy)
    }
}
