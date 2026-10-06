import AppKit
import Darwin
import FluxLLM
import Foundation

/// Inherited-pipe control is available only with the explicit launch argument.
/// Nothing in this adapter listens on a control network port or uses real app
/// preferences/history. The external collector owns resource measurements.
@MainActor
package final class PerformanceControl {
    // Preserve the field names in the performance JSON protocol.
    // swift-format-ignore: AlwaysUseLowerCamelCase
    private struct Configuration: Decodable {
        let upstream_url: String
        let history: String
        let protocol_version: Int
        let logging_enabled: Bool?
        let fixture_ending_at_epoch: Double?
        let graphics_mode: PerformanceGraphicsDiagnostics.Mode?
        let popover_animations_enabled: Bool?
        let backend_kind: BackendKind?
    }

    // Preserve the field names in the performance JSON protocol.
    // swift-format-ignore: AlwaysUseLowerCamelCase
    private struct Command: Decodable, Sendable {
        let command: String
        let command_id: String
        let protocol_version: Int?
        let enabled: Bool?
    }

    private let configuration: Configuration
    private let upstream: URL
    private let runDirectory: URL
    private let historyDirectory: URL
    private let preferencesSuite: String
    private let writer = PerformanceEventWriter()
    private var gpuReporter: PerformanceGPUReporter?
    private var session: PerformanceApplicationSession?
    private var startupTask: Task<PerformanceApplicationSession, Error>?
    private var reader: Thread?
    private var handshaken = false
    private var stopping = false
    private var stopTask: Task<Void, Never>?
    package private(set) var hasStopped = false
    private var shutdownCommandID = "termination"
    private var checkpointSequence = 0
    private var checkpointParentCommandID = "collector-handshake"

    package init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard ProcessInfo.processInfo.arguments.contains("--performance-control") else {
            throw ControlError.invalid("The explicit performance-control argument is required")
        }
        try Self.validatePipe(3, reading: true)
        try Self.validatePipe(4, reading: false)
        guard let json = environment["FLUXLLM_PERFORMANCE_CONFIGURATION"],
            let data = json.data(using: .utf8), data.count <= 4096
        else { throw ControlError.invalid("Missing or oversized performance configuration") }
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        guard configuration.protocol_version == 1,
            ["fresh", "populated"].contains(configuration.history),
            let parts = URLComponents(string: configuration.upstream_url),
            parts.scheme == "http", parts.host == "127.0.0.1",
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.path.isEmpty, let port = parts.port, (1...65535).contains(port),
            let upstream = parts.url
        else {
            throw ControlError.invalid("Invalid performance configuration or non-loopback upstream")
        }
        let backend = configuration.backend_kind ?? .ollama
        guard [.ollama, .unsloth].contains(backend),
            backend != .unsloth || configuration.history == "fresh"
        else {
            throw ControlError.invalid("Native Unsloth performance supports fresh history only")
        }
        if let epoch = configuration.fixture_ending_at_epoch {
            guard epoch.isFinite, abs(Date().timeIntervalSince1970 - epoch) < 120 else {
                throw ControlError.invalid("Fixture ending time must be finite and recent")
            }
        }
        let fileManager = FileManager.default
        let root = URL(
            fileURLWithPath: environment["FLUXLLM_PERFORMANCE_STORAGE_ROOT"]
                ?? fileManager.temporaryDirectory.path, isDirectory: true
        )
        .standardizedFileURL.resolvingSymlinksInPath()
        let allowed = [
            fileManager.temporaryDirectory, URL(fileURLWithPath: "/private/tmp", isDirectory: true),
        ]
        .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        var isDirectory: ObjCBool = false
        guard allowed.contains(where: { root.path == $0 || root.path.hasPrefix($0 + "/") }),
            fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ControlError.invalid(
                "Performance storage root must be an existing temporary directory")
        }
        let runID: UUID
        if let supplied = environment["FLUXLLM_PERFORMANCE_RUN_ID"] {
            guard let parsed = UUID(uuidString: supplied) else {
                throw ControlError.invalid("Performance run ID must be a UUID")
            }
            runID = parsed
        } else {
            runID = UUID()
        }
        let directory = root.appendingPathComponent(runID.uuidString, isDirectory: true)
        let history = directory.appendingPathComponent("History", isDirectory: true)
        try Self.validatePreparedDirectory(directory, history: history)
        self.configuration = configuration
        self.upstream = upstream
        self.runDirectory = directory
        self.historyDirectory = history
        self.preferencesSuite = "FluxLLM.Performance.\(runID.uuidString)"
        _ = signal(SIGPIPE, SIG_IGN)
        let reporter = PerformanceGPUReporter(writer: writer)
        gpuReporter = reporter
        reporter.start()
    }

    package func start() {
        NSApp.setActivationPolicy(.accessory)
        let thread = Thread { [weak self] in
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(3, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                buffer.append(contentsOf: bytes.prefix(count))
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard !line.isEmpty, line.count <= 4096,
                        let command = try? JSONDecoder().decode(Command.self, from: line),
                        !command.command_id.isEmpty, command.command_id.utf8.count <= 128,
                        command.command.utf8.count <= 64
                    else {
                        Task { @MainActor [weak self] in
                            self?.fail("Malformed control command", commandID: "invalid")
                        }
                        return
                    }
                    // One in-flight command bounds both queued actor work and
                    // reply volume. Input parsing runs off the app main thread.
                    let finished = DispatchSemaphore(value: 0)
                    Task { @MainActor [weak self] in
                        await self?.handle(command)
                        finished.signal()
                    }
                    finished.wait()
                }
                if buffer.count > 4096 {
                    Task { @MainActor [weak self] in
                        self?.fail("Oversized control command", commandID: "invalid")
                    }
                    return
                }
            }
            Task { @MainActor [weak self] in
                guard let self, !self.stopping else { return }
                self.fail("Performance collector pipe closed", commandID: "collector-disconnected")
            }
        }
        thread.name = "FluxLLM performance control"
        reader = thread
        thread.start()
    }

    private func handle(_ command: Command) async {
        guard !stopping else { return }
        if !handshaken {
            guard command.command == "handshake", command.protocol_version == 1 else {
                fail(
                    "A protocol-version-1 handshake must be the first command",
                    commandID: command.command_id)
                return
            }
            handshaken = true
            checkpointParentCommandID = command.command_id
            MenuBarController.performanceUICheckpoint = { [weak self] phase in
                self?.emitUICheckpoint(phase)
            }
            let task = Task { @MainActor in
                try await PerformanceApplicationSession.start(
                    upstream: upstream, historyDirectory: historyDirectory,
                    preferencesSuite: preferencesSuite,
                    populated: configuration.history == "populated",
                    fixtureEndingAt: configuration.fixture_ending_at_epoch.map(
                        Date.init(timeIntervalSince1970:)),
                    backendKind: configuration.backend_kind ?? .ollama,
                    graphicsMode: configuration.graphics_mode ?? .normal,
                    popoverAnimationsEnabled: configuration.popover_animations_enabled ?? true,
                    threadCPUAccountingEnabled: ProcessInfo.processInfo.environment[
                        "FLUXLLM_PERF_THREAD_CPU"] == "1",
                    nioCPUAccountingEnabled: ProcessInfo.processInfo.environment[
                        "FLUXLLM_PERF_NIO_CPU"] == "1")
            }
            startupTask = task
            do {
                let started = try await task.value
                session = started
                startupTask = nil
                try await started.store.diagnosticLogger.setEnabled(
                    configuration.logging_enabled ?? false,
                    directory: try validatedLoggingDirectory())
                gpuReporter?.sample()
                try await started.refreshPerformanceNIODiagnostics()
                var event: [String: Any] = [
                    "type": "ready", "command_id": command.command_id, "protocol_version": 1,
                    "proxy_port": started.proxyPort,
                    "proxy_url": "http://127.0.0.1:\(started.proxyPort)",
                    "history_directory": historyDirectory.path,
                    "preferences_suite": preferencesSuite,
                    "popover_lifecycle_policy": MenuBarController.performancePopoverLifecyclePolicy,
                    "ui_checkpoint_schema_version": 1,
                    "ui_checkpoint_sampling": "self-rusage-and-collector-receipt",
                    "fixture_schema_version": PerformanceHistoryFixture.schemaVersion,
                    "fixture_equivalence_sha256": started.fixtureManifest.sha256,
                    "fixture_component_sha256": started.fixtureManifest.components,
                    "snapshot": snapshot(of: started), "logging_supported": true,
                    "logging_enabled": started.store.diagnosticLogger.isEnabled,
                    "logging_destination": loggingDestination.path,
                    "logging_destinations": loggingDestinations,
                    "monotonic_seconds": Self.monotonicSeconds(),
                ]
                if started.backendKind == .unsloth {
                    event.removeValue(forKey: "proxy_port")
                    event.removeValue(forKey: "proxy_url")
                    event["load_url"] = started.loadURL.absoluteString
                    event["backend_kind"] = started.backendKind.rawValue
                    event["discovery_scope"] = "synthetic-stable-loopback"
                }
                send(event)
            } catch {
                startupTask = nil
                fail("Performance startup failed: \(error)", commandID: command.command_id)
            }
            return
        }
        guard let session else {
            fail("Performance startup is unavailable", commandID: command.command_id)
            return
        }
        if ["show_dashboard", "close_dashboard", "show_popover", "close_popover", "shutdown"]
            .contains(command.command)
        {
            checkpointParentCommandID = command.command_id
        }
        var status = "ok"
        var reason: String?
        var popoverReadinessBeforeShow: [String: Any]?
        var uiFailurePhase: String?
        switch command.command {
        case "snapshot":
            break
        case "show_dashboard":
            session.menuBarController.performanceSetDashboardVisible(true)
            if !(await waitForVisibility(dashboard: true)) {
                status = "error"
                reason = "Dashboard did not become visible"
            }
        case "close_dashboard":
            session.menuBarController.performanceSetDashboardVisible(false)
            if !(await waitForVisibility(dashboard: false)) {
                status = "error"
                reason = "Dashboard did not close"
            }
        case "show_popover":
            // Activation, anchor readiness and native visibility share one
            // deadline; successful preparation permits exactly one show call.
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            emitUICheckpoint("popover.readiness.begin")
            let prepared = await session.menuBarController.performancePreparePopover(
                until: deadline)
            emitUICheckpoint("popover.readiness.end")
            popoverReadinessBeforeShow = prepared.readiness.diagnostics
            if !prepared.ready {
                status = "error"
                reason = "Popover native anchor did not become ready"
                uiFailurePhase = "popover_readiness"
            } else {
                session.menuBarController.performanceSetPopoverVisible(true)
                if !(await waitForVisibility(popover: true, until: deadline)) {
                    status = "error"
                    reason = "Popover did not become visible"
                    uiFailurePhase = "popover_visibility"
                }
                emitUICheckpoint("popover.visibility_wait.end")
            }
        case "close_popover":
            session.menuBarController.performanceSetPopoverVisible(false)
            if !(await waitForVisibility(popover: false)) {
                status = "error"
                reason = "Popover did not close"
            }
        case "set_logging":
            guard let enabled = command.enabled else {
                fail("set_logging requires enabled: boolean", commandID: command.command_id)
                return
            }
            do {
                try await session.store.diagnosticLogger.setEnabled(
                    enabled, directory: try validatedLoggingDirectory())
            } catch {
                status = "error"
                reason = session.store.diagnosticLogger.errorMessage ?? String(describing: error)
            }
        case "shutdown":
            shutdownCommandID = command.command_id
        default:
            fail(
                "Unknown or repeated control command: \(command.command)",
                commandID: command.command_id)
            return
        }
        do {
            try await session.refreshPerformanceNIODiagnostics()
        } catch {
            fail("NIO CPU control checkpoint failed: \(error)", commandID: command.command_id)
            return
        }
        var event: [String: Any] = [
            "type": "ack", "command": command.command, "command_id": command.command_id,
            "status": status, "snapshot": snapshot(of: session),
        ]
        if command.command == "set_logging" {
            let logger = session.store.diagnosticLogger
            event["logging_enabled"] = logger.isEnabled
            // setEnabled(false) returns/throws only after acceptance has
            // stopped and its serial writer has drained and closed.
            event["drained"] = command.enabled == false && !logger.isEnabled && !logger.isUpdating
            event["logging_destination"] = loggingDestination.path
            event["logging_destinations"] = loggingDestinations
        }
        if command.command == "show_popover" || command.command == "close_popover" {
            event["popover_readiness"] =
                session.menuBarController.performancePopoverReadiness.diagnostics
        }
        if let popoverReadinessBeforeShow {
            event["popover_readiness_before_show"] = popoverReadinessBeforeShow
        }
        if let uiFailurePhase { event["ui_failure_phase"] = uiFailurePhase }
        event["monotonic_seconds"] = Self.monotonicSeconds()
        if let reason { event["reason"] = reason }
        gpuReporter?.sample()
        send(event)
        if command.command == "shutdown" {
            // Complete async production cleanup while the ordinary app run
            // loop is active. AppKit can then terminate synchronously without
            // relying on SwiftUI to schedule work inside terminateLater.
            await stop()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func waitForVisibility(
        dashboard: Bool? = nil, popover: Bool? = nil,
        until deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: .seconds(2))
    ) async -> Bool {
        while ContinuousClock.now < deadline && !Task.isCancelled {
            guard let visibility = session?.menuBarController.performanceVisibility else {
                return false
            }
            if dashboard.map({ $0 == visibility.dashboard }) ?? true,
                popover.map({ $0 == visibility.popover }) ?? true
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    package func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        stopping = true
        let task = Task { @MainActor in await completeStop() }
        stopTask = task
        await task.value
    }

    private func completeStop() async {
        if let startupTask {
            session = try? await startupTask.value
            self.startupTask = nil
        }
        await session?.stop { [weak self] phase in
            guard let self else { return }
            send([
                "type": "shutdown_phase", "command_id": shutdownCommandID,
                "phase": phase, "monotonic_seconds": Self.monotonicSeconds(),
            ])
        }
        MenuBarController.performanceUICheckpoint = nil
        gpuReporter?.stopAndEmitFinal()
        hasStopped = true
        var event: [String: Any] = [
            "type": "stopped", "command_id": shutdownCommandID, "status": "ok",
        ]
        if let error = session?.shutdownError {
            event["status"] = "error"
            event["error"] = error
        }
        send(event)
    }

    private func fail(_ message: String, commandID: String) {
        send(["type": "error", "command_id": commandID, "error": message])
        NSApp.terminate(nil)
    }

    private func emitUICheckpoint(_ phase: String) {
        checkpointSequence += 1
        // A distinct ID makes the collector sample this lifecycle boundary
        // without satisfying the runner's pending command acknowledgement.
        // Self rusage preserves short-lived allocation peaks at the producer;
        // the independent collector receipt sample exposes observer latency.
        var usage = rusage_info_v4()
        let started = Self.monotonicSeconds()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        let errorCode: Int32? = result == 0 ? nil : errno
        let finished = Self.monotonicSeconds()
        send([
            "type": "ui_checkpoint", "checkpoint_schema_version": 1,
            "command_id": "ui-checkpoint-\(checkpointSequence)",
            "parent_command_id": checkpointParentCommandID, "phase": phase,
            "process_id": getpid(), "birth_time_us": gpuReporter?.birthTime as Any? ?? NSNull(),
            "monotonic_seconds": (started + finished) / 2,
            "resource_read_started_monotonic_seconds": started,
            "resource_read_finished_monotonic_seconds": finished,
            "resource_provider": "self-proc-pid-rusage-v4",
            "resource_kernel_result": result, "resource_errno": errorCode as Any? ?? NSNull(),
            "process_start_abstime": result == 0 ? usage.ri_proc_start_abstime as Any : NSNull(),
            "physical_footprint_bytes": result == 0 ? usage.ri_phys_footprint as Any : NSNull(),
            "lifetime_peak_footprint_bytes": result == 0
                ? usage.ri_lifetime_max_phys_footprint as Any : NSNull(),
            "physical_write_bytes": result == 0 ? usage.ri_diskio_byteswritten as Any : NSNull(),
            "logical_write_bytes": result == 0 ? usage.ri_logical_writes as Any : NSNull(),
        ])
    }

    private func send(_ object: [String: Any]) {
        writer.send(object)
    }

    private var loggingDirectory: URL {
        runDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var loggingDestination: URL {
        loggingDirectory.appendingPathComponent("diagnostics.jsonl")
    }

    private var loggingDestinations: [String] {
        [loggingDirectory.path, loggingDestination.path]
            + (1...2).map {
                loggingDirectory.appendingPathComponent("diagnostics.\($0).jsonl").path
            }
    }

    private func validatedLoggingDirectory() throws -> URL {
        let directory = loggingDirectory
        guard
            directory.resolvingSymlinksInPath().standardizedFileURL.path
                == directory.standardizedFileURL.path
        else {
            throw ControlError.invalid(
                "The diagnostic destination must remain inside the owned run directory")
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ControlError.invalid("The diagnostic destination must be a directory")
            }
        }
        return directory
    }

    private func snapshot(of session: PerformanceApplicationSession) -> [String: Any] {
        var value = session.snapshot()
        let logger = session.store.diagnosticLogger
        value["logging_enabled"] = logger.isEnabled
        value["logging_supported"] = true
        value["logging_dropped_records"] = logger.droppedCount
        value["logging_error"] = logger.errorMessage as Any? ?? NSNull()
        return value
    }

    private nonisolated static func validatePipe(_ descriptor: Int32, reading: Bool) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
            information.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO)
        else {
            throw ControlError.invalid("Performance control requires inherited pipes on FD 3 and 4")
        }
        let flags = fcntl(descriptor, F_GETFL)
        let mode = flags & O_ACCMODE
        guard flags >= 0, reading ? mode != O_WRONLY : mode != O_RDONLY else {
            throw ControlError.invalid("Inherited control pipes have incorrect access directions")
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    private nonisolated static func monotonicSeconds() -> Double {
        var value = timespec()
        clock_gettime(CLOCK_MONOTONIC, &value)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }

    /// Both fixtures are populated in memory. The external collector may
    /// precreate this unique UUID directory, but never supplies legacy files.
    private nonisolated static func validatePreparedDirectory(
        _ directory: URL, history: URL
    ) throws {
        let manager = FileManager.default
        for url in [directory, history] {
            guard
                url.resolvingSymlinksInPath().standardizedFileURL.path
                    == url.standardizedFileURL.path
            else {
                throw ControlError.invalid("Performance fixture paths must not contain symlinks")
            }
            if manager.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw ControlError.invalid("Performance fixture paths must be directories")
                }
            }
        }
        if manager.fileExists(atPath: directory.path) {
            let names = try manager.contentsOfDirectory(atPath: directory.path)
            guard Set(names).isSubset(of: ["History"]) else {
                throw ControlError.invalid("Performance run directory contains unrelated files")
            }
        }
        let names =
            manager.fileExists(atPath: history.path)
            ? Set(try manager.contentsOfDirectory(atPath: history.path)) : []
        guard names.isEmpty else {
            throw ControlError.invalid("Session-only performance history directories must be empty")
        }
    }

    private enum ControlError: Error {
        case invalid(String)
    }
}

