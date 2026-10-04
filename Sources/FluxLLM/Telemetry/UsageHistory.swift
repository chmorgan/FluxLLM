import Foundation

public enum UsageScope: String, CaseIterable, Identifiable, Sendable {
    case sinceLaunch
    case selectedPeriod
    case today

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sinceLaunch: "Since launch"
        case .selectedPeriod: "Selected period"
        case .today: "Today"
        }
    }
}

public struct UsageSummary: Sendable, Equatable {
    /// A known subtotal when some requests have unknown input usage; nil when
    /// none of the requests reported input usage. Empty scopes return zero.
    public let inputTokens: Int?
    public let unknownInputRequests: Int
    public let outputTokens: Int
    public let outputIsEstimated: Bool
    public let toolCalls: Int
    public let requests: Int
    public let activeRequests: Int
    public let isPartial: Bool
}

/// Request usage is independent of the chart's viewport and sample retention.
/// Session-only counts and metadata. No request or tool payload is retained.
/// Exact event timestamps preserve half-open selected-period accounting.
@MainActor
public final class UsageHistory {
    public private(set) var persistenceError: String?
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private let metadata = UsageMetadata()
    private var sourceIDs: [String: Int] = [:]
    private let calendar: Calendar
    private let recordLimit: Int
    private let toolEventLimit: Int
    private var records: [RequestKey: UsageRequestRecord] = [:]
    private var tools: [ToolKey: UsageToolRecord] = [:]
    private var retainedToolEventCounts: [RequestKey: Int] = [:]
    private var launchTotals: [Int: UsageTotals] = [:]
    private var requestTruncatedThrough: [Int: Date] = [:]
    private var toolTruncatedThrough: [Int: Date] = [:]
    private var incompleteLaunchSources: Set<Int> = []
    // Queries reuse ordering until an insertion/removal changes it. Live token
    // updates do not invalidate order, and completed history is never sorted at 1 Hz.
    private var activeRequests: Set<RequestKey> = []
    private var completedOrder: [RequestKey] = []
    private var completedOrderIsDirty = true
    private var completedTotals: [AccountingBucket: UsageTotals] = [:]
    private var toolCallTotals: [AccountingBucket: Int] = [:]
    private var toolOrder: [ToolKey] = []
    private var toolOrderIsDirty = true
    /// Scalar work evidence; no event payloads or historical query results retained.
    private(set) var completedOrderBuildCount: UInt64 = 0
    private(set) var toolOrderBuildCount: UInt64 = 0
    private(set) var completedOrderIncrementalInsertCount: UInt64 = 0
    private(set) var toolOrderIncrementalInsertCount: UInt64 = 0
    private var cachedToolOwners: ToolOwnerQueryCache?
    /// Counts visited event records, excluding binary-search probes, so regression
    /// checks can distinguish a rolling query from rescanning the retained day.
    private(set) var toolOwnerQueryVisitedEvents: UInt64 = 0
    private var revision: UInt64 = 0
    private var cachedSummary: (SummaryKey, UsageSummary)?
    private var latestDate: Date
    private var lastPrunedAt: Date?

    public init(
        directory: URL? = nil, now: Date = Date(), calendar: Calendar = .current,
        recordLimit: Int = 20_000, toolEventLimit: Int = 50_000
    ) {
        // Kept for source compatibility; old files are intentionally untouched.
        _ = directory
        self.calendar = calendar
        self.recordLimit = max(1, recordLimit)
        self.toolEventLimit = max(1, toolEventLimit)
        latestDate = now
    }

    /// Release only rebuildable query storage when no chart is presented.
    /// Collection, accounting, retention and previously returned values are unchanged;
    /// the next query reconstructs the ordering it needs from authoritative records.
    public func releaseQueryCaches() {
        completedOrder.removeAll(keepingCapacity: false)
        completedOrderIsDirty = true
        toolOrder.removeAll(keepingCapacity: false)
        toolOrderIsDirty = true
        // The rolling cache's ranges refer to the released tool ordering.
        cachedToolOwners = nil
    }

    /// Scalar storage diagnostic; reading it never prepares or copies a cache.
    var cachedQueryEntryCount: Int {
        completedOrder.count + toolOrder.count
            + (cachedToolOwners?.counts.count ?? 0) + (cachedToolOwners?.owners.count ?? 0)
    }

