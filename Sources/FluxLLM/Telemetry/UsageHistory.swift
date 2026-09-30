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
    private var requestOrder: [RequestKey] = []
    private var requestOrderIsDirty = true
    private var toolOrder: [ToolKey] = []
    private var toolOrderIsDirty = true
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
            requestOrderIsDirty = true
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
            if terminal && record.endedAt == nil {
                record.endedAt = max(record.startedAt, snapshot.timestamp)
                activeRequests.remove(key)
                completedOrderIsDirty = true
            }
            records[key] = record
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
                toolOrderIsDirty = true
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

    public func requestLanes(source: String, interval: DateInterval) -> [RequestLane] {
        guard let source = sourceIDs[source] else { return [] }
        if requestOrderIsDirty {
            requestOrder = records.keys.sorted {
                records[$0]!.startedAt < records[$1]!.startedAt
            }
            requestOrderIsDirty = false
        }
        var result: [RequestLane] = []
        for key in requestOrder {
            guard let record = records[key] else { continue }
            if record.startedAt >= interval.end { break }
            if key.source == source && (record.endedAt == nil || record.endedAt! >= interval.start)
            {
                result.append(record.lane(id: key.id, model: metadata[record.modelID]))
            }
        }
        return result
    }

    public func toolEvents(source: String, interval: DateInterval) -> [ToolActivityEvent] {
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
            if record.timestamp >= interval.end { break }
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

    private func prepareToolOrder() {
        guard toolOrderIsDirty else { return }
        toolOrder = tools.keys.sorted { tools[$0]!.timestamp < tools[$1]!.timestamp }
        toolOrderIsDirty = false
    }

    private func addBoundaryUsage(source: Int, interval: DateInterval, to total: inout UsageTotals)
    {
        guard interval.duration > 0 else { return }
        if completedOrderIsDirty {
            completedOrder = records.keys.filter { records[$0]!.endedAt != nil }.sorted {
                records[$0]!.endedAt! < records[$1]!.endedAt!
            }
            completedOrderIsDirty = false
        }
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
        completedOrderIsDirty = true
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
        requestOrderIsDirty = true
        completedOrderIsDirty = true
    }

    private func removeTool(_ key: ToolKey) {
        guard let record = tools.removeValue(forKey: key) else { return }
        metadata.release(record.nameID)
        metadata.release(key.callID)
        if key.isCall {
            let bucket = AccountingBucket(source: key.request.source, date: record.timestamp)
            toolCallTotals[bucket, default: 0] -= 1
            if toolCallTotals[bucket] == 0 { toolCallTotals.removeValue(forKey: bucket) }
        }
        toolOrderIsDirty = true
    }

    private func prune(at now: Date) {
        guard
            records.count > recordLimit || tools.count > toolEventLimit
                || (lastPrunedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true)
        else { return }
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
