import Foundation

/// Borrows the dictionaries produced by JSONSerialization without bridging every
/// field into Swift storage. Native adapters retain their original scalar types:
/// wrapping a Swift Int in NSDictionary would turn it into an NSNumber and change
/// conditional casts used by the existing accounting entrypoints.
struct DecodedGenerationRecord {
    enum DictionaryView {
        case foundation(NSDictionary)
        case native([String: Any])

        subscript(key: String) -> Any? {
            switch self {
            case .foundation(let object): object[key]
            case .native(let object): object[key]
            }
        }

        func dictionary(_ key: String) -> DictionaryView? {
            switch self {
            case .foundation(let object):
                return (object[key] as? NSDictionary).map(DictionaryView.foundation)
            case .native(let object):
                return (object[key] as? [String: Any]).map(DictionaryView.native)
            }
        }

        func dictionaries(_ key: String) -> [DictionaryView]? {
            switch self {
            case .foundation(let object):
                return (object[key] as? [NSDictionary])?.map(DictionaryView.foundation)
            case .native(let object):
                return (object[key] as? [[String: Any]])?.map(DictionaryView.native)
            }
        }
    }

    let object: DictionaryView
    let message: DictionaryView?

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            return nil
        }
        self.init(object: .foundation(object))
    }

    init(_ object: [String: Any]) {
        self.init(object: .native(object))
    }

    private init(object: DictionaryView) {
        self.object = object
        message = object.dictionary("message")
    }
}

/// Tracks one native Ollama response. Live output is a text-delta estimate;
/// tokenizer counts and evaluation throughput become authoritative at completion.
public actor TokenCounter {
    public typealias Result = GenerationSnapshot

    private var state: TokenState

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        state = TokenState(clock: clock)
    }

    public func ingestStream(_ payload: String) { state.ingest(payload) }
    public func ingestNonStreaming(_ body: String) { state.ingest(body) }
    public func live() -> Result { state.snapshot() }
    public func finish() -> Result { state.finish() }
}

/// The proxy keeps this value on its NIO event loop, so byte ingestion and EOF
/// are ordered synchronously. The public actor exposes the same logic to callers.
struct TokenState: Sendable {
    private let clock: @Sendable () -> Date
    private var estimatedCount = 0
    private var evalCount: Int?
    private var promptCount: Int?
    private var model: String?
    private var firstPayloadAt: Date?
    private var firstTextAt: Date?
    private var endedAt: Date?
    private var evalDurationNanos: Double?
    private var finished = false
    private var error: String?

    init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    var isTerminal: Bool { finished }
    var hasOutput: Bool { (evalCount ?? estimatedCount) > 0 }

    mutating func ingest(_ payload: String) {
        guard !finished, let data = payload.data(using: .utf8),
            let record = DecodedGenerationRecord(data: data)
        else { return }
        ingest(record)
    }

    mutating func ingest(_ object: [String: Any], at timestamp: Date? = nil) {
        ingest(DecodedGenerationRecord(object), at: timestamp)
    }

    /// The proxy shares one decoded record with token and tool accounting.
    mutating func ingest(_ record: DecodedGenerationRecord, at timestamp: Date? = nil) {
        guard !finished else { return }
        let object = record.object
        let now = timestamp ?? clock()
        if firstPayloadAt == nil { firstPayloadAt = now }
        if let model = object["model"] as? String { self.model = model }
        if let message = object["error"] as? String {
            error = message
            endedAt = now
            finished = true
            return
        }

        let message = record.message
        var deltaCount = 0
        if let response = object["response"] as? String, !response.isEmpty { deltaCount += 1 }
        if let thinking = object["thinking"] as? String, !thinking.isEmpty { deltaCount += 1 }
        if let content = message?["content"] as? String, !content.isEmpty { deltaCount += 1 }
        if let thinking = message?["thinking"] as? String, !thinking.isEmpty { deltaCount += 1 }
        if deltaCount > 0 {
            if firstTextAt == nil { firstTextAt = now }
            estimatedCount += deltaCount
        }

        if let prompt = object["prompt_eval_count"] as? Int, prompt >= 0 {
            promptCount = prompt
        }
        if object["done"] as? Bool == true {
            if let count = object["eval_count"] as? Int, count >= 0 { evalCount = count }
            if let duration = object["eval_duration"] as? Double, duration.isFinite, duration > 0 {
                evalDurationNanos = duration
            }
            endedAt = now
            finished = true
            if evalCount == nil || (evalCount != 0 && evalDurationNanos == nil) {
                error = "Ollama completed without usable token usage statistics."
            }
        }
    }

    mutating func finish() -> GenerationSnapshot {
        if !finished {
            error = "Ollama response ended before its completion message."
            endedAt = clock()
            finished = true
        }
        return snapshot()
    }

    func snapshot(at timestamp: Date? = nil) -> GenerationSnapshot {
        let end = endedAt ?? timestamp ?? clock()
        let start = firstTextAt ?? firstPayloadAt ?? end
        let elapsed = max(0, end.timeIntervalSince(start))
        // A first fragment followed immediately by a snapshot has only a few
        // microseconds of history. Wait for a useful interval before estimating.
        let live = elapsed >= 0.1 ? Double(estimatedCount) / elapsed : 0
        let measured: Double?
        if let count = evalCount, let duration = evalDurationNanos {
            measured = Double(count) * 1_000_000_000 / duration
        } else {
            measured = nil
        }
        return GenerationSnapshot(
            model: model, outputTokens: evalCount ?? estimatedCount,
            promptTokens: promptCount, isEstimated: evalCount == nil,
            liveTPS: live.isFinite ? live : 0,
            authoritativeTPS: measured.flatMap { $0.isFinite ? $0 : nil },
            finished: finished, elapsed: elapsed, error: error, timestamp: end)
    }
}
