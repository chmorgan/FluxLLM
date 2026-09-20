import Foundation

/// An event count over the connected observation time inside one epoch-aligned bin.
struct ToolActivityBucket: Equatable, Sendable {
    let start: Date
    let end: Date
    let callCount: Int
    let callsPerMinute: Double
    let toolNames: [String]

    var timestamp: Date { end }
    var observedDuration: TimeInterval { end.timeIntervalSince(start) }
}

/// Count-based tool rates, prepared independently of the generated-token averages.
struct ToolActivityHistory {
    let interval: TimeInterval
    let segments: [[ToolActivityBucket]]
    let buckets: [ToolActivityBucket]
    let resultMarkers: [ToolActivityEvent]
    let peak: Double?
    let current: ToolActivityBucket?

    private let now: Date
    private let cutoff: Date
    private let hasValidWindow: Bool

    /// Horizontal spans and vertical transitions describe rates without implying
    /// fractional calls between bins. Instantaneous evidence has no measurable rate.
    var plotSegments: [[ChartDisplayPoint]] {
        segments.compactMap { segment in
            var points: [ChartDisplayPoint] = []
            for bucket in segment where bucket.observedDuration > 0 {
                let start = ChartDisplayPoint(
                    timestamp: max(bucket.start, cutoff), value: bucket.callsPerMinute)
                if points.last != start { points.append(start) }
                let end = ChartDisplayPoint(timestamp: bucket.end, value: bucket.callsPerMinute)
                if points.last != end { points.append(end) }
            }
            return points.isEmpty ? nil : points
        }
    }

    /// Keep the event-rate display connected without adding exposure time or
    /// changing any observed bin's count, rate, or step geometry.
    var zeroFilledPlotSegments: [[ChartDisplayPoint]] {
        guard hasValidWindow else { return [] }
        return ChartGapFilling.plotSegments(
            plotSegments, cutoff: cutoff, now: now, extendsCurrentToNow: current != nil)
    }

