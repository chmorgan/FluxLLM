import Foundation

/// A chart publication is immutable, so all consumers can share its prepared averages.
final class PreparedDashboardCharts {
    let publicationID: UUID
    let duration: TimeInterval
    let windowEnd: Date
    let isLive: Bool
    let optimized: Bool
    let throughput: ChartDisplayHistory
    let gpu: ChartDisplayHistory
    let toolActivity: ToolActivityHistory?
    let lanes: [RequestLane]
    let laneColorIndex: [UUID: Int]
    let requestRails: RequestRailPresentation
    let requestTools: [UUID: ToolActivityHistory]
    let omittedRequestCount: Int

    struct LaneSelection {
        let rendered: [RequestLane]
        let omittedCount: Int
    }

    init(
        snapshot: ChartPresentationSnapshot, duration: TimeInterval,
        requestRails: RequestRailPresentation? = nil, windowEnd: Date? = nil, isLive: Bool = true,
        optimized: Bool = false, laneSelection: LaneSelection? = nil
    ) {
        PerformancePresentationCounters.shared.record(.chartPreparations)
        if optimized { PerformancePresentationCounters.shared.record(.optimizedChartPreparations) }
        publicationID = snapshot.publicationID
        self.duration = duration
        let end = min(windowEnd ?? snapshot.timestamp, snapshot.timestamp)
        self.windowEnd = end
        self.isLive = isLive
        self.optimized = optimized
        throughput = ChartDisplayHistory(
            samples: snapshot.throughput, now: end, duration: duration,
            archivedSegments: snapshot.archive.throughput)
        gpu = ChartDisplayHistory(
            samples: GPUActivityPresentation.chartSamples(snapshot.systemGPU),
            now: end, duration: duration, archivedSegments: snapshot.archive.systemGPU)
        let events: [ToolActivityEvent]
        let knownToolRequests: Set<UUID>
        if optimized {
            let tools = PreparedDashboardToolEvents(snapshot: snapshot, through: end)
            events = tools.events
            knownToolRequests = tools.knownRequestIDs
        } else {
            var eventsByID: [UUID: ToolActivityEvent] = [:]
            for event in snapshot.historicalToolActivity + snapshot.toolActivity {
                eventsByID[event.id] = event
            }
            events = ToolActivityHistory.normalizedEvents(Array(eventsByID.values), through: end)
            knownToolRequests =
                snapshot.toolActivityRequestIDs
                ?? Set(eventsByID.values.compactMap(\.requestID))
        }
        let toolObservation = ToolActivityObservation(
            observations: snapshot.toolObservation, now: end, duration: duration,
            archivedSegments: snapshot.archive.toolObservation)
        toolActivity =
            snapshot.supportsToolActivity
            ? ToolActivityHistory(preparedEvents: events, observation: toolObservation)
            : nil

        // A retained allocator keeps request identity separate from the reused
        // track. Range changes and history expiry never renumber existing hues.
        let rendered: [RequestLane]
        if optimized {
            let selection =
                laneSelection
                ?? Self.optimizedLaneSelection(snapshot: snapshot, end: end, duration: duration)
            rendered = selection.rendered
            omittedRequestCount = selection.omittedCount
        } else {
            let visible = Self.visibleLanes(snapshot: snapshot, end: end, duration: duration)
            rendered = Self.renderedLanes(visible)
            omittedRequestCount = visible.count - rendered.count
        }
        lanes = rendered
        let rails =
            requestRails
            ?? RequestRailState().update(
                lanes: rendered, snapshotTime: snapshot.timestamp, presentedAt: snapshot.timestamp)
        self.requestRails = rails
        laneColorIndex = rails.assignments.mapValues(\.colorIndex)

        // Split the tool track into a per-request history so each request's
        // dashes and result diamonds take that request's lane color.
        var grouped: [UUID: [ToolActivityEvent]] = [:]
        let renderedIDs = Set(rendered.map(\.id))
        // A frozen window can precede a request's first tool event. Keep its
        // empty overlay (and observed zero-rate spans) just as in live history.
        for id in knownToolRequests where renderedIDs.contains(id) { grouped[id] = [] }
        for event in events {
            guard let id = event.requestID, renderedIDs.contains(id) else { continue }
            grouped[id, default: []].append(event)
        }
        requestTools =
            grouped.mapValues {
                ToolActivityHistory(preparedEvents: $0, observation: toolObservation)
            }
    }

