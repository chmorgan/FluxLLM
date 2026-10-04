import AppKit
import SwiftUI

/// Owns one native status item, a transient dashboard, and reusable windows.
@MainActor
public final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let metricsStore: MetricsStore
    private let coordinator: MonitoringCoordinator
    private let settings: AppSettings
    private let launchAtLogin: LaunchAtLoginController
    private let menuActions = MenuActions()
    private let popover = MenuBarController.makePopover()
    // Measurement readiness tracks the complete native close lifecycle rather
    // than inferring its completion from the window disappearing or isShown.
    private var performancePopoverClosePending = false
    private let popoverPresentation = DashboardPresentationState()
    private var popoverVisibilityObserver: DashboardWindowVisibilityObserver?
    private var isPopoverClosing = false
    private var dashboardWindow: DashboardWindow?
    private let dashboardPresentation = DashboardPresentationState()
    private var dashboardFrame: NSRect?
    private var settingsWindow: NSWindow?
    private var iconTimer: Timer?
    private var settingsActionTask: Task<Void, Error>?
    private var statusWidthBudget = StatusItemWidthBudget()
    private var statusImageCache = StatusItemImageCache()
    private var statusAccessibilitySummary: String?
    private var isStarted = false

    public static let appTitle = "FluxLLM"
    public static let performancePopoverLifecyclePolicy = "explicit-performance-commands-v2"

    /// Installed only by authenticated performance control. Nil during normal
    /// app use; records lifecycle boundaries, never drawing or timer callbacks.
    public static var performanceUICheckpoint: ((String) -> Void)?

    private static func makePopover() -> NSPopover {
        performanceUICheckpoint?("popover.native_create.begin")
        let popover = NSPopover()
        performanceUICheckpoint?("popover.native_create.end")
        return popover
    }

    /// Inspect the actual native policy without exposing or replacing its host.
    var popoverBehavior: NSPopover.Behavior { popover.behavior }
    public var performancePopoverAnimationsEnabled: Bool { popover.animates }

    public init(
        metricsStore: MetricsStore, coordinator: MonitoringCoordinator, settings: AppSettings,
        launchAtLogin: LaunchAtLoginController? = nil,
        popoverAnimationsEnabled: Bool = true
    ) {
        self.metricsStore = metricsStore
        self.coordinator = coordinator
        self.settings = settings
        self.launchAtLogin = launchAtLogin ?? LaunchAtLoginController()
        super.init()
        wireActions()

        // Give AppKit a usable first-open size without constructing charts to
        // measure them. The visible host supplies its actual preferred size,
        // which is remembered for later presentations.
        popoverPresentation.placeholderSize = NSSize(width: DashboardView.compactWidth, height: 480)

        popover.behavior = .transient
        // Performance sessions can isolate native transition allocations while
        // ordinary presentation preserves the established animation policy.
        popover.animates = popoverAnimationsEnabled
        popover.delegate = self
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        metricsStore.setChartPresentationDemand(false, consumer: .popover)
        metricsStore.setChartPresentationDemand(false, consumer: .dashboard)
        if let appIcon = BrandingAssets.appIcon {
            NSApp.applicationIconImage = appIcon
        }
        let initialLayout = StatusItemPresentation.layout(
            numberCharacters: statusWidthBudget.numberCharacters,
            availableHeight: NSStatusBar.system.thickness, visibility: statusVisibility)
        let item = NSStatusBar.system.statusItem(withLength: initialLayout.itemWidth)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(Self.appTitle)
            // Let AppKit swap to the selected artwork immediately on press,
            // while retaining its existing background highlight and tracking.
            if let cell = button.cell as? NSButtonCell {
                cell.highlightsBy.insert(.contentsCellMask)
            }
        }
        statusItem = item
        updateStatusItem()

        // Common mode keeps the meters and display preferences fresh while a
        // menu is tracking, without reconfiguring the monitoring session.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
        iconTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Called before monitoring shutdown, so no UI can reconfigure it.
    public func stop() {
        isStarted = false
        settingsActionTask?.cancel()
        iconTimer?.invalidate()
        iconTimer = nil
        closePopover()
        releasePopoverContent()
        dashboardWindow?.close()
        settingsWindow?.close()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        statusImageCache = StatusItemImageCache()
        statusAccessibilitySummary = nil
    }

    /// Drain the cancelled settings operation before final monitoring teardown.
    public func waitForPendingActions() async {
        let pending = settingsActionTask
        _ = try? await pending?.value
    }

    @objc private func handleClick() {
        guard isStarted else { return }
        let event = NSApp.currentEvent
        let isContextClick =
            event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isContextClick { showCommandMenu() } else { togglePopover() }
    }

    private func closePopover() {
        Self.performanceUICheckpoint?("popover.native_close.begin")
        if popover.isShown { performancePopoverClosePending = true }
        popover.performClose(nil)
        Self.performanceUICheckpoint?("popover.native_close.end")
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            preparePopoverContent()
            Self.performanceUICheckpoint?("popover.native_show.begin")
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            Self.performanceUICheckpoint?("popover.native_show.end")
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @discardableResult
    func preparePopoverContent() -> NSViewController {
        isPopoverClosing = false
        // A show attempt can fail or remain occluded. Only the native window
        // visibility observer may activate chart demand and the rendering tree.
        setPopoverPresentationActive(false)
        if let existing = popover.contentViewController { return existing }
        Self.performanceUICheckpoint?("popover.swiftui_create.begin")
        let hosting = NSHostingController(
            rootView: DashboardPopoverContent(
                store: metricsStore, actions: menuActions, presentation: popoverPresentation
            )
            .frame(width: DashboardView.compactWidth)
            .onExitCommand { [weak self] in self?.closePopover() })
        Self.performanceUICheckpoint?("popover.swiftui_create.end")
        Self.performanceUICheckpoint?("popover.host_attach.begin")
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        Self.performanceUICheckpoint?("popover.host_attach.end")
        return hosting
    }

    public func popoverDidShow(_ notification: Notification) {
        popoverVisibilityObserver?.stop()
        guard let window = popover.contentViewController?.view.window else { return }
        popoverPresentation.bindScalarPerformanceWindow(window, role: "popover")
        popoverVisibilityObserver = DashboardWindowVisibilityObserver(window: window) {
            [weak self] visible in
            guard let self else { return }
            self.setPopoverPresentationActive(
                visible && self.popover.isShown && !self.isPopoverClosing && self.isStarted)
        }
    }

    public func popoverWillClose(_ notification: Notification) {
        performancePopoverClosePending = true
        isPopoverClosing = true
        setPopoverPresentationActive(false)
    }

    public func popoverDidClose(_ notification: Notification) {
        performancePopoverClosePending = false
        guard !popover.isShown else { return }
        releasePopoverContent()
    }

    private func setPopoverPresentationActive(_ active: Bool) {
        if !active, let size = popover.contentViewController?.view.bounds.size,
            size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 1
        {
            popoverPresentation.placeholderSize = size
        }
        metricsStore.setChartPresentationDemand(active, consumer: .popover)
        popoverPresentation.setActive(active, store: metricsStore)
    }

    private func releasePopoverContent() {
        let hadContent = popover.contentViewController != nil
        if hadContent { Self.performanceUICheckpoint?("popover.host_release.begin") }
        popoverVisibilityObserver?.stop()
        popoverVisibilityObserver = nil
        setPopoverPresentationActive(false)
        popover.contentViewController = nil
        if hadContent { Self.performanceUICheckpoint?("popover.host_release.end") }
    }

    private func buildCommandMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, command) in MenuCommand.allCases.enumerated() {
            if command.hasSeparatorBefore { menu.addItem(.separator()) }
            let item = NSMenuItem(
                title: command.title, action: #selector(performMenuCommand(_:)),
                keyEquivalent: command.keyEquivalent)
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performMenuCommand(_ sender: NSMenuItem) {
        guard isStarted, MenuCommand.allCases.indices.contains(sender.tag) else { return }
        menuActions.perform(MenuCommand.allCases[sender.tag])
    }

    private func showCommandMenu() {
        guard let button = statusItem?.button else { return }
        closePopover()
        buildCommandMenu().popUp(
            positioning: nil, at: CGPoint(x: 0, y: button.bounds.minY), in: button)
    }

    private func wireActions() {
        menuActions.onOpenDashboardWindow = { [weak self] in self?.openDashboardWindow() }
        menuActions.onShowSettings = { [weak self] in self?.showSettings() }
        menuActions.onShowAbout = { [weak self] in self?.showAbout() }
        menuActions.onQuit = { NSApp.terminate(nil) }
    }

    private func openDashboardWindow() {
        guard isStarted else { return }
        closePopover()
        let window = prepareDashboardWindow()
        Self.performanceUICheckpoint?("dashboard.native_show.begin")
        window.present()
        Self.performanceUICheckpoint?("dashboard.native_show.end")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Preserve navigation and geometry independently of AppKit's closed window
    /// and its backing stores. A minimized or occluded window stays reusable.
    func prepareDashboardWindow() -> DashboardWindow {
        if let dashboardWindow { return dashboardWindow }
        let window = Self.makeDashboardWindow(
            store: metricsStore, actions: menuActions, presentation: dashboardPresentation)
        if let dashboardFrame { window.setFrame(dashboardFrame, display: false) }
        window.presentationClosed = { [weak self] closed in
            guard let self, self.dashboardWindow === closed else { return }
            self.dashboardFrame = closed.frame
            // AppKit still uses the receiver while dispatching willClose.
            DispatchQueue.main.async { [weak self, weak closed] in
                guard let self, let closed, self.dashboardWindow === closed,
                    !closed.isDashboardOpen
                else { return }
                self.dashboardWindow = nil
            }
        }
        dashboardWindow = window
        return window
    }

    /// A Dock click restores the open dashboard, including when it is minimized.
    public func reopenDashboardWindow() {
        guard isStarted, dashboardWindow?.isDashboardOpen == true else { return }
        openDashboardWindow()
    }

    /// Explicit lifecycle control for the isolated app resource harness. These
    /// use the same paths as menu actions and report actual native visibility.
    public func performanceSetDashboardVisible(_ visible: Bool) {
        if visible {
            openDashboardWindow()
        } else {
            Self.performanceUICheckpoint?("dashboard.native_close.begin")
            dashboardWindow?.close()
            Self.performanceUICheckpoint?("dashboard.native_close.end")
        }
    }

    public func performanceSetPopoverVisible(_ visible: Bool) {
        guard isStarted else { return }
        // The harness owns explicit close commands. Incidental focus changes
        // must not shorten its requested visible interval. Keep the native
        // content, animation, visibility and rendering paths unchanged; normal
        // menu interaction continues to use the transient policy from init.
        popover.behavior = .applicationDefined
        if visible != popover.isShown { togglePopover() }
    }

    public var performancePopoverReadiness: PerformancePopoverReadiness {
        let button = statusItem?.button
        let window = button?.window
        return PerformancePopoverReadiness(
            controllerStarted: isStarted, appActive: NSApp.isActive,
            activationPolicy: NSApp.activationPolicy().rawValue,
            anchorExists: button != nil, anchorWindowExists: window != nil,
            anchorWindowVisible: window?.isVisible == true,
            anchorScreenPresent: window?.screen != nil,
            anchorHidden: button?.isHiddenOrHasHiddenAncestor ?? true,
            anchorBoundsWidth: Double(button?.bounds.width ?? 0),
            anchorBoundsHeight: Double(button?.bounds.height ?? 0),
            popoverIsShown: popover.isShown,
            popoverWindowVisible: popover.contentViewController?.view.window?.isVisible == true,
            popoverIsClosing: performancePopoverClosePending,
            dashboardWindowExists: dashboardWindow != nil,
            dashboardNativeVisible: dashboardWindow?.isVisible == true,
            dashboardOcclusionVisible: dashboardWindow?.occlusionState.contains(.visible) == true,
            dashboardMiniaturized: dashboardWindow?.isMiniaturized == true,
            dashboardOpen: dashboardWindow?.isDashboardOpen == true,
            dashboardHostActive: dashboardWindow?.isPresentationContentActive == true)
    }

    /// Wait for native activation, an attached status anchor and completion of
    /// any prior close before the one controlled show attempt. This never opens,
    /// retries, or fabricates a view, and shares the caller's absolute deadline.
    public func performancePreparePopover(until deadline: ContinuousClock.Instant) async
        -> (readiness: PerformancePopoverReadiness, ready: Bool)
    {
        NSApp.activate(ignoringOtherApps: true)
        return await Self.waitForPerformancePopoverReadiness(
            until: deadline, read: { self.performancePopoverReadiness })
    }

    static func waitForPerformancePopoverReadiness(
        until deadline: ContinuousClock.Instant,
        read: @MainActor () -> PerformancePopoverReadiness,
        now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        pause: @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(20)) }
    ) async -> (readiness: PerformancePopoverReadiness, ready: Bool) {
        var state = read()
        while now() < deadline && !Task.isCancelled {
            if state.isReady { return (state, true) }
            await pause()
            state = read()
        }
        return (state, false)
    }

    public var performanceVisibility: (dashboard: Bool, popover: Bool) {
        let dashboardVisible =
            dashboardWindow.map {
                $0.presentationIsVisible && $0.isPresentationContentActive
            } ?? false
        let popoverWindowVisible =
            popover.contentViewController?.view.window.map {
                $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
            } ?? false
        let visible = (
            dashboardVisible,
            popover.isShown && !isPopoverClosing && popoverPresentation.isActive
                && popoverWindowVisible
        )
        if PerformanceGraphicsDiagnostics.shared.isEnabled {
            // The authenticated visibility checkpoints also refresh native
            // window origins; host-local anchors alone cannot see a moved window.
            if visible.0 { dashboardPresentation.refreshScalarPerformanceNativeFrame() }
            if visible.1 { popoverPresentation.refreshScalarPerformanceNativeFrame() }
        }
        return visible
    }

    /// AppKit owns resize limits; SwiftUI gives the chart the remaining height.
    static func makeDashboardWindow(
        store: MetricsStore, actions: MenuActions = MenuActions(),
        presentation: DashboardPresentationState = DashboardPresentationState()
    )
        -> DashboardWindow
    {
        Self.performanceUICheckpoint?("dashboard.native_create.begin")
        let window = DashboardWindow(
            contentRect: NSRect(origin: .zero, size: DashboardView.preferredWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        Self.performanceUICheckpoint?("dashboard.native_create.end")
        window.title = "FluxLLM Dashboard"
        window.isReleasedWhenClosed = false
        window.delegate = window
        presentation.bindScalarPerformanceWindow(window, role: "dashboard")
        window.configurePresentation(
            installPlaceholder: true,
            makeContent: {
                Self.performanceUICheckpoint?("dashboard.swiftui_create.begin")
                let dashboard = DashboardView(actions: actions, presentation: presentation)
                    .environment(store)
                let hosting = NSHostingController(rootView: dashboard)
                hosting.sizingOptions = []
                Self.performanceUICheckpoint?("dashboard.swiftui_create.end")
                return hosting
            },
            visibilityChanged: { visible in
                store.setChartPresentationDemand(visible, consumer: .dashboard)
                presentation.setActive(visible, store: store)
            })
        window.setContentSize(DashboardView.preferredWindowSize)
        window.center()
        return window
    }

    private func showSettings() {
        guard isStarted else { return }
        launchAtLogin.refresh()
        closePopover()
        if settingsWindow == nil {
            settingsWindow = Self.makeSettingsWindow(
                settings: settings, store: metricsStore, launchAtLogin: launchAtLogin,
                onApply: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.applyConfiguration()
                },
                onRescan: { [weak self] in
                    guard let self, self.isStarted else { return }
                    await self.coordinator.rescan()
                })
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// AppKit owns this fixed-size window. Deriving window limits from SwiftUI
    /// content can recursively resize it during safe-area/constraint updates.
    static func makeSettingsWindow(
        settings: AppSettings, store: MetricsStore? = nil,
        launchAtLogin: LaunchAtLoginController? = nil,
        onApply: @escaping () async throws -> Void,
        onRescan: @escaping () async -> Void = {}
    ) -> NSWindow {
        let contentSize = NSSize(width: 560, height: 680)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "FluxLLM Settings"
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(
            rootView: SettingsView(
                settings: settings, store: store, launchAtLogin: launchAtLogin,
                onApply: onApply, onRescan: onRescan))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(contentSize)
        window.center()
        return window
    }

    private func showAbout() {
        guard isStarted else { return }
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        let sourceLink = "github.com/chmorgan/fluxllm"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let credits = NSMutableAttributedString(
            string: "Chris Morgan\n\(sourceLink)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ])
        credits.addAttribute(
            .link, value: "https://\(sourceLink)",
            range: (credits.string as NSString).range(of: sourceLink))
        NSApp.orderFrontStandardAboutPanel(options: [.version: "", .credits: credits])
    }

    private func applyConfiguration() async throws {
        guard isStarted else { throw CancellationError() }
        guard settingsActionTask == nil else { throw CommandError.busy }
        let task = Task { @MainActor [coordinator] in
            try Task.checkCancellation()
            try await coordinator.applySettings()
            try Task.checkCancellation()
        }
        settingsActionTask = task
        defer { settingsActionTask = nil }
        try await task.value
    }

    private var statusVisibility: StatusItemVisibility {
        StatusItemVisibility(
            showLogo: settings.showMenuBarLogo,
            showTokensPerSecond: settings.showMenuBarTokensPerSecond)
    }

    private func updateStatusItem() {
        guard isStarted, let statusItem, let button = statusItem.button else { return }
        PerformancePresentationCounters.shared.record(.statusUpdates)
        let availableHeight =
            button.bounds.height > 0
            ? button.bounds.height : NSStatusBar.system.thickness
        statusWidthBudget.observe(publishedTPS: metricsStore.displayTPS)
        let visibility = statusVisibility
        let snapshot = StatusItemPresentation.snapshot(store: metricsStore)
        let images = statusImageCache.images(
            snapshot: snapshot, availableHeight: availableHeight,
            appearance: button.effectiveAppearance,
            numberCharacters: statusWidthBudget.numberCharacters, visibility: visibility)
        if statusItem.length != images.itemWidth {
            statusItem.length = images.itemWidth
        }
        if button.image !== images.normal { button.image = images.normal }
        if button.alternateImage !== images.highlighted {
            button.alternateImage = images.highlighted
        }
        if statusAccessibilitySummary != snapshot.accessibilitySummary {
            statusAccessibilitySummary = snapshot.accessibilitySummary
            button.toolTip = snapshot.accessibilitySummary
            button.setAccessibilityValue(snapshot.accessibilitySummary)
        }
    }

    private enum CommandError: LocalizedError {
        case busy

        var errorDescription: String? {
            switch self {
            case .busy: "Settings are already being applied. Try again when they finish."
            }
        }
    }
}

/// Native facts captured by the explicit performance adapter, independently of
/// chart demand. Status-bar windows need not be key or main windows.
public struct PerformancePopoverReadiness: Equatable {
    let controllerStarted: Bool
    let appActive: Bool
    let activationPolicy: Int
    let anchorExists: Bool
    let anchorWindowExists: Bool
    let anchorWindowVisible: Bool
    let anchorScreenPresent: Bool
    let anchorHidden: Bool
    let anchorBoundsWidth: Double
    let anchorBoundsHeight: Double
    let popoverIsShown: Bool
    let popoverWindowVisible: Bool
    let popoverIsClosing: Bool
    let dashboardWindowExists: Bool
    let dashboardNativeVisible: Bool
    let dashboardOcclusionVisible: Bool
    let dashboardMiniaturized: Bool
    let dashboardOpen: Bool
    let dashboardHostActive: Bool

    public var isReady: Bool {
        controllerStarted && appActive && !popoverIsClosing && anchorExists && anchorWindowExists
            && anchorWindowVisible && anchorScreenPresent && !anchorHidden
            && anchorBoundsWidth.isFinite && anchorBoundsWidth > 0
            && anchorBoundsHeight.isFinite && anchorBoundsHeight > 0
    }

    public var diagnostics: [String: Any] {
        [
            "controller_started": controllerStarted, "app_active": appActive,
            "activation_policy": activationPolicy,
            "anchor_exists": anchorExists, "anchor_window_exists": anchorWindowExists,
            "anchor_window_visible": anchorWindowVisible,
            "anchor_screen_present": anchorScreenPresent,
            "anchor_hidden": anchorHidden,
            "anchor_bounds_width": anchorBoundsWidth.isFinite ? anchorBoundsWidth as Any : NSNull(),
            "anchor_bounds_height": anchorBoundsHeight.isFinite
                ? anchorBoundsHeight as Any : NSNull(),
            "popover_is_shown": popoverIsShown, "popover_window_visible": popoverWindowVisible,
            "popover_is_closing": popoverIsClosing,
            "dashboard_window_exists": dashboardWindowExists,
            "dashboard_native_visible": dashboardNativeVisible,
            "dashboard_occlusion_visible": dashboardOcclusionVisible,
            "dashboard_is_minimized": dashboardMiniaturized,
            "dashboard_is_open": dashboardOpen,
            "dashboard_host_active": dashboardHostActive,
            "ready": isReady,
        ]
    }
}
