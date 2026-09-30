import AppKit
import Foundation
import ServiceManagement
import XCTest

@testable import FluxLLM

@MainActor
final class PerformancePopoverPolicyTests: XCTestCase {
    func testLifecycleCheckpointsAreOrderedAndOptionalWithoutOpeningWindows() throws {
        _ = NSApplication.shared
        let original = MenuBarController.performanceUICheckpoint
        defer { MenuBarController.performanceUICheckpoint = original }
        var phases: [String] = []
        MenuBarController.performanceUICheckpoint = { phases.append($0) }
        let suite = "FluxLLM.Performance.CheckpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let store = MetricsStore()
        let coordinator = MonitoringCoordinator(settings: settings, store: store)
        let controller = MenuBarController(
            metricsStore: store, coordinator: coordinator, settings: settings,
            launchAtLogin: LaunchAtLoginController(service: PopoverTestLoginService()))
        defer { controller.stop() }
        XCTAssertEqual(
            Array(phases.prefix(2)), ["popover.native_create.begin", "popover.native_create.end"])
        // Baseline attaches an eager SwiftUI host here; current attaches it on
        // first open. Preserve that production difference in the checkpoints.
        let afterConstruction = phases
        controller.start()
        XCTAssertEqual(phases, afterConstruction)
        XCTAssertFalse(controller.performanceVisibility.popover)
        controller.performanceSetDashboardVisible(false)
        XCTAssertEqual(
            Array(phases.suffix(2)), ["dashboard.native_close.begin", "dashboard.native_close.end"])
        let afterLifecycle = phases
        MenuBarController.performanceUICheckpoint = nil
        controller.stop()
        XCTAssertEqual(phases, afterLifecycle)
    }

