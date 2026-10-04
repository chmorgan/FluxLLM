import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class PerformanceGraphicsDiagnosticsTests: XCTestCase {

    func testOnlyTheProductionPathCanBeSelected() throws {
        typealias Mode = PerformanceGraphicsDiagnostics.Mode
        XCTAssertEqual(Mode.allCases, [.normal])
        XCTAssertEqual(try JSONDecoder().decode(Mode.self, from: Data("\"normal\"".utf8)), .normal)
        for retired in ["runtime-metal-full-chart", "bitmap-destination", "runtime-frozen-scalars"]
        {
            XCTAssertNil(Mode(rawValue: retired))
        }
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable()
        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot["mode"] as? String, "normal")
        XCTAssertEqual(snapshot["native_gpu_backend"] as? String, "swiftui-canvas-drawing-group")
        XCTAssertEqual(snapshot["chart_publication_interval_seconds"] as? Double, 1)
        XCTAssertEqual(snapshot["arrival_backend"] as? String, "canvas")
        XCTAssertEqual(
            snapshot["retained_twinkle_backend"] as? String, "core-animation-shape-layers")
        for flag in [
            "metal_full_chart_enabled", "metal_primitive_effects_enabled",
            "batched_telemetry_delivery_enabled", "atomic_chart_scale_enabled",
            "completed_lane_cache_enabled", "rail_geometry_cache_enabled",
            "frozen_scalar_presentation_enabled", "held_usage_enabled", "retained_usage_fields",
        ] {
            XCTAssertEqual(snapshot[flag] as? Bool, false, flag)
        }
    }

    func testDisabledHooksDoNotCreateOwnersOrRecordWork() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        let before = diagnostics.snapshot() as NSDictionary
        XCTAssertNil(diagnostics.canvasCreated(role: .staticChart))
        XCTAssertNil(diagnostics.retainedTwinkleHostCreated())
        XCTAssertNil(diagnostics.layoutCountersForPresentation)
        diagnostics.canvasGeometry(1, width: 100, height: 100, scale: 2)
        diagnostics.canvasUpdated(1)
        diagnostics.canvasDrawn(1)
        diagnostics.nativeGPUCanvasDrawn(1)
        diagnostics.drawSkipped(1)
        diagnostics.canvasDestroyed(1)
        diagnostics.retainedTwinkleHostUpdated(2, instances: ["a"], animationsStarted: 4)
        diagnostics.retainedTwinkleHostDestroyed(2)
        diagnostics.scalarPresentationPublished()
        diagnostics.recordScalarLeafBody(.header, owner: UUID())
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, before)
    }

    func testLiveOwnersPreventResetAndRetiredIDsCannotReappearInNewEpochs() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable()
        let id = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
        XCTAssertThrowsError(try diagnostics.enable())
        XCTAssertThrowsError(try diagnostics.disable())
        diagnostics.canvasDestroyed(id)
        try diagnostics.enable()
        let replacement = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
        XCTAssertNotEqual(id, replacement)
        diagnostics.nativeGPUCanvasDrawn(id)
        diagnostics.canvasDestroyed(id)
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 2)
        assertCounter("native_gpu_canvas_draws", in: diagnostics.snapshot(), equals: 0)
        assertCounter("live_canvases", in: diagnostics.snapshot(), equals: 1)
        diagnostics.canvasDestroyed(replacement)
        try diagnostics.disable()
        XCTAssertEqual(
            diagnostics.snapshot() as NSDictionary,
            PerformanceGraphicsDiagnostics().snapshot() as NSDictionary)
    }

    func testScalarPublicationsAreOptInAndReset() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        diagnostics.scalarPresentationPublished()
        assertCounter("scalar_presentation_publications", in: diagnostics.snapshot(), equals: 0)
        try diagnostics.enable()
        diagnostics.scalarPresentationPublished()
        diagnostics.scalarPresentationPublished()
        assertCounter("scalar_presentation_publications", in: diagnostics.snapshot(), equals: 2)
        try diagnostics.disable()
        assertCounter("scalar_presentation_publications", in: diagnostics.snapshot(), equals: 0)
    }

    func testGeometryTracksCurrentAreaAndConcurrentPeaksAcrossRoles() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable()
        let chart = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
        let rail = try XCTUnwrap(diagnostics.canvasCreated(role: .railBars))
        // Pixel dimensions are rounded up independently: ceil(15.375) * ceil(4.5).
        diagnostics.canvasGeometry(chart, width: 10.25, height: 3, scale: 1.5)
        diagnostics.canvasGeometry(chart, width: 10.25, height: 3, scale: 1.5)
        assertCounter("current_pixel_area", in: diagnostics.snapshot(), equals: 80)
        diagnostics.canvasGeometry(rail, width: 2, height: 5, scale: 2)
        assertCounter("current_pixel_area", in: diagnostics.snapshot(), equals: 120)

        diagnostics.canvasGeometry(chart, width: 3, height: 2, scale: 1)
        let resized = diagnostics.snapshot()
        assertCounter("current_pixel_area", in: resized, equals: 46)
        assertCounter("peak_pixel_area", in: resized, equals: 120)
        let chartCounters = try role(.staticChart, in: resized)
        assertCounter("current_pixel_area", in: chartCounters, equals: 6)
        assertCounter("peak_pixel_area", in: chartCounters, equals: 80)
        XCTAssertEqual(chartCounters["max_width_points"] as? Double, 10.25)
        XCTAssertEqual(chartCounters["max_height_points"] as? Double, 3)
        XCTAssertEqual(chartCounters["max_scale"] as? Double, 1.5)
        assertCounter("current_pixel_area", in: try role(.railBars, in: resized), equals: 40)

        diagnostics.canvasGeometry(rail, width: 0, height: 5, scale: 2)
        assertCounter("current_pixel_area", in: diagnostics.snapshot(), equals: 6)
        diagnostics.canvasDestroyed(chart)
        diagnostics.canvasDestroyed(rail)
        let finished = diagnostics.snapshot()
        assertCounter("current_pixel_area", in: finished, equals: 0)
        assertCounter("peak_pixel_area", in: finished, equals: 120)
        assertCounter("invalid_events", in: finished, equals: 0)
    }

    func testInvalidGeometryPreservesPreviousAccountingAndZeroSizeIsValid() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable()
        let id = try XCTUnwrap(diagnostics.canvasCreated(role: .railDecorations))
        diagnostics.canvasGeometry(id, width: 6, height: 4, scale: 2)
        let originalRole = try role(.railDecorations, in: diagnostics.snapshot())
        let invalid: [(Double, Double, Double)] = [
            (-1, 4, 2), (6, -1, 2), (6, 4, 0), (6, 4, -1),
            (.nan, 4, 2), (.infinity, 4, 2),
            (6, .nan, 2), (6, .infinity, 2),
            (6, 4, .nan), (6, 4, .infinity),
            (.greatestFiniteMagnitude, 4, 2),
            (4_294_967_296, 4_294_967_296, 1),
        ]
        for (width, height, scale) in invalid {
            diagnostics.canvasGeometry(id, width: width, height: height, scale: scale)
        }
        let afterInvalid = diagnostics.snapshot()
        assertCounter("current_pixel_area", in: afterInvalid, equals: 96)
        assertCounter("peak_pixel_area", in: afterInvalid, equals: 96)
        assertCounter("invalid_events", in: afterInvalid, equals: UInt64(invalid.count))
        XCTAssertEqual(
            try role(.railDecorations, in: afterInvalid) as NSDictionary,
            originalRole as NSDictionary)

        diagnostics.canvasGeometry(id, width: 6, height: 0, scale: 2)
        let zero = diagnostics.snapshot()
        assertCounter("current_pixel_area", in: zero, equals: 0)
        assertCounter("peak_pixel_area", in: zero, equals: 96)
        assertCounter("invalid_events", in: zero, equals: UInt64(invalid.count))
        diagnostics.canvasDestroyed(id)
    }

    func testNativeGPUCallbacksRequireLiveOwnersAndReconcileRolesAcrossTheirLifetimes() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable()
        let chart = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
        let decoration = try XCTUnwrap(diagnostics.canvasCreated(role: .railDecorations))
        let initial = diagnostics.snapshot()
        diagnostics.nativeGPUCanvasDrawn(nil)
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial as NSDictionary)
        diagnostics.nativeGPUCanvasDrawn(UInt64.max)
        diagnostics.nativeGPUCanvasDrawn(chart)
        diagnostics.nativeGPUCanvasDrawn(decoration)
        diagnostics.nativeGPUCanvasDrawn(decoration)
        diagnostics.canvasDestroyed(chart)
        diagnostics.nativeGPUCanvasDrawn(chart)
        let replacement = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
        XCTAssertNotEqual(chart, replacement)
        diagnostics.nativeGPUCanvasDrawn(replacement)
        diagnostics.canvasDestroyed(replacement)
        diagnostics.canvasDestroyed(decoration)

        let finished = diagnostics.snapshot()
        assertCounter("native_gpu_canvas_draws", in: finished, equals: 4)
        assertCounter("draws", in: try role(.staticChart, in: finished), equals: 2)
        assertCounter("draws", in: try role(.railDecorations, in: finished), equals: 2)
        assertCounter("invalid_events", in: finished, equals: 2)
        for key in [
            "live_canvases", "live_renderers", "peak_live_renderers",
            "current_bitmap_bytes", "peak_bitmap_bytes",
            "current_layer_image_bytes", "peak_layer_image_bytes",
        ] {
            assertCounter(key, in: finished, equals: 0)
        }
        for canvasRole in PerformanceGraphicsDiagnostics.Role.allCases {
            let counters = try role(canvasRole, in: finished)
            assertCounter("renderer_creations", in: counters, equals: 0)
            assertCounter("renderer_updates", in: counters, equals: 0)
            assertCounter("renderer_destructions", in: counters, equals: 0)
        }

        try diagnostics.enable()
        diagnostics.nativeGPUCanvasDrawn(replacement)
        assertCounter("native_gpu_canvas_draws", in: diagnostics.snapshot(), equals: 0)
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 1)
    }

    func testRetainedTwinklesAccountForReplacementAndReleaseAcrossHosts() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable()
        let first = try XCTUnwrap(diagnostics.retainedTwinkleHostCreated())
        let second = try XCTUnwrap(diagnostics.retainedTwinkleHostCreated())
        diagnostics.retainedTwinkleHostUpdated(first, instances: ["a", "b"], animationsStarted: 8)
        diagnostics.retainedTwinkleHostUpdated(second, instances: ["a"], animationsStarted: 4)
        // Updating geometry must not claim new instances or new animations.
        diagnostics.retainedTwinkleHostUpdated(first, instances: ["a", "b"], animationsStarted: 0)
        diagnostics.retainedTwinkleHostUpdated(first, instances: ["b", "c"], animationsStarted: 4)
        let live = try XCTUnwrap(diagnostics.snapshot()["retained_twinkles"] as? [String: UInt64])
        XCTAssertEqual(live["instances_created"], 4)
        XCTAssertEqual(live["instances_destroyed"], 1)
        XCTAssertEqual(live["live_instances"], 3)
        XCTAssertEqual(live["peak_instances"], 3)
        XCTAssertEqual(live["animation_starts"], 16)
        XCTAssertThrowsError(try diagnostics.disable())
        diagnostics.retainedTwinkleHostDestroyed(first)
        diagnostics.retainedTwinkleHostDestroyed(second)
        let closed = try XCTUnwrap(diagnostics.snapshot()["retained_twinkles"] as? [String: UInt64])
        XCTAssertEqual(closed["live_hosts"], 0)
        XCTAssertEqual(closed["live_instances"], 0)
        XCTAssertEqual(closed["hosts_destroyed"], 2)
        XCTAssertEqual(closed["instances_destroyed"], 4)
        try diagnostics.disable()
        XCTAssertEqual(
            diagnostics.snapshot() as NSDictionary,
            PerformanceGraphicsDiagnostics().snapshot() as NSDictionary)
    }

    func testRetainedTwinklesRejectStaleOwnersOverCapacityAndOverflowAtomically() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable()
        let host = try XCTUnwrap(diagnostics.retainedTwinkleHostCreated())
        diagnostics.retainedTwinkleHostUpdated(host, instances: [1], animationsStarted: 4)
        let before = diagnostics.snapshot()["retained_twinkles"] as? [String: UInt64]
        diagnostics.retainedTwinkleHostUpdated(host, instances: [1, 2, 3], animationsStarted: 8)
        diagnostics.retainedTwinkleHostUpdated(host, instances: [2], animationsStarted: .max)
        XCTAssertEqual(diagnostics.snapshot()["retained_twinkles"] as? [String: UInt64], before)
        diagnostics.retainedTwinkleHostDestroyed(host)
        let closed = diagnostics.snapshot()["retained_twinkles"] as? [String: UInt64]
        diagnostics.retainedTwinkleHostUpdated(host, instances: [2], animationsStarted: 4)
        diagnostics.retainedTwinkleHostDestroyed(host)
        diagnostics.retainedTwinkleHostUpdated(nil, instances: [2], animationsStarted: 4)
        diagnostics.retainedTwinkleHostDestroyed(nil)
        XCTAssertEqual(diagnostics.snapshot()["retained_twinkles"] as? [String: UInt64], closed)
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 4)
    }

    private func role(
        _ role: PerformanceGraphicsDiagnostics.Role, in snapshot: [String: Any],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        let roles = try XCTUnwrap(
            snapshot["roles"] as? [String: [String: Any]], file: file, line: line)
        return try XCTUnwrap(roles[role.rawValue], file: file, line: line)
    }

    private func assertCounter(
        _ key: String, in snapshot: [String: Any], equals expected: UInt64,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(snapshot[key] as? UInt64, expected, key, file: file, line: line)
    }

}
