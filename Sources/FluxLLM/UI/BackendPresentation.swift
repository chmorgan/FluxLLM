import Foundation

/// Dashboard labels summarize health; Settings also explains the applied connection.
@MainActor
enum BackendPresentation {
    struct SettingsConnection: Identifiable, Equatable {
        enum Tone: Equatable { case ready, pending, warning }

        let kind: BackendKind
        let endpoint: URL
        let isApplied: Bool
        let status: String
        let detail: String?
        let tone: Tone

        var id: String { "\(kind.rawValue)|\(BackendEndpoint.key(endpoint))" }

        var symbol: String {
            switch tone {
            case .ready: "checkmark.circle"
            case .pending: "arrow.triangle.2.circlepath"
            case .warning: "exclamationmark.circle"
            }
        }
    }

    /// Discovery is a snapshot. Only the applied kind and endpoint receive live
    /// health, regardless of the selected draft or a different server's scan result.
    static func settingsConnections(store: MetricsStore) -> [SettingsConnection] {
        var rows: [SettingsConnection] = []
        if let kind = store.backendKind, let endpoint = store.backendEndpoint {
            let status: String
            let tone: SettingsConnection.Tone
            switch store.connectionState {
            case .detecting, .connecting:
                status = "Connecting"
                tone = .pending
            case .needsConfiguration:
                status = "Configure"
                tone = .warning
            case .unavailable:
                status = "Unavailable"
                tone = .warning
            case .ready:
                status = statusTitle(store: store)
                tone = .ready
            }
            rows.append(
                SettingsConnection(
                    kind: kind, endpoint: endpoint, isApplied: true, status: status,
                    detail: nonempty(store.connectionMessage) ?? configurationPrompt(store: store),
                    tone: tone))
        }
        var seen = Set(rows.map(\.id))
        for backend in store.detectedBackends {
            let row = SettingsConnection(
                kind: backend.kind, endpoint: backend.baseURL, isApplied: false,
                status: backend.isReady ? "Ready" : "Not ready",
                detail: nonempty(backend.detail), tone: backend.isReady ? .ready : .warning)
            if seen.insert(row.id).inserted { rows.append(row) }
        }
        return rows
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    static func statusTitle(store: MetricsStore) -> String {
        if store.isBackendActive { return "Active" }
        switch store.connectionState {
        case .detecting, .connecting: return "Connecting"
        case .needsConfiguration: return "Configure"
        case .unavailable: return "Unavailable"
        case .ready: return store.backendActivity == .idle ? "Idle" : "Unknown"
        }
    }

    static func activityDetail(store: MetricsStore) -> String? {
        switch store.backendActivity {
        case .unknown, .idle:
            return nil
        case .requests(let running, let queued):
            return [running.map { "\($0) running" }, queued.map { "\($0) queued" }]
                .compactMap { $0 }.joined(separator: " · ")
        case .observedNativeRequests(let count):
            return "\(count) observed \(count == 1 ? "request" : "requests") in progress"
        case .observedRequests(let count, let startedAt, let hasOutput):
            if count > 1 { return "\(count) requests in flight" }
            let elapsed = max(0, store.sampleDate.timeIntervalSince(startedAt))
            let seconds = elapsed.isFinite ? Int(min(elapsed, Double(Int.max / 2))) : 0
            let phase = hasOutput ? "Generating" : "Awaiting output"
            return "\(phase) · \(seconds)s"
        }
    }

    static func configurationPrompt(store: MetricsStore) -> String? {
        switch store.connectionState {
        case .needsConfiguration: "Choose an LLM system in Settings."
        case .unavailable: "Check your LLM system in Settings."
        default: nil
        }
    }

    static func rateLabel(store: MetricsStore) -> String {
        guard let rate = store.displayTPS else {
            if case .observedRequests(_, _, false) = store.backendActivity {
                return "0.0"
            }
            return "—"
        }
        return String(format: "%.1f", max(rate, 0))
    }

    static func selectionWarning(
        selection: BackendSelection, detected: [DetectedBackend]
    ) -> String? {
        guard let selected = selection.kind,
            !detected.contains(where: { $0.kind == selected && $0.isReady })
        else { return nil }
        let others = Set(detected.filter(\.isReady).map(\.kind))
            .sorted { $0.title < $1.title }.map(\.title)
        guard !others.isEmpty else { return nil }
        return "\(others.joined(separator: ", ")) detected; \(selected.title) is selected."
    }
}
