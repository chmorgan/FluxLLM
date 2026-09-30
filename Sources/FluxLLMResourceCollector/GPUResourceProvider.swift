import Darwin
import FluxLLM
import Foundation
import Metal

/// These are execution-time counters, not GPU occupancy, watts, or Energy Impact.
/// A missing process/client/interval is deliberately not represented as zero.
// Preserve the field names in the performance JSON protocol.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct GPUResourceReading: Codable, Sendable {
    let gpu_seconds: Double?
    let gpu_unavailable_reason: String?
    let gpu_provider: String
    let gpu_interval_seconds: Double?
    let gpu_interval_execution_seconds: Double?
}

struct GPUCapabilityReport: Codable, Sendable {
    let available: Bool
    let provider: String
    let reason: String?
    let calibration: GPUCalibrationEvidence?
}

// Preserve the field names in the performance JSON protocol.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct GPUCalibrationEvidence: Codable, Sendable {
    let elapsed_seconds: Double
    let idle_execution_seconds: Double
    let metal_execution_seconds: Double
    let measured_execution_seconds: Double
    let unrelated_metal_execution_seconds: Double
    let unrelated_measured_execution_seconds: Double
    let target_during_unrelated_execution_seconds: Double
    let maximum_relative_error: Double
    let maximum_idle_execution_seconds: Double
    let target_pid: Int32
    let target_birth_microseconds: UInt64
    let unrelated_pid: Int32
    let unrelated_birth_microseconds: UInt64
    let notes: String
}

