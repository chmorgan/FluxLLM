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
        (throughput + systemGPU + toolObservation).compactMap { $0.first?.start }.min()
    }
}

/// Keeps a day of minute averages independently of the recent, raw chart buffer.
/// A nil directory is deliberately memory-only, including in ordinary unit tests.
@MainActor
public final class ChartHistoryArchive {
    public static let retention: TimeInterval = 24 * 60 * 60
    public private(set) var persistenceError: String?

    nonisolated private static let bucketInterval: TimeInterval = 60
    nonisolated private static let maximumGap: TimeInterval = 5
    nonisolated private static let maximumBucketsPerSeries = 20_000
    private static let maximumSources = 32

    private var sources: [String: Source] = [:]
    private var activeSource: String?
    private var latestDate: Date
    private let file: URL?
    private let writer = ArchiveWriter()
    private var restoreTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var persistenceEnabled = true

    public init(directory: URL? = nil, now: Date = Date()) {
        latestDate = now
        file = directory?.appendingPathComponent("chart-history.json")
        guard let file else { return }
        restoreTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                ArchiveFile.read(file)
            }.value
            guard let self else { return }
            switch result {
            case .success(let saved):
                for (key, restored) in saved.sources {
                    let current = self.sources[key] ?? Source()
                    self.sources[key] = Source(restored: restored, followedBy: current)
                }
                self.trim(at: self.latestDate)
            case .failure(let error):
                // Keep an unreadable or newer archive intact for recovery. New
                // observations can still be collected in memory this session.
                self.persistenceEnabled = false
                self.persistenceError = error.message
                self.writeTask?.cancel()
                self.writeTask = nil
            }
        }
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
        var history = sources[source] ?? Source()
        history.throughput.record(throughput)
        history.systemGPU.record(gpu)
        history.toolObservation.record(toolObservation)
        sources[source] = history
        trim(at: latestDate)
        scheduleWrite(immediately: false)
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

    public func endSession(source: String, at date: Date) {
        sources[source]?.endRun()
        if activeSource == source { activeSource = nil }
        if date.timeIntervalSince1970.isFinite { latestDate = max(latestDate, date) }
        scheduleWrite(immediately: false)
    }

    /// Wait for asynchronous restoration when an owner needs the initial archive.
    public func prepare() async {
        await restoreTask?.value
    }

    /// Queue an immediate atomic save without doing filesystem work on the main actor.
    public func flush() {
        scheduleWrite(immediately: true)
    }

    public func flushAndWait() async {
        flush()
        await writeTask?.value
    }

    private func scheduleWrite(immediately: Bool) {
        guard let file, persistenceEnabled else { return }
        if !immediately, writeTask != nil { return }
        writeTask?.cancel()
        revision &+= 1
        let revision = revision
        writeTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
            guard let self else { return }
            await self.restoreTask?.value
            guard !Task.isCancelled, self.persistenceEnabled else { return }
            let archive = ArchiveFile(sources: self.sources.mapValues(\.saved))
            let error = await self.writer.write(archive, to: file, revision: revision)
            guard self.revision == revision else { return }
            self.persistenceError = error
            self.writeTask = nil
        }
    }

    private func trim(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.retention)
        for key in Array(sources.keys) {
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

    private struct Source {
        var throughput = Series()
        var systemGPU = Series()
        var toolObservation = Series()

        init() {}

        init(restored: SavedSource, followedBy current: Source) {
            throughput = Series(restored: restored.throughput, followedBy: current.throughput)
            systemGPU = Series(restored: restored.systemGPU, followedBy: current.systemGPU)
            toolObservation = Series(
                restored: restored.toolObservation, followedBy: current.toolObservation)
        }

        var saved: SavedSource {
            SavedSource(
                throughput: throughput.segments, systemGPU: systemGPU.segments,
                toolObservation: toolObservation.segments)
        }

        var lastDate: Date? {
            [throughput.lastDate, systemGPU.lastDate, toolObservation.lastDate]
                .compactMap { $0 }.max()
        }

        mutating func endRun() {
            throughput.endRun()
            systemGPU.endRun()
            toolObservation.endRun()
        }

        mutating func trim(before cutoff: Date) {
            throughput.trim(before: cutoff)
            systemGPU.trim(before: cutoff)
            toolObservation.trim(before: cutoff)
        }
    }

    private struct Series {
        var segments: [[ArchivedChartBucket]] = []
        var lastSample: TimeSeriesPoint?
        var priorBucket: ArchivedChartBucket?
        var lastWasAvailable = false
        var lastBeganRun = false
        var beginsRun = true

        init() {}

        init(restored: [[ArchivedChartBucket]], followedBy current: Series) {
            self = current
            let earliestCurrent = current.segments.first?.first?.start ?? .distantFuture
            let valid = restored.compactMap { segment -> [ArchivedChartBucket]? in
                let buckets = segment.filter { $0.isValid && $0.end < earliestCurrent }
                    .sorted { $0.start < $1.start }
                return buckets.isEmpty ? nil : buckets
            }.sorted { $0[0].start < $1[0].start }
            segments = valid + current.segments
            // A restored run never silently reconnects across app downtime.
            if current.lastSample == nil { beginsRun = true }
        }

        var lastDate: Date? { segments.last?.last?.end }

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
                        segments[segments.count - 1][segments.last!.count - 1] = priorBucket
                    } else {
                        segments[segments.count - 1].removeLast()
                        if segments.last?.isEmpty == true { segments.removeLast() }
                    }
                }
                // A duplicate unavailable reading cannot heal a previous missing sample.
                beginsRun = beginsRun || lastBeganRun || !lastWasAvailable
            } else {
                priorBucket = nil
            }
            let previousDate = segments.last?.last?.end
            let gap = previousDate.map { point.timestamp.timeIntervalSince($0) } ?? .infinity
            if !available {
                beginsRun = true
                priorBucket = nil
                lastBeganRun = false
            } else {
                let bucket = ArchivedChartBucket(
                    start: point.timestamp, end: point.timestamp, value: point.value, count: 1)
                if beginsRun || gap > ChartHistoryArchive.maximumGap || segments.isEmpty {
                    segments.append([bucket])
                    priorBucket = nil
                    lastBeganRun = true
                } else if let previous = segments.last?.last,
                    Self.minute(previous.end) == Self.minute(point.timestamp)
                {
                    priorBucket = previous
                    let count = previous.count + 1
                    let mean = previous.value + (point.value - previous.value) / Double(count)
                    segments[segments.count - 1][segments.last!.count - 1] = ArchivedChartBucket(
                        start: previous.start, end: point.timestamp, value: mean, count: count)
                    lastBeganRun = false
                } else {
                    segments[segments.count - 1].append(bucket)
                    priorBucket = nil
                    lastBeganRun = false
                }
                beginsRun = false
            }
            lastSample = point
            lastWasAvailable = available
        }

        mutating func trim(before cutoff: Date) {
            segments = segments.compactMap {
                let retained = $0.filter { $0.end >= cutoff }
                return retained.isEmpty ? nil : retained
            }
            var excess =
                segments.reduce(0) { $0 + $1.count }
                - ChartHistoryArchive.maximumBucketsPerSeries
            while excess > 0, !segments.isEmpty {
                let removed = min(excess, segments[0].count)
                segments[0].removeFirst(removed)
                excess -= removed
                if segments[0].isEmpty { segments.removeFirst() }
            }
            if segments.isEmpty { endRun() }
        }

        func visible(before: Date, cutoff: Date, now: Date) -> [[ArchivedChartBucket]] {
            segments.compactMap {
                let retained = $0.filter { $0.end < before && $0.end >= cutoff && $0.end <= now }
                return retained.isEmpty ? nil : retained
            }
        }

        private static func minute(_ date: Date) -> Double {
            (date.timeIntervalSince1970 / ChartHistoryArchive.bucketInterval).rounded(.down)
        }
    }
}

