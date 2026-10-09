import Foundation

/// Bounded identity observation, independent of aggregate backend rate and usage.
/// A missing identity ends observation, rather than asserting request completion.
struct NativeRequestTracker {
    private struct CounterObservation {
        let count: Int
        let timestamp: Date
    }

    private struct Record {
        let id = UUID()
        let startedAt: Date
        var lastObservedAt: Date
        var model: String?
        var outputTokens: Int?
        var liveTPS: Double?
        var endedAt: Date?
        var endStatus: ObservedRequestStatus?
        var counterBaseline: CounterObservation?
        var latestCounter: CounterObservation?

        var sampledAverageTPS: Double? {
            guard let counterBaseline, let latestCounter,
                latestCounter.count >= counterBaseline.count
            else { return nil }
            let duration = latestCounter.timestamp.timeIntervalSince(counterBaseline.timestamp)
            guard duration.isFinite, duration > 0 else { return nil }
            let rate = Double(latestCounter.count - counterBaseline.count) / duration
            return rate.isFinite && rate >= 0 ? rate : nil
        }

        mutating func observeCounter(_ count: Int, at date: Date) {
            guard latestCounter.map({ date >= $0.timestamp }) ?? true else { return }
            let observation = CounterObservation(count: count, timestamp: date)
            // Studio can correct usage without replacing the request identity.
            if counterBaseline == nil || latestCounter.map({ count < $0.count }) == true {
                counterBaseline = observation
            }
            latestCounter = observation
        }

        func lane(source: RequestObservationSource) -> RequestLane {
            RequestLane(
                id: id, startedAt: startedAt, endedAt: endedAt, model: model,
                outputTokens: outputTokens ?? 0, outputIsEstimated: outputTokens == nil,
                liveTPS: liveTPS ?? 0, terminal: endStatus != nil,
                observationSource: source, endStatus: endStatus,
                sampledAverageTPS: sampledAverageTPS)
        }
    }

    private struct ProviderEpoch: Hashable {
        let source: RequestObservationSource
        let epoch: UUID
    }

    private let freshnessInterval: TimeInterval
    private let retentionInterval: TimeInterval
    private let capacity: Int
    private var source: RequestObservationSource?
    private var sourceEpoch: UUID?
    private var providerEpochs: [RequestObservationSource: UUID] = [:]
    private var retiredEpochs: [ProviderEpoch] = []
    private var records: [String: Record] = [:]
    private var earlierObservations: [Record] = []
    private var lastSnapshotAt: Date?

    init(
        freshnessInterval: TimeInterval = 5, retentionInterval: TimeInterval = 3600,
        capacity: Int = 256
    ) {
        self.freshnessInterval = freshnessInterval
        self.retentionInterval = retentionInterval
        self.capacity = max(1, capacity)
    }

    mutating func reset() {
        source = nil
        sourceEpoch = nil
        providerEpochs.removeAll(keepingCapacity: true)
        retiredEpochs.removeAll(keepingCapacity: true)
        records.removeAll(keepingCapacity: true)
        earlierObservations.removeAll(keepingCapacity: true)
        lastSnapshotAt = nil
    }

