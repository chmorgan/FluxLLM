import Darwin
import Foundation
import NIO

/// Created only by the isolated performance session on its single NIO loop.
/// Every mutation and snapshot stays on that thread. Only immutable snapshots
/// cross to the main actor; production handlers receive nil instead.
final class PerformanceNIODiagnostics: @unchecked Sendable {
    enum Metric: String, CaseIterable, Sendable {
        case upstreamRead = "upstream_read"
        case upstreamReadComplete = "upstream_read_complete"
        case forwarding, coalescer, framing
        case jsonDecode = "json_decode"
        case interpretation
        case relayUpdate = "relay_update"
        case relayScheduled = "relay_scheduled"

        var index: Int {
            switch self {
            case .upstreamRead: 0
            case .upstreamReadComplete: 1
            case .forwarding: 2
            case .coalescer: 3
            case .framing: 4
            case .jsonDecode: 5
            case .interpretation: 6
            case .relayUpdate: 7
            case .relayScheduled: 8
            }
        }
        var bit: UInt16 { 1 << index }
    }

    struct Counter: Sendable {
        var calls: UInt64 = 0
        var cpuNS: UInt64 = 0
        var bytes: UInt64 = 0
        var records: UInt64 = 0
        var bodies: UInt64 = 0
        var ends: UInt64 = 0
        var dictionary: [String: UInt64] {
            [
                "calls": calls, "cpu_ns": cpuNS, "bytes": bytes,
                "records": records, "bodies": bodies, "ends": ends,
            ]
        }
    }

    struct Scope {
        fileprivate let metric: Metric
        fileprivate let cpuNS: UInt64
        fileprivate let depth: Int
    }

    struct Calibration: Sendable {
        let iterations: Int
        let pairCPUNS: UInt64
        let pairWallNS: UInt64
        let emptyScopeCPUNS: UInt64
        let emptyScopeWallNS: UInt64
        let emptyScopeMeasuredNS: UInt64
        let available: Bool
        var dictionary: [String: Any] {
            [
                "clock": "CLOCK_THREAD_CPUTIME_ID", "iterations": iterations,
                "pair_cpu_ns": pairCPUNS, "pair_wall_ns": pairWallNS,
                "empty_scope_cpu_ns": emptyScopeCPUNS, "empty_scope_wall_ns": emptyScopeWallNS,
                "empty_scope_measured_ns": emptyScopeMeasuredNS, "available": available,
            ]
        }
    }

    struct Snapshot: Sendable {
        let processID: Int32
        let threadID: UInt64
        let sequence: UInt64
        let captureBeginMachTicks: UInt64
        let captureEndMachTicks: UInt64
        let threadCPUBeforeNS: UInt64
        let threadCPUAfterNS: UInt64
        let counters: [Counter]
        let calibration: Calibration
        let clockReads: UInt64
        let error: String?
        var dictionary: [String: Any] {
            var value: [String: Any] = [
                "schema_version": 1, "available": error == nil,
                "process_id": processID, "thread_id": threadID, "sequence": sequence,
                "capture_begin_mach_ticks": captureBeginMachTicks,
                "capture_end_mach_ticks": captureEndMachTicks,
                "thread_cpu_before_ns": threadCPUBeforeNS, "thread_cpu_after_ns": threadCPUAfterNS,
                "metrics": Dictionary(
                    uniqueKeysWithValues: Metric.allCases.map {
                        ($0.rawValue, counters[$0.index].dictionary)
                    }),
                "calibration": calibration.dictionary, "clock_reads": clockReads,
            ]
            if let error { value["error"] = error }
            return value
        }
    }

