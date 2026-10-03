import CoreFoundation
import Darwin
import Foundation

/// Diagnostic-only accounting for explicitly registered, stable app threads.
/// PROC_PIDTHREADID64INFO accepts pthread_threadid_np identities; thread names
/// are deliberately never used as a fallback. The raw unit is calibrated in a
/// separate owned child before launching the measured application.
final class ThreadCPUResources {
    static let source = "proc_pidinfo/PROC_PIDTHREADID64INFO"
    let probe: ProcessResources
    let calibration: ThreadCPUCalibration
    private var roles: [String: UInt64]?
    fileprivate var failure: String?
    private var ready = false
    private var previous: [String: (UInt64, UInt64)] = [:]

    init(probe: ProcessResources, calibration: ThreadCPUCalibration) {
        self.probe = probe
        self.calibration = calibration
    }

    func ingest(_ event: [String: Any]) {
        let isReady = event["type"] as? String == "ready"
        guard let snapshot = event["snapshot"] as? [String: Any] else {
            if isReady {
                ready = true
                invalidate("Ready event omitted the thread registration snapshot")
            }
            return
        }
        if isReady { ready = true }
        guard let registration = snapshot["thread_cpu_registration"] else {
            if ready { invalidate("Application snapshot omitted its registered thread identities") }
            return
        }
        do {
            let validated = try Self.validateRegistration(registration, processID: probe.processID)
            if let roles, roles != validated {
                throw CollectorFailure.message("Registered thread identities changed")
            }
            roles = validated
        } catch { invalidate(String(describing: error)) }
    }

    private func invalidate(_ reason: String) { if failure == nil { failure = reason } }

    static func integer(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let result = UInt64(number.stringValue)
        else { return nil }
        return result
    }

    static func validateRegistration(_ value: Any, processID: Int32) throws -> [String: UInt64] {
        guard let value = value as? [String: Any], integer(value["schema_version"]) == 1,
            integer(value["process_id"]) == UInt64(processID),
            let entries = value["roles"] as? [String: Any], Set(entries.keys) == ["main", "nio"],
            let main = integer(entries["main"]), let nio = integer(entries["nio"]),
            main > 0, nio > 0, main != nio
        else {
            throw CollectorFailure.message(
                "Invalid, incomplete, or misattributed thread CPU registration")
        }
        return ["main": main, "nio": nio]
    }

    func snapshot(ownedChild child: ControlledProcess) -> [String: Any]? {
        guard ready else { return nil }
        // Exited threads have no final retained counter. Process accounting still
        // has the existing authoritative zombie read, independently of this probe.
        if (try? child.hasExited()) == true { return nil }
        var result: [String: Any] = [
            "schema_version": 1, "source": Self.source, "process_id": probe.processID,
            "birth_time_us": probe.birthTimeMicroseconds, "calibration": calibration.summary,
            "timebase": ["numer": probe.timebase.numer, "denom": probe.timebase.denom],
        ]
        do {
            let observerBefore = try ThreadCPUCalibration.threadClockNS()
            if let failure { throw CollectorFailure.message(failure) }
            guard let roles, child.pid == probe.processID, !child.reaped,
                try ProcessResources.birthTime(of: probe.processID) == probe.birthTimeMicroseconds
            else {
                throw CollectorFailure.message(
                    "Thread CPU collection lost the owned process identity")
            }
            let begin = mach_absolute_time()
            let before = try ProcessResources.readUsage(probe.processID)
            var rows: [[String: Any]] = []
            var values: [String: (UInt64, UInt64)] = [:]
            for role in ["main", "nio"] {
                let identifier = roles[role]!
                let raw = try Self.read(processID: probe.processID, threadID: identifier)
                let user = try calibration.convert(raw.pth_user_time)
                let system = try calibration.convert(raw.pth_system_time)
                if let old = previous[role], user < old.0 || system < old.1 {
                    throw CollectorFailure.message(
                        "Registered thread CPU counter reset for \(role)")
                }
                values[role] = (user, system)
                rows.append([
                    "role": role, "thread_id": identifier,
                    "user_cpu_ns": user, "system_cpu_ns": system,
                    "user_cpu_raw": raw.pth_user_time, "system_cpu_raw": raw.pth_system_time,
                ])
            }
            let after = try ProcessResources.readUsage(probe.processID)
            let end = mach_absolute_time()
            guard before.ri_proc_start_abstime == probe.startAbsoluteTime,
                after.ri_proc_start_abstime == probe.startAbsoluteTime,
                try ProcessResources.birthTime(of: probe.processID) == probe.birthTimeMicroseconds
            else {
                throw CollectorFailure.message("Thread CPU read changed process identity")
            }
            let processBefore = try ThreadCPUCalibration.processNS(before, timebase: probe.timebase)
            let processAfter = try ThreadCPUCalibration.processNS(after, timebase: probe.timebase)
            let observerAfter = try ThreadCPUCalibration.threadClockNS()
            guard processAfter >= processBefore, end >= begin, observerAfter >= observerBefore
            else {
                throw CollectorFailure.message("Thread CPU read bracket contains a reset counter")
            }
            previous = values
            result.merge([
                "available": true, "read_begin_mach_ticks": begin, "read_end_mach_ticks": end,
                "process_cpu_before_ns": processBefore, "process_cpu_after_ns": processAfter,
                "observer_cpu_ns": observerAfter - observerBefore, "threads": rows,
            ]) { _, new in new }
        } catch {
            invalidate(String(describing: error))
            result["available"] = false
            result["reason"] = failure ?? String(describing: error)
        }
        return result
    }

