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
    @ObservationIgnored private(set) var scalarPerformanceFrames: [String: CGRect] = [:]
    private(set) var scalarFrameGeneration: UInt64 = 0
    @ObservationIgnored private weak var scalarNativeWindow: NSWindow?
    @ObservationIgnored private var scalarRole: String?

    func synchronize(with store: MetricsStore) {
        guard monitoringEpoch != store.monitoringEpoch else { return }
        releaseScalarPerformancePresentation()
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
            releaseScalarPerformancePresentation()
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

    private func releaseScalarPerformancePresentation() {
        if PerformanceGraphicsDiagnostics.shared.isEnabled {
            PerformanceGraphicsDiagnostics.shared.performanceScalarPresentationReleased(
                owner: scalarPerformanceOwnerID)
        }
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
