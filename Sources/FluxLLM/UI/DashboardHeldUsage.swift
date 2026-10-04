import CryptoKit
import Foundation

/// A bounded diagnostic receipt for the full dashboard's usage block only.
/// It owns no observable store, query, renderer or clock.
struct DashboardHeldUsage: Equatable, Sendable {
    let owner: UUID
    let epoch: UUID
    let scope: UsageScope
    let usage: UsageSummary
    let frames: [String: CGRect]
    let fingerprint: String
    let capturePayloadJSON: String
    /// Native admission token; not telemetry and not part of the exported value digest.
    let presentationGeneration: UInt64

    private init(
        owner: UUID, epoch: UUID, scope: UsageScope, usage: UsageSummary,
        frames: [String: CGRect], fingerprint: String, capturePayloadJSON: String,
        presentationGeneration: UInt64
    ) {
        self.owner = owner
        self.epoch = epoch
        self.scope = scope
        self.usage = usage
        self.frames = frames
        self.fingerprint = fingerprint
        self.capturePayloadJSON = capturePayloadJSON
        self.presentationGeneration = presentationGeneration
    }

    static let requiredFrames: Set<String> = [
        "activity-chart", "main-activity-plot", "request-rail-band", "statistics-row",
        "native-window",
    ]

    var values: [String: Any] {
        Self.values(for: usage)
    }

    static func values(for usage: UsageSummary) -> [String: Any] {
        [
            "input_tokens": usage.inputTokens as Any? ?? NSNull(),
            "unknown_input_requests": usage.unknownInputRequests,
            "output_tokens": usage.outputTokens, "output_is_estimated": usage.outputIsEstimated,
            "tool_calls": usage.toolCalls, "requests": usage.requests,
            "active_requests": usage.activeRequests, "is_partial": usage.isPartial,
        ]
    }

    var frameValues: [String: [String: Double]] {
        frames.mapValues { rect in
            [
                "x": Double(rect.origin.x), "y": Double(rect.origin.y),
                "width": Double(rect.size.width), "height": Double(rect.size.height),
            ]
        }
    }

    var diagnostics: [String: Any] {
        [
            "role": "dashboard", "epoch": epoch.uuidString, "scope": scope.rawValue,
            "capture_identity": fingerprint, "capture_payload_json": capturePayloadJSON,
            "values": values, "frames": frameValues,
        ]
    }

    @MainActor
    static func capture(
        store: MetricsStore, owner: UUID, frames: [String: CGRect],
        presentationGeneration: UInt64 = 0
    ) throws -> Self {
        guard store.backendKind == .ollama,
            requiredFrames.isSubset(of: Set(frames.keys)), validFrames(frames)
        else {
            throw DashboardScalarFreezeError.invalid(
                "Usage capture requires a full Ollama dashboard and complete native geometry")
        }
        let usage = store.dashboardScalarPresentation.usage
        guard usage.inputTokens.map({ $0 >= 0 }) ?? true,
            usage.unknownInputRequests >= 0, usage.outputTokens >= 0,
            usage.toolCalls >= 0, usage.requests >= 0, usage.activeRequests >= 0
        else {
            throw DashboardScalarFreezeError.invalid(
                "Usage capture requires nonnegative authoritative display counts")
        }
        let values = Self.values(for: usage)
        let frameValues = frames.mapValues { rect in
            [
                "x": Double(rect.origin.x), "y": Double(rect.origin.y),
                "width": Double(rect.size.width), "height": Double(rect.size.height),
            ]
        }
        let envelope: [String: Any] = [
            "schema": "dashboard-held-usage-v1", "owner": owner.uuidString,
            "epoch": store.monitoringEpoch.uuidString, "scope": store.usageScope.rawValue,
            "values": values, "frames": frameValues,
        ]
        let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard bytes.count <= 8192, let json = String(data: bytes, encoding: .utf8) else {
            throw DashboardScalarFreezeError.invalid(
                "Usage capture payload exceeds its bounded receipt")
        }
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return Self(
            owner: owner, epoch: store.monitoringEpoch, scope: store.usageScope, usage: usage,
            frames: frames, fingerprint: fingerprint, capturePayloadJSON: json,
            presentationGeneration: presentationGeneration)
    }

    static func validFrames(_ frames: [String: CGRect]) -> Bool {
        !frames.isEmpty && frames.count <= 16
            && frames.allSatisfy { name, rect in
                !name.isEmpty && name.utf8.count <= 64
                    && rect.origin.x.isFinite && rect.origin.y.isFinite
                    && rect.size.width.isFinite && rect.size.height.isFinite
                    && rect.maxX.isFinite && rect.maxY.isFinite
                    && rect.size.width > 0 && rect.size.height > 0
            }
    }
}
