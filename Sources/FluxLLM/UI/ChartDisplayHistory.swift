import Foundation

/// One display average, retaining the actual observations that support its time span.
struct ChartDisplayBucket: Equatable, Sendable {
    let timestamp: Date
    let value: Double
    let start: Date
    let end: Date
    let count: Int
}

/// A drawing coordinate derived from an average, without adding an observation to it.
struct ChartDisplayPoint: Equatable, Sendable {
    let timestamp: Date
    let value: Double
}

/// A calmer view of raw history without modifying collection or joining missing readings.
struct ChartDisplayHistory {
    let interval: TimeInterval
    let segments: [[ChartDisplayBucket]]
    let buckets: [ChartDisplayBucket]
    let peak: Double?
    let current: ChartDisplayBucket?

    private let now: Date
    private let cutoff: Date
    private let hasValidWindow: Bool
    private let runs: [DisplayRun]

    /// Cover the first average's observed span before connecting later bucket endpoints.
    /// Its start stays anchored as observations arrive, and raw gaps remain separate paths.
    var plotSegments: [[ChartDisplayPoint]] {
        segments.map { buckets in
            guard let first = buckets.first else { return [] }
            let start = max(first.start, cutoff)
            var points: [ChartDisplayPoint] = []
            if start < first.timestamp {
                points.append(ChartDisplayPoint(timestamp: start, value: first.value))
            }
            points.append(
                contentsOf: buckets.map {
                    ChartDisplayPoint(timestamp: $0.timestamp, value: $0.value)
                })
            return points
        }
    }

    /// Generated activity uses zero through unobserved spans for a continuous
    /// display. Measurement buckets and their availability remain unchanged.
    var zeroFilledPlotSegments: [[ChartDisplayPoint]] {
        guard hasValidWindow else { return [] }
        return ChartGapFilling.plotSegments(
            plotSegments, cutoff: cutoff, now: now, extendsCurrentToNow: current != nil)
    }

    init(
        samples: [TimeSeriesPoint], now: Date, duration: TimeInterval,
        maximumGap: TimeInterval = 5, archivedSegments: [[ArchivedChartBucket]] = []
    ) {
        let validDuration = duration.isFinite && duration > 0
        let cutoff = validDuration ? now.addingTimeInterval(-duration) : now
        let usesArchive = archivedSegments.contains { segment in
            segment.contains { $0.isValid && $0.end >= cutoff && $0.end <= now }
        }
        // Minute means cannot be expanded into pretend high-resolution samples.
        let interval =
            validDuration
            ? (usesArchive ? max(60, (duration / 3_600).rounded(.up) * 60) : max(3, duration / 60))
            : 3
        self.interval = interval
        self.now = now
        self.cutoff = cutoff
        hasValidWindow =
            validDuration && now.timeIntervalSince1970.isFinite
            && cutoff.timeIntervalSince1970.isFinite
            && maximumGap.isFinite && maximumGap >= 0

        guard hasValidWindow else {
            runs = []
            segments = []
            buckets = []
            peak = nil
            current = nil
            return
        }

        // Repeated timestamps follow the store's replacement rule. Preserve input order
        // for ties, then let the last observation at that timestamp win.
        let sorted = samples.enumerated().filter {
            $0.element.timestamp.timeIntervalSince1970.isFinite && $0.element.timestamp <= now
        }.sorted {
            if $0.element.timestamp == $1.element.timestamp { return $0.offset < $1.offset }
            return $0.element.timestamp < $1.element.timestamp
        }
        var observations: [TimeSeriesPoint] = []
        for entry in sorted {
            if observations.last?.timestamp == entry.element.timestamp {
                observations.removeLast()
            }
            observations.append(entry.element)
        }

        // At the source history's retention boundary, an incomplete leading bin
        // cannot be reconstructed. Omit that bin rather than change its old mean
        // as contributors disappear. Startup bins near Now remain visible.
        var omittedLeadingKey: Double?
        let archive = archivedSegments.compactMap { segment -> [ArchivedChartBucket]? in
            let retained = segment.filter { sample in
                sample.isValid && sample.end <= now
                    && (observations.first.map { sample.end < $0.timestamp } ?? true)
            }
            return retained.isEmpty ? nil : retained
        }
        let earliest = ([observations.first?.timestamp] + archive.map { $0.first?.start })
            .compactMap { $0 }.min()
        if let earliest {
            let key = Self.bucketKey(earliest, interval: interval)
            let start = key * interval
            let leftEdge = cutoff.timeIntervalSince1970
            if earliest.timeIntervalSince1970 > start,
                start <= leftEdge, leftEdge < start + interval
            {
                omittedLeadingKey = key
            }
        }

        var rawRuns: [[TimeSeriesPoint]] = []
        var rawRun: [TimeSeriesPoint] = []
        for sample in observations {
            guard Self.isValid(sample) else {
                if !rawRun.isEmpty { rawRuns.append(rawRun) }
                rawRun = []
                continue
            }
            if let previous = rawRun.last,
                sample.timestamp.timeIntervalSince(previous.timestamp) > maximumGap
            {
                rawRuns.append(rawRun)
                rawRun = []
            }
            rawRun.append(sample)
        }
        if !rawRun.isEmpty { rawRuns.append(rawRun) }

        var displayRuns: [DisplayRun] = []
        for rawRun in rawRuns {
            // Aggregate whole epoch-aligned bins first. Trimming individual samples at
            // the moving left edge would change previously completed averages.
            let visibleBuckets = Self.aggregate(rawRun, interval: interval).filter {
                $0.timestamp >= cutoff && $0.timestamp <= now
                    && Self.bucketKey($0.timestamp, interval: interval) != omittedLeadingKey
            }
            if let first = rawRun.first, let last = rawRun.last, !visibleBuckets.isEmpty {
                displayRuns.append(
                    DisplayRun(start: first.timestamp, end: last.timestamp, buckets: visibleBuckets)
                )
            }
        }
        for segment in archive {
            let visibleBuckets = Self.aggregate(segment, interval: interval).filter {
                $0.timestamp >= cutoff && $0.timestamp <= now
                    && Self.bucketKey($0.timestamp, interval: interval) != omittedLeadingKey
            }
            if let first = segment.first, let last = segment.last, !visibleBuckets.isEmpty {
                displayRuns.append(
                    DisplayRun(start: first.start, end: last.end, buckets: visibleBuckets))
            }
        }
        displayRuns.sort { $0.start < $1.start }
        runs = displayRuns
        segments = displayRuns.map(\.buckets)
        buckets = segments.flatMap { $0 }
        peak = buckets.map(\.value).max()

        if let latest = observations.last, Self.isValid(latest), latest.timestamp >= cutoff,
            now.timeIntervalSince(latest.timestamp) <= 5
        {
            current = buckets.last
        } else {
            current = nil
        }
    }

