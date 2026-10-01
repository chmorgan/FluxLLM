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
    /// One canonical allocation holds all buckets. Segment boundaries preserve
    /// gaps without retaining a second copy of every bucket for plotting.
    let buckets: [ToolActivityBucket]
    private let segmentRanges: [Range<Int>]
    let resultMarkers: [ToolActivityEvent]
    let peak: Double?
    let current: ToolActivityBucket?

    private let now: Date
    private let cutoff: Date
    private let hasValidWindow: Bool

    /// Compatibility view for callers that need owned segment arrays. Rendering
    /// walks the ranges below directly and never materializes these bucket copies.
    var segments: [[ToolActivityBucket]] {
        segmentRanges.map { Array(buckets[$0]) }
    }

    /// Horizontal spans and vertical transitions describe rates without implying
    /// fractional calls between bins. Instantaneous evidence has no measurable rate.
    var plotSegments: [[ChartDisplayPoint]] {
        segmentRanges.compactMap { range in
            var points: [ChartDisplayPoint] = []
            for bucket in buckets[range] where bucket.observedDuration > 0 {
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
        self.init(
            preparedEvents: Self.normalizedEvents(events, through: now),
            observation: ToolActivityObservation(
                observations: observations, now: now, duration: duration,
                maximumGap: maximumGap, archivedSegments: archivedSegments))
    }

    /// Events have already been merged, deduplicated, and ordered for this
    /// publication. Grouping them by request preserves that ordering.
    init(preparedEvents events: [ToolActivityEvent], observation: ToolActivityObservation) {
        let interval = observation.interval
        let now = observation.now
        let cutoff = observation.cutoff
        self.interval = interval
        self.now = now
        self.cutoff = cutoff
        hasValidWindow = observation.isValid
        guard hasValidWindow else {
            segmentRanges = []
            buckets = []
            resultMarkers = []
            peak = nil
            current = nil
            return
        }

        let calls = events.filter { $0.kind == .call }
        resultMarkers = events.filter {
            $0.kind == .resultSubmission && $0.timestamp >= cutoff
        }
        let omittedLeadingKey = observation.omittedLeadingKey
        var displaySegments: [[ToolActivityBucket]] = []
        var assignedIDs: Set<UUID> = []
        var callIndex = 0
        for run in observation.runs {
            while callIndex < calls.count && calls[callIndex].timestamp < run.start {
                callIndex += 1
            }
            let firstCallIndex = callIndex
            while callIndex < calls.count && calls[callIndex].timestamp <= run.end {
                assignedIDs.insert(calls[callIndex].id)
                callIndex += 1
            }
            var bucketCallIndex = firstCallIndex
            var segment: [ToolActivityBucket] = []
            segment.reserveCapacity(run.buckets.count)
            for bucket in run.buckets {
                while bucketCallIndex < callIndex
                    && Self.bucketKey(calls[bucketCallIndex].timestamp, interval: interval)
                        < bucket.key
                {
                    bucketCallIndex += 1
                }
                let firstBucketCallIndex = bucketCallIndex
                while bucketCallIndex < callIndex
                    && Self.bucketKey(calls[bucketCallIndex].timestamp, interval: interval)
                        == bucket.key
                {
                    bucketCallIndex += 1
                }
                segment.append(
                    Self.bucket(
                        start: bucket.start, end: bucket.end,
                        calls: calls[firstBucketCallIndex..<bucketCallIndex]))
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
        var offset = 0
        segmentRanges = displaySegments.map { segment in
            let start = offset
            offset += segment.count
            return start..<offset
        }
        buckets = displaySegments.count == 1 ? displaySegments[0] : displaySegments.flatMap { $0 }
        peak = buckets.lazy.filter { $0.observedDuration > 0 }.map(\.callsPerMinute).max()

        if let latest = observation.currentTimestamp,
            !pendingCalls.contains(where: { $0.timestamp > latest }),
            !buckets.contains(where: {
                $0.end == latest && $0.observedDuration == 0 && $0.callCount > 0
            }),
            let candidate = buckets.last(where: {
                $0.end == latest && $0.observedDuration > 0
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

    private static func bucket<Calls: Collection>(
        start: Date, end: Date, calls: Calls
    ) -> ToolActivityBucket where Calls.Element == ToolActivityEvent {
        let duration = end.timeIntervalSince(start)
        let rate = duration > 0 ? Double(calls.count) * 60 / duration : 0
        return ToolActivityBucket(
            start: start, end: end, callCount: calls.count,
            callsPerMinute: rate.isFinite ? rate : Double.greatestFiniteMagnitude,
            toolNames: Array(Set(calls.compactMap(\.name))).sorted())
    }

    static func normalizedEvents(
        _ events: [ToolActivityEvent], through now: Date
    ) -> [ToolActivityEvent] {
        var seenIDs: Set<UUID> = []
        return events.filter {
            $0.timestamp.timeIntervalSince1970.isFinite && $0.timestamp <= now
                && seenIDs.insert($0.id).inserted
        }.enumerated().sorted {
            if $0.element.timestamp == $1.element.timestamp { return $0.offset < $1.offset }
            return $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
    }

    private static func bucketKey(_ timestamp: Date, interval: TimeInterval) -> Double {
        (timestamp.timeIntervalSince1970 / interval).rounded(.down)
    }
}
