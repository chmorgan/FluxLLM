import Combine
import Darwin
import Foundation

/// Session preferences. Existing saved preferences are read for compatibility, never rewritten.
@MainActor
public final class AppSettings: ObservableObject {
    @Published public var proxyPort: Int
    @Published public var ollamaHost: String
    @Published public var ollamaPort: Int
    @Published public var autoStartProxy: Bool
    @Published public var showMenuBarTokensPerSecond: Bool
    @Published public var showMenuBarLogo: Bool
    @Published public var backendSelection: BackendSelection
    @Published public var backendEndpoints: [BackendKind: String]
    @Published public var llamaCppModel: String
    @Published public var lastAutomaticBackendID: String?
    /// Optional, session-only Studio API key or monitor token for recorded request history.
    @Published public var unslothMonitorToken: String?
    /// Session-only manual worker key override. Nil uses automatic authentication;
    /// automatically discovered worker secrets remain in the backend client.
    @Published public var unslothWorkerAPIKey: String?

    private let settingsKey = "appSettings"

    public init(defaults: UserDefaults = .standard, legacyDefaults: UserDefaults? = nil) {
        let currentData = defaults.data(forKey: settingsKey)
        var snapshot = currentData.flatMap {
            try? JSONDecoder().decode(SettingsSnapshot.self, from: $0)
        }
        if defaults.object(forKey: settingsKey) == nil {
            let legacyData =
                legacyDefaults?.data(forKey: settingsKey)
                ?? (defaults === UserDefaults.standard
                    ? defaults.persistentDomain(forName: "com.cmorgan.OllamaFlux")?[settingsKey]
                        as? Data
                    : nil)
            if let legacyData,
                let legacy = try? JSONDecoder().decode(SettingsSnapshot.self, from: legacyData),
                Self.validationError(
                    proxyPort: legacy.proxyPort, ollamaHost: legacy.ollamaHost,
                    ollamaPort: legacy.ollamaPort) == nil
            {
                snapshot = legacy
            }
        }
        proxyPort = snapshot?.proxyPort ?? 11435
        ollamaHost = snapshot?.ollamaHost ?? "localhost"
        ollamaPort = snapshot?.ollamaPort ?? 11434
        autoStartProxy = snapshot?.autoStartProxy ?? true
        showMenuBarTokensPerSecond = snapshot?.showMenuBarTokensPerSecond ?? true
        showMenuBarLogo = snapshot?.showMenuBarLogo ?? true
        backendSelection = snapshot?.backendSelection ?? .automatic
        backendEndpoints = Dictionary(
            uniqueKeysWithValues: BackendKind.allCases
                .filter { $0 != .ollama }
                .map { ($0, snapshot?.backendEndpoints?[$0.rawValue] ?? $0.defaultEndpoint) })
        llamaCppModel = snapshot?.llamaCppModel ?? ""
        lastAutomaticBackendID = snapshot?.lastAutomaticBackendID
        unslothMonitorToken = nil
        unslothWorkerAPIKey = nil
    }

    public var configurationError: String? {
        Self.validationError(
            proxyPort: proxyPort, ollamaHost: ollamaHost, ollamaPort: ollamaPort)
    }

    public var normalizedOllamaHost: String { Self.normalizedHost(ollamaHost) }

    /// Updates manual session credentials without changing backend selection or saved preferences.
    /// A blank worker override restores automatic authentication.
    func applyUnslothCredentials(workerAPIKey: String, monitorToken: String) throws {
        let normalizedWorkerKey = try Self.normalizedUnslothWorkerAPIKey(workerAPIKey)
        let normalizedMonitorToken = monitorToken.trimmingCharacters(in: .whitespacesAndNewlines)
        unslothWorkerAPIKey = normalizedWorkerKey
        unslothMonitorToken = normalizedMonitorToken.isEmpty ? nil : normalizedMonitorToken
    }

