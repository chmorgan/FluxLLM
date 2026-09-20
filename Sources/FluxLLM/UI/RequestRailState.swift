import Foundation

struct RequestRailAssignment: Sendable, Equatable {
    let track: Int
    let colorIndex: Int
}

struct RequestRailEvent: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Hashable {
        case arrival
        case completion
    }

    struct ID: Sendable, Hashable {
        let requestID: UUID
        let kind: Kind
    }

    let requestID: UUID
    let kind: Kind
    /// Receipt time, independent of the timestamp held by the chart publication.
    let startedAt: Date
    let seed: UInt64

    var id: ID { ID(requestID: requestID, kind: kind) }
    var duration: TimeInterval { kind == .arrival ? 0.8 : 2.8 }
    var expiresAt: Date { startedAt.addingTimeInterval(duration) }
}

struct RequestRailPresentation: Sendable, Equatable {
    let assignments: [UUID: RequestRailAssignment]
    let events: [RequestRailEvent]

    static let empty = RequestRailPresentation(assignments: [:], events: [])
}

/// UI-owned identity and lifecycle state. Feed full publications, before chart-range filtering.
/// Allocation is independent of rendering time: existing requests never change tracks or colors.
final class RequestRailState {
    static let individualTrackCount = 5
    static let overflowTrack = individualTrackCount
    /// The telemetry store retains at most 256 finished requests. Keep twice that many
    /// absent identities too, so temporary empty snapshots and range changes stay stable.
    static let retainedAbsentLimit = 512

    private struct Record {
        let assignment: RequestRailAssignment
        let startedAt: Date
        var endedAt: Date?
        var terminal: Bool
        var lastSeen: UInt64
    }

    private var records: [UUID: Record] = [:]
    private var events: [RequestRailEvent] = []
    private var nextColorIndex = 0
    private var observation: UInt64 = 0
    private var newestSnapshotTime: Date?

    func update(
        lanes: [RequestLane], snapshotTime: Date, presentedAt: Date
    ) -> RequestRailPresentation {
        observation &+= 1
        events.removeAll { $0.expiresAt <= presentedAt }

        // Snapshot order can vary, including requests with identical start timestamps.
        let ordered = lanes.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let currentIDs = Set(ordered.map(\.id))
        let previousSnapshotTime = newestSnapshotTime

        // Close every known interval before allocating newcomers. A completion and
        // replacement in the same publication can therefore share an exact endpoint.
        for lane in ordered {
            guard var record = records[lane.id] else { continue }
            let terminal = lane.terminal || lane.endedAt != nil
            if !record.terminal, terminal,
                let endedAt = lane.endedAt,
                isFresh(endedAt, snapshotTime: snapshotTime, after: previousSnapshotTime)
            {
                emit(lane.id, kind: .completion, at: presentedAt)
            }
            // A historical publication must not reopen an already completed request.
            if record.endedAt == nil, let endedAt = lane.endedAt {
                record.endedAt = max(record.startedAt, endedAt)
            } else if record.endedAt == nil, terminal {
                record.endedAt = max(record.startedAt, snapshotTime)
            }
            record.terminal = record.terminal || terminal
            record.lastSeen = observation
            records[lane.id] = record
        }

        for lane in ordered where records[lane.id] == nil {
            let terminal = lane.terminal || lane.endedAt != nil
            let end =
                lane.endedAt.map { max(lane.startedAt, $0) }
                ?? (terminal ? max(lane.startedAt, snapshotTime) : nil)
            let track =
                (0..<Self.individualTrackCount).first { candidate in
                    records.values.allSatisfy { record in
                        record.assignment.track != candidate
                            || !Self.overlaps(
                                lane.startedAt, end, record.startedAt, record.endedAt)
                    }
                } ?? Self.overflowTrack
            records[lane.id] = Record(
                assignment: RequestRailAssignment(track: track, colorIndex: nextColorIndex),
                startedAt: lane.startedAt, endedAt: end, terminal: terminal,
                lastSeen: observation)
            nextColorIndex += 1

            if terminal {
                // Requests shorter than a publication interval have no observed arrival.
                if let endedAt = lane.endedAt,
                    isFresh(endedAt, snapshotTime: snapshotTime, after: previousSnapshotTime)
                {
                    emit(lane.id, kind: .completion, at: presentedAt)
                }
            } else if isFresh(
                lane.startedAt, snapshotTime: snapshotTime, after: previousSnapshotTime)
            {
                emit(lane.id, kind: .arrival, at: presentedAt)
            }
        }

        newestSnapshotTime = max(newestSnapshotTime ?? snapshotTime, snapshotTime)
        trimAbsentRecords(keeping: currentIDs)
        return RequestRailPresentation(
            assignments: records.filter { currentIDs.contains($0.key) }.mapValues(\.assignment),
            events: events)
    }

    /// Half-open intervals permit reuse at an exact completion/start boundary. Check
    /// every retained interval rather than only a track's most recently observed end,
    /// because history may arrive out of chronological order.
    private static func overlaps(
        _ start: Date, _ end: Date?, _ otherStart: Date, _ otherEnd: Date?
    ) -> Bool {
        if let end, end <= start { return false }
        if let otherEnd, otherEnd <= otherStart { return false }
        return start < (otherEnd ?? .distantFuture) && otherStart < (end ?? .distantFuture)
    }

    private func isFresh(_ time: Date, snapshotTime: Date, after previous: Date?) -> Bool {
        // Initial history seeds silently. The monotonic watermark also keeps evicted
        // identities and older range snapshots from replaying historical events.
        // Equality permits callbacks sharing a coarse publication timestamp; identity
        // and terminal-state tracking still prevent duplicate lifecycle effects.
        guard let previous, snapshotTime >= previous, time >= previous else { return false }
        let age = snapshotTime.timeIntervalSince(time)
        return age >= 0 && age <= 2
    }

    private func emit(_ requestID: UUID, kind: RequestRailEvent.Kind, at date: Date) {
        // FNV-1a is deterministic across launches, unlike Swift's randomized Hasher.
        // Rendering can derive distinct, repeatable random choices from this seed.
        var seed: UInt64 = 14_695_981_039_346_656_037
        for byte in requestID.uuidString.utf8 {
            seed = (seed ^ UInt64(byte)) &* 1_099_511_628_211
        }
        seed = (seed ^ (kind == .arrival ? 0 : 1)) &* 1_099_511_628_211
        events.append(
            RequestRailEvent(requestID: requestID, kind: kind, startedAt: date, seed: seed))
    }

    private func trimAbsentRecords(keeping currentIDs: Set<UUID>) {
        let absent = records.filter { !currentIDs.contains($0.key) }.sorted {
            if $0.value.lastSeen != $1.value.lastSeen {
                return $0.value.lastSeen < $1.value.lastSeen
            }
            return $0.value.assignment.colorIndex < $1.value.assignment.colorIndex
        }
        for (id, _) in absent.prefix(max(0, absent.count - Self.retainedAbsentLimit)) {
            records.removeValue(forKey: id)
        }
    }
}
