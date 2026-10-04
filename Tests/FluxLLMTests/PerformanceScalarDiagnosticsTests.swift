import Foundation
import XCTest

@testable import FluxLLM

/// Production scalar instrumentation remains bounded and optional after the
/// diagnostic renderers and their capture receipts have been retired.
@MainActor
final class PerformanceScalarDiagnosticsTests: XCTestCase {
    private typealias Diagnostics = PerformanceGraphicsDiagnostics
    private let dashboard = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let popover = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private var frames: [String: CGRect] {
        [
            "native-window": CGRect(x: -40.5, y: 21.25, width: 720, height: 620),
            "activity-chart": CGRect(x: 14, y: 50, width: 690, height: 200),
            "main-activity-plot": CGRect(x: 14, y: 50, width: 690, height: 170),
        ]
    }

    func testDisabledInstrumentationCannotRecordScalarWorkOrFrames() throws {
        let diagnostics = Diagnostics()
        let initial = diagnostics.snapshot() as NSDictionary
        recordWork(diagnostics)
        XCTAssertNil(diagnostics.layoutCountersForPresentation)
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
        try diagnostics.enable()
        recordWork(diagnostics)
        let recorded = try scalar(diagnostics.snapshot())
        XCTAssertEqual(recorded["layout_size_calls"] as? UInt64, 1)
        XCTAssertEqual(recorded["layout_place_calls"] as? UInt64, 1)
        XCTAssertEqual(recorded["layout_child_measurements"] as? UInt64, 3)
        XCTAssertEqual((recorded["leaf_body_updates"] as? [String: UInt64])?["header"], 1)
        diagnostics.performanceScalarPresentationReleased(owner: dashboard)
        try diagnostics.disable()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
    }

    func testTwoOwnersKeepActualBodiesFramesAndRenderedValuesDisjoint() throws {
        let diagnostics = Diagnostics()
        try diagnostics.enable()
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: frames))
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: popover, role: "popover", frames: frames))
        diagnostics.recordScalarLeafBody(.header, owner: dashboard)
        diagnostics.recordScalarLeafBody(.metrics, owner: dashboard)
        diagnostics.recordScalarLeafBody(.metrics, owner: popover)
        diagnostics.recordScalarPresentedValues(
            .metrics, owner: dashboard, compact: false,
            values: ["rate": "17.3", "gpu": "38"])
        diagnostics.recordScalarPresentedValues(
            .metrics, owner: popover, compact: true,
            values: ["rate": "12.0", "gpu": "38"])
        var changed = frames
        changed["activity-chart"]!.size.width += 0.125
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: changed))
        diagnostics.recordScalarLeafBody(.details, owner: popover)
        let snapshot = try scalar(diagnostics.snapshot())
        let owners = try XCTUnwrap(snapshot["presentation_owners"] as? [String: [String: Any]])
        XCTAssertEqual(Set(owners.keys), [dashboard.uuidString, popover.uuidString])
        let first = try XCTUnwrap(owners[dashboard.uuidString])
        let second = try XCTUnwrap(owners[popover.uuidString])
        XCTAssertNotEqual(
            first["current_frames"] as? NSDictionary, second["current_frames"] as? NSDictionary)
        XCTAssertEqual((first["leaf_body_updates"] as? [String: UInt64])?["header"], 1)
        XCTAssertEqual((first["leaf_body_updates"] as? [String: UInt64])?["details"], 0)
        XCTAssertEqual((second["leaf_body_updates"] as? [String: UInt64])?["header"], 0)
        XCTAssertEqual((second["leaf_body_updates"] as? [String: UInt64])?["details"], 1)
        let firstValues = try XCTUnwrap(first["presented_values"] as? [String: [String: String]])
        let secondValues = try XCTUnwrap(second["presented_values"] as? [String: [String: String]])
        XCTAssertEqual(firstValues["metrics"]?["rate"], "17.3")
        XCTAssertEqual(secondValues["metrics"]?["rate"], "12.0")
        XCTAssertNoThrow(
            try JSONSerialization.data(
                withJSONObject: diagnostics.snapshot(), options: [.sortedKeys]))
        diagnostics.performanceScalarPresentationReleased(owner: dashboard)
        diagnostics.performanceScalarPresentationReleased(owner: popover)
        try diagnostics.disable()
    }

    func testClosingOneOwnerCannotHideAnotherAndCleanupIsIdempotent() throws {
        let diagnostics = Diagnostics()
        try diagnostics.enable()
        for (owner, role) in [(dashboard, "dashboard"), (popover, "popover")] {
            XCTAssertTrue(
                diagnostics.performanceScalarFramesUpdated(owner: owner, role: role, frames: frames)
            )
            diagnostics.recordScalarLeafBody(.header, owner: owner)
        }
        diagnostics.performanceScalarPresentationReleased(owner: dashboard)
        var owners = try XCTUnwrap(
            try scalar(diagnostics.snapshot())["presentation_owners"] as? [String: [String: Any]])
        XCTAssertEqual(Set(owners.keys), [popover.uuidString])
        diagnostics.performanceScalarPresentationReleased(owner: dashboard)
        diagnostics.performanceScalarPresentationReleased(owner: popover)
        owners = try XCTUnwrap(
            try scalar(diagnostics.snapshot())["presentation_owners"] as? [String: [String: Any]])
        XCTAssertTrue(owners.isEmpty)
        XCTAssertEqual(
            (try scalar(diagnostics.snapshot())["leaf_body_updates"] as? [String: UInt64])?[
                "header"], 2)
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 0)
        try diagnostics.disable()
    }

    func testActiveScalarOwnersPreventResetUntilReleased() throws {
        let diagnostics = Diagnostics()
        let initial = diagnostics.snapshot() as NSDictionary
        try diagnostics.enable()
        diagnostics.recordScalarLeafBody(.header, owner: dashboard)
        XCTAssertThrowsError(try diagnostics.enable())
        XCTAssertThrowsError(try diagnostics.disable())
        diagnostics.performanceScalarPresentationReleased(owner: dashboard)
        try diagnostics.enable()
        XCTAssertTrue(
            diagnostics.performanceScalarFramesUpdated(
                owner: dashboard, role: "dashboard", frames: frames))
        diagnostics.performanceScalarPresentationReleased(owner: dashboard)
        try diagnostics.disable()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
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
        try diagnostics.enable(mode: .normal)
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

        try diagnostics.enable(mode: .normal)
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
        try diagnostics.enable(mode: .normal)
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
    }

    private func scalar(_ snapshot: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(snapshot["scalar_presentation"] as? [String: Any])
    }
}
