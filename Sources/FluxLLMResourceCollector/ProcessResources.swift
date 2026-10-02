import Darwin
import FluxLLM
import Foundation

enum CollectorFailure: Error, CustomStringConvertible {
    case message(String)
    case processLookup(pid: Int32, operation: ProcessLookupOperation, errorCode: Int32)

    var description: String {
        switch self {
        case .message(let value): value
        case .processLookup(let pid, .birthTime, let errorCode):
            "Cannot verify PID \(pid) and process birth time (errno \(errorCode))"
        case .processLookup(let pid, .resourceUsage, let errorCode):
            "proc_pid_rusage(\(pid), RUSAGE_INFO_V4) failed (errno \(errorCode))"
        }
    }
}

enum ProcessLookupOperation { case birthTime, resourceUsage }

/// Injectable only to exercise exit-observation ordering without timing stress.
/// Recovery still confirms the real owned child's exit before reading rusage.
struct ExitTransitionObservation {
    var clock: () -> Double = ProcessResources.monotonicSeconds
    var pause: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var hasExited: (ControlledProcess) throws -> Bool = { try $0.hasExited() }
}

/// User/system CPU times returned by proc_pid_rusage are cumulative Mach ticks.
/// Other fields retain their own units; QoS times remain raw because their units
/// are not documented in the local SDK. Keep counters and conversions auditable.
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

    /// Export the existing V4 read without converting integer work counts or
    /// assigning time units to undocumented QoS counters. Zero is raw evidence,
    /// not proof that instruction/cycle accounting is supported by this hardware.
    static func cpuWorkCounters(_ usage: rusage_info_v4) -> [String: Any] {
        let qos: [String: UInt64] = [
            "default": usage.ri_cpu_time_qos_default,
            "maintenance": usage.ri_cpu_time_qos_maintenance,
            "background": usage.ri_cpu_time_qos_background,
            "utility": usage.ri_cpu_time_qos_utility,
            "legacy": usage.ri_cpu_time_qos_legacy,
            "user_initiated": usage.ri_cpu_time_qos_user_initiated,
            "user_interactive": usage.ri_cpu_time_qos_user_interactive,
        ]
        return [
            "schema_version": 1, "source": "proc_pid_rusage/RUSAGE_INFO_V4",
            "instructions": usage.ri_instructions, "cycles": usage.ri_cycles,
            "instructions_unit": "count", "cycles_unit": "count",
            "qos_time_unit": "unspecified_kernel_units", "qos_time_raw": qos,
        ]
    }

    /// Observe the already scheduled CPU calibration, without making CPU-time
    /// availability depend on these optional hardware counters.
    static func cpuWorkCounterObservation(before: rusage_info_v4, after: rusage_info_v4) -> [String:
        Any]
    {
        let monotonic =
            after.ri_instructions >= before.ri_instructions && after.ri_cycles >= before.ri_cycles
        return [
            "source": "proc_pid_rusage/RUSAGE_INFO_V4",
            "instructions_before": before.ri_instructions,
            "instructions_after": after.ri_instructions,
            "cycles_before": before.ri_cycles, "cycles_after": after.ri_cycles,
            "instructions_delta": monotonic
                ? (after.ri_instructions - before.ri_instructions) as Any : NSNull(),
            "cycles_delta": monotonic ? (after.ri_cycles - before.ri_cycles) as Any : NSNull(),
            "monotonic": monotonic,
            "observed_positive": monotonic && after.ri_instructions > before.ri_instructions
                && after.ri_cycles > before.ri_cycles,
        ]
    }

    /// PID reuse is impossible while this collector still owns the unreaped
    /// child. A completed exit can remove BSD birth metadata before a periodic
    /// or buffered control-event sample runs; final rusage remains authoritative.
    func snapshot(
        phase: String, ownedChild child: ControlledProcess, permitZombie: Bool = false,
        recoveryDeadline: Double = .infinity
    ) throws -> [String: Any] {
        guard child.pid == processID, !child.reaped else {
            throw CollectorFailure.message(
                "Resource sampling requires the original owned, unreaped child")
        }
        if permitZombie {
            guard try child.hasExited() else {
                throw CollectorFailure.message(
                    "Final resource sampling requires a confirmed owned-child exit")
            }
            return try snapshot(phase: phase, permitZombie: true)
        }
        do {
            return try snapshot(phase: phase)
        } catch {
            return try recoverSnapshotAfterExit(
                error, phase: phase, ownedChild: child,
                deadline: recoveryDeadline)
        }
    }

    func recoverSnapshotAfterExit(
        _ error: Error, phase: String, ownedChild child: ControlledProcess,
        deadline: Double = .infinity,
        observation: ExitTransitionObservation = ExitTransitionObservation()
    ) throws -> [String: Any] {
        guard let failure = error as? CollectorFailure,
            case .processLookup(let failedPID, _, let errorCode) = failure,
            errorCode == ESRCH, failedPID == processID,
            child.pid == processID, !child.reaped
        else {
            throw error
        }
        let started = observation.clock()
        guard started.isFinite, !deadline.isNaN, started < deadline else { throw error }
        let end = min(deadline, started + 0.1)
        var previous = started
        var observations = 0
        while true {
            let now = observation.clock()
            guard now.isFinite, now >= previous, now < end,
                child.pid == processID, !child.reaped
            else { throw error }
            observations += 1
            if try observation.hasExited(child) {
                // Even a scripted test observation cannot authorize a live or
                // reaped process. WNOWAIT keeps the original PID unreusable.
                guard child.pid == processID, !child.reaped, try child.hasExited() else {
                    throw error
                }
                let confirmedAt = observation.clock()
                guard confirmedAt.isFinite, confirmedAt >= now, confirmedAt < end else {
                    throw error
                }
                // Fresh kernel counters and the saved Mach start counter remain
                // authoritative; no cached counters or missing-identity waiver.
                var result = try snapshot(phase: phase, permitZombie: true)
                result["exit_identity_recovery"] =
                    [
                        "errno": errorCode, "observations": observations,
                        "wait_seconds": confirmedAt - started,
                    ] as [String: Any]
                return result
            }
            let after = observation.clock()
            guard after.isFinite, after >= now, after < end else { throw error }
            previous = after
            observation.pause(min(0.001, end - after))
        }
    }

    func snapshot(phase: String, permitZombie: Bool = false) throws -> [String: Any] {
        let started = Self.monotonicSeconds()
        if !permitZombie, try Self.birthTime(of: processID) != birthTimeMicroseconds {
            throw CollectorFailure.message("The measured process identity changed")
        }
        let usage = try Self.readUsage(processID)
        // Instruments uses Mach absolute time; CLOCK_MONOTONIC has a different
        // origin. Pair them on every sample instead of inferring an offset from
        // wall-clock time or a rounded trace start date.
        let clockBefore = Self.monotonicSeconds()
        let absoluteTicks = mach_absolute_time()
        let clockAfter = Self.monotonicSeconds()
        let timestamp = (clockBefore + clockAfter) / 2
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
            "mach_absolute_ticks": absoluteTicks,
            "mach_absolute_seconds": Double(absoluteTicks) * Double(timebase.numer)
                / Double(timebase.denom) / 1_000_000_000,
            "clock_read_uncertainty_seconds": clockAfter - clockBefore,
            "counter_read_seconds": timestamp - started,
            "cpu_seconds": Self.cpuSeconds(
                userTicks: usage.ri_user_time, systemTicks: usage.ri_system_time,
                numer: timebase.numer, denom: timebase.denom),
            "user_cpu_ticks": usage.ri_user_time, "system_cpu_ticks": usage.ri_system_time,
            "cpu_work_counters": Self.cpuWorkCounters(usage),
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
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, count) == count else {
            throw CollectorFailure.processLookup(pid: pid, operation: .birthTime, errorCode: errno)
        }
        guard info.pbi_pid == UInt32(bitPattern: pid), info.pbi_start_tvsec > 0,
            info.pbi_start_tvsec <= UInt64.max / 1_000_000, info.pbi_start_tvusec < 1_000_000
        else {
            throw CollectorFailure.message(
                "Kernel process birth identity is invalid for PID \(pid)")
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
            throw CollectorFailure.processLookup(
                pid: pid, operation: .resourceUsage, errorCode: errno)
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
            "cpu_work_counter_observation": cpuWorkCounterObservation(before: before, after: after),
            "reason": passed ? NSNull() : "CPU counters failed getrusage calibration" as Any,
        ]
    }
}
