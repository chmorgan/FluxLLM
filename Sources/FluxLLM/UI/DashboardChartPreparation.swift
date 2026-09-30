import Foundation

/// A chart publication is immutable, so all consumers can share its prepared averages.
final class PreparedDashboardCharts {
    let publicationID: UUID
    let duration: TimeInterval
    let windowEnd: Date
    let isLive: Bool
    let throughput: ChartDisplayHistory
    let gpu: ChartDisplayHistory
    let toolActivity: ToolActivityHistory?
    let lanes: [RequestLane]
    let laneColorIndex: [UUID: Int]
    let requestRails: RequestRailPresentation
    let requestTools: [UUID: ToolActivityHistory]
    let omittedRequestCount: Int

    init(
        snapshot: ChartPresentationSnapshot, duration: TimeInterval,
        requestRails: RequestRailPresentation? = nil, windowEnd: Date? = nil, isLive: Bool = true
    ) {
        PerformancePresentationCounters.shared.record(.chartPreparations)
        publicationID = snapshot.publicationID
        self.duration = duration
        let end = min(windowEnd ?? snapshot.timestamp, snapshot.timestamp)
        self.windowEnd = end
        self.isLive = isLive
        throughput = ChartDisplayHistory(
            samples: snapshot.throughput, now: end, duration: duration,
            archivedSegments: snapshot.archive.throughput)
        gpu = ChartDisplayHistory(
            samples: GPUActivityPresentation.chartSamples(snapshot.systemGPU),
            now: end, duration: duration, archivedSegments: snapshot.archive.systemGPU)
        var eventsByID: [UUID: ToolActivityEvent] = [:]
        for event in snapshot.historicalToolActivity + snapshot.toolActivity {
            eventsByID[event.id] = event
        }
        let events = ToolActivityHistory.normalizedEvents(Array(eventsByID.values), through: end)
        let toolObservation = ToolActivityObservation(
            observations: snapshot.toolObservation, now: end, duration: duration,
            archivedSegments: snapshot.archive.toolObservation)
        toolActivity =
            snapshot.supportsToolActivity
            ? ToolActivityHistory(preparedEvents: events, observation: toolObservation)
            : nil

        // A retained allocator keeps request identity separate from the reused
        // track. Range changes and history expiry never renumber existing hues.
        let visible = Self.visibleLanes(snapshot: snapshot, end: end, duration: duration)
        // Totals retain every request; bounded rails keep long busy periods responsive.
        let rendered = Self.renderedLanes(visible)
        lanes = rendered
        omittedRequestCount = visible.count - rendered.count
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
        let knownToolRequests =
            snapshot.toolActivityRequestIDs
            ?? Set(eventsByID.values.compactMap(\.requestID))
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
        windowEnd: Date? = nil, isLive: Bool? = nil
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
            prepared.isLive == followingLive
        {
            return prepared
        }
        if railPublicationID != snapshot.publicationID || railWindow != window {
            let lanes = PreparedDashboardCharts.visibleLanes(
                snapshot: snapshot, end: end, duration: duration)
            var tracked = Dictionary(
                uniqueKeysWithValues:
                    PreparedDashboardCharts.renderedLanes(lanes).map { ($0.id, $0) })
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
            isLive: followingLive)
        self.prepared = prepared
        return prepared
    }
}
