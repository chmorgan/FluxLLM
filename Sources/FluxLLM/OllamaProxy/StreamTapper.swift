import Foundation
import NIO
import NIOHTTP1

/// Serializes the terminal outcome shared by the two sides of a proxied request.
/// The lock protects pending accounting and event emission; the sink enqueues
/// without awaiting work.
final class GenerationRelay: @unchecked Sendable {
    typealias Scheduler = GenerationEventInbox.Scheduler
    typealias SnapshotFactory = @Sendable (TokenState, Date) -> GenerationSnapshot

    private struct PendingState {
        let state: TokenState
        let timestamp: Date
    }

    private let request: GenerationRequest?
    private let sink: @Sendable (GenerationEvent) -> Void
    private let makeSnapshot: SnapshotFactory
    private let lock = NSLock()
    private var terminal = false
    private var emittedFirstOutput = false
    private var pendingState: PendingState?
    private var schedule: Scheduler?
    private var scheduledDelivery: GenerationEventInbox.Cancellation?
    private var scheduleRevision: UInt64 = 0

    init(
        request: GenerationRequest?, sink: @escaping @Sendable (GenerationEvent) -> Void,
        schedule: Scheduler? = nil,
        makeSnapshot: @escaping SnapshotFactory = { state, timestamp in
            state.snapshot(at: timestamp)
        }
    ) {
        self.request = request
        self.sink = sink
        self.schedule = schedule
        self.makeSnapshot = makeSnapshot
        if let request { sink(.began(request)) }
    }

    /// Installed once by the upstream handler. The scheduler enqueues work;
    /// it must not invoke its callback synchronously while this lock is held.
    func setLiveUpdateScheduler(_ schedule: @escaping Scheduler) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, self.schedule == nil else { return }
        self.schedule = schedule
    }

    func toolActivity(_ events: [ToolActivityEvent]) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, let request, !events.isEmpty else { return }
        flushPendingState()
        sink(.toolActivity(requestID: request.id, events: events))
    }

    /// Store compact cumulative accounting before constructing a UI snapshot.
    /// Only one delayed callback is outstanding, irrespective of record rate.
    /// The existing global inbox can add another 50 ms before UI delivery;
    /// forwarding network bytes never waits for either accounting stage.
    /// The relay lock also lets a racing cancellation flush accepted accounting
    /// before emitting its terminal event, without reaching into the NIO handler.
    func update(_ state: TokenState, at timestamp: Date, toolEvents: [ToolActivityEvent] = []) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, let request else { return }
        let firstOutput = state.hasOutput && !emittedFirstOutput
        if firstOutput { emittedFirstOutput = true }
        pendingState = PendingState(state: state, timestamp: timestamp)
        if state.isTerminal || firstOutput || !toolEvents.isEmpty || schedule == nil {
            cancelScheduledDelivery()
            if !toolEvents.isEmpty {
                sink(.toolActivity(requestID: request.id, events: toolEvents))
            }
            terminal = state.isTerminal
            flushPendingState()
        } else if scheduledDelivery == nil, let schedule {
            scheduleRevision &+= 1
            let revision = scheduleRevision
            scheduledDelivery = schedule(.milliseconds(50)) { [weak self] in
                self?.deliverPendingState(revision: revision)
            }
        }
    }

    /// Already-materialized terminal snapshots (including premature EOF) still
    /// share the same serialized terminal decision and replace pending live data.
    func update(_ snapshot: GenerationSnapshot, toolEvents: [ToolActivityEvent] = []) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, let request else { return }
        cancelScheduledDelivery()
        pendingState = nil
        if !toolEvents.isEmpty {
            sink(.toolActivity(requestID: request.id, events: toolEvents))
        }
        terminal = snapshot.finished || snapshot.error != nil
        if snapshot.outputTokens > 0 { emittedFirstOutput = true }
        sink(.updated(requestID: request.id, snapshot: snapshot))
    }

    func fail(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return }
        flushPendingState()
        terminal = true
        if let request { sink(.failed(requestID: request.id, message: message)) }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return }
        flushPendingState()
        terminal = true
        if let request { sink(.cancelled(requestID: request.id)) }
    }

    private func deliverPendingState(revision: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, revision == scheduleRevision else { return }
        scheduledDelivery = nil
        flushPendingState()
    }

    private func flushPendingState() {
        cancelScheduledDelivery()
        guard let pendingState, let request else { return }
        self.pendingState = nil
        sink(
            .updated(
                requestID: request.id,
                snapshot: makeSnapshot(pendingState.state, pendingState.timestamp)))
    }

    private func cancelScheduledDelivery() {
        scheduleRevision &+= 1
        scheduledDelivery?()
        scheduledDelivery = nil
    }
}

