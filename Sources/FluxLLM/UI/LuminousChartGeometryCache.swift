import SwiftUI

/// One view-owned frame of drawing geometry. Publications identify immutable
/// histories, so a hover or scalar refresh never scans those histories for a key.
/// Coordinates are logical points with no pixel snapping; display scale and
/// appearance belong to SwiftUI's drawing pass, not this geometry's identity.
final class LuminousChartGeometryCache {
    struct Key: Equatable {
        let publicationID: UUID
        let now: Date
        let duration: TimeInterval
        let size: CGSize
        let compact: Bool
        let hasTools: Bool
        let tokenUpperBound: Double
        let toolUpperBound: Double
    }

    private var retained: Frame?

    func frame(
        for key: Key, throughput: ChartDisplayHistory, gpu: ChartDisplayHistory,
        requestTools: [UUID: ToolActivityHistory]
    ) -> Frame {
        if let retained, retained.key == key { return retained }
        let frame = Frame(key: key, throughput: throughput, gpu: gpu, requestTools: requestTools)
        retained = frame
        return frame
    }

    struct Layout {
        let main: CGRect
        let lanes: CGRect
        let tools: CGRect

        var selection: CGRect {
            let bottom = tools.height > 0 ? tools.maxY : (lanes.height > 0 ? lanes.maxY : main.maxY)
            return CGRect(
                x: main.minX, y: main.minY, width: main.width,
                height: bottom - main.minY)
        }

        init(size: CGSize, hasTools: Bool, compact: Bool) {
            let toolHeight: CGFloat = compact ? 30 : 34
            let laneBandHeight = RequestRailGeometry.bandHeight
            // Full charts reserve the fixed request band even with no lanes;
            // compact charts omit it, preserving the original plot dimensions.
            let laneReserve: CGFloat = compact ? 0 : (laneBandHeight + 22)
            let reserved: CGFloat = (hasTools ? toolHeight + 22 : 0) + laneReserve
            main = CGRect(
                x: 29, y: 5, width: max(size.width - 62, 1),
                height: max(size.height - 10 - reserved, 1))
            lanes = CGRect(
                x: main.minX, y: main.maxY + 22, width: main.width,
                height: laneReserve == 0 ? 0 : laneBandHeight)
            tools = CGRect(
                x: main.minX, y: main.maxY + 22 + laneReserve, width: main.width,
                height: hasTools ? toolHeight : 0)
        }
    }

    struct Segment {
        let points: [CGPoint]
        let spans: [ChartCurveGeometry.Span]
        let trace: Path
        let area: Path?

        init(points: [CGPoint], smoothed: Bool, baseline: CGFloat) {
            self.points = points
            spans = smoothed ? ChartCurveGeometry.spans(points: points) : []
            var trace = Path()
            if let first = points.first {
                trace.move(to: first)
                if smoothed {
                    for span in spans {
                        if span.isVertical {
                            trace.addLine(to: span.end)
                        } else {
                            trace.addCurve(
                                to: span.end, control1: span.control1, control2: span.control2)
                        }
                    }
                } else {
                    for point in points.dropFirst() { trace.addLine(to: point) }
                }
            }
            self.trace = trace
            if smoothed, points.count > 1, let first = points.first, let last = points.last {
                var area = trace
                area.addLine(to: CGPoint(x: last.x, y: baseline))
                area.addLine(to: CGPoint(x: first.x, y: baseline))
                area.closeSubpath()
                self.area = area
            } else {
                area = nil
            }
        }

        func inspectedY(atX x: CGFloat) -> CGFloat? {
            if points.count == 1, let point = points.first, point.x == x { return point.y }
            return ChartCurveGeometry.value(atX: x, spans: spans)
        }
    }

    struct ToolTrack {
        let segments: [Segment]
        let resultPoints: [CGPoint]
        let resultDiamonds: [Path]
    }

    final class Frame {
        let key: Key
        let layout: Layout
        let generated: [Segment]
        let device: [Segment]
        let generatedEndpoint: CGPoint?
        let deviceEndpoint: CGPoint?
        let requestTools: [UUID: ToolTrack]

