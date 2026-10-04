import SwiftUI

/// A scalar leaf observes only the displayed fields it renders. Its immutable
/// layout inputs remain equal when the parent publishes another chart frame.
struct DashboardScalarView: View, Equatable {
    @Environment(MetricsStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let actions: MenuActions
    let presentation: DashboardPresentationState
    let leaf: PerformanceGraphicsDiagnostics.ScalarLeaf
    let isCompact: Bool
    let narrow: Bool
    let density: DashboardHeightPolicy
    let omittedRequestCount: Int
    let scalarMode: PerformanceGraphicsDiagnostics.Mode
    let legacyUsageInterval: DateInterval?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.actions === rhs.actions && lhs.presentation === rhs.presentation
            && lhs.leaf == rhs.leaf && lhs.isCompact == rhs.isCompact
            && lhs.narrow == rhs.narrow && lhs.density == rhs.density
            && lhs.omittedRequestCount == rhs.omittedRequestCount
            && lhs.scalarMode == rhs.scalarMode
            && lhs.legacyUsageInterval == rhs.legacyUsageInterval
    }

    var body: some View {
        if PerformanceGraphicsDiagnostics.shared.isEnabled, presentation.isActive {
            PerformanceGraphicsDiagnostics.shared.recordScalarLeafBody(
                leaf, owner: presentation.scalarPerformanceOwnerID)
            recordPresentedValues()
        }
        return Group {
            switch leaf {
            case .header: header(narrow: narrow, density: density)
            case .metrics: metrics
            case .details:
                if isCompact {
                    compactDetails
                } else {
                    dashboardDetails(narrow: narrow, density: density)
                }
            case .cardFooter: cardFooter
            case .appFooter: appFooter
            }
        }
    }