    static func read(processID: Int32, threadID: UInt64) throws -> proc_threadinfo {
        var info = proc_threadinfo()
        let size = Int32(MemoryLayout<proc_threadinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTHREADID64INFO, threadID, &info, size) == size else {
            throw CollectorFailure.message(
                "External thread CPU read failed for PID \(processID), thread \(threadID) (errno \(errno))"
            )
        }
        return info
    }
}

struct ThreadCPUCalibration {
    let numerator: UInt32
    let denominator: UInt32
    let evidence: [String: Any]

    var summary: [String: Any] {
        evidence.filter {
            ["available", "source", "raw_unit", "conversion_numer", "conversion_denom"].contains(
                $0.key)
        }
    }

    func convert(_ value: UInt64) throws -> UInt64 {
        try Self.scale(value, numerator: numerator, denominator: denominator)
    }

    static func scale(_ value: UInt64, numerator: UInt32, denominator: UInt32) throws -> UInt64 {
        guard numerator > 0, denominator > 0 else {
            throw CollectorFailure.message("Invalid thread CPU conversion")
        }
        let (whole, overflow) = (value / UInt64(denominator)).multipliedReportingOverflow(
            by: UInt64(numerator))
        let remainder = (value % UInt64(denominator)) * UInt64(numerator) / UInt64(denominator)
        let (result, additionOverflow) = whole.addingReportingOverflow(remainder)
        guard !overflow, !additionOverflow else {
            throw CollectorFailure.message("Thread CPU conversion overflow")
        }
        return result
    }

    static func processNS(_ value: rusage_info_v4, timebase: mach_timebase_info_data_t) throws
        -> UInt64
    {
        let (raw, overflow) = value.ri_user_time.addingReportingOverflow(value.ri_system_time)
        guard !overflow else { throw CollectorFailure.message("Process CPU sum overflow") }
        return try scale(raw, numerator: timebase.numer, denominator: timebase.denom)
    }

