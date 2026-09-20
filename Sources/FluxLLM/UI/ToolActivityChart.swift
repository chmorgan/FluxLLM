import SwiftUI

/// Presentation for an independently scaled event rate; generated-token values never
/// participate in this scale or in tool-call counting.
enum ToolActivityChartPresentation {
    static let unit = "calls/min"
    static let spokenUnit = "tool calls per minute"

    static func color(_ scheme: ColorScheme, increasedContrast: Bool) -> Color {
        if scheme == .dark {
            return increasedContrast
                ? Color(red: 1, green: 0.80, blue: 0.35)
                : Color(red: 1, green: 0.69, blue: 0.24)
        }
        return increasedContrast
            ? Color(red: 0.48, green: 0.24, blue: 0)
            : Color(red: 0.62, green: 0.34, blue: 0)
    }

    static func normalizedSegments(
        history: ToolActivityHistory, now: Date, duration: TimeInterval, upperBound: Double
    ) -> [[CGPoint]] {
        guard duration.isFinite, duration > 0, upperBound.isFinite, upperBound > 0 else {
            return []
        }
        return history.plotSegments.map { points in
            points.map {
                CGPoint(
                    x: ($0.timestamp.timeIntervalSince(now) + duration) / duration,
                    y: min(max($0.value / upperBound, 0), 1))
            }
        }
    }

    /// Markers are selected by their actual submission time, not by an entire
    /// average bucket, so a long-range chart cannot imply continuous execution.
    static func results(
        near timestamp: Date, in history: ToolActivityHistory,
        duration: TimeInterval, plotWidth: CGFloat
    ) -> [ToolActivityEvent] {
        guard plotWidth > 0, duration.isFinite, duration > 0 else { return [] }
        let tolerance = duration * 5 / Double(plotWidth)
        return history.resultMarkers.filter {
            abs($0.timestamp.timeIntervalSince(timestamp)) <= tolerance
        }
    }

    static func rateDescription(_ bucket: ToolActivityBucket) -> String {
        guard bucket.observedDuration > 0 else { return "Tool-call rate pending" }
        return String(format: "Tool calls %.1f calls/min", bucket.callsPerMinute)
    }

    static func countDescription(_ bucket: ToolActivityBucket) -> String {
        let count = bucket.callCount
        return "\(count) \(count == 1 ? "call" : "calls") over "
            + String(format: "%.1f seconds", bucket.observedDuration)
    }

    static func namesDescription(_ bucket: ToolActivityBucket) -> String? {
        guard !bucket.toolNames.isEmpty else { return nil }
        return bucket.toolNames.joined(separator: ", ")
    }

    static func resultDescription(_ events: [ToolActivityEvent]) -> String? {
        guard !events.isEmpty else { return nil }
        let names = Array(Set(events.compactMap(\.name))).sorted()
        let detail = names.isEmpty ? "\(events.count)" : names.joined(separator: ", ")
        let times = events.map(\.timestamp).sorted()
        let first = times[0].formatted(date: .omitted, time: .standard)
        let last = times[times.count - 1].formatted(date: .omitted, time: .standard)
        let time = first == last ? first : "\(first)–\(last)"
        return "Tool results submitted at \(time): \(detail)"
    }

    static func accessibilitySummary(_ history: ToolActivityHistory) -> String {
        let current: String
        if let bucket = history.current {
            current = String(
                format: "Latest tool-call rate %.1f tool calls per minute", bucket.callsPerMinute)
        } else if let latest = history.buckets.last,
            latest.observedDuration == 0, latest.callCount > 0
        {
            current = "Tool-call rate pending for the latest observed calls"
        } else {
            current = "Current tool-call rate unavailable"
        }
        let count = history.buckets.reduce(0) { $0 + $1.callCount }
        return "Tool calls use an independent scale. \(current). "
            + "\(count) calls and \(history.resultMarkers.count) tool result submissions in this history."
    }
}