    private let owner: pthread_t
    private let processID: Int32
    private let threadID: UInt64
    // Injectable clocks keep error/overflow/nesting tests deterministic. The
    // closures are allocated once; begin/end return scalar stack values only.
    private let readCPU: () -> UInt64?
    private let readMach: () -> UInt64
    private let matchesThread: (() -> Bool)?
    private var counters = Array(repeating: Counter(), count: Metric.allCases.count)
    private var active: UInt16 = 0
    private var depth = 0
    private var sequence: UInt64 = 0
    private var clockReads: UInt64 = 0
    private var lastCPU: UInt64 = 0
    private var error: String?
    private var calibration = Calibration(
        iterations: 0, pairCPUNS: 0, pairWallNS: 0, emptyScopeCPUNS: 0,
        emptyScopeWallNS: 0, emptyScopeMeasuredNS: 0, available: false)

    init(
        threadID: UInt64? = nil,
        readCPU: @escaping () -> UInt64? = PerformanceNIODiagnostics.cpuNow,
        readMach: @escaping () -> UInt64 = { mach_absolute_time() },
        matchesThread: (() -> Bool)? = nil, calibrationIterations: Int = 1_000
    ) throws {
        owner = pthread_self()
        processID = getpid()
        self.threadID = try threadID ?? PerformanceThreadIdentity.current()
        self.readCPU = readCPU
        self.readMach = readMach
        self.matchesThread = matchesThread
        guard self.threadID != 0 else {
            throw PerformanceSessionError.invalid("NIO CPU thread ID is zero")
        }
        calibrate(iterations: calibrationIterations)
    }

    @inline(__always)
    func begin(
        _ metric: Metric, bytes: Int = 0, records: Int = 0,
        bodies: Int = 0, ends: Int = 0
    ) -> Scope? {
        guard checkThread(), error == nil else { return nil }
        // Only raw-read/read-complete callbacks contain leaf stages. Coalescer
        // is the single intentional child of forwarding. Relay timers run as
        // separate event-loop tasks and cannot overlap an upstream callback.
        let upstream = Metric.upstreamRead.bit | Metric.upstreamReadComplete.bit
        let legal: Bool
        switch metric {
        case .upstreamRead, .upstreamReadComplete, .relayScheduled:
            legal = active == 0
        case .coalescer:
            legal =
                active & Metric.forwarding.bit != 0
                && active & ~(upstream | Metric.forwarding.bit) == 0
        default:
            legal = active == Metric.upstreamRead.bit || active == Metric.upstreamReadComplete.bit
        }
        guard legal, active & metric.bit == 0 else {
            fail("Invalid or overlapping NIO CPU scope: \(metric.rawValue)")
            return nil
        }
        guard bytes >= 0, records >= 0, bodies >= 0, ends >= 0, let now = clock() else {
            fail("Invalid NIO CPU scope count or clock")
            return nil
        }
        guard add(1, to: &counters[metric.index].calls),
            add(UInt64(bytes), to: &counters[metric.index].bytes),
            add(UInt64(records), to: &counters[metric.index].records),
            add(UInt64(bodies), to: &counters[metric.index].bodies),
            add(UInt64(ends), to: &counters[metric.index].ends)
        else {
            fail("NIO CPU scope counter overflow")
            return nil
        }
        depth += 1
        active |= metric.bit
        return Scope(metric: metric, cpuNS: now, depth: depth)
    }

    @inline(__always)
    func end(_ scope: Scope?, records: Int = 0) {
        guard let scope, checkThread(), error == nil else { return }
        guard scope.depth == depth, active & scope.metric.bit != 0, records >= 0,
            let now = clock(), now >= scope.cpuNS
        else {
            fail("Unbalanced NIO CPU scope or invalid clock")
            return
        }
        guard add(now - scope.cpuNS, to: &counters[scope.metric.index].cpuNS),
            add(UInt64(records), to: &counters[scope.metric.index].records)
        else {
            fail("NIO CPU scope counter overflow")
            return
        }
        active &= ~scope.metric.bit
        depth -= 1
    }

