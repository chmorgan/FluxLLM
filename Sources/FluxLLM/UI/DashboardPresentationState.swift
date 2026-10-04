import AppKit
import Observation
import SwiftUI

/// Keep user choices and request identities between presentations, not prepared
/// histories or a SwiftUI render tree that continues observing telemetry.
@Observable
@MainActor
final class DashboardPresentationState {
    var navigation = HistoryNavigation()
    private(set) var isActive = false
    var placeholderSize = NSSize(width: DashboardView.compactWidth, height: 1)
    @ObservationIgnored let chartPreparation = DashboardChartPreparation()
    @ObservationIgnored private var monitoringEpoch: UUID?
    @ObservationIgnored let scalarPerformanceOwnerID = UUID()
    private(set) var frozenScalars: DashboardFrozenScalars?
    private(set) var heldUsage: DashboardHeldUsage?
    @ObservationIgnored private(set) var scalarPerformanceFrames: [String: CGRect] = [:]
    @ObservationIgnored private(set) var scalarFrameGeneration: UInt64 = 0
    @ObservationIgnored private weak var scalarNativeWindow: NSWindow?
    @ObservationIgnored private var scalarRole: String?

    func synchronize(with store: MetricsStore) {
        guard monitoringEpoch != store.monitoringEpoch else { return }
        releaseFrozenScalars()
        scalarPerformanceFrames.removeAll(keepingCapacity: false)
        scalarFrameGeneration &+= 1
        monitoringEpoch = store.monitoringEpoch
        navigation = HistoryNavigation(preset: store.historyRange)
    }

    func setActive(_ active: Bool, store: MetricsStore) {
        if active { synchronize(with: store) }
        if active != isActive { scalarFrameGeneration &+= 1 }
        isActive = active
        if !active {
            chartPreparation.releasePreparedCharts()
            releaseFrozenScalars()
            scalarPerformanceFrames.removeAll(keepingCapacity: false)
        }
    }

    func bindScalarPerformanceWindow(_ window: NSWindow, role: String) {
        guard PerformanceGraphicsDiagnostics.shared.isEnabled else { return }
        scalarNativeWindow = window
        scalarRole = role
    }

    /// Anchor callbacks carry the view lifetime, so a late preference update
    /// cannot recreate a closed or subsequently reopened presentation owner.
    func recordScalarPerformanceFrames(_ frames: [String: CGRect], generation: UInt64, epoch: UUID)
    {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        guard diagnostics.isEnabled, isActive, generation == scalarFrameGeneration,
            epoch == monitoringEpoch, let role = scalarRole
        else { return }
        var complete = frames
        if let window = scalarNativeWindow { complete["native-window"] = window.frame }
        let required: Set<String> =
            role == "dashboard"
            ? ["activity-chart", "main-activity-plot", "request-rail-band", "native-window"]
            : ["activity-chart", "main-activity-plot", "native-window"]
        guard complete.count <= 16, !complete.isEmpty,
            required.isSubset(of: Set(complete.keys)), complete.values.allSatisfy(Self.validFrame)
        else {
            // Initial layout may be incomplete. After a valid receipt, a
            // malformed same-lifetime update must fail the capture rather than
            // silently preserving old positive plot geometry.
            if !scalarPerformanceFrames.isEmpty {
                scalarPerformanceFrames.removeAll(keepingCapacity: false)
                complete["invalid-chart-geometry"] = .zero
                diagnostics.performanceScalarFramesUpdated(
                    owner: scalarPerformanceOwnerID, role: role, frames: complete)
            }
            return
        }
        scalarPerformanceFrames = complete
        diagnostics.performanceScalarFramesUpdated(
            owner: scalarPerformanceOwnerID, role: role, frames: complete)
    }

    func refreshScalarPerformanceNativeFrame() {
        guard PerformanceGraphicsDiagnostics.shared.isEnabled,
            !scalarPerformanceFrames.isEmpty, let epoch = monitoringEpoch
        else { return }
        recordScalarPerformanceFrames(
            scalarPerformanceFrames, generation: scalarFrameGeneration, epoch: epoch)
    }

    func prepareFrozenScalars(store: MetricsStore, compact: Bool) throws -> DashboardFrozenScalars {
        guard PerformanceGraphicsDiagnostics.shared.isEnabled,
            PerformanceGraphicsDiagnostics.shared.mode.usesFrozenScalarPresentation,
            isActive, frozenScalars == nil, monitoringEpoch == store.monitoringEpoch
        else {
            throw DashboardScalarFreezeError.invalid(
                "Scalar freezing requires an active, unfrozen diagnostic presentation")
        }
        let required: Set<String> =
            compact
            ? ["activity-chart", "main-activity-plot", "native-window"]
            : ["activity-chart", "main-activity-plot", "request-rail-band", "native-window"]
        guard required.isSubset(of: Set(scalarPerformanceFrames.keys)),
            scalarPerformanceFrames.values.allSatisfy(Self.validFrame)
        else {
            throw DashboardScalarFreezeError.invalid(
                "Scalar capture requires complete native chart geometry")
        }
        var selection = navigation
        if selection.preset != store.historyRange {
            selection.selectPreset(
                store.historyRange, now: store.chartPresentation.timestamp,
                historyAge: store.chartHistoryAge)
        }
        let now = store.chartPresentation.timestamp
        let interval =
            compact
            ? DateInterval(start: now.addingTimeInterval(-60), end: now)
            : selection.interval(now: now, historyAge: store.chartHistoryAge)
        let mode = PerformanceGraphicsDiagnostics.shared.mode
        let prepared = chartPreparation.histories(
            snapshot: store.chartPresentation, duration: interval.duration,
            epoch: store.monitoringEpoch,
            windowEnd: interval.end, isLive: compact || selection.isLive,
            optimized: mode.usesOptimizedChartPreparation,
            sharedNormalization: mode.usesSharedChartPreparation)
        return try DashboardFrozenScalars.capture(
            store: store, interval: interval, omittedRequestCount: prepared.omittedRequestCount)
    }

