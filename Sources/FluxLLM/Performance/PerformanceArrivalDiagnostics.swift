import Darwin
import Dispatch
import Foundation

/// Opt-in scoped arrival timings. CPU values come from the calling thread's
/// native CPU clock, while wall values use monotonic uptime. These diagnostic
/// scopes include their small measurement overhead and stay disabled during
/// acceptance captures. They do not measure GPU execution time.
public final class PerformanceArrivalDiagnostics: @unchecked Sendable {
    fileprivate final class OwnerIdentity {}

    public enum Metric: String, CaseIterable, Sendable {
        case profilePreparation = "profile_preparation"
        case profileCreate = "profile_create"
        case metalElements = "metal_elements"
        case metalDescriptorUpdate = "metal_descriptor_update"
        case metalDescriptorUpload = "metal_descriptor_upload"
        case metalSurfaceSetup = "metal_surface_setup"
        case metalFirstDrawable = "metal_first_drawable"
        case metalLaterDrawable = "metal_later_drawable"
        case metalFrameCallback = "metal_frame_callback"
        case metalFrameEncode = "metal_frame_encode"
        case metalFrameSubmit = "metal_frame_submit"
        case metalCompletionCallback = "metal_completion_callback"
        case metalCompletionMainActor = "metal_completion_main_actor"
        case metalClear = "metal_clear"
        case canvasArrivalDraw = "canvas_arrival_draw"
    }

    /// A token has no strong reference to its collector and is not stored in a
    /// registry. Dropping an unfinished token cannot grow collector storage.
    /// Its consumed flag is accessed only while its owning collector is locked.
    public final class Token: @unchecked Sendable {
        fileprivate let owner: OwnerIdentity
        fileprivate let generation: UInt64
        fileprivate let metric: Metric
        fileprivate let start: ClockSample
        fileprivate var consumed = false

        fileprivate init(
            owner: OwnerIdentity, generation: UInt64, metric: Metric, start: ClockSample
        ) {
            self.owner = owner
            self.generation = generation
            self.metric = metric
            self.start = start
        }
    }

    struct ClockSample: Sendable {
        let threadID: UInt64
        let cpuNanoseconds: UInt64
        let uptimeNanoseconds: UInt64
    }

    private struct Measurement {
        var calls: UInt64 = 0
        var cpu: UInt64 = 0
        var wall: UInt64 = 0
        var maxCPU: UInt64 = 0
        var maxWall: UInt64 = 0
        var clockFailures: UInt64 = 0
        var rejectedTokens: UInt64 = 0

        var json: [String: UInt64] {
            [
                "calls": calls, "cpu_ns": cpu, "wall_ns": wall,
                "max_cpu_ns": maxCPU, "max_wall_ns": maxWall,
                "clock_failures": clockFailures, "rejected_tokens": rejectedTokens,
            ]
        }
    }

    public static let shared = PerformanceArrivalDiagnostics()

    private let lock = NSLock()
    private let owner = OwnerIdentity()
    private let clock: @Sendable () -> ClockSample?
    private var enabled = false
    private var generation: UInt64 = 0
    private var measurements: [Metric: Measurement] = [:]

    convenience init() {
        self.init(clock: Self.nativeClock)
    }

    init(clock: @escaping @Sendable () -> ClockSample?) {
        self.clock = clock
    }

    /// Starts a fresh diagnostic epoch; tokens from older epochs cannot add data.
    public func enable() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        measurements = Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, Measurement()) })
        enabled = true
    }

    /// Stops measurement without clearing the completed results.
    public func disable() {
        lock.lock()
        defer { lock.unlock() }
        enabled = false
        generation &+= 1
    }

    public func begin(_ metric: Metric) -> Token? {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return nil }
        guard let sample = clock() else {
            measurements[metric, default: Measurement()].clockFailures &+= 1
            return nil
        }
        return Token(owner: owner, generation: generation, metric: metric, start: sample)
    }

    /// A scope must end once on its starting thread. Invalid clocks or tokens
    /// produce diagnostic failure counts, never fabricated CPU/wall durations.
    public func end(_ token: Token?) {
        guard let token else { return }
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        guard token.owner === owner, token.generation == generation else {
            measurements[token.metric, default: Measurement()].rejectedTokens &+= 1
            return
        }
        guard !token.consumed else {
            measurements[token.metric, default: Measurement()].rejectedTokens &+= 1
            return
        }
        token.consumed = true
        guard let sample = clock() else {
            measurements[token.metric, default: Measurement()].clockFailures &+= 1
            return
        }
        guard sample.threadID == token.start.threadID else {
            measurements[token.metric, default: Measurement()].rejectedTokens &+= 1
            return
        }
        guard sample.cpuNanoseconds >= token.start.cpuNanoseconds,
            sample.uptimeNanoseconds >= token.start.uptimeNanoseconds
        else {
            measurements[token.metric, default: Measurement()].clockFailures &+= 1
            return
        }
        let cpu = sample.cpuNanoseconds - token.start.cpuNanoseconds
        let wall = sample.uptimeNanoseconds - token.start.uptimeNanoseconds
        var value = measurements[token.metric, default: Measurement()]
        value.calls = Self.saturatingAdd(value.calls, 1)
        value.cpu = Self.saturatingAdd(value.cpu, cpu)
        value.wall = Self.saturatingAdd(value.wall, wall)
        value.maxCPU = max(value.maxCPU, cpu)
        value.maxWall = max(value.maxWall, wall)
        measurements[token.metric] = value
    }

    public func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let metrics = Dictionary(
            uniqueKeysWithValues: Metric.allCases.map {
                ($0.rawValue, measurements[$0, default: Measurement()].json)
            })
        return [
            "schema_version": 1, "measurement_thread_cpu": true,
            "cpu_clock": "CLOCK_THREAD_CPUTIME_ID", "wall_clock": "monotonic_uptime",
            "enabled": enabled, "metrics": metrics,
        ]
    }

    private static func saturatingAdd(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? .max : sum
    }

    private static func nativeClock() -> ClockSample? {
        var threadID: UInt64 = 0
        var cpu = timespec()
        guard pthread_threadid_np(nil, &threadID) == 0,
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu) == 0,
            cpu.tv_sec >= 0, cpu.tv_nsec >= 0, cpu.tv_nsec < 1_000_000_000
        else { return nil }
        let (seconds, overflow) = UInt64(cpu.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let (nanoseconds, additionOverflow) = seconds.addingReportingOverflow(UInt64(cpu.tv_nsec))
        guard !additionOverflow else { return nil }
        return ClockSample(
            threadID: threadID, cpuNanoseconds: nanoseconds,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}
