import Foundation
import Observation

/// The observable leaves contain the values actually displayed. Raw samples,
/// clock timestamps and unrelated usage fields never become leaf dependencies.
/// Each source updates only its own projection, on its existing delivery cadence.
@Observable
@MainActor
final class DashboardLiveScalars {
    enum StatusTone: String, Sendable { case throughput, secondary, blue, orange }

    private(set) var backendKind: BackendKind?
    private(set) var providerTitle = "LLM monitor"
    private(set) var modelLabel = "—"
    private(set) var activityDetail: String?
    private(set) var statusTitle = "Connecting"
    private(set) var configurationPrompt: String?
    private(set) var statusTone = StatusTone.blue
    private(set) var rateLabel = "—"
    private(set) var gpuLabel = GPUActivityPresentation.valueLabel(nil)
    private(set) var gpuHelp = "Waiting for macOS GPU utilization…"
    private(set) var throughputHelp =
        "Live token rate is approximate until the backend reports final token counts."
    private(set) var responseTokensLabel = "—"
    private(set) var usage = DashboardScalarPresentation.empty.usage
    private(set) var usageScopeHelp =
        "All requests observed for this endpoint since FluxLLM launched, including active estimates."
    private(set) var historyPersistenceError: String?
    private(set) var requestCountLabel = "—"
    private(set) var backendOutputTokensLabel = "—"
    private(set) var backendPromptTokensLabel = "—"
    private(set) var observationScope = "Waiting for backend"

    private struct ActivityKey: Equatable {
        let activity: BackendActivity
        let displayedSecond: Int?
    }
    private struct RateKey: Equatable {
        let value: Double?
        let awaitingOutput: Bool
    }
    @ObservationIgnored private var activityKey = ActivityKey(
        activity: .unknown, displayedSecond: nil)
    @ObservationIgnored private var rateKey = RateKey(value: nil, awaitingOutput: false)
    @ObservationIgnored private var gpuValue: Double?
    @ObservationIgnored private var response: DashboardScalarPresentation.LatestResponse?

    func updateBackend(_ kind: BackendKind?) {
        if backendKind != kind { backendKind = kind }
        let provider = kind?.title ?? "LLM monitor"
        if providerTitle != provider { providerTitle = provider }
        let scope: String
        switch kind {
        case .ollama: scope = "Via FluxLLM"
        case .none: scope = "Waiting for backend"
        default: scope = "Server metrics"
        }
        if observationScope != scope { observationScope = scope }
    }

    func updateModel(_ model: String?) {
        let next = model.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        if modelLabel != next { modelLabel = next }
    }

    func updateActivity(_ activity: BackendActivity, at date: Date) {
        let second: Int?
        if case .observedRequests(let count, let start, _) = activity, count <= 1 {
            let elapsed = max(0, date.timeIntervalSince(start))
            second = elapsed.isFinite ? Int(min(elapsed, Double(Int.max / 2))) : 0
        } else {
            second = nil
        }
        let key = ActivityKey(activity: activity, displayedSecond: second)
        guard key != activityKey else { return }
        activityKey = key
        let next: String?
        switch activity {
        case .unknown, .idle: next = nil
        case .requests(let running, let queued):
            next = [running.map { "\($0) running" }, queued.map { "\($0) queued" }]
                .compactMap { $0 }.joined(separator: " · ")
        case .observedNativeRequests(let count):
            next = "\(count) observed \(count == 1 ? "request" : "requests") in progress"
        case .observedRequests(let count, _, let hasOutput):
            next =
                count > 1
                ? "\(count) requests in flight"
                : "\(hasOutput ? "Generating" : "Awaiting output") · \(second ?? 0)s"
        }
        if activityDetail != next { activityDetail = next }
    }

