import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class DashboardRetainedUsageDiagnosticsTests: XCTestCase {
    private typealias Diagnostics = PerformanceGraphicsDiagnostics
    private typealias Mode = Diagnostics.Mode
    private let dashboard = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
    private let popover = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
    private let epoch = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!

    func testRetainedUsageChangesOnlyItsNamedFeatureAndKeepsNormalCadence() throws {
        let mode = Mode.runtimeRetainedUsage
        XCTAssertEqual(mode.rawValue, "runtime-retained-usage")
        XCTAssertEqual(try JSONDecoder().decode(Mode.self, from: JSONEncoder().encode(mode)), mode)
        XCTAssertTrue(mode.isRuntimeControl)
        XCTAssertTrue(mode.usesRetainedUsageFields)
        XCTAssertFalse(mode.usesFrozenScalarPresentation)
        XCTAssertFalse(mode.usesHeldUsagePresentation)
        let features: [(String, KeyPath<Mode, Bool>)] = [
            ("gradients", \.omitsGradients), ("bitmap destination", \.usesBitmapLayerDestination),
            ("BGRA", \.usesBGRA), ("rail decorations", \.omitsRailDecorations),
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
            XCTAssertEqual(value.usesRetainedUsageFields, value == .runtimeRetainedUsage)
            XCTAssertEqual(
                value.usesScalarPresentationInstrumentation,
                [.normal, .runtimeFrozenScalars, .runtimeHeldUsage, .runtimeRetainedUsage].contains(
                    value))
        }
    }

    func testDisabledAndOtherModesCannotCreateApplyOrDestroyRetainedHosts() throws {
        let disabled = Diagnostics()
        let before = disabled.snapshot() as NSDictionary
        recordAttempt(disabled)
        XCTAssertEqual(disabled.snapshot() as NSDictionary, before)
        for mode in Mode.allCases where mode != .runtimeRetainedUsage {
            let diagnostics = Diagnostics()
            try diagnostics.enable(mode: mode)
            let baseline = diagnostics.snapshot() as NSDictionary
            recordAttempt(diagnostics)
            XCTAssertEqual(diagnostics.snapshot() as NSDictionary, baseline, mode.rawValue)
            XCTAssertEqual(diagnostics.snapshot()["retained_usage_fields"] as? Bool, false)
            XCTAssertEqual(try retained(diagnostics)["enabled"] as? Bool, false)
        }
    }

    func testHostInventoryRejectsMalformedDuplicatePopoverAndSecondOwner() throws {
        let diagnostics = try enabled()
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: popover, role: "popover", frames: frames))
        XCTAssertFalse(diagnostics.retainedUsageHostCreated(owner: dashboard, field: ""))
        XCTAssertFalse(diagnostics.retainedUsageHostCreated(owner: dashboard, field: "other"))
        XCTAssertFalse(diagnostics.retainedUsageHostCreated(owner: popover, field: "input"))
        XCTAssertTrue(diagnostics.retainedUsageHostCreated(owner: dashboard, field: "input"))
        XCTAssertFalse(diagnostics.retainedUsageHostCreated(owner: dashboard, field: "input"))
        XCTAssertFalse(diagnostics.retainedUsageHostCreated(owner: UUID(), field: "output"))
        XCTAssertFalse(
            diagnostics.retainedUsageValueApplied(owner: dashboard, field: "output", changed: true))
        let counters = try retained(diagnostics)
        XCTAssertEqual(counter("hosts_created", counters), 1)
        XCTAssertEqual(counter("hosts_destroyed", counters), 0)
        XCTAssertEqual(counter("current_owners", counters), 1)
        XCTAssertEqual(counter("peak_owners", counters), 1)
        XCTAssertEqual(counter("value_apply_attempts", counters), 0)
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 6)
        diagnostics.frozenScalarPresentationReleased(owner: dashboard)
        diagnostics.frozenScalarPresentationReleased(owner: popover)
        XCTAssertEqual(counter("hosts_destroyed", try retained(diagnostics)), 1)
        try diagnostics.disable()
    }

    func testNativeWritesAndSkipsReconcileAndPresentationHasTheExactReceipt() throws {
        let diagnostics = try enabled()
        registerDashboard(diagnostics)
        createFields(diagnostics)
        for field in Diagnostics.retainedUsageFieldNames.sorted() {
            XCTAssertTrue(
                diagnostics.retainedUsageValueApplied(owner: dashboard, field: field, changed: true)
            )
            XCTAssertTrue(
                diagnostics.retainedUsageValueApplied(
                    owner: dashboard, field: field, changed: false))
        }
        XCTAssertTrue(
            diagnostics.retainedUsagePresentationApplied(
                owner: dashboard, epoch: epoch, scope: .today, usage: usage, fields: fields))
        let counters = try retained(diagnostics)
        XCTAssertEqual(
            Set(counters.keys),
            [
                "enabled", "hosts_created", "hosts_destroyed", "current_owners",
                "peak_owners", "value_apply_attempts", "value_applies", "value_apply_skips",
                "owners",
            ])
        XCTAssertEqual(diagnostics.snapshot()["retained_usage_fields"] as? Bool, true)
        XCTAssertEqual(counter("hosts_created", counters), 5)
        XCTAssertEqual(counter("hosts_destroyed", counters), 0)
        XCTAssertEqual(counter("value_apply_attempts", counters), 10)
        XCTAssertEqual(counter("value_applies", counters), 5)
        XCTAssertEqual(counter("value_apply_skips", counters), 5)
        XCTAssertEqual(
            counter("value_apply_attempts", counters),
            counter("value_applies", counters) + counter("value_apply_skips", counters))
        let owner = try ownerReceipt(diagnostics)
        XCTAssertEqual(Set(owner.keys), ["role", "epoch", "scope", "values", "fields"])
        XCTAssertEqual(owner["role"] as? String, "dashboard")
        XCTAssertEqual(owner["epoch"] as? String, epoch.uuidString)
        XCTAssertEqual(owner["scope"] as? String, UsageScope.today.rawValue)
        XCTAssertEqual(
            owner["values"] as? NSDictionary, DashboardHeldUsage.values(for: usage) as NSDictionary)
        XCTAssertEqual(owner["fields"] as? NSDictionary, fields as NSDictionary)
        let presented = try dashboardPresentedUsage(diagnostics)
        XCTAssertEqual(presented["scope"] as? String, UsageScope.today.rawValue)
        XCTAssertEqual(
            presented["values"] as? NSDictionary,
            DashboardHeldUsage.values(for: usage) as NSDictionary)
        XCTAssertNoThrow(
            try JSONSerialization.data(
                withJSONObject: diagnostics.snapshot(), options: [.sortedKeys]))
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 0)
    }

    func testReceiptRequiresAllFiveNativeCallbacksAndARegisteredDashboardFrameWitness() throws {
        let diagnostics = try enabled()
        XCTAssertFalse(present(diagnostics))
        createFields(diagnostics)
        XCTAssertFalse(present(diagnostics), "Creating fields is not native application evidence")
        for field in Diagnostics.retainedUsageFieldNames.sorted() {
            XCTAssertTrue(
                diagnostics.retainedUsageValueApplied(owner: dashboard, field: field, changed: true)
            )
        }
        XCTAssertFalse(
            present(diagnostics), "Native callbacks still need the matching dashboard witness")
        var incomplete = frames
        incomplete.removeValue(forKey: "statistics-row")
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: incomplete))
        XCTAssertFalse(
            present(diagnostics), "Incomplete dashboard geometry cannot attest native values")
        registerDashboard(diagnostics)
        XCTAssertTrue(present(diagnostics))
        let before = try ownerReceipt(diagnostics) as NSDictionary
        XCTAssertTrue(
            diagnostics.retainedUsageValueApplied(owner: dashboard, field: "input", changed: false))
        XCTAssertEqual(try ownerReceipt(diagnostics) as NSDictionary, before)
    }

    func testMalformedFieldsAndNegativeCountsCannotReplaceAnAdmittedReceipt() throws {
        let diagnostics = try enabled()
        registerDashboard(diagnostics)
        createFields(diagnostics)
        applyFields(diagnostics)
        XCTAssertTrue(present(diagnostics))
        let before = try ownerReceipt(diagnostics) as NSDictionary
        var missing = fields
        missing.removeValue(forKey: "badge")
        var extra = fields
        extra["other"] = ["value": "0", "help": ""]
        var missingHelp = fields
        missingHelp["input"] = ["value": "0"]
        var extraProperty = fields
        extraProperty["input"]?["other"] = "0"
        var oversized = fields
        oversized["output"]?["help"] = String(repeating: "é", count: 2049)
        for malformed in [missing, extra, missingHelp, extraProperty, oversized] {
            XCTAssertFalse(
                diagnostics.retainedUsagePresentationApplied(
                    owner: dashboard, epoch: epoch, scope: .sinceLaunch, usage: usage,
                    fields: malformed))
            XCTAssertEqual(try ownerReceipt(diagnostics) as NSDictionary, before)
        }
        let negatives = [
            UsageSummary(
                inputTokens: -1, unknownInputRequests: 0, outputTokens: 0,
                outputIsEstimated: false, toolCalls: 0, requests: 0, activeRequests: 0,
                isPartial: false),
            UsageSummary(
                inputTokens: nil, unknownInputRequests: -1, outputTokens: 0,
                outputIsEstimated: false, toolCalls: 0, requests: 0, activeRequests: 0,
                isPartial: false),
            UsageSummary(
                inputTokens: nil, unknownInputRequests: 0, outputTokens: -1,
                outputIsEstimated: false, toolCalls: 0, requests: 0, activeRequests: 0,
                isPartial: false),
            UsageSummary(
                inputTokens: nil, unknownInputRequests: 0, outputTokens: 0,
                outputIsEstimated: false, toolCalls: -1, requests: 0, activeRequests: 0,
                isPartial: false),
            UsageSummary(
                inputTokens: nil, unknownInputRequests: 0, outputTokens: 0,
                outputIsEstimated: false, toolCalls: 0, requests: -1, activeRequests: 0,
                isPartial: false),
            UsageSummary(
                inputTokens: nil, unknownInputRequests: 0, outputTokens: 0,
                outputIsEstimated: false, toolCalls: 0, requests: 0, activeRequests: -1,
                isPartial: false),
        ]
        for malformed in negatives {
            XCTAssertFalse(
                diagnostics.retainedUsagePresentationApplied(
                    owner: dashboard, epoch: epoch, scope: .sinceLaunch, usage: malformed,
                    fields: fields))
            XCTAssertEqual(try ownerReceipt(diagnostics) as NSDictionary, before)
        }
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 11)
    }

    func testChangingEpochScopeAndCompleteNativeValuesUpdatesOnlyTheSameOwner() throws {
        let diagnostics = try enabled()
        registerDashboard(diagnostics)
        createFields(diagnostics)
        applyFields(diagnostics)
        XCTAssertTrue(present(diagnostics))
        let next = UsageSummary(
            inputTokens: 46, unknownInputRequests: 0, outputTokens: 999,
            outputIsEstimated: false, toolCalls: 4, requests: 3, activeRequests: 0, isPartial: false
        )
        let nextEpoch = UUID()
        var changed = fields
        changed["input"]?["value"] = "46"
        changed["output"]?["value"] = "999"
        changed["tools"]?["value"] = "4"
        changed["requests"]?["value"] = "3"
        changed["badge"]?["value"] = ""
        applyFields(diagnostics)
        XCTAssertTrue(
            diagnostics.retainedUsagePresentationApplied(
                owner: dashboard, epoch: nextEpoch, scope: .selectedPeriod, usage: next,
                fields: changed))
        XCTAssertFalse(
            diagnostics.retainedUsagePresentationApplied(
                owner: popover, epoch: nextEpoch, scope: .selectedPeriod, usage: next,
                fields: changed))
        let owner = try ownerReceipt(diagnostics)
        XCTAssertEqual(owner["epoch"] as? String, nextEpoch.uuidString)
        XCTAssertEqual(owner["scope"] as? String, UsageScope.selectedPeriod.rawValue)
        XCTAssertEqual(
            owner["values"] as? NSDictionary, DashboardHeldUsage.values(for: next) as NSDictionary)
        XCTAssertEqual(owner["fields"] as? NSDictionary, changed as NSDictionary)
        XCTAssertEqual(counter("hosts_created", try retained(diagnostics)), 5)
        XCTAssertEqual(counter("current_owners", try retained(diagnostics)), 1)
        XCTAssertEqual(counter("peak_owners", try retained(diagnostics)), 1)
    }

    func testPartialDestructionClearsTheReceiptAndReleaseDrainsRemainingHostsExactlyOnce() throws {
        let diagnostics = try enabled()
        registerDashboard(diagnostics)
        createFields(diagnostics)
        applyFields(diagnostics)
        XCTAssertTrue(present(diagnostics))
        diagnostics.retainedUsageHostDestroyed(owner: dashboard, field: "output")
        diagnostics.retainedUsageHostDestroyed(owner: dashboard, field: "output")
        XCTAssertEqual(counter("hosts_destroyed", try retained(diagnostics)), 1)
        XCTAssertEqual(counter("current_owners", try retained(diagnostics)), 1)
        let incomplete = try ownerReceipt(diagnostics)
        XCTAssertTrue(incomplete["epoch"] is NSNull)
        XCTAssertTrue(incomplete["scope"] is NSNull)
        XCTAssertTrue(try XCTUnwrap(incomplete["values"] as? [String: Any]).isEmpty)
        XCTAssertTrue(try XCTUnwrap(incomplete["fields"] as? [String: Any]).isEmpty)
        XCTAssertFalse(present(diagnostics))
        XCTAssertTrue(diagnostics.retainedUsageHostCreated(owner: dashboard, field: "output"))
        XCTAssertFalse(
            present(diagnostics), "The replacement native field must apply before attestation")
        XCTAssertTrue(
            diagnostics.retainedUsageValueApplied(owner: dashboard, field: "output", changed: true))
        XCTAssertTrue(present(diagnostics))
        diagnostics.frozenScalarPresentationReleased(owner: dashboard)
        diagnostics.frozenScalarPresentationReleased(owner: dashboard)
        for field in Diagnostics.retainedUsageFieldNames {
            diagnostics.retainedUsageHostDestroyed(owner: dashboard, field: field)
        }
        let after = try retained(diagnostics)
        XCTAssertEqual(counter("hosts_created", after), 6)
        XCTAssertEqual(counter("hosts_destroyed", after), 6)
        XCTAssertEqual(counter("current_owners", after), 0)
        XCTAssertEqual(counter("peak_owners", after), 1)
        XCTAssertTrue(try XCTUnwrap(after["owners"] as? [String: Any]).isEmpty)
        let scalar = try XCTUnwrap(diagnostics.snapshot()["scalar_presentation"] as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(scalar["presentation_owners"] as? [String: Any]).isEmpty)
    }

    func testLiveNativeHostsPreventResetEvenBeforeAnyScalarOwnerExists() throws {
        let diagnostics = Diagnostics()
        let initial = diagnostics.snapshot() as NSDictionary
        try diagnostics.enable(mode: .runtimeRetainedUsage)
        XCTAssertTrue(diagnostics.retainedUsageHostCreated(owner: dashboard, field: "badge"))
        XCTAssertThrowsError(try diagnostics.enable(mode: .normal))
        XCTAssertThrowsError(try diagnostics.disable())
        diagnostics.retainedUsageHostDestroyed(owner: dashboard, field: "badge")
        diagnostics.retainedUsageHostDestroyed(owner: dashboard, field: "badge")
        try diagnostics.disable()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
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

    private var usage: UsageSummary {
        UsageSummary(
            inputTokens: nil, unknownInputRequests: 2, outputTokens: 17,
            outputIsEstimated: true, toolCalls: 3, requests: 2, activeRequests: 2, isPartial: true)
    }

    private var fields: [String: [String: String]] {
        [
            "input": ["value": "—", "help": "Input usage unavailable"],
            "output": ["value": "~17", "help": "Usage scope"],
            "tools": ["value": "3", "help": "Observed calls"],
            "requests": ["value": "2", "help": "Usage scope"],
            "badge": ["value": "Partial history", "help": "Usage scope"],
        ]
    }

    private func enabled() throws -> Diagnostics {
        let diagnostics = Diagnostics()
        try diagnostics.enable(mode: .runtimeRetainedUsage)
        return diagnostics
    }

    private func registerDashboard(_ diagnostics: Diagnostics) {
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: frames))
    }

    private func createFields(_ diagnostics: Diagnostics) {
        for field in Diagnostics.retainedUsageFieldNames.sorted() {
            XCTAssertTrue(diagnostics.retainedUsageHostCreated(owner: dashboard, field: field))
        }
    }

    private func applyFields(_ diagnostics: Diagnostics) {
        for field in Diagnostics.retainedUsageFieldNames.sorted() {
            XCTAssertTrue(
                diagnostics.retainedUsageValueApplied(owner: dashboard, field: field, changed: true)
            )
        }
    }

    @discardableResult
    private func present(_ diagnostics: Diagnostics) -> Bool {
        diagnostics.retainedUsagePresentationApplied(
            owner: dashboard, epoch: epoch, scope: .sinceLaunch,
            usage: usage, fields: fields)
    }

    private func recordAttempt(_ diagnostics: Diagnostics) {
        XCTAssertFalse(diagnostics.retainedUsageHostCreated(owner: dashboard, field: "input"))
        XCTAssertFalse(
            diagnostics.retainedUsageValueApplied(owner: dashboard, field: "input", changed: true))
        XCTAssertFalse(present(diagnostics))
        diagnostics.retainedUsageHostDestroyed(owner: dashboard, field: "input")
    }

    private func retained(_ diagnostics: Diagnostics) throws -> [String: Any] {
        try XCTUnwrap(diagnostics.snapshot()["retained_usage"] as? [String: Any])
    }

    private func ownerReceipt(_ diagnostics: Diagnostics) throws -> [String: Any] {
        let owners = try XCTUnwrap(try retained(diagnostics)["owners"] as? [String: [String: Any]])
        XCTAssertEqual(Set(owners.keys), [dashboard.uuidString])
        return try XCTUnwrap(owners[dashboard.uuidString])
    }

    private func dashboardPresentedUsage(_ diagnostics: Diagnostics) throws -> [String: Any] {
        let scalar = try XCTUnwrap(diagnostics.snapshot()["scalar_presentation"] as? [String: Any])
        let owners = try XCTUnwrap(scalar["presentation_owners"] as? [String: [String: Any]])
        let values = try XCTUnwrap(
            owners[dashboard.uuidString]?["presented_values"] as? [String: [String: Any]])
        return try XCTUnwrap(values["dashboard_usage"])
    }

    private func counter(_ name: String, _ counters: [String: Any]) -> UInt64 {
        let value = counters[name] as? NSNumber
        XCTAssertNotNil(value, "Missing retained-usage diagnostic counter \(name)")
        return value?.uint64Value ?? .max
    }
}
