import Foundation

/// Optional diagnostic counters; disabled during ordinary app operation.
/// An absent key means the metric is not instrumented. These work counters
/// never substitute for measured GPU execution time.
public final class PerformancePresentationCounters: @unchecked Sendable {
    public enum Metric: String, Sendable {
        case statusUpdates = "status_updates"
        case chartPreparations = "chart_preparations"
        case optimizedChartPreparations = "optimized_chart_preparations"
        case sharedChartNormalizationBuilds = "shared_chart_normalization_builds"
        case sharedChartPreparations = "shared_chart_preparations"
        case streamedBodiesWithoutPromises = "streamed_bodies_without_promises"
        case railFrameClockTicks = "rail_frame_clock_ticks"
        case railTimelineContentUpdates = "rail_timeline_content_updates"
        case orderedChartPublicationQueries = "ordered_chart_publication_queries"
        case chartPublicationFullSorts = "chart_publication_full_sorts"
        case directToolPlotBuilds = "direct_tool_plot_builds"
        case legacyToolPlotBuilds = "legacy_tool_plot_builds"
        case ungroupedNativeCanvasDraws = "ungrouped_native_canvas_draws"
        case groupedNativeCanvasDraws = "grouped_native_canvas_draws"
        case suppressedArrivalEffects = "suppressed_arrival_effects"
        case toolPathInputPoints = "tool_path_input_points"
        case toolPathOutputPoints = "tool_path_output_points"
        case historyToolOrderBuilds = "history_tool_order_builds"
        case historyCompletedOrderBuilds = "history_completed_order_builds"
        case historyToolOrderInsertions = "history_tool_order_insertions"
        case historyCompletedOrderInsertions = "history_completed_order_insertions"
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
        for metric in [
            Metric.statusUpdates, .chartPreparations, .canvasDraws,
            .optimizedChartPreparations, .historyToolOrderBuilds,
            .historyCompletedOrderBuilds, .historyToolOrderInsertions,
            .historyCompletedOrderInsertions, .sharedChartNormalizationBuilds,
            .sharedChartPreparations, .streamedBodiesWithoutPromises,
            .railFrameClockTicks, .railTimelineContentUpdates,
            .orderedChartPublicationQueries, .chartPublicationFullSorts,
            .directToolPlotBuilds, .legacyToolPlotBuilds,
            .ungroupedNativeCanvasDraws, .groupedNativeCanvasDraws,
            .suppressedArrivalEffects, .toolPathInputPoints, .toolPathOutputPoints,
        ] {
            values[metric.rawValue] = 0
        }
        enabled = true
    }

    public func record(_ metric: Metric, by count: UInt64 = 1) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        values[metric.rawValue, default: 0] &+= count
    }

    public func snapshot() -> [String: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