    func snapshot() -> Snapshot {
        let begin = readMach()
        _ = checkThread()
        if depth != 0 || active != 0 { fail("NIO CPU snapshot requested inside an active scope") }
        let before = clock() ?? lastCPU
        // The copy occurs solely at explicit control checkpoints. Counter
        // storage is made unique here, rather than at the next measured hit.
        let copy = counters.map { $0 }
        sequence &+= 1
        if sequence == 0 { fail("NIO CPU snapshot sequence overflow") }
        let after = clock() ?? lastCPU
        let end = readMach()
        if end < begin { fail("NIO CPU snapshot Mach clock regressed") }
        return Snapshot(
            processID: processID, threadID: threadID, sequence: sequence,
            captureBeginMachTicks: begin, captureEndMachTicks: end,
            threadCPUBeforeNS: before, threadCPUAfterNS: after, counters: copy,
            calibration: calibration, clockReads: clockReads, error: error)
    }

    @inline(__always)
    private func checkThread() -> Bool {
        let matches = matchesThread?() ?? (pthread_self() == owner)
        if !matches { fail("NIO CPU scope used from a different thread") }
        return matches
    }

    @inline(__always)
    private func clock() -> UInt64? {
        guard let value = readCPU(), value >= lastCPU else {
            fail("CLOCK_THREAD_CPUTIME_ID failed or regressed")
            return nil
        }
        lastCPU = value
        guard add(1, to: &clockReads) else {
            fail("NIO CPU clock-read counter overflow")
            return nil
        }
        return value
    }

    private func fail(_ message: String) { if error == nil { error = message } }

    @inline(__always)
    private func add(_ amount: UInt64, to value: inout UInt64) -> Bool {
        let (sum, overflow) = value.addingReportingOverflow(amount)
        if !overflow { value = sum }
        return !overflow
    }

    private func calibrate(iterations: Int) {
        let pairWallBegin = DispatchTime.now().uptimeNanoseconds
        guard (1...100_000).contains(iterations), checkThread(), let pairBegin = clock() else {
            fail("NIO CPU calibration could not start")
            return
        }
        for _ in 0..<iterations {
            _ = clock()
            _ = clock()
        }
        let pairEnd = clock() ?? pairBegin
        let pairWallEnd = DispatchTime.now().uptimeNanoseconds
        let emptyWallBegin = DispatchTime.now().uptimeNanoseconds
        let emptyBegin = clock() ?? pairEnd
        for _ in 0..<iterations {
            let scope = begin(.relayScheduled)
            end(scope)
        }
        let emptyEnd = clock() ?? emptyBegin
        let emptyWallEnd = DispatchTime.now().uptimeNanoseconds
        let measured = counters[Metric.relayScheduled.index].cpuNS
        calibration = Calibration(
            iterations: iterations,
            pairCPUNS: pairEnd - pairBegin, pairWallNS: pairWallEnd - pairWallBegin,
            emptyScopeCPUNS: emptyEnd - emptyBegin, emptyScopeWallNS: emptyWallEnd - emptyWallBegin,
            emptyScopeMeasuredNS: measured, available: error == nil)
        // Startup calibration is reported, never subtracted from scope totals.
        counters = Array(repeating: Counter(), count: Metric.allCases.count)
    }

    static func cpuNow() -> UInt64? {
        var value = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0,
            value.tv_sec >= 0, value.tv_nsec >= 0, value.tv_nsec < 1_000_000_000
        else { return nil }
        let (seconds, overflow) = UInt64(value.tv_sec).multipliedReportingOverflow(
            by: 1_000_000_000)
        let (result, additionOverflow) = seconds.addingReportingOverflow(UInt64(value.tv_nsec))
        return overflow || additionOverflow ? nil : result
    }
}

/// First inbound handler, below the HTTP decoder. Inclusive scopes include
/// synchronous downstream handlers; deferred NIO/socket work stays unassigned.
final class PerformanceNIOUpstreamObserver: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let diagnostics: PerformanceNIODiagnostics
    init(_ diagnostics: PerformanceNIODiagnostics) { self.diagnostics = diagnostics }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let scope = diagnostics.begin(.upstreamRead, bytes: unwrapInboundIn(data).readableBytes)
        defer { diagnostics.end(scope) }
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        let scope = diagnostics.begin(.upstreamReadComplete)
        defer { diagnostics.end(scope) }
        context.fireChannelReadComplete()
    }
}
