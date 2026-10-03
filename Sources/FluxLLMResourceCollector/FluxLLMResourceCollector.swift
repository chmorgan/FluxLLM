import CoreGraphics
import Darwin
import FluxLLM
import Foundation

nonisolated(unsafe) private var collectorInterrupted: sig_atomic_t = 0

/// The runner owns one Instruments recording spanning calibration and every
/// application lifetime. GPU capability remains deferred until it exports and
/// validates that recording. Filesystem tracing is validated independently.
private enum ExternalTrace {
    static let enabled =
        ProcessInfo.processInfo.environment["FLUXLLM_PERFORMANCE_EXTERNAL_TRACE"] == "1"
    static let provider = "Instruments Metal System Trace (external session)"
    static let reason = "Awaiting validation of the runner-owned Instruments recording"
}

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
        if arguments == ["--resource-exit-self-test-worker"] {
            exit(runResourceExitSelfTestWorker())
        }
        if arguments == ["--thread-cpu-calibration-worker"] {
            exit(ThreadCPUCalibration.runWorker())
        }
        do {
            if arguments == ["--preflight"] {
                try await preflight()
            } else if arguments == ["--self-test"] {
                try selfTest()
            } else if arguments == ["--thread-cpu-self-test"] {
                try ThreadCPUCalibration.verifyRegistrationAndConversion()
                let calibration = try ThreadCPUCalibration.run()
                try emit([
                    "type": "thread_cpu_self_test", "passed": true,
                    "registration_and_conversion": true, "calibration": calibration.evidence,
                ])
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
            "Usage: FluxLLMResourceCollector --preflight | --self-test | --thread-cpu-self-test | --app /absolute/FluxLLMApp [--deadline 300] | --terminate-owned PID --birth-time-us MICROSECONDS"
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
        let gpu: [String: Any]
        let gpuMethod: String
        if ExternalTrace.enabled {
            gpuMethod = ExternalTrace.provider
            gpu = [
                "available": false, "live_counter_available": false,
                "full_lifetime_coverage": false, "external_trace": true,
                "provider": gpuMethod, "reason": ExternalTrace.reason,
                "full_lifetime_unavailable_code": "external_trace_pending",
                "full_lifetime_unavailable_reason": ExternalTrace.reason,
            ]
        } else {
            try emit(["type": "preflight_progress", "stage": "gpu_calibration"])
            let capability = await GPUResourceProvider.preflight(deadlineSeconds: 12)
            gpu = try object(capability)
            gpuMethod = capability.provider
        }
        try emit(["type": "preflight_progress", "stage": "filesystem_trace"])
        let tracer = FileIOTracer(targetPID: nil, runID: nil, storageRoot: nil)
        _ = await tracer.start()
        await tracer.stop()
        let trace = tracer.capability
        let environment = collectorEnvironment(gpuMethod: gpuMethod)
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
            "gpu": gpu, "trace_coverage": try object(trace),
            "external_trace": ExternalTrace.enabled,
            "display": [
                "available": displayAvailable,
                "reason": displayAvailable
                    ? NSNull() : (environment["display"] ?? "unavailable") as Any,
            ],
            "environment": environment,
            "elapsed_seconds": ProcessResources.monotonicSeconds() - started,
        ]
        try emit(result)
        try emit(["type": "calibration", "cpu": cpu, "gpu": gpu])
    }

    @MainActor
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
        try verifyCPUWorkCounterExports()
        let calibration = try ProcessResources.calibrateCPU()
        guard calibration["available"] as? Bool == true else {
            throw CollectorFailure.message("CPU self-calibration failed")
        }
        let clockSample = try ProcessResources(processID: getpid()).snapshot(phase: "self_test")
        guard let ticks = clockSample["mach_absolute_ticks"] as? UInt64, ticks > 0,
            let seconds = clockSample["mach_absolute_seconds"] as? Double, seconds > 0,
            let uncertainty = clockSample["clock_read_uncertainty_seconds"] as? Double,
            uncertainty >= 0, uncertainty < 0.01
        else {
            throw CollectorFailure.message("Mach/monotonic clock pairing self-test failed")
        }
        guard clockSample["cpu_work_counters"] as? [String: Any] != nil else {
            throw CollectorFailure.message("Resource snapshot omitted raw CPU work counters")
        }
        try GPUResourceProvider.verifyControlPipe()
        try GPUCapabilityReport.verifyCoverageReporting()
        try FileIOTracer.verifyClosingProofValidation()
        try verifyOwnedExitSampling()
        let finalEvent: [String: Any] = [
            "type": "gpu_sample", "final": true, "process_id": 42,
            "birth_time_us": 123, "monotonic_seconds": 5.0,
            "kernel_gpu_counter": 0,
        ]
        guard
            validatedNativeGPUFinalTimestamp(finalEvent, processID: 42, birthTime: 123, now: 5.1)
                == 5,
            validatedNativeGPUFinalTimestamp(finalEvent, processID: 43, birthTime: 123, now: 5.1)
                == nil,
            validatedNativeGPUFinalTimestamp(finalEvent, processID: 42, birthTime: 124, now: 5.1)
                == nil,
            validatedNativeGPUFinalTimestamp(finalEvent, processID: 42, birthTime: 123, now: 4)
                == nil
        else {
            throw CollectorFailure.message("Final GPU receipt identity/timestamp self-test failed")
        }
        try emit([
            "type": "self_test", "passed": true, "cpu": calibration, "short_line_pipe": true,
            "raw_gpu_final_receipt": true, "gpu_lifetime_capability_reporting": true,
            "paired_mach_monotonic_clocks": true, "closing_filesystem_proof": true,
            "cpu_work_counter_mapping": true,
            "owned_exit_resource_sampling": true, "bounded_exit_transition_recovery": true,
        ])
    }

    private static func verifyCPUWorkCounterExports() throws {
        let large: UInt64 = 9_007_199_254_740_993  // Double would round this integer.
        var usage = rusage_info_v4()
        usage.ri_instructions = large
        usage.ri_cycles = large + 2
        usage.ri_cpu_time_qos_default = large + 4
        usage.ri_cpu_time_qos_maintenance = large + 6
        usage.ri_cpu_time_qos_background = large + 8
        usage.ri_cpu_time_qos_utility = large + 10
        usage.ri_cpu_time_qos_legacy = large + 12
        usage.ri_cpu_time_qos_user_initiated = large + 14
        usage.ri_cpu_time_qos_user_interactive = large + 16
        let expectedQoS: [String: UInt64] = [
            "default": large + 4, "maintenance": large + 6, "background": large + 8,
            "utility": large + 10, "legacy": large + 12,
            "user_initiated": large + 14, "user_interactive": large + 16,
        ]
        let exported = ProcessResources.cpuWorkCounters(usage)
        guard
            Set(exported.keys)
                == Set([
                    "schema_version", "source", "instructions", "cycles",
                    "instructions_unit", "cycles_unit", "qos_time_unit", "qos_time_raw",
                ]),
            exported["schema_version"] as? Int == 1,
            exported["source"] as? String == "proc_pid_rusage/RUSAGE_INFO_V4",
            exported["instructions_unit"] as? String == "count",
            exported["cycles_unit"] as? String == "count",
            exported["qos_time_unit"] as? String == "unspecified_kernel_units",
            exported["instructions"] as? UInt64 == large,
            exported["cycles"] as? UInt64 == large + 2,
            exported["qos_time_raw"] as? [String: UInt64] == expectedQoS
        else {
            throw CollectorFailure.message("Raw CPU work counter mapping or units self-test failed")
        }
        let encoded = try jsonLine(exported)
        guard let text = String(data: encoded, encoding: .utf8),
            text.contains("\"instructions\":\(large)"), text.contains("\"cycles\":\(large + 2)"),
            expectedQoS.allSatisfy({ text.contains("\"\($0.key)\":\($0.value)") }),
            let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
            (decoded["instructions"] as? NSNumber)?.uint64Value == large,
            (decoded["cycles"] as? NSNumber)?.uint64Value == large + 2
        else {
            throw CollectorFailure.message("CPU work counter JSON lost integer precision")
        }
        let zeroUsage = rusage_info_v4()
        let zero = ProcessResources.cpuWorkCounters(zeroUsage)
        let zeroObservation = ProcessResources.cpuWorkCounterObservation(
            before: zeroUsage, after: zeroUsage)
        guard zero["instructions"] as? UInt64 == 0, zero["cycles"] as? UInt64 == 0,
            zero["qos_time_raw"] as? [String: UInt64] == expectedQoS.mapValues({ _ in UInt64(0) }),
            zeroObservation["monotonic"] as? Bool == true,
            zeroObservation["observed_positive"] as? Bool == false,
            zeroObservation["instructions_delta"] as? UInt64 == 0,
            zeroObservation["cycles_delta"] as? UInt64 == 0
        else {
            throw CollectorFailure.message(
                "Zero CPU work counters were not preserved as unqualified observations")
        }
        var after = usage
        after.ri_instructions += 37
        after.ri_cycles += 91
        let observation = ProcessResources.cpuWorkCounterObservation(before: usage, after: after)
        guard observation["monotonic"] as? Bool == true,
            observation["observed_positive"] as? Bool == true,
            observation["instructions_delta"] as? UInt64 == 37,
            observation["cycles_delta"] as? UInt64 == 91
        else {
            throw CollectorFailure.message("CPU work counter observation delta self-test failed")
        }
        var fewerInstructions = usage
        fewerInstructions.ri_instructions -= 1
        var fewerCycles = usage
        fewerCycles.ri_cycles -= 1
        for regressed in [fewerInstructions, fewerCycles] {
            let invalid = ProcessResources.cpuWorkCounterObservation(
                before: usage, after: regressed)
            guard invalid["monotonic"] as? Bool == false,
                invalid["observed_positive"] as? Bool == false,
                invalid["instructions_delta"] is NSNull, invalid["cycles_delta"] is NSNull
            else {
                throw CollectorFailure.message(
                    "Regressing CPU work counters produced usable deltas")
            }
        }
    }

    private static func runResourceExitSelfTestWorker() -> Int32 {
        let count = 8 * 1_024 * 1_024
        guard let allocation = malloc(count) else { return 2 }
        defer { free(allocation) }
        // An observable libc call prevents Release dead-store elimination of
        // the temporary allocation used to exercise lifetime peak accounting.
        arc4random_buf(allocation, count)
        do {
            let probe = try ProcessResources(processID: getpid())
            let usage = try ProcessResources.readUsage(getpid())
            try writeAll(
                jsonLine([
                    "type": "stopped", "command_id": "exit-race", "status": "ok",
                    "process_id": getpid(), "birth_time_us": probe.birthTimeMicroseconds,
                    "observed_peak_bytes": usage.ri_lifetime_max_phys_footprint,
                ]), to: 4)
            return 0
        } catch { return 2 }
    }

    /// Exercise the real kernel/zombie state and a buffered authenticated pipe,
    /// rather than relying on timing-sensitive repetitions of a fast shutdown.
    private static func verifyOwnedExitSampling() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let child = try ControlledProcess(
            executable: executable, environment: ProcessInfo.processInfo.environment,
            arguments: ["--resource-exit-self-test-worker"])
        defer { child.terminate() }
        let probe = try ProcessResources(processID: child.pid)
        let missing = CollectorFailure.processLookup(
            pid: child.pid, operation: .birthTime, errorCode: ESRCH)
        func requireRejection(
            _ error: CollectorFailure, phase: String, deadline: Double = .infinity,
            observation: ExitTransitionObservation = ExitTransitionObservation()
        ) throws {
            do {
                _ = try probe.recoverSnapshotAfterExit(
                    error, phase: "control_boundary", ownedChild: child,
                    deadline: deadline, observation: observation)
            } catch let actual {
                guard String(describing: actual) == String(describing: error) else {
                    throw CollectorFailure.message(
                        "Exit-race recovery replaced an unrelated process failure during \(phase)")
                }
                return
            }
            throw CollectorFailure.message(
                "Exit-race recovery accepted an unrelated process failure during \(phase)")
        }
        func requireImmediateRejection(_ error: CollectorFailure, phase: String) throws {
            var callbacks = 0
            let observation = ExitTransitionObservation(
                clock: {
                    callbacks += 1
                    return 0
                },
                pause: { _ in callbacks += 1 },
                hasExited: { _ in
                    callbacks += 1
                    return true
                })
            try requireRejection(error, phase: phase, deadline: 0, observation: observation)
            guard callbacks == 0 else {
                throw CollectorFailure.message(
                    "Ineligible exit recovery invoked observation callbacks during \(phase)")
            }
        }
        // Fake time makes the uncovered ordering and all timeout edges
        // deterministic. The real owned child remains suspended throughout.
        for (phase, deadline, reportsExit, expectedWait) in [
            ("persistent not-exited", Double.infinity, false, 0.1),
            ("clipped collector deadline", 0.0025, false, 0.0025),
            ("expired collector deadline", 0.0, false, 0.0),
            ("false exit observation for live child", Double.infinity, true, 0.0),
        ] {
            var clock = 0.0
            var waits: [Double] = []
            var observations = 0
            let scripted = ExitTransitionObservation(
                clock: { clock },
                pause: { interval in
                    waits.append(interval)
                    clock += interval
                },
                hasExited: { _ in
                    observations += 1
                    return reportsExit
                })
            try requireRejection(missing, phase: phase, deadline: deadline, observation: scripted)
            guard abs(clock - expectedWait) < 0.000_000_001,
                waits.allSatisfy({ $0 > 0 && $0 <= 0.001 }),
                expectedWait > 0 ? !waits.isEmpty : waits.isEmpty,
                deadline > 0 ? observations > 0 : observations == 0
            else {
                throw CollectorFailure.message(
                    "Exit-transition recovery violated its fixed polling bound during \(phase)")
            }
        }
        let observationFailure = CollectorFailure.message("scripted exit observation failure")
        do {
            _ = try probe.recoverSnapshotAfterExit(
                missing, phase: "control_boundary", ownedChild: child,
                observation: ExitTransitionObservation(
                    clock: { 0 }, pause: { _ in },
                    hasExited: { _ in throw observationFailure }))
            throw CollectorFailure.message("Exit recovery swallowed an observation error")
        } catch {
            guard String(describing: error) == String(describing: observationFailure) else {
                throw error
            }
        }
        try child.resume()
        let deadline = ProcessResources.monotonicSeconds() + 3
        while !(try child.hasExited()), ProcessResources.monotonicSeconds() < deadline {
            usleep(1_000)
        }
        guard try child.hasExited() else {
            throw CollectorFailure.message("Exit-race worker did not exit within its deadline")
        }

        let buffered = try readAvailable(child.eventDescriptor)
        guard buffered.last == 10,
            let event = try JSONSerialization.jsonObject(with: Data(buffered.dropLast()))
                as? [String: Any],
            event["type"] as? String == "stopped", event["command_id"] as? String == "exit-race",
            (event["process_id"] as? NSNumber)?.int32Value == child.pid,
            (event["birth_time_us"] as? NSNumber)?.uint64Value == probe.birthTimeMicroseconds,
            let observedPeak = (event["observed_peak_bytes"] as? NSNumber)?.uint64Value,
            observedPeak >= 8 * 1_024 * 1_024
        else {
            throw CollectorFailure.message(
                "Exit-race worker did not preserve its authenticated buffered stop event: \(String(decoding: buffered.prefix(1_024), as: UTF8.self))"
            )
        }
        let boundary = try probe.snapshot(phase: "control_boundary", ownedChild: child)
        let recovered = try probe.recoverSnapshotAfterExit(
            missing, phase: "periodic", ownedChild: child)
        var transitionClock = 0.0
        var transitionObservations = 0
        var transitionWaits: [Double] = []
        let transitioned = try probe.recoverSnapshotAfterExit(
            missing, phase: "control_boundary", ownedChild: child,
            deadline: 1,
            observation: ExitTransitionObservation(
                clock: { transitionClock },
                pause: { interval in
                    transitionWaits.append(interval)
                    transitionClock += interval
                },
                hasExited: { _ in
                    transitionObservations += 1
                    return transitionObservations == 3
                }))
        guard transitionObservations == 3, transitionWaits == [0.001, 0.001],
            let recovery = transitioned["exit_identity_recovery"] as? [String: Any],
            recovery["observations"] as? Int == 3,
            recovery["wait_seconds"] as? Double == 0.002
        else {
            throw CollectorFailure.message(
                "Scripted not-exited/not-exited/exited recovery did not preserve its ordering")
        }
        let final = try probe.snapshot(phase: "final", ownedChild: child, permitZombie: true)
        let kernel = try ProcessResources.readUsage(child.pid)
        for sample in [boundary, recovered, transitioned, final] {
            guard (sample["birth_time_us"] as? UInt64) == probe.birthTimeMicroseconds,
                (sample["lifetime_peak_footprint_bytes"] as? UInt64)
                    == kernel.ri_lifetime_max_phys_footprint,
                (sample["user_cpu_ticks"] as? UInt64) == kernel.ri_user_time,
                (sample["system_cpu_ticks"] as? UInt64) == kernel.ri_system_time,
                kernel.ri_lifetime_max_phys_footprint >= observedPeak
            else {
                throw CollectorFailure.message(
                    "Exit-race sampling did not retain genuine final kernel counters")
            }
        }
        try requireImmediateRejection(
            .processLookup(pid: child.pid, operation: .birthTime, errorCode: EPERM),
            phase: "permission error")
        try requireImmediateRejection(
            .processLookup(pid: getpid(), operation: .birthTime, errorCode: ESRCH),
            phase: "unrelated PID")
        try requireImmediateRejection(
            .message("The measured process identity changed"), phase: "identity mismatch")
        guard try child.reap().status == 0 else {
            throw CollectorFailure.message("Exit-race worker failed")
        }
        try requireImmediateRejection(missing, phase: "reaped child")
    }
}

