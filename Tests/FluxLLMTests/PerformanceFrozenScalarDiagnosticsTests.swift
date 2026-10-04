import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class PerformanceFrozenScalarDiagnosticsTests: XCTestCase {
    private typealias Diagnostics = PerformanceGraphicsDiagnostics
    private let dashboard = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let popover = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let fingerprint = String(repeating: "a", count: 64)
    private var frames: [String: CGRect] {
        [
            "native-window": CGRect(x: -40.5, y: 21.25, width: 720, height: 620),
            "activity-chart": CGRect(x: 14, y: 50, width: 690, height: 200),
            "main-activity-plot": CGRect(x: 14, y: 50, width: 690, height: 170),
        ]
    }

    func testFrozenModePreservesNormalRenderingAndChangesOnlyScalarPresentation() throws {
        typealias Mode = Diagnostics.Mode
        XCTAssertEqual(Mode.runtimeFrozenScalars.rawValue, "runtime-frozen-scalars")
        XCTAssertEqual(Mode.allCases.count, 46)
        XCTAssertEqual(
            try JSONDecoder().decode(
                Mode.self, from: JSONEncoder().encode(Mode.runtimeFrozenScalars)),
            .runtimeFrozenScalars)
        let mode = Mode.runtimeFrozenScalars
        XCTAssertTrue(mode.isRuntimeControl)
        XCTAssertTrue(mode.usesNativeGPUCanvas)
        XCTAssertTrue(mode.usesCoalescedScalarPresentation)
        XCTAssertTrue(mode.usesRetainedTwinkles)
        XCTAssertTrue(mode.usesIncrementalHistoryOrdering)
        XCTAssertTrue(mode.usesOptimizedChartPreparation)
        XCTAssertTrue(mode.usesOrderedChartPublication)
        XCTAssertTrue(mode.usesUnpromisedStreamBodyWrites)
        XCTAssertTrue(mode.usesCanvasFrameClock)
        XCTAssertEqual(mode.chartPublicationIntervalSeconds, 1)
        XCTAssertFalse(mode.omitsLifecycleEffects)
        XCTAssertFalse(mode.omitsArrivalEffects)
        XCTAssertFalse(mode.usesHeldStaticChart)
        XCTAssertFalse(mode.usesMetalArrivalBursts)
        XCTAssertFalse(mode.usesMetalFullChart)
        XCTAssertFalse(mode.usesMetalPrimitiveEffects)
        XCTAssertFalse(mode.usesBatchedTelemetryDelivery)
        XCTAssertFalse(mode.usesAtomicChartScale)
        XCTAssertFalse(mode.usesCompletedLaneCache)
        XCTAssertFalse(mode.usesCachedRailGeometry)
        for value in Mode.allCases {
            XCTAssertEqual(value.usesFrozenScalarPresentation, value == .runtimeFrozenScalars)
        }
    }

    func testDisabledAndUnrelatedModesCannotRecordScalarWorkOrFrames() throws {
        let disabled = Diagnostics()
        let initial = disabled.snapshot() as NSDictionary
        recordWork(disabled)
        XCTAssertEqual(disabled.snapshot() as NSDictionary, initial)
        for mode in Diagnostics.Mode.allCases {
            let diagnostics = Diagnostics()
            try diagnostics.enable(mode: mode)
            recordWork(diagnostics)
            let enabled = [.normal, .runtimeFrozenScalars, .runtimeHeldUsage].contains(mode)
            XCTAssertEqual(diagnostics.layoutCountersForPresentation != nil, enabled)
            let snapshot = diagnostics.snapshot()
            XCTAssertEqual(snapshot["scalar_instrumentation_enabled"] as? Bool, enabled)
            XCTAssertEqual(
                snapshot["frozen_scalar_presentation_enabled"] as? Bool,
                mode == .runtimeFrozenScalars)
            let scalar = try scalar(snapshot)
            XCTAssertEqual(scalar["layout_size_calls"] as? UInt64, enabled ? 1 : 0)
            XCTAssertEqual(scalar["layout_place_calls"] as? UInt64, enabled ? 1 : 0)
            XCTAssertEqual(scalar["layout_child_measurements"] as? UInt64, enabled ? 3 : 0)
            let leaves = try XCTUnwrap(scalar["leaf_body_updates"] as? [String: UInt64])
            XCTAssertEqual(
                Set(leaves.keys), ["header", "metrics", "details", "card_footer", "app_footer"])
            XCTAssertEqual(leaves["header"], enabled ? 1 : 0)
            XCTAssertEqual(
                scalar["freezes_captured"] as? UInt64, mode == .runtimeFrozenScalars ? 1 : 0)
            diagnostics.frozenScalarPresentationReleased(owner: dashboard)
            try diagnostics.disable()
            XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
        }
    }

    func testTwoOwnerBodiesAndImmutableFreezeReceiptsRemainDisjoint() throws {
        let diagnostics = Diagnostics()
        try diagnostics.enable(mode: .runtimeFrozenScalars)
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: frames))
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: popover, role: "popover", frames: frames))
        diagnostics.recordScalarLeafBody(.header, owner: dashboard)
        diagnostics.recordScalarLeafBody(.metrics, owner: dashboard)
        diagnostics.recordScalarLeafBody(.metrics, owner: popover)
        XCTAssertTrue(
            diagnostics.frozenScalarPresentationCaptured(
                owner: dashboard, role: "dashboard", fingerprint: fingerprint, frames: frames))
        XCTAssertTrue(
            diagnostics.frozenScalarPresentationCaptured(
                owner: popover, role: "popover", fingerprint: String(repeating: "b", count: 64),
                frames: frames))
        let before = try scalar(diagnostics.snapshot())
        let frozenBefore = try XCTUnwrap(before["frozen_owners"] as? [String: [String: Any]])
        XCTAssertEqual(Set(frozenBefore.keys), [dashboard.uuidString, popover.uuidString])
        XCTAssertEqual(
            frozenBefore[dashboard.uuidString]?["capture_identity"] as? String, fingerprint)
        var changed = frames
        changed["activity-chart"]!.size.width += 0.125
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: changed))
        diagnostics.recordScalarLeafBody(.details, owner: popover)
        let after = try scalar(diagnostics.snapshot())
        XCTAssertEqual(
            after["frozen_owners"] as? NSDictionary, before["frozen_owners"] as? NSDictionary,
            "Live geometry callbacks cannot rewrite the captured before-load receipt")
        let live = try XCTUnwrap(after["presentation_owners"] as? [String: [String: Any]])
        XCTAssertNotEqual(
            live[dashboard.uuidString]?["current_frames"] as? NSDictionary,
            frozenBefore[dashboard.uuidString]?["frames"] as? NSDictionary)
        let dashboardLeaves = try XCTUnwrap(
            live[dashboard.uuidString]?["leaf_body_updates"] as? [String: UInt64])
        let popoverLeaves = try XCTUnwrap(
            live[popover.uuidString]?["leaf_body_updates"] as? [String: UInt64])
        XCTAssertEqual(dashboardLeaves["header"], 1)
        XCTAssertEqual(dashboardLeaves["details"], 0)
        XCTAssertEqual(popoverLeaves["header"], 0)
        XCTAssertEqual(popoverLeaves["details"], 1)
        XCTAssertEqual(after["current_frozen_owners"] as? UInt64, 2)
        XCTAssertEqual(after["peak_frozen_owners"] as? UInt64, 2)
        XCTAssertNoThrow(
            try JSONSerialization.data(
                withJSONObject: diagnostics.snapshot(), options: [.sortedKeys]))
    }

    func testClosingOneOwnerCannotHideAnotherAndCleanupIsIdempotent() throws {
        let diagnostics = Diagnostics()
        try diagnostics.enable(mode: .runtimeFrozenScalars)
        for (owner, role) in [(dashboard, "dashboard"), (popover, "popover")] {
            XCTAssertTrue(
                diagnostics.performanceScalarFramesUpdated(owner: owner, role: role, frames: frames)
            )
            XCTAssertTrue(
                diagnostics.frozenScalarPresentationCaptured(
                    owner: owner, role: role, fingerprint: fingerprint, frames: frames))
            diagnostics.recordScalarLeafBody(.header, owner: owner)
        }
        diagnostics.frozenScalarPresentationReleased(owner: dashboard)
        var counts = try scalar(diagnostics.snapshot())
        XCTAssertEqual(counts["current_frozen_owners"] as? UInt64, 1)
        XCTAssertEqual(counts["freezes_released"] as? UInt64, 1)
        XCTAssertEqual(
            Set(try XCTUnwrap(counts["frozen_owners"] as? [String: [String: Any]]).keys),
            [popover.uuidString])
        XCTAssertEqual(
            Set(try XCTUnwrap(counts["presentation_owners"] as? [String: [String: Any]]).keys),
            [popover.uuidString])
        diagnostics.frozenScalarPresentationReleased(owner: dashboard)
        diagnostics.frozenScalarPresentationReleased(owner: popover)
        counts = try scalar(diagnostics.snapshot())
        XCTAssertEqual(counts["current_frozen_owners"] as? UInt64, 0)
        XCTAssertEqual(counts["peak_frozen_owners"] as? UInt64, 2)
        XCTAssertEqual(counts["freezes_captured"] as? UInt64, 2)
        XCTAssertEqual(counts["freezes_released"] as? UInt64, 2)
        XCTAssertTrue(try XCTUnwrap(counts["frozen_owners"] as? [String: [String: Any]]).isEmpty)
        XCTAssertTrue(
            try XCTUnwrap(counts["presentation_owners"] as? [String: [String: Any]]).isEmpty)
        XCTAssertEqual((counts["leaf_body_updates"] as? [String: UInt64])?["header"], 2)
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 0)
    }

    func testOwnersAreBoundedAndRolesCannotBeDuplicatedOrChanged() throws {
        let diagnostics = Diagnostics()
        try diagnostics.enable(mode: .normal)
        diagnostics.recordScalarLeafBody(.header, owner: dashboard)
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: frames))
        diagnostics.recordScalarLeafBody(.header, owner: popover)
        XCTAssertFalse(
            diagnostics.performanceScalarFramesUpdated(
                owner: popover, role: "dashboard", frames: frames))
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: popover, role: "popover", frames: frames))
        XCTAssertFalse(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "popover", frames: frames))
        let third = UUID()
        diagnostics.recordScalarLeafBody(.header, owner: third)
        XCTAssertFalse(
            diagnostics.performanceScalarFramesUpdated(
                owner: third, role: "dashboard", frames: frames))
        let counts = try scalar(diagnostics.snapshot())
        XCTAssertEqual((counts["presentation_owners"] as? [String: [String: Any]])?.count, 2)
        XCTAssertEqual((counts["leaf_body_updates"] as? [String: UInt64])?["header"], 2)
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 4)
        XCTAssertEqual(counts["freezes_captured"] as? UInt64, 0)
    }

    func testMalformedFrameReceiptsCannotReplaceValidGeometry() throws {
        let diagnostics = Diagnostics()
        try diagnostics.enable(mode: .runtimeFrozenScalars)
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: frames))
        let previous = try scalar(diagnostics.snapshot())["presentation_owners"] as? NSDictionary
        let invalid: [[String: CGRect]] = [
            [:], ["": CGRect(x: 0, y: 0, width: 1, height: 1)],
            [String(repeating: "x", count: 65): CGRect(x: 0, y: 0, width: 1, height: 1)],
            Dictionary(
                uniqueKeysWithValues: (0..<17).map {
                    ("anchor-\($0)", CGRect(x: 0, y: 0, width: 1, height: 1))
                }),
            ["plot": CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)],
            ["plot": CGRect(x: 0, y: CGFloat.infinity, width: 1, height: 1)],
            ["plot": CGRect(x: 0, y: 0, width: 0, height: 1)],
            ["plot": CGRect(x: 0, y: 0, width: 1, height: -1)],
            [
                "plot": CGRect(
                    x: CGFloat.greatestFiniteMagnitude, y: 0,
                    width: CGFloat.greatestFiniteMagnitude, height: 1)
            ],
        ]
        for receipt in invalid {
            XCTAssertFalse(
                diagnostics.performanceScalarFramesUpdated(
                    owner: dashboard, role: "dashboard", frames: receipt))
            XCTAssertEqual(
                try scalar(diagnostics.snapshot())["presentation_owners"] as? NSDictionary, previous
            )
        }
        XCTAssertFalse(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "other", frames: frames))
        XCTAssertEqual(
            diagnostics.snapshot()["invalid_events"] as? UInt64, UInt64(invalid.count + 1))
    }

    func testCaptureRequiresACompleteCurrentReceiptAndRejectsIdentityReplacement() throws {
        let diagnostics = Diagnostics()
        try diagnostics.enable(mode: .runtimeFrozenScalars)
        XCTAssertFalse(
            diagnostics.frozenScalarPresentationCaptured(
                owner: dashboard, role: "dashboard", fingerprint: fingerprint, frames: frames))
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: frames))
        for invalid in [
            "", String(repeating: "a", count: 63), String(repeating: "g", count: 64),
            String(repeating: "A", count: 64),
        ] {
            XCTAssertFalse(
                diagnostics.frozenScalarPresentationCaptured(
                    owner: dashboard, role: "dashboard", fingerprint: invalid, frames: frames))
        }
        var other = frames
        other["activity-chart"]!.origin.x += 1
        XCTAssertFalse(
            diagnostics.frozenScalarPresentationCaptured(
                owner: dashboard, role: "dashboard", fingerprint: fingerprint, frames: other))
        XCTAssertTrue(
            diagnostics.frozenScalarPresentationCaptured(
                owner: dashboard, role: "dashboard", fingerprint: fingerprint, frames: frames))
        let previous = try scalar(diagnostics.snapshot())["frozen_owners"] as? NSDictionary
        XCTAssertFalse(
            diagnostics.frozenScalarPresentationCaptured(
                owner: dashboard, role: "dashboard", fingerprint: String(repeating: "b", count: 64),
                frames: frames))
        XCTAssertEqual(
            try scalar(diagnostics.snapshot())["frozen_owners"] as? NSDictionary, previous)
        XCTAssertEqual(try scalar(diagnostics.snapshot())["freezes_captured"] as? UInt64, 1)
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 7)
    }

    func testActiveScalarOwnersPreventModeResetUntilReleased() throws {
        let diagnostics = Diagnostics()
        let initial = diagnostics.snapshot() as NSDictionary
        try diagnostics.enable(mode: .normal)
        diagnostics.recordScalarLeafBody(.header, owner: dashboard)
        XCTAssertThrowsError(try diagnostics.enable(mode: .runtimeFrozenScalars))
        XCTAssertThrowsError(try diagnostics.disable())
        XCTAssertEqual(diagnostics.mode, .normal)
        diagnostics.frozenScalarPresentationReleased(owner: dashboard)
        try diagnostics.enable(mode: .runtimeFrozenScalars)
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: frames))
        XCTAssertTrue(
            diagnostics.frozenScalarPresentationCaptured(
                owner: dashboard, role: "dashboard", fingerprint: fingerprint, frames: frames))
        diagnostics.frozenScalarPresentationReleased(owner: dashboard)
        try diagnostics.disable()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
    }

    func testLayoutRejectsNegativeCountsAndOverflowWithoutCounterWrap() throws {
        let diagnostics = Diagnostics()
        try diagnostics.enable(mode: .normal)
        diagnostics.recordDashboardLayoutChildMeasurements(-1)
        diagnostics.recordDashboardLayoutChildMeasurements(Int.max)
        diagnostics.recordDashboardLayoutChildMeasurements(Int.max)
        diagnostics.recordDashboardLayoutChildMeasurements(1)
        XCTAssertEqual(
            try scalar(diagnostics.snapshot())["layout_child_measurements"] as? UInt64, UInt64.max)
        diagnostics.recordDashboardLayoutChildMeasurements(1)
        XCTAssertEqual(
            try scalar(diagnostics.snapshot())["layout_child_measurements"] as? UInt64, UInt64.max)
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 2)
    }

    func testLayoutCountersRecordConcurrentCallbacksAndRetireRetainedReferences() throws {
        let diagnostics = Diagnostics()
        XCTAssertNil(diagnostics.layoutCountersForPresentation)
        try diagnostics.enable(mode: .normal)
        let retained = try XCTUnwrap(diagnostics.layoutCountersForPresentation)
        let iterations = 10_000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            retained.recordSize()
            retained.recordPlace()
            retained.recordChildMeasurements(3)
            _ = retained.snapshot()
        }
        let concurrent = retained.snapshot()
        XCTAssertEqual(concurrent.sizeCalls, UInt64(iterations))
        XCTAssertEqual(concurrent.placeCalls, UInt64(iterations))
        XCTAssertEqual(concurrent.childMeasurements, UInt64(iterations * 3))
        XCTAssertEqual(concurrent.invalidEvents, 0)
        let scalarCounts = try scalar(diagnostics.snapshot())
        XCTAssertEqual(scalarCounts["layout_size_calls"] as? UInt64, concurrent.sizeCalls)
        XCTAssertEqual(scalarCounts["layout_place_calls"] as? UInt64, concurrent.placeCalls)
        XCTAssertEqual(
            scalarCounts["layout_child_measurements"] as? UInt64, concurrent.childMeasurements)

        try diagnostics.disable()
        XCTAssertNil(diagnostics.layoutCountersForPresentation)
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            retained.recordSize()
            retained.recordPlace()
            retained.recordChildMeasurements(-1)
        }
        let retired = retained.snapshot()
        XCTAssertEqual(retired.sizeCalls, 0)
        XCTAssertEqual(retired.placeCalls, 0)
        XCTAssertEqual(retired.childMeasurements, 0)
        XCTAssertEqual(
            retired.invalidEvents, 0,
            "A disabled retained callback cannot record even an invalid event")

        try diagnostics.enable(mode: .runtimeFrozenScalars)
        let current = try XCTUnwrap(diagnostics.layoutCountersForPresentation)
        XCTAssertFalse(
            retained === current, "A new session cannot reactivate an old layout's retained probe")
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            retained.recordSize()
            current.recordPlace()
        }
        let resetCounts = try scalar(diagnostics.snapshot())
        XCTAssertEqual(resetCounts["layout_size_calls"] as? UInt64, 0)
        XCTAssertEqual(resetCounts["layout_place_calls"] as? UInt64, UInt64(iterations))
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 0)
        try diagnostics.disable()
    }

    func testCurrentStaticCanvasFramesUseActualGeometryAndReleaseIdentity() throws {
        let diagnostics = Diagnostics()
        try diagnostics.enable(mode: .runtimeFrozenScalars)
        let first = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
        let second = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
        let cursor = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
        diagnostics.canvasGeometry(first, width: 690.25, height: 200.5, scale: 2)
        diagnostics.canvasGeometry(second, width: 330, height: 154, scale: 1)
        diagnostics.canvasGeometry(cursor, width: 690, height: 200, scale: 2)
        diagnostics.nativeGPUCanvasDrawn(first)
        diagnostics.nativeGPUCanvasDrawn(first)
        diagnostics.nativeGPUCanvasDrawn(second)
        diagnostics.nativeGPUCanvasDrawn(cursor)
        var receipts = try XCTUnwrap(
            diagnostics.snapshot()["native_canvas_frames"] as? [String: [String: Any]])
        XCTAssertEqual(Set(receipts.keys), [String(first), String(second)])
        XCTAssertEqual(
            diagnostics.snapshot()["native_canvas_draws"] as? [String: UInt64],
            [String(first): 2, String(second): 1],
            "Each visible chart proves its own continued drawing")
        XCTAssertEqual(receipts[String(first)]?["width"] as? Double, 690.25)
        XCTAssertEqual(receipts[String(first)]?["height"] as? Double, 200.5)
        XCTAssertEqual(receipts[String(first)]?["scale"] as? Double, 2)
        diagnostics.canvasGeometry(first, width: 600, height: 190, scale: 1)
        receipts = try XCTUnwrap(
            diagnostics.snapshot()["native_canvas_frames"] as? [String: [String: Any]])
        XCTAssertEqual(
            receipts[String(first)]?["width"] as? Double, 600,
            "Current geometry must not expose historical maxima")
        let before = receipts as NSDictionary
        diagnostics.canvasGeometry(first, width: .nan, height: 190, scale: 1)
        XCTAssertEqual(diagnostics.snapshot()["native_canvas_frames"] as? NSDictionary, before)
        diagnostics.canvasDestroyed(first)
        XCTAssertEqual(
            (diagnostics.snapshot()["native_canvas_frames"] as? [String: [String: Any]])?.count, 1)
        XCTAssertEqual(
            diagnostics.snapshot()["native_canvas_draws"] as? [String: UInt64], [String(second): 1])
        diagnostics.canvasDestroyed(second)
        diagnostics.canvasDestroyed(cursor)
        XCTAssertTrue(
            try XCTUnwrap(
                diagnostics.snapshot()["native_canvas_frames"] as? [String: [String: Any]]
            ).isEmpty)
        XCTAssertTrue(
            try XCTUnwrap(diagnostics.snapshot()["native_canvas_draws"] as? [String: UInt64])
                .isEmpty)
    }

    private func recordWork(_ diagnostics: Diagnostics) {
        diagnostics.recordScalarLeafBody(.header, owner: dashboard)
        diagnostics.recordDashboardLayoutSize()
        diagnostics.recordDashboardLayoutPlace()
        diagnostics.recordDashboardLayoutChildMeasurements(3)
        diagnostics.performanceScalarFramesUpdated(
            owner: dashboard, role: "dashboard", frames: frames)
        diagnostics.frozenScalarPresentationCaptured(
            owner: dashboard, role: "dashboard", fingerprint: fingerprint, frames: frames)
    }

    private func scalar(_ snapshot: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(snapshot["scalar_presentation"] as? [String: Any])
    }
}
