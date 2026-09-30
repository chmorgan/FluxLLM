import CoreGraphics
import Darwin
import FluxLLM
import Foundation

nonisolated(unsafe) private var collectorInterrupted: sig_atomic_t = 0

@main
struct FluxLLMResourceCollector {
    @MainActor
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGINT) { _ in collectorInterrupted = 1 }
        signal(SIGTERM) { _ in collectorInterrupted = 1 }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--gpu-calibration-worker"] {
            exit(GPUResourceProvider.runCalibrationWorker())
        }
        if arguments == ["--gpu-protocol-self-test-worker"] {
            exit(GPUResourceProvider.runProtocolSelfTestWorker())
        }
        do {
            if arguments == ["--preflight"] {
                try await preflight()
            } else if arguments == ["--self-test"] {
                try selfTest()
            } else if arguments.first == "--terminate-owned" {
                try terminateOwned(arguments)
            } else {
                var executable: String?
                var deadline = 300.0
                var index = 0
                while index < arguments.count {
                    guard index + 1 < arguments.count else { throw usageError() }
                    switch arguments[index] {
                    case "--app": executable = arguments[index + 1]
                    case "--deadline":
                        guard let seconds = Double(arguments[index + 1]), seconds.isFinite,
                            seconds >= 1, seconds <= 300
                        else { throw usageError() }
                        deadline = seconds
                    default: throw usageError()
                    }
                    index += 2
                }
                guard let executable, executable.hasPrefix("/"),
                    FileManager.default.isExecutableFile(atPath: executable)
                else { throw usageError() }
                let run = ApplicationMeasurement(executable: executable, deadlineSeconds: deadline)
                try await run.execute()
            }
        } catch {
            try? emit(["type": "error", "message": String(describing: error)])
            exit(2)
        }
    }

    private static func usageError() -> CollectorFailure {
        .message(
            "Usage: FluxLLMResourceCollector --preflight | --self-test | --app /absolute/FluxLLMApp [--deadline 300] | --terminate-owned PID --birth-time-us MICROSECONDS"
        )
    }

    private static func terminateOwned(_ arguments: [String]) throws {
        guard arguments.count == 4, arguments[0] == "--terminate-owned",
            arguments[2] == "--birth-time-us",
            let pid = Int32(arguments[1]), pid > 1, let birth = UInt64(arguments[3]), birth > 0
        else {
            throw usageError()
        }
        if kill(pid, 0) == -1, errno == ESRCH {
            try emit(["type": "terminated_owned", "pid": pid, "already_exited": true])
            return
        }
        guard try ProcessResources.birthTime(of: pid) == birth, getpgid(pid) == pid else {
            throw CollectorFailure.message(
                "Refusing cleanup because process birth identity or owned process group does not match"
            )
        }
        guard kill(-pid, SIGKILL) == 0 || errno == ESRCH else {
            throw CollectorFailure.message("Owned process cleanup failed (errno \(errno))")
        }
        try emit(["type": "terminated_owned", "pid": pid, "already_exited": false])
    }

    @MainActor
    private static func preflight() async throws {
        let started = ProcessResources.monotonicSeconds()
        try emit(["type": "preflight_progress", "stage": "cpu_calibration"])
        let cpu = try ProcessResources.calibrateCPU()
        let usage = try ProcessResources.readUsage(getpid())
        try emit(["type": "preflight_progress", "stage": "gpu_calibration"])
        let gpu = await GPUResourceProvider.preflight(deadlineSeconds: 12)
        try emit(["type": "preflight_progress", "stage": "filesystem_trace"])
        let tracer = FileIOTracer(targetPID: nil, runID: nil, storageRoot: nil)
        let trace = await tracer.start()
        await tracer.stop()
        let environment = collectorEnvironment(gpuMethod: gpu.provider)
        let displayAvailable = environment["display_available"] == "true"
        let physical: [String: Any] = [
            "available": usage.ri_phys_footprint > 0,
            "reason": usage.ri_phys_footprint > 0
                ? NSNull() : "Kernel physical footprint is unavailable" as Any,
        ]
        let result: [String: Any] = [
            "type": "capabilities", "protocol_version": 1,
            "cpu": cpu, "physical_footprint": physical,
            "physical_writes": ["available": true, "reason": NSNull()],
            "logical_writes": ["available": true, "reason": NSNull()],
            "gpu": try object(gpu), "trace_coverage": try object(trace),
            "display": [
                "available": displayAvailable,
                "reason": displayAvailable
                    ? NSNull() : (environment["display"] ?? "unavailable") as Any,
            ],
            "environment": environment,
            "elapsed_seconds": ProcessResources.monotonicSeconds() - started,
        ]
        try emit(result)
        try emit(["type": "calibration", "cpu": cpu, "gpu": try object(gpu)])
    }

    private static func selfTest() throws {
        let fractional = ProcessResources.cpuSeconds(
            userTicks: 24_000_000, systemTicks: 24_000_000,
            numer: 125, denom: 3)
        guard abs(fractional - 2) < 0.000_000_001 else {
            throw CollectorFailure.message("Mach time conversion self-test failed")
        }
        let parallel = ProcessResources.cpuSeconds(
            userTicks: 2_000_000_000, systemTicks: 2_000_000_000,
            numer: 1, denom: 1)
        guard parallel == 4 else {
            throw CollectorFailure.message("CPU conversion lost parallel-thread time")
        }
        let calibration = try ProcessResources.calibrateCPU()
        guard calibration["available"] as? Bool == true else {
            throw CollectorFailure.message("CPU self-calibration failed")
        }
        try GPUResourceProvider.verifyControlPipe()
        try emit(["type": "self_test", "passed": true, "cpu": calibration, "short_line_pipe": true])
    }
}