    /// Select once for both rendering and retained rail lifecycles. The visible
    /// order already contains the start-time/identity ordering that drawing needs.
    static func optimizedLaneSelection(
        snapshot: ChartPresentationSnapshot, end: Date, duration: TimeInterval
    ) -> LaneSelection {
        var byID: [UUID: RequestLane] = [:]
        byID.reserveCapacity(
            max(snapshot.historicalRequestLanes.count, snapshot.requestLanes.count))
        for lane in snapshot.historicalRequestLanes { byID[lane.id] = lane }
        for lane in snapshot.requestLanes { byID[lane.id] = lane }
        let start = end.addingTimeInterval(-duration)
        let visible = byID.values.filter {
            $0.startedAt <= end && ($0.endedAt ?? snapshot.timestamp) >= start
        }.sorted {
            $0.startedAt == $1.startedAt
                ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
        let openCount = visible.reduce(0) {
            $0 + (!$1.terminal && $1.endedAt == nil ? 1 : 0)
        }
        let omittedCount = max(0, visible.count - max(256, openCount))
        var remainingToOmit = omittedCount
        let rendered = visible.filter { lane in
            if !lane.terminal && lane.endedAt == nil { return true }
            if remainingToOmit > 0 {
                remainingToOmit -= 1
                return false
            }
            return true
        }
        return LaneSelection(rendered: rendered, omittedCount: omittedCount)
    }

    static func renderedLanes(_ visible: [RequestLane]) -> [RequestLane] {
        let open = visible.filter { !$0.terminal && $0.endedAt == nil }
        let ended = visible.filter { $0.terminal || $0.endedAt != nil }
        // Never hide an active request behind a busy period of completed work.
        return (open + ended.suffix(max(0, 256 - open.count))).sorted {
            $0.startedAt == $1.startedAt
                ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
    }

    static func visibleLanes(
        snapshot: ChartPresentationSnapshot, end: Date, duration: TimeInterval
    ) -> [RequestLane] {
        var byID: [UUID: RequestLane] = [:]
        for lane in snapshot.historicalRequestLanes + snapshot.requestLanes { byID[lane.id] = lane }
        let start = end.addingTimeInterval(-duration)
        return byID.values.filter {
            $0.startedAt <= end && ($0.endedAt ?? snapshot.timestamp) >= start
        }.sorted {
            $0.startedAt == $1.startedAt
                ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
    }
}

/// Merge immutable source publications without discarding their usual timestamp
/// order. Winner indexes preserve corrections without copying event values into a
/// dictionary or deduplicating them a second time during normalization.
private struct PreparedDashboardToolEvents {
    let events: [ToolActivityEvent]
    let knownRequestIDs: Set<UUID>

    init(snapshot: ChartPresentationSnapshot, through end: Date) {
        let historical = snapshot.historicalToolActivity
        let current = snapshot.toolActivity
        var winnerIndexes: [UUID: Int] = [:]
        winnerIndexes.reserveCapacity(max(historical.count, current.count))
        for (index, event) in historical.enumerated() { winnerIndexes[event.id] = index }
        var historicalWinnerCount = winnerIndexes.count
        for (index, event) in current.enumerated() {
            if let previous = winnerIndexes.updateValue(historical.count + index, forKey: event.id),
                previous < historical.count
            {
                historicalWinnerCount -= 1
            }
        }

        var knownRequests = snapshot.toolActivityRequestIDs ?? []
        let deriveKnownRequests = snapshot.toolActivityRequestIDs == nil
        func survivors(
            _ source: [ToolActivityEvent], offset: Int, capacity: Int
        ) -> (events: [ToolActivityEvent], ordered: Bool) {
            var result: [ToolActivityEvent] = []
            result.reserveCapacity(capacity)
            var ordered = true
            for (index, event) in source.enumerated() {
                guard winnerIndexes[event.id] == offset + index else { continue }
                // Resolve winners before filtering: an invalid/future correction
                // suppresses the old copy, while still identifying its overlay.
                if deriveKnownRequests, let requestID = event.requestID {
                    knownRequests.insert(requestID)
                }
                guard event.timestamp.timeIntervalSince1970.isFinite, event.timestamp <= end else {
                    continue
                }
                if let previous = result.last, event.timestamp < previous.timestamp {
                    ordered = false
                }
                result.append(event)
            }
            return (result, ordered)
        }
        let saved = survivors(historical, offset: 0, capacity: historicalWinnerCount)
        let live = survivors(
            current, offset: historical.count, capacity: winnerIndexes.count - historicalWinnerCount
        )
        knownRequestIDs = knownRequests
        if saved.ordered && live.ordered {
            if saved.events.isEmpty {
                events = live.events
                return
            }
            if live.events.isEmpty {
                events = saved.events
                return
            }
            var merged: [ToolActivityEvent] = []
            merged.reserveCapacity(saved.events.count + live.events.count)
            var savedIndex = 0
            var liveIndex = 0
            while savedIndex < saved.events.count && liveIndex < live.events.count {
                // Equal timestamps retain source order, including historical
                // evidence before current evidence at the same instant.
                if saved.events[savedIndex].timestamp <= live.events[liveIndex].timestamp {
                    merged.append(saved.events[savedIndex])
                    savedIndex += 1
                } else {
                    merged.append(live.events[liveIndex])
                    liveIndex += 1
                }
            }
            merged.append(contentsOf: saved.events[savedIndex...])
            merged.append(contentsOf: live.events[liveIndex...])
            events = merged
        } else {
            // Imported/test publications can be unordered. Keep the same stable
            // timestamp normalization without assuming ingestion ordering.
            events = (saved.events + live.events).enumerated().sorted {
                $0.element.timestamp == $1.element.timestamp
                    ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp
            }.map(\.element)
        }
    }
}

/// Keeps history preparation publication-bound while request identities survive range changes.
final class DashboardChartPreparation {
    private var prepared: PreparedDashboardCharts?
    private var railState = RequestRailState()
    private var railPublicationID: UUID?
    private var railWindow: DateInterval?
    private var requestRails = RequestRailPresentation.empty
    private var monitoringEpoch: UUID?
    private let clock: () -> Date

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Release chart arrays when their host is hidden while keeping stable rail
    /// assignments and the request lifecycle state needed when it opens again.
    func releasePreparedCharts() {
        prepared = nil
    }

    func histories(
        snapshot: ChartPresentationSnapshot, duration: TimeInterval, epoch: UUID? = nil,
        windowEnd: Date? = nil, isLive: Bool? = nil, optimized: Bool = false
    ) -> PreparedDashboardCharts {
        let end = min(windowEnd ?? snapshot.timestamp, snapshot.timestamp)
        let followingLive = isLive ?? (windowEnd == nil)
        let window = DateInterval(start: end.addingTimeInterval(-duration), end: end)
        if monitoringEpoch != epoch {
            monitoringEpoch = epoch
            prepared = nil
            railState = RequestRailState()
            railPublicationID = nil
            railWindow = nil
            requestRails = .empty
        }
        if let prepared, prepared.publicationID == snapshot.publicationID,
            prepared.duration == duration, prepared.windowEnd == end,
            prepared.isLive == followingLive, prepared.optimized == optimized
        {
            return prepared
        }
        let selection =
            optimized
            ? PreparedDashboardCharts.optimizedLaneSelection(
                snapshot: snapshot, end: end, duration: duration) : nil
        if railPublicationID != snapshot.publicationID || railWindow != window {
            let rendered =
                selection?.rendered
                ?? PreparedDashboardCharts.renderedLanes(
                    PreparedDashboardCharts.visibleLanes(
                        snapshot: snapshot, end: end, duration: duration))
            var tracked = Dictionary(
                uniqueKeysWithValues: rendered.map { ($0.id, $0) })
            // Keep receiving current lifecycles while the viewport is pinned in
            // the past; otherwise an unseen completion could strand an open rail.
            for lane in snapshot.requestLanes { tracked[lane.id] = lane }
            requestRails = railState.update(
                lanes: Array(tracked.values), snapshotTime: snapshot.timestamp,
                presentedAt: clock())
            railPublicationID = snapshot.publicationID
            railWindow = window
        }
        let rails =
            !followingLive
            ? RequestRailPresentation(assignments: requestRails.assignments, events: [])
            : requestRails
        let prepared = PreparedDashboardCharts(
            snapshot: snapshot, duration: duration, requestRails: rails, windowEnd: end,
            isLive: followingLive, optimized: optimized, laneSelection: selection)
        self.prepared = prepared
        return prepared
    }
}
