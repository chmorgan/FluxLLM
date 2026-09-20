import SwiftUI

/// One timeline, two explicit scales: returned tokens and this Mac's GPU.
/// Tool requests retain their own dashed, count-based track below the overlay.
struct LuminousActivityChart: View {
    let throughput: ChartDisplayHistory
    let gpu: ChartDisplayHistory
    let tools: ToolActivityHistory?
    let now: Date
    let duration: TimeInterval
    let compact: Bool
    let lanes: [RequestLane]
    let laneColorIndex: [UUID: Int]
    let requestTools: [UUID: ToolActivityHistory]
    let requestRails: RequestRailPresentation
    let heightCompression: CGFloat
    let isLive: Bool
    let observationTime: Date?
    let onSelectInterval: ((DateInterval) -> Void)?
    let onFitRequest: ((RequestLane) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.chartInspectionViewport) private var inspectionViewport
    @State private var tokenScale = ChartScaleState()
    @State private var toolScale = ChartScaleState()
    @State private var hoverLocation: CGPoint?
    @State private var dragSelection: DragSelection?
    @GestureState private var isSelecting = false

    init(
        throughput: ChartDisplayHistory, gpu: ChartDisplayHistory,
        tools: ToolActivityHistory?, now: Date, duration: TimeInterval,
        compact: Bool, lanes: [RequestLane] = [], laneColorIndex: [UUID: Int] = [:],
        requestTools: [UUID: ToolActivityHistory] = [:],
        requestRails: RequestRailPresentation? = nil,
        heightCompression: CGFloat = 0,
        isLive: Bool = true, observationTime: Date? = nil,
        onSelectInterval: ((DateInterval) -> Void)? = nil,
        onFitRequest: ((RequestLane) -> Void)? = nil
    ) {
        self.throughput = throughput
        self.gpu = gpu
        self.tools = tools
        self.now = now
        self.duration = duration
        self.compact = compact
        self.lanes = lanes
        let rails =
            requestRails
            ?? RequestRailState().update(lanes: lanes, snapshotTime: now, presentedAt: now)
        self.requestRails = rails
        self.laneColorIndex =
            laneColorIndex.isEmpty
            ? rails.assignments.mapValues(\.colorIndex) : laneColorIndex
        self.requestTools = requestTools
        self.heightCompression = min(max(heightCompression, 0), 1)
        self.isLive = isLive
        self.observationTime = observationTime
        self.onSelectInterval = onSelectInterval
        self.onFitRequest = onFitRequest
        var tokens = ChartScaleState()
        tokens.update(peak: throughput.peak ?? 0, now: now)
        _tokenScale = State(initialValue: tokens)
        var calls = ChartScaleState()
        calls.update(peak: tools?.peak ?? 0, now: now)
        _toolScale = State(initialValue: calls)
    }

    nonisolated static let laneBandHeight: CGFloat = RequestRailGeometry.bandHeight

    static func compactHeight(hasTools: Bool) -> CGFloat { hasTools ? 200 : 148 }
    nonisolated static func minimumHeight(hasTools: Bool, compression: CGFloat = 0) -> CGFloat {
        // The fixed lane band (requests) sits between the main plot and the tool
        // track only in the full view; the compact view keeps its prior height.
        let laneReserve = laneBandHeight + 22
        return (hasTools ? 232 : 176) + laneReserve - 40 * min(max(compression, 0), 1)
    }

    private var generatedColor: Color { TelemetryPalette.throughput(colorScheme) }
    private var gpuColor: Color { TelemetryPalette.gpu(colorScheme) }
    private var toolColor: Color {
        ToolActivityChartPresentation.color(colorScheme, increasedContrast: contrast == .increased)

    }
    private func laneColor(_ lane: RequestLane) -> Color {
        RequestLanePalette.color(at: laneColorIndex[lane.id] ?? 0, scheme: colorScheme)
    }
    private var inFlightCount: Int { lanes.filter { !$0.terminal }.count }

