import SwiftUI

/// Native layout landmarks shared by the retained-host transition checks.
enum DashboardFrameAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(
        value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct DashboardView: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var presentation: DashboardPresentationState
    let actions: MenuActions
    let isCompact: Bool

    static let compactWidth: CGFloat = 360
    static let preferredWindowSize = DashboardSizingPolicy.preferredWindowSize

    init(
        actions: MenuActions = MenuActions(), isCompact: Bool = false,
        presentation: DashboardPresentationState = DashboardPresentationState()
    ) {
        self.actions = actions
        self.isCompact = isCompact
        _presentation = State(initialValue: presentation)
    }

    var body: some View {
        Group {
            if isCompact {
                compactContent.fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.compactWidth)
            } else {
                GeometryReader { viewport in
                    let widthPolicy = DashboardWidthPolicy(viewportWidth: viewport.size.width)
                    let density = DashboardHeightPolicy(
                        viewportHeight: viewport.size.height, viewportWidth: viewport.size.width)
                    dashboardContent(narrow: widthPolicy.usesNarrowLayout, density: density)
                        .frame(
                            width: viewport.size.width, height: viewport.size.height,
                            alignment: .topLeading
                        )
                        .environment(\.chartInspectionViewport, viewport.frame(in: .global))
                }
            }
        }
        .background(TelemetryPanelBackground())
        .onAppear { updateChartViewport(for: currentNavigation) }
        .onChange(of: store.monitoringEpoch) { _, _ in
            presentation.synchronize(with: store)
            updateChartViewport(for: currentNavigation)
        }
        .onChange(of: currentNavigation) { _, navigation in
            updateChartViewport(for: navigation)
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardScalarContent { header() }
            activityCard()
            if store.backendKind != nil {
                DashboardScalarContent { compactDetails }
            }
            Divider()
            Button(action: actions.onOpenDashboardWindow) {
                HStack {
                    Image(systemName: "arrow.up.right.square")
                    Text("Open Dashboard")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(throughputColor)
            .help("Open a persistent window with larger charts and history controls")
            .accessibilityIdentifier("open-dashboard")
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 13)
    }

    private func dashboardContent(narrow: Bool, density: DashboardHeightPolicy) -> some View {
        DashboardStackLayout(spacing: density.rowSpacing) {
            DashboardScalarContent { header(narrow: narrow, density: density) }
            historyControls(narrow: narrow)
            activityCard(narrow: narrow, density: density)
                .layoutValue(key: DashboardFlexibleRow.self, value: true)
            if store.backendKind != nil {
                VStack(alignment: .leading, spacing: density.value(8, 4)) {
                    Divider()
                    DashboardScalarContent { dashboardDetails(narrow: narrow, density: density) }
                }
            }
            DashboardScalarContent {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(GPUActivityPresentation.summary)
                        .lineLimit(narrow ? nil : 1).minimumScaleFactor(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .help(gpuHelp)
                .anchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
                    ["dashboard-footer": $0]
                }
            }
        }
        .padding(.horizontal, DashboardSizingPolicy.horizontalInset)
        .padding(.vertical, density.verticalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transformAnchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
            $0["dashboard-content"] = $1
        }
    }

    private func historyControls(narrow: Bool) -> some View {
        let layout =
            narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout())
        return layout {
            HistoryControls(
                navigation: navigationBinding, now: store.chartPresentation.timestamp,
                historyAge: store.chartHistoryAge, narrow: narrow)
        }
        .anchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
            ["history-controls": $0]
        }
    }

    private func header(narrow: Bool = false, density: DashboardHeightPolicy = .roomy) -> some View
    {
        VStack(alignment: .leading, spacing: isCompact ? 7 : density.value(4, 3)) {
            headerTitleRow(narrow: narrow, density: density)
            if narrow { statusControl }
            providerModelLine(narrow: narrow)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard-header")
        .transformAnchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
            frames, bounds in
            frames["dashboard-header"] = bounds
        }
    }

    private func headerTitleRow(narrow: Bool, density: DashboardHeightPolicy) -> some View {
        HStack(spacing: 8) {
            if let logo = BrandingAssets.brandMark(for: colorScheme == .dark ? .dark : .light) {
                Image(nsImage: logo).resizable().renderingMode(.original).scaledToFit()
                    .frame(
                        width: isCompact ? 28 : density.value(36, 30),
                        height: isCompact ? 24 : density.value(30, 24)
                    )
                    .accessibilityHidden(true)
            }
            Text(MenuBarExtraView.appTitle)
                .font(.system(size: isCompact ? 14 : density.value(20, 16), weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if !narrow { statusControl }
            CommandMenu(actions: actions)
        }
        .frame(minHeight: isCompact ? 28 : density.value(34, 28))
    }

    private func providerModelLine(narrow: Bool) -> some View {
        let layout =
            narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 5))
        return layout {
            HStack(spacing: 5) {
                Text(store.backendKind?.title ?? "LLM monitor").fixedSize()
                Text("·")
                Text(modelLabel).lineLimit(1).truncationMode(.middle)
                    .help(modelLabel)
            }
            .frame(height: 14)
            if !narrow { Spacer(minLength: 6) }
            // Reserve the activity line even while idle so incoming requests
            // do not push the chart down in the stacked header.
            Text(BackendPresentation.activityDetail(store: store) ?? "")
                .lineLimit(1).minimumScaleFactor(0.85)
                .monospacedDigit()
                .frame(height: 14)
                .layoutPriority(1)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .frame(height: narrow ? nil : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("provider-model")
        .anchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
            ["provider-model": $0]
        }
    }

    @ViewBuilder private var statusControl: some View {
        if let prompt = BackendPresentation.configurationPrompt(store: store) {
            Button(action: actions.onShowSettings) { statusBadge }
                .buttonStyle(.plain)
                .help(prompt)
                .accessibilityHint("Open Settings")
                .accessibilityIdentifier("backend-settings")
        } else {
            statusBadge
        }
    }

    private func throughputValue(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(BackendPresentation.rateLabel(store: store))
                .font(.system(size: size, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("tokens/s").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .frame(height: ceil(size * 1.25))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Generated")
        .accessibilityValue("\(BackendPresentation.rateLabel(store: store)) tokens per second")
        .accessibilityIdentifier("throughput-value")
        .anchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
            ["throughput-value": $0]
        }
        .accessibilityHint(throughputHelp)
        .help(throughputHelp)
    }

    private func activityCard(
        narrow: Bool = false, density: DashboardHeightPolicy = .roomy
    ) -> some View {
        let prepared = preparedCharts
        let metricLayout =
            narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: density.value(12, 8)))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return VStack(alignment: .leading, spacing: isCompact ? 10 : density.cardSpacing) {
            DashboardScalarContent {
                metricLayout {
                    VStack(alignment: .leading, spacing: isCompact ? 6 : density.metricLabelSpacing)
                    {
                        sectionHeader("Generated", color: throughputColor)
                        throughputValue(size: isCompact ? 32 : density.value(40, 28))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: isCompact ? 6 : density.metricLabelSpacing)
                    {
                        sectionHeader("System GPU", color: gpuColor)
                        gpuValue(
                            size: isCompact ? 30 : density.value(38, 28),
                            height: isCompact ? 40 : density.metricValueHeight)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(gpuHelp)
                }
                .frame(
                    height: narrow ? nil : (isCompact ? 60 : density.metricRowHeight),
                    alignment: .top)
            }
            LuminousActivityChart(
                throughput: prepared.throughput, gpu: prepared.gpu,
                tools: prepared.toolActivity, now: chartInterval.end,
                duration: chartDuration, compact: isCompact,
                lanes: prepared.lanes, laneColorIndex: prepared.laneColorIndex,
                requestTools: prepared.requestTools, requestRails: prepared.requestRails,
                heightCompression: density.compression,
                isLive: isCompact || currentNavigation.isLive,
                observationTime: store.chartPresentation.timestamp,
                onSelectInterval: isCompact
                    ? nil
                    : { interval in
                        var updated = currentNavigation
                        updated.select(interval, now: store.chartPresentation.timestamp)
                        navigationBinding.wrappedValue = updated
                    },
                onFitRequest: isCompact
                    ? nil
                    : { lane in
                        var updated = currentNavigation
                        updated.fit(lane, now: store.chartPresentation.timestamp)
                        navigationBinding.wrappedValue = updated
                    },
                publicationID: prepared.publicationID
            )
            .accessibilityIdentifier("activity-chart")
            .transformAnchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
                $0["activity-chart"] = $1
            }
            .zIndex(1)
            DashboardScalarContent {
                HStack(spacing: 8) {
                    Text(
                        prepared.omittedRequestCount > 0
                            ? "\(observationScope) · \(prepared.omittedRequestCount) older rails omitted"
                            : observationScope
                    )
                    .help(throughputHelp)
                    Spacer(minLength: 0)
                    Text("GPU · This Mac").help(gpuHelp)
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 12)
            }
        }
        .padding(.horizontal, isCompact ? 12 : 18)
        .padding(.vertical, isCompact ? 12 : density.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: isCompact ? nil : .infinity, alignment: .topLeading)
        .background { FlowMetricSurface(compact: isCompact) }
        .overlay { FlowMetricRim(compact: isCompact) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity-card")
        .zIndex(1)
        .transformAnchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
            frames, bounds in
            frames["activity-card"] = bounds
            if isCompact { frames["compact-activity"] = bounds }
        }
    }

    private func gpuValue(size: CGFloat, height: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(GPUActivityPresentation.valueLabel(store.systemGPUUtilizationPercent))
                .font(.system(size: size, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text("%").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(height: height)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("system-gpu-value")
        .anchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
            ["gpu-value": $0]
        }
    }

    private var compactDetails: some View {
        Group {
            if store.backendKind == .ollama {
                detailRow("Latest response tokens", responseTokensLabel)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("total-response-tokens")
                    .anchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
                        ["total-response-tokens": $0]
                    }
            } else {
                detailRow("Requests", requestCountLabel)
            }
        }
        .frame(height: 14)
        .transformAnchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
            frames, bounds in
            frames["statistics-row"] = bounds
        }
    }

    private func dashboardDetails(narrow: Bool, density: DashboardHeightPolicy) -> some View {
        VStack(alignment: .leading, spacing: density.value(8, 5)) {
            if store.backendKind == .ollama {
                let totals = displayedUsageSummary
                HStack(spacing: 8) {
                    Text("Usage").font(.system(size: 11, weight: .semibold))
                    Picker("Usage scope", selection: usageScope) {
                        ForEach(UsageScope.allCases) { scope in Text(scope.title).tag(scope) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
                    .help(usageScopeHelp)
                    Spacer(minLength: 0)
                    if totals.isPartial {
                        Text("Partial history").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if totals.activeRequests > 0 {
                        Text("\(totals.activeRequests) active")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), alignment: .leading), count: narrow ? 2 : 4
                    ),
                    alignment: .leading, spacing: 8
                ) {
                    summaryValue("Input tokens", inputUsageLabel(totals), density: density)
                        .help(
                            totals.unknownInputRequests > 0
                                ? "Input usage is unavailable for \(totals.unknownInputRequests) requests. A + marks the known subtotal."
                                : "Input tokens reported by the backend.")
                    summaryValue(
                        "Output tokens",
                        (totals.outputIsEstimated ? "~" : "") + totals.outputTokens.formatted(),
                        density: density)
                    summaryValue("Tool calls", totals.toolCalls.formatted(), density: density)
                        .help(
                            "Observed calls, excluding submitted results; this does not measure execution success."
                        )
                    summaryValue("Requests", totals.requests.formatted(), density: density)
                }
                .help(usageScopeHelp)
            } else {
                let layout =
                    narrow
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: density.value(12, 8)))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                layout {
                    summaryValue(
                        "Server output total", store.backendOutputTokens?.formatted() ?? "—",
                        density: density)
                    summaryValue(
                        "Server prompt total", store.backendPromptTokens?.formatted() ?? "—",
                        density: density)
                    summaryValue("Requests", requestCountLabel, density: density)
                }
            }
            if let error = displayedHistoryPersistenceError {
                Label("History storage unavailable", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.secondary).help(error)
            }
        }
        .anchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
            ["statistics-row": $0]
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value).fontWeight(.medium).monospacedDigit()
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .font(.system(size: 11))
    }

    private func summaryValue(_ label: String, _ value: String, density: DashboardHeightPolicy)
        -> some View
    {
        VStack(alignment: .leading, spacing: density.value(5, 2)) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(height: 14)
            Text(value).font(
                .system(size: density.value(16, 14), weight: .medium, design: .rounded)
            )
            .monospacedDigit().textSelection(.enabled)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(height: density.value(21, 18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(height: 14)
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text(BackendPresentation.statusTitle(store: store))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1).fixedSize()
            if BackendPresentation.configurationPrompt(store: store) != nil {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(statusColor.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
        .help(
            BackendPresentation.configurationPrompt(store: store)
                ?? (store.backendKind == .ollama
                    ? "Observed generation activity for requests sent through FluxLLM."
                    : "Observed generation activity reported by the selected backend."))
    }

    private var statusColor: Color {
        if store.isBackendActive { return throughputColor }
        return switch store.connectionState {
        case .ready: store.isBackendActive ? throughputColor : .secondary
        case .connecting, .detecting: .blue
        case .needsConfiguration, .unavailable: .orange
        }
    }

    private var currentNavigation: HistoryNavigation {
        var value = presentation.navigation
        if value.preset != store.historyRange {
            value.selectPreset(
                store.historyRange, now: store.chartPresentation.timestamp,
                historyAge: store.chartHistoryAge)
        }
        return value
    }
    private var navigationBinding: Binding<HistoryNavigation> {
        Binding(
            get: { currentNavigation },
            set: {
                presentation.navigation = $0
                // Moving presets use the shared range. Custom/frozen views own
                // their interval, so install that before changing the preset.
                if $0.isLive && $0.preset != .custom {
                    store.historyRange = $0.preset
                    updateChartViewport(for: $0)
                } else {
                    updateChartViewport(for: $0)
                    store.historyRange = $0.preset
                }
            })
    }
    private func updateChartViewport(for navigation: HistoryNavigation) {
        let viewport: ChartPresentationViewport =
            isCompact
            ? .live(duration: 60) : navigation.presentationViewport
        store.setChartPresentationViewport(viewport, consumer: isCompact ? .popover : .dashboard)
    }

    private var usageScope: Binding<UsageScope> {
        Binding(get: { store.usageScope }, set: { store.usageScope = $0 })
    }
    private var usageScopeHelp: String {
        switch store.usageScope {
        case .sinceLaunch:
            "All requests observed for this endpoint since FluxLLM launched, including active estimates."
        case .selectedPeriod:
            "Full usage of requests completed in the selected chart interval. Tool calls are counted by their event time."
        case .today:
            "Requests completed today and active requests started today, including saved history for this endpoint."
        }
    }
    private func inputUsageLabel(_ summary: UsageSummary) -> String {
        guard let input = summary.inputTokens else { return "—" }
        return input.formatted() + (summary.unknownInputRequests > 0 ? "+" : "")
    }
    private var chartInterval: DateInterval {
        let now = store.chartPresentation.timestamp
        return isCompact
            ? DateInterval(start: now.addingTimeInterval(-60), end: now)
            : currentNavigation.interval(now: now, historyAge: store.chartHistoryAge)
    }
    private var chartDuration: TimeInterval { chartInterval.duration }
    private var observationScope: String {
        switch store.backendKind {
        case .ollama: "Via FluxLLM"
        case .none: "Waiting for backend"
        default: "Server metrics"
        }
    }
    private var throughputColor: Color { TelemetryPalette.throughput(colorScheme) }
    private var gpuColor: Color { TelemetryPalette.gpu(colorScheme) }
    private var preparedCharts: PreparedDashboardCharts {
        presentation.chartPreparation.histories(
            snapshot: store.chartPresentation, duration: chartDuration,
            epoch: store.monitoringEpoch,
            windowEnd: chartInterval.end, isLive: isCompact || currentNavigation.isLive,
            optimized: PerformanceGraphicsDiagnostics.shared.mode.usesOptimizedChartPreparation,
            sharedNormalization: PerformanceGraphicsDiagnostics.shared.mode
                .usesSharedChartPreparation
        )
    }
    private var gpuIsAvailable: Bool {
        store.systemGPUUtilizationPercent != nil
    }
    private var gpuHelp: String {
        gpuIsAvailable ? GPUActivityPresentation.explanation : store.gpuAvailabilityMessage
    }
    private var throughputHelp: String {
        switch store.throughputBasis {
        case .estimated:
            if store.backendKind == .ollama {
                "Generated and tool-call rates follow the latest request via FluxLLM. Active includes all open monitored requests. Live token rate is approximate until the backend reports final token counts."
            } else {
                "Live token rate is approximate until the backend reports final token counts."
            }
        case .serverAggregate:
            "Total token throughput across requests reported by this backend."
        case .serverReportedAverage:
            "Average token rate reported by this backend."
        }
    }
    private var modelLabel: String {
        guard let model = store.currentModel, !model.isEmpty else { return "—" }
        return model
    }
    private var responseTokensLabel: String {
        if PerformanceGraphicsDiagnostics.shared.mode.usesCoalescedScalarPresentation {
            guard let response = store.dashboardScalarPresentation.latestResponse else {
                return "—"
            }
            return (response.outputIsEstimated ? "~" : "") + response.outputTokens.formatted()
        }
        return store.activeGeneration == nil
            ? "—" : (store.outputIsEstimated ? "~" : "") + store.outputTokens.formatted()
    }
    private var displayedUsageSummary: UsageSummary {
        if PerformanceGraphicsDiagnostics.shared.mode.usesCoalescedScalarPresentation {
            return store.dashboardScalarPresentation.usage
        }
        return store.usageSummary(in: chartInterval)
    }
    private var displayedHistoryPersistenceError: String? {
        if PerformanceGraphicsDiagnostics.shared.mode.usesCoalescedScalarPresentation {
            return store.dashboardScalarPresentation.historyPersistenceError
        }
        return store.historyPersistenceError
    }
    private var requestCountLabel: String {
        guard let running = store.runningRequests else { return "—" }
        let queued = store.queuedRequests ?? 0
        return queued > 0 ? "\(running) active · \(queued) queued" : running.formatted()
    }
}

/// Observation reads in this closure belong to the child body. High-rate token,
/// activity and GPU scalar changes therefore leave the chart parent untouched.
private struct DashboardScalarContent<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    var body: some View { content() }
}