    static func threadClockNS() throws -> UInt64 {
        var value = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0, value.tv_sec >= 0,
            value.tv_nsec >= 0
        else {
            throw CollectorFailure.message("CLOCK_THREAD_CPUTIME_ID unavailable")
        }
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private static func selfUsageNS() throws -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw CollectorFailure.message("Thread calibration getrusage failed")
        }
        return UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
            + UInt64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1_000
    }

    /// The observer owns this helper and reads its thread externally. A quiet
    /// phase proves CPU time is not elapsed time; a burst phase verifies units
    /// outside a continuous busy loop. All counter evidence is retained.
    static func run(deadlineSeconds: Double = 10) throws -> ThreadCPUCalibration {
        let started = ProcessResources.monotonicSeconds()
        let deadline = started + min(10, deadlineSeconds)
        let child = try ControlledProcess(
            executable: CommandLine.arguments[0],
            environment: ProcessInfo.processInfo.environment,
            arguments: ["--thread-cpu-calibration-worker"])
        defer { child.terminate() }
        let probe = try ProcessResources(processID: child.pid)
        try child.resume()
        var buffer = Data()
        func reply() throws -> [String: Any] {
            while ProcessResources.monotonicSeconds() < deadline {
                buffer.append(try readAvailable(child.eventDescriptor))
                if let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard
                        let value = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                        value["error"] == nil
                    else { throw CollectorFailure.message("Invalid thread calibration reply") }
                    return value
                }
                if try child.hasExited() {
                    throw CollectorFailure.message("Thread calibration worker exited early")
                }
                var descriptor = pollfd(
                    fd: child.eventDescriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 20)
            }
            throw CollectorFailure.message("Thread CPU calibration exceeded its fixed deadline")
        }
        let ready = try reply()
        guard ready["event"] as? String == "ready",
            ThreadCPUResources.integer(ready["process_id"]) == UInt64(child.pid),
            let identifier = ThreadCPUResources.integer(ready["thread_id"]), identifier > 0
        else {
            throw CollectorFailure.message("Thread CPU calibration worker identity is invalid")
        }
        var phases: [[String: Any]] = []
        var conversion: (UInt32, UInt32, String)?
        for mode in ["continuous", "bursty", "idle"] {
            let processBefore = try processNS(
                ProcessResources.readUsage(child.pid), timebase: probe.timebase)
            let before = try ThreadCPUResources.read(processID: child.pid, threadID: identifier)
            let wallBefore = ProcessResources.monotonicSeconds()
            try writeAll(jsonLine(["command": mode]), to: child.commandDescriptor)
            let response = try reply()
            let after = try ThreadCPUResources.read(processID: child.pid, threadID: identifier)
            let processAfter = try processNS(
                ProcessResources.readUsage(child.pid), timebase: probe.timebase)
            guard response["event"] as? String == mode,
                let reference = ThreadCPUResources.integer(response["thread_clock_delta_ns"]),
                let getrusage = ThreadCPUResources.integer(response["getrusage_delta_ns"]),
                after.pth_user_time >= before.pth_user_time,
                after.pth_system_time >= before.pth_system_time, processAfter >= processBefore
            else {
                throw CollectorFailure.message(
                    "Thread CPU calibration received invalid or reset counters")
            }
            let raw =
                (after.pth_user_time - before.pth_user_time)
                + (after.pth_system_time - before.pth_system_time)
            func agrees(_ measured: UInt64, _ expected: UInt64) -> Bool {
                abs(Double(measured) - Double(expected)) <= max(2_000_000, Double(expected) * 0.05)
            }
            if conversion == nil {
                guard reference >= 50_000_000 else {
                    throw CollectorFailure.message(
                        "Thread calibration did not perform enough CPU work")
                }
                let nsMatches = agrees(raw, reference)
                let machMatches = agrees(
                    try scale(
                        raw, numerator: probe.timebase.numer, denominator: probe.timebase.denom),
                    reference)
                if probe.timebase.numer == probe.timebase.denom, nsMatches {
                    conversion = (1, 1, "nanoseconds")
                } else if nsMatches != machMatches {
                    conversion =
                        nsMatches
                        ? (1, 1, "nanoseconds")
                        : (probe.timebase.numer, probe.timebase.denom, "mach_ticks")
                } else {
                    throw CollectorFailure.message(
                        "Thread CPU units failed independent calibration or were ambiguous")
                }
            }
            let measured = try scale(raw, numerator: conversion!.0, denominator: conversion!.1)
            let process = processAfter - processBefore
            let passed =
                agrees(measured, reference) && agrees(getrusage, reference)
                && agrees(process, reference)
                && (mode != "idle" || (reference < 5_000_000 && measured < 5_000_000))
                && (mode != "bursty" || reference >= 30_000_000)
            phases.append([
                "name": mode, "passed": passed, "thread_raw_delta": raw,
                "thread_clock_delta_ns": reference, "getrusage_delta_ns": getrusage,
                "process_cpu_delta_ns": process, "measured_thread_cpu_ns": measured,
                "wall_seconds": ProcessResources.monotonicSeconds() - wallBefore,
            ])
            guard passed else {
                throw CollectorFailure.message(
                    "Thread CPU calibration failed for \(mode): \(phases.last!)")
            }
        }
        let overheadCPU = try threadClockNS()
        let overheadWall = mach_absolute_time()
        let readCount = 200
        for _ in 0..<readCount {
            _ = try ThreadCPUResources.read(processID: child.pid, threadID: identifier)
        }
        let cpuNS = try threadClockNS() - overheadCPU
        let wallNS = try scale(
            mach_absolute_time() - overheadWall, numerator: probe.timebase.numer,
            denominator: probe.timebase.denom)
        // Join a real short-lived thread in the helper, then verify its ID fails.
        try writeAll(jsonLine(["command": "dead_thread"]), to: child.commandDescriptor)
        let dead = try reply()
        guard let deadID = ThreadCPUResources.integer(dead["thread_id"]), deadID > 0 else {
            throw CollectorFailure.message("Dead-thread self-test omitted its identity")
        }
        do {
            _ = try ThreadCPUResources.read(processID: child.pid, threadID: deadID)
            throw CollectorFailure.message("A terminated thread unexpectedly produced CPU counters")
        } catch let error as CollectorFailure {
            guard error.description.contains("External thread CPU read failed") else { throw error }
        }
        try writeAll(jsonLine(["command": "exit"]), to: child.commandDescriptor)
        while !(try child.hasExited()), ProcessResources.monotonicSeconds() < deadline {
            var descriptor = pollfd(fd: child.eventDescriptor, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 10)
        }
        guard try child.hasExited(), try child.reap().status == 0 else {
            throw CollectorFailure.message("Thread CPU calibration helper failed to exit")
        }
        let selected = conversion!
        return ThreadCPUCalibration(
            numerator: selected.0, denominator: selected.1,
            evidence: [
                "available": true, "source": ThreadCPUResources.source,
                "reference": "CLOCK_THREAD_CPUTIME_ID/getrusage/owned-process-rusage",
                "process_id": child.pid, "birth_time_us": probe.birthTimeMicroseconds,
                "thread_id": identifier,
                "timebase": ["numer": probe.timebase.numer, "denom": probe.timebase.denom],
                "raw_unit": selected.2, "conversion_numer": selected.0,
                "conversion_denom": selected.1,
                "tolerance_relative": 0.05, "tolerance_absolute_ns": 2_000_000,
                "phases": phases, "external_owned_child": true, "dead_thread_rejected": true,
                "observer_overhead": ["read_count": readCount, "cpu_ns": cpuNS, "wall_ns": wallNS],
                "elapsed_seconds": ProcessResources.monotonicSeconds() - started,
            ])
    }

    static func runWorker() -> Int32 {
        do {
            var identifier: UInt64 = 0
            guard pthread_threadid_np(nil, &identifier) == 0 else { return 2 }
            try writeAll(
                jsonLine(["event": "ready", "process_id": getpid(), "thread_id": identifier]), to: 4
            )
            var buffer = Data()
            while true {
                var byte: UInt8 = 0
                let count = read(3, &byte, 1)
                if count < 0, errno == EINTR { continue }
                guard count == 1, buffer.count < 1024 else { return 2 }
                if byte != 10 {
                    buffer.append(byte)
                    continue
                }
                guard
                    let command = try JSONSerialization.jsonObject(with: buffer)
                        as? [String: String],
                    let mode = command["command"]
                else { return 2 }
                buffer.removeAll(keepingCapacity: true)
                if mode == "exit" { return 0 }
                if mode == "dead_thread" {
                    let output = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
                    output.initialize(to: 0)
                    defer {
                        output.deinitialize(count: 1)
                        output.deallocate()
                    }
                    var thread: pthread_t?
                    guard
                        pthread_create(
                            &thread, nil,
                            { pointer in
                                _ = pthread_threadid_np(
                                    nil, pointer.assumingMemoryBound(to: UInt64.self))
                                return nil
                            }, output) == 0, let thread, pthread_join(thread, nil) == 0
                    else { return 2 }
                    try writeAll(jsonLine(["event": mode, "thread_id": output.pointee]), to: 4)
                    continue
                }
                let usageBefore = try selfUsageNS()
                let before = try threadClockNS()
                func busy(_ target: UInt64) throws {
                    let origin = try threadClockNS()
                    let deadline = ProcessResources.monotonicSeconds() + 2
                    while try threadClockNS() - origin < target {
                        guard ProcessResources.monotonicSeconds() < deadline else {
                            throw CollectorFailure.message("Thread calibration worker timed out")
                        }
                        for _ in 0..<128 { _ = getpid() }
                    }
                }
                switch mode {
                case "continuous": try busy(100_000_000)
                case "bursty":
                    for _ in 0..<8 {
                        try busy(5_000_000)
                        usleep(15_000)
                    }
                case "idle": usleep(100_000)
                default: return 2
                }
                let elapsed = try threadClockNS() - before
                let usage = try selfUsageNS() - usageBefore
                try writeAll(
                    jsonLine([
                        "event": mode, "thread_clock_delta_ns": elapsed,
                        "getrusage_delta_ns": usage,
                    ]), to: 4)
            }
        } catch {
            try? writeAll(jsonLine(["error": String(describing: error)]), to: 4)
            return 2
        }
    }

    static func verifyRegistrationAndConversion() throws {
        let valid: [String: Any] = [
            "schema_version": 1, "process_id": getpid(), "roles": ["main": 100, "nio": 101],
        ]
        _ = try ThreadCPUResources.validateRegistration(valid, processID: getpid())
        let invalid: [[String: Any]] = [
            ["schema_version": true, "process_id": getpid(), "roles": ["main": 100, "nio": 101]],
            ["schema_version": 1, "process_id": getpid() + 1, "roles": ["main": 100, "nio": 101]],
            ["schema_version": 1, "process_id": getpid(), "roles": ["main": 100, "nio": 100]],
            ["schema_version": 1, "process_id": getpid(), "roles": ["main": 100]],
            ["schema_version": 1, "process_id": getpid(), "roles": ["main": 0, "nio": 101]],
            ["schema_version": 1, "process_id": getpid(), "roles": ["main": 100.5, "nio": 101]],
        ]
        for value in invalid {
            var rejected = false
            do { _ = try ThreadCPUResources.validateRegistration(value, processID: getpid()) } catch
            { rejected = true }
            guard rejected else {
                throw CollectorFailure.message("Malformed thread registration was accepted")
            }
        }
        let scale = try Self.scale(24_000_000, numerator: 125, denominator: 3)
        guard scale == 1_000_000_000 else {
            throw CollectorFailure.message("Thread CPU rational conversion failed")
        }
        var overflowRejected = false
        do { _ = try Self.scale(UInt64.max, numerator: 125, denominator: 3) } catch {
            overflowRejected = true
        }
        guard overflowRejected else {
            throw CollectorFailure.message("Thread CPU overflow was accepted")
        }
        let probe = try ProcessResources(processID: getpid())
        let collector = ThreadCPUResources(
            probe: probe, calibration: .init(numerator: 1, denominator: 1, evidence: [:]))
        collector.ingest(["type": "ready", "snapshot": ["thread_cpu_registration": valid]])
        var changed = valid
        changed["roles"] = ["main": 100, "nio": 102]
        collector.ingest(["type": "snapshot", "snapshot": ["thread_cpu_registration": changed]])
        guard collector.failure == "Registered thread identities changed" else {
            throw CollectorFailure.message(
                "Changed registered roles did not invalidate thread accounting")
        }
        collector.ingest(["type": "snapshot", "snapshot": ["thread_cpu_registration": valid]])
        guard collector.failure == "Registered thread identities changed" else {
            throw CollectorFailure.message(
                "A later registration incorrectly cleared a thread identity failure")
        }
        let missing = ThreadCPUResources(
            probe: probe, calibration: .init(numerator: 1, denominator: 1, evidence: [:]))
        missing.ingest(["type": "ready", "snapshot": [:] as [String: Any]])
        guard missing.failure != nil else {
            throw CollectorFailure.message("Missing ready registration was accepted")
        }
    }
}
