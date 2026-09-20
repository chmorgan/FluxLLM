import AppKit
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testSettingsWindowKeepsItsSizeAcrossConstraintPasses() throws {
        try withSettings { settings in
            let window = MenuBarController.makeSettingsWindow(settings: settings, onApply: {})
            defer { window.close() }
            try assertStableLayout(window)

            // Published preferences invalidate the hosted view while its
            // existing draft remains intact, as happens after applying settings.
            settings.backendSelection = .vllm
            try assertStableLayout(window)
        }
    }

    func testValidationMessagesDoNotResizeSettingsWindow() throws {
        try withSettings { settings in
            settings.backendSelection = .ollama
            for invalidHost in [false, true] {
                settings.proxyPort = invalidHost ? 11435 : 0
                settings.ollamaHost = invalidHost ? "http://localhost:11434/api" : "localhost"
                XCTAssertNotNil(settings.configurationError)
                let window = MenuBarController.makeSettingsWindow(settings: settings, onApply: {})
                defer { window.close() }
                try assertStableLayout(window)
            }
        }
    }

    func testMenuBarVisibilityKeepsWindowSizeAndDoesNotApplyInvalidConnectionDraft() throws {
        try withSettings { settings in
            settings.backendSelection = .ollama
            settings.proxyPort = 0
            XCTAssertNotNil(settings.configurationError)
            var applyCount = 0
            let window = MenuBarController.makeSettingsWindow(
                settings: settings, onApply: { applyCount += 1 })
            defer { window.close() }

            for showLogo in [true, false] {
                for showTokensPerSecond in [true, false] {
                    settings.showMenuBarLogo = showLogo
                    settings.showMenuBarTokensPerSecond = showTokensPerSecond
                    try assertStableLayout(window)
                    XCTAssertEqual(settings.showMenuBarLogo, showLogo)
                    XCTAssertEqual(settings.showMenuBarTokensPerSecond, showTokensPerSecond)
                    XCTAssertEqual(settings.proxyPort, 0)
                    XCTAssertEqual(applyCount, 0)
                }
            }
        }
    }

    func testEveryBackendFitsStableSettingsWindow() throws {
        try withSettings { settings in
            for selection in BackendSelection.allCases {
                settings.backendSelection = selection
                let store = MetricsStore()
                store.setDetections([
                    DetectedBackend(kind: .vllm, baseURL: URL(string: "http://localhost:8000")!)
                ])
                let window = MenuBarController.makeSettingsWindow(
                    settings: settings, store: store, onApply: {})
                try assertStableLayout(window)
                window.close()
            }
        }
    }

    func testNativeBackendValidationDoesNotDependOnUnusedOllamaFields() {
        XCTAssertNil(
            SettingsView.validationError(
                selection: .vllm, proxyPort: "invalid", ollamaHost: "http://invalid/path",
                ollamaPort: "0", endpoints: [.vllm: "http://localhost:8000"]))
        XCTAssertNotNil(
            SettingsView.validationError(
                selection: .ollama, proxyPort: "invalid", ollamaHost: "localhost",
                ollamaPort: "11434", endpoints: [:]))
        XCTAssertNotNil(
            SettingsView.validationError(
                selection: .vllm, proxyPort: "11435", ollamaHost: "localhost",
                ollamaPort: "11434", endpoints: [.vllm: "file:///tmp/server"]))
    }

    private func assertStableLayout(
        _ window: NSWindow, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let hosting = try XCTUnwrap(
            window.contentViewController as? NSHostingController<SettingsView>, file: file,
            line: line)
        XCTAssertTrue(hosting.sizingOptions.isEmpty, file: file, line: line)
        let expectedSize = NSSize(width: 560, height: 680)
        for _ in 0..<4 {
            hosting.view.needsUpdateConstraints = true
            window.updateConstraintsIfNeeded()
            window.layoutIfNeeded()
            XCTAssertEqual(window.contentLayoutRect.size, expectedSize, file: file, line: line)
            XCTAssertEqual(hosting.view.bounds.size, expectedSize, file: file, line: line)
        }
    }

    private func withSettings(_ operation: (AppSettings) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "com.cmorgan.FluxLLM.settings-window-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try operation(AppSettings(defaults: defaults))
    }
}
