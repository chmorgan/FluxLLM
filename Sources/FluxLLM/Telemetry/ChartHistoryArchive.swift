import Foundation

/// A minute mean and the observations that support it. Explicit segments retain
/// collection gaps without treating the space between archived points as measured.
public struct ArchivedChartBucket: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let value: Double
    public let count: Int

    public init(start: Date, end: Date, value: Double, count: Int) {
        self.start = start
        self.end = end
        self.value = value
        self.count = count
    }

    var isValid: Bool {
        start.timeIntervalSince1970.isFinite && end.timeIntervalSince1970.isFinite
            && start <= end && end.timeIntervalSince(start) < 60
            && value.isFinite && value >= 0 && count > 0 && count <= 1_000_000
    }
}

public struct ArchivedChartHistory: Equatable, Sendable {
    public let throughput: [[ArchivedChartBucket]]
    public let systemGPU: [[ArchivedChartBucket]]
    public let toolObservation: [[ArchivedChartBucket]]

    public static let empty = ArchivedChartHistory()

    public init(
        throughput: [[ArchivedChartBucket]] = [], systemGPU: [[ArchivedChartBucket]] = [],
        toolObservation: [[ArchivedChartBucket]] = []
    ) {
        self.throughput = throughput
        self.systemGPU = systemGPU
        self.toolObservation = toolObservation
    }

    public var availableSince: Date? {
        var earliest: Date?
        for series in [throughput, systemGPU, toolObservation] {
            for segment in series {
                if let date = segment.first?.start { earliest = min(earliest ?? date, date) }
            }
        }
        return earliest
    }
}

/// Keeps a day of minute averages in memory for the current application session.
/// No history is loaded or written, including when a legacy directory is supplied.
@MainActor
public final class ChartHistoryArchive {
    public static let retention: TimeInterval = 24 * 60 * 60

    // Compatibility for callers transitioning away from persistence. These never
    // perform IO or schedule work and can be removed when the callers are migrated.
    public var persistenceError: String? { nil }

    nonisolated private static let bucketInterval: TimeInterval = 60
    nonisolated private static let maximumGap: TimeInterval = 5
    nonisolated private static let maximumBucketsPerSeries = 20_000
    private static let maximumSources = 32

    private var sources: [String: Source] = [:]
    private var activeSource: String?
    private var latestDate: Date

    public init(directory: URL? = nil, now: Date = Date()) {
        latestDate = now
    }

    public func record(
        source: String, at date: Date, throughput: TimeSeriesPoint,
        gpu: TimeSeriesPoint, toolObservation: TimeSeriesPoint
    ) {
        guard date.timeIntervalSince1970.isFinite else { return }
        latestDate = max(latestDate, date)
        if activeSource != source {
            if let activeSource { sources[activeSource]?.endRun() }
            sources[source]?.endRun()
            activeSource = source
        }
        let history: Source
        if let existing = sources[source] {
            history = existing
        } else {
            history = Source()
            sources[source] = history
        }
        history.throughput.record(throughput)
        history.systemGPU.record(gpu)
        history.toolObservation.record(toolObservation)
        trim(at: latestDate)
    }

    /// Return complete archived buckets preceding the raw buffer. Never split a
    /// mean at the boundary and pretend its contributors are still individually known.
    public func history(source: String, before: Date, now: Date) -> ArchivedChartHistory {
        guard now.timeIntervalSince1970.isFinite, before.timeIntervalSince1970.isFinite else {
            return .empty
        }
        trim(at: now)
        guard let source = sources[source] else { return .empty }
        let cutoff = now.addingTimeInterval(-Self.retention)
        return ArchivedChartHistory(
            throughput: source.throughput.visible(before: before, cutoff: cutoff, now: now),
            systemGPU: source.systemGPU.visible(before: before, cutoff: cutoff, now: now),
            toolObservation: source.toolObservation.visible(
                before: before, cutoff: cutoff, now: now))
    }