actor GPUResourceProvider {
    static let provider = "IOKit AGX AppUsage accumulatedGPUTime; PID and process birth verified"
    static let kernelProvider =
        "Mach TASK_POWER_INFO_V2 task_gpu_utilisation nanoseconds; self PID and birth verified"
    private static let maximumRelativeError = 0.20
    private static let maximumIdleExecutionSeconds = 0.002

    private let target: GPUProcessIdentity
    private let capability: GPUCapabilityReport?
    private let sampler = IOKitGPUActivitySampler()
    private var cumulativeExecutionSeconds = 0.0

    init(target: GPUProcessIdentity, capability: GPUCapabilityReport? = nil) {
        self.target = target
        self.capability = capability
    }

    /// The cumulative value sums successfully observed intervals only. Callers
    /// must reject every missing interval rather than carrying the last value
    /// forward or treating this as an uninterrupted kernel lifetime counter.
    func sample() async -> GPUResourceReading {
        guard let capability, capability.available,
            capability.provider == Self.provider, capability.calibration != nil
        else {
            return unavailable(
                capability?.reason ?? "The GPU provider has not passed automatic calibration.")
        }
        guard Self.identity(of: target.pid) == target else {
            return unavailable("The measured process exited or its PID/birth identity changed.")
        }
        let value = await sampler.sample(processes: [target])
        guard Self.identity(of: target.pid) == target else {
            return unavailable("The measured process identity changed during the GPU read.")
        }
        guard value.scope == .backendProcesses, value.processIDs == [target.pid],
            let interval = value.intervalSeconds, interval.isFinite, interval > 0, interval <= 5,
            let execution = value.executionSeconds, execution.isFinite, execution >= 0,
            let activity = value.activityPercent, activity.isFinite, activity >= 0,
            abs(activity - execution / interval * 100) < 0.000_001
        else {
            return unavailable(
                value.unavailableReason ?? "GPU attribution, counters, or interval are invalid.")
        }
        cumulativeExecutionSeconds += execution
        return GPUResourceReading(
            gpu_seconds: cumulativeExecutionSeconds, gpu_unavailable_reason: nil,
            gpu_provider: Self.provider, gpu_interval_seconds: interval,
            gpu_interval_execution_seconds: execution)
    }

    private func unavailable(_ reason: String) -> GPUResourceReading {
        GPUResourceReading(
            gpu_seconds: nil, gpu_unavailable_reason: reason, gpu_provider: Self.provider,
            gpu_interval_seconds: nil, gpu_interval_execution_seconds: nil)
    }

    /// Calibrates native task accounting and the driver-specific fallback on
    /// this invocation. Two helper PIDs retain warmed Metal queues: idle, serial
    /// work, then unrelated work. Completed command-buffer timestamps provide
    /// the independent units check. Native accounting is preferred because a
    /// successful self read represents idle zero without requiring a GPU client.
    /// No capability result is inferred from hardware names or privileges.
    ///
    /// powermetrics is intentionally not parsed speculatively: its documented
    /// per-process GPU option is hardware-dependent and its plist schema/zero
    /// semantics need a captured, calibrated implementation before use here.
    static func preflight(deadlineSeconds: Double = 15) async -> GPUCapabilityReport {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + min(max(deadlineSeconds, 1), 15)
        var first: GPUCalibrationSession?
        var second: GPUCalibrationSession?
        defer {
            first?.stop()
            second?.stop()
        }
        do {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let target = try GPUCalibrationSession(executable: executable, deadline: deadline)
            first = target
            let unrelated = try GPUCalibrationSession(executable: executable, deadline: deadline)
            second = unrelated
            let targetSampler = IOKitGPUActivitySampler()
            let unrelatedSampler = IOKitGPUActivitySampler()
            _ = await targetSampler.sample(processes: [target.identity])
            _ = await unrelatedSampler.sample(processes: [unrelated.identity])
            try await pause(until: deadline)
            let idle = try? await execution(targetSampler, identity: target.identity)
            _ = try? await execution(unrelatedSampler, identity: unrelated.identity)
            let kernelAfterIdle = try target.snapshot(deadline: deadline)

            try target.beginWork(seconds: 2)
            var active: [Double?] = []
            for _ in 0..<3 {
                try await pause(until: deadline)
                active.append(try? await execution(targetSampler, identity: target.identity))
                _ = try? await execution(unrelatedSampler, identity: unrelated.identity)
            }
            let targetTiming = try target.finishWork(deadline: deadline)
            let kernelAfterTarget = try target.snapshot(deadline: deadline)
            let kernelBeforeUnrelated = try unrelated.snapshot(deadline: deadline)

            try unrelated.beginWork(seconds: 2)
            var unrelatedActive: [Double?] = []
            var leakedActivity: [Double?] = []
            for _ in 0..<3 {
                try await pause(until: deadline)
                leakedActivity.append(
                    try? await execution(targetSampler, identity: target.identity))
                unrelatedActive.append(
                    try? await execution(unrelatedSampler, identity: unrelated.identity))
            }
            let unrelatedTiming = try unrelated.finishWork(deadline: deadline)
            let kernelUnrelatedEnd = try unrelated.snapshot(deadline: deadline)
            let kernelTargetEnd = try target.snapshot(deadline: deadline)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw GPUCalibrationError.invalid("GPU calibration exceeded its deadline.")
            }
            func accepted(
                provider: String, idle: Double, active: Double, unrelatedActive: Double,
                leaked: Double, notes: String
            ) -> GPUCapabilityReport {
                GPUCapabilityReport(
                    available: true, provider: provider, reason: nil,
                    calibration: GPUCalibrationEvidence(
                        elapsed_seconds: elapsed, idle_execution_seconds: idle,
                        metal_execution_seconds: targetTiming, measured_execution_seconds: active,
                        unrelated_metal_execution_seconds: unrelatedTiming,
                        unrelated_measured_execution_seconds: unrelatedActive,
                        target_during_unrelated_execution_seconds: leaked,
                        maximum_relative_error: maximumRelativeError,
                        maximum_idle_execution_seconds: maximumIdleExecutionSeconds,
                        target_pid: target.identity.pid,
                        target_birth_microseconds: target.identity.startTimeMicroseconds,
                        unrelated_pid: unrelated.identity.pid,
                        unrelated_birth_microseconds: unrelated.identity.startTimeMicroseconds,
                        notes: notes + " WindowServer/compositor work is excluded. "
                            + "Calibration establishes a provider capability, not a GPU performance budget."
                    ))
            }
            // Successful task_info returns an explicit zero even before a task
            // owns a GPU client. Accept that zero only after independently
            // proving on this machine that the same field advances during work.
            var nativeFailure = ""
            do {
                let nativeIdle = try nativeDelta(target.initialKernelCounter, kernelAfterIdle)
                let nativeActive = try nativeDelta(kernelAfterIdle, kernelAfterTarget)
                let nativeUnrelated = try nativeDelta(kernelBeforeUnrelated, kernelUnrelatedEnd)
                let nativeLeak = try nativeDelta(kernelAfterTarget, kernelTargetEnd)
                try compare(measured: nativeActive, metal: targetTiming)
                try compare(measured: nativeUnrelated, metal: unrelatedTiming)
                guard nativeIdle <= maximumIdleExecutionSeconds,
                    nativeLeak <= maximumIdleExecutionSeconds
                else {
                    throw GPUCalibrationError.invalid(
                        "Native GPU idle or unrelated-process attribution failed.")
                }
                return accepted(
                    provider: kernelProvider, idle: nativeIdle, active: nativeActive,
                    unrelatedActive: nativeUnrelated, leaked: nativeLeak,
                    notes:
                        "Native self task_info raw counter deltas / 1e9 match completed serial Metal timing. "
                        + "Explicit idle zeros are supported. Self reads add their small cost to the measured app."
                )
            } catch { nativeFailure = error.localizedDescription }

            do {
                guard let idle, active.allSatisfy({ $0 != nil }),
                    unrelatedActive.allSatisfy({ $0 != nil }),
                    leakedActivity.allSatisfy({ $0 != nil })
                else {
                    throw GPUCalibrationError.invalid(
                        "IOKit did not expose every required calibration interval.")
                }
                let activeTotal = active.compactMap { $0 }.reduce(0, +)
                let unrelatedTotal = unrelatedActive.compactMap { $0 }.reduce(0, +)
                let leakTotal = leakedActivity.compactMap { $0 }.reduce(0, +)
                try compare(measured: activeTotal, metal: targetTiming)
                try compare(measured: unrelatedTotal, metal: unrelatedTiming)
                guard idle <= maximumIdleExecutionSeconds, leakTotal <= maximumIdleExecutionSeconds
                else {
                    throw GPUCalibrationError.invalid(
                        "IOKit GPU idle or unrelated-process attribution failed.")
                }
                return accepted(
                    provider: provider, idle: idle, active: activeTotal,
                    unrelatedActive: unrelatedTotal, leaked: leakTotal,
                    notes:
                        "Undocumented AGX counters validated against serial Metal timing. Missing clients remain unavailable. "
                        + "Native provider unavailable: \(nativeFailure)")
            } catch {
                throw GPUCalibrationError.invalid(
                    "Native: \(nativeFailure) IOKit: \(error.localizedDescription)")
            }
        } catch {
            return GPUCapabilityReport(
                available: false, provider: provider,
                reason: "GPU calibration failed: \(error.localizedDescription)", calibration: nil)
        }
    }

    private static func pause(until deadline: Double) async throws {
        guard ProcessInfo.processInfo.systemUptime + 1 < deadline else {
            throw GPUCalibrationError.invalid("GPU calibration exceeded its deadline.")
        }
        try await Task.sleep(for: .seconds(1))
    }

    private static func execution(
        _ sampler: IOKitGPUActivitySampler, identity: GPUProcessIdentity
    ) async throws -> Double {
        guard Self.identity(of: identity.pid) == identity else {
            throw GPUCalibrationError.invalid("The GPU calibration helper identity changed.")
        }
        let sample = await sampler.sample(processes: [identity])
        guard Self.identity(of: identity.pid) == identity,
            sample.scope == .backendProcesses, sample.processIDs == [identity.pid],
            let interval = sample.intervalSeconds, interval.isFinite, interval > 0, interval <= 5,
            let seconds = sample.executionSeconds, seconds.isFinite, seconds >= 0
        else {
            throw GPUCalibrationError.invalid(
                sample.unavailableReason ?? "Invalid GPU calibration interval.")
        }
        return seconds
    }

    private static func compare(measured: Double, metal: Double) throws {
        guard metal.isFinite, metal >= 0.05, measured.isFinite, measured > 0,
            abs(measured - metal) / metal <= maximumRelativeError
        else {
            throw GPUCalibrationError.invalid(
                "GPU counter units/timing failed calibration: counter=\(measured)s, Metal=\(metal)s."
            )
        }
    }

    private static func nativeDelta(_ earlier: UInt64?, _ later: UInt64?) throws -> Double {
        guard let earlier, let later, later >= earlier else {
            throw GPUCalibrationError.invalid(
                "Native task GPU counters are missing or moved backwards.")
        }
        return Double(later - earlier) / 1_000_000_000
    }

    static func identity(of pid: Int32) -> GPUProcessIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
            info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0,
            info.pbi_start_tvsec <= (UInt64.max - 999_999) / 1_000_000,
            info.pbi_start_tvusec < 1_000_000
        else { return nil }
        return GPUProcessIdentity(
            pid: pid,
            startTimeMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

    /// Dispatch this mode before the normal collector CLI, and never load or
    /// launch the application in this child. Only its command/event pipes are used.
    static func runCalibrationWorker() -> Int32 {
        do {
            _ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)
            let worker = try MetalCalibrationWorkload()
            _ = try worker.run(seconds: 0.01)  // Establish the same queue before baselining.
            try writeWorkerReply(
                .init(
                    event: "ready", gpu_seconds: nil, error: nil,
                    kernel_gpu_counter: NativeProcessGPUCounter.read()?.rawTimeNanoseconds))
            while let line = readLine() {
                guard line.utf8.count <= 1_024 else {
                    throw GPUCalibrationError.invalid("Oversized calibration command.")
                }
                let command = try JSONDecoder().decode(GPUWorkerCommand.self, from: Data(line.utf8))
                if command.command == "stop" { return 0 }
                if command.command == "snapshot" {
                    try writeWorkerReply(
                        .init(
                            event: "snapshot", gpu_seconds: nil, error: nil,
                            kernel_gpu_counter: NativeProcessGPUCounter.read()?.rawTimeNanoseconds))
                    continue
                }
                guard command.command == "work", let duration = command.seconds,
                    duration.isFinite, duration > 0, duration <= 3
                else { throw GPUCalibrationError.invalid("Invalid calibration command.") }
                let before = NativeProcessGPUCounter.read()?.rawTimeNanoseconds
                let seconds = try worker.run(seconds: duration)
                let after = NativeProcessGPUCounter.read()?.rawTimeNanoseconds
                try writeWorkerReply(
                    .init(
                        event: "completed", gpu_seconds: seconds, error: nil,
                        kernel_gpu_counter: after, kernel_gpu_counter_before: before,
                        kernel_gpu_counter_after: after))
            }
            return 0
        } catch {
            try? writeWorkerReply(
                .init(event: "error", gpu_seconds: nil, error: error.localizedDescription))
            return 1
        }
    }

    /// Exercises the real short-line pipe reader without requiring a Metal
    /// device. The child deliberately stays alive after each short response;
    /// reading until EOF or a 4096-byte fill would deadlock this check.
    static func verifyControlPipe() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let session = try GPUCalibrationSession(
            executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            deadline: deadline, workerArguments: ["--gpu-protocol-self-test-worker"])
        defer { session.stop() }
        guard try session.snapshot(deadline: deadline) == 0 else {
            throw GPUCalibrationError.invalid(
                "GPU control pipe self-test received an invalid snapshot.")
        }
    }

    static func runProtocolSelfTestWorker() -> Int32 {
        do {
            try writeWorkerReply(
                .init(event: "ready", gpu_seconds: nil, error: nil, kernel_gpu_counter: 0))
            while let line = readLine() {
                guard line.utf8.count <= 1_024 else { return 1 }
                let command = try JSONDecoder().decode(GPUWorkerCommand.self, from: Data(line.utf8))
                if command.command == "stop" { return 0 }
                guard command.command == "snapshot" else { return 1 }
                try writeWorkerReply(
                    .init(event: "snapshot", gpu_seconds: nil, error: nil, kernel_gpu_counter: 0))
            }
            return 0
        } catch { return 1 }
    }

    private static func writeWorkerReply(_ reply: GPUWorkerReply) throws {
        var data = try JSONEncoder().encode(reply)
        data.append(0x0a)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

private enum GPUCalibrationError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        }
    }
}

