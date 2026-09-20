import CoreGraphics
import Foundation

/// Maps a horizontal drag to the same time bounds used to draw the chart.
enum ChartTimeSelection {
    static let minimumDistance: CGFloat = 8

    static func interval(
        from start: CGPoint, to end: CGPoint, in plot: CGRect,
        endingAt windowEnd: Date, duration: TimeInterval
    ) -> DateInterval? {
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
            plot.origin.x.isFinite, plot.origin.y.isFinite,
            plot.width.isFinite, plot.height.isFinite,
            plot.size.width > 0, plot.size.height > 0,
            plot.maxX.isFinite, plot.maxY.isFinite,
            duration.isFinite, duration > 0,
            windowEnd.timeIntervalSinceReferenceDate.isFinite,
            windowEnd.addingTimeInterval(-duration).timeIntervalSinceReferenceDate.isFinite,
            start.x >= plot.minX, start.x <= plot.maxX,
            start.y >= plot.minY, start.y <= plot.maxY
        else { return nil }

        let startX = min(plot.maxX, max(plot.minX, start.x))
        let endX = min(plot.maxX, max(plot.minX, end.x))
        guard abs(endX - startX) >= minimumDistance else { return nil }
        let lowerFraction = Double((min(startX, endX) - plot.minX) / plot.width)
        let upperFraction = Double((max(startX, endX) - plot.minX) / plot.width)
        let lower = windowEnd.addingTimeInterval((lowerFraction - 1) * duration)
        let upper = windowEnd.addingTimeInterval((upperFraction - 1) * duration)
        guard lower < upper else { return nil }
        return DateInterval(start: lower, end: upper)
    }
}
