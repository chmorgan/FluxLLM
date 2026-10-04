import AppKit
import Darwin
import FluxLLM
import FluxLLMPerformanceSupport
import Foundation

/// A minimal native application for drawing isolation. The external resource
/// collector owns process sampling; this process owns only the requested view.
@main
struct FluxLLMDrawingProbe {
    @MainActor
    static func main() {
        _ = signal(SIGPIPE, SIG_IGN)
        do {
            let control = try DrawingProbeControl()
            let application = NSApplication.shared
            let delegate = DrawingProbeDelegate(control: control)
            application.setActivationPolicy(.accessory)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            // Launch rejection must not write to arbitrary inherited files.
            // Report over FD4 only after both endpoints pass pipe validation.
            if DrawingProbeControl.hasValidControlPipes {
                try? DrawingProbeControl.writeEvent([
                    "type": "error", "command_id": "launch", "protocol_version": 1,
                    "backend": NSNull(), "primitive": NSNull(),
                    "error": String(describing: error),
                ])
            }
            FileHandle.standardError.write(Data("Drawing probe launch failed: \(error)\n".utf8))
            Darwin.exit(2)
        }
    }
}

@MainActor
private final class DrawingProbeDelegate: NSObject, NSApplicationDelegate {
    private let control: DrawingProbeControl

    init(control: DrawingProbeControl) {
        self.control = control
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        control.startReading()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await control.fail(
                "Native termination interrupted the drawing probe", commandID: "termination")
        }
        return .terminateLater
    }
}

@MainActor
private final class DrawingProbeControl {
    // Preserve the field names in the performance JSON protocol.
    // swift-format-ignore: AlwaysUseLowerCamelCase
    private struct Configuration: Decodable {
        let protocol_version: Int
        let history: String
        let drawing_backend: String
        let drawing_primitive: String
    }

    // Preserve the field names in the performance JSON protocol.
    // swift-format-ignore: AlwaysUseLowerCamelCase
    private struct Command: Decodable, Sendable {
        let command: String
        let command_id: String
        let protocol_version: Int?
        let count: Int?
    }

    private enum ControlError: Error, CustomStringConvertible {
        case invalid(String)

        var description: String {
            switch self {
            case .invalid(let message): message
            }
        }
    }

    private let configuration: Configuration
    private var session: DrawingProbeSession?
    private var reader: Thread?
    private var handshaken = false
    private var stopping = false

    init() throws {
        guard ProcessInfo.processInfo.arguments.contains("--performance-control") else {
            throw ControlError.invalid("The explicit --performance-control argument is required")
        }
        try Self.validatePipe(3, reading: true)
        try Self.validatePipe(4, reading: false)
        guard let json = ProcessInfo.processInfo.environment["FLUXLLM_PERFORMANCE_CONFIGURATION"],
            let data = json.data(using: .utf8), data.count <= 4096
        else {
            throw ControlError.invalid("Missing or oversized drawing probe configuration")
        }
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        guard configuration.protocol_version == 1, configuration.history == "fresh",
            ["image-renderer", "canvas", "core-graphics", "core-graphics-unhosted", "bitmap-layer"]
                .contains(configuration.drawing_backend),
            [
                "empty", "line", "solid-fill", "linear-gradient", "radial-gradient", "text",
                "clipped-line",
                "layer-line", "with-cg-line", "chart-path",
            ].contains(configuration.drawing_primitive)
        else {
            throw ControlError.invalid(
                "Invalid drawing probe protocol, history, backend, or primitive")
        }
        self.configuration = configuration
    }

