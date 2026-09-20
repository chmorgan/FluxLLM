import Foundation

/// Keeps UI delivery current when the main actor is busy. Stream snapshots are
/// cumulative, so only the newest pending live snapshot for each request is
/// needed. Request boundaries and discrete tool events remain ordered and are
/// never dropped.
final class GenerationEventInbox: @unchecked Sendable {
    let notifications: AsyncStream<Void>

    private struct PendingEvent {
        let sequence: UInt64
        let event: GenerationEvent
    }

    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var lifecycleEvents: [PendingEvent] = []
    private var liveSnapshots: [UUID: PendingEvent] = [:]
    private var sequence: UInt64 = 0
    private var isFinished = false

    init() {
        let (notifications, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        self.notifications = notifications
        self.continuation = continuation
    }

    func submit(_ event: GenerationEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        sequence += 1
        let pending = PendingEvent(sequence: sequence, event: event)
        switch event {
        case .began, .toolActivity:
            lifecycleEvents.append(pending)
        case .updated(let requestID, let snapshot):
            if snapshot.finished || snapshot.error != nil {
                // A final snapshot already includes the cumulative usage. It
                // replaces the live update while preserving its own position.
                liveSnapshots.removeValue(forKey: requestID)
                lifecycleEvents.append(pending)
            } else {
                liveSnapshots[requestID] = pending
            }
        case .failed(let requestID, _), .cancelled(let requestID):
            // These terminal events do not carry usage. Deliver the most
            // recent cumulative count first so cancelling cannot lose it.
            if let latest = liveSnapshots.removeValue(forKey: requestID) {
                lifecycleEvents.append(latest)
            }
            lifecycleEvents.append(pending)
        }

        // Signals cannot build a per-token backlog. The inbox is bounded by
        // pending request boundaries, discrete tool events, and one live
        // snapshot per request, rather than text fragment count.
        continuation.yield(())
    }

    /// Atomically takes one batch. Sorting by emission order keeps updates for
    /// overlapping requests on the correct side of newer request beginnings.
    func drain() -> [GenerationEvent] {
        lock.lock()
        defer { lock.unlock() }
        let pending = lifecycleEvents + liveSnapshots.values
        lifecycleEvents.removeAll(keepingCapacity: true)
        liveSnapshots.removeAll(keepingCapacity: true)
        return pending.sorted { $0.sequence < $1.sequence }.map(\.event)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        continuation.finish()
    }
}
