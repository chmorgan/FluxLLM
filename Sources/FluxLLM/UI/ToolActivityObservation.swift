import Foundation

/// Exposure geometry is identical for the combined tool chart and every request
/// overlay. Prepare it once per publication/window, not once per request.
struct ToolActivityObservation {
    /// A value copy keeps this immutable coverage identity. Histories can then
    /// compare sparse call counts without hashing the same observation buckets.
    final class PlotIdentity {}
    let plotIdentity = PlotIdentity()

    struct Bucket {
        let key: Double
        let start: Date
        let end: Date
        let zeroBucket: ToolActivityBucket

        init(key: Double, start: Date, end: Date) {
            self.key = key
            self.start = start
            self.end = end
            zeroBucket = ToolActivityBucket(
                start: start, end: end, callCount: 0, callsPerMinute: 0, toolNames: [])
        }
    }

    struct Run {
        let start: Date
        let end: Date
        let buckets: [Bucket]
        /// Requests share the same zero-rate coverage until a call changes a bin.
        let zeroBuckets: [ToolActivityBucket]

        init(start: Date, end: Date, buckets: [Bucket]) {
            self.start = start
            self.end = end
            self.buckets = buckets
            zeroBuckets = buckets.map(\.zeroBucket)
        }
    }

    let interval: TimeInterval
    let now: Date
    let cutoff: Date
    let isValid: Bool
    let omittedLeadingKey: Double?
    let currentTimestamp: Date?
    let runs: [Run]

    init(
        observations: [TimeSeriesPoint], now: Date, duration: TimeInterval,
        maximumGap: TimeInterval = 5, archivedSegments: [[ArchivedChartBucket]] = []
    ) {
        let window = ChartObservationWindow(
            samples: observations, now: now, duration: duration, maximumGap: maximumGap,
            archivedSegments: archivedSegments)
        let interval = window.interval
        let cutoff = window.cutoff
        self.interval = interval
        self.now = now
        self.cutoff = cutoff
        isValid = window.isValid
        omittedLeadingKey = window.omittedLeadingKey
        if let latest = window.latest, ChartObservationWindow.isValid(latest),
            latest.timestamp >= cutoff, now.timeIntervalSince(latest.timestamp) <= maximumGap
        {
            currentTimestamp = latest.timestamp
        } else {
            currentTimestamp = nil
        }

        var coverage = window.rawRuns.compactMap { run -> (start: Date, end: Date)? in
            guard let first = run.first, let last = run.last else { return nil }
            return (first.timestamp, last.timestamp)
        }
        coverage += window.archive.compactMap { run -> (start: Date, end: Date)? in
            guard let first = run.first, let last = run.last else { return nil }
            return (first.start, last.end)
        }
        coverage.sort { $0.start < $1.start }
        runs = coverage.map { run in
            var key = ChartObservationWindow.bucketKey(max(run.start, cutoff), interval: interval)
            let lastKey = ChartObservationWindow.bucketKey(run.end, interval: interval)
            var buckets: [Bucket] = []
            while key <= lastKey {
                if key != window.omittedLeadingKey {
                    let start = max(run.start, Date(timeIntervalSince1970: key * interval))
                    let end = min(run.end, Date(timeIntervalSince1970: (key + 1) * interval))
                    if end >= cutoff, start <= end {
                        buckets.append(Bucket(key: key, start: start, end: end))
                    }
                }
                guard key + 1 > key else { break }
                key += 1
            }
            return Run(start: run.start, end: run.end, buckets: buckets)
        }
    }
}
