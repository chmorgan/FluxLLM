import Foundation
import NIO
import NIOHTTP1

/// Serializes the terminal outcome shared by the two sides of a proxied request.
/// The lock protects only event emission; the sink enqueues without awaiting work.
final class GenerationRelay: @unchecked Sendable {
    private let request: GenerationRequest?
    private let sink: @Sendable (GenerationEvent) -> Void
    private let lock = NSLock()
    private var terminal = false

    init(request: GenerationRequest?, sink: @escaping @Sendable (GenerationEvent) -> Void) {
        self.request = request
        self.sink = sink
        if let request { sink(.began(request)) }
    }

    func toolActivity(_ events: [ToolActivityEvent]) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, let request, !events.isEmpty else { return }
        sink(.toolActivity(requestID: request.id, events: events))
    }

    func update(_ snapshot: GenerationSnapshot, toolEvents: [ToolActivityEvent] = []) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, let request else { return }
        if !toolEvents.isEmpty {
            sink(.toolActivity(requestID: request.id, events: toolEvents))
        }
        terminal = snapshot.finished || snapshot.error != nil
        sink(.updated(requestID: request.id, snapshot: snapshot))
    }

    func fail(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return }
        terminal = true
        if let request { sink(.failed(requestID: request.id, message: message)) }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return }
        terminal = true
        if let request { sink(.cancelled(requestID: request.id)) }
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
            for payload in parser.feed(Array(buffer.readableBytesView)) {
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
            for payload in parser.finish() { ingest(payload) }
        } else if let body = nonStreamBody,
            let text = String(bytes: body.readableBytesView, encoding: .utf8)
        {
            ingest(text)
        }
        relay.update(counter.finish())
    }

    private func ingest(_ payload: String) {
        let events = toolCalls.ingest(payload, at: Date())
        counter.ingest(payload)
        // Discrete calls must arrive before a terminal snapshot from the same
        // payload, which closes the request and stops further relay emissions.
        relay.update(counter.snapshot(), toolEvents: events)
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
