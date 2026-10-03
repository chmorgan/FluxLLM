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
        requestTools: [UUID: ToolActivityHistory], directToolPlot: Bool = false,
        compactToolPaths: Bool = false, deferredToolGeometry: Bool = false,
        buildDrawingPaths: Bool = true
    ) -> Frame {
        if let retained, retained.key == key, retained.directToolPlot == directToolPlot,
            retained.compactToolPaths == compactToolPaths,
            retained.deferredToolGeometry == deferredToolGeometry,
            retained.buildDrawingPaths == buildDrawingPaths
        {
            return retained
        }
        let frame = Frame(
            key: key, throughput: throughput, gpu: gpu, requestTools: requestTools,
            directToolPlot: directToolPlot, compactToolPaths: compactToolPaths,
            deferredToolGeometry: deferredToolGeometry,
            buildDrawingPaths: buildDrawingPaths)
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
        let tracePointCount: Int

        init(
            points: [CGPoint], smoothed: Bool, baseline: CGFloat,
            compactToolPaths: Bool = false, buildDrawingPaths: Bool = true
        ) {
            self.points = points
            spans = smoothed ? ChartCurveGeometry.spans(points: points) : []
            var trace = Path()
            var tracePointCount = points.count
            if let first = points.first {
                if buildDrawingPaths { trace.move(to: first) }
                if smoothed {
                    tracePointCount = spans.count + 1
                    if buildDrawingPaths {
                        for span in spans {
                            if span.isVertical {
                                trace.addLine(to: span.end)
                            } else {
                                trace.addCurve(
                                    to: span.end, control1: span.control1, control2: span.control2)
                            }
                        }
                    }
                } else if compactToolPaths {
                    for index in 1..<points.count {
                        if index < points.count - 1,
                            Self.isHorizontalInterior(
                                points[index - 1], points[index], points[index + 1])
                        {
                            tracePointCount -= 1
                        } else if buildDrawingPaths {
                            trace.addLine(to: points[index])
                        }
                    }
                } else if buildDrawingPaths {
                    for point in points.dropFirst() { trace.addLine(to: point) }
                }
            }
            self.trace = trace
            self.tracePointCount = tracePointCount
            if buildDrawingPaths, smoothed, points.count > 1,
                let first = points.first, let last = points.last
            {
                var area = trace
                area.addLine(to: CGPoint(x: last.x, y: baseline))
                area.addLine(to: CGPoint(x: first.x, y: baseline))
                area.closeSubpath()
                self.area = area
            } else {
                area = nil
            }
        }

        /// Only exact horizontal interiors can disappear from a tool trace.
        /// Inspect original neighbors so duplicate, reversed, vertical, and
        /// nonfinite vertices retain their original command boundaries.
        private static func isHorizontalInterior(
            _ previous: CGPoint, _ point: CGPoint, _ next: CGPoint
        ) -> Bool {
            previous.x.isFinite && previous.y.isFinite
                && point.x.isFinite && point.y.isFinite
                && next.x.isFinite && next.y.isFinite
                && previous.y == point.y && point.y == next.y
                && previous.x < point.x && point.x < next.x
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
        // Allocated only by an actual draw in the cpu-glow diagnostic mode.
        // Replacing the geometry frame also releases its bounded mask cache.
        lazy var seriesGlowRasterCache = SeriesGlowRasterCache()
        let key: Key
        let directToolPlot: Bool
        let compactToolPaths: Bool
        let deferredToolGeometry: Bool
        let buildDrawingPaths: Bool
        let layout: Layout
        let generated: [Segment]
        let device: [Segment]
        let generatedEndpoint: CGPoint?
        let deviceEndpoint: CGPoint?
        private let toolGeometry: ToolGeometryHolder
        var requestTools: [UUID: ToolTrack] { toolGeometry.value() }

        /// Canvas may first read a frame from its drawing callback. Keep that
        /// construction one-shot even when readers arrive on different threads.
        /// The pending factory holds only immutable inputs, never its Frame.
        private final class ToolGeometryHolder {
            private let lock = NSLock()
            private var pendingFactory: (() -> [UUID: ToolTrack])?
            private var prepared: [UUID: ToolTrack]?

            init(factory: @escaping () -> [UUID: ToolTrack]) {
                pendingFactory = factory
            }

            func value() -> [UUID: ToolTrack] {
                lock.lock()
                defer { lock.unlock() }
                if let prepared { return prepared }
                // The factory is removed only after its result is retained,
                // under this same lock, including an empty track dictionary.
                let result = pendingFactory!()
                prepared = result
                pendingFactory = nil
                return result
            }
        }

        init(
            key: Key, throughput: ChartDisplayHistory, gpu: ChartDisplayHistory,
            requestTools: [UUID: ToolActivityHistory], directToolPlot: Bool = false,
            compactToolPaths: Bool = false, deferredToolGeometry: Bool = false,
            buildDrawingPaths: Bool = true
        ) {
            self.key = key
            self.directToolPlot = directToolPlot
            self.compactToolPaths = compactToolPaths
            self.deferredToolGeometry = deferredToolGeometry
            self.buildDrawingPaths = buildDrawingPaths
            let layout = Layout(size: key.size, hasTools: key.hasTools, compact: key.compact)
            self.layout = layout
            generated = Self.segments(
                throughput.zeroFilledPlotSegments, key: key, rect: layout.main,
                upperBound: key.tokenUpperBound, smoothed: true,
                buildDrawingPaths: buildDrawingPaths)
            device = Self.segments(
                gpu.plotSegments, key: key, rect: layout.main,
                upperBound: 100, smoothed: true, buildDrawingPaths: buildDrawingPaths)
            generatedEndpoint = generated.last?.points.last
            deviceEndpoint = gpu.current.map {
                Self.project(
                    $0.timestamp, value: $0.value, key: key, rect: layout.main, upperBound: 100)
            }
            let toolGeometry = ToolGeometryHolder {
                [
                    requestTools, key, toolRect = layout.tools, directToolPlot, compactToolPaths,
                    buildDrawingPaths
                ] in
                Self.makeToolTracks(
                    requestTools, key: key, rect: toolRect,
                    directToolPlot: directToolPlot, compactToolPaths: compactToolPaths,
                    buildDrawingPaths: buildDrawingPaths)
            }
            self.toolGeometry = toolGeometry
            if !deferredToolGeometry { _ = toolGeometry.value() }
        }

        private static func makeToolTracks(
            _ requestTools: [UUID: ToolActivityHistory], key: Key, rect: CGRect,
            directToolPlot: Bool, compactToolPaths: Bool, buildDrawingPaths: Bool
        ) -> [UUID: ToolTrack] {
            var toolPathInputPoints: UInt64 = 0
            var toolPathOutputPoints: UInt64 = 0
            var uniqueToolTraceBuilds: UInt64 = 0
            var reusedToolTraceBuilds: UInt64 = 0
            // Identical rate traces can belong to distinct requests. Share only
            // immutable geometry within this frame; every lane still draws in
            // its original order/color and owns its independent result markers.
            var sharedTraces: [ToolActivityHistory.PlotKey: [Segment]] = [:]
            let tracks = requestTools.mapValues { history in
                let points = history.resultMarkers.map {
                    Self.project($0.timestamp, value: 0, key: key, rect: rect, upperBound: 1)
                }
                let segments: [Segment]
                if let plotKey = history.reusablePlotKey, let shared = sharedTraces[plotKey] {
                    reusedToolTraceBuilds &+= 1
                    segments = shared
                } else {
                    uniqueToolTraceBuilds &+= 1
                    let plotSegments =
                        directToolPlot
                        ? history.directZeroFilledPlotSegments : history.zeroFilledPlotSegments
                    segments = Self.segments(
                        plotSegments, key: key, rect: rect,
                        upperBound: key.toolUpperBound, smoothed: false,
                        compactToolPaths: compactToolPaths, buildDrawingPaths: buildDrawingPaths)
                    if let plotKey = history.reusablePlotKey { sharedTraces[plotKey] = segments }
                }
                for segment in segments {
                    toolPathInputPoints &+= UInt64(segment.points.count)
                    toolPathOutputPoints &+= UInt64(segment.tracePointCount)
                }
                return ToolTrack(
                    segments: segments,
                    resultPoints: points,
                    resultDiamonds: buildDrawingPaths
                        ? points.map { point in
                            var diamond = Path()
                            diamond.move(to: CGPoint(x: point.x, y: point.y - 3))
                            diamond.addLine(to: CGPoint(x: point.x + 3, y: point.y))
                            diamond.addLine(to: CGPoint(x: point.x, y: point.y + 3))
                            diamond.addLine(to: CGPoint(x: point.x - 3, y: point.y))
                            diamond.closeSubpath()
                            return diamond
                        } : [])
            }
            PerformancePresentationCounters.shared.recordToolTraces(
                unique: uniqueToolTraceBuilds, reused: reusedToolTraceBuilds,
                direct: directToolPlot)
            if toolPathInputPoints > 0 {
                PerformancePresentationCounters.shared.record(
                    .toolPathInputPoints, by: toolPathInputPoints)
                PerformancePresentationCounters.shared.record(
                    .toolPathOutputPoints, by: toolPathOutputPoints)
            }
            return tracks
        }

        private static func segments(
            _ segments: [[ChartDisplayPoint]], key: Key, rect: CGRect, upperBound: Double,
            smoothed: Bool, compactToolPaths: Bool = false, buildDrawingPaths: Bool = true
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
                    }, smoothed: smoothed, baseline: rect.maxY,
                    compactToolPaths: compactToolPaths, buildDrawingPaths: buildDrawingPaths)
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
