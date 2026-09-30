import Darwin
import Foundation

@testable import FluxLLM

/// Cumulative process counters, except for the instantaneous physical footprint.
/// Subtract counters between phase boundaries; setup is deliberately not hidden.
struct ProcessResourceSnapshot: Codable, Sendable {
    let timestamp: Date
    let uptimeSeconds: Double
    let processID: Int32
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let physicalFootprintBytes: UInt64
    /// Includes everything since process launch, including fixture setup.
    let lifetimePeakPhysicalFootprintBytes: UInt64
    let diskBytesWritten: UInt64
    /// Kernel logical-write accounting, distinct from physical disk traffic.
    let logicalBytesWritten: UInt64
    let packageIdleWakeups: UInt64
    let interruptWakeups: UInt64
    /// Process CPU accumulated inside probe read windows. This includes any
    /// concurrent application work and must not be subtracted from CPU totals.
    let observerCPUSeconds: Double
    /// Monotonic wall time accumulated inside the same probe read windows.
    let observerElapsedSeconds: Double
    let gpu: ProcessGPUReading

    var cpuSeconds: Double { userCPUSeconds + systemCPUSeconds }
}

/// A process-attributed execution-time estimate, never device utilization.
/// A nil value is unavailable, including when a process has no readable clients.
struct ProcessGPUReading: Codable, Sendable {
    let activityPercent: Double?
    /// The same monotonic interval used by the sampler's percentage denominator.
    let intervalSeconds: Double?
    let measuredProcessIDs: [Int32]
    let unavailableReason: String?
    let method: String
    let caveat: String

    /// Execution across concurrent queues can exceed elapsed wall time.
    var executionSeconds: Double? {
        guard let activityPercent, let intervalSeconds else { return nil }
        return activityPercent / 100 * intervalSeconds
    }
}

