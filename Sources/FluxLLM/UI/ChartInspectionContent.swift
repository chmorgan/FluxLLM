import Foundation

/// Small, bounded summaries. Request metrics describe the full request, not
/// history at the cursor; tool rates and counts come from the same observed bin.
struct ChartInspectionContent: Equatable {
    enum Accent: Equatable {
        case generated, gpu, tools, secondary
        case request(UUID)
    }

    struct Row: Equatable {
        let label: String
        let value: String
        var accent: Accent = .secondary
    }

    struct RequestMetrics: Equatable {
        let duration: String
        let averageRate: String
        let outputTokens: String
    }

    let title: String
    let badge: String?
    var accent: Accent = .secondary
    let rows: [Row]
    var requestMetrics: RequestMetrics? = nil

    static func plot(
        at timestamp: Date, generated: Double, gpu: Double?, requestCount: Int
    ) -> Self {
        var rows = [
            Row(
                label: "Generated", value: String(format: "%.1f tok/s", generated),
                accent: .generated),
            Row(
                label: "GPU", value: gpu.map { String(format: "%.0f%%", $0) } ?? "—",
                accent: .gpu),
        ]
        if requestCount > 0 {
            rows.append(Row(label: "Requests", value: requestCount.formatted()))
        }
        return Self(title: time(timestamp), badge: nil, rows: rows)
    }

    /// Active requests use publication time so moving the cursor cannot change
    /// the duration while the retained output count stays the same.
    static func request(_ lane: RequestLane, at snapshotTime: Date) -> Self {
        let ended = lane.terminal || lane.endedAt != nil
        let end = lane.endedAt ?? (lane.terminal ? nil : snapshotTime)
        let duration = end.map { $0.timeIntervalSince(lane.startedAt) }
        let elapsed = duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let tokens = max(0, lane.outputTokens)
        let estimate = lane.outputIsEstimated ? "~" : ""
        var average = "—"
        if let elapsed, elapsed > 0 {
            let rate = Double(tokens) / elapsed
            if rate.isFinite {
                average = estimate + String(format: "%.1f tok/s", rate)
            }
        }
        return Self(
            title: modelName(lane.model), badge: ended ? "Ended" : "In progress",
            accent: .request(lane.id), rows: [],
            requestMetrics: RequestMetrics(
                duration: elapsed.map(requestDuration) ?? "—", averageRate: average,
                outputTokens: "\(estimate)\(tokens.formatted()) tok"))
    }

    static func tools(
        at timestamp: Date, bucket: ToolActivityBucket?, results: [ToolActivityEvent]
    ) -> Self {
        let pending = bucket.map { $0.observedDuration == 0 && $0.callCount > 0 } ?? false
        var rows = [
            Row(
                label: "Tool calls",
                value: pending
                    ? "Pending" : String(format: "%.1f/min", bucket?.callsPerMinute ?? 0),
                accent: .tools)
        ]
        if let bucket {
            rows.append(
                Row(
                    label: "Observed",
                    value:
                        "\(bucket.callCount) \(bucket.callCount == 1 ? "call" : "calls") / \(seconds(bucket.observedDuration))"
                ))
            if !bucket.toolNames.isEmpty {
                rows.append(Row(label: "Tools", value: names(bucket.toolNames)))
            }
        }
        if !results.isEmpty {
            rows.append(
                Row(
                    label: "◇ Submitted",
                    value: "\(results.count) \(results.count == 1 ? "result" : "results")",
                    accent: .tools))
        }
        return Self(title: time(timestamp), badge: "Tools", rows: rows)
    }

    static func toolBucket(
        at timestamp: Date, in history: ToolActivityHistory, now: Date
    ) -> ToolActivityBucket? {
        if let bucket = history.bucket(at: timestamp) { return bucket }
        // The plotted fresh tail holds the latest rate until publication time.
        // Its count and exposure remain those of the original observed bucket.
        if let current = history.current, timestamp > current.end, timestamp <= now {
            return current
        }
        return nil
    }

    static func overflow(at timestamp: Date, lanes: [RequestLane]) -> Self {
        Self(
            title: time(timestamp), badge: "Overflow",
            rows: [
                Row(label: "Requests", value: lanes.count.formatted()),
                Row(label: "Models", value: names(lanes.map { modelName($0.model) })),
            ])
    }

    private static func modelName(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "Unknown model" }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    private static func names(_ values: [String]) -> String {
        let unique = Array(Set(values)).sorted()
        let visible = unique.prefix(2).joined(separator: ", ")
        return unique.count > 2 ? "\(visible) +\(unique.count - 2)" : visible
    }

    private static func time(_ timestamp: Date) -> String {
        timestamp.formatted(date: .omitted, time: .standard)
    }

    private static func seconds(_ duration: TimeInterval) -> String {
        String(format: duration < 10 ? "%.1fs" : "%.0fs", duration)
    }

    private static func requestDuration(_ duration: TimeInterval) -> String {
        if duration < 60 { return String(format: "%.1f s", duration) }
        if duration < 3600 { return String(format: "%.1f min", duration / 60) }
        return String(format: "%.1f h", duration / 3600)
    }
}
