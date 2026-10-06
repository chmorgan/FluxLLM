import Foundation

/// Follows a verified local Studio's native inference worker without changing the
/// configured endpoint, requesting generation, loading models, or reading credentials.
/// The production llama.cpp adapter remains the source of every reported value.
public actor UnslothBackendClient: BackendClientProtocol {
    private struct CachedWorker {
        let server: UnslothServer
        let detected: DetectedBackend
    }

    private struct Operation: Equatable {
        let epoch: UInt64
        let workerRevision: UInt64
    }

    private let normal: any BackendClientProtocol
    private let discovery: any UnslothDiscovering
    private var workers: [String: CachedWorker] = [:]
    private var epoch: UInt64 = 0
    private var workerRevision: UInt64 = 0

    public init(
        normal: any BackendClientProtocol = HTTPBackendClient(),
        discovery: any UnslothDiscovering = UnslothProcessDiscovery()
    ) {
        self.normal = normal
        self.discovery = discovery
    }

    public func reset() async {
        epoch &+= 1
        workerRevision &+= 1
        workers.removeAll()
        await discovery.reset()
        await normal.reset()
    }

    public func detect(at baseURL: URL) async throws -> DetectedBackend? {
        // Ordinary remote endpoints do not trigger machine-local process discovery.
        guard let key = Self.localEndpointKey(baseURL) else {
            return try await normal.detect(at: baseURL)
        }
        let requestedEpoch = epoch
        let servers = await discovery.servers()
        try checkEpoch(requestedEpoch)
        let matches = servers.filter { Self.localEndpointKey($0.studioURL) == key }
        guard !matches.isEmpty else { return try await normal.detect(at: baseURL) }
        return try await detection(for: matches, requestedEpoch: requestedEpoch)
    }

    public func discoverLocalBackends() async -> [DetectedBackend] {
        let requestedEpoch = epoch
        let servers = await discovery.servers()
        guard !Task.isCancelled, epoch == requestedEpoch else { return [] }
        let groups = Dictionary(
            grouping: servers.filter {
                Self.localEndpointKey($0.studioURL) != nil
            }, by: { Self.localEndpointKey($0.studioURL)! })
        var results: [DetectedBackend] = []
        for key in groups.keys.sorted() {
            guard let group = groups[key] else { continue }
            do {
                results.append(try await detection(for: group, requestedEpoch: requestedEpoch))
            } catch is CancellationError {
                return []
            } catch {
                // One unresponsive Studio must not hide other verified local instances.
                guard let studio = group.first else { continue }
                results.append(unavailable(studio.studioURL, detail: error.localizedDescription))
            }
        }
        guard !Task.isCancelled, epoch == requestedEpoch else { return [] }
        return results
    }

    public func sample(_ configuration: BackendConfiguration) async throws -> BackendSample {
        guard configuration.kind == .unsloth else { return try await normal.sample(configuration) }
        guard let key = Self.localEndpointKey(configuration.baseURL) else {
            throw BackendClientError.configurationRequired(
                "Enter the local Unsloth Studio HTTP address using localhost, 127.0.0.1 or [::1], without an API path or credentials."
            )
        }
        let requestedEpoch = epoch
        let servers = await discovery.servers()
        try checkEpoch(requestedEpoch)
        let matches = servers.filter { Self.localEndpointKey($0.studioURL) == key }
        guard !matches.isEmpty else {
            await discardWorker(key)
            throw BackendClientError.configurationRequired(
                "No verified Unsloth Studio is running at this address. Start local Unsloth Studio and check its port."
            )
        }
        guard matches.count == 1, let server = matches.first else {
            await discardWorker(key)
            throw BackendClientError.configurationRequired(Self.ambiguousMessage)
        }
        guard server.workerURL != nil, server.workerIdentity != nil else {
            await discardWorker(key)
            throw BackendClientError.configurationRequired(Self.unloadedMessage)
        }
        let (detected, operation) = try await verifiedWorker(server, requestedEpoch: requestedEpoch)
        guard detected.supportsLiveMetrics else {
            throw BackendClientError.configurationRequired(Self.metricsMessage)
        }
        guard detected.isReady else {
            throw BackendClientError.configurationRequired(
                detected.detail
                    ?? "The Unsloth inference worker is not ready. Load a model in Studio.")
        }
        guard let workerURL = server.workerURL else { throw BackendClientError.invalidResponse }
        do {
            let sample = try await normal.sample(
                .init(
                    kind: .llamaCpp, baseURL: workerURL, model: configuration.model,
                    proxyPort: configuration.proxyPort))
            try check(operation)
            // Discovery cheaply rechecks cached process birth identities. A worker can
            // disappear or change during an HTTP request, even on the same port.
            let current = await discovery.servers().filter {
                Self.localEndpointKey($0.studioURL) == key
            }
            try check(operation)
            guard current.count == 1, current.first == server else {
                throw BackendClientError.configurationRequired(
                    "Unsloth's inference processes changed during monitoring. The next poll will reconnect to the current worker."
                )
            }
            guard sample.kind == .llamaCpp else { throw BackendClientError.invalidResponse }
            return BackendSample(
                kind: .unsloth, timestamp: sample.timestamp, model: sample.model,
                isReady: sample.isReady, currentTPS: sample.currentTPS, basis: sample.basis,
                runningRequests: sample.runningRequests, queuedRequests: sample.queuedRequests,
                outputTokens: sample.outputTokens, promptTokens: sample.promptTokens,
                inferenceGPUPercent: sample.inferenceGPUPercent, gpuSource: sample.gpuSource,
                detail: sample.detail)
        } catch {
            // An old session must not clear the new session's cache after reset.
            if operation == currentOperation, !Task.isCancelled {
                await discardWorker(key)
            }
            throw error
        }
    }

    private func detection(for servers: [UnslothServer], requestedEpoch: UInt64) async throws
        -> DetectedBackend
    {
        guard let studio = servers.first else { throw BackendClientError.invalidResponse }
        guard servers.count == 1 else {
            return unavailable(studio.studioURL, detail: Self.ambiguousMessage)
        }
        guard studio.workerURL != nil, studio.workerIdentity != nil else {
            return unavailable(studio.studioURL, detail: Self.unloadedMessage)
        }
        do {
            let (native, operation) = try await verifiedWorker(
                studio, requestedEpoch: requestedEpoch)
            let current = await discovery.servers().filter {
                Self.localEndpointKey($0.studioURL) == Self.localEndpointKey(studio.studioURL)
            }
            try check(operation)
            guard current.count == 1, current.first == studio else {
                throw BackendClientError.configurationRequired(
                    "Unsloth's inference processes changed during discovery. Monitoring will retry."
                )
            }
            return DetectedBackend(
                kind: .unsloth, baseURL: studio.studioURL, version: native.version,
                isReady: native.isReady && native.supportsLiveMetrics,
                supportsLiveMetrics: native.supportsLiveMetrics,
                detail: native.supportsLiveMetrics ? native.detail : Self.metricsMessage)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkEpoch(requestedEpoch)
            return unavailable(studio.studioURL, detail: error.localizedDescription)
        }
    }

    private func verifiedWorker(_ server: UnslothServer, requestedEpoch: UInt64) async throws
        -> (DetectedBackend, Operation)
    {
        try checkEpoch(requestedEpoch)
        guard let key = Self.localEndpointKey(server.studioURL),
            let workerURL = server.workerURL, server.workerIdentity != nil,
            Self.localEndpointKey(workerURL) != nil
        else {
            throw BackendClientError.configurationRequired(
                "Unsloth monitoring requires a verified local llama.cpp inference worker.")
        }
        if let cached = workers[key], cached.server == server {
            return (cached.detected, currentOperation)
        }
        if workers[key] != nil {
            // In particular, invalidate HTTPBackendClient's model_alias for PID reuse
            // on an unchanged port. Neither model names nor counter history cross workers.
            await discardWorker(key)
            try checkEpoch(requestedEpoch)
        }
        let operation = currentOperation
        guard let detected = try await normal.detect(at: workerURL), detected.kind == .llamaCpp
        else {
            try check(operation)
            throw BackendClientError.configurationRequired(
                "The verified Unsloth worker does not expose llama.cpp monitoring. Load a GGUF model in Studio and enable its metrics support."
            )
        }
        try check(operation)
        // Bound retained capability records even when many local instances are found.
        if workers.count >= 16 { workers.removeAll() }
        workers[key] = CachedWorker(server: server, detected: detected)
        return (detected, operation)
    }

    private func discardWorker(_ key: String) async {
        guard workers[key] != nil else { return }
        workerRevision &+= 1
        workers.removeAll()
        await normal.reset()
    }

    private var currentOperation: Operation { .init(epoch: epoch, workerRevision: workerRevision) }

    private func check(_ operation: Operation) throws {
        try Task.checkCancellation()
        guard operation == currentOperation else { throw CancellationError() }
    }

    private func checkEpoch(_ requestedEpoch: UInt64) throws {
        try Task.checkCancellation()
        guard requestedEpoch == epoch else { throw CancellationError() }
    }

    private func unavailable(_ studioURL: URL, detail: String) -> DetectedBackend {
        .init(
            kind: .unsloth, baseURL: studioURL, isReady: false,
            supportsLiveMetrics: false, detail: detail)
    }

    private static let ambiguousMessage =
        "Unsloth has multiple verified inference workers at this Studio address. Select one loaded model in Studio before monitoring."
    private static let unloadedMessage =
        "Load a GGUF model in Unsloth Studio to start its local inference worker."
    private static let metricsMessage =
        "The Unsloth inference worker has metrics disabled. Enable metrics support in Studio's llama.cpp backend and reload the model."

    /// The conventional localhost name aliases the verified IPv4 loopback endpoint
    /// without a DNS lookup. Other hosts, URL credentials, and API paths cannot match.
    private static func localEndpointKey(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "http", components.user == nil,
            components.password == nil, components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/", let hostname = components.host
        else { return nil }
        let hostnameKey = hostname.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: "[]"))
        guard ["localhost", "127.0.0.1", "::1"].contains(hostnameKey) else { return nil }
        let host = hostnameKey == "localhost" ? "127.0.0.1" : hostnameKey
        let port = components.port ?? 80
        guard (1...65535).contains(port) else { return nil }
        return "http|\(host)|\(port)"
    }
}
