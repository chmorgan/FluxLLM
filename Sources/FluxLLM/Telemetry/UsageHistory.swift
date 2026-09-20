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
/// Only counts, model names, and tool names/timestamps are persisted, never
/// prompts, responses, arguments, or tool-result contents.
@MainActor
public final class UsageHistory {
    public private(set) var persistenceError: String?
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private let launchID = UUID()
    private let directory: URL?
    private let calendar: Calendar
    private let recordLimit: Int
    private let toolEventLimit: Int
    private var records: [RequestKey: UsageRequestRecord] = [:]
    private var tools: [ToolKey: UsageToolRecord] = [:]
    private var launchTotals: [String: UsageTotals] = [:]
    private var requestTruncatedThrough: [String: Date] = [:]
    private var toolTruncatedThrough: [String: Date] = [:]
    private var incompleteLaunchSources: Set<String> = []
    private var persistenceIsDisabled = false
    private var scheduledWrite: Task<Void, Never>?
    private var pendingWrite: Task<Void, Never>?
    private var latestDate: Date
    private var lastPrunedAt: Date?

    public init(
        directory: URL? = nil, now: Date = Date(), calendar: Calendar = .current,
        recordLimit: Int = 20_000, toolEventLimit: Int = 50_000
    ) {
        self.directory = directory
        self.calendar = calendar
        self.recordLimit = max(1, recordLimit)
        self.toolEventLimit = max(1, toolEventLimit)
        latestDate = now
        load(at: now)
    }

    deinit {
        scheduledWrite?.cancel()
    }

