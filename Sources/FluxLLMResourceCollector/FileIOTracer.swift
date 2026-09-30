import Darwin
import Foundation

// Preserve the field names in the performance JSON protocol.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct TraceCapability: Codable, Sendable {
    let available: Bool
    let reason: String?
    let timestamp_attribution: Bool
    let timestamp_unavailable_reason: String?

    init(
        available: Bool,
        reason: String?,
        timestamp_attribution: Bool = false,
        timestamp_unavailable_reason: String? = "Filesystem timestamp calibration has not run."
    ) {
        self.available = available
        self.reason = reason
        self.timestamp_attribution = timestamp_attribution
        self.timestamp_unavailable_reason = timestamp_unavailable_reason
    }
}

/// fs_usage is supplementary evidence for direct and delegated filesystem
/// writes. Its wide process suffix is a THREAD ID, not a PID. The kernel-side
/// PID filter identifies the app; only namespace-matched cfprefsd paths are
/// attributed to it. Unknown or ambiguous evidence invalidates coverage.
@MainActor
final class FileIOTracer {
    private(set) var capability = TraceCapability(
        available: false, reason: "Filesystem tracing has not started.",
        timestamp_attribution: false,
        timestamp_unavailable_reason: "Filesystem timestamp calibration has not run.")
    private let targetPID: Int32?
    private let targetName: String?
    private let namespaces: [String]
    private let proofName = "flx-proof-" + UUID().uuidString.prefix(12)
    private var process: Process?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var pending = Data()
    private var events: [[String: Any]] = []
    private var proofObserved = false
    private var failure: String?
    private var stopping = false
    private var descriptors: [String: [String: String]] = [:]
    private var clockOrigin: ClockOrigin?
    private var proofWriteBrackets: [ClosedRange<Double>] = []
    private var timestampFailure: String?

    init(targetPID: Int32?, runID: String?, storageRoot: String?) {
        self.targetPID = targetPID
        targetName = targetPID.flatMap(Self.processName)
        var names: [String] = []
        if let runID, !runID.isEmpty {
            let normalizedID = UUID(uuidString: runID)?.uuidString ?? runID
            names += ["FluxLLM.Performance.\(normalizedID)", normalizedID]
            if let storageRoot, !storageRoot.isEmpty {
                names.append(
                    URL(fileURLWithPath: storageRoot).appendingPathComponent(normalizedID)
                        .standardizedFileURL.path)
            }
        }
        namespaces = names
    }

