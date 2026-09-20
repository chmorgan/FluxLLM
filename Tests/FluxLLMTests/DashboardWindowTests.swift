import AppKit
import XCTest

@testable import FluxLLM

/// Exercise the production window factory, including AppKit/hosting constraints.
@MainActor
final class DashboardWindowTests: XCTestCase {
    func testConstructingAndClosingAnUnopenedDashboardKeepsTheAppPolicyUnchanged() {
        let application = NSApplication.shared
        let initialPolicy = application.activationPolicy()
        let window = MenuBarController.makeDashboardWindow(store: MetricsStore())
        var requestedPolicies: [NSApplication.ActivationPolicy] = []
        window.setActivationPolicy = { requestedPolicies.append($0) }

        XCTAssertFalse(window.isDashboardOpen)
        XCTAssertTrue(window.delegate === window)
        XCTAssertEqual(application.activationPolicy(), initialPolicy)

        window.close()

        XCTAssertFalse(window.isDashboardOpen)
        XCTAssertTrue(requestedPolicies.isEmpty)
        XCTAssertEqual(application.activationPolicy(), initialPolicy)
    }

    func testPresentCloseAndReopenChangePolicyOnlyWhenDashboardOpenStateChanges() {
        let window = makeRecordingWindow()
        defer { window.close() }
        var requestedPolicies: [NSApplication.ActivationPolicy] = []
        window.setActivationPolicy = { requestedPolicies.append($0) }

        window.present()
        window.present()

        XCTAssertTrue(window.isDashboardOpen)
        XCTAssertEqual(requestedPolicies, [.regular])
        XCTAssertEqual(window.presentationEvents, [.orderFront, .orderFront])

        window.close()

        XCTAssertFalse(window.isDashboardOpen)
        XCTAssertEqual(requestedPolicies, [.regular, .accessory])

        window.close()

        XCTAssertEqual(requestedPolicies, [.regular, .accessory])

        window.present()

        XCTAssertTrue(window.isDashboardOpen)
        XCTAssertEqual(requestedPolicies, [.regular, .accessory, .regular])
        XCTAssertEqual(window.presentationEvents, [.orderFront, .orderFront, .orderFront])
    }

    func testPresentingAMinimizedDashboardRestoresItBeforeOrderingWithoutChangingPolicy() {
        let window = makeRecordingWindow()
        defer { window.close() }
        var requestedPolicies: [NSApplication.ActivationPolicy] = []
        window.setActivationPolicy = { requestedPolicies.append($0) }
        window.present()

        window.simulatedMiniaturized = true
        window.delegate?.windowDidMiniaturize?(
            Notification(name: NSWindow.didMiniaturizeNotification, object: window))

        XCTAssertTrue(window.isDashboardOpen)
        XCTAssertEqual(requestedPolicies, [.regular])

        window.present()

        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(window.isDashboardOpen)
        XCTAssertEqual(requestedPolicies, [.regular])
        XCTAssertEqual(window.presentationEvents, [.orderFront, .deminiaturize, .orderFront])

        window.close()

        XCTAssertFalse(window.isDashboardOpen)
        XCTAssertEqual(requestedPolicies, [.regular, .accessory])
    }

    func testDashboardClampsUndersizedWindowsAndKeepsAllowedSizesDuringTelemetryChanges() throws {
        _ = NSApplication.shared
        let store = MetricsStore()
        let window = MenuBarController.makeDashboardWindow(store: store)
        defer { window.close() }
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 320)