    public func apply(_ event: GenerationEvent, source: String, at date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        latestDate = max(latestDate, date)
        let source = sourceID(for: source)
        switch event {
        case .began(let request):
            guard request.startedAt.timeIntervalSinceReferenceDate.isFinite else { return }
            let key = RequestKey(source: source, id: request.id)
            guard records[key] == nil else { return }
            // Once a bounded history has forgotten an identity, old deliveries
            // cannot reintroduce that request and count it twice.
            guard request.startedAt >= latestDate.addingTimeInterval(-Self.retentionInterval),
                requestTruncatedThrough[source].map({ request.startedAt > $0 }) ?? true
            else {
                incompleteLaunchSources.insert(source)
                return
            }
            let record = UsageRequestRecord(
                startedAt: request.startedAt, lastUpdatedAt: request.startedAt,
                modelID: metadata.retain(request.model))
            records[key] = record
            activeRequests.insert(key)
            updateLaunchTotals(source: source, removing: nil, adding: record)
        case .updated(let id, let snapshot):
            let key = RequestKey(source: source, id: id)
            guard snapshot.timestamp.timeIntervalSinceReferenceDate.isFinite,
                let old = records[key], snapshot.timestamp >= old.lastUpdatedAt
            else { return }
            let terminal = snapshot.finished || snapshot.error != nil
            // Terminal usage can correct an estimate (including downwards), but
            // delayed live snapshots must never reopen a completed request.
            if old.endedAt != nil {
                guard terminal, old.outputIsEstimated, !snapshot.isEstimated else { return }
            }
            var record = old
            record.lastUpdatedAt = snapshot.timestamp
            if let model = snapshot.model, model != metadata[record.modelID] {
                metadata.release(record.modelID)
                record.modelID = metadata.retain(model)
            }
            record.outputTokens = max(0, snapshot.outputTokens)
            record.outputIsEstimated = snapshot.isEstimated
            if let input = snapshot.promptTokens { record.inputTokens = max(0, input) }
            if !terminal && snapshot.liveTPS.isFinite {
                record.liveTPS = max(0, snapshot.liveTPS)
            }
            let newlyCompleted = terminal && record.endedAt == nil
            if newlyCompleted {
                record.endedAt = max(record.startedAt, snapshot.timestamp)
                activeRequests.remove(key)
            }
            records[key] = record
            if newlyCompleted { insertCompletedOrder(key, endedAt: record.endedAt!) }
            updateLaunchTotals(source: source, removing: old, adding: record)
        case .failed(let id, _), .cancelled(let id):
            finish(RequestKey(source: source, id: id), at: date)
        case .toolActivity(let id, let events):
            let requestKey = RequestKey(source: source, id: id)
            guard let request = records[requestKey] else { return }
            for event in events {
                guard event.timestamp.timeIntervalSinceReferenceDate.isFinite,
                    event.timestamp >= request.startedAt
                else { continue }
                guard event.timestamp >= latestDate.addingTimeInterval(-Self.retentionInterval),
                    toolTruncatedThrough[source].map({ event.timestamp > $0 }) ?? true
                else {
                    incompleteLaunchSources.insert(source)
                    continue
                }
                let callID = metadata.retain(event.callID)
                let key = ToolKey(
                    request: requestKey, isCall: event.kind == .call,
                    identity: callID >= 0 ? .call(callID) : .event(event.id))
                guard tools[key] == nil else {
                    metadata.release(callID)
                    continue
                }
                tools[key] = UsageToolRecord(
                    id: event.id, nameID: metadata.retain(event.name), timestamp: event.timestamp)
                retainedToolEventCounts[requestKey, default: 0] += 1
                insertToolOrder(key, timestamp: event.timestamp)
                if event.kind == .call {
                    launchTotals[source, default: UsageTotals()].toolCalls += 1
                    toolCallTotals[
                        AccountingBucket(source: source, date: event.timestamp), default: 0] += 1
                }
            }
        }
        prune(at: latestDate)
        revision &+= 1
    }

