import Combine
import Darwin
import Foundation

/// Persisted display and backend preferences. Connection drafts take effect on Apply.
@MainActor
public final class AppSettings: ObservableObject {
    @Published public var proxyPort: Int { didSet { save() } }
    @Published public var ollamaHost: String { didSet { save() } }
    @Published public var ollamaPort: Int { didSet { save() } }
    @Published public var autoStartProxy: Bool { didSet { save() } }
    @Published public var showMenuBarTokensPerSecond: Bool { didSet { save() } }
    @Published public var showMenuBarLogo: Bool { didSet { save() } }
    @Published public var backendSelection: BackendSelection { didSet { save() } }
    @Published public var backendEndpoints: [BackendKind: String] { didSet { save() } }
    @Published public var llamaCppModel: String { didSet { save() } }
    @Published public var lastAutomaticBackendID: String? { didSet { save() } }

    private let defaults: UserDefaults
    private let settingsKey = "appSettings"
    private var isLoading = true

    public init(defaults: UserDefaults = .standard, legacyDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        let currentData = defaults.data(forKey: settingsKey)
        var snapshot = currentData.flatMap {
            try? JSONDecoder().decode(SettingsSnapshot.self, from: $0)
        }
        var migrated = false
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
                migrated = true
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
        isLoading = false
        if migrated { save() }
    }

    public var configurationError: String? {
        Self.validationError(
            proxyPort: proxyPort, ollamaHost: ollamaHost, ollamaPort: ollamaPort)
    }

    public var normalizedOllamaHost: String { Self.normalizedHost(ollamaHost) }

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
        let model = llamaCppModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return BackendConfiguration(
            kind: kind, baseURL: url,
            model: kind == .llamaCpp && !model.isEmpty ? model : nil,
            proxyPort: proxyPort)
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

    private func save() {
        // Optional published properties already have an initial nil value, so
        // assigning them during initialization can invoke their observers.
        guard !isLoading else { return }
        let snapshot = SettingsSnapshot(
            proxyPort: proxyPort, ollamaHost: ollamaHost,
            ollamaPort: ollamaPort, autoStartProxy: autoStartProxy,
            showMenuBarTokensPerSecond: showMenuBarTokensPerSecond,
            showMenuBarLogo: showMenuBarLogo,
            backendSelection: backendSelection,
            backendEndpoints: Dictionary(
                uniqueKeysWithValues: backendEndpoints.map { ($0.key.rawValue, $0.value) }),
            llamaCppModel: llamaCppModel, lastAutomaticBackendID: lastAutomaticBackendID)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: settingsKey)
        }
    }
}

/// Extra fields from earlier settings snapshots are intentionally ignored. This
/// keeps existing proxy preferences while removing controls with no POC behavior.
private struct SettingsSnapshot: Codable {
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