    /// Compact-surface pill: how many requests are in flight, since the
    /// compact view suppresses the full lane band. Hidden when idle.
    private var inFlightPill: some View {
        HStack(spacing: 4) {
            Circle().fill(generatedColor).frame(width: 6, height: 6).opacity(0.9)
            Text("\(inFlightCount) in flight")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .opacity(inFlightCount > 0 ? 1 : 0)
    }

    private var hasEffects: Bool { contrast != .increased && !reduceTransparency }
    private var strokeWidth: CGFloat { contrast == .increased ? 2.8 : (compact ? 2.2 : 2.7) }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                axisKey("tokens/s", color: generatedColor)
                Spacer(minLength: 8)
                axisKey("System GPU %", color: gpuColor)
            }
            .padding(.leading, 29)
            .padding(.trailing, 33)
            .accessibilityHidden(true)
            if compact { inFlightPill }
            plot
                .zIndex(1)
            HStack {
                Text(axisTimeLabel(secondsAgo: duration))
                    .help(
                        now.addingTimeInterval(-duration).formatted(
                            date: .abbreviated, time: .standard))
                Spacer()
                Text(axisTimeLabel(secondsAgo: duration / 2))
                    .help(
                        now.addingTimeInterval(-duration / 2).formatted(
                            date: .abbreviated, time: .standard))
                Spacer()
                Text(axisTimeLabel(secondsAgo: 0))
                    .help(now.formatted(date: .abbreviated, time: .standard))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.leading, 29)
            .padding(.trailing, 33)
            .accessibilityHidden(true)
        }
        .frame(
            minHeight: compact
                ? Self.compactHeight(hasTools: tools != nil)
                : Self.minimumHeight(hasTools: tools != nil, compression: heightCompression),
            maxHeight: compact ? Self.compactHeight(hasTools: tools != nil) : .infinity
        )
        .onAppear { updateScales() }
        .onChange(of: now) { _, _ in updateScales() }
        .onChange(of: throughput.peak) { _, _ in updateScales() }
        .onChange(of: tools?.peak) { _, _ in updateScales() }
        .onChange(of: duration) { _, _ in
            dragSelection = nil
            hoverLocation = nil
            updateScales()
        }
        .onChange(of: isLive) { _, _ in updateScales() }
        .onChange(of: isSelecting) { _, selecting in
            if !selecting { dragSelection = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint(navigationHint)
        .accessibilityActions {
            if !compact, let onFitRequest {
                ForEach(lanes, id: \.id) { lane in
                    Button(fitRequestLabel(lane)) { onFitRequest(lane) }
                }
            }
        }
    }

    private func axisKey(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 2)
            Text(label).foregroundStyle(color)
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
    }

    private var plot: some View {
        GeometryReader { geometry in
            let layout = PlotLayout(size: geometry.size, hasTools: tools != nil, compact: compact)
            let generated = projected(
                throughput.zeroFilledPlotSegments, in: layout.main,
                upperBound: tokenScale.upperBound)
            let device = projected(gpu.plotSegments, in: layout.main, upperBound: 100)
            // Tool tracks are drawn per request, each in its lane's color.
            let perLaneCallPoints: [(RequestLane, [[CGPoint]])] = lanes.compactMap { lane in
                guard let history = requestTools[lane.id] else { return nil }
                let points = projected(
                    history.zeroFilledPlotSegments, in: layout.tools,
                    upperBound: toolScale.upperBound)
                return (lane, points)
            }
            let selected = (dragSelection == nil ? hoverLocation : nil).flatMap {
                ChartInspectionGeometry.selection(
                    at: $0, now: now, duration: duration, main: layout.main,
                    rails: layout.lanes, tools: layout.tools,
                    lanes: lanes, assignments: requestRails.assignments)
            }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawGrid(in: &context, layout: layout)
                    drawSeries(
                        device, color: gpuColor, fillOpacity: 0.14, in: &context, rect: layout.main)
                    drawSeries(
                        generated, color: generatedColor, fillOpacity: 0.25, in: &context,
                        rect: layout.main)
                    drawEndpoint(generated.last?.last, color: generatedColor, in: &context)
                    if let current = gpu.current {
                        drawEndpoint(
                            project(
                                current.timestamp, value: current.value, in: layout.main,
                                upperBound: 100), color: gpuColor, in: &context)
                    }
                    for (lane, points) in perLaneCallPoints {
                        drawTools(
                            points, history: requestTools[lane.id]!, in: &context,
                            rect: layout.tools, color: laneColor(lane))
                    }
                    if !compact {
                        if layout.lanes.height > 0 {
                            context.draw(
                                Text("Requests")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.secondary),
                                at: CGPoint(x: layout.lanes.minX, y: layout.lanes.minY - 6),
                                anchor: .leading)
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                if !compact {
                    RequestRailLayer(
                        lanes: lanes, presentation: requestRails, now: now,
                        duration: duration, rect: layout.lanes, isLive: isLive
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                if let selected {
                    Canvas { context, _ in
                        drawCursor(
                            selected.timestamp, generated: generated, device: device,
                            in: &context, layout: layout)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                axes(layout: layout)
                selectionOverlay(layout: layout)
                if tools != nil { toolHeading(layout: layout) }
                layoutLandmark("main-activity-plot", rect: layout.main)
                if !compact { layoutLandmark("request-rail-band", rect: layout.lanes) }
                if let selected {
                    inspection(
                        selected: selected, generated: generated, device: device,
                        layout: layout, geometry: geometry)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                selectionGesture(in: layout),
                including: !compact && onSelectInterval != nil ? .all : .none
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    fitRequest(at: value.location, layout: layout)
                }, including: !compact && onFitRequest != nil ? .all : .none
            )
            .contextMenu {
                if !compact, let onFitRequest {
                    if let selected, case .request(let id) = selected.target,
                        let lane = lanes.first(where: { $0.id == id })
                    {
                        Button("Fit request") { onFitRequest(lane) }
                    } else {
                        ForEach(lanes, id: \.id) { lane in
                            Button(fitRequestLabel(lane)) { onFitRequest(lane) }
                        }
                    }
                }
            }
            .help(navigationHint)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if dragSelection == nil { hoverLocation = location }
                case .ended: hoverLocation = nil
                }
            }
            .onChange(of: geometry.frame(in: .global)) { _, _ in
                hoverLocation = nil
                dragSelection = nil
            }
        }
    }

    private struct DragSelection {
        let start: CGPoint
        let end: CGPoint
        let windowEnd: Date
    }

    private func selectionGesture(in layout: PlotLayout) -> some Gesture {
        DragGesture(minimumDistance: ChartTimeSelection.minimumDistance)
            .updating($isSelecting) { _, selecting, _ in selecting = true }
            .onChanged { value in
                let windowEnd = dragSelection?.windowEnd ?? now
                hoverLocation = nil
                dragSelection = DragSelection(
                    start: value.startLocation, end: value.location, windowEnd: windowEnd)
            }
            .onEnded { value in
                let windowEnd = dragSelection?.windowEnd ?? now
                dragSelection = nil
                hoverLocation = nil
                if let interval = ChartTimeSelection.interval(
                    from: value.startLocation, to: value.location, in: layout.selection,
                    endingAt: windowEnd, duration: duration)
                {
                    onSelectInterval?(interval)
                }
            }
    }

    @ViewBuilder
    private func selectionOverlay(layout: PlotLayout) -> some View {
        if let dragSelection,
            let interval = ChartTimeSelection.interval(
                from: dragSelection.start, to: dragSelection.end, in: layout.selection,
                endingAt: dragSelection.windowEnd, duration: duration)
        {
            let left = project(interval.start, value: 0, in: layout.main, upperBound: 1).x
            let right = project(interval.end, value: 0, in: layout.main, upperBound: 1).x
            Rectangle()
                .fill(generatedColor.opacity(0.12))
                .overlay(Rectangle().strokeBorder(generatedColor.opacity(0.5), lineWidth: 1))
                .frame(width: max(0, right - left), height: layout.selection.height)
                .offset(x: left, y: layout.selection.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func fitRequest(at location: CGPoint, layout: PlotLayout) {
        guard !compact, let onFitRequest,
            let selected = ChartInspectionGeometry.selection(
                at: location, now: now, duration: duration, main: layout.main,
                rails: layout.lanes, tools: layout.tools,
                lanes: lanes, assignments: requestRails.assignments),
            case .request(let id) = selected.target,
            let lane = lanes.first(where: { $0.id == id })
        else { return }
        hoverLocation = nil
        onFitRequest(lane)
    }

    private func fitRequestLabel(_ lane: RequestLane) -> String {
        let model = lane.model?.split(separator: "/").last.map(String.init) ?? "request"
        let start = lane.startedAt.formatted(date: .omitted, time: .standard)
        return "Fit \(model), \(start)"
    }

    private var navigationHint: String {
        guard !compact else { return "" }
        var hints: [String] = []
        if onSelectInterval != nil { hints.append("Drag across the chart to zoom into a period.") }
        if onFitRequest != nil {
            hints.append("Double-click a request or choose Fit request from its context menu.")
        }
        return hints.joined(separator: " ")
    }

    private func layoutLandmark(_ name: String, rect: CGRect) -> some View {
        Color.clear
            .frame(width: rect.width, height: rect.height)
            .anchorPreference(key: DashboardFrameAnchors.self, value: .bounds) { [name: $0] }
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private struct PlotLayout {
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
            // The lane band is fixed-height and always reserved in the full view
            // (it shows an empty state when no request history is visible); compact
            // suppresses it entirely.
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

    private func projected(
        _ segments: [[ChartDisplayPoint]], in rect: CGRect, upperBound: Double
    ) -> [[CGPoint]] {
        guard duration.isFinite, duration > 0, upperBound.isFinite, upperBound > 0 else {
            return []
        }
        return segments.map { points in
            points.map { project($0.timestamp, value: $0.value, in: rect, upperBound: upperBound) }
        }
    }

    private func project(_ timestamp: Date, value: Double, in rect: CGRect, upperBound: Double)
        -> CGPoint
    {
        let fraction = min(max(timestamp.timeIntervalSince(now) / duration + 1, 0), 1)
        return CGPoint(
            x: rect.minX + CGFloat(fraction) * rect.width,
            y: rect.maxY - CGFloat(min(max(value / upperBound, 0), 1)) * rect.height)
    }

    private func line(_ points: [CGPoint], smoothed: Bool) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            if smoothed {
                for span in ChartCurveGeometry.spans(points: points) {
                    if span.isVertical {
                        path.addLine(to: span.end)
                    } else {
                        path.addCurve(
                            to: span.end, control1: span.control1, control2: span.control2)
                    }
                }
            } else {
                for point in points.dropFirst() { path.addLine(to: point) }
            }
        }
    }

    private func drawSeries(
        _ segments: [[CGPoint]], color: Color, fillOpacity: Double,
        in context: inout GraphicsContext, rect: CGRect
    ) {
        for points in segments {
            guard let first = points.first, let last = points.last else { continue }
            let trace = line(points, smoothed: true)
            if hasEffects && points.count > 1 {
                var area = trace
                area.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                area.addLine(to: CGPoint(x: first.x, y: rect.maxY))
                area.closeSubpath()
                context.fill(
                    area,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: color.opacity(fillOpacity), location: 0),
                            .init(color: color.opacity(0.01), location: 1),
                        ]), startPoint: CGPoint(x: 0, y: rect.minY),
                        endPoint: CGPoint(x: 0, y: rect.maxY)))
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: compact ? 2.5 : 3))
                    glow.stroke(
                        trace, with: .color(color.opacity(colorScheme == .dark ? 0.35 : 0.24)),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                }
            }
            context.stroke(
                trace, with: .color(color),
                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            if points.count == 1 { drawEndpoint(first, color: color, in: &context) }
        }
    }

    private func drawEndpoint(_ point: CGPoint?, color: Color, in context: inout GraphicsContext) {
        guard let point else { return }
        if hasEffects {
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
                with: .color(color.opacity(0.13)))
        }
        let marker = Path(
            ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
        context.fill(marker, with: .color(Color(nsColor: .windowBackgroundColor)))
        context.stroke(marker, with: .color(color), lineWidth: 1.7)
    }

    private func drawGrid(in context: inout GraphicsContext, layout: PlotLayout) {
        var grid = Path()
        for fraction in [0.0, 0.5, 1.0] {
            let y = layout.main.minY + fraction * layout.main.height
            grid.move(to: CGPoint(x: layout.main.minX, y: y))
            grid.addLine(to: CGPoint(x: layout.main.maxX, y: y))
        }
        if tools != nil {
            grid.move(to: CGPoint(x: layout.tools.minX, y: layout.tools.maxY))
            grid.addLine(to: CGPoint(x: layout.tools.maxX, y: layout.tools.maxY))
        }
        context.stroke(
            grid, with: .color(.primary.opacity(contrast == .increased ? 0.3 : 0.10)),
            lineWidth: 0.6)
    }

    private func drawTools(
        _ segments: [[CGPoint]], history: ToolActivityHistory,
        in context: inout GraphicsContext, rect: CGRect, color: Color
    ) {
        for points in segments {
            context.stroke(
                line(points, smoothed: false), with: .color(color),
                style: StrokeStyle(
                    lineWidth: contrast == .increased ? 2.2 : 1.6, lineCap: .round,
                    lineJoin: .round, dash: [4, 3]))
        }
        for event in history.resultMarkers {
            let point = project(event.timestamp, value: 0, in: rect, upperBound: 1)
            var diamond = Path()
            diamond.move(to: CGPoint(x: point.x, y: point.y - 3))
            diamond.addLine(to: CGPoint(x: point.x + 3, y: point.y))
            diamond.addLine(to: CGPoint(x: point.x, y: point.y + 3))
            diamond.addLine(to: CGPoint(x: point.x - 3, y: point.y))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(color))
        }
    }

    private func drawCursor(
        _ timestamp: Date, generated: [[CGPoint]], device: [[CGPoint]],
        in context: inout GraphicsContext, layout: PlotLayout
    ) {
        let x = project(timestamp, value: 0, in: layout.main, upperBound: 1).x
        var cursor = Path()
        cursor.move(to: CGPoint(x: x, y: layout.main.minY))
        let bottom =
            tools != nil ? layout.tools.maxY : (compact ? layout.main.maxY : layout.lanes.maxY)
        cursor.addLine(to: CGPoint(x: x, y: bottom))
        context.stroke(cursor, with: .color(.secondary.opacity(0.55)), lineWidth: 0.8)
        for (segments, color) in [(generated, generatedColor), (device, gpuColor)] {
            if let y = inspectedY(atX: x, segments: segments) {
                drawEndpoint(CGPoint(x: x, y: y), color: color, in: &context)
            }
        }
    }

    private func inspectedY(atX x: CGFloat, segments: [[CGPoint]])
        -> CGFloat?
    {
        segments.compactMap { points in
            if points.count == 1, let point = points.first, point.x == x { return point.y }
            return ChartCurveGeometry.value(atX: x, spans: ChartCurveGeometry.spans(points: points))
        }.last
    }

    private func inspectedValue(
        atX x: CGFloat, segments: [[CGPoint]], rect: CGRect, upperBound: Double
    ) -> Double? {
        inspectedY(atX: x, segments: segments).map {
            min(max(Double((rect.maxY - $0) / rect.height) * upperBound, 0), upperBound)
        }
    }

    private func axes(layout: PlotLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { index in
                let fraction = Double(index) / 2
                let y = layout.main.maxY - fraction * layout.main.height
                Text(scaleLabel(tokenScale.upperBound * fraction))
                    .frame(width: 25, alignment: .trailing)
                    .position(x: 12.5, y: y)
                Text(String(Int(fraction * 100)))
                    .frame(width: 28, alignment: .leading)
                    .position(x: layout.main.maxX + 18, y: y)
            }
            if tools != nil {
                Text(scaleLabel(toolScale.upperBound))
                    .frame(width: 25, alignment: .trailing)
                    .position(x: 12.5, y: layout.tools.minY)
                Text("0")
                    .frame(width: 25, alignment: .trailing)
                    .position(x: 12.5, y: layout.tools.maxY)
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func toolHeading(layout: PlotLayout) -> some View {
        // The "Tool calls" label sits just above the tools track. Lane
        // colors are self-evident from the bands, so no palette legend is shown.
        HStack(spacing: 4) {
            Text("Tool calls")
            Spacer(minLength: 4)
            Text("0–\(scaleLabel(toolScale.upperBound)) calls/min")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.primary)
        .frame(width: layout.main.width, alignment: .leading)
        .offset(x: layout.main.minX, y: layout.tools.minY - 16)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func inspection(
        selected: ChartInspectionSelection, generated: [[CGPoint]], device: [[CGPoint]],
        layout: PlotLayout, geometry: GeometryProxy
    ) -> some View {
        if let pointer = hoverLocation {
            let bounds = inspectionBounds(in: geometry)
            let content = inspectionContent(
                selected: selected, generated: generated, device: device, layout: layout)
            let width = min(230, bounds.width)
            let height = ChartInspectionCard.height(for: content)
            // An impossibly small viewport should not receive a clipped or
            // unreadably scaled card. Normal dashboard sizes keep every row.
            if !bounds.isNull, !bounds.isInfinite, width >= 180, height <= bounds.height {
                let origin = ChartInspectionGeometry.cardOrigin(
                    pointer: pointer, cardSize: CGSize(width: width, height: height), bounds: bounds
                )
                ChartInspectionCard(
                    content: content, width: width, color: inspectionColor, hasEffects: hasEffects
                )
                .offset(x: origin.x, y: origin.y)
            }
        }
    }

    private func inspectionBounds(in geometry: GeometryProxy) -> CGRect {
        let local = CGRect(origin: .zero, size: geometry.size)
        guard let viewport = inspectionViewport else { return local.insetBy(dx: 6, dy: 6) }
        let frame = geometry.frame(in: .global)
        // Let inspection cards use the visible dashboard around the plot,
        // while keeping their edges inside the window.
        return viewport.offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: 6, dy: 6)
    }

    private func inspectionContent(
        selected: ChartInspectionSelection, generated: [[CGPoint]], device: [[CGPoint]],
        layout: PlotLayout
    ) -> ChartInspectionContent {
        let timestamp = selected.timestamp
        let active = ChartInspectionGeometry.activeLanes(at: timestamp, now: now, lanes: lanes)
        switch selected.target {
        case .plot:
            let x = project(timestamp, value: 0, in: layout.main, upperBound: 1).x
            return .plot(
                at: timestamp,
                generated: inspectedValue(
                    atX: x, segments: generated, rect: layout.main,
                    upperBound: tokenScale.upperBound
                ) ?? 0,
                gpu: inspectedValue(atX: x, segments: device, rect: layout.main, upperBound: 100),
                requestCount: active.count)
        case .request(let id):
            if let lane = active.first(where: { $0.id == id }) {
                return .request(lane, at: observationTime ?? now)
            }
            return .overflow(at: timestamp, lanes: [])
        case .overflow:
            let overflow = active.filter {
                (requestRails.assignments[$0.id]?.track ?? -1) >= RequestRailState.overflowTrack
            }
            return .overflow(at: timestamp, lanes: overflow)
        case .tools:
            let bucket = tools.flatMap {
                ChartInspectionContent.toolBucket(at: timestamp, in: $0, now: now)
            }
            let results =
                tools.map {
                    ToolActivityChartPresentation.results(
                        near: timestamp, in: $0, duration: duration, plotWidth: layout.tools.width)
                } ?? []
            return .tools(at: timestamp, bucket: bucket, results: results)
        }
    }

    private func inspectionColor(_ accent: ChartInspectionContent.Accent) -> Color {
        switch accent {
        case .generated: generatedColor
        case .gpu: gpuColor
        case .tools: toolColor
        case .secondary: .secondary
        case .request(let id):
            RequestLanePalette.color(at: laneColorIndex[id] ?? 0, scheme: colorScheme)
        }
    }
    private func updateScales() {
        if !isLive {
            tokenScale = ChartScaleState()
            toolScale = ChartScaleState()
        }
        tokenScale.update(peak: throughput.peak ?? 0, now: now)
        toolScale.update(peak: tools?.peak ?? 0, now: now)
    }

    private func scaleLabel(_ value: Double) -> String {
        let precision = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        if value >= 1_000_000 { return "\((value / 1_000_000).formatted(precision))M" }
        if value >= 1_000 { return "\((value / 1_000).formatted(precision))k" }
        return value.formatted(precision)
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        if seconds >= 3600 {
            let hours = Int(seconds / 3600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return minutes == 0 ? "−\(hours)h" : "−\(hours)h \(minutes)m"
        }
        return seconds >= 60 ? "−\(Int(seconds / 60))m" : "−\(Int(seconds))s"
    }

    private func axisTimeLabel(secondsAgo: TimeInterval) -> String {
        if isLive { return secondsAgo == 0 ? "Now" : timeLabel(secondsAgo) }
        let timestamp = now.addingTimeInterval(-secondsAgo)
        return timestamp.formatted(date: .omitted, time: duration < 300 ? .standard : .shortened)
    }

    private var accessibilityTitle: String {
        if isLive { return "Generated tokens and System GPU history, last \(spokenDuration)" }
        let start = now.addingTimeInterval(-duration).formatted(
            date: .abbreviated, time: .shortened)
        let end = now.formatted(date: .abbreviated, time: .shortened)
        return "Generated tokens and System GPU history, \(start) to \(end)"
    }

    private var spokenDuration: String {
        if duration >= 3600 { return "\(Int(duration / 3600)) hours" }
        return duration >= 60 ? "\(Int(duration / 60)) minutes" : "\(Int(duration)) seconds"
    }

    private var accessibilitySummary: String {
        let generated = String(format: "%.1f", throughput.current?.value ?? 0)
        let device = gpu.current.map { String(format: "%.0f percent", $0.value) } ?? "unavailable"
        var summary =
            "Generated \(generated) tokens per second, using the left scale. "
            + "System GPU \(device), using the right 0 to 100 percent scale. "
            + "GPU covers this Mac, including other apps."
        if let tools {
            let rate = String(format: "%.1f", tools.current?.callsPerMinute ?? 0)
            let calls = tools.buckets.reduce(0) { $0 + $1.callCount }
            summary +=
                " Dashed tool track: \(rate) calls per minute, independently scaled. "
                + "\(calls) tool calls and \(tools.resultMarkers.count) result submissions in this history."
        }
        if isLive && inFlightCount > 0 {
            summary +=
                " \(inFlightCount) \(inFlightCount == 1 ? "request" : "requests") in flight on separate reusable tracks."
        }
        if !compact,
            requestRails.assignments.values.contains(where: {
                $0.track == RequestRailState.overflowTrack
            })
        {
            summary +=
                " Additional requests share a counted overflow track; inspection summarizes their count and models."
        }
        return summary
    }
}