    func updateStatus(activity: BackendActivity, connection: BackendConnectionState) {
        let title: String
        let tone: StatusTone
        if activity.isActive {
            title = "Active"
            tone = .throughput
        } else {
            switch connection {
            case .detecting, .connecting:
                title = "Connecting"
                tone = .blue
            case .needsConfiguration:
                title = "Configure"
                tone = .orange
            case .unavailable:
                title = "Unavailable"
                tone = .orange
            case .ready:
                title = activity == .idle ? "Idle" : "Unknown"
                tone = .secondary
            }
        }
        let prompt: String?
        switch connection {
        case .needsConfiguration: prompt = "Choose an LLM system in Settings."
        case .unavailable: prompt = "Check your LLM system in Settings."
        default: prompt = nil
        }
        if statusTitle != title { statusTitle = title }
        if statusTone != tone { statusTone = tone }
        if configurationPrompt != prompt { configurationPrompt = prompt }
    }

    func updateRate(_ value: Double?, activity: BackendActivity) {
        let waiting: Bool
        if case .observedRequests(_, _, false) = activity {
            waiting = true
        } else {
            waiting = false
        }
        let key = RateKey(value: value, awaitingOutput: waiting)
        guard key != rateKey else { return }
        rateKey = key
        let next = value.map { String(format: "%.1f", max($0, 0)) } ?? (waiting ? "0.0" : "—")
        if rateLabel != next { rateLabel = next }
    }

    func updateGPUValue(_ value: Double?) {
        guard value != gpuValue else { return }
        gpuValue = value
        let next = GPUActivityPresentation.valueLabel(value)
        if gpuLabel != next { gpuLabel = next }
    }

    func updateGPUHelp(available: Bool, unavailableMessage: String) {
        let next = available ? GPUActivityPresentation.explanation : unavailableMessage
        if gpuHelp != next { gpuHelp = next }
    }

    func updateThroughputHelp(basis: ThroughputBasis, backend: BackendKind?) {
        let next: String
        switch basis {
        case .estimated:
            next =
                backend == .ollama
                ? "Generated and tool-call rates follow the latest request via FluxLLM. Active includes all open monitored requests. Live token rate is approximate until the backend reports final token counts."
                : "Live token rate is approximate until the backend reports final token counts."
        case .serverAggregate:
            next = "Total token throughput across requests reported by this backend."
        case .serverReportedAverage: next = "Average token rate reported by this backend."
        }
        if throughputHelp != next { throughputHelp = next }
    }

    func updateRequestCounts(running: Int?, queued: Int?) {
        let next =
            running.map { running in
                let queued = queued ?? 0
                return queued > 0 ? "\(running) active · \(queued) queued" : running.formatted()
            } ?? "—"
        if requestCountLabel != next { requestCountLabel = next }
    }

    func updateBackendOutput(_ value: Int?) {
        let next = value?.formatted() ?? "—"
        if backendOutputTokensLabel != next { backendOutputTokensLabel = next }
    }

    func updateBackendPrompt(_ value: Int?) {
        let next = value?.formatted() ?? "—"
        if backendPromptTokensLabel != next { backendPromptTokensLabel = next }
    }

    func updateUsageScope(_ scope: UsageScope) {
        let next: String
        switch scope {
        case .sinceLaunch:
            next =
                "All requests observed for this endpoint since FluxLLM launched, including active estimates."
        case .selectedPeriod:
            next =
                "Full usage of requests completed in the selected chart interval. Tool calls are counted by their event time."
        case .today:
            next =
                "Requests completed today and active requests started today, including saved history for this endpoint."
        }
        if usageScopeHelp != next { usageScopeHelp = next }
    }

    /// Receives the already prepared, existing coalesced value. This creates no
    /// usage query, ordering cache or stream-record formatting work.
    func updateCoalesced(_ value: DashboardScalarPresentation) {
        if response != value.latestResponse {
            response = value.latestResponse
            let next =
                value.latestResponse.map {
                    ($0.outputIsEstimated ? "~" : "") + $0.outputTokens.formatted()
                } ?? "—"
            if responseTokensLabel != next { responseTokensLabel = next }
        }
        if usage != value.usage { usage = value.usage }
        if historyPersistenceError != value.historyPersistenceError {
            historyPersistenceError = value.historyPersistenceError
        }
    }
}
