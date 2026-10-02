import Foundation

/// Data-only normalization shared by every consumer of one immutable publication.
/// Viewports, coverage, request caps and receipt-timed rail state remain host-owned.
/// This object never retains its source snapshot or a previous publication.
final class SharedChartPresentationMetadata: Sendable {
    let requestLanes: [RequestLane]
    let requiresLegacyLaneSelection: Bool
    let toolEvents: [ToolActivityEvent]
    let knownToolRequestIDs: Set<UUID>

    init(snapshot: ChartPresentationSnapshot) {
        PerformancePresentationCounters.shared.record(.sharedChartNormalizationBuilds)
        func nonfiniteBoundary(_ lane: RequestLane) -> Bool {
            !lane.startedAt.timeIntervalSince1970.isFinite
                || !(lane.endedAt?.timeIntervalSince1970.isFinite ?? true)
        }
        requiresLegacyLaneSelection =
            snapshot.historicalRequestLanes.contains(where: nonfiniteBoundary)
            || snapshot.requestLanes.contains(where: nonfiniteBoundary)
        if requiresLegacyLaneSelection {
            // Foundation Date comparisons with NaN differ from raw Double
            // comparisons. Preserve every winner and let the original viewport
            // path apply its Date predicates before sorting, exactly as before.
            var byID: [UUID: RequestLane] = [:]
            for lane in snapshot.historicalRequestLanes { byID[lane.id] = lane }
            for lane in snapshot.requestLanes { byID[lane.id] = lane }
            requestLanes = Array(byID.values)
        } else {
            requestLanes = Self.mergeWinners(
                historical: snapshot.historicalRequestLanes, current: snapshot.requestLanes,
                identity: { $0.id }, retain: { _ in true },
                before: {
                    $0.startedAt == $1.startedAt
                        ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
                })
        }

        var known = snapshot.toolActivityRequestIDs ?? []
        let deriveKnown = snapshot.toolActivityRequestIDs == nil
        toolEvents = Self.mergeWinners(
            historical: snapshot.historicalToolActivity, current: snapshot.toolActivity,
            identity: { $0.id },
            retain: { event in
                // Ownership survives invalid/future corrections and frozen views
                // before the winning event. Caller-supplied ownership stays exact.
                if deriveKnown, let requestID = event.requestID { known.insert(requestID) }
                return event.timestamp.timeIntervalSince1970.isFinite
            },
            before: { $0.timestamp < $1.timestamp })
        knownToolRequestIDs = known
    }

    /// Future winners stay in the shared data so each host can independently
    /// select its inclusive endpoint without repeating identity resolution.
    func toolEvents(through end: Date) -> [ToolActivityEvent] {
        if !end.timeIntervalSince1970.isFinite {
            return toolEvents.filter { $0.timestamp <= end }
        }
        guard let last = toolEvents.last else { return [] }
        if last.timestamp <= end { return toolEvents }
        var low = 0
        var high = toolEvents.count
        while low < high {
            let middle = (low + high) / 2
            if toolEvents[middle].timestamp <= end {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return Array(toolEvents[..<low])
    }

    private static func mergeWinners<Element>(
        historical: [Element], current: [Element], identity: (Element) -> UUID,
        retain: (Element) -> Bool, before: (Element, Element) -> Bool
    ) -> [Element] {
        var winners: [UUID: Int] = [:]
        winners.reserveCapacity(max(historical.count, current.count))
        for (index, value) in historical.enumerated() { winners[identity(value)] = index }
        var historicalCount = winners.count
        for (index, value) in current.enumerated() {
            if let previous = winners.updateValue(
                historical.count + index, forKey: identity(value)),
                previous < historical.count
            {
                historicalCount -= 1
            }
        }

        func survivors(_ source: [Element], offset: Int, capacity: Int)
            -> (values: [Element], ordered: Bool)
        {
            var values: [Element] = []
            values.reserveCapacity(capacity)
            var ordered = true
            for (index, value) in source.enumerated() {
                guard winners[identity(value)] == offset + index, retain(value) else { continue }
                if let previous = values.last, before(value, previous) { ordered = false }
                values.append(value)
            }
            return (values, ordered)
        }
        let saved = survivors(historical, offset: 0, capacity: historicalCount)
        let live = survivors(
            current, offset: historical.count, capacity: winners.count - historicalCount)
        guard saved.ordered && live.ordered else {
            // Imported and test inputs need not follow production ingestion order.
            // Preserve source order for distinct events with equal timestamps.
            return (saved.values + live.values).enumerated().sorted {
                if before($0.element, $1.element) { return true }
                if before($1.element, $0.element) { return false }
                return $0.offset < $1.offset
            }.map(\.element)
        }
        if saved.values.isEmpty { return live.values }
        if live.values.isEmpty { return saved.values }
        var result: [Element] = []
        result.reserveCapacity(saved.values.count + live.values.count)
        var savedIndex = 0
        var liveIndex = 0
        while savedIndex < saved.values.count && liveIndex < live.values.count {
            if before(live.values[liveIndex], saved.values[savedIndex]) {
                result.append(live.values[liveIndex])
                liveIndex += 1
            } else {
                result.append(saved.values[savedIndex])
                savedIndex += 1
            }
        }
        result.append(contentsOf: saved.values[savedIndex...])
        result.append(contentsOf: live.values[liveIndex...])
        return result
    }
}
