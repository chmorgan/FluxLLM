import Foundation

/// A short display average of measured intervals. Raw rates and chart history stay separate.
struct SlotThroughputDisplayAverage {
    private struct Interval {
        let start: Date
        let end: Date
        let rate: Double
    }

    private static let window: TimeInterval = 3
    private var intervals: [Interval] = []

    var value: Double? {
        if intervals.count == 1 { return intervals.first?.rate }
        let duration = intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard duration > 0 else { return nil }
        let weighted = intervals.reduce(0) {
            $0 + $1.rate * $1.end.timeIntervalSince($1.start)
        }
        let rate = weighted / duration
        return rate.isFinite ? rate : nil
    }

    mutating func reset() {
        intervals.removeAll(keepingCapacity: true)
    }

    mutating func record(rate: Double, duration: TimeInterval, endingAt end: Date) {
        guard rate.isFinite, rate >= 0, duration.isFinite, duration > 0,
            end.timeIntervalSinceReferenceDate.isFinite
        else {
            reset()
            return
        }
        // A repeated timestamp replaces its interval instead of adding another observation.
        if intervals.last?.end == end { intervals.removeLast() }
        if let last = intervals.last, end < last.end { reset() }

        let cutoff = end.addingTimeInterval(-Self.window)
        intervals = intervals.compactMap { interval in
            guard interval.end > cutoff else { return nil }
            return Interval(
                start: max(interval.start, cutoff), end: interval.end, rate: interval.rate)
        }
        // Monotonic durations provide the weight. Wall-clock endpoints only position the
        // window; clip overlap so adjacent observations never count the same time twice.
        let start = max(end.addingTimeInterval(-duration), cutoff, intervals.last?.end ?? cutoff)
        guard start < end else { return }
        intervals.append(Interval(start: start, end: end, rate: rate))
    }
}
