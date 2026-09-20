import Combine
import Foundation
import NIO
import NIOHTTP1

/// A loopback-only, byte-preserving proxy with one ordered telemetry consumer.
@MainActor
public final class ProxyManager: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var isStarting = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var boundPort: Int?

    private let listenHost: String
    private var listenPort: Int
    private var ollamaHost: String
    private var ollamaPort: Int
    private weak var metricsStore: MetricsStore?

    private var serverChannel: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var channels: ProxyChannelRegistry?
    private let eventInbox: GenerationEventInbox
    private var eventConsumer: Task<Void, Never>?

    // Operations wait for their predecessor. Stop invalidates starts that are
    // queued or suspended in bind, so an old restart cannot reopen during Quit.
    private var lifecycleTask: Task<Void, Error>?
    private var lifecycleID: UUID?
    private var lifecycleRevision = 0

    public init(
        listenHost: String = "127.0.0.1",
        listenPort: Int = 11435,
        ollamaHost: String = "localhost",
        ollamaPort: Int = 11434,
        metricsStore: MetricsStore? = nil,
        eventEpoch: UUID? = nil
    ) {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.ollamaHost = ollamaHost
        self.ollamaPort = ollamaPort
        self.metricsStore = metricsStore
        let inbox = GenerationEventInbox()
        eventInbox = inbox
        eventConsumer = Task { @MainActor [weak metricsStore] in
            for await _ in inbox.notifications {
                guard !Task.isCancelled else { return }
                for event in inbox.drain() {
                    metricsStore?.apply(event, epoch: eventEpoch)
                }
            }
        }
        publishEndpoints()
    }

    deinit {
        eventInbox.finish()
        eventConsumer?.cancel()
    }

    public func start() async throws {
        try Task.checkCancellation()
        let previous = lifecycleTask
        let revision = lifecycleRevision
        let id = UUID()
        let task = Task { @MainActor in
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            guard self.lifecycleRevision == revision else { throw CancellationError() }
            guard !self.isRunning else { return }
            try await self.startListener(revision: revision)
        }
        lifecycleTask = task
        lifecycleID = id
        defer { finishOperation(id) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func stop() async {
        lifecycleRevision += 1
        let previous = lifecycleTask
        let id = UUID()
        metricsStore?.proxyState = .stopping
        let task = Task<Void, Error> { @MainActor in
            if let previous { _ = await previous.result }
            await self.stopListener()
        }
        lifecycleTask = task
        lifecycleID = id
        // Shutdown finishes even if its caller has already been cancelled.
        _ = await task.result
        finishOperation(id)
    }

    public func restart(listenPort: Int, ollamaHost: String, ollamaPort: Int) async throws {
        try Task.checkCancellation()
        _ = try Self.validate(
            listenHost: listenHost, listenPort: listenPort,
            ollamaHost: ollamaHost, ollamaPort: ollamaPort)
        lifecycleRevision += 1
        let revision = lifecycleRevision
        let previous = lifecycleTask
        let id = UUID()
        metricsStore?.proxyState = .stopping
        let task = Task { @MainActor in
            if let previous { _ = await previous.result }
            guard self.lifecycleRevision == revision else { throw CancellationError() }
            await self.stopListener()
            try Task.checkCancellation()
            guard self.lifecycleRevision == revision else { throw CancellationError() }
            self.listenPort = listenPort
            self.ollamaHost = ollamaHost
            self.ollamaPort = ollamaPort
            try await self.startListener(revision: revision)
        }
        lifecycleTask = task
        lifecycleID = id
        defer { finishOperation(id) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func finishOperation(_ id: UUID) {
        guard lifecycleID == id else { return }
        lifecycleTask = nil
        lifecycleID = nil
    }

    private func startListener(revision: Int) async throws {
        isStarting = true
        lastError = nil
        metricsStore?.proxyError = nil
        metricsStore?.proxyState = .starting
        publishEndpoints()

        do {
            let configuration = try Self.validate(
                listenHost: listenHost, listenPort: listenPort,
                ollamaHost: ollamaHost, ollamaPort: ollamaPort)
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let registry = ProxyChannelRegistry()
            eventLoopGroup = group
            channels = registry
            let inbox = eventInbox
            let sink: @Sendable (GenerationEvent) -> Void = { event in
                inbox.submit(event)
            }
            let upstreamHost = configuration.upstreamHost
            let upstreamPort = ollamaPort

            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(
                    ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1
                )
                .serverChannelInitializer { channel in
                    guard registry.insert(channel) else {
                        return channel.eventLoop.makeFailedFuture(CancellationError())
                    }
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .childChannelInitializer { channel in
                    guard registry.insert(channel) else {
                        return channel.eventLoop.makeFailedFuture(CancellationError())
                    }
                    // This proxy handles one request per connection. NIO's
                    // pipelining assistance pauses reads until the response
                    // ends, hiding client disconnects during a live stream.
                    return channel.pipeline.configureHTTPServerPipeline(
                        withPipeliningAssistance: false
                    ).flatMap {
                        channel.eventLoop.submit {
                            try channel.pipeline.syncOperations.addHandler(
                                NIOHTTPServerRequestAggregator(maxContentLength: 1 << 20))
                            try channel.pipeline.syncOperations.addHandler(
                                RequestForwarder(
                                    ollamaHost: upstreamHost, ollamaPort: upstreamPort,
                                    registry: registry, eventSink: sink))
                        }
                    }
                }

            let channel = try await bootstrap.bind(
                host: configuration.listenerHost, port: listenPort
            ).get()
            serverChannel = channel
            try Task.checkCancellation()
            guard lifecycleRevision == revision else { throw CancellationError() }
            if Self.isLocalHost(upstreamHost), channel.localAddress?.port == upstreamPort {
                throw ProxyConfigurationError(
                    message: "The proxy and local Ollama server must use different ports.")
            }
            boundPort = channel.localAddress?.port
            isRunning = true
            isStarting = false
            metricsStore?.proxyState = .listening
            publishEndpoints(listenerHost: configuration.listenerHost, upstreamHost: upstreamHost)
        } catch {
            await releaseResources()
            isRunning = false
            isStarting = false
            boundPort = nil
            if lifecycleRevision == revision {
                if error is CancellationError {
                    metricsStore?.proxyState = .stopped
                } else {
                    lastError = "Proxy failed to start: \(error.localizedDescription)"
                    metricsStore?.proxyError = lastError
                    metricsStore?.proxyState = .failed
                }
            }
            throw error
        }
    }

    private func stopListener() async {
        metricsStore?.proxyState = .stopping
        await releaseResources()
        isRunning = false
        isStarting = false
        boundPort = nil
        metricsStore?.proxyState = .stopped
        publishEndpoints()
    }

    private func releaseResources() async {
        if let channels {
            let openChannels = channels.beginClosing()
            for channel in openChannels { channel.close(promise: nil) }
            for channel in openChannels { _ = try? await channel.closeFuture.get() }
        }
        if let eventLoopGroup {
            do {
                try await eventLoopGroup.shutdownGracefully()
            } catch {
                lastError = "Error stopping proxy: \(error.localizedDescription)"
                metricsStore?.proxyError = lastError
            }
        }
        serverChannel = nil
        eventLoopGroup = nil
        channels = nil
    }

    private func publishEndpoints(listenerHost: String? = nil, upstreamHost: String? = nil) {
        metricsStore?.proxyEndpoint = Self.endpoint(
            host: listenerHost ?? AppSettings.normalizedHost(listenHost),
            port: boundPort ?? listenPort)
        metricsStore?.upstreamEndpoint = Self.endpoint(
            host: upstreamHost ?? AppSettings.normalizedHost(ollamaHost), port: ollamaPort)
    }

    private static func endpoint(host: String, port: Int) -> String {
        "http://\(host.contains(":") ? "[\(host)]" : host):\(port)"
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        let name = lower.hasSuffix(".") ? String(lower.dropLast()) : lower
        return name == "localhost" || name.hasSuffix(".localhost")
            || isLoopbackAddress(name)
    }

    private static func isLoopbackAddress(_ host: String) -> Bool {
        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4 && components.first == "127"
            && components.allSatisfy { UInt8($0) != nil }
    }

    private static func validate(
        listenHost: String, listenPort: Int, ollamaHost: String, ollamaPort: Int
    ) throws -> (listenerHost: String, upstreamHost: String) {
        let listener = AppSettings.normalizedHost(listenHost).lowercased()
        guard listener == "localhost" || isLoopbackAddress(listener) else {
            throw ProxyConfigurationError(message: "The proxy must listen on a loopback address.")
        }
        if let error = AppSettings.validationError(
            proxyPort: listenPort, ollamaHost: ollamaHost, ollamaPort: ollamaPort,
            allowsEphemeralPort: true)
        {
            throw ProxyConfigurationError(message: error)
        }
        let upstream = AppSettings.normalizedHost(ollamaHost)
        guard listenPort == 0 || !isLocalHost(upstream) || listenPort != ollamaPort else {
            throw ProxyConfigurationError(
                message: "The proxy and local Ollama server must use different ports.")
        }
        return (listener == "localhost" ? "127.0.0.1" : listener, upstream)
    }
}

private struct ProxyConfigurationError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// The lock protects membership and the shutdown gate. Channels created after
/// shutdown begins close immediately instead of escaping cleanup.
private final class ProxyChannelRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var isClosing = false
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var relays: [ObjectIdentifier: GenerationRelay] = [:]

    func insert(_ channel: Channel) -> Bool {
        let id = ObjectIdentifier(channel)
        lock.lock()
        guard !isClosing else {
            lock.unlock()
            channel.close(promise: nil)
            return false
        }
        channels[id] = channel
        lock.unlock()
        channel.closeFuture.whenComplete { [self] _ in
            lock.lock()
            channels.removeValue(forKey: id)
            lock.unlock()
        }
        return true
    }

    func insert(_ relay: GenerationRelay, downstream: Channel) -> Bool {
        let id = ObjectIdentifier(relay)
        lock.lock()
        guard !isClosing else {
            lock.unlock()
            relay.cancel()
            return false
        }
        relays[id] = relay
        lock.unlock()
        downstream.closeFuture.whenComplete { [self] _ in
            relay.cancel()
            lock.lock()
            relays.removeValue(forKey: id)
            lock.unlock()
        }
        return true
    }

    func beginClosing() -> [Channel] {
        lock.lock()
        isClosing = true
        let openChannels = Array(channels.values)
        let activeRelays = Array(relays.values)
        lock.unlock()
        // Cancellation precedes transport closure, regardless of channel order.
        for relay in activeRelays { relay.cancel() }
        return openChannels
    }
}

/// Each downstream connection forwards one request, then closes. Both sides
/// share an event loop, and all response bytes are handled by StreamTapper.
private final class RequestForwarder: ChannelInboundHandler {
    typealias InboundIn = NIOHTTPServerRequestFull
    typealias OutboundOut = HTTPServerResponsePart

    private let ollamaHost: String
    private let ollamaPort: Int
    private let registry: ProxyChannelRegistry
    private let eventSink: @Sendable (GenerationEvent) -> Void
    private var hasForwardedRequest = false
    private var requestRelay: GenerationRelay?

    init(
        ollamaHost: String, ollamaPort: Int, registry: ProxyChannelRegistry,
        eventSink: @escaping @Sendable (GenerationEvent) -> Void
    ) {
        self.ollamaHost = ollamaHost
        self.ollamaPort = ollamaPort
        self.registry = registry
        self.eventSink = eventSink
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !hasForwardedRequest else { return }
        hasForwardedRequest = true
        let request = unwrapInboundIn(data)
        let body = request.body ?? ByteBuffer()
        let serverChannel = context.channel
        let isGeneration = StreamTapper.isGenerationRequest(path: request.head.uri, body: body)
        let model =
            (try? JSONSerialization.jsonObject(with: Data(body.readableBytesView)))
            .flatMap { $0 as? [String: Any] }?["model"] as? String
        let relay = GenerationRelay(
            request: isGeneration ? GenerationRequest(model: model) : nil, sink: eventSink)
        if isGeneration {
            relay.toolActivity(
                ToolCallParser.resultSubmissions(path: request.head.uri, body: body, at: Date()))
        }
        requestRelay = relay
        let registry = self.registry
        guard registry.insert(relay, downstream: serverChannel) else {
            serverChannel.close(promise: nil)
            return
        }

        var head = request.head
        head.headers.replaceOrAdd(name: "connection", value: "close")
        let upstreamHost = ollamaHost.contains(":") ? "[\(ollamaHost)]" : ollamaHost
        head.headers.replaceOrAdd(name: "host", value: "\(upstreamHost):\(ollamaPort)")
        let forwardedHead = head

        ClientBootstrap(group: serverChannel.eventLoop)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                guard registry.insert(channel) else {
                    return channel.eventLoop.makeFailedFuture(CancellationError())
                }
                // Cancellation was registered first, so closing the client
                // cannot be mistaken for an upstream failure.
                serverChannel.closeFuture.whenComplete { _ in
                    relay.cancel()
                    channel.close(promise: nil)
                }
                guard serverChannel.isActive else {
                    channel.close(promise: nil)
                    return channel.eventLoop.makeFailedFuture(CancellationError())
                }
                return channel.eventLoop.makeSucceededFuture(())
            }
            .connect(host: ollamaHost, port: ollamaPort)
            .flatMap { channel in
                // Happy Eyeballs can initialize several candidate channels.
                // Only the winning connection may emit response telemetry.
                channel.pipeline.addHTTPClientHandlers().flatMap {
                    channel.eventLoop.submit {
                        try channel.pipeline.syncOperations.addHandler(
                            StreamTapper(
                                serverChannel: serverChannel, relay: relay,
                                isGeneration: isGeneration))
                    }
                }.map { channel }
            }
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    guard serverChannel.isActive else {
                        relay.cancel()
                        channel.close(promise: nil)
                        return
                    }
                    channel.write(HTTPClientRequestPart.head(forwardedHead), promise: nil)
                    if body.readableBytes > 0 {
                        channel.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil)
                    }
                    channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { error in
                        relay.fail(
                            "Could not forward request to Ollama: \(error.localizedDescription)")
                        channel.close(promise: nil)
                        serverChannel.close(promise: nil)
                    }
                case .failure(let error):
                    relay.fail("Could not connect to Ollama: \(error.localizedDescription)")
                    guard serverChannel.isActive else { return }
                    serverChannel.write(
                        HTTPServerResponsePart.head(
                            HTTPResponseHead(
                                version: forwardedHead.version, status: .badGateway,
                                headers: [
                                    "content-type": "text/plain", "content-length": "0",
                                    "connection": "close",
                                ])), promise: nil)
                    serverChannel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                        serverChannel.close(promise: nil)
                    }
                }
            }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        requestRelay?.cancel()
        context.close(promise: nil)
    }
}