@MainActor
private final class ApplicationMeasurement {
    private let executable: String
    private let deadlineSeconds: Double
    private var samplingDeadline = -Double.infinity
    private var child: ControlledProcess?
    private var probe: ProcessResources?
    private var threadCPU: ThreadCPUResources?
    private var tracer: FileIOTracer?
    private var gpu: GPUResourceProvider?
    private var latestGPU: GPUResourceReading?
    private var lastGPURead = -Double.infinity
    private var nativeGPUEnabled = false
    private var nativeGPUCounter: UInt64 = 0
    private var nativeGPUFailure: String?
    private var nativeGPUFinal = false
    /// Receipt is a protocol fact. It does not establish a usable GPU counter.
    private var nativeGPUFinalReceivedAt: Double?
    private var lastGPUReported = -Double.infinity
    private var commandBuffer = Data()
    private var eventBuffer = Data()
    private var traceCapability: TraceCapability {
        tracer?.capability
            ?? TraceCapability(available: false, reason: "Filesystem tracing has not started")
    }

    init(executable: String, deadlineSeconds: Double) {
        self.executable = executable
        self.deadlineSeconds = deadlineSeconds
    }

    func execute() async throws {
        let deadline = ProcessResources.monotonicSeconds() + deadlineSeconds
        samplingDeadline = deadline
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
        let threadCalibration =
            environment["FLUXLLM_PERF_THREAD_CPU"] == "1"
            ? try ThreadCPUCalibration.run(
                deadlineSeconds: max(0, deadline - ProcessResources.monotonicSeconds())) : nil
        if let threadCalibration {
            try emit(["type": "thread_cpu_calibration", "calibration": threadCalibration.evidence])
        }
        let process = try ControlledProcess(executable: executable, environment: environment)
        child = process
        defer { process.terminate() }
        let probe = try ProcessResources(processID: process.pid)
        self.probe = probe
        if let threadCalibration {
            threadCPU = ThreadCPUResources(probe: probe, calibration: threadCalibration)
        }
        let capability = environment["FLUXLLM_PERFORMANCE_GPU_CAPABILITY_JSON"]
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(GPUCapabilityReport.self, from: $0) }
        nativeGPUEnabled =
            !ExternalTrace.enabled && capability?.live_counter_available == true
            && capability?.provider == GPUResourceProvider.kernelProvider
            && capability?.calibration != nil
        if !ExternalTrace.enabled {
            gpu = GPUResourceProvider(target: probe.gpuIdentity, capability: capability)
        }
        tracer = FileIOTracer(targetPID: process.pid, runID: runID, storageRoot: storageRoot)
        do {
            // Publish the owned PID before any capability wait so the runner can
            // clean it up even if this observer is forcibly terminated at startup.
            try emit([
                "type": "launched", "pid": process.pid,
                "birth_time_us": probe.birthTimeMicroseconds,
                "run_id": runID, "storage_root": storageRoot,
                "external_trace": ExternalTrace.enabled,
                "environment": collectorEnvironment(
                    gpuMethod: ExternalTrace.enabled
                        ? ExternalTrace.provider
                        : capability?.provider ?? GPUResourceProvider.provider),
            ])
            _ = await tracer?.start()
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
                    await tracer?.stop()
                    try drainTrace()
                    try emit([
                        "type": "exited", "status": result.status,
                        "wait4_cpu_seconds": result.cpuSeconds,
                        "final_sample": final,
                        "gpu_final_self_sample_received": nativeGPUFinalReceivedAt != nil,
                        "gpu_final_self_sample_monotonic_seconds": nativeGPUFinalReceivedAt as Any?
                            ?? NSNull(),
                        "gpu_final_self_sample_calibrated": nativeGPUFinal,
                        "gpu_exit_gap_seconds": lastGPURead.isFinite
                            ? max(0, exitedAt - lastGPURead) as Any : NSNull(),
                        "gpu_exit_tail_measured": false,
                        "external_trace": ExternalTrace.enabled,
                        "trace_coverage": traceCapability.available,
                        "trace_timestamp_attribution": traceCapability.timestamp_attribution,
                        "trace_timestamp_unavailable_reason": traceCapability
                            .timestamp_unavailable_reason as Any? ?? NSNull(),
                        "trace_unavailable_reason": traceCapability.reason as Any? ?? NSNull(),
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
            await tracer?.stop()
            throw error
        }
    }

    @discardableResult
    private func sample(phase: String, commandID: Any? = nil, permitZombie: Bool = false)
        async throws -> [String: Any]
    {
        guard let probe, let child else {
            throw CollectorFailure.message("Process probe is not initialized")
        }
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
        var result = try probe.snapshot(
            phase: phase, ownedChild: child, permitZombie: permitZombie,
            recoveryDeadline: samplingDeadline)
        if !permitZombie, let threads = threadCPU?.snapshot(ownedChild: child) {
            result["thread_cpu"] = threads
        }
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
                ExternalTrace.enabled
                ? ExternalTrace.reason
                : latestGPU?.gpu_seconds == nil
                    ? "GPU counters have not produced a valid interval" : NSNull() as Any
        }
        result["external_trace"] = ExternalTrace.enabled
        if ExternalTrace.enabled { result["gpu_provider"] = ExternalTrace.provider }
        result["gpu_sampled"] = gpuSampled
        result["gpu_sample_monotonic_seconds"] =
            lastGPURead.isFinite ? lastGPURead as Any : NSNull()
        result["gpu_final_self_sample"] = nativeGPUFinal
        if nativeGPUEnabled {
            result["kernel_gpu_counter"] = nativeGPUCounter
            result["gpu_coverage_end_monotonic_seconds"] = lastGPURead
        }
        lastGPUReported = lastGPURead
        result["trace_coverage"] = traceCapability.available
        result["trace_unavailable_reason"] = traceCapability.reason as Any? ?? NSNull()
        result["trace_timestamp_attribution"] = traceCapability.timestamp_attribution
        result["trace_timestamp_unavailable_reason"] =
            traceCapability.timestamp_unavailable_reason as Any? ?? NSNull()
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
            threadCPU?.ingest(event)
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
        guard let probe else { return }
        if let timestamp = validatedNativeGPUFinalTimestamp(
            event, processID: probe.processID, birthTime: probe.birthTimeMicroseconds,
            now: ProcessResources.monotonicSeconds())
        {
            nativeGPUFinalReceivedAt = timestamp
        }
        // An unsupported provider may still deliver its final raw event. Record
        // that receipt above while keeping every measured GPU value unavailable.
        guard nativeGPUEnabled else { return }
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

private func validatedNativeGPUFinalTimestamp(
    _ event: [String: Any], processID: Int32, birthTime: UInt64, now: Double
) -> Double? {
    guard event["type"] as? String == "gpu_sample", event["final"] as? Bool == true,
        let pid = event["process_id"] as? NSNumber, CFGetTypeID(pid) != CFBooleanGetTypeID(),
        pid.int64Value == Int64(processID),
        let birth = event["birth_time_us"] as? NSNumber, CFGetTypeID(birth) != CFBooleanGetTypeID(),
        birth.uint64Value == birthTime,
        let timestamp = event["monotonic_seconds"] as? Double, timestamp.isFinite,
        timestamp >= 0, timestamp <= now + 0.01
    else { return nil }
    return timestamp
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
