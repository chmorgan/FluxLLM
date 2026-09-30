import Foundation

/// Source boundaries are retained independently of the drawing window. Clipping
/// to an epoch-aligned bin must not turn its first visible sample into a new
/// retention boundary or remove the observation that establishes its coverage.
struct ChartObservationWindow {
    let interval: TimeInterval
    let now: Date
    let cutoff: Date
    let maximumGap: TimeInterval
    let isValid: Bool
    let omittedLeadingKey: Double?
    let latest: TimeSeriesPoint?
    let rawRuns: [[TimeSeriesPoint]]
    let archive: [[ArchivedChartBucket]]

    init(
        samples: [TimeSeriesPoint], now: Date, duration: TimeInterval,
        maximumGap: TimeInterval, archivedSegments: [[ArchivedChartBucket]]
    ) {
        let validDuration = duration.isFinite && duration > 0
        let cutoff = validDuration ? now.addingTimeInterval(-duration) : now
        let usesArchive = archivedSegments.contains { segment in
            segment.contains { $0.isValid && $0.end >= cutoff && $0.end <= now }
        }
        let interval =
            validDuration
            ? (usesArchive ? max(60, (duration / 3_600).rounded(.up) * 60) : max(3, duration / 60))
            : 3
        self.interval = interval
        self.now = now
        self.cutoff = cutoff
        self.maximumGap = maximumGap
        isValid =
            validDuration && now.timeIntervalSince1970.isFinite
            && cutoff.timeIntervalSince1970.isFinite
            && maximumGap.isFinite && maximumGap >= 0
        guard isValid else {
            omittedLeadingKey = nil
            latest = nil
            rawRuns = []
            archive = []
            return
        }

        let observations = Self.normalized(samples, through: now)
        latest = observations.last
        let retainedArchive = archivedSegments.compactMap { segment -> [ArchivedChartBucket]? in
            let retained = segment.filter { sample in
                sample.isValid && sample.end <= now
                    && (observations.first.map { sample.end < $0.timestamp } ?? true)
            }
            return retained.isEmpty ? nil : retained
        }
        let earliest = ([observations.first?.timestamp] + retainedArchive.map { $0.first?.start })
            .compactMap { $0 }.min()
        if let earliest {
            let key = Self.bucketKey(earliest, interval: interval)
            let start = key * interval
            let leftEdge = cutoff.timeIntervalSince1970
            omittedLeadingKey =
                earliest.timeIntervalSince1970 > start
                    && start <= leftEdge && leftEdge < start + interval ? key : nil
        } else {
            omittedLeadingKey = nil
        }

        // Keep the complete first visible bin, plus its immediate predecessor.
        // The predecessor preserves continuous coverage and hover before the
        // first sample in that bin. An unavailable predecessor still breaks it.
        let firstVisibleKey = Self.bucketKey(cutoff, interval: interval)
        var lower = 0
        var upper = observations.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if Self.bucketKey(observations[middle].timestamp, interval: interval) < firstVisibleKey
            {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let startIndex = max(0, lower - 1)
        var runs: [[TimeSeriesPoint]] = []
        var run: [TimeSeriesPoint] = []
        for sample in observations[startIndex...] {
            guard Self.isValid(sample) else {
                if !run.isEmpty { runs.append(run) }
                run = []
                continue
            }
            if let previous = run.last,
                sample.timestamp.timeIntervalSince(previous.timestamp) > maximumGap
            {
                runs.append(run)
                run = []
            }
            run.append(sample)
        }
        if !run.isEmpty { runs.append(run) }
        rawRuns = runs
        // Keep each archive segment's original endpoints for tool exposure and
        // chart hover. Chart aggregation below selects whole bins by their end.
        archive = retainedArchive.filter { segment in segment.contains { $0.end >= cutoff } }
    }

    static func isValid(_ sample: TimeSeriesPoint) -> Bool {
        sample.isAvailable && sample.value.isFinite && sample.value >= 0
    }

    static func bucketKey(_ timestamp: Date, interval: TimeInterval) -> Double {
        (timestamp.timeIntervalSince1970 / interval).rounded(.down)
    }

    /// Normal production publications are ordered already. Fall back to a stable
    /// timestamp sort for imported/test input, preserving last-writer wins.
    private static func normalized(
        _ samples: [TimeSeriesPoint], through now: Date
    ) -> [TimeSeriesPoint] {
        var ordered: [TimeSeriesPoint] = []
        ordered.reserveCapacity(samples.count)
        for sample in samples
        where sample.timestamp.timeIntervalSince1970.isFinite
            && sample.timestamp <= now
        {
            if let previous = ordered.last {
                if sample.timestamp < previous.timestamp {
                    return sorted(samples, through: now)
                }
                if sample.timestamp == previous.timestamp { ordered.removeLast() }
            }
            ordered.append(sample)
        }
        return ordered
    }

    private static func sorted(
        _ samples: [TimeSeriesPoint], through now: Date
    ) -> [TimeSeriesPoint] {
        let sorted = samples.enumerated().filter {
            $0.element.timestamp.timeIntervalSince1970.isFinite && $0.element.timestamp <= now
        }.sorted {
            if $0.element.timestamp == $1.element.timestamp { return $0.offset < $1.offset }
            return $0.element.timestamp < $1.element.timestamp
        }
        var observations: [TimeSeriesPoint] = []
        observations.reserveCapacity(sorted.count)
        for entry in sorted {
            if observations.last?.timestamp == entry.element.timestamp { observations.removeLast() }
            observations.append(entry.element)
        }
        return observations
    }
}