    /// Earliest retained observation without allocating a chart snapshot.
    public func availableSince(source: String, now: Date) -> Date? {
        guard now.timeIntervalSince1970.isFinite else { return nil }
        trim(at: now)
        return sources[source]?.availableSince(at: now)
    }

    public func endSession(source: String, at date: Date) {
        sources[source]?.endRun()
        if activeSource == source { activeSource = nil }
        if date.timeIntervalSince1970.isFinite { latestDate = max(latestDate, date) }
    }

    public func prepare() async {}
    public func flush() {}
    public func flushAndWait() async {}

    private func trim(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.retention)
        for key in sources.keys {
            sources[key]?.trim(before: cutoff)
            if sources[key]?.lastDate == nil { sources.removeValue(forKey: key) }
        }
        if sources.count > Self.maximumSources {
            let oldest = sources.keys.sorted {
                (sources[$0]?.lastDate ?? .distantPast) < (sources[$1]?.lastDate ?? .distantPast)
            }
            for key in oldest.prefix(sources.count - Self.maximumSources) {
                sources.removeValue(forKey: key)
            }
        }
    }

    // Reference ownership keeps recording into a dictionary entry from copying
    // its bucket buffers on each sample. All access stays on the main actor.
    private final class Source {
        var throughput = Series()
        var systemGPU = Series()
        var toolObservation = Series()

        var lastDate: Date? {
            var latest = throughput.lastDate
            if let date = systemGPU.lastDate { latest = max(latest ?? date, date) }
            if let date = toolObservation.lastDate { latest = max(latest ?? date, date) }
            return latest
        }

        func availableSince(at now: Date) -> Date? {
            var earliest = throughput.availableSince(at: now)
            if let date = systemGPU.availableSince(at: now) {
                earliest = min(earliest ?? date, date)
            }
            if let date = toolObservation.availableSince(at: now) {
                earliest = min(earliest ?? date, date)
            }
            return earliest
        }

        func endRun() {
            throughput.endRun()
            systemGPU.endRun()
            toolObservation.endRun()
        }

        func trim(before cutoff: Date) {
            throughput.trim(before: cutoff)
            systemGPU.trim(before: cutoff)
            toolObservation.trim(before: cutoff)
        }
    }

    private struct Entry {
        var bucket: ArchivedChartBucket
        let beginsRun: Bool
    }

    /// A bounded ring with amortized constant-time insertion and expiry. Segment
    /// boundaries are flags rather than individually allocated nested arrays.
    private struct BucketBuffer {
        private var entries: [Entry?] = []
        private var head = 0
        private(set) var count = 0

        var isEmpty: Bool { count == 0 }
        var first: Entry? { isEmpty ? nil : self[0] }
        var last: Entry? { isEmpty ? nil : self[count - 1] }

        subscript(index: Int) -> Entry {
            get { entries[(head + index) % entries.count]! }
            set { entries[(head + index) % entries.count] = newValue }
        }

        mutating func append(_ entry: Entry) {
            if count == ChartHistoryArchive.maximumBucketsPerSeries { removeFirst() }
            if count == entries.count {
                let capacity = min(
                    max(16, entries.count * 2), ChartHistoryArchive.maximumBucketsPerSeries)
                var grown = [Entry?](repeating: nil, count: capacity)
                for index in 0..<count { grown[index] = self[index] }
                entries = grown
                head = 0
            }
            entries[(head + count) % entries.count] = entry
            count += 1
        }

        mutating func removeFirst() {
            guard !isEmpty else { return }
            entries[head] = nil
            head = (head + 1) % entries.count
            count -= 1
        }

        mutating func removeLast() {
            guard !isEmpty else { return }
            entries[(head + count - 1) % entries.count] = nil
            count -= 1
        }

        /// First bucket satisfying a monotone predicate over ordered end times.
        func lowerBound(where predicate: (Date) -> Bool) -> Int {
            var low = 0
            var high = count
            while low < high {
                let middle = low + (high - low) / 2
                if predicate(self[middle].bucket.end) {
                    high = middle
                } else {
                    low = middle + 1
                }
            }
            return low
        }
    }

    private struct Series {
        var buckets = BucketBuffer()
        var lastSample: TimeSeriesPoint?
        var priorBucket: ArchivedChartBucket?
        var lastWasAvailable = false
        var lastBeganRun = false
        var beginsRun = true

        var lastDate: Date? { buckets.last?.bucket.end }

        func availableSince(at now: Date) -> Date? {
            guard let first = buckets.first?.bucket, first.end <= now else { return nil }
            return first.start
        }

        mutating func endRun() {
            beginsRun = true
            lastSample = nil
            priorBucket = nil
        }

        mutating func record(_ point: TimeSeriesPoint) {
            guard point.timestamp.timeIntervalSince1970.isFinite else { return }
            if let lastSample, point.timestamp < lastSample.timestamp { return }
            if let lastDate, point.timestamp < lastDate { return }
            let available = point.isAvailable && point.value.isFinite && point.value >= 0
            if let lastSample, point.timestamp == lastSample.timestamp {
                if lastWasAvailable {
                    if let priorBucket {
                        buckets[buckets.count - 1].bucket = priorBucket
                    } else {
                        buckets.removeLast()
                    }
                }
                // A duplicate unavailable reading cannot heal a previous missing sample.
                beginsRun = beginsRun || lastBeganRun || !lastWasAvailable
            } else {
                priorBucket = nil
            }
            let previousDate = buckets.last?.bucket.end
            let gap = previousDate.map { point.timestamp.timeIntervalSince($0) } ?? .infinity
            if !available {
                beginsRun = true
                priorBucket = nil
                lastBeganRun = false
            } else {
                let bucket = ArchivedChartBucket(
                    start: point.timestamp, end: point.timestamp, value: point.value, count: 1)
                if beginsRun || gap > ChartHistoryArchive.maximumGap || buckets.isEmpty {
                    buckets.append(Entry(bucket: bucket, beginsRun: true))
                    priorBucket = nil
                    lastBeganRun = true
                } else if let previous = buckets.last?.bucket,
                    Self.minute(previous.end) == Self.minute(point.timestamp)
                {
                    priorBucket = previous
                    let count = previous.count + 1
                    let mean = previous.value + (point.value - previous.value) / Double(count)
                    buckets[buckets.count - 1].bucket = ArchivedChartBucket(
                        start: previous.start, end: point.timestamp, value: mean, count: count)
                    lastBeganRun = false
                } else {
                    buckets.append(Entry(bucket: bucket, beginsRun: false))
                    priorBucket = nil
                    lastBeganRun = false
                }
                beginsRun = false
            }
            lastSample = point
            lastWasAvailable = available
        }

        mutating func trim(before cutoff: Date) {
            while let first = buckets.first, first.bucket.end < cutoff { buckets.removeFirst() }
            if buckets.isEmpty { endRun() }
        }

        func visible(before: Date, cutoff: Date, now: Date) -> [[ArchivedChartBucket]] {
            let lower = buckets.lowerBound { $0 >= cutoff }
            let upper = min(
                buckets.lowerBound { $0 >= before }, buckets.lowerBound { $0 > now })
            guard lower < upper else { return [] }
            var segments: [[ArchivedChartBucket]] = []
            var run: [ArchivedChartBucket] = []
            for index in lower..<upper {
                let entry = buckets[index]
                if entry.beginsRun, !run.isEmpty {
                    segments.append(run)
                    run = []
                }
                run.append(entry.bucket)
            }
            if !run.isEmpty { segments.append(run) }
            return segments
        }

        private static func minute(_ date: Date) -> Double {
            (date.timeIntervalSince1970 / ChartHistoryArchive.bucketInterval).rounded(.down)
        }
    }
}
