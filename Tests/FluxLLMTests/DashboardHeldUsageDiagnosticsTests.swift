import CryptoKit
import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class DashboardHeldUsageDiagnosticsTests: XCTestCase {
    private typealias Diagnostics = PerformanceGraphicsDiagnostics
    private typealias Mode = Diagnostics.Mode
    private let dashboard = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let popover = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testHeldUsageKeepsEveryNormalRenderingFeatureAndCadence() throws {
        let mode = Mode.runtimeHeldUsage
        XCTAssertEqual(mode.rawValue, "runtime-held-usage")
        XCTAssertEqual(try JSONDecoder().decode(Mode.self, from: JSONEncoder().encode(mode)), mode)
        XCTAssertTrue(mode.isRuntimeControl)
        XCTAssertTrue(mode.usesHeldUsagePresentation)
        XCTAssertFalse(mode.usesFrozenScalarPresentation)
        XCTAssertTrue(Mode.runtimeFrozenScalars.usesFrozenScalarPresentation)
        XCTAssertFalse(Mode.runtimeFrozenScalars.usesHeldUsagePresentation)
        let features: [(String, KeyPath<Mode, Bool>)] = [
            ("gradients", \.omitsGradients),
            ("bitmap destination", \.usesBitmapLayerDestination),
            ("BGRA", \.usesBGRA),
            ("rail decorations", \.omitsRailDecorations),
            ("native GPU Canvas", \.usesNativeGPUCanvas),
            ("coalesced scalar presentation", \.usesCoalescedScalarPresentation),
            ("retained twinkles", \.usesRetainedTwinkles),
            ("lifecycle effects", \.omitsLifecycleEffects),
            ("arrival effects", \.omitsArrivalEffects),
            ("Metal arrivals", \.usesMetalArrivalBursts),
            ("full Metal chart", \.usesMetalFullChart),
            ("cached Metal chart", \.cachesMetalStaticChart),
            ("Metal primitive effects", \.usesMetalPrimitiveEffects),
            ("telemetry batching", \.usesBatchedTelemetryDelivery),
            ("atomic chart scales", \.usesAtomicChartScale),
            ("completed lane cache", \.usesCompletedLaneCache),
            ("rail geometry cache", \.usesCachedRailGeometry),
            ("held static drawing", \.usesHeldStaticChart),
            ("shared preparation", \.usesSharedChartPreparation),
            ("stable decoration hosts", \.usesStableDecorationHosts),
            ("ordered publication", \.usesOrderedChartPublication),
            ("direct tool plot", \.usesDirectToolPlot),
            ("compact tool paths", \.usesCompactToolPaths),
            ("deferred tool geometry", \.usesDeferredToolGeometry),
            ("ungrouped Canvas", \.usesUngroupedNativeCanvas),
            ("stream writes", \.usesUnpromisedStreamBodyWrites),
            ("Canvas frame clock", \.usesCanvasFrameClock),
            ("incremental history order", \.usesIncrementalHistoryOrdering),
            ("optimized preparation", \.usesOptimizedChartPreparation),
        ]
        for (name, property) in features {
            XCTAssertEqual(mode[keyPath: property], Mode.normal[keyPath: property], name)
        }
        XCTAssertEqual(
            mode.chartPublicationIntervalSeconds, Mode.normal.chartPublicationIntervalSeconds)
        for value in Mode.allCases {
            XCTAssertEqual(value.usesHeldUsagePresentation, value == .runtimeHeldUsage)
            XCTAssertEqual(value.usesFrozenScalarPresentation, value == .runtimeFrozenScalars)
            XCTAssertEqual(
                value.usesScalarPresentationInstrumentation,
                [.normal, .runtimeFrozenScalars, .runtimeHeldUsage].contains(value))
        }
    }

    func testCanonicalCaptureBindsEveryUsageValueFrameScopeOwnerAndEpoch() throws {
        let store = makeStore()
        addUsage(store, tokens: 17)
        for scope in UsageScope.allCases {
            store.usageScope = scope
            store.sample(at: origin.addingTimeInterval(2))
            let receipt = try DashboardHeldUsage.capture(
                store: store, owner: dashboard, frames: frames)
            XCTAssertEqual(receipt.owner, dashboard)
            XCTAssertEqual(receipt.epoch, store.monitoringEpoch)
            XCTAssertEqual(receipt.scope, scope)
            XCTAssertEqual(receipt.usage, store.dashboardScalarPresentation.usage)
            XCTAssertEqual(receipt.frames, frames)
            let bytes = Data(receipt.capturePayloadJSON.utf8)
            XCTAssertLessThanOrEqual(bytes.count, 8192)
            XCTAssertEqual(
                receipt.fingerprint,
                SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(
                Set(payload.keys), ["schema", "owner", "epoch", "scope", "values", "frames"])
            XCTAssertEqual(payload["schema"] as? String, "dashboard-held-usage-v1")
            XCTAssertEqual(payload["owner"] as? String, dashboard.uuidString)
            XCTAssertEqual(payload["epoch"] as? String, store.monitoringEpoch.uuidString)
            XCTAssertEqual(payload["scope"] as? String, scope.rawValue)
            XCTAssertEqual(payload["values"] as? NSDictionary, receipt.values as NSDictionary)
            XCTAssertEqual(payload["frames"] as? NSDictionary, receipt.frameValues as NSDictionary)
            XCTAssertEqual(
                Set(receipt.values.keys),
                [
                    "input_tokens", "unknown_input_requests", "output_tokens",
                    "output_is_estimated", "tool_calls", "requests", "active_requests",
                    "is_partial",
                ])
            XCTAssertEqual(
                try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), bytes)
            XCTAssertEqual(
                receipt,
                try DashboardHeldUsage.capture(store: store, owner: dashboard, frames: frames))
            XCTAssertNoThrow(
                try JSONSerialization.data(
                    withJSONObject: receipt.diagnostics, options: [.sortedKeys]))
        }
    }

    func testHeldCaptureRemainsImmutableWhileAuthoritativeUsageAdvances() throws {
        let store = makeStore()
        let request = addUsage(store, tokens: 17)
        let receipt = try DashboardHeldUsage.capture(store: store, owner: dashboard, frames: frames)
        let payload = receipt.capturePayloadJSON
        XCTAssertEqual(receipt.usage.outputTokens, 17)
        XCTAssertEqual(receipt.usage.activeRequests, 1)
        XCTAssertTrue(receipt.usage.outputIsEstimated)
        XCTAssertNil(receipt.usage.inputTokens)
        XCTAssertEqual(receipt.usage.unknownInputRequests, 1)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    model: "Changed", outputTokens: 999, promptTokens: 46, isEstimated: false,
                    liveTPS: 321, timestamp: origin.addingTimeInterval(3))),
            epoch: store.monitoringEpoch)
        store.sample(at: origin.addingTimeInterval(3))
        let fresh = try DashboardHeldUsage.capture(store: store, owner: dashboard, frames: frames)
        XCTAssertEqual(store.outputTokens, 999)
        XCTAssertEqual(fresh.usage.outputTokens, 999)
        XCTAssertEqual(fresh.usage.inputTokens, 46)
        XCTAssertFalse(fresh.usage.outputIsEstimated)
        XCTAssertEqual(receipt.usage.outputTokens, 17)
        XCTAssertEqual(receipt.capturePayloadJSON, payload)
        XCTAssertNotEqual(fresh.fingerprint, receipt.fingerprint)
        var moved = frames
        moved["statistics-row"]!.origin.y += 0.125
        XCTAssertNotEqual(
            fresh.fingerprint,
            try DashboardHeldUsage.capture(store: store, owner: dashboard, frames: moved)
                .fingerprint)
        XCTAssertNotEqual(
            fresh.fingerprint,
            try DashboardHeldUsage.capture(store: store, owner: popover, frames: frames).fingerprint
        )
    }

    func testCaptureRejectsWrongBackendAndMalformedOrIncompleteGeometry() throws {
        XCTAssertThrowsError(
            try DashboardHeldUsage.capture(store: MetricsStore(), owner: dashboard, frames: frames))
        XCTAssertThrowsError(
            try DashboardHeldUsage.capture(
                store: makeStore(kind: .vllm), owner: dashboard, frames: frames))
        let store = makeStore()
        var missing = frames
        missing.removeValue(forKey: "statistics-row")
        var tooMany = frames
        for index in 0..<12 { tooMany["extra-\(index)"] = CGRect(x: 0, y: 0, width: 1, height: 1) }
        var emptyName = frames
        emptyName[""] = CGRect(x: 0, y: 0, width: 1, height: 1)
        var longName = frames
        longName[String(repeating: "x", count: 65)] = CGRect(x: 0, y: 0, width: 1, height: 1)
        var invalid = [[:], missing, tooMany, emptyName, longName]
        for rectangle in [
            CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: CGFloat.infinity, width: 1, height: 1),
            CGRect(x: 0, y: 0, width: 0, height: 1),
            CGRect(x: 0, y: 0, width: 1, height: -1),
            CGRect(
                x: CGFloat.greatestFiniteMagnitude, y: 0,
                width: CGFloat.greatestFiniteMagnitude, height: 1),
        ] {
            var current = frames
            current["statistics-row"] = rectangle
            invalid.append(current)
        }
        for current in invalid {
            XCTAssertThrowsError(
                try DashboardHeldUsage.capture(store: store, owner: dashboard, frames: current))
        }
        XCTAssertNoThrow(
            try DashboardHeldUsage.capture(store: store, owner: dashboard, frames: frames))
    }

    func testDisabledNormalAndFullFreezeCannotCaptureHeldUsage() throws {
        let receipt = try DashboardHeldUsage.capture(
            store: makeStore(), owner: dashboard, frames: frames)
        let disabled = Diagnostics()
        let original = disabled.snapshot() as NSDictionary
        XCTAssertFalse(disabled.heldUsagePresentationCaptured(receipt))
        disabled.heldUsagePresentationReleased(owner: dashboard)
        XCTAssertEqual(disabled.snapshot() as NSDictionary, original)
        for mode in Mode.allCases where mode != .runtimeHeldUsage {
            let diagnostics = Diagnostics()
            try diagnostics.enable(mode: mode)
            XCTAssertFalse(diagnostics.heldUsagePresentationCaptured(receipt))
            let held = try held(diagnostics)
            XCTAssertEqual(held["enabled"] as? Bool, false)
            XCTAssertEqual(counter("captures", held), 0)
            XCTAssertEqual(counter("current_owners", held), 0)
            XCTAssertTrue(try XCTUnwrap(held["owners"] as? [String: Any]).isEmpty)
        }
    }

    func testCaptureRequiresBothRegisteredRolesAndExactCurrentGeometry() throws {
        let store = makeStore()
        let receipt = try DashboardHeldUsage.capture(store: store, owner: dashboard, frames: frames)
        let diagnostics = Diagnostics()
        try diagnostics.enable(mode: .runtimeHeldUsage)
        XCTAssertFalse(
            diagnostics.heldUsagePresentationCaptured(receipt), "Unregistered owners cannot capture"
        )
        diagnostics.recordScalarLeafBody(.details, owner: dashboard)
        XCTAssertFalse(
            diagnostics.heldUsagePresentationCaptured(receipt),
            "An owner without a native role cannot capture")
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: frames))
        XCTAssertFalse(
            diagnostics.heldUsagePresentationCaptured(receipt),
            "The live popover must also be registered")
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: popover, role: "popover", frames: frames))
        let compact = try DashboardHeldUsage.capture(store: store, owner: popover, frames: frames)
        XCTAssertFalse(
            diagnostics.heldUsagePresentationCaptured(compact), "Only dashboard usage may be held")
        var changed = frames
        changed["statistics-row"]!.size.height += 1
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: changed))
        XCTAssertFalse(
            diagnostics.heldUsagePresentationCaptured(receipt),
            "Stale captured geometry cannot install")
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: frames))
        XCTAssertTrue(diagnostics.heldUsagePresentationCaptured(receipt))
        XCTAssertEqual(counter("captures", try held(diagnostics)), 1)
    }

    func testOneDashboardReceiptIsBoundedImmutableAndReleasedIdempotently() throws {
        let store = makeStore()
        let receipt = try DashboardHeldUsage.capture(store: store, owner: dashboard, frames: frames)
        let diagnostics = Diagnostics()
        try diagnostics.enable(mode: .runtimeHeldUsage)
        registerBoth(diagnostics)
        XCTAssertTrue(diagnostics.heldUsagePresentationCaptured(receipt))
        let before = try held(diagnostics)
        let owners = try XCTUnwrap(before["owners"] as? [String: [String: Any]])
        XCTAssertEqual(Set(owners.keys), [dashboard.uuidString])
        XCTAssertEqual(
            owners[dashboard.uuidString] as NSDictionary?, receipt.diagnostics as NSDictionary)
        XCTAssertEqual(counter("captures", before), 1)
        XCTAssertEqual(counter("releases", before), 0)
        XCTAssertEqual(counter("current_owners", before), 1)
        XCTAssertEqual(counter("peak_owners", before), 1)
        XCTAssertFalse(
            diagnostics.heldUsagePresentationCaptured(receipt), "Duplicate capture is forbidden")
        XCTAssertFalse(
            diagnostics.heldUsagePresentationCaptured(
                try DashboardHeldUsage.capture(store: store, owner: popover, frames: frames)),
            "A second owner is forbidden")
        var changed = frames
        changed["statistics-row"]!.origin.x += 1
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: changed))
        XCTAssertEqual(
            try held(diagnostics)["owners"] as? NSDictionary, before["owners"] as? NSDictionary,
            "Current geometry updates cannot rewrite the captured receipt")
        diagnostics.heldUsagePresentationReleased(owner: popover)
        XCTAssertEqual(counter("current_owners", try held(diagnostics)), 1)
        diagnostics.heldUsagePresentationReleased(owner: dashboard)
        diagnostics.heldUsagePresentationReleased(owner: dashboard)
        let after = try held(diagnostics)
        XCTAssertEqual(counter("captures", after), 1)
        XCTAssertEqual(counter("releases", after), 1)
        XCTAssertEqual(counter("current_owners", after), 0)
        XCTAssertEqual(counter("peak_owners", after), 1)
        XCTAssertTrue(try XCTUnwrap(after["owners"] as? [String: Any]).isEmpty)
        XCTAssertNoThrow(
            try JSONSerialization.data(
                withJSONObject: diagnostics.snapshot(), options: [.sortedKeys]))
    }

    func testModeResetRequiresHeldAndLivePresentationCleanup() throws {
        let diagnostics = Diagnostics()
        let original = diagnostics.snapshot() as NSDictionary
        try diagnostics.enable(mode: .runtimeHeldUsage)
        registerBoth(diagnostics)
        XCTAssertTrue(
            diagnostics.heldUsagePresentationCaptured(
                try DashboardHeldUsage.capture(store: makeStore(), owner: dashboard, frames: frames)
            ))
        XCTAssertThrowsError(try diagnostics.enable(mode: .normal))
        XCTAssertThrowsError(try diagnostics.disable())
        diagnostics.heldUsagePresentationReleased(owner: dashboard)
        XCTAssertThrowsError(
            try diagnostics.disable(), "Live scalar instrumentation still owns both presentations")
        diagnostics.frozenScalarPresentationReleased(owner: dashboard)
        diagnostics.frozenScalarPresentationReleased(owner: popover)
        XCTAssertEqual(counter("releases", try held(diagnostics)), 1)
        try diagnostics.disable()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, original)
    }

    private var frames: [String: CGRect] {
        [
            "activity-chart": CGRect(x: 18, y: 120, width: 700, height: 280),
            "main-activity-plot": CGRect(x: 40, y: 130, width: 650, height: 180),
            "request-rail-band": CGRect(x: 40, y: 330, width: 650, height: 50),
            "statistics-row": CGRect(x: 18, y: 440, width: 700, height: 84),
            "native-window": CGRect(x: -40.5, y: 21.25, width: 740, height: 700),
        ]
    }

    private func makeStore(kind: BackendKind = .ollama) -> MetricsStore {
        let now = origin
        let store = MetricsStore(clock: { now })
        store.beginBackendSession(kind: kind, epoch: UUID())
        store.applyBackendSample(
            BackendSample(kind: kind, timestamp: origin, model: "Initial"),
            epoch: store.monitoringEpoch)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        store.setChartPresentationDemand(true, consumer: .popover)
        store.sample(at: origin)
        return store
    }

    @discardableResult
    private func addUsage(_ store: MetricsStore, tokens: Int) -> GenerationRequest {
        let request = GenerationRequest(model: "Initial", startedAt: origin.addingTimeInterval(0.1))
        store.apply(.began(request), epoch: store.monitoringEpoch)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    model: "Initial", outputTokens: tokens, liveTPS: 12,
                    timestamp: origin.addingTimeInterval(1))), epoch: store.monitoringEpoch)
        store.sample(at: origin.addingTimeInterval(1))
        return request
    }

    private func registerBoth(_ diagnostics: Diagnostics) {
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: frames))
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: popover, role: "popover", frames: frames))
    }

    private func held(_ diagnostics: Diagnostics) throws -> [String: Any] {
        try XCTUnwrap(diagnostics.snapshot()["held_usage"] as? [String: Any])
    }

    private func counter(_ name: String, _ held: [String: Any]) -> UInt64 {
        let value = held[name] as? NSNumber
        XCTAssertNotNil(value, "Missing held-usage diagnostic counter \(name)")
        return value?.uint64Value ?? .max
    }
}
