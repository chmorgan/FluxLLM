import Foundation

/// An explicitly supplied access token authorizes only this bounded, passive Studio read.
struct UnslothStudioMonitor: Sendable {
    private let transport: HTTPBackendClient.Transport
    static let maximumEntries = 50

    init(transport: HTTPBackendClient.Transport? = nil) {
        if let transport {
            self.transport = transport
        } else {
            let bounded = BoundedBackendTransport()
            self.transport = { try await bounded.send($0) }
        }
    }

    func snapshot(at baseURL: URL, token: String, sourceEpoch: UUID) async throws
        -> NativeRequestSnapshot?
    {
        try Task.checkCancellation()
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "http", components.user == nil,
            components.password == nil, components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            (1...65535).contains(components.port ?? 80),
            let host = components.host?.lowercased().trimmingCharacters(
                in: CharacterSet(charactersIn: "[]")),
            ["localhost", "127.0.0.1", "::1"].contains(host)
        else { throw BackendClientError.invalidEndpoint }
        guard !token.isEmpty, token.utf8.count <= 16_384,
            token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { throw BackendClientError.invalidResponse }
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/inference/monitor"),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await transport(request)
        try Task.checkCancellation()
        guard response.data.count <= HTTPBackendClient.maximumResponseBytes else {
            throw BackendClientError.responseTooLarge
        }
        guard (200..<300).contains(response.statusCode) else {
            throw BackendClientError.httpStatus(response.statusCode)
        }
        let body = try JSONDecoder().decode(Monitor.self, from: response.data)
        guard body.loggingEnabled else { return nil }
        guard body.entries.count <= Self.maximumEntries else {
            throw BackendClientError.invalidResponse
        }
        var identities: Set<String> = []
        var requests: [NativeRequestObservation] = []
        for entry in body.entries {
            guard identities.insert(entry.id).inserted else {
                throw BackendClientError.invalidResponse
            }
            requests.append(entry.observation)
        }
        // The retained monitor history can evict entries. Absence cannot prove completion.
        return NativeRequestSnapshot(
            sourceEpoch: sourceEpoch, source: .studioMonitor, requests: requests, isComplete: false)
    }

    private struct Monitor: Decodable {
        let loggingEnabled: Bool
        let entries: [Entry]

        private enum CodingKeys: String, CodingKey {
            case loggingEnabled = "logging_enabled"
            case entries
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            loggingEnabled = try fields.decode(Bool.self, forKey: .loggingEnabled)
            entries = loggingEnabled ? try fields.decode([Entry].self, forKey: .entries) : []
        }
    }

    private struct Entry: Decodable {
        let id: String
        let observation: NativeRequestObservation

        private enum CodingKeys: String, CodingKey {
            case id, model, status
            case startedAt = "started_at"
            case finishedAt = "finished_at"
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case tokensPerSecond = "tok_per_sec"
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(String.self, forKey: .id)
            guard !id.isEmpty, id.utf8.count <= 512 else {
                throw BackendClientError.invalidResponse
            }
            let status: ObservedRequestStatus
            switch try fields.decode(String.self, forKey: .status) {
            case "running": status = .running
            case "completed": status = .completed
            case "cancelled": status = .cancelled
            case "error": status = .failed
            default: throw BackendClientError.invalidResponse
            }
            let model = try fields.decodeIfPresent(String.self, forKey: .model)
            guard (model?.utf8.count ?? 0) <= 1_024 else {
                throw BackendClientError.invalidResponse
            }
            let start = try Self.date(fields, key: .startedAt)
            let end = try Self.date(fields, key: .finishedAt)
            if let start, let end, end < start {
                throw BackendClientError.invalidResponse
            }
            let prompt = try Self.count(fields, key: .promptTokens)
            let completion = try Self.count(fields, key: .completionTokens)
            let rate = try fields.decodeIfPresent(Double.self, forKey: .tokensPerSecond)
            guard rate.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw BackendClientError.invalidResponse
            }
            observation = NativeRequestObservation(
                id: id, model: model, startedAt: start,
                endedAt: status == .running ? nil : end,
                outputTokens: completion, promptTokens: prompt, liveTPS: rate, status: status)
        }

        private static func date(_ fields: KeyedDecodingContainer<CodingKeys>, key: CodingKeys)
            throws -> Date?
        {
            guard let seconds = try fields.decodeIfPresent(Double.self, forKey: key) else {
                return nil
            }
            guard seconds.isFinite, seconds >= 0 else { throw BackendClientError.invalidResponse }
            return Date(timeIntervalSince1970: seconds)
        }

        private static func count(_ fields: KeyedDecodingContainer<CodingKeys>, key: CodingKeys)
            throws -> Int?
        {
            let value = try fields.decodeIfPresent(Int.self, forKey: key)
            guard value.map({ $0 >= 0 }) ?? true else { throw BackendClientError.invalidResponse }
            return value
        }
    }
}
