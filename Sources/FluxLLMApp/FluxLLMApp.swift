import AppKit
import FluxLLM
import SwiftUI

@main
struct FluxLLMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Owns the shared metrics store, backend monitor, and status bar so they persist
/// independent of any SwiftUI scene (the popover is AppKit-backed).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings: AppSettings
    private let metricsStore: MetricsStore
    private let coordinator: MonitoringCoordinator
    private let launchAtLogin: LaunchAtLoginController
    private let menuBarController: MenuBarController
    private var startupTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?

    override init() {
        let historyDirectory = URL.applicationSupportDirectory
            .appendingPathComponent("FluxLLM", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
        let store = MetricsStore(historyDirectory: historyDirectory)
        let settings = AppSettings()
        let coordinator = MonitoringCoordinator(settings: settings, store: store)
        let launchAtLogin = LaunchAtLoginController()
        self.settings = settings
        self.metricsStore = store
        self.coordinator = coordinator
        self.launchAtLogin = launchAtLogin
        self.menuBarController = MenuBarController(
            metricsStore: store, coordinator: coordinator, settings: settings,
            launchAtLogin: launchAtLogin)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quit and diagnostics remain available even if the listener cannot bind.
        menuBarController.start()
        startupTask = Task { @MainActor in
            await metricsStore.prepareHistory()
            guard !Task.isCancelled else { return }
            metricsStore.startSampling()
            await coordinator.start()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        launchAtLogin.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        // Disable command entry points before asynchronous cleanup starts.
        menuBarController.stop()
        startupTask?.cancel()
        terminationTask = Task { @MainActor in
            // Let an in-flight bind settle before shutting down its channels.
            await startupTask?.value
            await menuBarController.waitForPendingActions()
            await coordinator.stop()
            metricsStore.stopSampling()
            await metricsStore.flushHistory()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        menuBarController.reopenDashboardWindow()
        return false
    }
}
