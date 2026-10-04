import CryptoKit
import Foundation

/// Diagnostic receipt of every telemetry-driven scalar leaf. It owns values,
/// never a store, binding, clock, prepared chart, or renderer.
struct DashboardFrozenScalars: Equatable, Sendable {
    enum StatusTone: String, Sendable { case throughput, secondary, blue, orange }

    let epoch: UUID
    let interval: DateInterval
    let backendKind: BackendKind?
    let providerTitle: String
    let modelLabel: String
    let activityDetail: String?
    let statusTitle: String
    let configurationPrompt: String?
    let statusTone: StatusTone
    let rateLabel: String
    let gpuLabel: String
    let gpuHelp: String
    let throughputHelp: String
    let responseTokensLabel: String
    let usage: UsageSummary
    let usageScope: UsageScope
    let usageScopeHelp: String
    let historyPersistenceError: String?
    let requestCountLabel: String
    let backendOutputTokensLabel: String
    let backendPromptTokensLabel: String
    let observationScope: String
    let cardFooterLabel: String
    let fingerprint: String

    @MainActor
    static func capture(store: MetricsStore, interval: DateInterval, omittedRequestCount: Int = 0)
        throws -> Self
    {
        guard interval.start.timeIntervalSince1970.isFinite,
            interval.end.timeIntervalSince1970.isFinite, interval.duration > 0
        else {
            throw DashboardScalarFreezeError.invalid(
                "Scalar capture requires a finite chart interval")
        }
        let coalesced = PerformanceGraphicsDiagnostics.shared.mode.usesCoalescedScalarPresentation
        let scalar = coalesced ? store.dashboardScalarPresentation : nil
        let usage = scalar?.usage ?? store.usageSummary(in: interval)
        let response: String
        if let scalar {
            response =
                scalar.latestResponse.map {
                    ($0.outputIsEstimated ? "~" : "") + $0.outputTokens.formatted()
                } ?? "—"
        } else {
            response =
                store.activeGeneration == nil
                ? "—"
                : (store.outputIsEstimated ? "~" : "") + store.outputTokens.formatted()
        }
        let tone: StatusTone
        if store.isBackendActive {
            tone = .throughput
        } else {
            switch store.connectionState {
            case .ready: tone = .secondary
            case .connecting, .detecting: tone = .blue
            case .needsConfiguration, .unavailable: tone = .orange
            }
        }
        let throughputHelp: String
        switch store.throughputBasis {
        case .estimated:
            throughputHelp =
                store.backendKind == .ollama
                ? "Generated and tool-call rates follow the latest request via FluxLLM. Active includes all open monitored requests. Live token rate is approximate until the backend reports final token counts."
                : "Live token rate is approximate until the backend reports final token counts."
        case .serverAggregate:
            throughputHelp = "Total token throughput across requests reported by this backend."
        case .serverReportedAverage:
            throughputHelp = "Average token rate reported by this backend."
        }
        let scopeHelp: String
        switch store.usageScope {
        case .sinceLaunch:
            scopeHelp =
                "All requests observed for this endpoint since FluxLLM launched, including active estimates."
        case .selectedPeriod:
            scopeHelp =
                "Full usage of requests completed in the selected chart interval. Tool calls are counted by their event time."
        case .today:
            scopeHelp =
                "Requests completed today and active requests started today, including saved history for this endpoint."
        }
        let requestCount =
            store.runningRequests.map { running in
                let queued = store.queuedRequests ?? 0
                return queued > 0 ? "\(running) active · \(queued) queued" : running.formatted()
            } ?? "—"
        let gpuHelp =
            store.systemGPUUtilizationPercent != nil
            ? GPUActivityPresentation.explanation : store.gpuAvailabilityMessage
        let model = store.currentModel.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        let observationScope: String
        switch store.backendKind {
        case .ollama: observationScope = "Via FluxLLM"
        case .none: observationScope = "Waiting for backend"
        default: observationScope = "Server metrics"
        }
        let footer =
            omittedRequestCount > 0
            ? "\(observationScope) · \(omittedRequestCount) older rails omitted" : observationScope
        let persistenceError =
            coalesced
            ? store.dashboardScalarPresentation.historyPersistenceError
            : store.historyPersistenceError
        let provider = store.backendKind?.title ?? "LLM monitor"
        let detail = BackendPresentation.activityDetail(store: store)
        let status = BackendPresentation.statusTitle(store: store)
        let prompt = BackendPresentation.configurationPrompt(store: store)
        let rate = BackendPresentation.rateLabel(store: store)
        let gpu = GPUActivityPresentation.valueLabel(store.systemGPUUtilizationPercent)
        let output = store.backendOutputTokens?.formatted() ?? "—"
        let input = store.backendPromptTokens?.formatted() ?? "—"
        let null = NSNull()
        let fields: [String: Any] = [
            "schema": "dashboard-frozen-scalars-v1", "epoch": store.monitoringEpoch.uuidString,
            "interval": [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970],
            "backend": store.backendKind?.rawValue as Any? ?? null,
            "provider": provider, "model": model, "activity": detail as Any? ?? null,
            "status": status, "configuration": prompt as Any? ?? null, "tone": tone.rawValue,
            "rate": rate, "gpu": gpu, "gpu_help": gpuHelp, "throughput_help": throughputHelp,
            "response": response, "scope_help": scopeHelp,
            "usage_scope": store.usageScope.rawValue,
            "persistence_error": persistenceError as Any? ?? null,
            "requests": requestCount, "server_output": output, "server_input": input,
            "observation_scope": observationScope, "card_footer": footer,
            "usage": [
                "input": usage.inputTokens as Any? ?? null,
                "unknown_input": usage.unknownInputRequests,
                "output": usage.outputTokens, "estimated": usage.outputIsEstimated,
                "tools": usage.toolCalls, "requests": usage.requests,
                "active": usage.activeRequests, "partial": usage.isPartial,
            ],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return Self(
            epoch: store.monitoringEpoch, interval: interval, backendKind: store.backendKind,
            providerTitle: provider, modelLabel: model, activityDetail: detail, statusTitle: status,
            configurationPrompt: prompt, statusTone: tone, rateLabel: rate, gpuLabel: gpu,
            gpuHelp: gpuHelp, throughputHelp: throughputHelp, responseTokensLabel: response,
            usage: usage, usageScope: store.usageScope, usageScopeHelp: scopeHelp,
            historyPersistenceError: persistenceError,
            requestCountLabel: requestCount, backendOutputTokensLabel: output,
            backendPromptTokensLabel: input, observationScope: observationScope,
            cardFooterLabel: footer, fingerprint: fingerprint)
    }
}

enum DashboardScalarFreezeError: Error {
    case invalid(String)
}
