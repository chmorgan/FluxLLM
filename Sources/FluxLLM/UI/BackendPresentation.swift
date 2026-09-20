import Foundation

/// Human-facing connection labels never expose collector or proxy diagnostics.
@MainActor
enum BackendPresentation {
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