private struct GPUWorkerCommand: Codable {
    let command: String
    let seconds: Double?
}

// Preserve the field names in the performance JSON protocol.
// swift-format-ignore: AlwaysUseLowerCamelCase
private struct GPUWorkerReply: Codable {
    let event: String
    let gpu_seconds: Double?
    let error: String?
    let kernel_gpu_counter: UInt64?
    let kernel_gpu_counter_before: UInt64?
    let kernel_gpu_counter_after: UInt64?
    let kernel_gpu_unavailable_reason: String?

    init(
        event: String, gpu_seconds: Double?, error: String?,
        kernel_gpu_counter: UInt64? = nil, kernel_gpu_counter_before: UInt64? = nil,
        kernel_gpu_counter_after: UInt64? = nil
    ) {
        self.event = event
        self.gpu_seconds = gpu_seconds
        self.error = error
        self.kernel_gpu_counter = kernel_gpu_counter
        self.kernel_gpu_counter_before = kernel_gpu_counter_before
        self.kernel_gpu_counter_after = kernel_gpu_counter_after
        kernel_gpu_unavailable_reason =
            kernel_gpu_counter == nil
            ? "Native task_info GPU counter is unavailable." : nil
    }
}

/// Synchronous pipe operations are bounded by poll deadlines. The owning
/// preflight task is the only caller; @unchecked Sendable permits its state to
/// survive async sampler calls without transferring ownership to another task.
private final class GPUCalibrationSession: @unchecked Sendable {
    let identity: GPUProcessIdentity
    private(set) var initialKernelCounter: UInt64?
    private let process: Process
    private let commands: FileHandle
    private let events: FileHandle
    private var buffered = Data()
    private var stopped = false