    /// Nil leaves identities intact until their own freshness expires. Only a
    /// complete snapshot can establish that an omitted request is no longer seen.
    mutating func apply(_ snapshot: NativeRequestSnapshot?, at date: Date) {
        guard date.timeIntervalSince1970.isFinite,
            lastSnapshotAt.map({ date >= $0 }) ?? true
        else { return }
        guard let snapshot else {
            lastSnapshotAt = date
            advance(at: date)
            return
        }
        guard snapshot.source != .protocolStream else { return }
        let provider = ProviderEpoch(source: snapshot.source, epoch: snapshot.sourceEpoch)
        guard !retiredEpochs.contains(provider) else { return }
        lastSnapshotAt = date
        if source != snapshot.source || sourceEpoch != snapshot.sourceEpoch {
            if let previous = providerEpochs[snapshot.source], previous != snapshot.sourceEpoch {
                retiredEpochs.append(ProviderEpoch(source: snapshot.source, epoch: previous))
                // Epoch replay protection is bounded independently of lane retention.
                if retiredEpochs.count > 64 { retiredEpochs.removeFirst() }
            }
            providerEpochs[snapshot.source] = snapshot.sourceEpoch
            source = snapshot.source
            sourceEpoch = snapshot.sourceEpoch
            // Provider coverage overlaps: retaining both would draw duplicate bars.
            records.removeAll(keepingCapacity: true)
            earlierObservations.removeAll(keepingCapacity: true)
        }

        var observations: [String: NativeRequestObservation] = [:]
        for observation in snapshot.requests {
            guard !observation.id.isEmpty, observation.id.utf8.count <= 512 else { continue }
            // A terminal copy wins over a running duplicate in a monitor response.
            if let previous = observations[observation.id], previous.status != .running,
                observation.status == .running
            {
                continue
            }
            observations[observation.id] = observation
        }
        for (key, observation) in observations {
            if var previous = records[key], observation.status == .running {
                let counterRestarted =
                    snapshot.source == .slotPolling
                    && previous.endStatus == nil
                    && observation.outputTokens.map { count in
                        count >= 0 && previous.outputTokens.map { count < $0 } == true
                    } == true
                if previous.endStatus == .observationEnded || counterRestarted {
                    if counterRestarted {
                        previous.endStatus = .observationEnded
                        previous.endedAt = date
                    }
                    earlierObservations.append(previous)
                    records.removeValue(forKey: key)
                }
            }
            var record = records[key] ?? makeRecord(observation, at: date)
            // Explicit terminal evidence cannot be undone by replayed running rows.
            if record.endStatus != nil, record.endStatus != .observationEnded,
                observation.status == .running
            {
                continue
            }
            let wasExplicitlyTerminal =
                record.endStatus != nil && record.endStatus != .observationEnded
            record.lastObservedAt = date
            record.model = observation.model ?? record.model
            if let count = observation.outputTokens, count >= 0 {
                record.outputTokens = count
                if !wasExplicitlyTerminal {
                    // The first terminal counter is one final observation. Replayed
                    // history, idle detection, and expiry cannot extend this window.
                    record.observeCounter(count, at: date)
                }
            }
            record.liveTPS = observation.liveTPS.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            if observation.status != .running {
                record.endStatus = observation.status
                record.endedAt =
                    validEnd(observation.endedAt, start: record.startedAt, now: date)
                    ?? record.endedAt ?? date
            }
            records[key] = record
        }
        if snapshot.isComplete {
            for key in records.keys where observations[key] == nil && records[key]?.endStatus == nil
            {
                records[key]?.endStatus = .observationEnded
                records[key]?.endedAt = date
            }
        }
        advance(at: date)
    }

    /// Health and aggregate activity polls cannot refresh identity observation.
    mutating func advance(at date: Date) {
        guard date.timeIntervalSince1970.isFinite else { return }
        for key in records.keys {
            guard var record = records[key], record.endStatus == nil,
                date.timeIntervalSince(record.lastObservedAt) > freshnessInterval
            else { continue }
            record.endStatus = .observationEnded
            record.endedAt = record.lastObservedAt.addingTimeInterval(freshnessInterval)
            records[key] = record
        }
        let cutoff = date.addingTimeInterval(-retentionInterval)
        records = records.filter { $0.value.endedAt.map { $0 >= cutoff } ?? true }
        earlierObservations.removeAll { $0.endedAt.map { $0 < cutoff } ?? false }
        let excess = records.count + earlierObservations.count - capacity
        guard excess > 0 else { return }
        // Drop old terminal observations before active identities under a burst.
        let candidates = (Array(records.values) + earlierObservations)
            .sorted {
                if ($0.endStatus == nil) != ($1.endStatus == nil) {
                    return $0.endStatus != nil
                }
                if $0.lastObservedAt != $1.lastObservedAt {
                    return $0.lastObservedAt < $1.lastObservedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        let evicted = Set(candidates.prefix(excess).map(\.id))
        records = records.filter { !evicted.contains($0.value.id) }
        earlierObservations.removeAll { evicted.contains($0.id) }
    }

    func lanes(at date: Date) -> [RequestLane] {
        guard let source else { return [] }
        let cutoff = date.addingTimeInterval(-retentionInterval)
        return (Array(records.values) + earlierObservations).map { $0.lane(source: source) }
            .filter { $0.isVisible(at: cutoff) }
            .sorted {
                $0.startedAt == $1.startedAt
                    ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
            }
    }

    private func makeRecord(_ observation: NativeRequestObservation, at date: Date) -> Record {
        let start =
            observation.startedAt.flatMap {
                $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 0 && $0 <= date
                    ? $0 : nil
            } ?? date
        return Record(
            startedAt: start, lastObservedAt: date, model: observation.model,
            outputTokens: nil, liveTPS: nil)
    }

    private func validEnd(_ end: Date?, start: Date, now: Date) -> Date? {
        end.flatMap { $0.timeIntervalSince1970.isFinite && $0 >= start && $0 <= now ? $0 : nil }
    }
}
