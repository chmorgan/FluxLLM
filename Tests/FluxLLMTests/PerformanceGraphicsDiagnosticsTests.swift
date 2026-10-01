import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class PerformanceGraphicsDiagnosticsTests: XCTestCase {
    func testModesRoundTripAndRejectUnknownValues() throws {
        typealias Mode = PerformanceGraphicsDiagnostics.Mode
        XCTAssertEqual(Mode.normal.rawValue, "normal")
        XCTAssertEqual(Mode.directHost.rawValue, "direct-host")
        XCTAssertEqual(Mode.noBlur.rawValue, "no-blur")
        XCTAssertEqual(Mode.cpuGlow.rawValue, "cpu-glow")
        XCTAssertEqual(Mode.allCases.count, 7)
        for mode in Mode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(Mode.self, from: encoded), mode)
        }
        for value in ["", "directHost", "unsupported-mode"] {
            let encoded = try JSONEncoder().encode(value)
            XCTAssertThrowsError(try JSONDecoder().decode(Mode.self, from: encoded))
        }
    }

    func testCPUGlowFallbacksAreReportedOnlyForThatEnabledCandidate() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        diagnostics.recordCPUGlowFallback()
        assertCounter("cpu_glow_fallbacks", in: diagnostics.snapshot(), equals: 0)
        try diagnostics.enable(mode: .normal)
        diagnostics.recordCPUGlowFallback()
        assertCounter("cpu_glow_fallbacks", in: diagnostics.snapshot(), equals: 0)
        try diagnostics.enable(mode: .cpuGlow)
        diagnostics.recordCPUGlowFallback()
        assertCounter("cpu_glow_fallbacks", in: diagnostics.snapshot(), equals: 1)
        try diagnostics.disable()
        assertCounter("cpu_glow_fallbacks", in: diagnostics.snapshot(), equals: 0)
    }

    func testDisabledDiagnosticsIgnoreAllEvents() {
        let diagnostics = PerformanceGraphicsDiagnostics()
        let initial = diagnostics.snapshot()
        XCTAssertEqual(initial["enabled"] as? Bool, false)
        XCTAssertEqual(initial["mode"] as? String, "normal")
        for key in [
            "invalid_events", "live_canvases", "peak_live_canvases",
            "live_renderers", "peak_live_renderers", "current_pixel_area",
            "peak_pixel_area", "current_bitmap_bytes", "peak_bitmap_bytes",
        ] {
            assertCounter(key, in: initial, equals: 0)
        }
        for role in PerformanceGraphicsDiagnostics.Role.allCases {
            XCTAssertNil(diagnostics.canvasCreated(role: role))
        }
        let ids: [UInt64?] = [nil, 123]
        for id in ids {
            diagnostics.canvasGeometry(id, width: 10, height: 20, scale: 2)
            diagnostics.canvasUpdated(id)
            diagnostics.rendererCreated(id)
            diagnostics.rendererUpdated(id)
            diagnostics.canvasDrawn(id)
            diagnostics.drawSkipped(id)
            diagnostics.bitmapBytes(id, bytes: 4_096)
            diagnostics.rendererDestroyed(id)
            diagnostics.canvasDestroyed(id)
        }
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial as NSDictionary)
    }

    func testLiveCanvasesPreventResetAndSuccessfulResetClearsCounters() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .emptyDrawing)
        let first = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
        let second = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
        XCTAssertNotEqual(first, second)
        diagnostics.canvasUpdated(first)
        diagnostics.canvasDrawn(first)
        diagnostics.canvasDrawn(second)
        diagnostics.drawSkipped(second)

        XCTAssertThrowsError(try diagnostics.enable(mode: .directHost))
        XCTAssertThrowsError(try diagnostics.disable())
        let live = diagnostics.snapshot()
        XCTAssertEqual(live["enabled"] as? Bool, true)
        XCTAssertEqual(
            live["mode"] as? String, PerformanceGraphicsDiagnostics.Mode.emptyDrawing.rawValue)
        assertCounter("live_canvases", in: live, equals: 2)
        assertCounter("peak_live_canvases", in: live, equals: 2)
        let cursor = try role(.cursor, in: live)
        assertCounter("created", in: cursor, equals: 2)
        assertCounter("live", in: cursor, equals: 2)
        assertCounter("peak_live", in: cursor, equals: 2)
        assertCounter("updates", in: cursor, equals: 1)
        assertCounter("draws", in: cursor, equals: 2)
        assertCounter("skipped_draws", in: cursor, equals: 1)

        diagnostics.canvasDestroyed(first)
        diagnostics.canvasDestroyed(second)
        let finished = diagnostics.snapshot()
        assertCounter("live_canvases", in: finished, equals: 0)
        assertCounter("peak_live_canvases", in: finished, equals: 2)
        assertCounter("destroyed", in: try role(.cursor, in: finished), equals: 2)
        try diagnostics.enable(mode: .directHost)
        let reset = diagnostics.snapshot()
        XCTAssertEqual(reset["mode"] as? String, "direct-host")
        assertCounter("peak_live_canvases", in: reset, equals: 0)
        assertCounter("created", in: try role(.cursor, in: reset), equals: 0)
        try diagnostics.disable()
        XCTAssertEqual(
            diagnostics.snapshot() as NSDictionary,
            PerformanceGraphicsDiagnostics().snapshot() as NSDictionary)
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

    func testRendererTransitionsRejectDuplicatesAndCanvasDestructionReleasesOwnership() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable()
        let chart = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
        let cursor = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
        diagnostics.rendererCreated(chart)
        diagnostics.rendererCreated(chart)
        diagnostics.rendererUpdated(chart)
        diagnostics.rendererUpdated(chart)
        diagnostics.rendererCreated(cursor)
        assertCounter("live_renderers", in: diagnostics.snapshot(), equals: 2)
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 1)

        diagnostics.rendererDestroyed(chart)
        diagnostics.rendererDestroyed(chart)
        assertCounter("live_renderers", in: diagnostics.snapshot(), equals: 1)
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 2)
        diagnostics.rendererCreated(chart)
        diagnostics.canvasDestroyed(chart)
        diagnostics.canvasDestroyed(cursor)

        let finished = diagnostics.snapshot()
        assertCounter("live_renderers", in: finished, equals: 0)
        assertCounter("peak_live_renderers", in: finished, equals: 2)
        assertCounter("invalid_events", in: finished, equals: 2)
        let chartCounters = try role(.staticChart, in: finished)
        assertCounter("renderer_creations", in: chartCounters, equals: 2)
        assertCounter("renderer_updates", in: chartCounters, equals: 2)
        assertCounter("renderer_destructions", in: chartCounters, equals: 2)
        assertCounter("live_renderers", in: chartCounters, equals: 0)
        assertCounter("peak_live_renderers", in: chartCounters, equals: 1)
        let cursorCounters = try role(.cursor, in: finished)
        assertCounter("renderer_creations", in: cursorCounters, equals: 1)
        assertCounter("renderer_destructions", in: cursorCounters, equals: 1)
        assertCounter("live_renderers", in: cursorCounters, equals: 0)
    }

    func testBitmapBytesRepresentCurrentBuffersAndReleaseOnCanvasDestruction() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .bitmapDestination)
        let chart = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
        let cursor = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
        diagnostics.bitmapBytes(chart, bytes: 1_024)
        diagnostics.bitmapBytes(chart, bytes: 1_024)
        assertCounter("current_bitmap_bytes", in: diagnostics.snapshot(), equals: 1_024)
        diagnostics.bitmapBytes(cursor, bytes: 2_048)
        assertCounter("current_bitmap_bytes", in: diagnostics.snapshot(), equals: 3_072)
        diagnostics.bitmapBytes(chart, bytes: 512)
        let resized = diagnostics.snapshot()
        assertCounter("current_bitmap_bytes", in: resized, equals: 2_560)
        assertCounter("peak_bitmap_bytes", in: resized, equals: 3_072)

        diagnostics.canvasDestroyed(chart)
        assertCounter("current_bitmap_bytes", in: diagnostics.snapshot(), equals: 2_048)
        diagnostics.bitmapBytes(cursor, bytes: 0)
        assertCounter("current_bitmap_bytes", in: diagnostics.snapshot(), equals: 0)
        diagnostics.bitmapBytes(cursor, bytes: 2_048)
        diagnostics.canvasDestroyed(cursor)
        let finished = diagnostics.snapshot()
        assertCounter("current_bitmap_bytes", in: finished, equals: 0)
        assertCounter("peak_bitmap_bytes", in: finished, equals: 3_072)
        assertCounter("invalid_events", in: finished, equals: 0)
    }

    func testNilIDsAreNoOpsAndUnknownOrDestroyedIDsCannotCreateAccounting() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable()
        let id = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
        let initial = diagnostics.snapshot()
        let eventIDs: [UInt64?] = [nil, UInt64.max]
        for eventID in eventIDs {
            diagnostics.canvasGeometry(eventID, width: 10, height: 20, scale: 2)
            diagnostics.canvasUpdated(eventID)
            diagnostics.rendererCreated(eventID)
            diagnostics.rendererUpdated(eventID)
            diagnostics.rendererDestroyed(eventID)
            diagnostics.canvasDrawn(eventID)
            diagnostics.drawSkipped(eventID)
            diagnostics.bitmapBytes(eventID, bytes: 4_096)
            diagnostics.canvasDestroyed(eventID)
            if eventID == nil {
                XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial as NSDictionary)
            }
        }
        var expected = initial
        expected["invalid_events"] = UInt64(9)
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, expected as NSDictionary)

        diagnostics.canvasDestroyed(id)
        diagnostics.canvasDestroyed(id)
        diagnostics.canvasUpdated(id)
        let finished = diagnostics.snapshot()
        assertCounter("invalid_events", in: finished, equals: 11)
        assertCounter("live_canvases", in: finished, equals: 0)
        assertCounter("destroyed", in: try role(.cursor, in: finished), equals: 1)
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
