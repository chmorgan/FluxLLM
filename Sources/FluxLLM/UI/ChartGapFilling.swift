import Foundation

/// Joins measured drawing paths with a zero baseline without creating observations.
enum ChartGapFilling {
    static func plotSegments(
        _ segments: [[ChartDisplayPoint]], cutoff: Date, now: Date, extendsCurrentToNow: Bool
    ) -> [[ChartDisplayPoint]] {
        guard cutoff.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
            cutoff < now
        else { return [] }

        var points = [ChartDisplayPoint(timestamp: cutoff, value: 0)]
        func append(_ point: ChartDisplayPoint) {
            if points.last != point { points.append(point) }
        }

        for segment in segments where !segment.isEmpty {
            guard let first = segment.first else { continue }
            // History preparation already clips and orders its paths. Keep the
            // display fallback defensive without silently changing measured spans.
            guard first.timestamp >= points[points.count - 1].timestamp,
                segment.allSatisfy({
                    $0.timestamp.timeIntervalSince1970.isFinite
                        && $0.timestamp >= cutoff && $0.timestamp <= now
                        && $0.value.isFinite && $0.value >= 0
                }),
                zip(segment, segment.dropFirst()).allSatisfy({ $0.0.timestamp <= $0.1.timestamp })
            else { return [] }

            if let previous = points.last, first.timestamp > previous.timestamp {
                append(ChartDisplayPoint(timestamp: previous.timestamp, value: 0))
                append(ChartDisplayPoint(timestamp: first.timestamp, value: 0))
            }
            for point in segment { append(point) }
        }

        if let last = points.last {
            if extendsCurrentToNow {
                append(ChartDisplayPoint(timestamp: now, value: last.value))
            } else {
                append(ChartDisplayPoint(timestamp: last.timestamp, value: 0))
                append(ChartDisplayPoint(timestamp: now, value: 0))
            }
        }
        return [points]
    }
}