/// Serialize main-actor replies and the independent GPU observer onto one pipe.
private final class PerformanceEventWriter: @unchecked Sendable {
    private let lock = NSLock()

    func send(_ object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object), body.count <= 32768
        else { return }
        let data = body + Data([10])
        lock.lock()
        defer { lock.unlock() }
        data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = Darwin.write(4, base.advanced(by: sent), data.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}

/// Self task_info is required by macOS for this native process GPU counter.
/// Sampling stays independent of the main actor even while history is seeded.
/// The collector validates units/attribution using an automatic Metal workload;
/// this event alone makes no claim that a raw zero is a calibrated measurement.
private final class PerformanceGPUReporter: @unchecked Sendable {
    private let writer: PerformanceEventWriter
    private let queue = DispatchQueue(label: "FluxLLM performance GPU observer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let processID = getpid()
    fileprivate let birthTime: UInt64?

    init(writer: PerformanceEventWriter) {
        self.writer = writer
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &information, size) == size,
            information.pbi_pid == UInt32(bitPattern: getpid()),
            information.pbi_start_tvsec > 0,
            information.pbi_start_tvsec <= (UInt64.max - 999_999) / 1_000_000,
            information.pbi_start_tvusec < 1_000_000
        {
            birthTime = information.pbi_start_tvsec * 1_000_000 + information.pbi_start_tvusec
        } else {
            birthTime = nil
        }
    }

    func start() {
        queue.sync {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(25))
            timer.setEventHandler { [weak self] in self?.emit(final: false) }
            self.timer = timer
            timer.resume()
        }
    }

    func sample() {
        queue.sync { emit(final: false) }
    }

    func stopAndEmitFinal() {
        queue.sync {
            timer?.cancel()
            timer = nil
            emit(final: true)
        }
    }

    private func emit(final: Bool) {
        let sample = NativeProcessGPUCounter.read()
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        let timestamp =
            sample?.sampledAtMonotonicSeconds
            ?? Double(now.tv_sec) + Double(now.tv_nsec) / 1_000_000_000
        let reason: String?
        if birthTime == nil {
            reason = "The app's process birth identity could not be verified"
        } else if sample == nil {
            reason = "The native self GPU counter is unavailable"
        } else {
            reason = nil
        }
        writer.send([
            "type": "gpu_sample", "process_id": processID,
            "birth_time_us": birthTime as Any? ?? NSNull(),
            "monotonic_seconds": timestamp,
            "kernel_gpu_counter": sample?.rawTimeNanoseconds as Any? ?? NSNull(),
            "gpu_unavailable_reason": reason as Any? ?? NSNull(),
            "final": final,
        ])
    }
}