    public func configuration(for kind: BackendKind) throws -> BackendConfiguration {
        if kind == .ollama {
            if let error = configurationError { throw SettingsError.invalid(error) }
            var components = URLComponents()
            components.scheme = "http"
            let host = normalizedOllamaHost
            components.host = host.contains(":") ? "[\(host)]" : host
            components.port = ollamaPort
            guard let url = components.url else {
                throw SettingsError.invalid("Enter a valid Ollama host and port.")
            }
            return BackendConfiguration(kind: kind, baseURL: url, proxyPort: proxyPort)
        }
        let url = try Self.endpointURL(backendEndpoints[kind] ?? kind.defaultEndpoint)
        if kind == .unsloth { try Self.validateUnslothEndpoint(url) }
        let model = llamaCppModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let monitorToken = unslothMonitorToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workerAPIKey =
            kind == .unsloth ? try Self.normalizedUnslothWorkerAPIKey(unslothWorkerAPIKey) : nil
        return BackendConfiguration(
            kind: kind, baseURL: url,
            model: kind == .llamaCpp && !model.isEmpty ? model : nil,
            proxyPort: proxyPort,
            studioMonitorToken: kind == .unsloth && monitorToken?.isEmpty == false
                ? monitorToken : nil,
            workerAPIKey: workerAPIKey)
    }

    public nonisolated static func endpointURL(_ endpoint: String) throws -> URL {
        let text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.port.map({ (1...65535).contains($0) }) ?? true
        else {
            throw SettingsError.invalid(
                "Enter an http:// or https:// backend URL without credentials, a query, or a fragment."
            )
        }
        components.scheme = scheme
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else {
            throw SettingsError.invalid("Enter a valid backend URL.")
        }
        return url
    }

    /// Passive Unsloth monitoring resolves the local worker behind Studio.
    /// A public API URL is not the native metrics endpoint.
    public nonisolated static func validateUnslothEndpoint(_ url: URL) throws {
        guard url.scheme == "http", LocalBackendEndpoint(url) != nil,
            url.path.isEmpty || url.path == "/"
        else {
            throw SettingsError.invalid(
                "Enter the local Unsloth Studio address, such as http://127.0.0.1:8888, without an API path. Remote Unsloth monitoring is not supported."
            )
        }
    }

    public nonisolated static func normalizedUnslothWorkerAPIKey(_ key: String?) throws -> String? {
        guard let key else { return nil }
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.utf8.count <= 16_384,
            normalized.utf8.allSatisfy({ (33...126).contains($0) })
        else {
            throw SettingsError.invalid(
                "Enter a worker API key using printable ASCII characters without spaces, up to 16,384 bytes."
            )
        }
        return normalized
    }

    public nonisolated static func validationError(
        proxyPort: Int, ollamaHost: String, ollamaPort: Int,
        allowsEphemeralPort: Bool = false
    ) -> String? {
        let minimumPort = allowsEphemeralPort ? 0 : 1
        guard (minimumPort...65535).contains(proxyPort), (1...65535).contains(ollamaPort) else {
            return "Ports must be between 1 and 65535."
        }
        let host = normalizedHost(ollamaHost)
        let validHost: Bool
        if host.contains(":") {
            var address = in6_addr()
            validHost = host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
        } else {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
            validHost = !host.isEmpty && host.rangeOfCharacter(from: allowed.inverted) == nil
        }
        guard validHost else {
            return "Enter an Ollama host name or IP address, without a URL scheme or path."
        }
        if ["localhost", "localhost.", "127.0.0.1", "::1"].contains(host.lowercased()),
            proxyPort == ollamaPort
        {
            return "The proxy and local Ollama server must use different ports."
        }
        return nil
    }

    public nonisolated static func normalizedHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.contains(":") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}

/// Extra fields from earlier settings snapshots are intentionally ignored. This
/// keeps existing proxy preferences while removing controls with no POC behavior.
private struct SettingsSnapshot: Decodable {
    let proxyPort: Int
    let ollamaHost: String
    let ollamaPort: Int
    let autoStartProxy: Bool
    let showMenuBarTokensPerSecond: Bool?
    let showMenuBarLogo: Bool?
    let backendSelection: BackendSelection?
    let backendEndpoints: [String: String]?
    let llamaCppModel: String?
    let lastAutomaticBackendID: String?
}

public enum SettingsError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}
