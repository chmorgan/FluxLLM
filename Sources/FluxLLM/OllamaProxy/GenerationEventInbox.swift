import Foundation

/// Coalesces cumulative snapshots for at most 20 ordinary UI deliveries per
/// second, even when the consumer is ready for every token. Request boundaries
/// and discrete tool events bypass the delay and keep their emission order.
final class GenerationEventInbox: @unchecked Sendable {
    typealias Cancellation = @Sendable () -> Void
    /// Schedulers must enqueue the action, not call it before returning. A
    /// cancellation may race with the action; revisions reject stale callbacks.
    typealias Scheduler = @Sendable (Duration, @escaping @Sendable () -> Void) -> Cancellation

    let notifications: AsyncStream<Void>

    private struct PendingEvent {
        let sequence: UInt64
        let event: GenerationEvent
    }

    private let continuation: AsyncStream<Void>.Continuation
    private let schedule: Scheduler
    private let lock = NSLock()
    private var lifecycleEvents: [PendingEvent] = []
    private var liveSnapshots: [UUID: PendingEvent] = [:]
    private var sequence: UInt64 = 0
    private var isFinished = false
    private var notificationPending = false
    private var deliveryReady = false
    private var scheduledDelivery: Cancellation?
    private var scheduleRevision: UInt64 = 0

    init(
        schedule: @escaping Scheduler = { delay, action in
            let task = Task {
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled else { return }
                action()
            }
            return { task.cancel() }
        }
    ) {
        let (notifications, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        self.notifications = notifications
        self.continuation = continuation
        self.schedule = schedule
    }

    func submit(_ event: GenerationEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        sequence += 1
        let pending = PendingEvent(sequence: sequence, event: event)
        var urgent = true
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
                urgent = false
            }
        case .failed(let requestID, _), .cancelled(let requestID):
            // These terminal events do not carry usage. Deliver the most
            // recent cumulative count first so cancelling cannot lose it.
            if let latest = liveSnapshots.removeValue(forKey: requestID) {
                lifecycleEvents.append(latest)
            }
            lifecycleEvents.append(pending)
        }

        if urgent {
            cancelScheduledDelivery()
            signalDelivery()
        } else if !deliveryReady, scheduledDelivery == nil {
            scheduleRevision &+= 1
            let revision = scheduleRevision
            scheduledDelivery = schedule(.milliseconds(50)) { [weak self] in
                self?.scheduledDeliveryIsReady(revision: revision)
            }
        }
    }

    /// Consumer entry point. A forced drain can leave a buffered signal behind;
    /// that stale signal must not deliver the next live batch before its deadline.
    func drainReadyEvents() -> [GenerationEvent] {
        lock.lock()
        defer { lock.unlock() }
        notificationPending = false
        guard deliveryReady else { return [] }
        return takePendingEvents()
    }

    /// Atomically takes one batch. Sorting by emission order keeps updates for
    /// overlapping requests on the correct side of newer request beginnings.
    /// Shutdown uses this to apply final usage/cancellations before returning.
    func drain() -> [GenerationEvent] {
        lock.lock()
        defer { lock.unlock() }
        notificationPending = false
        return takePendingEvents()
    }

    private func takePendingEvents() -> [GenerationEvent] {
        cancelScheduledDelivery()
        deliveryReady = false
        let pending = lifecycleEvents + liveSnapshots.values
        lifecycleEvents.removeAll(keepingCapacity: true)
        liveSnapshots.removeAll(keepingCapacity: true)
        return pending.sorted { $0.sequence < $1.sequence }.map(\.event)
    }

    /// Normal completion flushes the final pending batch before ending the
    /// stream. An owner canceling its consumer can explicitly discard instead.
    func finish(deliveringPendingEvents: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        cancelScheduledDelivery()
        if deliveringPendingEvents {
            if !lifecycleEvents.isEmpty || !liveSnapshots.isEmpty { signalDelivery() }
        } else {
            lifecycleEvents.removeAll()
            liveSnapshots.removeAll()
            deliveryReady = false
        }
        continuation.finish()
    }

    private func scheduledDeliveryIsReady(revision: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, revision == scheduleRevision, scheduledDelivery != nil else { return }
        scheduledDelivery = nil
        signalDelivery()
    }

    /// All private helpers below run with the inbox lock held.
    private func signalDelivery() {
        deliveryReady = true
        guard !notificationPending else { return }
        notificationPending = true
        continuation.yield(())
    }

    private func cancelScheduledDelivery() {
        scheduleRevision &+= 1
        scheduledDelivery?()
        scheduledDelivery = nil
    }
}
