import Foundation

/// Identifies the request that owns the dashboard. Older requests still forward
/// normally, but their events must not overwrite a more recently started request.
public struct GenerationRequest: Sendable, Equatable {
    public let id: UUID
    public let model: String?
    public let startedAt: Date

    public init(id: UUID = UUID(), model: String? = nil, startedAt: Date = Date()) {
        self.id = id
        self.model = model
        self.startedAt = startedAt
    }
}

/// Live text-delta estimates and final Ollama measurements have distinct origins.
/// Prompt usage remains unavailable until Ollama reports it.
public struct GenerationSnapshot: Sendable {
    public let model: String?
    public let outputTokens: Int
    public let promptTokens: Int?
    public let isEstimated: Bool
    public let liveTPS: Double
    public let authoritativeTPS: Double?
    public let finished: Bool
    public let elapsed: TimeInterval
    public let error: String?
    public let timestamp: Date

    public init(
        model: String? = nil, outputTokens: Int = 0, promptTokens: Int? = nil,
        isEstimated: Bool = true, liveTPS: Double = 0, authoritativeTPS: Double? = nil,
        finished: Bool = false, elapsed: TimeInterval = 0, error: String? = nil,
        timestamp: Date = Date()
    ) {
        self.model = model
        self.outputTokens = outputTokens
        self.promptTokens = promptTokens
        self.isEstimated = isEstimated
        self.liveTPS = liveTPS
        self.authoritativeTPS = authoritativeTPS
        self.finished = finished
        self.elapsed = elapsed
        self.error = error
        self.timestamp = timestamp
    }
}

/// Observable protocol activity, without retaining tool arguments or result contents.
public struct ToolActivityEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case call
        case resultSubmission
    }

    public let id: UUID
    public let kind: Kind
    public let name: String?
    public let callID: String?
    public let timestamp: Date
    /// The request that produced this event. It is excluded from `==` so a
    /// pre-stamp event compares equal to the value the store keeps after
    /// stamping it with the owning request (mirrors `ChartPresentationSnapshot`
    /// excluding its `publicationID`).
    public let requestID: UUID?

    public init(
        id: UUID = UUID(), kind: Kind, name: String? = nil, callID: String? = nil,
        timestamp: Date = Date(), requestID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.callID = callID
        self.timestamp = timestamp
        self.requestID = requestID
    }

    /// Stamps the event with the request it belongs to so the chart can color
    /// tool activity per request rather than with one shared color.
    func withRequestID(_ requestID: UUID) -> ToolActivityEvent {
        ToolActivityEvent(
            id: id, kind: kind, name: name, callID: callID, timestamp: timestamp,
            requestID: requestID)
    }

    /// `requestID` is excluded so a stamped copy still compares equal to the
    /// pre-stamp event the tests build.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.name == rhs.name
            && lhs.callID == rhs.callID && lhs.timestamp == rhs.timestamp
    }
}

public enum GenerationEvent: Sendable {
    case began(GenerationRequest)
    case toolActivity(requestID: UUID, events: [ToolActivityEvent])
    case updated(requestID: UUID, snapshot: GenerationSnapshot)
    case failed(requestID: UUID, message: String)
    case cancelled(requestID: UUID)
}

public enum ProxyState: String, Sendable {
    case stopped, starting, listening, stopping, failed
}

public struct TimeSeriesPoint: Sendable, Equatable {
    public let timestamp: Date
    public let value: Double
    public let isAvailable: Bool

    public init(timestamp: Date, value: Double, isAvailable: Bool = true) {
        self.timestamp = timestamp
        self.value = value
        self.isAvailable = isAvailable
    }
}
/// One in-flight or recently-finished proxied request, drawn as a horizontal
/// lane in the dashboard chart. The main throughput line is the sum of every
/// open request's live rate; each request also gets its own lane so concurrent
/// streams can be seen overlapping in time.
public struct RequestLane: Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    /// `nil` while the request is still running; set when it finishes.
    public let endedAt: Date?
    public let model: String?
    public let outputTokens: Int
    public let outputIsEstimated: Bool
    public let liveTPS: Double
    public let terminal: Bool

    public init(
        id: UUID, startedAt: Date, endedAt: Date? = nil, model: String? = nil,
        outputTokens: Int = 0, outputIsEstimated: Bool = true,
        liveTPS: Double = 0, terminal: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.model = model
        self.outputTokens = outputTokens
        self.outputIsEstimated = outputIsEstimated
        self.liveTPS = liveTPS
        self.terminal = terminal
    }

    /// A lane is visible on the chart while it is running, or until its finish
    /// time scrolls past the window's lower cutoff.
    public func isVisible(at cutoff: Date) -> Bool {
        guard let endedAt else { return true }
        return endedAt >= cutoff
    }
}