@MainActor
private final class ApplicationMeasurement {
    private let executable: String
    private let deadlineSeconds: Double
    private var child: ControlledProcess?
    private var probe: ProcessResources?
    private var tracer: FileIOTracer?
    private var gpu: GPUResourceProvider?
    private var latestGPU: GPUResourceReading?
    private var lastGPURead = -Double.infinity
    private var nativeGPUEnabled = false
    private var nativeGPUCounter: UInt64 = 0
    private var nativeGPUFailure: String?
    private var nativeGPUFinal = false
    private var lastGPUReported = -Double.infinity
    private var commandBuffer = Data()
    private var eventBuffer = Data()

    init(executable: String, deadlineSeconds: Double) {
        self.executable = executable
        self.deadlineSeconds = deadlineSeconds
    }

    func execute() async throws {
        let deadline = ProcessResources.monotonicSeconds() + deadlineSeconds
        var environment = ProcessInfo.processInfo.environment
        guard let configuration = environment["FLUXLLM_PERFORMANCE_CONFIGURATION"],
            let configBytes = configuration.data(using: .utf8), configBytes.count <= 65_536,
            (try? JSONSerialization.jsonObject(with: configBytes)) is [String: Any]
        else {
            throw CollectorFailure.message(
                "FLUXLLM_PERFORMANCE_CONFIGURATION must contain a bounded JSON object")
        }
        let suppliedRunID = environment["FLUXLLM_PERFORMANCE_RUN_ID"] ?? UUID().uuidString
        guard let parsedRunID = UUID(uuidString: suppliedRunID) else {
            throw CollectorFailure.message("Invalid performance run ID")
        }
        let runID = parsedRunID.uuidString
        environment["FLUXLLM_PERFORMANCE_RUN_ID"] = runID
        let storageRoot =
            environment["FLUXLLM_PERFORMANCE_STORAGE_ROOT"]
            ?? FileManager.default.temporaryDirectory.path
        environment["FLUXLLM_PERFORMANCE_STORAGE_ROOT"] = storageRoot
        let process = try ControlledProcess(executable: executable, environment: environment)
        child = process
        defer { process.terminate() }
        let probe = try ProcessResources(processID: process.pid)
        self.probe = probe
        let capability = environment["FLUXLLM_PERFORMANCE_GPU_CAPABILITY_JSON"]
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(GPUCapabilityReport.self, from: $0) }
        nativeGPUEnabled =
            capability?.available == true
            && capability?.provider == GPUResourceProvider.kernelProvider
            && capability?.calibration != nil
        gpu = GPUResourceProvider(target: probe.gpuIdentity, capability: capability)
        let tracer = FileIOTracer(targetPID: process.pid, runID: runID, storageRoot: storageRoot)
        self.tracer = tracer
        do {
            // Publish the owned PID before any capability wait so the runner can
            // clean it up even if this observer is forcibly terminated at startup.
            try emit([
                "type": "launched", "pid": process.pid,
                "birth_time_us": probe.birthTimeMicroseconds,
                "run_id": runID, "storage_root": storageRoot,
                "environment": collectorEnvironment(
                    gpuMethod: capability?.provider ?? GPUResourceProvider.provider),
            ])
            _ = await tracer.start()
            let stdinFlags = fcntl(STDIN_FILENO, F_GETFL)
            guard stdinFlags >= 0, fcntl(STDIN_FILENO, F_SETFL, stdinFlags | O_NONBLOCK) == 0 else {
                throw CollectorFailure.message("Cannot configure runner command input")
            }
            defer { _ = fcntl(STDIN_FILENO, F_SETFL, stdinFlags) }
            try await sample(phase: "baseline")
            try process.resume()
            try writeAll(
                jsonLine([
                    "command": "handshake", "command_id": "collector-handshake",
                    "protocol_version": 1,
                ]), to: process.commandDescriptor)
            var nextSample = ProcessResources.monotonicSeconds() + 0.25
            while true {
                guard collectorInterrupted == 0 else {
                    throw CollectorFailure.message("Resource collection was interrupted")
                }
                guard ProcessResources.monotonicSeconds() < deadline else {
                    throw CollectorFailure.message(
                        "Resource collection exceeded its fixed deadline")
                }
                try await drainCommands()
                try await drainAppEvents()
                try drainDiagnostics()
                try drainTrace()
                if try process.hasExited() {
                    let exitedAt = ProcessResources.monotonicSeconds()
                    try await drainAppEvents(permitBoundarySample: false)
                    // The zombie still owns its final resource accounting. Read
                    // it before wait4, which would permanently discard it.
                    let final = try await sample(phase: "final", permitZombie: true)
                    let result = try process.reap()
                    try await drainAppEvents(permitBoundarySample: false)
                    try drainDiagnostics()
                    let drainDeadline = min(deadline, ProcessResources.monotonicSeconds() + 1)
                    while ProcessResources.monotonicSeconds() < drainDeadline {
                        try drainTrace()
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    await tracer.stop()
                    try drainTrace()
                    try emit([
                        "type": "exited", "status": result.status,
                        "wait4_cpu_seconds": result.cpuSeconds,
                        "final_sample": final,
                        "gpu_final_self_sample_received": nativeGPUFinal,
                        "gpu_exit_gap_seconds": lastGPURead.isFinite
                            ? max(0, exitedAt - lastGPURead) as Any : NSNull(),
                        "gpu_exit_tail_measured": false,
                        "trace_coverage": tracer.capability.available,
                        "trace_timestamp_attribution": tracer.capability.timestamp_attribution,
                        "trace_timestamp_unavailable_reason": tracer.capability
                            .timestamp_unavailable_reason as Any? ?? NSNull(),
                        "trace_unavailable_reason": tracer.capability.reason as Any? ?? NSNull(),
                    ])
                    return
                }
                let now = ProcessResources.monotonicSeconds()
                if now >= nextSample {
                    try await sample(phase: "periodic")
                    nextSample = ProcessResources.monotonicSeconds() + 0.25
                }
                var descriptors = [
                    pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: process.eventDescriptor, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: process.stdoutDescriptor, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: process.stderrDescriptor, events: Int16(POLLIN), revents: 0),
                ]
                let wait = Int32(
                    max(1, min(100, (nextSample - ProcessResources.monotonicSeconds()) * 1000)))
                _ = poll(&descriptors, nfds_t(descriptors.count), wait)
            }
        } catch {
            process.terminate()
            await tracer.stop()
            throw error
        }
    }

    @discardableResult
    private func sample(phase: String, commandID: Any? = nil, permitZombie: Bool = false)
        async throws -> [String: Any]
    {
        guard let probe else { throw CollectorFailure.message("Process probe is not initialized") }
        let now = ProcessResources.monotonicSeconds()
        var gpuSampled = false
        if nativeGPUEnabled, phase == "baseline" {
            // The child is still stopped before its first user-space instruction.
            // A calibrated lifetime task counter therefore has an exact zero origin.
            lastGPURead = now
            latestGPU = GPUResourceReading(
                gpu_seconds: 0, gpu_unavailable_reason: nil,
                gpu_provider: GPUResourceProvider.kernelProvider, gpu_interval_seconds: nil,
                gpu_interval_execution_seconds: nil)
        } else if nativeGPUEnabled {
            gpuSampled = lastGPURead > lastGPUReported
            if now - lastGPURead > 1.5, nativeGPUFailure == nil {
                nativeGPUFailure =
                    "The application's independent GPU counter stream missed its maximum interval"
            }
        } else if !permitZombie, let gpu, now - lastGPURead >= 1 {
            latestGPU = await gpu.sample()
            lastGPURead = ProcessResources.monotonicSeconds()
            gpuSampled = true
        }
        var result = try probe.snapshot(phase: phase, permitZombie: permitZombie)
        if let latestGPU {
            result.merge(try object(latestGPU)) { _, new in new }
        }
        if let nativeGPUFailure {
            result["gpu_seconds"] = NSNull()
            result["gpu_unavailable_reason"] = nativeGPUFailure
        }
        if result["gpu_seconds"] == nil { result["gpu_seconds"] = NSNull() }
        if result["gpu_unavailable_reason"] == nil {
            result["gpu_unavailable_reason"] =
                latestGPU?.gpu_seconds == nil
                ? "GPU counters have not produced a valid interval" : NSNull() as Any
        }
        result["gpu_sampled"] = gpuSampled
        result["gpu_sample_monotonic_seconds"] =
            lastGPURead.isFinite ? lastGPURead as Any : NSNull()
        result["gpu_final_self_sample"] = nativeGPUFinal
        if nativeGPUEnabled {
            result["kernel_gpu_counter"] = nativeGPUCounter
            result["gpu_coverage_end_monotonic_seconds"] = lastGPURead
        }
        lastGPUReported = lastGPURead
        result["trace_coverage"] = tracer?.capability.available ?? false
        result["trace_unavailable_reason"] = tracer?.capability.reason as Any? ?? NSNull()
        result["trace_timestamp_attribution"] = tracer?.capability.timestamp_attribution ?? false
        result["trace_timestamp_unavailable_reason"] =
            tracer?.capability.timestamp_unavailable_reason as Any? ?? NSNull()
        if let commandID { result["command_id"] = commandID }
        try emit(result)
        return result
    }

    private func drainCommands() async throws {
        guard let child else { return }
        commandBuffer.append(try readAvailable(STDIN_FILENO))
        guard commandBuffer.count <= 1_048_576 else {
            throw CollectorFailure.message("Runner command line is too large")
        }
        while let newline = commandBuffer.firstIndex(of: 10) {
            let line = Data(commandBuffer[..<newline])
            commandBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                let command = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                let identifier = command["command_id"] as? String, !identifier.isEmpty
            else {
                throw CollectorFailure.message(
                    "Runner commands require a JSON object and command_id")
            }
            try await sample(phase: "control_boundary", commandID: identifier)
            var forwarded = line
            forwarded.append(10)
            try writeAll(forwarded, to: child.commandDescriptor)
        }
    }

    private func drainAppEvents(permitBoundarySample: Bool = true) async throws {
        guard let child else { return }
        eventBuffer.append(try readAvailable(child.eventDescriptor))
        guard eventBuffer.count <= 1_048_576 else {
            throw CollectorFailure.message("App event line is too large")
        }
        while let newline = eventBuffer.firstIndex(of: 10) {
            let line = Data(eventBuffer[..<newline])
            eventBuffer.removeSubrange(...newline)
            guard let event = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CollectorFailure.message("App control emitted invalid JSON")
            }
            if event["type"] as? String == "gpu_sample" { ingestNativeGPU(event) }
            if permitBoundarySample, let identifier = event["command_id"] {
                try await sample(phase: "control_boundary", commandID: identifier)
            }
            try emit([
                "type": "app_event", "event": event,
                "monotonic_seconds": ProcessResources.monotonicSeconds(),
            ])
        }
    }

    private func ingestNativeGPU(_ event: [String: Any]) {
        guard nativeGPUEnabled, let probe else { return }
        if let reason = event["gpu_unavailable_reason"] as? String {
            nativeGPUFailure = reason
            return
        }
        guard let pid = event["process_id"] as? NSNumber, pid.int32Value == probe.processID,
            let counter = event["kernel_gpu_counter"] as? NSNumber,
            CFGetTypeID(counter) != CFBooleanGetTypeID(), counter.doubleValue >= 0,
            let timestamp = event["monotonic_seconds"] as? Double, timestamp.isFinite,
            timestamp >= lastGPURead, timestamp <= ProcessResources.monotonicSeconds() + 0.01,
            counter.uint64Value >= nativeGPUCounter
        else {
            nativeGPUFailure =
                "The application emitted an invalid, reset, or misattributed native GPU counter"
            return
        }
        if let birth = event["birth_time_us"] as? NSNumber,
            birth.uint64Value != probe.birthTimeMicroseconds
        {
            nativeGPUFailure = "The native GPU process birth identity changed"
            return
        }
        let interval = timestamp - lastGPURead
        let execution = Double(counter.uint64Value - nativeGPUCounter) / 1_000_000_000
        if interval > 1.5 {
            nativeGPUFailure = "The native GPU stream contains a missing measurement interval"
        }
        nativeGPUCounter = counter.uint64Value
        lastGPURead = timestamp
        nativeGPUFinal = nativeGPUFinal || (event["final"] as? Bool == true)
        latestGPU = GPUResourceReading(
            gpu_seconds: Double(nativeGPUCounter) / 1_000_000_000,
            gpu_unavailable_reason: nil, gpu_provider: GPUResourceProvider.kernelProvider,
            gpu_interval_seconds: interval, gpu_interval_execution_seconds: execution)
    }

    private func drainDiagnostics() throws {
        guard let child else { return }
        for (stream, descriptor) in [
            ("stdout", child.stdoutDescriptor), ("stderr", child.stderrDescriptor),
        ] {
            let bytes = try readAvailable(descriptor)
            if !bytes.isEmpty {
                try emit([
                    "type": "diagnostic", "stream": stream,
                    "text": String(decoding: bytes, as: UTF8.self),
                ])
            }
        }
    }

    private func drainTrace() throws {
        for event in tracer?.drain() ?? [] { try emit(event) }
    }
}

func object<T: Encodable>(_ value: T) throws -> [String: Any] {
    guard
        let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            as? [String: Any]
    else {
        throw CollectorFailure.message("Collector report value was not an object")
    }
    return result
}

func emit(_ value: [String: Any]) throws {
    try writeAll(jsonLine(value), to: STDOUT_FILENO)
}

private func collectorEnvironment(gpuMethod: String) -> [String: String] {
    var size = 0
    _ = sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: max(1, size))
    _ = sysctlbyname("hw.model", &model, &size, nil, 0)
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    let status = CGGetActiveDisplayList(UInt32(displays.count), &displays, &count)
    let displayAvailable = status == .success && count > 0
    let display =
        displayAvailable
        ? displays.prefix(Int(count)).map {
            "\(CGDisplayPixelsWide($0))x\(CGDisplayPixelsHigh($0))"
        }.joined(separator: ",")
        : "unavailable: CoreGraphics active-display status=\(status.rawValue), count=\(count)"
    #if DEBUG
        let configuration = "debug"
    #else
        let configuration = "release"
    #endif
    return [
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "hardware": String(
            decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
        "build_configuration": configuration,
        "display": display, "display_available": displayAvailable ? "true" : "false",
        "gpu_method": gpuMethod,
    ]
}