    init(
        executable: URL, deadline: Double, workerArguments: [String] = ["--gpu-calibration-worker"]
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = workerArguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard let identity = GPUResourceProvider.identity(of: process.processIdentifier) else {
            process.terminate()
            // Process startup/termination notifications must not turn a failed
            // capability probe into an unbounded preflight wait.
            throw GPUCalibrationError.invalid("Could not verify GPU helper PID and birth time.")
        }
        self.identity = identity
        self.process = process
        commands = input.fileHandleForWriting
        events = output.fileHandleForReading
        _ = fcntl(commands.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            guard
                fcntl(
                    events.fileDescriptor, F_SETFL,
                    fcntl(events.fileDescriptor, F_GETFL) | O_NONBLOCK) == 0
            else {
                throw GPUCalibrationError.invalid("Cannot make GPU helper events nonblocking.")
            }
            let ready = try reply(deadline: deadline)
            guard ready.event == "ready", ready.error == nil else {
                throw GPUCalibrationError.invalid(ready.error ?? "GPU helper did not become ready.")
            }
            initialKernelCounter = ready.kernel_gpu_counter
        } catch {
            stop()
            throw error
        }
    }

    func beginWork(seconds: Double) throws {
        var command = try JSONEncoder().encode(GPUWorkerCommand(command: "work", seconds: seconds))
        command.append(0x0a)
        try commands.write(contentsOf: command)
    }

