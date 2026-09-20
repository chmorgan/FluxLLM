import CoreFoundation
import Foundation

/// The transport boundary makes backend probes deterministic without starting an inference server.
public struct BackendHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public enum BackendClientError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint, invalidResponse, responseTooLarge, unsupportedMetrics
    case httpStatus(Int)
    case configurationRequired(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Enter an HTTP or HTTPS backend address without credentials, a query, or a fragment."
        case .invalidResponse: "The backend returned an unrecognized response."
        case .responseTooLarge: "The backend response exceeded the monitoring size limit."
        case .unsupportedMetrics: "This backend did not expose the expected monitoring metrics."
        case .configurationRequired(let message): message
        case .httpStatus(let code):
            code == 401 || code == 403
                ? "The backend requires authentication. Authenticated monitoring is not configured."
                : "The backend returned HTTP \(code)."
        }
    }
}

/// Read-only native monitoring. No completion, activation, or model-download route is used.
public actor HTTPBackendClient: BackendClientProtocol {
    public typealias Transport = @Sendable (URLRequest) async throws -> BackendHTTPResponse
    public static let maximumResponseBytes = 2 * 1_024 * 1_024

    private let transport: Transport
    private let monotonicTime: @Sendable () -> TimeInterval
    private let wallClock: @Sendable () -> Date
    private var counters: [String: CounterSnapshot] = [:]
    private var knownModels: [String: String] = [:]

    private struct CounterSnapshot {
        let time: TimeInterval
        let values: [String: Double]
        let processStart: Double?
    }

    public init(
        transport: Transport? = nil,
        monotonicTime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport ?? { request in try await BoundedBackendRequest().send(request) }
        self.monotonicTime = monotonicTime
        self.wallClock = wallClock
    }

    public func detect(at baseURL: URL) async throws -> DetectedBackend? {
        _ = try Self.endpoint(baseURL, path: "metrics")
        // A shared port is not an identity. Prefer backend-specific metric names, then
        // native response shapes; generic /v1/models compatibility is insufficient.
        if let metrics = try await optionalMetrics(baseURL) {
            if let build = metrics.matching("rapid_mlx_build_info").first {
                let status = try await optionalJSON(baseURL, path: "v1/status")
                return DetectedBackend(
                    kind: .rapidMLX, baseURL: baseURL, version: build.labels["version"],
                    isReady: status.map(Self.rapidReady) ?? false,
                    detail: status == nil
                        ? "Rapid-MLX detected; its status endpoint is unavailable." : nil)
            }
            if metrics.samples.contains(where: { $0.name.hasPrefix("vllm:") }) {
                let ready: Bool
                do { ready = try await vllmReady(baseURL) } catch {
                    try Task.checkCancellation()
                    ready = false
                }
                return DetectedBackend(kind: .vllm, baseURL: baseURL, isReady: ready)
            }
            if metrics.samples.contains(where: { $0.name.hasPrefix("llamacpp:") }) {
                return DetectedBackend(kind: .llamaCpp, baseURL: baseURL)
            }
        }

        if let version = try await optionalJSON(baseURL, path: "api/version"),
            let versionString = version["version"] as? String,
            let tags = try await optionalJSON(baseURL, path: "api/tags"),
            tags["models"] is [[String: Any]]
        {
            return DetectedBackend(
                kind: .ollama, baseURL: baseURL, version: versionString,
                supportsLiveMetrics: false)
        }
        if let status = try await optionalJSON(baseURL, path: "v1/status"),
            Self.isRapidStatus(status)
        {
            return DetectedBackend(
                kind: .rapidMLX, baseURL: baseURL, isReady: Self.rapidReady(status))
        }
        if let props = try await optionalJSON(baseURL, path: "props"), Self.isLlamaProps(props) {
            let enabled = props["endpoint_metrics"] as? Bool ?? false
            return DetectedBackend(
                kind: .llamaCpp, baseURL: baseURL, version: props["build_info"] as? String,
                isReady: enabled, supportsLiveMetrics: enabled,
                detail: enabled ? nil : "Start llama.cpp with --metrics to enable monitoring.")
        }
        if let models = try await optionalJSON(baseURL, path: "models"), Self.isLlamaRouter(models)
        {
            return DetectedBackend(
                kind: .llamaCpp, baseURL: baseURL, isReady: false, supportsLiveMetrics: false,
                detail: "Select a loaded llama.cpp router model in Settings.")
        }
        return nil
    }

    public func reset() async {
        counters.removeAll()
        knownModels.removeAll()
    }

    public func sample(_ configuration: BackendConfiguration) async throws -> BackendSample {
        do {
            switch configuration.kind {
            case .ollama: return try await sampleOllama(configuration)
            case .vllm: return try await sampleVLLM(configuration)
            case .rapidMLX: return try await sampleRapid(configuration)
            case .llamaCpp: return try await sampleLlama(configuration)
            }
        } catch {
            // Never bridge an outage with a throughput estimate on reconnection.
            counters.removeValue(forKey: counterKey(configuration))
            throw error
        }
    }

    private func sampleOllama(_ configuration: BackendConfiguration) async throws -> BackendSample {
        let version = try await json(configuration.baseURL, path: "api/version")
        guard version["version"] is String else { throw BackendClientError.invalidResponse }
        let status = try await json(configuration.baseURL, path: "api/ps")
        guard let models = status["models"] as? [[String: Any]] else {
            throw BackendClientError.invalidResponse
        }
        let names = models.compactMap { ($0["model"] ?? $0["name"]) as? String }
        return BackendSample(
            kind: .ollama, timestamp: wallClock(), model: configuration.model ?? names.first,
            basis: .estimated)
    }

    private func sampleVLLM(_ configuration: BackendConfiguration) async throws -> BackendSample {
        let metrics = try await fetchMetrics(configuration.baseURL)
        guard metrics.samples.contains(where: { $0.name.hasPrefix("vllm:") }) else {
            throw BackendClientError.unsupportedMetrics
        }
        let generated = metrics.matching("vllm:generation_tokens_total", model: configuration.model)
        let ready = try await vllmReady(configuration.baseURL)
        let running = Self.integer(
            metrics.sum("vllm:num_requests_running", model: configuration.model))
        let queued = Self.integer(
            metrics.sum("vllm:num_requests_waiting", model: configuration.model))
        let rate = counterRate(
            generated, configuration: configuration,
            processStart: metrics.sum("process_start_time_seconds"))
        let names = Set(generated.compactMap { $0.labels["model_name"] ?? $0.labels["model"] })
        return BackendSample(
            kind: .vllm, timestamp: wallClock(),
            model: configuration.model ?? (names.count == 1 ? names.first : nil),
            isReady: ready, currentTPS: ready ? rate : nil, basis: .serverAggregate,
            runningRequests: running,
            queuedRequests: queued,
            outputTokens: Self.integer(
                metrics.sum("vllm:generation_tokens_total", model: configuration.model)),
            promptTokens: Self.integer(
                metrics.sum("vllm:prompt_tokens_total", model: configuration.model)),
            detail: !ready
                ? "vLLM is responding but is not ready to serve requests."
                : generated.isEmpty ? "Token counters are unavailable for the selected model." : nil
        )
    }

    private func vllmReady(_ baseURL: URL) async throws -> Bool {
        do {
            _ = try await get(baseURL, path: "health")
            return true
        } catch BackendClientError.httpStatus(let code) where code == 404 || code == 405 {
            // Older or reverse-proxied installations may expose only /metrics.
            return true
        } catch BackendClientError.httpStatus(let code) where code == 503 {
            return false
        }
    }

    private func sampleRapid(_ configuration: BackendConfiguration) async throws -> BackendSample {
        let status = try await json(configuration.baseURL, path: "v1/status")
        guard Self.isRapidStatus(status) else { throw BackendClientError.invalidResponse }
        let running = Self.integer(Self.number(status["num_running"]))
        let reported = Self.nonnegative(Self.number(status["generation_tps"]))
        // This value can survive the last request. Preserve it as a reported average;
        // MetricsStore gates the live display by runningRequests and retains the last rate.
        let current = running == nil ? nil : reported
        return BackendSample(
            kind: .rapidMLX, timestamp: wallClock(), model: status["model"] as? String,
            isReady: Self.rapidReady(status), currentTPS: current, basis: .serverReportedAverage,
            runningRequests: running,
            queuedRequests: Self.integer(Self.number(status["num_waiting"])),
            outputTokens: Self.integer(Self.number(status["total_completion_tokens"])),
            promptTokens: Self.integer(Self.number(status["total_prompt_tokens"])),
            detail: Self.rapidReady(status) ? nil : "The configured Rapid-MLX model is not loaded.")
    }

    private func sampleLlama(_ configuration: BackendConfiguration) async throws -> BackendSample {
        let metrics: PrometheusMetrics
        do {
            metrics = try await fetchMetrics(configuration.baseURL, model: configuration.model)
        } catch {
            try Task.checkCancellation()
            if let props = try await optionalJSON(
                configuration.baseURL, path: "props", model: configuration.model),
                Self.isLlamaProps(props), props["endpoint_metrics"] as? Bool == false
            {
                throw BackendClientError.configurationRequired(
                    "Start llama.cpp with --metrics to enable monitoring.")
            }
            if configuration.model == nil,
                let models = try await optionalJSON(configuration.baseURL, path: "models"),
                Self.isLlamaRouter(models)
            {
                throw BackendClientError.configurationRequired(
                    "Select a loaded llama.cpp router model in Settings.")
            }
            throw error
        }
        guard metrics.samples.contains(where: { $0.name.hasPrefix("llamacpp:") }) else {
            throw BackendClientError.unsupportedMetrics
        }
        let running = Self.integer(metrics.sum("llamacpp:requests_processing"))
        let reported = Self.nonnegative(metrics.sum("llamacpp:predicted_tokens_seconds"))
        // llama.cpp's documented gauge is an average; older counter implementations
        // publish completed work in batches, so counter deltas are not a live token feed.
        let current = running == nil ? nil : reported
        if knownModels[counterKey(configuration)] == nil,
            let props = try await optionalJSON(
                configuration.baseURL, path: "props", model: configuration.model)
        {
            knownModels[counterKey(configuration)] = props["model_alias"] as? String
        }
        return BackendSample(
            kind: .llamaCpp, timestamp: wallClock(),
            model: configuration.model ?? knownModels[counterKey(configuration)],
            currentTPS: current, basis: .serverReportedAverage, runningRequests: running,
            queuedRequests: Self.integer(metrics.sum("llamacpp:requests_deferred")),
            outputTokens: Self.integer(metrics.sum("llamacpp:tokens_predicted_total")),
            promptTokens: Self.integer(metrics.sum("llamacpp:prompt_tokens_total")))
    }

    private func counterKey(_ configuration: BackendConfiguration) -> String {
        "\(configuration.kind.rawValue)|\(configuration.baseURL.absoluteString)|\(configuration.model ?? "")"
    }

    private func counterRate(
        _ samples: [PrometheusMetric], configuration: BackendConfiguration, processStart: Double?
    ) -> Double? {
        let key = counterKey(configuration)
        let time = monotonicTime()
        let values = Dictionary(
            uniqueKeysWithValues: samples.filter { $0.value >= 0 }.map { ($0.seriesKey, $0.value) })
        let previous = counters.updateValue(
            CounterSnapshot(time: time, values: values, processStart: processStart), forKey: key)
        guard !values.isEmpty, let previous, Set(previous.values.keys) == Set(values.keys) else {
            return nil
        }
        guard previous.processStart == processStart else { return nil }
        let interval = time - previous.time
        guard interval > 0, interval <= 5 else { return nil }
        var delta = 0.0
        for (series, value) in values {
            guard let oldValue = previous.values[series], value >= oldValue else { return nil }
            delta += value - oldValue
        }
        let rate = delta / interval
        return rate.isFinite ? rate : nil
    }

    private func fetchMetrics(_ baseURL: URL, model: String? = nil) async throws
        -> PrometheusMetrics
    {
        let response = try await get(baseURL, path: "metrics", model: model)
        guard let text = String(data: response.data, encoding: .utf8) else {
            throw BackendClientError.invalidResponse
        }
        return PrometheusMetrics(text)
    }

    private func optionalMetrics(_ baseURL: URL) async throws -> PrometheusMetrics? {
        do { return try await fetchMetrics(baseURL) } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func optionalJSON(_ baseURL: URL, path: String, model: String? = nil) async throws
        -> [String: Any]?
    {
        do { return try await json(baseURL, path: path, model: model) } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func json(_ baseURL: URL, path: String, model: String? = nil) async throws -> [String:
        Any]
    {
        let response = try await get(baseURL, path: path, model: model)
        guard let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        else {
            throw BackendClientError.invalidResponse
        }
        return value
    }

    private func get(_ baseURL: URL, path: String, model: String? = nil) async throws
        -> BackendHTTPResponse
    {
        try Task.checkCancellation()
        let url = try Self.endpoint(baseURL, path: path, model: model)
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        request.setValue(
            path == "metrics" ? "text/plain; version=0.0.4" : "application/json",
            forHTTPHeaderField: "Accept")
        let response = try await transport(request)
        try Task.checkCancellation()
        guard response.data.count <= Self.maximumResponseBytes else {
            throw BackendClientError.responseTooLarge
        }
        guard (200..<300).contains(response.statusCode) else {
            throw BackendClientError.httpStatus(response.statusCode)
        }
        return response
    }

    private static func endpoint(_ baseURL: URL, path: String, model: String? = nil) throws -> URL {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.host?.isEmpty == false, components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else {
            throw BackendClientError.invalidEndpoint
        }
        guard
            var endpoint = URLComponents(
                url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else {
            throw BackendClientError.invalidEndpoint
        }
        if path == "metrics" || path == "props" {
            // llama.cpp's router can otherwise load a model merely to answer a GET.
            // Unknown query fields are ignored by the other supported metrics servers.
            endpoint.queryItems = [URLQueryItem(name: "autoload", value: "false")]
            if let model, !model.isEmpty {
                endpoint.queryItems?.append(URLQueryItem(name: "model", value: model))
            }
        }
        guard let url = endpoint.url else { throw BackendClientError.invalidEndpoint }
        return url
    }

    private static func isRapidStatus(_ status: [String: Any]) -> Bool {
        guard let state = status["status"] as? String,
            ["idle", "generating", "not_loaded"].contains(state),
            status["requests"] is [Any]
        else { return false }
        return state == "not_loaded"
            || (status["num_running"] != nil
                && (status["generation_tps"] != nil
                    || (status["uptime_s"] != nil && status["total_completion_tokens"] != nil)))
    }

    private static func rapidReady(_ status: [String: Any]) -> Bool {
        guard let state = status["status"] as? String else { return false }
        return state == "idle" || state == "generating"
    }

    private static func isLlamaProps(_ props: [String: Any]) -> Bool {
        props["default_generation_settings"] is [String: Any]
            && props["total_slots"] is NSNumber && props["model_alias"] is String
    }

    private static func isLlamaRouter(_ models: [String: Any]) -> Bool {
        guard let entries = models["data"] as? [[String: Any]] else { return false }
        return entries.contains { entry in
            entry["id"] is String && entry["path"] is String
                && (entry["status"] as? [String: Any])?["value"] is String
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    private static func nonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func integer(_ value: Double?) -> Int? {
        guard let value = nonnegative(value), value < Double(Int.max) else { return nil }
        return Int(value)
    }
}

/// A bounded, ephemeral request owns its session until completion. Cancellation and
/// delegate callbacks share a lock; only the first terminal callback resumes the task.
private final class BoundedBackendRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BackendHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var statusCode = 0
    private var cancelled = false

    func send(_ request: URLRequest) async throws -> BackendHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 1.5
                configuration.timeoutIntervalForResource = 3
                configuration.urlCredentialStorage = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCache = nil
                let session = URLSession(
                    configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let shouldCancel = lock.withLock {
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    return cancelled
                }
                if shouldCancel { finish(.failure(CancellationError())) } else { task.resume() }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(BackendClientError.invalidResponse))
            return
        }
        guard response.expectedContentLength <= HTTPBackendClient.maximumResponseBytes else {
            completionHandler(.cancel)
            finish(.failure(BackendClientError.responseTooLarge))
            return
        }
        lock.withLock { statusCode = response.statusCode }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let overflow = lock.withLock {
            guard data.count + chunk.count <= HTTPBackendClient.maximumResponseBytes else {
                return true
            }
            data.append(chunk)
            return false
        }
        if overflow { finish(.failure(BackendClientError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        if let error {
            finish(.failure(error))
        } else {
            let response = lock.withLock { BackendHTTPResponse(statusCode: statusCode, data: data) }
            finish(.success(response))
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Detection must never follow redirects to another host or send credentials.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func finish(_ result: Result<BackendHTTPResponse, Error>) {
        let state = lock.withLock {
            () -> (CheckedContinuation<BackendHTTPResponse, Error>?, URLSession?) in
            let state = (continuation, session)
            continuation = nil
            session = nil
            task = nil
            return state
        }
        state.1?.invalidateAndCancel()
        state.0?.resume(with: result)
    }
}
