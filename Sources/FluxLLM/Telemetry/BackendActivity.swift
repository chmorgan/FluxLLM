import Foundation

/// Activity describes outstanding work, independently of connection health or
/// throughput. Native counts do not identify an individual request's phase.
public enum BackendActivity: Sendable, Equatable {
    case unknown
    case idle
    case requests(running: Int?, queued: Int?)
    case observedRequests(count: Int, startedAt: Date, hasOutput: Bool)

    public var isActive: Bool {
        switch self {
        case .requests, .observedRequests: true
        case .unknown, .idle: false
        }
    }

    static func native(running: Int?, queued: Int?) -> Self {
        if (running ?? 0) > 0 || (queued ?? 0) > 0 {
            return .requests(running: running, queued: queued)
        }
        // A missing count cannot rule out work in that category.
        return running == 0 && queued == 0 ? .idle : .unknown
    }
}