    public func apply(_ event: GenerationEvent, source: String, at date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        latestDate = max(latestDate, date)
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
                id: request.id, source: source, launchID: launchID,
                startedAt: request.startedAt, lastUpdatedAt: request.startedAt,
                model: request.model)
            records[key] = record
            updateLaunchTotals(removing: nil, adding: record)
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
            record.model = snapshot.model ?? record.model
            record.outputTokens = max(0, snapshot.outputTokens)
            record.outputIsEstimated = snapshot.isEstimated
            if let input = snapshot.promptTokens { record.inputTokens = max(0, input) }
            if !terminal && snapshot.liveTPS.isFinite {
                record.liveTPS = max(0, snapshot.liveTPS)
            }
            if terminal && record.endedAt == nil {
                record.endedAt = max(record.startedAt, snapshot.timestamp)
            }
            records[key] = record
            updateLaunchTotals(removing: old, adding: record)
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
                    if request.launchID == launchID { incompleteLaunchSources.insert(source) }
                    continue
                }
                let kind = event.kind == .call ? "call" : "result"
                let key = ToolKey(
                    request: requestKey, kind: kind,
                    identity: event.callID.map { "call:\($0)" } ?? "event:\(event.id)")
                guard tools[key] == nil else { continue }
                tools[key] = UsageToolRecord(
                    id: event.id, source: source, launchID: request.launchID,
                    requestID: id, kind: kind, name: event.name,
                    callID: event.callID, timestamp: event.timestamp)
                if request.launchID == launchID && event.kind == .call {
                    launchTotals[source, default: UsageTotals()].toolCalls += 1
                }
            }
        }
        prune(at: latestDate)
        scheduleWrite()
    }

    public func finishOpenRequests(source: String, at date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        latestDate = max(latestDate, date)
        let keys = records.keys.filter { $0.source == source && records[$0]?.endedAt == nil }
        for key in keys { finish(key, at: date) }
        prune(at: latestDate)
        flush()
    }

    /// Selected-period requests belong to the interval in which they ended.
    /// Intervals are half-open [start, end), so adjacent periods never double
    /// count a request or tool call. Today also includes live requests that
    /// began today; their estimates are replaced when final usage arrives.
    public func summary(
        scope: UsageScope, source: String, interval: DateInterval, now: Date
    ) -> UsageSummary {
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
        var total = UsageTotals()
        for record in records.values where record.source == source {
            if let end = record.endedAt {
                if contains(range, end) { total.include(record) }
            } else if scope == .today && contains(range, record.startedAt) {
                total.include(record)
            }
        }
        total.toolCalls =
            tools.values.filter {
                $0.source == source && $0.kind == "call" && contains(range, $0.timestamp)
            }.count
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        let partial =
            persistenceIsDisabled || range.start < cutoff
            || requestTruncatedThrough[source].map { range.start <= $0 } == true
            || toolTruncatedThrough[source].map { range.start <= $0 } == true
        return total.summary(isPartial: partial)
    }

    public func requestLanes(source: String, interval: DateInterval) -> [RequestLane] {
        records.values.filter {
            $0.source == source && $0.startedAt < interval.end
                && ($0.endedAt == nil || $0.endedAt! >= interval.start)
        }.sorted { $0.startedAt < $1.startedAt }.map { $0.lane }
    }

    public func toolEvents(source: String, interval: DateInterval) -> [ToolActivityEvent] {
        tools.values.filter { $0.source == source && contains(interval, $0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }.map { $0.event }
    }

    /// Schedules an atomic save off the main actor. Writes are serialized so an
    /// older snapshot cannot replace newer usage. Call waitForPendingWrites
    /// when a caller needs a durability barrier before terminating.
    public func flush() {
        scheduledWrite?.cancel()
        scheduledWrite = nil
        guard let directory, !persistenceIsDisabled else { return }
        let snapshot = UsageHistorySnapshot(
            version: 1, records: Array(records.values), tools: Array(tools.values),
            requestTruncatedThrough: requestTruncatedThrough,
            toolTruncatedThrough: toolTruncatedThrough)
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            await previous?.value
            let error = await Task.detached(priority: .utility) {
                Self.write(snapshot, directory: directory)
            }.value
            self?.persistenceError = error
        }
    }

    public func waitForPendingWrites() async {
        flush()
        await pendingWrite?.value
    }

    private func finish(_ key: RequestKey, at date: Date) {
        guard let old = records[key], old.endedAt == nil else { return }
        var record = old
        record.endedAt = max(record.startedAt, record.lastUpdatedAt, date)
        record.lastUpdatedAt = record.endedAt ?? date
        records[key] = record
        updateLaunchTotals(removing: old, adding: record)
    }

    private func updateLaunchTotals(
        removing old: UsageRequestRecord?, adding record: UsageRequestRecord
    ) {
        guard record.launchID == launchID else { return }
        if let old { launchTotals[record.source, default: UsageTotals()].include(old, sign: -1) }
        launchTotals[record.source, default: UsageTotals()].include(record)
    }

    private func scheduleWrite() {
        guard directory != nil, !persistenceIsDisabled, scheduledWrite == nil else { return }
        scheduledWrite = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            self?.flush()
        }
    }

    private func prune(at now: Date) {
        guard
            records.count > recordLimit || tools.count > toolEventLimit
                || (lastPrunedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true)
        else { return }
        lastPrunedAt = now
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        let expired = records.filter { ($0.value.endedAt.map { $0 < cutoff }) ?? false }
        for (key, _) in expired { records.removeValue(forKey: key) }
        if records.count > recordLimit {
            let finished = records.filter { $0.value.endedAt != nil }.sorted {
                ($0.value.endedAt ?? $0.value.startedAt) < ($1.value.endedAt ?? $1.value.startedAt)
            }
            for (key, record) in finished.prefix(records.count - recordLimit) {
                records.removeValue(forKey: key)
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
                records.removeValue(forKey: key)
                incompleteLaunchSources.insert(key.source)
                requestTruncatedThrough[key.source] = max(
                    requestTruncatedThrough[key.source] ?? .distantPast, record.startedAt)
            }
        }
        tools = tools.filter { $0.value.timestamp >= cutoff }
        if tools.count > toolEventLimit {
            let oldest = tools.sorted { $0.value.timestamp < $1.value.timestamp }
            for (key, tool) in oldest.prefix(tools.count - toolEventLimit) {
                tools.removeValue(forKey: key)
                toolTruncatedThrough[key.request.source] = max(
                    toolTruncatedThrough[key.request.source] ?? .distantPast, tool.timestamp)
            }
        }
        requestTruncatedThrough = requestTruncatedThrough.filter { $0.value >= cutoff }
        toolTruncatedThrough = toolTruncatedThrough.filter { $0.value >= cutoff }
    }

    private func load(at now: Date) {
        guard let directory else { return }
        let file = directory.appendingPathComponent("usage-history.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1_024 * 1_024 else { throw UsageHistoryError.fileTooLarge }
            let snapshot = try JSONDecoder().decode(
                UsageHistorySnapshot.self, from: Data(contentsOf: file))
            guard snapshot.version == 1 else { throw UsageHistoryError.unsupportedVersion }
            for var record in snapshot.records {
                guard record.outputTokens >= 0, record.inputTokens.map({ $0 >= 0 }) ?? true,
                    record.liveTPS.isFinite,
                    record.startedAt.timeIntervalSinceReferenceDate.isFinite,
                    record.lastUpdatedAt.timeIntervalSinceReferenceDate.isFinite,
                    record.endedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
                    record.lastUpdatedAt >= record.startedAt,
                    record.endedAt.map({ $0 >= record.startedAt }) ?? true
                else { throw UsageHistoryError.invalidRecord }
                if record.endedAt == nil {
                    record.endedAt = max(record.startedAt, record.lastUpdatedAt)
                    record.outputIsEstimated = true
                }
                let key = RequestKey(source: record.source, id: record.id)
                guard records[key] == nil else { throw UsageHistoryError.invalidRecord }
                records[key] = record
            }
            for tool in snapshot.tools {
                guard tool.kind == "call" || tool.kind == "result" else {
                    throw UsageHistoryError.invalidRecord
                }
                guard tool.timestamp.timeIntervalSinceReferenceDate.isFinite else {
                    throw UsageHistoryError.invalidRecord
                }
                let request = RequestKey(source: tool.source, id: tool.requestID)
                let key = ToolKey(
                    request: request, kind: tool.kind,
                    identity: tool.callID.map { "call:\($0)" } ?? "event:\(tool.id)")
                guard tools[key] == nil else { throw UsageHistoryError.invalidRecord }
                tools[key] = tool
            }
            requestTruncatedThrough = snapshot.requestTruncatedThrough
            toolTruncatedThrough = snapshot.toolTruncatedThrough
            prune(at: now)
        } catch {
            records.removeAll()
            tools.removeAll()
            persistenceIsDisabled = true
            persistenceError = "Saved usage could not be loaded: \(error.localizedDescription)"
        }
    }

    nonisolated private static func write(
        _ snapshot: UsageHistorySnapshot, directory: URL
    ) -> String? {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= 32 * 1_024 * 1_024 else { throw UsageHistoryError.fileTooLarge }
            try data.write(
                to: directory.appendingPathComponent("usage-history.json"), options: .atomic)
            return nil
        } catch {
            return "Usage could not be saved: \(error.localizedDescription)"
        }
    }

    private func contains(_ interval: DateInterval, _ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }
}

