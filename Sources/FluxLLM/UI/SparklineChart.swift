import SwiftUI

/// Time-based geometry shared by the detailed chart and compact status item.
enum SparklineGeometry {
    static let window: TimeInterval = 60

    /// The flat representation retains the compact chart's exact scale.
    static func normalizedPoints(samples: [TimeSeriesPoint], now: Date) -> [CGPoint] {
        let visible = visibleSamples(samples, now: now, duration: window).filter {
            $0.isAvailable && $0.value.isFinite
        }
        let upperBound = max(visible.map(\.value).max() ?? 0, 1)
        return visible.map {
            normalizedPoint($0, now: now, duration: window, upperBound: upperBound)
        }
    }

    /// Unavailable observations and gaps break paths instead of implying activity.
    static func normalizedSegments(
        samples: [TimeSeriesPoint], now: Date, duration: TimeInterval = window,
        upperBound: Double? = nil, pixelWidth: Int? = nil, maximumGap: TimeInterval = 5
    ) -> [[CGPoint]] {
        guard duration.isFinite && duration > 0 else { return [] }
        let visible = visibleSamples(samples, now: now, duration: duration)
        let peak = visible.filter { $0.isAvailable && $0.value.isFinite }.map(\.value).max() ?? 0
        let ceiling = max(upperBound ?? peak, 1)
        var segments: [[TimeSeriesPoint]] = []
        var current: [TimeSeriesPoint] = []
        for sample in visible {
            guard sample.isAvailable && sample.value.isFinite else {
                if !current.isEmpty { segments.append(current) }
                current = []
                continue
            }
            if let previous = current.last,
                sample.timestamp.timeIntervalSince(previous.timestamp) > maximumGap
            {
                segments.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { segments.append(current) }
        return segments.map { segment in
            let reduced = reduce(segment, now: now, duration: duration, pixelWidth: pixelWidth)
            return reduced.map {
                normalizedPoint($0, now: now, duration: duration, upperBound: ceiling)
            }
        }
    }

    static func visibleSamples(
        _ samples: [TimeSeriesPoint], now: Date, duration: TimeInterval
    ) -> [TimeSeriesPoint] {
        guard duration.isFinite && duration > 0 else { return [] }
        return samples.filter {
            $0.timestamp.timeIntervalSince(now).isFinite
                && $0.timestamp <= now && $0.timestamp >= now.addingTimeInterval(-duration)
        }.sorted { $0.timestamp < $1.timestamp }
    }

    /// A live marker must represent the latest observation, never reach back across a gap.
    static func currentSample(
        samples: [TimeSeriesPoint], now: Date, duration: TimeInterval,
        maximumAge: TimeInterval = 5
    ) -> TimeSeriesPoint? {
        guard maximumAge.isFinite && maximumAge >= 0,
            let latest = visibleSamples(samples, now: now, duration: duration).last,
            latest.isAvailable, latest.value.isFinite, latest.value >= 0,
            now.timeIntervalSince(latest.timestamp) <= maximumAge
        else { return nil }
        return latest
    }

    static func currentPoint(
        samples: [TimeSeriesPoint], now: Date, duration: TimeInterval,
        upperBound: Double, maximumAge: TimeInterval = 5
    ) -> CGPoint? {
        guard upperBound.isFinite && upperBound > 0,
            let sample = currentSample(
                samples: samples, now: now, duration: duration, maximumAge: maximumAge)
        else { return nil }
        return normalizedPoint(sample, now: now, duration: duration, upperBound: upperBound)
    }

    /// Keeps each pixel bucket's extrema in temporal order, preserving short bursts.
    private static func reduce(
        _ samples: [TimeSeriesPoint], now: Date, duration: TimeInterval, pixelWidth: Int?
    ) -> [TimeSeriesPoint] {
        guard let pixelWidth, pixelWidth > 0, samples.count > pixelWidth * 2 else {
            return samples
        }
        var result: [TimeSeriesPoint] = []
        var bucket: [TimeSeriesPoint] = []
        var bucketIndex: Int?
        func flush() {
            guard !bucket.isEmpty else { return }
            let minimum = bucket.indices.min { bucket[$0].value < bucket[$1].value } ?? 0
            let maximum = bucket.indices.max { bucket[$0].value < bucket[$1].value } ?? 0
            let indices = Set([0, minimum, maximum, bucket.count - 1]).sorted()
            result.append(contentsOf: indices.map { bucket[$0] })
            bucket.removeAll(keepingCapacity: true)
        }
        for sample in samples {
            let unitX = (sample.timestamp.timeIntervalSince(now) + duration) / duration
            let index = min(Int(unitX * Double(pixelWidth)), pixelWidth - 1)
            if let bucketIndex, bucketIndex != index { flush() }
            bucketIndex = index
            bucket.append(sample)
        }
        flush()
        return result
    }

    private static func normalizedPoint(
        _ sample: TimeSeriesPoint, now: Date, duration: TimeInterval, upperBound: Double
    ) -> CGPoint {
        CGPoint(
            x: (sample.timestamp.timeIntervalSince(now) + duration) / duration,
            y: min(max(sample.value, 0) / upperBound, 1))
    }

    static func niceUpperBound(for peak: Double) -> Double {
        guard peak.isFinite && peak > 0 else { return 1 }
        let target = max(min(peak, Double.greatestFiniteMagnitude / 1.15) * 1.15, 1)
        let magnitude = pow(10, floor(log10(target)))
        let fraction = target / magnitude
        let step = [1.0, 2, 5, 10].first { $0 >= fraction } ?? 10
        let bound = step * magnitude
        return bound.isFinite ? bound : Double.greatestFiniteMagnitude
    }
}

/// Grow immediately for a burst; shrink only after a sustained lower range.
struct ChartScaleState {
    private(set) var upperBound: Double = 1
    private var belowSince: Date?

    mutating func update(peak: Double, now: Date) {
        let desired = SparklineGeometry.niceUpperBound(for: peak)
        if desired > upperBound {
            upperBound = desired
            belowSince = nil
        } else if desired <= upperBound * 0.5 {
            if let belowSince, now.timeIntervalSince(belowSince) >= 8 {
                upperBound = desired
                self.belowSince = nil
            } else if belowSince == nil {
                belowSince = now
            }
        } else {
            belowSince = nil
        }
    }
}

enum ChartMetric {
    case throughput
    case gpuActivity

    /// Utilization has an absolute capacity scale; token rates adapt to recent history.
    var fixedUpperBound: Double? { self == .gpuActivity ? 100 : nil }

    var unit: String {
        switch self {
        case .throughput: "tokens/s"
        case .gpuActivity: "%"
        }
    }

    var spokenUnit: String {
        switch self {
        case .throughput: "tokens per second"
        case .gpuActivity: "percent system GPU utilization"
        }
    }

    var historyLabel: String {
        switch self {
        case .throughput: "Generated token history"
        case .gpuActivity: "System GPU utilization history"
        }
    }
}

enum ChartPresentationStyle {
    case framed
    case flow
}

struct SparklineChart: View {
    static let minimumFlexiblePlotHeight: CGFloat = 128

    let history: ChartDisplayHistory
    let now: Date
    var duration: TimeInterval = 60
    var height: CGFloat? = 150
    var metric: ChartMetric = .throughput
    var showsAxes: Bool = true
    var showsInspection: Bool = true
    var presentation: ChartPresentationStyle = .framed
    let toolActivity: ToolActivityHistory?
    var showsSeriesLegend: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale
    @State private var scale = ChartScaleState()
    @State private var toolScale = ChartScaleState()
    @State private var hoverLocation: CGPoint?

    private var axisWidth: CGFloat { metric == .throughput ? 62 : 34 }
    private let plotInset: CGFloat = 4
    private var hasYAxisGutter: Bool { showsAxes && presentation == .framed }
    private var upperBound: Double { metric.fixedUpperBound ?? scale.upperBound }
    private var hasSeriesLegend: Bool { toolActivity != nil || showsSeriesLegend }
    init(
        history: ChartDisplayHistory, now: Date, duration: TimeInterval = 60,
        height: CGFloat? = 150,
        metric: ChartMetric = .throughput, showsAxes: Bool = true, showsInspection: Bool = true,
        presentation: ChartPresentationStyle = .framed,
        toolActivity: ToolActivityHistory? = nil, showsSeriesLegend: Bool = false
    ) {
        self.history = history
        self.now = now
        self.duration = duration
        self.height = height
        self.metric = metric
        self.showsAxes = showsAxes
        self.showsInspection = showsInspection
        self.presentation = presentation
        self.toolActivity = metric == .throughput ? toolActivity : nil
        self.showsSeriesLegend = showsSeriesLegend
        var initialScale = ChartScaleState()
        initialScale.update(peak: history.peak ?? 0, now: now)
        _scale = State(initialValue: initialScale)
        var initialToolScale = ChartScaleState()
        initialToolScale.update(peak: toolActivity?.peak ?? 0, now: now)
        _toolScale = State(initialValue: initialToolScale)
    }

    var body: some View {
        let averageInterval = String(format: "%.0f", history.interval)
        return VStack(spacing: hasSeriesLegend && !showsAxes ? 4 : 6) {
            if hasSeriesLegend {
                seriesLegend
            } else if showsAxes && presentation == .flow {
                Text("\(rateLabel(upperBound)) \(metric.unit)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, plotInset)
            }
            HStack(alignment: .top, spacing: hasYAxisGutter ? 7 : 0) {
                if hasYAxisGutter { yAxis }
                plot(history: history)
            }
            if showsAxes {
                HStack {
                    Text(timeLabel(duration))
                    Spacer()
                    Text(timeLabel(duration / 2))
                    Spacer()
                    Text("Now")
                }
                .padding(.leading, hasYAxisGutter ? axisWidth + 7 : plotInset)
                .padding(.trailing, presentation == .flow ? plotInset : 0)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { updateScale() }
        .onChange(of: now) { _, _ in updateScale() }
        .onChange(of: duration) { _, _ in updateScale() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.historyLabel), last \(spokenDuration)")
        .accessibilityValue(accessibilitySummary(history: history))
        .help(
            "History shows \(averageInterval)-second averages. Current readings above the chart update independently."
                + (toolActivity == nil
                    ? ""
                    : " The dashed amber line uses a separate tool calls per minute scale. Diamonds mark tool results submitted to the model, not execution duration.")
        )
    }

    /// The two numerical scales are printed beside their own line keys, including
    /// in the compact menu, where unlabeled overlaid rates would be ambiguous.
    @ViewBuilder private var seriesLegend: some View {
        if showsAxes {
            HStack(alignment: .top, spacing: 8) {
                seriesKey(
                    title: metric == .throughput ? "Generated" : "GPU",
                    range: "0–\(rateLabel(upperBound)) \(metric.unit)",
                    color: lineColor, dashed: false, alignment: .leading)
                Spacer(minLength: 0)
                if toolActivity != nil {
                    seriesKey(
                        title: "Tool calls",
                        range: "0–\(rateLabel(toolScale.upperBound)) calls/min",
                        color: toolColor, dashed: true, alignment: .trailing)
                }
            }
            .frame(height: 22)
            .padding(.horizontal, plotInset)
            .accessibilityHidden(true)
        } else {
            HStack(spacing: 8) {
                compactSeriesKey(
                    title: "0–\(rateLabel(upperBound)) \(metric.unit)",
                    color: lineColor, dashed: false)
                Spacer(minLength: 0)
                if toolActivity != nil {
                    compactSeriesKey(
                        title: "Tool calls 0–\(rateLabel(toolScale.upperBound)) calls/min",
                        color: toolColor, dashed: true)
                }
            }
            .frame(height: 12)
            .padding(.horizontal, plotInset)
            .accessibilityHidden(true)
        }
    }

    private func compactSeriesKey(title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 3) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 10, y: 4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : []))
            .frame(width: 10, height: 8)
            Text(title).foregroundStyle(color)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .lineLimit(1).minimumScaleFactor(0.9)
    }

    private func seriesKey(
        title: String, range: String, color: Color, dashed: Bool,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            HStack(spacing: 4) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 4))
                    path.addLine(to: CGPoint(x: 14, y: 4))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : []))
                .frame(width: 14, height: 8)
                Text(title).foregroundStyle(color)
            }
            Text(range).foregroundStyle(.secondary)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }

    private var yAxis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(rateLabel(upperBound))
            Spacer()
            Text(rateLabel(upperBound / 2))
            Spacer()
            Text("0 \(metric.unit)")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(width: axisWidth, alignment: .trailing)
        .frame(
            minHeight: height ?? Self.minimumFlexiblePlotHeight,
            maxHeight: height ?? .infinity)
    }

    private func plot(history: ChartDisplayHistory) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            // Raw gaps are already split before averaging. Coarse history
            // points must not be reinterpreted as missing five-second samples.
            let segments = history.plotSegments.map { $0.map(normalizedPoint) }
            let selectedTime = inspectionTime(width: size.width)
            let selected = selectedTime.flatMap { history.bucket(at: $0) }
            let selectedTools = selectedTime.flatMap { toolActivity?.bucket(at: $0) }
            let selectedResults =
                selectedTime.flatMap { timestamp in
                    toolActivity.map {
                        ToolActivityChartPresentation.results(
                            near: timestamp, in: $0, duration: duration,
                            plotWidth: max(size.width - 2 * plotInset, 0))
                    }
                } ?? []
            let currentPoint = history.current.map(normalizedPoint)
            ZStack(alignment: .topLeading) {
                if presentation == .framed {
                    MetalChartSurface(compact: !showsAxes)
                }
                if showsAxes {
                    grid(size: size)
                } else if (height ?? Self.minimumFlexiblePlotHeight) >= 40 {
                    Path { path in
                        path.move(to: CGPoint(x: plotInset, y: size.height - plotInset))
                        path.addLine(
                            to: CGPoint(x: size.width - plotInset, y: size.height - plotInset))
                    }
                    .stroke(
                        Color.primary.opacity(contrast == .increased ? 0.3 : 0.10), lineWidth: 0.5)
                }
                ForEach(segments.indices, id: \.self) { index in
                    let points = segments[index]
                    plottedSegment(points: points, size: size)
                    if points.count == 1, let point = points.first, point != currentPoint {
                        Circle()
                            .fill(lineColor)
                            .frame(width: 2, height: 2)
                            .position(position(point, size: size))
                    }
                }
                if let currentPoint {
                    endpoint(at: position(currentPoint, size: size))
                }
                if let toolActivity {
                    toolOverlay(history: toolActivity, size: size)
                }
                if presentation == .framed {
                    MetalChartRim(compact: !showsAxes)
                } else if showsAxes {
                    HStack {
                        Text("0")
                        Spacer()
                        if toolActivity != nil { Text("0").foregroundStyle(toolColor) }
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, plotInset)
                    .padding(.bottom, plotInset + 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                if let selectedTime,
                    selected != nil || selectedTools != nil || !selectedResults.isEmpty
                {
                    inspection(
                        timestamp: selectedTime, bucket: selected, tools: selectedTools,
                        results: selectedResults, size: size)
                }
            }
            .clipShape(
                RoundedRectangle(cornerRadius: presentation == .flow ? 0 : (showsAxes ? 8 : 5))
            )
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard showsInspection else {
                    hoverLocation = nil
                    return
                }
                switch phase {
                case .active(let location): hoverLocation = location
                case .ended: hoverLocation = nil
                }
            }
        }
        .frame(
            minHeight: height ?? Self.minimumFlexiblePlotHeight,
            maxHeight: height ?? .infinity)
    }

    @ViewBuilder
    private func plottedSegment(points: [CGPoint], size: CGSize) -> some View {
        let line = trace(points: points, size: size)
        let fill = area(points: points, size: size)
        if hasSurfaceEffects {
            fill.fill(
                LinearGradient(
                    stops: [
                        .init(
                            color: lineColor.opacity(
                                presentation == .flow
                                    ? (showsAxes ? 0.16 : 0.13)
                                    : (showsAxes ? 0.10 : 0.07)), location: 0),
                        .init(
                            color: lineColor.opacity(
                                presentation == .flow ? 0.045 : (showsAxes ? 0.03 : 0.02)),
                            location: 0.55),
                        .init(
                            color: lineColor.opacity(presentation == .flow ? 0.01 : 0), location: 1),
                    ], startPoint: .top, endPoint: .bottom))
            underLineBand(line: line, area: fill)
        }
        line.stroke(
            lineColor,
            style: StrokeStyle(
                lineWidth: contrast == .increased
                    ? 2
                    : 1.25 / max(displayScale, 1),
                lineCap: .round, lineJoin: .round))
    }

    private func underLineBand(line: Path, area: Path) -> some View {
        let pixel = 1 / max(displayScale, 1)
        let isDark = colorScheme == .dark
        // Nested strokes fade within four physical pixels of the trace. Clip
        // each segment to its own area so the accent stays below the line and
        // cannot extend into missing-data gaps. The crisp trace is drawn last.
        return ZStack {
            line.stroke(
                lineColor.opacity(isDark ? 0.06 : 0.035),
                style: StrokeStyle(lineWidth: 8 * pixel, lineCap: .round, lineJoin: .round))
            line.stroke(
                lineColor.opacity(isDark ? 0.10 : 0.055),
                style: StrokeStyle(lineWidth: 5.5 * pixel, lineCap: .round, lineJoin: .round))
            line.stroke(
                lineColor.opacity(isDark ? 0.16 : 0.08),
                style: StrokeStyle(lineWidth: 3 * pixel, lineCap: .round, lineJoin: .round))
        }
        .clipShape(area)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var hasSurfaceEffects: Bool {
        contrast != .increased && !reduceTransparency
    }

    private func endpoint(at point: CGPoint) -> some View {
        Circle().fill(lineColor)
            .frame(width: showsAxes ? 3 : 2.5, height: showsAxes ? 3 : 2.5)
            .position(point)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func toolOverlay(history: ToolActivityHistory, size: CGSize) -> some View {
        let segments = ToolActivityChartPresentation.normalizedSegments(
            history: history, now: now, duration: duration, upperBound: toolScale.upperBound)
        return ZStack {
            ForEach(segments.indices, id: \.self) { index in
                trace(points: segments[index], size: size)
                    .stroke(
                        toolColor,
                        style: StrokeStyle(
                            lineWidth: contrast == .increased ? 2 : 1.25,
                            lineCap: .butt, lineJoin: .miter, dash: [4, 2]))
            }
            Path { path in
                let y = size.height - plotInset
                for event in history.resultMarkers {
                    let x = position(
                        CGPoint(
                            x: (event.timestamp.timeIntervalSince(now) + duration) / duration, y: 0),
                        size: size
                    ).x
                    path.move(to: CGPoint(x: x, y: y - 3))
                    path.addLine(to: CGPoint(x: x + 3, y: y))
                    path.addLine(to: CGPoint(x: x, y: y + 3))
                    path.addLine(to: CGPoint(x: x - 3, y: y))
                    path.closeSubpath()
                }
            }
            .fill(toolColor)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func grid(size: CGSize) -> some View {
        let horizontal = Path { path in
            for fraction in presentation == .flow ? [0.0, 1.0] : [0.0, 0.5, 1.0] {
                let y = plotInset + fraction * max(size.height - 2 * plotInset, 0)
                path.move(to: CGPoint(x: plotInset, y: y))
                path.addLine(to: CGPoint(x: size.width - plotInset, y: y))
            }
        }
        let vertical = Path { path in
            for fraction in [0.25, 0.5, 0.75] {
                let x = plotInset + fraction * max(size.width - 2 * plotInset, 0)
                path.move(to: CGPoint(x: x, y: plotInset))
                path.addLine(to: CGPoint(x: x, y: size.height - plotInset))
            }
        }
        return ZStack {
            horizontal.stroke(
                Color.primary.opacity(contrast == .increased ? 0.30 : 0.13), lineWidth: 0.5)
            if presentation == .framed {
                vertical.stroke(
                    Color.primary.opacity(contrast == .increased ? 0.15 : 0.055),
                    style: StrokeStyle(lineWidth: 0.5, dash: [2, 5]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func trace(points: [CGPoint], size: CGSize) -> Path {
        Path { path in
            for (index, point) in points.enumerated() {
                let coordinate = position(point, size: size)
                if index == 0 { path.move(to: coordinate) } else { path.addLine(to: coordinate) }
            }
        }
    }

    private func area(points: [CGPoint], size: CGSize) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last, points.count > 1 else { return }
            path.move(to: CGPoint(x: position(first, size: size).x, y: size.height - plotInset))
            for point in points { path.addLine(to: position(point, size: size)) }
            path.addLine(to: CGPoint(x: position(last, size: size).x, y: size.height - plotInset))
            path.closeSubpath()
        }
    }

    private func position(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: plotInset + point.x * max(size.width - 2 * plotInset, 0),
            y: plotInset + (1 - point.y) * max(size.height - 2 * plotInset, 0))
    }

    private func normalizedPoint(_ bucket: ChartDisplayBucket) -> CGPoint {
        normalizedPoint(ChartDisplayPoint(timestamp: bucket.timestamp, value: bucket.value))
    }

    private func normalizedPoint(_ point: ChartDisplayPoint) -> CGPoint {
        CGPoint(
            x: (point.timestamp.timeIntervalSince(now) + duration) / duration,
            y: min(max(point.value, 0) / upperBound, 1))
    }

    private func inspection(
        timestamp: Date, bucket: ChartDisplayBucket?, tools: ToolActivityBucket?,
        results: [ToolActivityEvent], size: CGSize
    ) -> some View {
        let x = position(
            CGPoint(x: (timestamp.timeIntervalSince(now) + duration) / duration, y: 0),
            size: size
        ).x
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(lineColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if let bucket {
                Circle().fill(lineColor).frame(width: 5, height: 5)
                    .position(x: x, y: position(normalizedPoint(bucket), size: size).y)
            }
            if let tools, tools.observedDuration > 0 {
                let y = position(
                    CGPoint(x: 0, y: min(tools.callsPerMinute / toolScale.upperBound, 1)),
                    size: size
                ).y
                Rectangle().fill(toolColor).frame(width: 5, height: 5)
                    .position(x: x, y: y)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let bucket {
                    Text(
                        "\(metric == .throughput ? "Generated " : "")\(bucket.value, specifier: "%.1f") \(metric.unit) average"
                    )
                    .foregroundStyle(lineColor)
                    Text(intervalDescription(start: bucket.start, end: bucket.end))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Generated rate unavailable").foregroundStyle(.secondary)
                }
                if let tools {
                    Text(ToolActivityChartPresentation.rateDescription(tools))
                        .foregroundStyle(toolColor)
                    Text(ToolActivityChartPresentation.countDescription(tools))
                    if let names = ToolActivityChartPresentation.namesDescription(tools) {
                        Text(names).foregroundStyle(.secondary)
                    }
                    Text("Tools \(intervalDescription(start: tools.start, end: tools.end))")
                        .foregroundStyle(.secondary)
                } else if toolActivity != nil {
                    Text("Tool-call rate unavailable").foregroundStyle(.secondary)
                }
                if let description = ToolActivityChartPresentation.resultDescription(results) {
                    Text("◇ \(description)").foregroundStyle(toolColor)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: max(size.width - 12, 0), alignment: .leading)
            .background {
                if reduceTransparency || contrast == .increased {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .textBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.regularMaterial)
                }
            }
            .padding(6)
        }
        .allowsHitTesting(false)
    }

    private func intervalDescription(start: Date, end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .standard))–\(end.formatted(date: .omitted, time: .standard))"
    }

    private func inspectionTime(width: CGFloat) -> Date? {
        guard showsInspection, let hoverLocation, width > 2 * plotInset else { return nil }
        let fraction = min(max((hoverLocation.x - plotInset) / (width - 2 * plotInset), 0), 1)
        return now.addingTimeInterval((fraction - 1) * duration)
    }

    private func updateScale() {
        guard metric.fixedUpperBound == nil else { return }
        let peak = history.peak ?? 0
        scale.update(peak: peak, now: now)
        toolScale.update(peak: toolActivity?.peak ?? 0, now: now)
    }

    private var toolColor: Color {
        ToolActivityChartPresentation.color(colorScheme, increasedContrast: contrast == .increased)
    }

    private var lineColor: Color {
        switch metric {
        case .throughput:
            TelemetryPalette.throughput(colorScheme)
        case .gpuActivity:
            TelemetryPalette.gpu(colorScheme)
        }
    }

    private func rateLabel(_ value: Double) -> String {
        if value >= 1_000 {
            let format = value.truncatingRemainder(dividingBy: 1_000) == 0 ? "%.0fk" : "%.1fk"
            return String(format: format, value / 1_000)
        }
        return String(format: value < 1 ? "%.1f" : "%.0f", value)
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        if seconds >= 3_600 { return String(format: "−%.0fh", seconds / 3_600) }
        if seconds >= 60 {
            let format = seconds.truncatingRemainder(dividingBy: 60) == 0 ? "−%.0fm" : "−%.1fm"
            return String(format: format, seconds / 60)
        }
        return String(format: "−%.0fs", seconds)
    }

    private var spokenDuration: String {
        if duration >= 60 { return "\(Int(duration / 60)) minutes" }
        return "\(Int(duration)) seconds"
    }

    private func accessibilitySummary(history: ChartDisplayHistory) -> String {
        let currentDescription =
            history.current.map {
                String(format: "Latest chart average %.1f", $0.value) + " \(metric.spokenUnit)"
            } ?? "Current chart average unavailable"
        let generatedDescription =
            history.peak.map { peak in
                String(format: "%.0f-second averages. ", history.interval) + currentDescription
                    + ", " + String(format: "peak average %.1f", peak) + " \(metric.spokenUnit)"
            } ?? "No samples yet"
        guard let toolActivity else { return generatedDescription }
        return generatedDescription + ". "
            + ToolActivityChartPresentation.accessibilitySummary(toolActivity)
    }
}