/// Forwards response bodies without aggregating the stream, then taps native
/// Ollama payloads on the upstream event loop in order through completion.
final class StreamTapper: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = Void

    private let serverChannel: Channel
    private let relay: GenerationRelay
    private let isGeneration: Bool
    private var parser = SSEParser()
    private var counter = TokenState()
    private var toolCalls = ToolCallParser()
    private var isStreaming = false
    private var successfulResponse = true
    private var receivedHead = false
    private var ended = false
    private var nonStreamBody: ByteBuffer?

    init(serverChannel: Channel, relay: GenerationRelay, isGeneration: Bool) {
        self.serverChannel = serverChannel
        self.relay = relay
        self.isGeneration = isGeneration
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let eventLoop = context.eventLoop
        relay.setLiveUpdateScheduler { delay, action in
            let components = delay.components
            let nanoseconds =
                components.seconds * 1_000_000_000
                + components.attoseconds / 1_000_000_000
            let task = eventLoop.scheduleTask(in: .nanoseconds(nanoseconds)) { action() }
            return { task.cancel() }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(var head):
            if head.status.code >= 200 {
                receivedHead = true
                successfulResponse = head.status.code < 300
                let contentType = head.headers.first(name: "content-type")?.lowercased() ?? ""
                isStreaming =
                    contentType.contains("application/x-ndjson")
                    || contentType.contains("text/event-stream")
                if !successfulResponse {
                    relay.fail(
                        "Ollama returned HTTP \(head.status.code) \(head.status.reasonPhrase).")
                }
                // The POC uses one response per connection. Content framing and
                // all response body bytes are preserved.
                head.headers.replaceOrAdd(name: "connection", value: "close")
            }
            forward(.head(head), upstream: context.channel)

        case .body(let buffer):
            forward(.body(.byteBuffer(buffer)), upstream: context.channel)
            if isGeneration && successfulResponse { tapBody(buffer) }

        case .end(let trailers):
            guard !ended else { return }
            ended = true
            if isGeneration && successfulResponse { finalize() }
            let downstream = serverChannel
            let upstream = context.channel
            let relay = relay
            downstream.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenComplete { result in
                if case .failure = result { relay.cancel() }
                downstream.close(promise: nil)
                upstream.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failTransport(context: context, message: "Ollama connection failed: \(error)")
    }

    func channelInactive(context: ChannelHandlerContext) {
        failTransport(
            context: context, message: "Ollama disconnected before completing its response.")
        context.fireChannelInactive()
    }

    /// Native generation routes only. A stream flag on model pull/create routes
    /// describes progress messages rather than generated tokens.
    static func isGenerationRequest(path: String, body: ByteBuffer) -> Bool {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return pathOnly == "/api/generate" || pathOnly == "/api/chat"
    }

    private func tapBody(_ buffer: ByteBuffer) {
        if isStreaming {
            for payload in parser.feedBytes(buffer.readableBytesView) {
                ingest(payload)
            }
        } else {
            if nonStreamBody == nil { nonStreamBody = ByteBuffer() }
            var body = buffer
            nonStreamBody?.writeBuffer(&body)
        }
    }

    private func finalize() {
        if isStreaming {
            for payload in parser.finishBytes() { ingest(payload) }
        } else if let body = nonStreamBody, SSEParser.isValidUTF8(body.readableBytesView) {
            ingest(Data(body.readableBytesView))
        }
        if !counter.isTerminal { relay.update(counter.finish()) }
    }

    private func ingest(_ payload: Data) {
        let timestamp = Date()
        var events: [ToolActivityEvent] = []
        // Both parsers borrow one decoded Foundation record and its message;
        // ordinary text records need no whole-dictionary Swift bridge.
        if let record = DecodedGenerationRecord(data: payload) {
            events = toolCalls.ingest(record, at: timestamp)
            counter.ingest(record, at: timestamp)
        }
        // Discrete calls must arrive before a terminal snapshot from the same
        // payload, which closes the request and stops further relay emissions.
        // Malformed records retain the existing cumulative snapshot behavior.
        relay.update(counter, at: timestamp, toolEvents: events)
    }

    private func forward(_ part: HTTPServerResponsePart, upstream: Channel) {
        let downstream = serverChannel
        let relay = relay
        downstream.writeAndFlush(part).whenFailure { _ in
            relay.cancel()
            upstream.close(promise: nil)
            downstream.close(promise: nil)
        }
    }

    private func failTransport(context: ChannelHandlerContext, message: String) {
        guard !ended else { return }
        ended = true
        relay.fail(message)
        let downstream = serverChannel
        if receivedHead {
            downstream.close(promise: nil)
        } else {
            downstream.write(
                HTTPServerResponsePart.head(
                    HTTPResponseHead(
                        version: .http1_1, status: .badGateway,
                        headers: ["content-length": "0", "connection": "close"])),
                promise: nil)
            downstream.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                downstream.close(promise: nil)
            }
        }
        context.close(promise: nil)
    }
}