    private var metrics: some View {
        let metricLayout =
            narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: density.value(12, 8)))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return metricLayout {
            VStack(alignment: .leading, spacing: isCompact ? 6 : density.metricLabelSpacing) {
                sectionHeader("Generated", color: throughputColor)
                throughputValue(size: isCompact ? 32 : density.value(40, 28))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: isCompact ? 6 : density.metricLabelSpacing) {
                sectionHeader("System GPU", color: gpuColor)
                gpuValue(
                    size: isCompact ? 30 : density.value(38, 28),
                    height: isCompact ? 40 : density.metricValueHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(gpuHelp)
        }
        .frame(height: narrow ? nil : (isCompact ? 60 : density.metricRowHeight), alignment: .top)
    }

    private var cardFooter: some View {
        HStack(spacing: 8) {
            Text(cardFooterLabel(omittedRequestCount: omittedRequestCount)).help(throughputHelp)
            Spacer(minLength: 0)
            Text("GPU · This Mac").help(gpuHelp)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .lineLimit(1).frame(height: 12)
    }

    private var appFooter: some View {
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
                Text(providerTitle).fixedSize()
                Text("·")
                Text(modelLabel).lineLimit(1).truncationMode(.middle)
                    .help(modelLabel)
            }
            .frame(height: 14)
            if !narrow { Spacer(minLength: 6) }
            // Reserve the activity line even while idle so incoming requests
            // do not push the chart down in the stacked header.
            Text(activityDetail ?? "")
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
        if let prompt = configurationPrompt {
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
            Text(rateLabel)
                .font(.system(size: size, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("tokens/s").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .frame(height: ceil(size * 1.25))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Generated")
        .accessibilityValue("\(rateLabel) tokens per second")
        .accessibilityIdentifier("throughput-value")
        .anchorPreference(key: DashboardFrameAnchors.self, value: .bounds) {
            ["throughput-value": $0]
        }
        .accessibilityHint(throughputHelp)
        .help(throughputHelp)
    }

    private func gpuValue(size: CGFloat, height: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(gpuLabel)
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
            if scalarBackendKind == .ollama {
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
            if scalarBackendKind == .ollama {
                if scalarMode.usesRetainedUsageFields {
                    retainedUsageDetails(narrow: narrow, density: density)
                } else {
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
                            Text("Partial history").font(.system(size: 10)).foregroundStyle(
                                .secondary)
                        } else if totals.activeRequests > 0 {
                            Text("\(totals.activeRequests) active")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), alignment: .leading),
                            count: narrow ? 2 : 4
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
                }
            } else {
                let layout =
                    narrow
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: density.value(12, 8)))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                layout {
                    summaryValue(
                        "Server output total", backendOutputTokensLabel,
                        density: density)
                    summaryValue(
                        "Server prompt total", backendPromptTokensLabel,
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

    private func retainedUsageDetails(narrow: Bool, density: DashboardHeightPolicy) -> some View {
        let coordinator = presentation.retainedUsageCoordinator(store: store)
        return VStack(alignment: .leading, spacing: density.value(8, 5)) {
            HStack(spacing: 8) {
                Text("Usage").font(.system(size: 11, weight: .semibold))
                Picker("Usage scope", selection: usageScope) {
                    ForEach(UsageScope.allCases) { scope in Text(scope.title).tag(scope) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
                .help(usageScopeHelp)
                Spacer(minLength: 0)
                DashboardRetainedUsageField(
                    coordinator: coordinator, field: .badge,
                    density: density, colorScheme: colorScheme)
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), alignment: .leading), count: narrow ? 2 : 4),
                alignment: .leading, spacing: 8
            ) {
                ForEach(
                    [DashboardRetainedUsageCoordinator.Field.input, .output, .tools, .requests],
                    id: \.self
                ) {
                    retainedUsageCell($0, coordinator: coordinator, density: density)
                }
            }
            .help(usageScopeHelp)
        }
    }

    @ViewBuilder private func retainedUsageCell(
        _ field: DashboardRetainedUsageCoordinator.Field,
        coordinator: DashboardRetainedUsageCoordinator, density: DashboardHeightPolicy
    ) -> some View {
        let content = VStack(alignment: .leading, spacing: density.value(5, 2)) {
            Text(retainedUsageLabel(field)).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8).frame(height: 14)
            GeometryReader { geometry in
                DashboardRetainedUsageField(
                    coordinator: coordinator, field: field,
                    density: density, colorScheme: colorScheme,
                    logicalFrame: geometry.frame(in: .global))
            }
            .frame(height: density.value(21, 18))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        switch field {
        case .input: content.help(coordinator.inputHelp.text)
        case .tools:
            content.help(
                "Observed calls, excluding submitted results; this does not measure execution success."
            )
        default: content
        }
    }

    private func retainedUsageLabel(_ field: DashboardRetainedUsageCoordinator.Field) -> String {
        switch field {
        case .input: "Input tokens"
        case .output: "Output tokens"
        case .tools: "Tool calls"
        case .requests: "Requests"
        case .badge: ""
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
            Text(statusTitle)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1).fixedSize()
            if configurationPrompt != nil {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(statusColor.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .combine)
        .help(
            configurationPrompt
                ?? (scalarBackendKind == .ollama
                    ? "Observed generation activity for requests sent through FluxLLM."
                    : "Observed generation activity reported by the selected backend."))
    }

    private var statusColor: Color {
        if let frozen = frozenScalars {
            return switch frozen.statusTone {
            case .throughput: throughputColor
            case .secondary: .secondary
            case .blue: .blue
            case .orange: .orange
            }
        }
        if let live = liveScalars {
            return switch live.statusTone {
            case .throughput: throughputColor
            case .secondary: .secondary
            case .blue: .blue
            case .orange: .orange
            }
        }
        if store.isBackendActive { return throughputColor }
        return switch store.connectionState {
        case .ready: store.isBackendActive ? throughputColor : .secondary
        case .connecting, .detecting: .blue
        case .needsConfiguration, .unavailable: .orange
        }
    }

    private var usageScope: Binding<UsageScope> {
        Binding(
            get: { frozenScalars?.usageScope ?? store.usageScope }, set: { store.usageScope = $0 })
    }

    private var usageScopeHelp: String {
        if let frozen = frozenScalars { return frozen.usageScopeHelp }
        if let live = liveScalars { return live.usageScopeHelp }
        return switch store.usageScope {
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

    private var observationScope: String {
        if let frozen = frozenScalars { return frozen.observationScope }
        if let live = liveScalars { return live.observationScope }
        return switch store.backendKind {
        case .ollama: "Via FluxLLM"
        case .none: "Waiting for backend"
        default: "Server metrics"
        }
    }

    private var gpuIsAvailable: Bool {
        store.systemGPUUtilizationPercent != nil
    }

    private var gpuHelp: String {
        if let frozen = frozenScalars { return frozen.gpuHelp }
        if let live = liveScalars { return live.gpuHelp }
        return gpuIsAvailable ? GPUActivityPresentation.explanation : store.gpuAvailabilityMessage
    }

    private var throughputHelp: String {
        if let frozen = frozenScalars { return frozen.throughputHelp }
        if let live = liveScalars { return live.throughputHelp }
        return switch store.throughputBasis {
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
        if let frozen = frozenScalars { return frozen.modelLabel }
        if let live = liveScalars { return live.modelLabel }
        guard let model = store.currentModel, !model.isEmpty else { return "—" }
        return model
    }

    private var responseTokensLabel: String {
        if let frozen = frozenScalars { return frozen.responseTokensLabel }
        if let live = liveScalars { return live.responseTokensLabel }
        return store.activeGeneration == nil
            ? "—" : (store.outputIsEstimated ? "~" : "") + store.outputTokens.formatted()
    }

    private var displayedUsageSummary: UsageSummary {
        if let frozen = frozenScalars { return frozen.usage }
        if scalarMode.usesHeldUsagePresentation, !isCompact, let held = presentation.heldUsage,
            held.epoch == store.monitoringEpoch
        {
            return held.usage
        }
        if let live = liveScalars { return live.usage }
        return store.usageSummary(
            in: legacyUsageInterval
                ?? DateInterval(
                    start: store.chartPresentation.timestamp.addingTimeInterval(-60),
                    end: store.chartPresentation.timestamp))
    }

    /// These bounded receipts are the actual labels read by the native leaf,
    /// not sampled raw counters. They do not run in ordinary app sessions.
    private func recordPresentedValues() {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        guard
            diagnostics.mode == .normal || diagnostics.mode.usesHeldUsagePresentation
                || diagnostics.mode.usesRetainedUsageFields
        else { return }
        let values: [String: Any]
        switch leaf {
        case .header:
            values = [
                "status": statusTitle, "model": modelLabel,
                "activity": activityDetail as Any? ?? NSNull(),
            ]
        case .metrics:
            values = ["rate": rateLabel, "gpu": gpuLabel]
        case .details where isCompact && scalarBackendKind == .ollama:
            values = ["response": responseTokensLabel]
        case .details where !isCompact && scalarBackendKind == .ollama:
            // Native host apply callbacks supply this witness after applying
            // the actual retained fields. Reading usage here would enroll the
            // parent details body and report values it did not render.
            if scalarMode.usesRetainedUsageFields { return }
            let scope: UsageScope
            if scalarMode.usesHeldUsagePresentation, let held = presentation.heldUsage,
                held.epoch == store.monitoringEpoch
            {
                scope = held.scope
            } else {
                scope = store.usageScope
            }
            values = [
                "scope": scope.rawValue,
                "values": DashboardHeldUsage.values(for: displayedUsageSummary),
            ]
        default: return
        }
        diagnostics.recordScalarPresentedValues(
            leaf, owner: presentation.scalarPerformanceOwnerID,
            compact: isCompact, values: values)
    }

    private var displayedHistoryPersistenceError: String? {
        if let frozen = frozenScalars { return frozen.historyPersistenceError }
        if let live = liveScalars { return live.historyPersistenceError }
        return store.historyPersistenceError
    }

    private var requestCountLabel: String {
        if let frozen = frozenScalars { return frozen.requestCountLabel }
        if let live = liveScalars { return live.requestCountLabel }
        guard let running = store.runningRequests else { return "—" }
        let queued = store.queuedRequests ?? 0
        return queued > 0 ? "\(running) active · \(queued) queued" : running.formatted()
    }

    private var providerTitle: String {
        if let frozen = frozenScalars { return frozen.providerTitle }
        if let live = liveScalars { return live.providerTitle }
        return store.backendKind?.title ?? "LLM monitor"
    }

    private var activityDetail: String? {
        if let frozen = frozenScalars { return frozen.activityDetail }
        if let live = liveScalars { return live.activityDetail }
        return BackendPresentation.activityDetail(store: store)
    }

    private var configurationPrompt: String? {
        if let frozen = frozenScalars { return frozen.configurationPrompt }
        if let live = liveScalars { return live.configurationPrompt }
        return BackendPresentation.configurationPrompt(store: store)
    }

    private var statusTitle: String {
        if let frozen = frozenScalars { return frozen.statusTitle }
        if let live = liveScalars { return live.statusTitle }
        return BackendPresentation.statusTitle(store: store)
    }

    private var rateLabel: String {
        if let frozen = frozenScalars { return frozen.rateLabel }
        if let live = liveScalars { return live.rateLabel }
        return BackendPresentation.rateLabel(store: store)
    }

    private var gpuLabel: String {
        if let frozen = frozenScalars { return frozen.gpuLabel }
        if let live = liveScalars { return live.gpuLabel }
        return GPUActivityPresentation.valueLabel(store.systemGPUUtilizationPercent)
    }

    private var backendOutputTokensLabel: String {
        if let frozen = frozenScalars { return frozen.backendOutputTokensLabel }
        if let live = liveScalars { return live.backendOutputTokensLabel }
        return store.backendOutputTokens?.formatted() ?? "—"
    }

    private var backendPromptTokensLabel: String {
        if let frozen = frozenScalars { return frozen.backendPromptTokensLabel }
        if let live = liveScalars { return live.backendPromptTokensLabel }
        return store.backendPromptTokens?.formatted() ?? "—"
    }

    private func cardFooterLabel(omittedRequestCount: Int) -> String {
        if let frozen = frozenScalars { return frozen.cardFooterLabel }
        return omittedRequestCount > 0
            ? "\(observationScope) · \(omittedRequestCount) older rails omitted" : observationScope
    }

    private var frozenScalars: DashboardFrozenScalars? {
        scalarMode.usesFrozenScalarPresentation ? presentation.frozenScalars : nil
    }
    private var liveScalars: DashboardLiveScalars? {
        scalarMode.usesCoalescedScalarPresentation ? store.liveScalars : nil
    }
    private var scalarBackendKind: BackendKind? {
        if let frozen = frozenScalars { return frozen.backendKind }
        if let live = liveScalars { return live.backendKind }
        return store.backendKind
    }
    private var throughputColor: Color { TelemetryPalette.throughput(colorScheme) }
    private var gpuColor: Color { TelemetryPalette.gpu(colorScheme) }
}
