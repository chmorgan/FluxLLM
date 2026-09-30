import Foundation

/// Optional diagnostic counters; disabled during ordinary app operation.
/// An absent key means the metric is not instrumented. These work counters
/// never substitute for measured GPU execution time.
public final class PerformancePresentationCounters: @unchecked Sendable {
    public enum Metric: String, Sendable {
        case statusUpdates = "status_updates"
        case chartPreparations = "chart_preparations"
        case canvasDraws = "canvas_draws"
        case metalFrames = "metal_frames"
    }

    public static let shared = PerformancePresentationCounters()
    private let lock = NSLock()
    private var enabled = false
    private var values: [String: UInt64] = [:]

    private init() {}

    public func enable() {
        lock.lock()
        defer { lock.unlock() }
        for metric in [Metric.statusUpdates, .chartPreparations, .canvasDraws] {
            values[metric.rawValue] = 0
        }
        enabled = true
    }

    public func record(_ metric: Metric) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        values[metric.rawValue, default: 0] &+= 1
    }

    public func snapshot() -> [String: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
