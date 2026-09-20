import Foundation
import NIO
import NIOHTTP1

/// Holds terminal bytes so tests can prove live forwarding before completion.
actor MockResponseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

struct MockOllamaResponse: Sendable {
    var status = 200
    var contentType = "application/json"
    var firstBytes: [UInt8]
    var remainingBytes: [UInt8] = []
    var gate: MockResponseGate?
    var streaming = false
    var truncate = false

    var body: Data { Data(firstBytes + remainingBytes) }

    static func generation(chat: Bool = false, gate: MockResponseGate? = nil) -> Self {
        let content =
            chat
            ? "\"message\":{\"role\":\"assistant\",\"content\":\"Hello 🌊\"}"
            : "\"response\":\"Hello 🌊\""
        let first = "{\"model\":\"fixture-model\",\(content),\"done\":false}\n"
        let final =
            "{\"model\":\"fixture-model\",\"done\":true,\"eval_count\":12,"
            + "\"prompt_eval_count\":4,\"eval_duration\":600000000}\n"
        return Self(
            contentType: "application/x-ndjson", firstBytes: Array(first.utf8),
            remainingBytes: Array(final.utf8), gate: gate, streaming: true)
    }

    static func nonStreaming(chat: Bool = false) -> Self {
        let content =
            chat
            ? "\"message\":{\"role\":\"assistant\",\"content\":\"Hello 🌊\"}"
            : "\"response\":\"Hello 🌊\""
        return Self(
            firstBytes: Array(
                "{\"model\":\"fixture-model\",\(content),\"done\":true,\"eval_count\":12,\"prompt_eval_count\":4,\"eval_duration\":600000000}"
                    .utf8))
    }

    static func httpError() -> Self {
        Self(status: 404, firstBytes: Array("{\"error\":\"model does not exist\"}".utf8))
    }
}

struct CapturedOllamaRequest: Sendable {
    let method: String
    let uri: String
    let headers: [String: String]
    let body: Data
}

/// NIO callbacks and the main-actor tests share these small locked records.
private final class MockRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CapturedOllamaRequest] = []

    func append(_ request: CapturedOllamaRequest) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
    }

    var requests: [CapturedOllamaRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class MockConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Channel] = []

    func append(_ channel: Channel) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(channel)
    }

    var channels: [Channel] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Loopback-only fixture using ephemeral ports to avoid the app and other tests.
@MainActor
final class MockOllamaServer {
    private let requestedPort: Int
    private let response: MockOllamaResponse
    private let recorder = MockRequestRecorder()
    private let connections = MockConnections()
    private var serverChannel: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?

    var port: Int { serverChannel?.localAddress?.port ?? requestedPort }
    var requests: [CapturedOllamaRequest] { recorder.requests }

    init(port: Int = 0, response: MockOllamaResponse = .nonStreaming()) {
        requestedPort = port
        self.response = response
    }

    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        eventLoopGroup = group
        let response = self.response
        let recorder = self.recorder
        let connections = self.connections
        do {
            serverChannel = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    connections.append(channel)
                    return channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.eventLoop.submit {
                            try channel.pipeline.syncOperations.addHandler(
                                NIOHTTPServerRequestAggregator(maxContentLength: 1 << 20))
                            try channel.pipeline.syncOperations.addHandler(
                                MockOllamaHandler(response: response, recorder: recorder))
                        }
                    }
                }
                .bind(host: "127.0.0.1", port: requestedPort).get()
        } catch {
            try? await group.shutdownGracefully()
            eventLoopGroup = nil
            throw error
        }
    }

    func stop() async {
        await response.gate?.release()
        try? await serverChannel?.close().get()
        for channel in connections.channels {
            try? await channel.close().get()
        }
        try? await eventLoopGroup?.shutdownGracefully()
        serverChannel = nil
        eventLoopGroup = nil
    }
}

private final class MockOllamaHandler: ChannelInboundHandler {
    typealias InboundIn = NIOHTTPServerRequestFull
    typealias OutboundOut = HTTPServerResponsePart

    private let response: MockOllamaResponse
    private let recorder: MockRequestRecorder

    init(response: MockOllamaResponse, recorder: MockRequestRecorder) {
        self.response = response
        self.recorder = recorder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = unwrapInboundIn(data)
        var headers: [String: String] = [:]
        for header in request.head.headers {
            headers[header.name.lowercased()] = header.value
        }
        let body = request.body ?? ByteBuffer()
        recorder.append(
            CapturedOllamaRequest(
                method: request.head.method.rawValue, uri: request.head.uri,
                headers: headers, body: Data(body.readableBytesView)))

        let response = self.response
        let channel = context.channel
        var responseHeaders: HTTPHeaders = [
            "content-type": response.contentType,
            "x-fixture": "FluxLLM POC",
            "connection": "close",
        ]
        if response.streaming {
            responseHeaders.add(name: "transfer-encoding", value: "chunked")
        } else {
            responseHeaders.add(name: "content-length", value: String(response.body.count))
        }
        context.write(
            wrapOutboundOut(
                .head(
                    HTTPResponseHead(
                        version: .http1_1, status: HTTPResponseStatus(statusCode: response.status),
                        headers: responseHeaders))), promise: nil)
        context.writeAndFlush(
            wrapOutboundOut(
                .body(
                    .byteBuffer(
                        channel.allocator.buffer(bytes: response.firstBytes)))), promise: nil)

        if let gate = response.gate {
            Task {
                await gate.wait()
                channel.eventLoop.execute { MockOllamaHandler.finish(response, on: channel) }
            }
        } else {
            Self.finish(response, on: channel)
        }
    }

    private static func finish(_ response: MockOllamaResponse, on channel: Channel) {
        guard channel.isActive else { return }
        if response.truncate {
            channel.close(promise: nil)
            return
        }
        if !response.remainingBytes.isEmpty {
            channel.write(
                HTTPServerResponsePart.body(
                    .byteBuffer(
                        channel.allocator.buffer(bytes: response.remainingBytes))), promise: nil)
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