    /// Select a displayed bin only inside its original contiguous measurement run.
    /// A long-range average may span more than five seconds; its raw gaps still win.
    func bucket(at timestamp: Date) -> ChartDisplayBucket? {
        guard timestamp.timeIntervalSince1970.isFinite, timestamp >= cutoff, timestamp <= now,
            let run = runs.first(where: { timestamp >= $0.start && timestamp <= $0.end })
        else { return nil }
        let key = Self.bucketKey(timestamp, interval: interval)
        return run.buckets.first { Self.bucketKey($0.timestamp, interval: interval) == key }
    }

    private static func isValid(_ sample: TimeSeriesPoint) -> Bool {
        sample.isAvailable && sample.value.isFinite && sample.value >= 0
    }

    private static func bucketKey(_ timestamp: Date, interval: TimeInterval) -> Double {
        (timestamp.timeIntervalSince1970 / interval).rounded(.down)
    }

    private static func aggregate(
        _ samples: [TimeSeriesPoint], interval: TimeInterval
    ) -> [ChartDisplayBucket] {
        aggregate(
            samples.map {
                ArchivedChartBucket(
                    start: $0.timestamp, end: $0.timestamp, value: $0.value, count: 1)
            }, interval: interval)
    }

    private static func aggregate(
        _ samples: [ArchivedChartBucket], interval: TimeInterval
    ) -> [ChartDisplayBucket] {
        var result: [ChartDisplayBucket] = []
        var previousKey: Double?
        for sample in samples {
            let key = bucketKey(sample.end, interval: interval)
            if previousKey == key, let previous = result.popLast() {
                let count = previous.count + sample.count
                // Incremental nonnegative means avoid overflowing a sum of finite rates.
                let mean =
                    previous.value
                    + (sample.value - previous.value) * (Double(sample.count) / Double(count))
                result.append(
                    ChartDisplayBucket(
                        timestamp: sample.end, value: mean, start: previous.start,
                        end: sample.end, count: count))
            } else {
                result.append(
                    ChartDisplayBucket(
                        timestamp: sample.end, value: sample.value, start: sample.start,
                        end: sample.end, count: sample.count))
            }
            previousKey = key
        }
        return result
    }

    private struct DisplayRun {
        let start: Date
        let end: Date
        let buckets: [ChartDisplayBucket]
    }
}
