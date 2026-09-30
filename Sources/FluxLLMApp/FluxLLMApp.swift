import AppKit
import Darwin
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
    private var settings: AppSettings!
    private var metricsStore: MetricsStore!
    private var coordinator: MonitoringCoordinator!
    private var launchAtLogin: LaunchAtLoginController!
    private var menuBarController: MenuBarController!
    private var performanceControl: PerformanceControl?
    private var startupTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?

    override init() {
        if ProcessInfo.processInfo.arguments.contains("--performance-control") {
            do {
                performanceControl = try PerformanceControl()
                super.init()
                return
            } catch {
                FileHandle.standardError.write(Data("Invalid performance launch: \(error)\n".utf8))
                Darwin.exit(64)
            }
        }
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
        if let performanceControl {
            performanceControl.start()
            return
        }
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
        guard performanceControl == nil else { return }
        launchAtLogin.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if performanceControl?.hasStopped == true { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        if let performanceControl {
            terminationTask = Task { @MainActor in
                await performanceControl.stop()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
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
        guard performanceControl == nil else { return false }
        menuBarController.reopenDashboardWindow()
        return false
    }
}
