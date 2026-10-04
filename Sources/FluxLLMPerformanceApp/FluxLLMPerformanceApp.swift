import AppKit
import Darwin
import FluxLLMPerformanceSupport
import SwiftUI

/// The production core and native dashboard run with isolated fixture services.
/// The desktop executable neither imports nor links the control implementation.
@main
struct FluxLLMPerformanceApp: App {
    @NSApplicationDelegateAdaptor(PerformanceAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
private final class PerformanceAppDelegate: NSObject, NSApplicationDelegate {
    private let control: PerformanceControl
    private var terminationTask: Task<Void, Never>?

    override init() {
        do {
            control = try PerformanceControl()
            super.init()
        } catch {
            FileHandle.standardError.write(Data("Invalid performance launch: \(error)\n".utf8))
            Darwin.exit(64)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        control.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if control.hasStopped { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor in
            await control.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        false
    }
}
