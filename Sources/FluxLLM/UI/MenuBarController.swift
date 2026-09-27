import AppKit
import SwiftUI

/// Owns one native status item, a transient dashboard, and reusable windows.
@MainActor
public final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let metricsStore: MetricsStore
    private let coordinator: MonitoringCoordinator
    private let settings: AppSettings
    private let launchAtLogin: LaunchAtLoginController
    private let menuActions = MenuActions()
    private let popover = NSPopover()
    private var dashboardWindow: DashboardWindow?
    private var settingsWindow: NSWindow?
    private var iconTimer: Timer?
    private var settingsActionTask: Task<Void, Error>?
    private var statusWidthBudget = StatusItemWidthBudget()
    private var isStarted = false

    public static let appTitle = "FluxLLM"

    public init(
        metricsStore: MetricsStore, coordinator: MonitoringCoordinator, settings: AppSettings,
        launchAtLogin: LaunchAtLoginController? = nil
    ) {
        self.metricsStore = metricsStore
        self.coordinator = coordinator
        self.settings = settings
        self.launchAtLogin = launchAtLogin ?? LaunchAtLoginController()
        super.init()
        wireActions()

        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(
            rootView: MenuBarExtraView(actions: menuActions)
                .environment(metricsStore)
                .frame(width: 360)
                .onExitCommand { [weak self] in self?.popover.performClose(nil) })
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
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
        popover.performClose(nil)
        dashboardWindow?.close()
        settingsWindow?.close()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
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

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
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
        popover.performClose(nil)
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
        popover.performClose(nil)
        if dashboardWindow == nil {
            dashboardWindow = Self.makeDashboardWindow(store: metricsStore, actions: menuActions)
        }
        dashboardWindow?.present()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A Dock click restores the open dashboard, including when it is minimized.
    public func reopenDashboardWindow() {
        guard isStarted, dashboardWindow?.isDashboardOpen == true else { return }
        openDashboardWindow()
    }

    /// AppKit owns resize limits; SwiftUI gives the chart the remaining height.
    static func makeDashboardWindow(store: MetricsStore, actions: MenuActions = MenuActions())
        -> DashboardWindow
    {
        let window = DashboardWindow(
            contentRect: NSRect(origin: .zero, size: DashboardView.preferredWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "FluxLLM Dashboard"
        window.isReleasedWhenClosed = false
        window.delegate = window
        let hosting = NSHostingController(
            rootView: DashboardView(actions: actions).environment(store))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(DashboardView.preferredWindowSize)
        window.center()
        return window
    }

    private func showSettings() {
        guard isStarted else { return }
        launchAtLogin.refresh()
        popover.performClose(nil)
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
        popover.performClose(nil)
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
        let availableHeight =
            button.bounds.height > 0
            ? button.bounds.height : NSStatusBar.system.thickness
        statusWidthBudget.observe(publishedTPS: metricsStore.displayTPS)
        let visibility = statusVisibility
        let layout = StatusItemPresentation.layout(
            numberCharacters: statusWidthBudget.numberCharacters, availableHeight: availableHeight,
            visibility: visibility)
        if statusItem.length != layout.itemWidth {
            statusItem.length = layout.itemWidth
        }
        button.image = StatusItemPresentation.image(
            store: metricsStore, availableHeight: availableHeight,
            appearance: button.effectiveAppearance,
            numberCharacters: statusWidthBudget.numberCharacters, visibility: visibility)
        button.alternateImage = StatusItemPresentation.image(
            store: metricsStore, availableHeight: availableHeight,
            appearance: button.effectiveAppearance, isHighlighted: true,
            numberCharacters: statusWidthBudget.numberCharacters, visibility: visibility)
        let summary = StatusItemPresentation.accessibilitySummary(store: metricsStore)
        button.toolTip = summary
        button.setAccessibilityValue(summary)
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
