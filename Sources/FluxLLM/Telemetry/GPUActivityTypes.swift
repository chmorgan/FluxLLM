import Foundation

/// PID plus process birth time prevents a reused PID from inheriting GPU history.
public struct GPUProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startTimeMicroseconds: UInt64

    public init(pid: Int32, startTimeMicroseconds: UInt64) {
        self.pid = pid
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

public struct GPUProcessSelection: Sendable {
    public let processes: Set<GPUProcessIdentity>
    public let unavailableReason: String?

    public init(processes: Set<GPUProcessIdentity>, unavailableReason: String? = nil) {
        self.processes = processes
        self.unavailableReason = unavailableReason
    }
}

public protocol BackendProcessResolving: Sendable {
    func resolve(_ configuration: BackendConfiguration) async -> GPUProcessSelection
    func reset() async
}

/// Separates whole-device utilization from process execution time. These
/// measurements have different units and must never share a chart history.
public enum GPUActivityScope: Sendable, Equatable {
    /// Execution time / elapsed wall time × 100; concurrent queues may exceed 100.
    case backendProcesses
    /// macOS device utilization, expressed as a percentage between 0 and 100.
    case system
}

public struct GPUActivitySample: Sendable, Equatable {
    public let timestamp: Date
    public let activityPercent: Double?
    public let processIDs: [Int32]
    public let source: String
    public let unavailableReason: String?
    public let scope: GPUActivityScope

    public init(
        timestamp: Date = Date(), activityPercent: Double? = nil,
        processIDs: [Int32] = [], source: String = "macOS per-process GPU time",
        unavailableReason: String? = nil, scope: GPUActivityScope = .backendProcesses
    ) {
        self.timestamp = timestamp
        self.activityPercent = activityPercent
        self.processIDs = processIDs
        self.source = source
        self.unavailableReason = unavailableReason
        self.scope = scope
    }
}

public protocol GPUActivitySampling: Sendable {
    func sample(processes: Set<GPUProcessIdentity>) async -> GPUActivitySample
    func reset() async
}

public protocol BackendGPUMonitoring: Sendable {
    func sample(_ configuration: BackendConfiguration?) async -> GPUActivitySample
    func reset() async
}

/// Deterministic tests can opt out of reading machine-local process information.
public actor UnavailableBackendGPUMonitor: BackendGPUMonitoring {
    public init() {}
    public func sample(_ configuration: BackendConfiguration?) async -> GPUActivitySample {
        GPUActivitySample(unavailableReason: "GPU telemetry is unavailable for this connection.")
    }
    public func reset() async {}
}