private struct SavedSource: Codable, Sendable {
    let throughput: [[ArchivedChartBucket]]
    let systemGPU: [[ArchivedChartBucket]]
    let toolObservation: [[ArchivedChartBucket]]
}

private struct ArchiveFile: Codable, Sendable {
    var version = 1
    let sources: [String: SavedSource]

    static func read(_ file: URL) -> Result<ArchiveFile, ArchiveError> {
        do {
            guard FileManager.default.fileExists(atPath: file.path) else {
                return .success(ArchiveFile(sources: [:]))
            }
            let archive = try JSONDecoder().decode(ArchiveFile.self, from: Data(contentsOf: file))
            guard archive.version == 1 else {
                return .failure(ArchiveError(message: "Unsupported chart history version."))
            }
            return .success(archive)
        } catch {
            return .failure(
                ArchiveError(message: "Could not load chart history: \(error.localizedDescription)")
            )
        }
    }
}

private struct ArchiveError: Error, Sendable {
    let message: String
}

private actor ArchiveWriter {
    private var latestRevision: UInt64 = 0

    func write(_ archive: ArchiveFile, to file: URL, revision: UInt64) -> String? {
        guard revision >= latestRevision else { return nil }
        latestRevision = revision
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(archive).write(to: file, options: .atomic)
            return nil
        } catch {
            return "Could not save chart history: \(error.localizedDescription)"
        }
    }
}
