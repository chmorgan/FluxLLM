import AppKit
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class DashboardLifecycleTests: XCTestCase {
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
                host = controller
                return controller
            },
            visibilityChanged: { visible in
                store.setChartPresentationDemand(visible, consumer: .dashboard)
                state.setActive(visible, store: store)
            })

        XCTAssertEqual(creations, 0, "Construction must not initialize the chart renderer")
        window.present()
        window.simulatedVisible = true
        window.synchronizePresentationVisibility()
        XCTAssertEqual(creations, 1)
        XCTAssertNotNil(host)

        let end = Date(timeIntervalSince1970: 2_000_000_000)
        state.navigation.select(
            DateInterval(start: end.addingTimeInterval(-120), end: end), now: end)
        let selected = state.navigation
        let beforeHide = store.chartPresentation.publicationID
        window.simulatedVisible = false
        window.synchronizePresentationVisibility()
        drainNativeUpdates()
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

        window.simulatedVisible = true
        window.synchronizePresentationVisibility()
        XCTAssertEqual(creations, 2)
        XCTAssertNotEqual(presentedSnapshots.last, beforeHide)
        XCTAssertEqual(store.chartPresentation.timestamp, sampledAt)
        XCTAssertEqual(state.navigation, selected)

        window.windowDidMiniaturize(
            Notification(name: NSWindow.didMiniaturizeNotification, object: window))
        drainNativeUpdates()
        XCTAssertNil(host)
        window.simulatedVisible = false
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
        for _ in 0..<4 {
            window.present()
            window.simulatedVisible = true
            window.synchronizePresentationVisibility()
            XCTAssertNotNil(host)
            window.close()
            drainNativeUpdates()
            XCTAssertNil(host)
            XCTAssertEqual(window.contentLayoutRect.size, size)
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
}
