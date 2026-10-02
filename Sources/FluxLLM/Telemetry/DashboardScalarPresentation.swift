import Foundation

/// Immutable values consumed by the optional coalesced dashboard presentation.
/// The telemetry ledger remains current between publications. No history arrays,
/// observable store references, or wall-clock ticks are retained in this value.
struct DashboardScalarPresentation: Equatable, Sendable {
    struct LatestResponse: Equatable, Sendable {
        let requestID: UUID
        let outputTokens: Int
        let outputIsEstimated: Bool
    }

    let latestResponse: LatestResponse?
    let usage: UsageSummary
    let usageScope: UsageScope
    /// Only selected-period accounting needs a displayed interval identity.
    let selectedInterval: DateInterval?
    let historyPersistenceError: String?

    static let empty = DashboardScalarPresentation(
        latestResponse: nil,
        usage: UsageSummary(
            inputTokens: 0, unknownInputRequests: 0, outputTokens: 0,
            outputIsEstimated: false, toolCalls: 0, requests: 0,
            activeRequests: 0, isPartial: false),
        usageScope: .sinceLaunch, selectedInterval: nil, historyPersistenceError: nil)
}
