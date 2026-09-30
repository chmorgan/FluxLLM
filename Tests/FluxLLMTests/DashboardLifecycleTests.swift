import AppKit
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class DashboardLifecycleTests: XCTestCase {
    func testPopoverPreparationKeepsChartWorkInactiveUntilNativeVisibility() throws {
        _ = NSApplication.shared
        drainNativeUpdates()
        let origin = Date(timeIntervalSince1970: 2_000_000_000)
        let store = MetricsStore(clock: { origin })
        let suite = "FluxLLM.popover-lifecycle-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let coordinator = MonitoringCoordinator(settings: settings, store: store)
        let controller = MenuBarController(
            metricsStore: store, coordinator: coordinator, settings: settings)
        defer { controller.stop() }
        store.setChartPresentationDemand(false, consumer: .popover)
        let unpublished = store.chartPresentation.publicationID
        let counters = PerformancePresentationCounters.shared
        counters.enable()

        let host = controller.preparePopoverContent()
        host.view.layoutSubtreeIfNeeded()
        drainNativeUpdates()
        let initialSize = host.view.fittingSize
        XCTAssertEqual(initialSize.width, DashboardView.compactWidth, accuracy: 0.5)
        XCTAssertEqual(initialSize.height, 480, accuracy: 0.5)
        XCTAssertFalse(
            host.view.window?.isVisible ?? false,
            "Preparing content must not show a native window")

        for second in 1...3 {
            store.sample(at: origin.addingTimeInterval(Double(second)))
            host.view.layoutSubtreeIfNeeded()
            drainNativeUpdates()
        }
        XCTAssertFalse(store.tpsHistory.isEmpty, "Collection continues before a window is visible")
        XCTAssertEqual(store.chartPresentation.publicationID, unpublished)
        XCTAssertTrue(store.chartPresentation.throughput.isEmpty)
        XCTAssertEqual(counters.snapshot()["chart_preparations"], 0)
        XCTAssertEqual(counters.snapshot()["canvas_draws"], 0)
        XCTAssertFalse(controller.performanceVisibility.popover)

        // The native close callbacks remember a measured size without building
        // the chart merely to size the next attempted presentation.
        let remembered = NSSize(width: DashboardView.compactWidth, height: 390)
        host.view.setFrameSize(remembered)
        controller.popoverWillClose(Notification(name: NSPopover.willCloseNotification))
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        let reopened = controller.preparePopoverContent()
        XCTAssertFalse(reopened === host)
        reopened.view.layoutSubtreeIfNeeded()
        drainNativeUpdates()
        XCTAssertEqual(reopened.view.fittingSize.width, remembered.width, accuracy: 0.5)
        XCTAssertEqual(reopened.view.fittingSize.height, remembered.height, accuracy: 0.5)
        XCTAssertEqual(store.chartPresentation.publicationID, unpublished)
        XCTAssertEqual(counters.snapshot()["chart_preparations"], 0)
    }

    func testNativeVisibilityReleasesHostsAndRestoresTheLatestSnapshot() throws {
        _ = NSApplication.shared
        let store = MetricsStore()
        let state = DashboardPresentationState()
        let window = LifecycleDashboardWindow(
            contentRect: NSRect(origin: .zero, size: DashboardView.preferredWindowSize),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.delegate = window
        window.isReleasedWhenClosed = false
        window.setActivationPolicy = { _ in }
        defer { window.close() }
        store.setChartPresentationDemand(false, consumer: .dashboard)
        var creations = 0
        var presentedSnapshots: [UUID] = []
        weak var host: NSViewController?
        window.configurePresentation(
            makeContent: {
                creations += 1
                presentedSnapshots.append(store.chartPresentation.publicationID)
                let controller = NSHostingController(
                    rootView: DashboardView(presentation: state).environment(store))
                controller.sizingOptions = []
                host = controller
                return controller
            },
            visibilityChanged: { visible in
                store.setChartPresentationDemand(visible, consumer: .dashboard)
                state.setActive(visible, store: store)
            })

        XCTAssertEqual(creations, 0, "Construction must not initialize the chart renderer")
        autoreleasepool {
            window.present()
            window.simulatedVisible = true
            window.synchronizePresentationVisibility()
            XCTAssertNotNil(host)
        }
        XCTAssertEqual(creations, 1)

        let end = Date(timeIntervalSince1970: 2_000_000_000)
        state.navigation.select(
            DateInterval(start: end.addingTimeInterval(-120), end: end), now: end)
        let selected = state.navigation
        let beforeHide = store.chartPresentation.publicationID
        autoreleasepool {
            window.simulatedVisible = false
            window.synchronizePresentationVisibility()
            drainNativeUpdates()
        }
        XCTAssertNil(host, "An occluded dashboard must not keep its SwiftUI host alive")
        XCTAssertFalse(window.isPresentationContentActive)
        let hiddenPublication = store.chartPresentation.publicationID

        let sampledAt = store.sampleDate.addingTimeInterval(10)
        store.sample(at: sampledAt)
        XCTAssertEqual(
            store.sampleDate, sampledAt, "Collection continues without a visible dashboard")
        XCTAssertEqual(store.chartPresentation.publicationID, hiddenPublication)
        window.synchronizePresentationVisibility()
        XCTAssertEqual(creations, 1, "Hidden telemetry must not recreate a chart host")

        autoreleasepool {
            window.simulatedVisible = true
            window.synchronizePresentationVisibility()
        }
        XCTAssertEqual(creations, 2)
        XCTAssertNotEqual(presentedSnapshots.last, beforeHide)
        XCTAssertEqual(store.chartPresentation.timestamp, sampledAt)
        XCTAssertEqual(state.navigation, selected)

        autoreleasepool {
            window.simulatedVisible = false
            window.windowDidMiniaturize(
                Notification(name: NSWindow.didMiniaturizeNotification, object: window))
            drainNativeUpdates()
        }
        XCTAssertNil(host)
        window.close()
        XCTAssertFalse(window.isDashboardOpen)
        XCTAssertFalse(window.isPresentationContentActive)
        XCTAssertNil(host)
    }

    func testRepeatedCloseAndReopenReleasesEachHostWithoutLosingNativeSize() {
        _ = NSApplication.shared
        let size = DashboardView.preferredWindowSize
        let window = LifecycleDashboardWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.delegate = window
        window.isReleasedWhenClosed = false
        window.setActivationPolicy = { _ in }
        weak var host: NSViewController?
        var creations = 0
        var changes: [Bool] = []
        window.configurePresentation(
            makeContent: {
                creations += 1
                let controller = NSViewController()
                controller.view = NSView()
                host = controller
                return controller
            }, visibilityChanged: { changes.append($0) })
        for cycle in 0..<4 {
            let selectedSize = cycle.isMultiple(of: 2) ? size : NSSize(width: 900, height: 900)
            window.setContentSize(selectedSize)
            let selectedFrame = window.frame
            autoreleasepool {
                window.present()
                window.simulatedVisible = true
                window.synchronizePresentationVisibility()
                XCTAssertNotNil(host)
                XCTAssertEqual(
                    window.frame, selectedFrame,
                    "Attaching an unsized view must preserve the window")
                window.close()
                drainNativeUpdates()
            }
            XCTAssertNil(host)
            XCTAssertEqual(window.contentLayoutRect.size, selectedSize)
            XCTAssertEqual(
                window.frame, selectedFrame,
                "Detaching content must also preserve position and size")
        }
        XCTAssertEqual(creations, 4)
        XCTAssertEqual(changes, [true, false, true, false, true, false, true, false])
    }

    func testSuspensionReleasesPreparedHistoriesAndBackendChangesResetNavigation() {
        let store = MetricsStore()
        let state = DashboardPresentationState()
        state.setActive(true, store: store)
        let snapshot = ChartPerformanceFixture.publications(
            retainedSeconds: 120, laneCount: 3, count: 1)[0]
        weak var prepared: PreparedDashboardCharts?
        do {
            let value = state.chartPreparation.histories(snapshot: snapshot, duration: 60)
            prepared = value
        }
        XCTAssertNotNil(prepared)
        state.navigation.select(
            DateInterval(
                start: snapshot.timestamp.addingTimeInterval(-120), end: snapshot.timestamp),
            now: snapshot.timestamp)
        let selected = state.navigation
        state.setActive(false, store: store)
        XCTAssertNil(prepared)
        state.setActive(true, store: store)
        XCTAssertEqual(state.navigation, selected)
        state.setActive(false, store: store)
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        state.setActive(true, store: store)
        XCTAssertTrue(state.navigation.isLive)
        XCTAssertEqual(state.navigation.preset, store.historyRange)
    }

    private func drainNativeUpdates() {
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}

@MainActor
private final class LifecycleDashboardWindow: DashboardWindow {
    var simulatedVisible = false
    override var presentationIsVisible: Bool { isDashboardOpen && simulatedVisible }
    override func makeKeyAndOrderFront(_ sender: Any?) {}
    override func close() {
        // This mock never orders a native window in, so AppKit does not reset
        // its internal closed state on present(). Deliver the matching close
        // event for each simulated presentation; the production callback is
        // idempotent when super.close also delivers it on the first cycle.
        simulatedVisible = false
        windowWillClose(Notification(name: NSWindow.willCloseNotification, object: self))
        super.close()
    }
}
