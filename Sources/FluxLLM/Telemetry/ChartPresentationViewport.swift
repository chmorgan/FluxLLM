import Foundation

/// The display demand is independent of collection and of native visibility.
/// The standard dashboard range follows recent request activity; a pinned viewport
/// preserves its absolute interval, and a custom live view preserves its width.
public enum ChartPresentationViewport: Equatable, Sendable {
    case historyRange
    case live(duration: TimeInterval)
    case fixed(DateInterval)

    func interval(
        at now: Date, range: HistoryRange, historyAge: TimeInterval,
        automaticDuration: TimeInterval = 30
    ) -> DateInterval {
        switch self {
        case .historyRange:
            return DateInterval(
                start: now.addingTimeInterval(
                    -range.duration(historyAge: historyAge, automaticDuration: automaticDuration)),
                end: now)
        case .live(let duration):
            let duration = duration.isFinite ? min(max(duration, 1), 86_400) : 60
            return DateInterval(start: now.addingTimeInterval(-duration), end: now)
        case .fixed(let interval):
            let duration = interval.duration.isFinite ? min(max(interval.duration, 1), 86_400) : 60
            let requestedEnd =
                interval.end.timeIntervalSinceReferenceDate.isFinite ? interval.end : now
            let end = min(now, max(now.addingTimeInterval(-86_400 + duration), requestedEnd))
            return DateInterval(start: end.addingTimeInterval(-duration), end: end)
        }
    }
}

/// Whole averaging bins are fetched before clipping the plotted interval. Each
/// numeric query also retains its predecessor and true retention boundary.
struct ChartPresentationSelection {
    let windows: [DateInterval]

    func sampleIntervals(archive: ArchivedChartHistory) -> [DateInterval] {
        Self.merged(
            windows.map { window in
                let starts = [archive.throughput, archive.systemGPU, archive.toolObservation].map {
                    segments in
                    let usesArchive = segments.contains { segment in
                        segment.contains {
                            $0.isValid && $0.end >= window.start && $0.end <= window.end
                        }
                    }
                    let width =
                        usesArchive
                        ? max(60, (window.duration / 3_600).rounded(.up) * 60)
                        : max(3, window.duration / 60)
                    return Date(
                        timeIntervalSince1970: (window.start.timeIntervalSince1970 / width).rounded(
                            .down) * width)
                }
                return DateInterval(start: starts.min() ?? window.start, end: window.end)
            })
    }

    /// An archive cannot contribute a visible bin or change a leading retention
    /// boundary if every raw series already starts before that entire first bin.
    func needsArchive(rawStarts: [Date?]) -> Bool {
        guard rawStarts.allSatisfy({ $0 != nil }),
            let latestStart = rawStarts.compactMap({ $0 }).max()
        else { return true }
        return sampleIntervals(archive: .empty).contains { $0.start <= latestStart }
    }

    static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(
                    start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