    func freezeScalars(_ snapshot: DashboardFrozenScalars) throws {
        guard isActive, frozenScalars == nil, snapshot.epoch == monitoringEpoch,
            let role = scalarRole,
            PerformanceGraphicsDiagnostics.shared.mode.usesFrozenScalarPresentation,
            PerformanceGraphicsDiagnostics.shared.frozenScalarPresentationCaptured(
                owner: scalarPerformanceOwnerID, role: role, fingerprint: snapshot.fingerprint,
                frames: scalarPerformanceFrames)
        else { throw DashboardScalarFreezeError.invalid("Scalar diagnostic receipt was rejected") }
        frozenScalars = snapshot
    }

    func releaseFrozenScalars() {
        frozenScalars = nil
        releaseHeldUsage()
        if PerformanceGraphicsDiagnostics.shared.isEnabled {
            PerformanceGraphicsDiagnostics.shared.frozenScalarPresentationReleased(
                owner: scalarPerformanceOwnerID)
        }
    }

    func prepareHeldUsage(store: MetricsStore) throws -> DashboardHeldUsage {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        guard diagnostics.isEnabled, diagnostics.mode.usesHeldUsagePresentation,
            isActive, heldUsage == nil, frozenScalars == nil,
            scalarRole == "dashboard", monitoringEpoch == store.monitoringEpoch
        else {
            throw DashboardScalarFreezeError.invalid(
                "Usage holding requires an active, unheld full diagnostic dashboard")
        }
        return try DashboardHeldUsage.capture(
            store: store, owner: scalarPerformanceOwnerID, frames: scalarPerformanceFrames,
            presentationGeneration: scalarFrameGeneration)
    }

    func holdUsage(_ snapshot: DashboardHeldUsage, store: MetricsStore) throws {
        guard isActive, heldUsage == nil, frozenScalars == nil,
            scalarRole == "dashboard", snapshot.owner == scalarPerformanceOwnerID,
            snapshot.presentationGeneration == scalarFrameGeneration,
            snapshot.frames == scalarPerformanceFrames,
            snapshot.epoch == monitoringEpoch, snapshot.epoch == store.monitoringEpoch,
            snapshot.scope == store.usageScope,
            snapshot.usage == store.dashboardScalarPresentation.usage,
            store.backendKind == .ollama, !store.backendActivity.isActive,
            store.activeGeneration?.state != .running,
            PerformanceGraphicsDiagnostics.shared.mode.usesHeldUsagePresentation,
            PerformanceGraphicsDiagnostics.shared.heldUsagePresentationCaptured(snapshot)
        else {
            throw DashboardScalarFreezeError.invalid("Held usage diagnostic receipt was rejected")
        }
        heldUsage = snapshot
    }

    func releaseHeldUsage() {
        heldUsage = nil
        PerformanceGraphicsDiagnostics.shared.heldUsagePresentationReleased(
            owner: scalarPerformanceOwnerID)
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite
            && frame.size.width > 0 && frame.size.height > 0
    }
}

/// The popover must keep its native sizing host while temporarily occluded. The
/// inactive branch reads no telemetry and owns no chart or animation subtree.
struct DashboardPopoverContent: View {
    let store: MetricsStore
    let actions: MenuActions
    let presentation: DashboardPresentationState

    var body: some View {
        if presentation.isActive {
            DashboardView(actions: actions, isCompact: true, presentation: presentation)
                .environment(store)
        } else {
            Color.clear.frame(
                width: presentation.placeholderSize.width,
                height: presentation.placeholderSize.height)
        }
    }
}

/// Popovers are native AppKit windows. Their visibility cannot be inferred from
/// SwiftUI onAppear/onDisappear or whether their window is key.
@MainActor
final class DashboardWindowVisibilityObserver: NSObject {
    private weak var window: NSWindow?
    private var onChange: ((Bool) -> Void)?
    private var generation = 0
    private var lastValue: Bool?
    private var closing = false

    init(window: NSWindow, onChange: @escaping (Bool) -> Void) {
        self.window = window
        self.onChange = onChange
        super.init()
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didExposeNotification,
            NSWindow.willCloseNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowChanged(_:)), name: name, object: window)
        }
        scheduleUpdate()
    }

    @objc private func windowChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification {
            closing = true
        } else if let window, window.isVisible, window.occlusionState.contains(.visible) {
            closing = false
        }
        scheduleUpdate()
    }

    private func scheduleUpdate() {
        generation &+= 1
        let expected = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected, let onChange = self.onChange else {
                return
            }
            let visible =
                self.window.map {
                    !self.closing && $0.isVisible && !$0.isMiniaturized
                        && $0.occlusionState.contains(.visible)
                } ?? false
            guard visible != self.lastValue else { return }
            self.lastValue = visible
            onChange(visible)
        }
    }

    func stop() {
        generation &+= 1
        NotificationCenter.default.removeObserver(self)
        onChange = nil
        window = nil
    }
}