private struct RequestKey: Hashable {
    let source: String
    let id: UUID
}

private struct ToolKey: Hashable {
    let request: RequestKey
    let kind: String
    let identity: String
}

private struct UsageRequestRecord: Codable, Sendable {
    let id: UUID
    let source: String
    let launchID: UUID
    let startedAt: Date
    var lastUpdatedAt: Date
    var endedAt: Date?
    var model: String?
    var inputTokens: Int?
    var outputTokens = 0
    var outputIsEstimated = true
    var liveTPS: Double = 0

    var lane: RequestLane {
        RequestLane(
            id: id, startedAt: startedAt, endedAt: endedAt, model: model,
            outputTokens: outputTokens, outputIsEstimated: outputIsEstimated,
            liveTPS: liveTPS, terminal: endedAt != nil)
    }
}

private struct UsageToolRecord: Codable, Sendable {
    let id: UUID
    let source: String
    let launchID: UUID
    let requestID: UUID
    let kind: String
    let name: String?
    let callID: String?
    let timestamp: Date

    var event: ToolActivityEvent {
        ToolActivityEvent(
            id: id, kind: kind == "call" ? .call : .resultSubmission,
            name: name, callID: callID, timestamp: timestamp, requestID: requestID)
    }
}

private struct UsageHistorySnapshot: Codable, Sendable {
    let version: Int
    let records: [UsageRequestRecord]
    let tools: [UsageToolRecord]
    let requestTruncatedThrough: [String: Date]
    let toolTruncatedThrough: [String: Date]
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

private enum UsageHistoryError: LocalizedError {
    case unsupportedVersion
    case invalidRecord
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This usage history format is not supported."
        case .invalidRecord: "The usage history contains invalid records."
        case .fileTooLarge: "The usage history exceeds the supported file size."
        }
    }
}
