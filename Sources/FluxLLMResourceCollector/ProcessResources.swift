import Darwin
import FluxLLM
import Foundation

enum CollectorFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): value
        }
    }
}

/// Values returned by proc_pid_rusage are cumulative Mach ticks, not nanoseconds.
/// Keep the raw counters and conversion in the report so its units are auditable.
struct ProcessResources {
    let processID: Int32
    let birthTimeMicroseconds: UInt64
    let startAbsoluteTime: UInt64
    let timebase: mach_timebase_info_data_t

    init(processID: Int32) throws {
        self.processID = processID
        birthTimeMicroseconds = try Self.birthTime(of: processID)
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            throw CollectorFailure.message("The CPU Mach timebase is unavailable")
        }
        self.timebase = timebase
        startAbsoluteTime = try Self.readUsage(processID).ri_proc_start_abstime
    }

    var gpuIdentity: GPUProcessIdentity {
        GPUProcessIdentity(pid: processID, startTimeMicroseconds: birthTimeMicroseconds)
    }

    static func monotonicSeconds() -> Double {
        var value = timespec()
        clock_gettime(CLOCK_MONOTONIC, &value)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }

    static func cpuSeconds(
        userTicks: UInt64, systemTicks: UInt64,
        numer: UInt32, denom: UInt32
    ) -> Double {
        (Double(userTicks) + Double(systemTicks)) * Double(numer) / Double(denom) / 1_000_000_000
    }

    func snapshot(phase: String, permitZombie: Bool = false) throws -> [String: Any] {
        let started = Self.monotonicSeconds()
        if !permitZombie, try Self.birthTime(of: processID) != birthTimeMicroseconds {
            throw CollectorFailure.message("The measured process identity changed")
        }
        let usage = try Self.readUsage(processID)
        let timestamp = Self.monotonicSeconds()
        guard usage.ri_proc_start_abstime == startAbsoluteTime else {
            throw CollectorFailure.message("The measured process start counter changed")
        }
        if !permitZombie, try Self.birthTime(of: processID) != birthTimeMicroseconds {
            throw CollectorFailure.message(
                "The measured process identity changed during collection")
        }
        return [
            "type": "sample", "phase": phase,
            "process_id": processID, "birth_time_us": birthTimeMicroseconds,
            "monotonic_seconds": timestamp,
            "counter_read_seconds": timestamp - started,
            "cpu_seconds": Self.cpuSeconds(
                userTicks: usage.ri_user_time, systemTicks: usage.ri_system_time,
                numer: timebase.numer, denom: timebase.denom),
            "user_cpu_ticks": usage.ri_user_time, "system_cpu_ticks": usage.ri_system_time,
            "mach_timebase_numer": timebase.numer, "mach_timebase_denom": timebase.denom,
            "physical_footprint_bytes": usage.ri_phys_footprint,
            "lifetime_peak_footprint_bytes": usage.ri_lifetime_max_phys_footprint,
            "physical_write_bytes": usage.ri_diskio_byteswritten,
            "logical_write_bytes": usage.ri_logical_writes,
            "interrupt_wakeups": usage.ri_interrupt_wkups,
            "package_idle_wakeups": usage.ri_pkg_idle_wkups,
            "physical_writes_unavailable_reason": NSNull(),
            "logical_writes_unavailable_reason": NSNull(),
        ]
    }

    static func birthTime(of pid: Int32) throws -> UInt64 {
        var info = proc_bsdinfo()
        let count = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, count) == count,
            info.pbi_pid == UInt32(bitPattern: pid), info.pbi_start_tvsec > 0,
            info.pbi_start_tvsec <= UInt64.max / 1_000_000, info.pbi_start_tvusec < 1_000_000
        else {
            throw CollectorFailure.message(
                "Cannot verify PID \(pid) and process birth time (errno \(errno))")
        }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    static func readUsage(_ pid: Int32) throws -> rusage_info_v4 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else {
            throw CollectorFailure.message(
                "proc_pid_rusage(\(pid), RUSAGE_INFO_V4) failed (errno \(errno))")
        }
        return usage
    }

    /// Runs only in the external observer, before the app launches. A busy interval
    /// makes a wrong nanosecond/Mach-tick conversion detectable on Apple silicon.
    static func calibrateCPU() throws -> [String: Any] {
        func selfCPU() throws -> Double {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else {
                throw CollectorFailure.message("getrusage calibration failed")
            }
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let probe = try ProcessResources(processID: getpid())
        let expectedBefore = try selfCPU()
        let before = try readUsage(getpid())
        let deadline = monotonicSeconds() + 0.08
        while monotonicSeconds() < deadline { _ = getpid() }
        let after = try readUsage(getpid())
        let expected = try selfCPU() - expectedBefore
        let measured = cpuSeconds(
            userTicks: after.ri_user_time - before.ri_user_time,
            systemTicks: after.ri_system_time - before.ri_system_time,
            numer: probe.timebase.numer, denom: probe.timebase.denom)
        let passed = expected >= 0.005 && abs(measured - expected) <= max(0.002, expected * 0.05)
        return [
            "available": passed, "reference_cpu_seconds": expected,
            "measured_cpu_seconds": measured,
            "mach_timebase_numer": probe.timebase.numer,
            "mach_timebase_denom": probe.timebase.denom,
            "reason": passed ? NSNull() : "CPU counters failed getrusage calibration" as Any,
        ]
    }
}
