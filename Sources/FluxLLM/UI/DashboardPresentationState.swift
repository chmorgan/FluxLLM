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

    func synchronize(with store: MetricsStore) {
        guard monitoringEpoch != store.monitoringEpoch else { return }
        monitoringEpoch = store.monitoringEpoch
        navigation = HistoryNavigation(preset: store.historyRange)
    }

    func setActive(_ active: Bool, store: MetricsStore) {
        if active { synchronize(with: store) }
        isActive = active
        if !active { chartPreparation.releasePreparedCharts() }
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
