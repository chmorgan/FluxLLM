import Foundation

/// Exposure geometry is identical for the combined tool chart and every request
/// overlay. Prepare it once per publication/window, not once per request.
struct ToolActivityObservation {
    struct Bucket {
        let key: Double
        let start: Date
        let end: Date
    }

    struct Run {
        let start: Date
        let end: Date
        let buckets: [Bucket]
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
