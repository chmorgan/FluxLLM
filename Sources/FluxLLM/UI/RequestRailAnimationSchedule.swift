import Foundation

/// Include pixel eligibility in the task identity: a completion received during
/// an empty layout must start drawing when its segment becomes visible, without
/// replaying the receipt or changing the cached profile on an ordinary resize.
struct RequestRailAnimationEligibility: Hashable {
    let liveIDs: [UUID]
    let effectIDs: [RequestRailEvent.ID]

    init(
        segments: [RequestRailGeometry.Segment], events: [RequestRailEvent],
        now: Date, duration: TimeInterval
    ) {
        liveIDs = segments.filter(\.isLive).map { $0.lane.id }
        effectIDs = events.compactMap { event in
            guard let segment = segments.first(where: { $0.lane.id == event.requestID }),
                event.kind == .completion
                    || segment.lane.startedAt >= now.addingTimeInterval(-duration)
            else { return nil }
            return event.id
        }
    }
}

/// Decoration ticks are only useful while at least one effect is visible.
/// Lifecycle receipts can outlive their pixels; an active request alone also
/// does not require frames during the gap before its next glint.
struct RequestRailAnimationSchedule: Equatable {
    static let twinkleInterval: TimeInterval = 0.505

    let isAnimating: Bool
    let nextUpdate: Date?

    init(
        at timestamp: Date, visibleUntil: [Date], nextTwinkleAt: Date?,
        retainedUntil: [Date] = []
    ) {
        // All supplied effects have started. Overlapping effects keep the
        // timeline running continuously until the last one's visible end.
        let lastVisibleEnd = visibleUntil.filter { $0 > timestamp }.max()
        // Empty geometry pauses pixels but retains the exact prepared profile.
        // One cleanup wake releases those profiles at their final visible end.
        let lastRetainedEnd = retainedUntil.filter { $0 > timestamp }.max()
        isAnimating = lastVisibleEnd != nil
        nextUpdate = [lastVisibleEnd, nextTwinkleAt, lastRetainedEnd].compactMap { $0 }.min()
    }
}
