import Foundation

/// Human-readable axis ceilings shared by the active chart scales.
enum SparklineGeometry {
    static func niceUpperBound(for peak: Double) -> Double {
        guard peak.isFinite && peak > 0 else { return 1 }
        let target = max(min(peak, Double.greatestFiniteMagnitude / 1.15) * 1.15, 1)
        let magnitude = pow(10, floor(log10(target)))
        let fraction = target / magnitude
        let step = [1.0, 2, 5, 10].first { $0 >= fraction } ?? 10
        let bound = step * magnitude
        return bound.isFinite ? bound : Double.greatestFiniteMagnitude
    }
}

/// Grow immediately for a burst; shrink only after a sustained lower range.
struct ChartScaleState {
    private(set) var upperBound: Double = 1
    private var belowSince: Date?

    mutating func update(peak: Double, now: Date) {
        let desired = SparklineGeometry.niceUpperBound(for: peak)
        if desired > upperBound {
            upperBound = desired
            belowSince = nil
        } else if desired <= upperBound * 0.5 {
            if let belowSince, now.timeIntervalSince(belowSince) >= 8 {
                upperBound = desired
                self.belowSince = nil
            } else if belowSince == nil {
                belowSince = now
            }
        } else {
            belowSince = nil
        }
    }
}
