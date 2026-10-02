import Foundation
import Observation

/// Diagnostic Canvas clock. Only the drawing closure reads `date`; scheduling
/// state is not observed by SwiftUI. Wall time preserves the existing effect
/// ages, while monotonic deadlines bound wakeups independently of clock changes.
@MainActor @Observable
final class RequestRailFrameClock {
    static let interval: TimeInterval = 1.0 / 30

    private var tickDate: Date?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var deadline: TimeInterval?

    // Canvas may draw before its task starts. Never reuse an old episode's date.
    var date: Date { tickDate ?? Date() }

    @discardableResult
    func start(at date: Date, monotonicTime: TimeInterval) -> UInt64 {
        generation &+= 1
        deadline = nil
        guard date.timeIntervalSinceReferenceDate.isFinite, monotonicTime.isFinite else {
            tickDate = nil
            return generation
        }
        deadline = monotonicTime + Self.interval
        tickDate = date
        PerformancePresentationCounters.shared.record(.railFrameClockTicks)
        return generation
    }

    func nextDeadline(for generation: UInt64) -> TimeInterval? {
        self.generation == generation ? deadline : nil
    }

    @discardableResult
    func tick(generation: UInt64, at date: Date, monotonicTime: TimeInterval) -> Bool {
        guard self.generation == generation, let deadline,
            date.timeIntervalSinceReferenceDate.isFinite, monotonicTime.isFinite,
            monotonicTime >= deadline
        else { return false }
        // A delayed frame advances directly to the current age. Never replay
        // missed frames or schedule the next one less than a full interval away.
        self.deadline = monotonicTime + Self.interval
        tickDate = date
        PerformancePresentationCounters.shared.record(.railFrameClockTicks)
        return true
    }

    func stop(generation: UInt64? = nil) {
        if let generation, self.generation != generation { return }
        self.generation &+= 1
        deadline = nil
        tickDate = nil
    }

    func run() async {
        guard !Task.isCancelled else { return }
        let generation = start(at: Date(), monotonicTime: ProcessInfo.processInfo.systemUptime)
        defer { stop(generation: generation) }
        while !Task.isCancelled, let deadline = nextDeadline(for: generation) {
            do {
                try await Task.sleep(
                    for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            } catch { return }
            guard !Task.isCancelled else { return }
            tick(
                generation: generation, at: Date(),
                monotonicTime: ProcessInfo.processInfo.systemUptime)
        }
    }
}