        init(
            key: Key, throughput: ChartDisplayHistory, gpu: ChartDisplayHistory,
            requestTools: [UUID: ToolActivityHistory]
        ) {
            self.key = key
            let layout = Layout(size: key.size, hasTools: key.hasTools, compact: key.compact)
            self.layout = layout
            generated = Self.segments(
                throughput.zeroFilledPlotSegments, key: key, rect: layout.main,
                upperBound: key.tokenUpperBound, smoothed: true)
            device = Self.segments(
                gpu.plotSegments, key: key, rect: layout.main,
                upperBound: 100, smoothed: true)
            generatedEndpoint = generated.last?.points.last
            deviceEndpoint = gpu.current.map {
                Self.project(
                    $0.timestamp, value: $0.value, key: key, rect: layout.main, upperBound: 100)
            }
            self.requestTools = requestTools.mapValues { history in
                let points = history.resultMarkers.map {
                    Self.project(
                        $0.timestamp, value: 0, key: key, rect: layout.tools, upperBound: 1)
                }
                return ToolTrack(
                    segments: Self.segments(
                        history.zeroFilledPlotSegments, key: key, rect: layout.tools,
                        upperBound: key.toolUpperBound, smoothed: false),
                    resultPoints: points,
                    resultDiamonds: points.map { point in
                        var diamond = Path()
                        diamond.move(to: CGPoint(x: point.x, y: point.y - 3))
                        diamond.addLine(to: CGPoint(x: point.x + 3, y: point.y))
                        diamond.addLine(to: CGPoint(x: point.x, y: point.y + 3))
                        diamond.addLine(to: CGPoint(x: point.x - 3, y: point.y))
                        diamond.closeSubpath()
                        return diamond
                    })
            }
        }

        private static func segments(
            _ segments: [[ChartDisplayPoint]], key: Key, rect: CGRect, upperBound: Double,
            smoothed: Bool
        ) -> [Segment] {
            guard key.duration.isFinite, key.duration > 0, upperBound.isFinite, upperBound > 0
            else {
                return []
            }
            return segments.map { points in
                Segment(
                    points: points.map {
                        project(
                            $0.timestamp, value: $0.value, key: key, rect: rect,
                            upperBound: upperBound)
                    }, smoothed: smoothed, baseline: rect.maxY)
            }
        }

        private static func project(
            _ timestamp: Date, value: Double, key: Key, rect: CGRect, upperBound: Double
        ) -> CGPoint {
            let fraction = min(max(timestamp.timeIntervalSince(key.now) / key.duration + 1, 0), 1)
            return CGPoint(
                x: rect.minX + CGFloat(fraction) * rect.width,
                y: rect.maxY - CGFloat(min(max(value / upperBound, 0), 1)) * rect.height)
        }
    }
}

/// Native surface bounds, distinct from the full-chart coordinate system used
/// by cached paths. Clipping alone would leave an unnecessarily large backing.
enum ChartSurfaceBounds {
    // The furthest spark endpoint is <40.09pt from its origin, including its
    // round stroke cap. Other burst families, glints and lightning fit inside.
    static let decorationMargin: CGFloat = 41
    static let cursorMargin: CGFloat = 7  // 6pt endpoint halo plus antialiasing.

    static func decorations(rail: CGRect, plotSize: CGSize) -> CGRect {
        guard valid(rail), let plot = plotRect(plotSize) else { return .zero }
        return clipped(rail.insetBy(dx: -decorationMargin, dy: -decorationMargin), to: plot)
    }

    static func cursor(x: CGFloat, plotSize: CGSize) -> CGRect {
        guard x.isFinite, let plot = plotRect(plotSize) else { return .zero }
        return clipped(
            CGRect(x: x - cursorMargin, y: 0, width: cursorMargin * 2, height: plot.height),
            to: plot)
    }

    private static func plotRect(_ size: CGSize) -> CGRect? {
        guard size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: .zero, size: size)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        // CGRect's width/height accessors standardize negative raw sizes.
        // Invalid layout proposals must not become small drawable slivers.
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite
            && rect.size.height.isFinite && rect.size.width > 0 && rect.size.height > 0
    }

    private static func clipped(_ rect: CGRect, to plot: CGRect) -> CGRect {
        let result = rect.intersection(plot)
        guard !result.isNull, !result.isEmpty else { return .zero }
        // Integer-point origins keep the original pixel phase at both supported
        // 1x and 2x backing scales, including fractional chart layout sizes.
        let aligned = CGRect(
            x: floor(result.minX), y: floor(result.minY),
            width: ceil(result.maxX) - floor(result.minX),
            height: ceil(result.maxY) - floor(result.minY))
        return aligned.intersection(plot)
    }
}
