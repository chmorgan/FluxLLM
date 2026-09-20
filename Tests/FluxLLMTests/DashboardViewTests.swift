import XCTest

@testable import FluxLLM

/// Command and construction contracts only. Native menu clicks, popover dismissal,
/// and actual application termination are covered by the manual POC checklist.
@MainActor
final class DashboardViewTests: XCTestCase {
    func testDashboardViewConstructsWithDefaultActions() {
        let _ = DashboardView()
    }

    func testVisibleAndContextMenusUseSameQuitCommand() {
        XCTAssertTrue(MenuCommand.allCases.contains(.quit))
        XCTAssertEqual(MenuCommand.quit.title, MenuBarExtraView.quitTitle)
        XCTAssertEqual(MenuCommand.quit.keyEquivalent, "q")
        XCTAssertEqual(MenuCommand.settings.keyEquivalent, ",")
    }

    func testEachMenuCommandDispatchesOnlyItsMatchingAction() {
        let actions = MenuActions()
        var received: [String] = []
        actions.onOpenDashboardWindow = { received.append("dashboard") }
        actions.onShowSettings = { received.append("settings") }
        actions.onShowAbout = { received.append("about") }
        actions.onQuit = { received.append("quit") }
        actions.perform(.dashboard)
        actions.perform(.settings)
        actions.perform(.about)
        actions.perform(.quit)
        XCTAssertEqual(received, ["dashboard", "settings", "about", "quit"])
    }
}
