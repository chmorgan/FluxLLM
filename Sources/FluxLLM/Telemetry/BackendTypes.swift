import Foundation

public enum BackendKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama, vllm, rapidMLX, llamaCpp

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ollama: "Ollama"
        case .vllm: "vLLM"
        case .rapidMLX: "Rapid-MLX"
        case .llamaCpp: "llama.cpp"
        }
    }
    public var defaultEndpoint: String {
        switch self {
        case .ollama: "http://127.0.0.1:11434"
        case .vllm, .rapidMLX: "http://127.0.0.1:8000"
        case .llamaCpp: "http://127.0.0.1:8080"
        }
    }
}

public enum BackendSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, ollama, vllm, rapidMLX, llamaCpp
    public var id: String { rawValue }
    public var kind: BackendKind? { BackendKind(rawValue: rawValue) }
    public var title: String { kind?.title ?? "Automatic" }
}

public struct BackendConfiguration: Equatable, Sendable {
    public let kind: BackendKind
    public let baseURL: URL
    public let model: String?
    public let proxyPort: Int

    public init(kind: BackendKind, baseURL: URL, model: String? = nil, proxyPort: Int = 11435) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.proxyPort = proxyPort
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

/// Server-level telemetry is distinct from the proxy's individual request events.
/// Missing measurements remain optional; hardware memory is never GPU utilization.
public struct BackendSample: Sendable {
    public let kind: BackendKind
    public let timestamp: Date
    public let model: String?
    public let isReady: Bool
    public let currentTPS: Double?
    public let basis: ThroughputBasis
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
    func detect(at baseURL: URL) async throws -> DetectedBackend?
    func sample(_ configuration: BackendConfiguration) async throws -> BackendSample
    func reset() async
}

extension BackendClientProtocol {
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
