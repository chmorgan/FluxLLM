import Foundation

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
struct TokenState {
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

    mutating func ingest(_ payload: String) {
        guard !finished, let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let now = clock()
        if firstPayloadAt == nil { firstPayloadAt = now }
        if let model = object["model"] as? String { self.model = model }
        if let message = object["error"] as? String {
            error = message
            endedAt = now
            finished = true
            return
        }

        let message = object["message"] as? [String: Any]
        let deltas = [
            object["response"] as? String, object["thinking"] as? String,
            message?["content"] as? String, message?["thinking"] as? String,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        if !deltas.isEmpty {
            if firstTextAt == nil { firstTextAt = now }
            estimatedCount += deltas.count
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

    func snapshot() -> GenerationSnapshot {
        let now = clock()
        let end = endedAt ?? now
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