    func finishWork(deadline: Double) throws -> Double {
        let result = try reply(deadline: deadline)
        guard result.event == "completed", result.error == nil, let seconds = result.gpu_seconds
        else {
            throw GPUCalibrationError.invalid(
                result.error ?? "GPU helper did not complete its work.")
        }
        return seconds
    }

    func snapshot(deadline: Double) throws -> UInt64? {
        var command = try JSONEncoder().encode(GPUWorkerCommand(command: "snapshot", seconds: nil))
        command.append(0x0a)
        try commands.write(contentsOf: command)
        let result = try reply(deadline: deadline)
        guard result.event == "snapshot", result.error == nil else {
            throw GPUCalibrationError.invalid(result.error ?? "GPU helper snapshot failed.")
        }
        return result.kernel_gpu_counter
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        try? commands.close()
        // A helper may be compiling or waiting on GPU completion. Bound cleanup;
        // terminate only this exact child identity, never an arbitrary reused PID.
        if GPUResourceProvider.identity(of: identity.pid) == identity {
            _ = kill(identity.pid, SIGKILL)
        }
        // Foundation's blocking wait must not defeat the calibration deadline.
        // Its normal child reaper remains responsible for asynchronous cleanup.
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning, ProcessInfo.processInfo.systemUptime < cleanupDeadline {
            usleep(5_000)
        }
        if !process.isRunning { process.waitUntilExit() }
        try? events.close()
    }