    public func finishOpenRequests(source: String, at date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        latestDate = max(latestDate, date)
        guard let source = sourceIDs[source] else { return }
        let keys = activeRequests.filter { $0.source == source }
        for key in keys { finish(key, at: date) }
        prune(at: latestDate)
        revision &+= 1
    }

    /// Selected-period requests belong to the interval in which they ended.
    /// Intervals are half-open [start, end), so adjacent periods never double
    /// count a request or tool call. Today also includes live requests that
    /// began today; their estimates are replaced when final usage arrives.
    public func summary(
        scope: UsageScope, source: String, interval: DateInterval, now: Date
    ) -> UsageSummary {
        let source = sourceIDs[source] ?? -1
        if scope == .sinceLaunch {
            return launchTotals[source, default: UsageTotals()].summary(
                isPartial: incompleteLaunchSources.contains(source))
        }
        let range: DateInterval
        switch scope {
        case .sinceLaunch:
            range = interval
        case .selectedPeriod:
            range = interval
        case .today:
            range =
                calendar.dateInterval(of: .day, for: now)
                ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        }
        let key = SummaryKey(
            scope: scope, source: source, start: range.start, end: range.end,
            revision: revision,
            retentionExpired: range.start < now.addingTimeInterval(-Self.retentionInterval))
        if let cachedSummary, cachedSummary.0 == key { return cachedSummary.1 }
        let fullStart = Date(
            timeIntervalSinceReferenceDate: (range.start.timeIntervalSinceReferenceDate / 3600)
                .rounded(.up) * 3600)
        let fullEnd = Date(
            timeIntervalSinceReferenceDate: (range.end.timeIntervalSinceReferenceDate / 3600)
                .rounded(.down) * 3600)
        var total = UsageTotals()
        if fullStart < fullEnd {
            for (bucket, value) in completedTotals
            where bucket.source == source && bucket.start >= fullStart && bucket.start < fullEnd {
                total.include(value)
            }
            for (bucket, count) in toolCallTotals
            where bucket.source == source && bucket.start >= fullStart && bucket.start < fullEnd {
                total.toolCalls += count
            }
            addBoundaryUsage(
                source: source, interval: DateInterval(start: range.start, end: fullStart),
                to: &total)
            addBoundaryUsage(
                source: source, interval: DateInterval(start: fullEnd, end: range.end), to: &total)
        } else {
            addBoundaryUsage(source: source, interval: range, to: &total)
        }
        if scope == .today {
            for key in activeRequests where key.source == source {
                if let record = records[key], contains(range, record.startedAt) {
                    total.include(record)
                }
            }
        }
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        let partial =
            range.start < cutoff
            || requestTruncatedThrough[source].map { range.start <= $0 } == true
            || toolTruncatedThrough[source].map { range.start <= $0 } == true
        let result = total.summary(isPartial: partial)
        cachedSummary = (key, result)
        return result
    }

