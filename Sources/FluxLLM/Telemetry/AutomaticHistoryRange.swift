import Foundation

/// Follows the latest observed activity episode without consulting retained history.
struct AutomaticHistoryRange: Sendable {
    private static let widths: [TimeInterval] = [30, 60, 120, 300, 600]
    private static let expansionFraction = 0.8
    private static let episodeSeparation: TimeInterval = 60
    /// Distant idle observations cannot establish continuously observed inactivity.
    private static let observationFreshness: TimeInterval = 5

    private(set) var duration: TimeInterval = 30
    private var episodeStartedAt: Date?
    private var idleSince: Date?
    private var unknownSince: Date?
    private var lastObservedAt: Date?
    private var startsNewEpisode = false

    mutating func observe(_ activity: BackendActivity, at date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite,
            lastObservedAt.map({ date >= $0 }) ?? true
        else { return }

        if let lastObservedAt {
            let gap = date.timeIntervalSince(lastObservedAt)
            if gap > Self.observationFreshness { idleSince = nil }
            // A long observation outage breaks continuity without asserting idle.
            if gap >= Self.episodeSeparation { startsNewEpisode = true }
        }
        if let unknownSince,
            date.timeIntervalSince(unknownSince) >= Self.episodeSeparation
        {
            startsNewEpisode = true
        }
        lastObservedAt = date

        switch activity {
        case .requests, .observedRequests:
            if episodeStartedAt == nil || startsNewEpisode {
                episodeStartedAt = date
                duration = Self.widths[0]
            }
            startsNewEpisode = false
            idleSince = nil
            unknownSince = nil
            if let episodeStartedAt {
                let span = date.timeIntervalSince(episodeStartedAt)
                while let next = Self.widths.first(where: { $0 > duration }),
                    span >= duration * Self.expansionFraction
                {
                    duration = next
                }
            }
        case .idle:
            unknownSince = nil
            if idleSince == nil { idleSince = date }
            if let idleSince,
                date.timeIntervalSince(idleSince) >= Self.episodeSeparation
            {
                startsNewEpisode = true
            }
        case .unknown:
            idleSince = nil
            if unknownSince == nil { unknownSince = date }
        }
    }

    mutating func reset() {
        self = Self()
    }
}