    private func reply(deadline: Double) throws -> GPUWorkerReply {
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let current = GPUResourceProvider.identity(of: identity.pid), current != identity {
                throw GPUCalibrationError.invalid("GPU helper process identity changed.")
            }
            if let newline = buffered.firstIndex(of: 0x0a) {
                let line = buffered.prefix(upTo: newline)
                buffered.removeSubrange(...newline)
                let decoded = try JSONDecoder().decode(GPUWorkerReply.self, from: line)
                // Preserve a short error reply from a helper that has already
                // exited; successful replies still require the verified child.
                guard
                    decoded.error != nil
                        || GPUResourceProvider.identity(of: identity.pid) == identity
                else {
                    throw GPUCalibrationError.invalid("GPU helper process identity changed.")
                }
                return decoded
            }
            guard buffered.count <= 8_192 else {
                throw GPUCalibrationError.invalid("Oversized GPU helper response.")
            }
            var descriptor = pollfd(fd: events.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(
                1, min(250, Int((deadline - ProcessInfo.processInfo.systemUptime) * 1_000)))
            let result = poll(&descriptor, 1, Int32(remaining))
            if result < 0 {
                if errno == EINTR { continue }
                throw GPUCalibrationError.invalid("GPU helper event poll failed.")
            }
            if result == 0 { continue }
            guard descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else {
                throw GPUCalibrationError.invalid("GPU helper event pipe became unavailable.")
            }
            // FileHandle.read(upToCount:) can wait to fill the requested length
            // on a pipe. A worker emits a short JSON line and then waits for its
            // next command, so use one nonblocking POSIX read after poll instead.
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = read(events.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                buffered.append(contentsOf: bytes.prefix(count))
            } else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            } else {
                throw GPUCalibrationError.invalid("GPU helper exited without a complete response.")
            }
        }
        throw GPUCalibrationError.invalid("GPU helper exceeded the calibration deadline.")
    }
}

/// One persistent queue and buffer keep registry topology fixed. Serial command
/// buffers make summed Metal GPU timestamps comparable to accumulated execution.
private final class MetalCalibrationWorkload {
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let buffer: any MTLBuffer

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
            let buffer = device.makeBuffer(
                length: 4_096 * MemoryLayout<Float>.stride, options: .storageModeShared)
        else { throw GPUCalibrationError.invalid("Metal device, queue, or buffer is unavailable.") }
        let source = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void exercise(device float *values [[buffer(0)]], uint index [[thread_position_in_grid]]) {
                float value = values[index] + float(index) * 0.0001f;
                for (uint round = 0; round < 2048; ++round) {
                    value = sin(value) * 0.999f + 0.001f;
                }
                values[index] = value;
            }
            """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "exercise") else {
            throw GPUCalibrationError.invalid("Metal calibration function is unavailable.")
        }
        self.queue = queue
        self.buffer = buffer
        pipeline = try device.makeComputePipelineState(function: function)
        memset(buffer.contents(), 0, buffer.length)
    }

    func run(seconds: Double) throws -> Double {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var gpuSeconds = 0.0
        repeat {
            gpuSeconds += try autoreleasepool {
                guard let command = queue.makeCommandBuffer(),
                    let encoder = command.makeComputeCommandEncoder()
                else {
                    throw GPUCalibrationError.invalid("Could not encode GPU calibration work.")
                }
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.dispatchThreads(
                    MTLSize(width: 4_096, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1
                    ))
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                let started = command.gpuStartTime
                let ended = command.gpuEndTime
                guard command.status == .completed, command.error == nil,
                    started.isFinite, ended.isFinite, started > 0, ended > started
                else {
                    throw GPUCalibrationError.invalid(
                        "Completed Metal GPU timestamps are unavailable.")
                }
                return ended - started
            }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return gpuSeconds
    }
}