    public func requestLanes(
        source: String, interval: DateInterval, inclusiveEnd: Bool = false
    ) -> [RequestLane] {
        guard let source = sourceIDs[source] else { return [] }
        prepareCompletedOrder()
        // Completion order skips requests that ended before the viewport while
        // retaining long-running requests that began before its lower boundary.
        let first = lowerBound(completedOrder.count) {
            records[completedOrder[$0]]!.endedAt! < interval.start
        }
        var result: [RequestLane] = []
        func appendLane(_ key: RequestKey) {
            guard key.source == source, let record = records[key],
                record.startedAt < interval.end
                    || (inclusiveEnd && record.startedAt == interval.end)
            else { return }
            result.append(record.lane(id: key.id, model: metadata[record.modelID]))
        }
        for key in completedOrder[first...] { appendLane(key) }
        for key in activeRequests { appendLane(key) }
        return result.sorted {
            $0.startedAt == $1.startedAt
                ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
    }

    public func toolEvents(
        source: String, interval: DateInterval, inclusiveEnd: Bool = false
    ) -> [ToolActivityEvent] {
        guard let source = sourceIDs[source] else { return [] }
        prepareToolOrder()
        // Find the visible suffix without materializing all retained events.
        var low = 0
        var high = toolOrder.count
        while low < high {
            let middle = (low + high) / 2
            if tools[toolOrder[middle]]!.timestamp < interval.start {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var result: [ToolActivityEvent] = []
        for key in toolOrder[low...] {
            guard let record = tools[key] else { continue }
            if inclusiveEnd ? record.timestamp > interval.end : record.timestamp >= interval.end {
                break
            }
            if key.request.source == source {
                result.append(
                    ToolActivityEvent(
                        id: record.id, kind: key.isCall ? .call : .resultSubmission,
                        name: metadata[record.nameID], callID: metadata[key.callID],
                        timestamp: record.timestamp, requestID: key.request.id))
            }
        }
        return result
    }

    /// Retained ownership survives viewport clipping without copying event payloads.
    /// A supplied interval uses the same half-open boundaries as usage accounting.
    public func requestIDsWithToolEvents(
        source: String, interval: DateInterval? = nil
    ) -> Set<UUID> {
        guard let source = sourceIDs[source] else { return [] }
        guard let interval else {
            return Set(retainedToolEventCounts.keys.lazy.filter { $0.source == source }.map(\.id))
        }
        prepareToolOrder()
        if let cachedToolOwners, cachedToolOwners.source == source,
            cachedToolOwners.interval == interval
        {
            return cachedToolOwners.owners
        }

        let first = lowerBound(toolOrder.count) {
            tools[toolOrder[$0]]!.timestamp < interval.start
        }
        let end = lowerBound(toolOrder.count) {
            !(tools[toolOrder[$0]]!.timestamp >= interval.end)
        }
        let range = first..<max(first, end)
        let cache: ToolOwnerQueryCache
        if let previous = cachedToolOwners, previous.source == source,
            interval.start >= previous.interval.start, interval.end >= previous.interval.end
        {
            cache = previous
            // Disjoint moves remove the previous range and add only the new
            // range. Events in the unobserved gap never enter the cache.
            adjustToolOwners(
                in: previous.range.lowerBound..<min(first, previous.range.upperBound),
                by: -1, cache: cache)
            adjustToolOwners(
                in: max(previous.range.upperBound, first)..<range.upperBound,
                by: 1, cache: cache)
        } else {
            cache = ToolOwnerQueryCache(source: source, interval: interval, range: range)
            adjustToolOwners(in: range, by: 1, cache: cache)
        }
        cache.interval = interval
        cache.range = range
        cachedToolOwners = cache
        return cache.owners
    }

    private func adjustToolOwners(in range: Range<Int>, by delta: Int, cache: ToolOwnerQueryCache) {
        toolOwnerQueryVisitedEvents &+= UInt64(range.count)
        for index in range {
            let key = toolOrder[index]
            guard key.request.source == cache.source else { continue }
            let id = key.request.id
            let count = cache.counts[id, default: 0] + delta
            if count == 0 {
                cache.counts.removeValue(forKey: id)
                cache.owners.remove(id)
            } else {
                cache.counts[id] = count
                if count == 1 && delta > 0 { cache.owners.insert(id) }
            }
        }
    }

    /// Only one bounded query is retained. A reference cache avoids copying its
    /// refcounts whenever the two endpoints advance; returned sets remain values.
    private final class ToolOwnerQueryCache {
        let source: Int
        var interval: DateInterval
        var range: Range<Int>
        var counts: [UUID: Int] = [:]
        var owners: Set<UUID> = []

        init(source: Int, interval: DateInterval, range: Range<Int>) {
            self.source = source
            self.interval = interval
            self.range = range
        }
    }

    private func prepareToolOrder() {
        guard toolOrderIsDirty else { return }
        toolOrder = tools.map { (key: $0.key, timestamp: $0.value.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }.map(\.key)
        toolOrderIsDirty = false
        toolOrderBuildCount &+= 1
        PerformancePresentationCounters.shared.record(.historyToolOrderBuilds)
    }

    private func prepareCompletedOrder() {
        guard completedOrderIsDirty else { return }
        completedOrder = records.compactMap { element in
            element.value.endedAt.map { (key: element.key, timestamp: $0) }
        }.sorted { $0.timestamp < $1.timestamp }.map(\.key)
        completedOrderIsDirty = false
        completedOrderBuildCount &+= 1
        PerformancePresentationCounters.shared.record(.historyCompletedOrderBuilds)
    }

    /// Keep a materialized order current without sorting the retained history
    /// for one new record. Released/never-queried caches remain unmaterialized.
    private func insertCompletedOrder(_ key: RequestKey, endedAt: Date) {
        guard !completedOrderIsDirty else {
            completedOrderIsDirty = true
            return
        }
        if let last = completedOrder.last, records[last]!.endedAt! > endedAt {
            let index = lowerBound(completedOrder.count) {
                records[completedOrder[$0]]!.endedAt! <= endedAt
            }
            completedOrder.insert(key, at: index)
        } else {
            completedOrder.append(key)
        }
        completedOrderIncrementalInsertCount &+= 1
        PerformancePresentationCounters.shared.record(.historyCompletedOrderInsertions)
    }

    private func insertToolOrder(_ key: ToolKey, timestamp: Date) {
        guard !toolOrderIsDirty else {
            toolOrderIsDirty = true
            cachedToolOwners = nil
            return
        }
        if let last = toolOrder.last, tools[last]!.timestamp > timestamp {
            let index = lowerBound(toolOrder.count) { tools[toolOrder[$0]]!.timestamp <= timestamp }
            toolOrder.insert(key, at: index)
            // Every saved range uses array indices. An insertion before its end
            // may shift those indices or add an owner to an unchanged viewport.
            cachedToolOwners = nil
        } else {
            toolOrder.append(key)
            // A chronological append beyond the half-open window changes none
            // of its indices or owners. The next rolling query visits the delta.
            if let cachedToolOwners, timestamp < cachedToolOwners.interval.end {
                self.cachedToolOwners = nil
            }
        }
        toolOrderIncrementalInsertCount &+= 1
        PerformancePresentationCounters.shared.record(.historyToolOrderInsertions)
    }

    private func addBoundaryUsage(source: Int, interval: DateInterval, to total: inout UsageTotals)
    {
        guard interval.duration > 0 else { return }
        prepareCompletedOrder()
        let first = lowerBound(completedOrder.count) {
            records[completedOrder[$0]]!.endedAt! < interval.start
        }
        for key in completedOrder[first...] {
            let record = records[key]!
            if record.endedAt! >= interval.end { break }
            if key.source == source { total.include(record) }
        }
        prepareToolOrder()
        let firstTool = lowerBound(toolOrder.count) {
            tools[toolOrder[$0]]!.timestamp < interval.start
        }
        for key in toolOrder[firstTool...] {
            let tool = tools[key]!
            if tool.timestamp >= interval.end { break }
            if key.request.source == source && key.isCall { total.toolCalls += 1 }
        }
    }

    private func lowerBound(_ count: Int, before: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if before(middle) { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Compatibility barriers: session history never queues filesystem work.
    public func flush() {}
    public func waitForPendingWrites() async {}

    private func sourceID(for source: String) -> Int {
        if let id = sourceIDs[source] { return id }
        let id = sourceIDs.count
        sourceIDs[source] = id
        return id
    }

    private func finish(_ key: RequestKey, at date: Date) {
        guard let old = records[key], old.endedAt == nil else { return }
        var record = old
        record.endedAt = max(record.startedAt, record.lastUpdatedAt, date)
        record.lastUpdatedAt = record.endedAt ?? date
        records[key] = record
        activeRequests.remove(key)
        insertCompletedOrder(key, endedAt: record.endedAt!)
        updateLaunchTotals(source: key.source, removing: old, adding: record)
    }

    private func updateLaunchTotals(
        source: Int, removing old: UsageRequestRecord?, adding record: UsageRequestRecord
    ) {
        if let old { launchTotals[source, default: UsageTotals()].include(old, sign: -1) }
        launchTotals[source, default: UsageTotals()].include(record)
        if let old, let endedAt = old.endedAt {
            completedTotals[AccountingBucket(source: source, date: endedAt), default: UsageTotals()]
                .include(old, sign: -1)
        }
        if let endedAt = record.endedAt {
            completedTotals[AccountingBucket(source: source, date: endedAt), default: UsageTotals()]
                .include(record)
        }
    }

    private func removeRequest(_ key: RequestKey) {
        guard let record = records.removeValue(forKey: key) else { return }
        metadata.release(record.modelID)
        activeRequests.remove(key)
        if let end = record.endedAt {
            let bucket = AccountingBucket(source: key.source, date: end)
            completedTotals[bucket]?.include(record, sign: -1)
            if completedTotals[bucket]?.requests == 0 {
                completedTotals.removeValue(forKey: bucket)
            }
        }
        completedOrderIsDirty = true
    }

    private func removeTool(_ key: ToolKey) {
        guard let record = tools.removeValue(forKey: key) else { return }
        retainedToolEventCounts[key.request, default: 0] -= 1
        if retainedToolEventCounts[key.request] == 0 {
            retainedToolEventCounts.removeValue(forKey: key.request)
        }
        metadata.release(record.nameID)
        metadata.release(key.callID)
        if key.isCall {
            let bucket = AccountingBucket(source: key.request.source, date: record.timestamp)
            toolCallTotals[bucket, default: 0] -= 1
            if toolCallTotals[bucket] == 0 { toolCallTotals.removeValue(forKey: bucket) }
        }
        toolOrderIsDirty = true
        cachedToolOwners = nil
    }

    private func prune(at now: Date) {
        guard
            records.count > recordLimit || tools.count > toolEventLimit
                || (lastPrunedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true)
        else { return }
        // Removal helpers invalidate indices immediately. Repair each prepared
        // order once after the batch, avoiding a shift per expired record.
        let preserveCompletedOrder = !completedOrderIsDirty
        let preserveToolOrder = !toolOrderIsDirty
        lastPrunedAt = now
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        let expired = records.filter { ($0.value.endedAt.map { $0 < cutoff }) ?? false }
        for (key, _) in expired { removeRequest(key) }
        if records.count > recordLimit {
            let finished = records.filter { $0.value.endedAt != nil }.sorted {
                ($0.value.endedAt ?? $0.value.startedAt) < ($1.value.endedAt ?? $1.value.startedAt)
            }
            for (key, record) in finished.prefix(records.count - recordLimit) {
                removeRequest(key)
                requestTruncatedThrough[key.source] = max(
                    requestTruncatedThrough[key.source] ?? .distantPast,
                    record.endedAt ?? record.startedAt)
            }
        }
        // All-active overflow is exceptionally unusual, but still bounded and
        // explicitly partial rather than allowing unbounded lifetime growth.
        if records.count > recordLimit {
            let oldest = records.sorted { $0.value.startedAt < $1.value.startedAt }
            for (key, record) in oldest.prefix(records.count - recordLimit) {
                finish(key, at: now)
                removeRequest(key)
                incompleteLaunchSources.insert(key.source)
                requestTruncatedThrough[key.source] = max(
                    requestTruncatedThrough[key.source] ?? .distantPast, record.startedAt)
            }
        }
        for key in tools.keys where tools[key]!.timestamp < cutoff { removeTool(key) }
        if tools.count > toolEventLimit {
            let oldest = tools.sorted { $0.value.timestamp < $1.value.timestamp }
            for (key, tool) in oldest.prefix(tools.count - toolEventLimit) {
                removeTool(key)
                toolTruncatedThrough[key.request.source] = max(
                    toolTruncatedThrough[key.request.source] ?? .distantPast, tool.timestamp)
            }
        }
        requestTruncatedThrough = requestTruncatedThrough.filter { $0.value >= cutoff }
        toolTruncatedThrough = toolTruncatedThrough.filter { $0.value >= cutoff }
        if preserveCompletedOrder && completedOrderIsDirty {
            completedOrder.removeAll { records[$0] == nil }
            completedOrderIsDirty = false
        }
        if preserveToolOrder && toolOrderIsDirty {
            toolOrder.removeAll { tools[$0] == nil }
            toolOrderIsDirty = false
        }
    }

    private func contains(_ interval: DateInterval, _ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }
}

private struct AccountingBucket: Hashable {
    let source: Int
    let hour: Double
    init(source: Int, date: Date) {
        self.source = source
        hour = (date.timeIntervalSinceReferenceDate / 3600).rounded(.down)
    }
    var start: Date { Date(timeIntervalSinceReferenceDate: hour * 3600) }
}

private struct SummaryKey: Equatable {
    let scope: UsageScope
    let source: Int
    let start: Date
    let end: Date
    let revision: UInt64
    let retentionExpired: Bool
}

private struct RequestKey: Hashable {
    let source: Int
    let id: UUID
}

private enum ToolIdentity: Hashable {
    case call(Int32)
    case event(UUID)
}

private struct ToolKey: Hashable {
    let request: RequestKey
    let isCall: Bool
    let identity: ToolIdentity

    var callID: Int32 {
        if case .call(let id) = identity { return id }
        return -1
    }
}

private struct UsageRequestRecord {
    let startedAt: Date
    var lastUpdatedAt: Date
    var endedAt: Date?
    var modelID: Int32
    var inputTokens: Int?
    var outputTokens = 0
    var outputIsEstimated = true
    var liveTPS: Double = 0

    func lane(id: UUID, model: String?) -> RequestLane {
        RequestLane(
            id: id, startedAt: startedAt, endedAt: endedAt, model: model,
            outputTokens: outputTokens, outputIsEstimated: outputIsEstimated,
            liveTPS: liveTPS, terminal: endedAt != nil)
    }
}

private struct UsageToolRecord {
    let id: UUID
    let nameID: Int32
    let timestamp: Date
}

/// Reference-counted metadata slots are reused after retention eviction. This
/// shares repeated names without retaining every unique lifetime string forever.
private final class UsageMetadata {
    private var ids: [String: Int32] = [:]
    private var values: [String?] = []
    private var references: [Int] = []
    private var available: [Int32] = []

    subscript(_ id: Int32) -> String? { id >= 0 ? values[Int(id)] : nil }

    func retain(_ value: String?) -> Int32 {
        guard let value else { return -1 }
        if let id = ids[value] {
            references[Int(id)] += 1
            return id
        }
        let id: Int32
        if let reused = available.popLast() {
            id = reused
            values[Int(id)] = value
            references[Int(id)] = 1
        } else {
            id = Int32(values.count)
            values.append(value)
            references.append(1)
        }
        ids[value] = id
        return id
    }

    func release(_ id: Int32) {
        guard id >= 0 else { return }
        references[Int(id)] -= 1
        if references[Int(id)] == 0, let value = values[Int(id)] {
            ids.removeValue(forKey: value)
            values[Int(id)] = nil
            available.append(id)
        }
    }
}

private struct UsageTotals {
    // Decimal keeps corrections exact after an aggregate temporarily exceeds
    // Int.max. Clamping each update would lose the amount to subtract later.
    var knownInputTokens = Decimal.zero
    var unknownInputRequests = 0
    var outputTokens = Decimal.zero
    var estimatedRequests = 0
    var toolCalls = 0
    var requests = 0
    var activeRequests = 0

    mutating func include(_ record: UsageRequestRecord, sign: Int = 1) {
        requests += sign
        activeRequests += record.endedAt == nil ? sign : 0
        outputTokens += Decimal(record.outputTokens) * Decimal(sign)
        estimatedRequests += record.outputIsEstimated ? sign : 0
        if let input = record.inputTokens {
            knownInputTokens += Decimal(input) * Decimal(sign)
        } else {
            unknownInputRequests += sign
        }
    }

    mutating func include(_ other: UsageTotals) {
        knownInputTokens += other.knownInputTokens
        unknownInputRequests += other.unknownInputRequests
        outputTokens += other.outputTokens
        estimatedRequests += other.estimatedRequests
        toolCalls += other.toolCalls
        requests += other.requests
        activeRequests += other.activeRequests
    }

    func summary(isPartial: Bool) -> UsageSummary {
        let input = clampedTokens(knownInputTokens)
        let output = clampedTokens(outputTokens)
        return UsageSummary(
            inputTokens: requests > 0 && requests == unknownInputRequests ? nil : input.value,
            unknownInputRequests: unknownInputRequests,
            outputTokens: output.value, outputIsEstimated: estimatedRequests > 0,
            toolCalls: toolCalls, requests: requests,
            activeRequests: activeRequests, isPartial: isPartial || input.clamped || output.clamped)
    }

    private func clampedTokens(_ value: Decimal) -> (value: Int, clamped: Bool) {
        guard !value.isNaN, value <= Decimal(Int.max) else { return (Int.max, true) }
        return (max(0, NSDecimalNumber(decimal: value).intValue), false)
    }
}