    /// Off-main parsing and one in-flight command keep the measurement process
    /// from accumulating a task or reply queue when drawing becomes expensive.
    func startReading() {
        let thread = Thread { [weak self] in
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(3, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.append(contentsOf: bytes.prefix(count))
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard !line.isEmpty, line.count <= 4096,
                        let command = try? JSONDecoder().decode(Command.self, from: line),
                        !command.command_id.isEmpty, command.command_id.utf8.count <= 128,
                        !command.command.isEmpty, command.command.utf8.count <= 64
                    else {
                        Task { @MainActor [weak self] in
                            await self?.fail(
                                "Malformed or oversized control command", commandID: "invalid")
                        }
                        return
                    }
                    let completed = DispatchSemaphore(value: 0)
                    Task { @MainActor [weak self] in
                        defer { completed.signal() }
                        await self?.handle(command)
                    }
                    completed.wait()
                }
                guard buffer.count <= 4096 else {
                    Task { @MainActor [weak self] in
                        await self?.fail("Oversized control command", commandID: "invalid")
                    }
                    return
                }
            }
            Task { @MainActor [weak self] in
                await self?.fail(
                    "Drawing probe collector pipe closed", commandID: "collector-disconnected")
            }
        }
        thread.name = "FluxLLM drawing probe control"
        reader = thread
        thread.start()
    }

    private func handle(_ command: Command) async {
        guard !stopping else { return }
        do {
            if !handshaken {
                guard command.command == "handshake", command.protocol_version == 1 else {
                    throw ControlError.invalid(
                        "A protocol-version-1 handshake must be the first command")
                }
                handshaken = true
                let created = try DrawingProbeSession(
                    backend: configuration.drawing_backend,
                    primitive: configuration.drawing_primitive)
                session = created
                // start() validates that this process's owned native window is
                // visible before readiness becomes a measurement boundary.
                try await created.start()
                try send("ready", command: command)
                return
            }
            guard command.protocol_version == nil || command.protocol_version == 1 else {
                throw ControlError.invalid("Unsupported command protocol version")
            }
            guard let session else {
                throw ControlError.invalid("Drawing probe session is unavailable")
            }
            switch command.command {
            case "snapshot":
                break
            case "draw_once":
                try await session.drawOnce()
            case "redraw":
                let count = command.count ?? 100
                guard (1...300).contains(count) else {
                    throw ControlError.invalid("redraw count must be between 1 and 300")
                }
                try await session.redraw(count: count)
            case "close":
                try await session.close()
            case "shutdown":
                stopping = true
                try await session.close()
                try send("stopped", command: command)
                Darwin.exit(0)
            default:
                throw ControlError.invalid(
                    "Unknown or repeated control command: \(command.command)")
            }
            try send("ack", command: command)
        } catch {
            // A failed shutdown still needs an error event and a nonzero exit.
            stopping = false
            await fail(String(describing: error), commandID: command.command_id)
        }
    }

    private func send(_ type: String, command: Command) throws {
        var event = baseEvent(type, commandID: command.command_id)
        event["command"] = command.command
        event["status"] = "ok"
        // Deliberately separate from the application telemetry "snapshot".
        // The collector runner must not apply popover validation to this probe.
        event["drawing_snapshot"] = session?.snapshot() ?? [:]
        try Self.writeEvent(event)
    }

    func fail(_ message: String, commandID: String) async {
        guard !stopping else { return }
        stopping = true
        var failure = message
        do { try await session?.close() } catch { failure += "; cleanup failed: \(error)" }
        var event = baseEvent("error", commandID: commandID)
        event["error"] = failure
        event["drawing_snapshot"] = session?.snapshot() ?? [:]
        try? Self.writeEvent(event)
        Darwin.exit(2)
    }

    private func baseEvent(_ type: String, commandID: String) -> [String: Any] {
        [
            "type": type, "command_id": commandID, "protocol_version": 1,
            "backend": configuration.drawing_backend, "primitive": configuration.drawing_primitive,
            "monotonic_seconds": Self.monotonicSeconds(),
        ]
    }

    nonisolated static var hasValidControlPipes: Bool {
        do {
            try validatePipe(3, reading: true)
            try validatePipe(4, reading: false)
            return true
        } catch { return false }
    }

    private nonisolated static func validatePipe(_ descriptor: Int32, reading: Bool) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
            information.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO)
        else {
            throw ControlError.invalid("Drawing control requires inherited pipes on FD 3 and FD 4")
        }
        let flags = fcntl(descriptor, F_GETFL)
        let mode = flags & O_ACCMODE
        guard flags >= 0, reading ? mode != O_WRONLY : mode != O_RDONLY else {
            throw ControlError.invalid("Inherited control pipes have incorrect access directions")
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw ControlError.invalid("Cannot isolate inherited control descriptors")
        }
    }

    nonisolated static func writeEvent(_ event: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        guard body.count <= 32768 else {
            throw ControlError.invalid("Drawing probe event exceeds its size limit")
        }
        let data = body + Data([10])
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(4, address.advanced(by: sent), bytes.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ControlError.invalid("Cannot write drawing probe event")
                }
                sent += count
            }
        }
    }

    private nonisolated static func monotonicSeconds() -> Double {
        var value = timespec()
        clock_gettime(CLOCK_MONOTONIC, &value)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }
}
