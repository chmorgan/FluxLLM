import SwiftUI

/// Native layout landmarks used by geometry and scalar rendering checks.
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
        .modifier(
            DashboardScalarFrameProbe(
                presentation: presentation, epoch: store.monitoringEpoch)
        )
        .onAppear { updateChartViewport(for: currentNavigation) }
        .onChange(of: store.monitoringEpoch) { _, _ in
            presentation.synchronize(with: store)
            updateChartViewport(for: currentNavigation)
        }
        .onChange(of: currentNavigation) { _, navigation in
            updateChartViewport(for: navigation)
        }
    }

    private func scalarView(
        _ leaf: PerformanceGraphicsDiagnostics.ScalarLeaf, narrow: Bool = false,
        density: DashboardHeightPolicy = .roomy, omittedRequestCount: Int = 0
    ) -> some View {
        return DashboardScalarView(
            actions: actions, presentation: presentation, leaf: leaf, isCompact: isCompact,
            narrow: narrow, density: density, omittedRequestCount: omittedRequestCount
        )
        .equatable()
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            scalarView(.header)
            activityCard()
            if scalarBackendKind != nil {
                scalarView(.details)
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
        DashboardStackLayout(
            spacing: density.rowSpacing,
            layoutCounters: PerformanceGraphicsDiagnostics.shared.layoutCountersForPresentation
        ) {
            scalarView(.header, narrow: narrow, density: density)
            historyControls(narrow: narrow)
            activityCard(narrow: narrow, density: density)
                .layoutValue(key: DashboardFlexibleRow.self, value: true)
            if scalarBackendKind != nil {
                VStack(alignment: .leading, spacing: density.value(8, 4)) {
                    Divider()
                    scalarView(.details, narrow: narrow, density: density)
                }
            }
            scalarView(.appFooter, narrow: narrow, density: density)
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

    private func activityCard(
        narrow: Bool = false, density: DashboardHeightPolicy = .roomy
    ) -> some View {
        let prepared = preparedCharts
        return VStack(alignment: .leading, spacing: isCompact ? 10 : density.cardSpacing) {
            scalarView(.metrics, narrow: narrow, density: density)
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
            scalarView(
                .cardFooter, narrow: narrow, density: density,
                omittedRequestCount: prepared.omittedRequestCount)
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

    private var chartInterval: DateInterval {
        let now = store.chartPresentation.timestamp
        return isCompact
            ? DateInterval(start: now.addingTimeInterval(-60), end: now)
            : currentNavigation.interval(now: now, historyAge: store.chartHistoryAge)
    }
    private var chartDuration: TimeInterval { chartInterval.duration }

    private var throughputColor: Color { TelemetryPalette.throughput(colorScheme) }
    private var preparedCharts: PreparedDashboardCharts {
        presentation.chartPreparation.histories(
            snapshot: store.chartPresentation, duration: chartDuration,
            epoch: store.monitoringEpoch,
            windowEnd: chartInterval.end, isLive: isCompact || currentNavigation.isLive
        )
    }

    private var scalarBackendKind: BackendKind? { store.liveScalars.backendKind }
}

/// Resolve existing native layout landmarks only in authenticated captures.
/// The receipt is nonobservable and creates no polling or animation work.
struct DashboardScalarFrameProbe: ViewModifier {
    let presentation: DashboardPresentationState
    let epoch: UUID

    private struct Receipt: Equatable {
        let frames: [String: CGRect]
        let generation: UInt64
        let epoch: UUID
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        if diagnostics.isEnabled {
            let generation = presentation.scalarFrameGeneration
            content.overlayPreferenceValue(DashboardFrameAnchors.self) { anchors in
                GeometryReader { geometry in
                    let frames = anchors.mapValues { geometry[$0] }
                    let receipt = Receipt(frames: frames, generation: generation, epoch: epoch)
                    Color.clear
                        .onChange(of: receipt, initial: true) { _, current in
                            presentation.recordScalarPerformanceFrames(
                                current.frames, generation: current.generation, epoch: current.epoch
                            )
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}