    init(
        events: [ToolActivityEvent], observations: [TimeSeriesPoint], now: Date,
        duration: TimeInterval, maximumGap: TimeInterval = 5,
        archivedSegments: [[ArchivedChartBucket]] = []
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
        hasValidWindow =
            validDuration && now.timeIntervalSince1970.isFinite
            && cutoff.timeIntervalSince1970.isFinite
            && maximumGap.isFinite && maximumGap >= 0

        guard hasValidWindow else {
            segments = []
            buckets = []
            resultMarkers = []
            peak = nil
            current = nil
            return
        }

        // Match replacement semantics of the underlying time-series store.
        let sortedObservations = observations.enumerated().filter {
            $0.element.timestamp.timeIntervalSince1970.isFinite && $0.element.timestamp <= now
        }.sorted {
            if $0.element.timestamp == $1.element.timestamp { return $0.offset < $1.offset }
            return $0.element.timestamp < $1.element.timestamp
        }
        var samples: [TimeSeriesPoint] = []
        for observation in sortedObservations {
            if samples.last?.timestamp == observation.element.timestamp { samples.removeLast() }
            samples.append(observation.element)
        }

        var seenIDs: Set<UUID> = []
        let validEvents = events.filter {
            $0.timestamp.timeIntervalSince1970.isFinite && $0.timestamp <= now
                && seenIDs.insert($0.id).inserted
        }.enumerated().sorted {
            if $0.element.timestamp == $1.element.timestamp { return $0.offset < $1.offset }
            return $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
        let calls = validEvents.filter { $0.kind == .call }
        resultMarkers = validEvents.filter {
            $0.kind == .resultSubmission && $0.timestamp >= cutoff
        }

        // An incomplete retention bin has lost both its exposure time and events.
        // Omit it instead of allowing old completed rates to drift as data expires.
        var omittedLeadingKey: Double?
        let archive = archivedSegments.compactMap { segment -> [ArchivedChartBucket]? in
            let retained = segment.filter { sample in
                sample.isValid && sample.end <= now
                    && (samples.first.map { sample.end < $0.timestamp } ?? true)
            }
            return retained.isEmpty ? nil : retained
        }
        let earliest = ([samples.first?.timestamp] + archive.map { $0.first?.start })
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
        for sample in samples {
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

        // Archived segments retain exact collection spans even though the rate
        // samples within them have been reduced to minute means. Their endpoints
        // provide exposure time; gaps between segments remain unobserved.
        var coverageRuns = rawRuns.compactMap { run -> (start: Date, end: Date)? in
            guard let first = run.first, let last = run.last else { return nil }
            return (first.timestamp, last.timestamp)
        }
        coverageRuns += archive.compactMap { run -> (start: Date, end: Date)? in
            guard let first = run.first, let last = run.last else { return nil }
            return (first.start, last.end)
        }
        coverageRuns.sort { $0.start < $1.start }

        var displaySegments: [[ToolActivityBucket]] = []
        var assignedIDs: Set<UUID> = []
        var callIndex = 0
        for run in coverageRuns {
            while callIndex < calls.count && calls[callIndex].timestamp < run.start {
                callIndex += 1
            }
            let firstCallIndex = callIndex
            while callIndex < calls.count && calls[callIndex].timestamp <= run.end {
                callIndex += 1
            }
            let runCalls = Array(calls[firstCallIndex..<callIndex])
            assignedIDs.formUnion(runCalls.map(\.id))
            let firstKey = Self.bucketKey(max(run.start, cutoff), interval: interval)
            let lastKey = Self.bucketKey(run.end, interval: interval)
            var key = firstKey
            var segment: [ToolActivityBucket] = []
            while key <= lastKey {
                if key != omittedLeadingKey {
                    let start = max(
                        run.start, Date(timeIntervalSince1970: key * interval))
                    let end = min(
                        run.end, Date(timeIntervalSince1970: (key + 1) * interval))
                    let bucketCalls = runCalls.filter {
                        Self.bucketKey($0.timestamp, interval: interval) == key
                    }
                    if end >= cutoff, start <= end {
                        segment.append(Self.bucket(start: start, end: end, calls: bucketCalls))
                    }
                }
                guard key + 1 > key else { break }
                key += 1
            }
            if !segment.isEmpty { displaySegments.append(segment) }
        }

        // Events can precede the next half-second observation, or arrive during a
        // telemetry gap. Preserve their counts as instantaneous pending evidence;
        // they must not create invented coverage or reconnect a missing interval.
        let pendingCalls = calls.filter {
            !assignedIDs.contains($0.id) && $0.timestamp >= cutoff
                && Self.bucketKey($0.timestamp, interval: interval) != omittedLeadingKey
        }
        var pending: [ToolActivityEvent] = []
        for call in pendingCalls {
            if let previous = pending.last, call.timestamp != previous.timestamp {
                displaySegments.append([
                    Self.bucket(start: previous.timestamp, end: previous.timestamp, calls: pending)
                ])
                pending = []
            }
            pending.append(call)
        }
        if let last = pending.last {
            displaySegments.append([
                Self.bucket(start: last.timestamp, end: last.timestamp, calls: pending)
            ])
        }
        displaySegments.sort { $0[0].start < $1[0].start }
        segments = displaySegments
        buckets = displaySegments.flatMap { $0 }
        peak = buckets.filter { $0.observedDuration > 0 }.map(\.callsPerMinute).max()

        if let latest = samples.last, Self.isValid(latest), latest.timestamp >= cutoff,
            now.timeIntervalSince(latest.timestamp) <= maximumGap,
            !pendingCalls.contains(where: { $0.timestamp > latest.timestamp }),
            !buckets.contains(where: {
                $0.end == latest.timestamp && $0.observedDuration == 0 && $0.callCount > 0
            }),
            let candidate = buckets.last(where: {
                $0.end == latest.timestamp && $0.observedDuration > 0
            })
        {
            current = candidate
        } else {
            current = nil
        }
    }

    /// Select only a bin supported by coverage at the pointer's exact timestamp.
    func bucket(at timestamp: Date) -> ToolActivityBucket? {
        guard timestamp.timeIntervalSince1970.isFinite,
            timestamp >= cutoff, timestamp <= now
        else { return nil }
        let key = Self.bucketKey(timestamp, interval: interval)
        return buckets.first {
            timestamp >= $0.start && timestamp <= $0.end
                && Self.bucketKey($0.start, interval: interval) == key
        }
    }

    private static func bucket(
        start: Date, end: Date, calls: [ToolActivityEvent]
    ) -> ToolActivityBucket {
        let duration = end.timeIntervalSince(start)
        let rate = duration > 0 ? Double(calls.count) * 60 / duration : 0
        return ToolActivityBucket(
            start: start, end: end, callCount: calls.count,
            callsPerMinute: rate.isFinite ? rate : Double.greatestFiniteMagnitude,
            toolNames: Array(Set(calls.compactMap(\.name))).sorted())
    }

    private static func isValid(_ sample: TimeSeriesPoint) -> Bool {
        sample.isAvailable && sample.value.isFinite && sample.value >= 0
    }

    private static func bucketKey(_ timestamp: Date, interval: TimeInterval) -> Double {
        (timestamp.timeIntervalSince1970 / interval).rounded(.down)
    }
}