/// Sample sequentially at about 1 Hz from the isolated performance test host.
/// Read failures throw; missing GPU counters remain explicitly unavailable.
/// Observer CPU and memory are included in the host's measured resource use.
/// GPU enumeration runs in this process. Observer counters conservatively
/// expose its read windows; they cannot separate observer CPU from app work.
actor ProcessResourceProbe {
    static let gpuMeasurementMethod =
        "IOKit AGX AppUsage accumulatedGPUTime for the test host PID and birth identity"
    static let gpuMeasurementCaveat =
        "Undocumented driver counters; execution seconds / wall seconds, not GPU occupancy or energy. "
        + "Requires external attribution validation for this Mac/OS before use as a regression gate. "
        + "Rendering charged to WindowServer or other processes is excluded."

    private let processID: Int32
    private let identity: GPUProcessIdentity?
    private let gpuClock: ProcessGPUProbeClock
    private let gpuSampler: IOKitGPUActivitySampler
    private var isSampling = false
    private var observerCPUSeconds = 0.0
    private var observerElapsedSeconds = 0.0

    init() {
        let processID = getpid()
        let gpuClock = ProcessGPUProbeClock()
        self.processID = processID
        identity = DarwinBackendProcessInspector().identity(of: processID)
        self.gpuClock = gpuClock
        gpuSampler = IOKitGPUActivitySampler(
            reader: IOKitGPURegistry.read,
            clock: { gpuClock.sample() })
    }

    func sample() async throws -> ProcessResourceSnapshot {
        // The actor yields while its GPU sampler reads. Refuse overlapping calls
        // so a second call cannot replace the first call's recorded interval.
        guard !isSampling else { throw ProbeError.concurrentSampling }
        isSampling = true
        defer { isSampling = false }

        let observerStarted = ContinuousClock().now
        let cpuBeforeSampling = try Self.readCPUUsage()
        let cpuSecondsBeforeSampling =
            Self.seconds(cpuBeforeSampling.ru_utime) + Self.seconds(cpuBeforeSampling.ru_stime)
        let gpu = await sampleGPU()
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processID, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else {
            throw ProbeError.systemCall(name: "proc_pid_rusage(RUSAGE_INFO_V4)", code: errno)
        }

        // getrusage exposes CPU time as timeval, avoiding any dependence on
        // undocumented absolute-time units in other process accounting fields.
        let cpu = try Self.readCPUUsage()
        let userCPUSeconds = Self.seconds(cpu.ru_utime)
        let systemCPUSeconds = Self.seconds(cpu.ru_stime)
        let observerDuration = observerStarted.duration(to: ContinuousClock().now).components
        observerCPUSeconds += userCPUSeconds + systemCPUSeconds - cpuSecondsBeforeSampling
        observerElapsedSeconds +=
            Double(observerDuration.seconds) + Double(observerDuration.attoseconds) / 1e18
        return ProcessResourceSnapshot(
            timestamp: Date(),
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            processID: processID,
            userCPUSeconds: userCPUSeconds,
            systemCPUSeconds: systemCPUSeconds,
            physicalFootprintBytes: usage.ri_phys_footprint,
            lifetimePeakPhysicalFootprintBytes: usage.ri_lifetime_max_phys_footprint,
            diskBytesWritten: usage.ri_diskio_byteswritten,
            logicalBytesWritten: usage.ri_logical_writes,
            packageIdleWakeups: usage.ri_pkg_idle_wkups,
            interruptWakeups: usage.ri_interrupt_wkups,
            observerCPUSeconds: observerCPUSeconds,
            observerElapsedSeconds: observerElapsedSeconds,
            gpu: gpu)
    }

    private func sampleGPU() async -> ProcessGPUReading {
        func unavailable(_ reason: String) -> ProcessGPUReading {
            ProcessGPUReading(
                activityPercent: nil, intervalSeconds: nil, measuredProcessIDs: [],
                unavailableReason: reason, method: Self.gpuMeasurementMethod,
                caveat: Self.gpuMeasurementCaveat)
        }
        guard let identity else {
            return unavailable("The test host's PID and process birth time could not be verified.")
        }
        let sample = await gpuSampler.sample(processes: [identity])
        guard let value = sample.activityPercent else {
            return unavailable(sample.unavailableReason ?? "Process GPU counters are unavailable.")
        }
        guard sample.scope == .backendProcesses, sample.processIDs == [processID] else {
            return unavailable("GPU counter attribution did not match the test host process.")
        }
        guard value.isFinite, value >= 0,
            let interval = gpuClock.lastIntervalSeconds, interval.isFinite,
            interval > 0, interval <= 5
        else {
            return unavailable("The process GPU counter interval is invalid.")
        }
        return ProcessGPUReading(
            activityPercent: value, intervalSeconds: interval,
            measuredProcessIDs: sample.processIDs, unavailableReason: nil,
            method: Self.gpuMeasurementMethod, caveat: Self.gpuMeasurementCaveat)
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    private static func readCPUUsage() throws -> rusage {
        var cpu = rusage()
        guard getrusage(RUSAGE_SELF, &cpu) == 0 else {
            throw ProbeError.systemCall(name: "getrusage(RUSAGE_SELF)", code: errno)
        }
        return cpu
    }

    enum ProbeError: Error, LocalizedError {
        case concurrentSampling
        case systemCall(name: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .concurrentSampling:
                return "Process resource samples must be collected sequentially."
            case .systemCall(let name, let code):
                return "\(name) failed with errno \(code); resource measurements are unavailable."
            }
        }
    }
}

/// The production sampler accepts a monotonic clock. Capture its exact interval
/// without changing production code or estimating GPU time from polling cadence.
/// The lock protects the state shared by the probe and GPU sampler actors.
private final class ProcessGPUProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let origin = ContinuousClock().now
    private var previousUptime: Double?
    private var intervalSeconds: Double?

    var lastIntervalSeconds: Double? {
        lock.withLock { intervalSeconds }
    }

    func sample() -> GPUActivityInstant {
        lock.withLock {
            let duration = origin.duration(to: clock.now).components
            let uptime = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            intervalSeconds = previousUptime.map { uptime - $0 }
            previousUptime = uptime
            return GPUActivityInstant(uptime: uptime, date: Date())
        }
    }
}
