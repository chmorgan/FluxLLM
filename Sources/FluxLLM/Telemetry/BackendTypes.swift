import Foundation

public enum BackendKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama, vllm, rapidMLX, llamaCpp, unsloth

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ollama: "Ollama"
        case .vllm: "vLLM"
        case .rapidMLX: "Rapid-MLX"
        case .llamaCpp: "llama.cpp"
        case .unsloth: "Unsloth"
        }
    }
    public var defaultEndpoint: String {
        switch self {
        case .ollama: "http://127.0.0.1:11434"
        case .vllm, .rapidMLX: "http://127.0.0.1:8000"
        case .llamaCpp: "http://127.0.0.1:8080"
        case .unsloth: "http://127.0.0.1:8888"
        }
    }
}

public enum BackendSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, ollama, vllm, rapidMLX, llamaCpp, unsloth
    public var id: String { rawValue }
    public var kind: BackendKind? { BackendKind(rawValue: rawValue) }
    public var title: String { kind?.title ?? "Automatic" }
}

public struct BackendConfiguration: Equatable, Sendable {
    public let kind: BackendKind
    public let baseURL: URL
    public let model: String?
    public let proxyPort: Int
    public let studioMonitorToken: String?
    /// A session-only worker credential override. Unsloth resolves the verified worker's
    /// current launch key automatically when this is nil.
    public let workerAPIKey: String?

    public init(
        kind: BackendKind, baseURL: URL, model: String? = nil, proxyPort: Int = 11435,
        studioMonitorToken: String? = nil, workerAPIKey: String? = nil
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.proxyPort = proxyPort
        self.studioMonitorToken = studioMonitorToken
        self.workerAPIKey = workerAPIKey
    }
}

public struct DetectedBackend: Identifiable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue)|\(baseURL.absoluteString)" }
    public let kind: BackendKind
    public let baseURL: URL
    public let version: String?
    public let isReady: Bool
    public let supportsLiveMetrics: Bool
    public let detail: String?

    public init(
        kind: BackendKind, baseURL: URL, version: String? = nil,
        isReady: Bool = true, supportsLiveMetrics: Bool = true, detail: String? = nil
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.version = version
        self.isReady = isReady
        self.supportsLiveMetrics = supportsLiveMetrics
        self.detail = detail
    }
}

public enum BackendConnectionState: String, Sendable {
    case detecting, connecting, ready, needsConfiguration, unavailable
}

public enum ThroughputBasis: String, Sendable {
    case estimated, serverAggregate, serverReportedAverage

    public var title: String {
        switch self {
        case .estimated: "Estimated throughput"
        case .serverAggregate: "Total throughput"
        case .serverReportedAverage: "Server-reported average"
        }
    }
}

/// A healthy counter baseline has no measured rate yet, but is distinct from missing telemetry.
public enum ThroughputMeasurementState: String, Sendable {
    case measured, warmingUp, unavailable
}

public enum RequestObservationSource: String, Sendable {
    case slotPolling, studioMonitor, protocolStream
}

public enum ObservedRequestStatus: String, Sendable {
    case running, completed, cancelled, failed, observationEnded
}

/// Reduced request metadata. No prompt, reply, tool arguments, or result contents are retained.
public struct NativeRequestObservation: Sendable {
    public let id: String
    public let model: String?
    public let startedAt: Date?
    public let endedAt: Date?
    public let outputTokens: Int?
    public let promptTokens: Int?
    public let liveTPS: Double?
    public let status: ObservedRequestStatus

    public init(
        id: String, model: String? = nil, startedAt: Date? = nil, endedAt: Date? = nil,
        outputTokens: Int? = nil, promptTokens: Int? = nil, liveTPS: Double? = nil,
        status: ObservedRequestStatus = .running
    ) {
        self.id = id
        self.model = model
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outputTokens = outputTokens
        self.promptTokens = promptTokens
        self.liveTPS = liveTPS
        self.status = status
    }
}

/// Nil snapshots mean unavailable observation; an empty complete snapshot establishes idle.
public struct NativeRequestSnapshot: Sendable {
    public let sourceEpoch: UUID
    public let source: RequestObservationSource
    public let requests: [NativeRequestObservation]
    public let isComplete: Bool