        for proposed in [
            NSSize(width: 360, height: 260), NSSize(width: 240, height: 160),
            NSSize(width: 519, height: 330), NSSize(width: 520, height: 330),
            NSSize(width: 740, height: 450), NSSize(width: 900, height: 300),
            DashboardView.preferredWindowSize, NSSize(width: 900, height: 1200),
        ] {
            let size = DashboardSizingPolicy.constrainedContentSize(proposed)
            window.setContentSize(proposed)
            try assertContentSize(size, in: window)
            store.updateConnection(.needsConfiguration, message: "Select a backend")
            try assertContentSize(size, in: window)
            store.updateConnection(.unavailable, message: "Backend not responding")
            try assertContentSize(size, in: window)
        }
    }

    func testInteractiveResizeReservesMoreHeightWhenControlsStack() throws {
        _ = NSApplication.shared
        let window = MenuBarController.makeDashboardWindow(store: MetricsStore())
        defer { window.close() }

        let preferred = DashboardView.preferredWindowSize
        let wideMinimum = DashboardSizingPolicy.minimumContentSize(forWidth: 740)
        let narrowMinimum = DashboardSizingPolicy.minimumContentSize(forWidth: 360)
        XCTAssertGreaterThan(narrowMinimum.height, wideMinimum.height)

        for (proposed, expected) in [
            (NSSize(width: 740, height: 100), wideMinimum),
            (
                NSSize(width: 360, height: preferred.height),
                NSSize(width: 520, height: preferred.height)
            ),
            (narrowMinimum, narrowMinimum),
            (
                NSSize(width: 240, height: narrowMinimum.height),
                NSSize(width: 320, height: narrowMinimum.height)
            ),
            (NSSize(width: 740, height: 100), wideMinimum),
        ] {
            let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: proposed))
            let resized = try XCTUnwrap(
                window.delegate?.windowWillResize?(window, to: frame.size),
                "The native window must enforce the same limits during interactive resizing")
            let content = window.contentRect(forFrameRect: NSRect(origin: .zero, size: resized))
            XCTAssertEqual(content.size.width, expected.width, accuracy: 0.5)
            XCTAssertEqual(content.size.height, expected.height, accuracy: 0.5)
            window.setFrame(NSRect(origin: window.frame.origin, size: resized), display: false)
            try assertContentSize(expected, in: window)
        }
    }

    func testBackendSwitchesDoNotChangeTheWindowMinimum() throws {
        _ = NSApplication.shared
        let store = MetricsStore()
        let window = MenuBarController.makeDashboardWindow(store: store)
        defer { window.close() }

        for width: CGFloat in [320, 360, 519, 520, 740] {
            let minimum = DashboardSizingPolicy.minimumContentSize(forWidth: width)
            window.setContentSize(minimum)
            try assertContentSize(minimum, in: window)
            let nativeMinimum = window.contentMinSize
            for kind in [BackendKind.vllm, .ollama, .rapidMLX] {
                store.beginBackendSession(kind: kind, epoch: UUID())
                try assertContentSize(minimum, in: window)
                XCTAssertEqual(window.contentMinSize, nativeMinimum)
            }
        }
    }

    private func makeRecordingWindow() -> RecordingDashboardWindow {
        _ = NSApplication.shared
        let window = RecordingDashboardWindow(
            contentRect: NSRect(origin: .zero, size: DashboardView.preferredWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.delegate = window
        window.isReleasedWhenClosed = false
        window.setActivationPolicy = { _ in }
        return window
    }

    private func assertContentSize(
        _ size: NSSize, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let view = try XCTUnwrap(window.contentViewController?.view, file: file, line: line)
        for _ in 0..<4 {
            view.needsUpdateConstraints = true
            window.updateConstraintsIfNeeded()
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            XCTAssertEqual(
                window.contentLayoutRect.width, size.width, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(
                window.contentLayoutRect.height, size.height, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(view.bounds.width, size.width, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(view.bounds.height, size.height, accuracy: 0.5, file: file, line: line)
        }
    }
}

@MainActor
private final class RecordingDashboardWindow: DashboardWindow {
    enum PresentationEvent: Equatable {
        case deminiaturize
        case orderFront
    }

    var simulatedMiniaturized = false
    private(set) var presentationEvents: [PresentationEvent] = []

    override var isMiniaturized: Bool { simulatedMiniaturized }

    override func deminiaturize(_ sender: Any?) {
        presentationEvents.append(.deminiaturize)
        simulatedMiniaturized = false
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        presentationEvents.append(.orderFront)
    }
}