    func start() async -> TraceCapability {
        guard process == nil else { return capability }
        guard targetPID == nil || targetName != nil else {
            invalidate("Could not verify the app process name for the filesystem PID filter.")
            return capability
        }
        let tool = "/usr/bin/fs_usage"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            invalidate("fs_usage is unavailable on this machine.")
            return capability
        }
        let child = Process()
        var arguments = ["-w", "-f", "filesys", "-t", "300", String(getpid()), "cfprefsd"]
        if let targetPID { arguments.append(String(targetPID)) }
        if geteuid() == 0 {
            child.executableURL = URL(fileURLWithPath: tool)
            child.arguments = arguments
        } else {
            child.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            child.arguments = ["-n", tool] + arguments
        }
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        // fs_usage prints time of day without a timezone or date. The proof
        // write below verifies that the child actually honored this setting;
        // merely putting TZ in sudo's input environment is not proof.
        environment["TZ"] = "UTC"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        child.standardOutput = out
        child.standardError = err
        do {
            clockOrigin = try ClockOrigin.capture()
            try child.run()
            process = child
            output = out.fileHandleForReading
            errors = err.fileHandleForReading
            for descriptor in [output!.fileDescriptor, errors!.fileDescriptor] {
                guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0
                else {
                    throw CollectorFailure.message("Cannot make trace collection nonblocking")
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            // A unique observed collector write proves that kernel tracing is
            // ready. Merely seeing a live sudo/fs_usage process proves nothing.
            while ProcessInfo.processInfo.systemUptime < deadline, failure == nil, !proofObserved {
                try makeProofWrite()
                try await Task.sleep(for: .milliseconds(50))
                readOutput()
                if !child.isRunning { break }
            }
            if !proofObserved, failure == nil {
                invalidate(
                    "Filesystem tracing did not observe its proof write within two seconds; noninteractive root authorization or tracing support is unavailable."
                )
            }
            if proofObserved, failure == nil {
                capability = TraceCapability(
                    available: true, reason: nil,
                    timestamp_attribution: true, timestamp_unavailable_reason: nil)
            }
        } catch {
            invalidate("Filesystem trace launch/readiness failed: \(error.localizedDescription)")
        }
        if !capability.available { await stop() }
        return capability
    }

    /// Consumers must inspect capability after every drain and again after stop:
    /// losing events invalidates the whole zero-write assertion retroactively.
    func drain() -> [[String: Any]] {
        readOutput()
        let result = events
        events.removeAll(keepingCapacity: true)
        return result
    }

    func stop() async {
        guard let child = process, !stopping else { return }
        stopping = true
        readOutput()
        if child.isRunning { child.interrupt() }
        for _ in 0..<10 {
            readOutput()
            if !child.isRunning { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if child.isRunning { child.terminate() }
        for _ in 0..<10 {
            readOutput()
            if !child.isRunning { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if child.isRunning {
            invalidate(
                "The privileged filesystem tracer did not acknowledge shutdown; its hard timeout remains active."
            )
        } else {
            child.waitUntilExit()
        }
        readOutput()
        if !pending.isEmpty { invalidate("Filesystem tracing ended with a truncated event.") }
        try? output?.close()
        try? errors?.close()
        output = nil
        errors = nil
        try? FileManager.default.removeItem(atPath: "/private/tmp/\(proofName)")
    }

    private func invalidate(_ reason: String) {
        if failure == nil { failure = reason }
        capability = TraceCapability(
            available: false, reason: failure,
            timestamp_attribution: false, timestamp_unavailable_reason: timestampFailure ?? failure)
    }

    private func invalidateTimestamp(_ reason: String) {
        if timestampFailure == nil { timestampFailure = reason }
        invalidate(reason)
    }

    private func readOutput() {
        guard let output, let errors else { return }
        do {
            if let clockOrigin, !clockOrigin.isStillValid() {
                invalidateTimestamp(
                    "Wall time diverged from the monotonic clock; filesystem event times cannot be attributed safely."
                )
            }
            let diagnostics = try readAvailable(errors.fileDescriptor)
            if !diagnostics.isEmpty {
                // Do not copy privileged diagnostic output or unrelated paths
                // into reports. A stderr stream invalidates coverage.
                invalidate(
                    "fs_usage reported an error, missing privileges, or unsupported tracing.")
            }
            pending.append(try readAvailable(output.fileDescriptor))
            guard pending.count <= 1_048_576 else {
                invalidate("Filesystem trace exceeded its bounded collection buffer.")
                pending.removeAll()
                return
            }
            while let newline = pending.firstIndex(of: 10) {
                let bytes = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                guard let line = String(data: bytes, encoding: .utf8) else {
                    invalidate("Filesystem trace contained an undecodable event.")
                    continue
                }
                consume(line)
            }
            if let process, !process.isRunning, !stopping {
                invalidate(
                    "Filesystem tracing exited before the complete application lifecycle was observed."
                )
            }
        } catch {
            invalidate("Filesystem trace collection failed: \(error.localizedDescription)")
        }
    }

    private func consume(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        if ["overrun", "dropped", "lost events", "error:", "ktrace_start"].contains(
            where: lower.contains)
        {
            invalidate(
                "Filesystem tracing reported lost events or an unsupported tracing operation.")
            return
        }
        guard
            let match = Self.linePattern.firstMatch(
                in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
            let timestampRange = Range(match.range(at: 1), in: trimmed),
            let operationRange = Range(match.range(at: 2), in: trimmed),
            let detailRange = Range(match.range(at: 3), in: trimmed),
            let processRange = Range(match.range(at: 4), in: trimmed)
        else {
            invalidate("Filesystem tracing emitted an unknown event format.")
            return
        }
        let operation = String(trimmed[operationRange])
        let sourceTimestamp = String(trimmed[timestampRange])
        let detail = String(trimmed[detailRange])
        let name = String(trimmed[processRange])
        let normalized = operation.lowercased()
        let descriptor = Self.capture(Self.descriptorPattern, in: detail)
        let path = Self.path(in: detail)
        // Multiple cfprefsd PIDs share this displayed name; the suffix is only
        // a thread ID. Never join one daemon's descriptor with another's path.
        if name != "cfprefsd", let path, let descriptor {
            descriptors[name, default: [:]][descriptor] = path
        }
        let resolvedPath =
            path ?? (name == "cfprefsd" ? nil : descriptor.flatMap { descriptors[name]?[$0] })
        if normalized == "close" || normalized == "guarded_close_np", let descriptor {
            descriptors[name]?[descriptor] = nil
        }
        let proof = detail.contains(proofName) || resolvedPath?.contains(proofName) == true
        let isApp = targetName == name
        let isDelegated = targetPID != nil && name == "cfprefsd"
        guard proof || isApp || isDelegated else { return }

        let classification = Self.classify(normalized, detail: detail)
        if proof, normalized == "write" {
            guard let timing = convertedTimestamp(sourceTimestamp),
                proofWriteBrackets.contains(where: {
                    timing.monotonicSeconds >= $0.lowerBound - timing.uncertaintySeconds
                        && timing.monotonicSeconds <= $0.upperBound + timing.uncertaintySeconds
                })
            else {
                invalidateTimestamp(
                    "The filesystem proof-write timestamp did not match its actual monotonic write bracket; timezone or timestamp semantics are unverified."
                )
                return
            }
            proofObserved = timestampFailure == nil
            return
        }
        guard !proof else { return }
        guard classification != .unknown else {
            invalidate(
                "Filesystem tracing encountered an unclassified operation for a relevant process.")
            return
        }
        guard classification == .write else { return }
        let namespaceMatch = namespaces.contains { token in
            detail.contains(token) || resolvedPath?.contains(token) == true
        }
        if isDelegated, !namespaceMatch {
            // An explicitly unrelated path is safe to omit. A pathless write
            // cannot establish which preferences client requested it; guessing
            // would either expose unrelated paths or manufacture a zero.
            if resolvedPath == nil {
                invalidate(
                    "A delegated preferences write could not be attributed to a complete path.")
            }
            return
        }
        guard events.count < 8_192 else {
            invalidate("Filesystem write events exceeded their bounded collection buffer.")
            return
        }
        var reportedDetail = detail
        if path == nil, let resolvedPath { reportedDetail += " \(resolvedPath)" }
        let timing = convertedTimestamp(sourceTimestamp)
        let timestampReason: Any
        if let timestampFailure {
            timestampReason = timestampFailure
        } else if !proofObserved {
            timestampReason = "Filesystem timestamp proof has not completed."
        } else {
            timestampReason = NSNull()
        }
        var event: [String: Any] = [
            "type": "file_io", "is_write": true,
            "source": isApp ? "app" : "delegated",
            "operation": operation, "detail": reportedDetail,
            "path": resolvedPath as Any? ?? NSNull(),
            "source_timestamp": sourceTimestamp,
            "timestamp_attribution": proofObserved && timestampFailure == nil && timing != nil,
            "timestamp_unavailable_reason": timestampReason,
        ]
        // Arrival time is deliberately never substituted for the event's
        // timestamp: buffered output can cross a logging-mode boundary.
        if let timing, proofObserved, timestampFailure == nil {
            event["monotonic_seconds"] = timing.monotonicSeconds
            event["timestamp_uncertainty_seconds"] = timing.uncertaintySeconds
        }
        events.append(event)
    }

    private func convertedTimestamp(_ timestamp: String) -> EventTiming? {
        guard timestampFailure == nil else { return nil }
        guard let clockOrigin,
            let observedAt = try? Self.monotonicTime(),
            let timing = clockOrigin.convert(timestamp, observedAt: observedAt)
        else {
            invalidateTimestamp(
                "A filesystem timestamp could not be resolved to one UTC day within the observed lifecycle."
            )
            return nil
        }
        return timing
    }

    private func makeProofWrite() throws {
        let location = "/private/tmp/\(proofName)"
        let descriptor = open(location, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CollectorFailure.message("Cannot create filesystem trace proof")
        }
        defer { close(descriptor) }
        var value: UInt8 = 1
        let started = try Self.monotonicTime()
        let written = write(descriptor, &value, 1)
        let finished = try Self.monotonicTime()
        guard finished >= started else {
            throw CollectorFailure.message("The filesystem proof monotonic clock moved backwards")
        }
        proofWriteBrackets.append(started...finished)
        guard written == 1, fsync(descriptor) == 0 else {
            throw CollectorFailure.message("Cannot write filesystem trace proof")
        }
    }

    private struct EventTiming {
        let monotonicSeconds: Double
        let uncertaintySeconds: Double
    }

    /// All externally reported timestamps share the app/collector/runner's
    /// exact clock domain. ProcessInfo.systemUptime is only used for the local
    /// readiness timeout, never for event attribution or proof brackets.
    private nonisolated static func monotonicTime() throws -> Double {
        var instant = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &instant) == 0,
            instant.tv_sec >= 0, instant.tv_nsec >= 0, instant.tv_nsec < 1_000_000_000
        else { throw CollectorFailure.message("Cannot read the filesystem event monotonic clock") }
        return Double(instant.tv_sec) + Double(instant.tv_nsec) / 1_000_000_000
    }

    private struct ClockOrigin {
        let wallSeconds: Double
        let monotonicSeconds: Double
        let uncertaintySeconds: Double

        // Include the allowed clock drift in every reported event's timing
        // uncertainty. The runner must reject boundary-overlapping writes.
        static let maximumDriftSeconds = 0.010
        static let maximumReadSpanSeconds = 0.010

        static func capture() throws -> ClockOrigin {
            let before = try FileIOTracer.monotonicTime()
            let wall = Date().timeIntervalSince1970
            let after = try FileIOTracer.monotonicTime()
            guard after >= before, after - before <= maximumReadSpanSeconds else {
                throw CollectorFailure.message(
                    "Cannot establish a sufficiently precise filesystem wall/monotonic clock origin"
                )
            }
            return ClockOrigin(
                wallSeconds: wall, monotonicSeconds: (before + after) / 2,
                uncertaintySeconds: (after - before) / 2)
        }

        func isStillValid() -> Bool {
            guard let current = try? Self.capture() else { return false }
            let wallDelta = current.wallSeconds - wallSeconds
            let monotonicDelta = current.monotonicSeconds - monotonicSeconds
            return monotonicDelta >= 0
                && abs(wallDelta - monotonicDelta) + uncertaintySeconds + current.uncertaintySeconds
                    <= Self.maximumDriftSeconds
        }

        func convert(_ timestamp: String, observedAt: Double) -> EventTiming? {
            let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3,
                let hours = Int(parts[0]), (0...23).contains(hours),
                let minutes = Int(parts[1]), (0...59).contains(minutes),
                let seconds = Double(parts[2]), seconds >= 0, seconds < 60,
                let decimal = parts[2].firstIndex(of: ".")
            else { return nil }
            let fractionalDigits = parts[2].distance(
                from: parts[2].index(after: decimal), to: parts[2].endIndex)
            guard (3...9).contains(fractionalDigits), observedAt >= monotonicSeconds,
                observedAt - monotonicSeconds < 86_400
            else { return nil }
            let precision = pow(10.0, -Double(fractionalDigits))
            let uncertainty = uncertaintySeconds + Self.maximumDriftSeconds + precision
            let timeOfDay = Double(hours * 3_600 + minutes * 60) + seconds
            let originUTCDay = floor(wallSeconds / 86_400) * 86_400
            // The trace lasts at most 300 seconds. Adjacent UTC dates handle
            // midnight without assuming kernel events arrive in timestamp order.
            // Receipt time only bounds possible dates; it is not the event time.
            let candidates = [-1.0, 0, 1].map { dayOffset in
                monotonicSeconds + originUTCDay + dayOffset * 86_400 + timeOfDay - wallSeconds
            }.filter {
                $0 >= monotonicSeconds - uncertainty && $0 <= observedAt + uncertainty
            }
            guard candidates.count == 1, let candidate = candidates.first else { return nil }
            return EventTiming(monotonicSeconds: candidate, uncertaintySeconds: uncertainty)
        }
    }

    private static func processName(_ pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
            info.pbi_pid == UInt32(bitPattern: pid)
        else { return nil }
        return withUnsafeBytes(of: info.pbi_comm) { bytes in
            let name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            return name.isEmpty ? nil : name
        }
    }

    private enum Classification { case read, write, unknown }

    private static func classify(_ operation: String, detail: String) -> Classification {
        if writes.contains(operation) || operation.hasPrefix("wrdata")
            || operation.hasPrefix("page_out")
        {
            return .write
        }
        if reads.contains(operation) || operation.hasPrefix("rddata")
            || operation.hasPrefix("page_in")
        {
            return .read
        }
        if opens.contains(operation) {
            // fs_usage's open mode string explicitly carries create/truncate.
            // Refuse an OS format change rather than assuming an open is read-only.
            guard let flags = capture(openFlagsPattern, in: detail),
                flags.first == "R" || flags.first == "W"
            else { return .unknown }
            return flags.contains("C") || flags.contains("T") ? .write : .read
        }
        return .unknown
    }

    private static func capture(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func path(in detail: String) -> String? {
        guard let slash = detail.firstIndex(of: "/") else { return nil }
        let candidate = detail[slash...].trimmingCharacters(in: .whitespaces)
        // Truncation would make namespace attribution unsafe.
        guard !candidate.contains("..."), !candidate.isEmpty else { return nil }
        return candidate
    }

    private static let linePattern = try! NSRegularExpression(
        pattern: #"^(\d{2}:\d{2}:\d{2}\.\d+)\s+(\S+)\s+(.*?)\s+\d+\.\d+(?:\s+W)?\s+(.+)\.\d+\s*$"#)
    private static let descriptorPattern = try! NSRegularExpression(pattern: #"\bF=\s*(\d+)\b"#)
    private static let openFlagsPattern = try! NSRegularExpression(
        pattern: #"\(([RW][A-Za-z_+ -]*)\)"#)
    private static let opens: Set<String> = [
        "open", "openat", "open_extended", "open_dprotected", "guarded_open_np",
        "guarded_open_dprotected_np",
    ]
    private static let writes: Set<String> = [
        "write", "pwrite", "writev", "pwritev", "guarded_write_np", "guarded_pwrite_np",
        "guarded_writev_np",
        "aio_write", "aio_writev", "fsync", "fdatasync", "aio_fsync", "sync", "msync",
        "rename", "renameat", "renameatx_np", "unlink", "unlinkat", "truncate", "ftruncate",
        "guarded_ftruncate_np",
        "mkdir", "mkdirat", "mkdir_extended", "rmdir", "link", "linkat", "symlink", "symlinkat",
        "mknod", "mkfifo", "mkfifo_extended", "clonefile", "clonefileat", "fclonefileat",
        "copyfile", "fcopyfile",
        "setattrlist", "setattrlistat", "fsetattrlist", "setxattr", "fsetxattr", "removexattr",
        "fremovexattr",
        "chmod", "fchmod", "chmodat", "chmod_extended", "fchmod_extended", "chown", "fchown",
        "chownat", "lchown",
        "chflags", "fchflags", "fchflagsat", "utimes", "futimes", "utimensat", "futimens",
        "exchangedata", "delete-carbon",
    ]
    private static let reads: Set<String> = [
        "read", "pread", "readv", "preadv", "aio_read", "aio_readv", "close", "guarded_close_np",
        "stat", "fstat", "lstat", "stat64", "fstat64", "lstat64", "fstatat", "fstatat64",
        "stat_extended", "lstat_extended", "fstat_extended", "stat_extended64", "lstat_extended64",
        "fstat64_extended",
        "statfs", "fstatfs", "statfs64", "fstatfs64", "getfsstat", "getfsstat64",
        "access", "access_extended", "checkuseraccess", "getattrlist", "getattrlistat",
        "fgetattrlist", "getattrlistbulk",
        "getxattr", "fgetxattr", "listxattr", "flistxattr", "readlink", "readlinkat",
        "getdirentries", "getdirentries64",
        "getdirentriesattr", "fsgetpath", "pathconf", "fpathconf", "lseek", "cache_hit", "exit",
    ]
}