    func testReadinessRequiresEveryNativePreconditionAndFiniteGeometry() throws {
        XCTAssertTrue(readiness().isReady)
        for state in [
            readiness(controllerStarted: false), readiness(appActive: false),
            readiness(popoverIsClosing: true),
            readiness(anchorExists: false), readiness(anchorWindowExists: false),
            readiness(anchorWindowVisible: false), readiness(anchorScreenPresent: false),
            readiness(anchorHidden: true), readiness(width: 0), readiness(height: -1),
            readiness(width: .nan), readiness(height: .infinity),
        ] {
            XCTAssertFalse(state.isReady)
            // A failed native geometry read must not suppress its diagnostics.
            XCTAssertTrue(JSONSerialization.isValidJSONObject(state.diagnostics))
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: state.diagnostics))
        }
        XCTAssertTrue(readiness(width: .nan).diagnostics["anchor_bounds_width"] is NSNull)
        XCTAssertTrue(readiness(height: .infinity).diagnostics["anchor_bounds_height"] is NSNull)
    }

    func testReadinessBarrierWaitsForNativeStateWithoutShowingAnyUI() async {
        let start = ContinuousClock.now
        var now = start
        var pauses = 0
        let result = await MenuBarController.waitForPerformancePopoverReadiness(
            until: start.advanced(by: .seconds(4)),
            read: { self.readiness(appActive: pauses >= 2) }, now: { now },
            pause: {
                pauses += 1
                now = now.advanced(by: .seconds(1))
            })
        XCTAssertTrue(result.ready)
        XCTAssertTrue(result.readiness.isReady)
        XCTAssertEqual(pauses, 2)
    }

    func testReadinessBarrierUsesAbsoluteDeadlineAndNeverAcceptsLateReadiness() async {
        let start = ContinuousClock.now
        var now = start
        var pauses = 0
        let result = await MenuBarController.waitForPerformancePopoverReadiness(
            until: start.advanced(by: .seconds(4)),
            read: { self.readiness(appActive: pauses > 0) }, now: { now },
            pause: {
                pauses += 1
                // Model an AppKit/main-actor stall: iteration count must not
                // stretch the allowed readiness and visibility window.
                now = now.advanced(by: .seconds(5))
            })
        XCTAssertFalse(result.ready)
        XCTAssertTrue(result.readiness.isReady)
        XCTAssertEqual(pauses, 1)
        let expired = await MenuBarController.waitForPerformancePopoverReadiness(
            until: start, read: { self.readiness() }, now: { now },
            pause: { XCTFail("An expired barrier must not wait") })
        XCTAssertFalse(expired.ready)
    }

    func testReadinessWaitsForCloseCompletionWhenShownAndWindowStateLag() async {
        let start = ContinuousClock.now
        var now = start
        var pauses = 0
        let result = await MenuBarController.waitForPerformancePopoverReadiness(
            until: start.advanced(by: .seconds(4)),
            read: {
                // The window disappears before isShown clears, and didClose
                // follows both. Neither earlier state permits the next show.
                self.readiness(popoverIsShown: pauses == 0, popoverIsClosing: pauses < 2)
            }, now: { now },
            pause: {
                pauses += 1
                now = now.advanced(by: .seconds(1))
            })
        XCTAssertTrue(result.ready)
        XCTAssertEqual(pauses, 2)
        XCTAssertFalse(result.readiness.popoverIsShown)
        XCTAssertFalse(result.readiness.popoverIsClosing)
        XCTAssertEqual(result.readiness.diagnostics["popover_is_closing"] as? Bool, false)
        // An already visible, stable popover remains an idempotent show target.
        XCTAssertTrue(readiness(popoverIsShown: true, popoverWindowVisible: true).isReady)
    }

    func testCloseCompletionCannotExtendTheSharedFourSecondDeadline() async {
        let start = ContinuousClock.now
        var now = start
        var pauses = 0
        let result = await MenuBarController.waitForPerformancePopoverReadiness(
            until: start.advanced(by: .seconds(4)),
            read: { self.readiness(popoverIsClosing: pauses < 4) }, now: { now },
            pause: {
                pauses += 1
                now = now.advanced(by: .seconds(1))
            })
        XCTAssertEqual(pauses, 4)
        XCTAssertFalse(result.ready)
        XCTAssertFalse(result.readiness.popoverIsClosing)
    }

    func testOnlyNativeDidCloseClearsTheMeasurementClosingLatch() throws {
        _ = NSApplication.shared
        let suite = "FluxLLM.Performance.CloseReadinessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let store = MetricsStore()
        let coordinator = MonitoringCoordinator(settings: settings, store: store)
        let controller = MenuBarController(
            metricsStore: store, coordinator: coordinator, settings: settings,
            launchAtLogin: LaunchAtLoginController(service: PopoverTestLoginService()))
        defer { controller.stop() }
        controller.start()
        controller.performanceSetPopoverVisible(false)
        XCTAssertFalse(controller.performancePopoverReadiness.popoverIsClosing)
        controller.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
        let closing = controller.performancePopoverReadiness
        XCTAssertFalse(closing.popoverIsShown)
        XCTAssertFalse(closing.popoverWindowVisible)
        XCTAssertTrue(closing.popoverIsClosing)
        // A repeated close command cannot treat hidden/isShown=false as didClose.
        controller.performanceSetPopoverVisible(false)
        XCTAssertTrue(controller.performancePopoverReadiness.popoverIsClosing)
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertFalse(controller.performancePopoverReadiness.popoverIsClosing)
        let diagnostics = controller.performancePopoverReadiness.diagnostics
        for key in [
            "dashboard_window_exists", "dashboard_native_visible",
            "dashboard_occlusion_visible", "dashboard_is_minimized",
            "dashboard_is_open", "dashboard_host_active",
        ] {
            XCTAssertEqual(diagnostics[key] as? Bool, false, key)
        }
    }

    private func readiness(
        controllerStarted: Bool = true, appActive: Bool = true,
        anchorExists: Bool = true, anchorWindowExists: Bool = true,
        anchorWindowVisible: Bool = true, anchorScreenPresent: Bool = true,
        anchorHidden: Bool = false, width: Double = 100, height: Double = 24,
        popoverIsShown: Bool = false, popoverWindowVisible: Bool = false,
        popoverIsClosing: Bool = false
    ) -> PerformancePopoverReadiness {
        PerformancePopoverReadiness(
            controllerStarted: controllerStarted, appActive: appActive,
            activationPolicy: NSApplication.ActivationPolicy.regular.rawValue,
            anchorExists: anchorExists, anchorWindowExists: anchorWindowExists,
            anchorWindowVisible: anchorWindowVisible, anchorScreenPresent: anchorScreenPresent,
            anchorHidden: anchorHidden, anchorBoundsWidth: width, anchorBoundsHeight: height,
            popoverIsShown: popoverIsShown, popoverWindowVisible: popoverWindowVisible,
            popoverIsClosing: popoverIsClosing,
            dashboardWindowExists: false, dashboardNativeVisible: false,
            dashboardOcclusionVisible: false, dashboardMiniaturized: false,
            dashboardOpen: false, dashboardHostActive: false)
    }

    func testOnlyExplicitPerformanceControlChangesNativeDismissalPolicy() throws {
        _ = NSApplication.shared
        let suite = "FluxLLM.Performance.PopoverTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let store = MetricsStore()
        let coordinator = MonitoringCoordinator(settings: settings, store: store)
        let controller = MenuBarController(
            metricsStore: store, coordinator: coordinator, settings: settings,
            launchAtLogin: LaunchAtLoginController(service: PopoverTestLoginService()))
        defer { controller.stop() }

        XCTAssertEqual(controller.popoverBehavior, .transient)
        // Commands before startup remain no-ops.
        controller.performanceSetPopoverVisible(false)
        XCTAssertEqual(controller.popoverBehavior, .transient)
        controller.start()
        XCTAssertEqual(controller.popoverBehavior, .transient)
        XCTAssertFalse(controller.performanceVisibility.popover)

        // Selecting the explicit-command policy must not open a native window
        // or fabricate visibility when the requested state is closed.
        controller.performanceSetPopoverVisible(false)
        XCTAssertEqual(controller.popoverBehavior, .applicationDefined)
        XCTAssertFalse(controller.performanceVisibility.popover)
        controller.performanceSetPopoverVisible(false)
        XCTAssertEqual(controller.popoverBehavior, .applicationDefined)
        XCTAssertFalse(controller.performanceVisibility.popover)
        XCTAssertEqual(
            MenuBarController.performancePopoverLifecyclePolicy,
            "explicit-performance-commands-v2")
    }
}

@MainActor
private final class PopoverTestLoginService: LaunchAtLoginService {
    var status: SMAppService.Status { .notRegistered }
    func register() throws { XCTFail("The fixture must not register a login item") }
    func unregister() async throws { XCTFail("The fixture must not unregister a login item") }
    func openSystemSettings() { XCTFail("The fixture must not open system settings") }
}