    public init(
        sourceEpoch: UUID, source: RequestObservationSource,
        requests: [NativeRequestObservation], isComplete: Bool = true
    ) {
        self.sourceEpoch = sourceEpoch
        self.source = source
        self.requests = requests
        self.isComplete = isComplete
    }
}

/// Server-level telemetry is distinct from the proxy's individual request events.
/// Missing measurements remain optional; hardware memory is never GPU utilization.
public struct BackendSample: Sendable {
    public let kind: BackendKind
    public let timestamp: Date
    public let model: String?
    public let isReady: Bool
    public let currentTPS: Double?
    public let basis: ThroughputBasis
    public let throughputState: ThroughputMeasurementState
    /// Monotonic duration represented by a slot-counter measurement, for display smoothing.
    public let measurementDuration: TimeInterval?
    public let nativeRequests: NativeRequestSnapshot?
    public let runningRequests: Int?
    public let queuedRequests: Int?
    public let outputTokens: Int?
    public let promptTokens: Int?
    public let inferenceGPUPercent: Double?
    public let gpuSource: String?
    public let detail: String?

    public init(
        kind: BackendKind, timestamp: Date = Date(), model: String? = nil,
        isReady: Bool = true, currentTPS: Double? = nil,
        basis: ThroughputBasis = .serverAggregate,
        throughputState: ThroughputMeasurementState? = nil,
        measurementDuration: TimeInterval? = nil,
        nativeRequests: NativeRequestSnapshot? = nil,
        runningRequests: Int? = nil, queuedRequests: Int? = nil,
        outputTokens: Int? = nil, promptTokens: Int? = nil,
        inferenceGPUPercent: Double? = nil, gpuSource: String? = nil, detail: String? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.model = model
        self.isReady = isReady
        self.currentTPS = currentTPS
        self.basis = basis
        self.throughputState =
            throughputState
            ?? (currentTPS.map { $0.isFinite && $0 >= 0 } == true ? .measured : .unavailable)
        self.measurementDuration = measurementDuration
        self.nativeRequests = nativeRequests
        self.runningRequests = runningRequests
        self.queuedRequests = queuedRequests
        self.outputTokens = outputTokens
        self.promptTokens = promptTokens
        self.inferenceGPUPercent = inferenceGPUPercent
        self.gpuSource = gpuSource
        self.detail = detail
    }
}

/// Implementations must make read-only requests and never activate a model.
public protocol BackendClientProtocol: Sendable {
    func discoverLocalBackends() async -> [DetectedBackend]
    func discoverLocalBackends(configurations: [BackendConfiguration]) async -> [DetectedBackend]
    func detect(at baseURL: URL) async throws -> DetectedBackend?
    func detect(_ configuration: BackendConfiguration) async throws -> DetectedBackend?
    func sample(_ configuration: BackendConfiguration) async throws -> BackendSample
    func reset() async
}

extension BackendClientProtocol {
    public func discoverLocalBackends() async -> [DetectedBackend] { [] }
    /// Clients without authenticated local discovery keep their existing behavior.
    public func discoverLocalBackends(configurations: [BackendConfiguration]) async
        -> [DetectedBackend]
    {
        await discoverLocalBackends()
    }
    public func detect(_ configuration: BackendConfiguration) async throws -> DetectedBackend? {
        try await detect(at: configuration.baseURL)
    }
    public func reset() async {}
}

public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case automatic, minute, fiveMinutes, fifteenMinutes, thirtyMinutes, hour, sixHours, day, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "Auto"
        case .minute: "1m"
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        case .thirtyMinutes: "30m"
        case .hour: "1h"
        case .sixHours: "6h"
        case .day: "24h"
        case .custom: "Custom"
        }
    }
    public func duration(historyAge: TimeInterval) -> TimeInterval {
        switch self {
        case .minute: 60
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .thirtyMinutes: 1800
        case .hour: 3600
        case .sixHours: 21_600
        case .day: 86_400
        case .custom: 60
        case .automatic:
            if historyAge <= 60 {
                60
            } else if historyAge <= 300 {
                300
            } else if historyAge <= 900 {
                900
            } else if historyAge <= 1800 {
                1800
            } else if historyAge <= 3600 {
                3600
            } else if historyAge <= 21_600 {
                21_600
            } else {
                86_400
            }
        }
    }
}
