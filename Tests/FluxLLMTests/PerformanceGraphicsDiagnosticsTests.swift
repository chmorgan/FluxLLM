import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class PerformanceGraphicsDiagnosticsTests: XCTestCase {
    func testPrimitiveEffectsCountersTrackOverlappingFramesAndDrainResources() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeMetalPrimitiveEffects)
        let first = try XCTUnwrap(diagnostics.metalPrimitiveEffectsHostCreated())
        let second = try XCTUnwrap(diagnostics.metalPrimitiveEffectsHostCreated())
        diagnostics.metalPrimitiveEffectsDescriptorsUploaded(first, bytes: 1_024)
        diagnostics.metalPrimitiveEffectsDescriptorsUploaded(second, bytes: 512)
        diagnostics.metalPrimitiveEffectsFrameSubmitted(
            first, arrival: true, completion: false, twinkle: true, clear: false)
        diagnostics.metalPrimitiveEffectsFrameSubmitted(
            second, arrival: false, completion: true, twinkle: false, clear: false)
        diagnostics.metalPrimitiveEffectsFrameSubmitted(
            first, arrival: false, completion: false, twinkle: false, clear: true)
        XCTAssertThrowsError(try diagnostics.enable(mode: .normal))
        XCTAssertThrowsError(try diagnostics.disable())
        var counts = try XCTUnwrap(
            diagnostics.snapshot()["metal_primitive_effects"] as? [String: UInt64])
        XCTAssertEqual(counts["submissions"], 3)
        XCTAssertEqual(counts["clears"], 1)
        XCTAssertEqual(counts["arrival_frames"], 1)
        XCTAssertEqual(counts["completion_frames"], 1)
        XCTAssertEqual(counts["twinkle_frames"], 1)
        XCTAssertEqual(counts["current_buffer_bytes"], 1_536)
        XCTAssertEqual(counts["peak_buffer_bytes"], 1_536)
        XCTAssertEqual(counts["live_hosts"], 2)
        diagnostics.metalPrimitiveEffectsBuffersRetained(first, bytes: 0)
        diagnostics.metalPrimitiveEffectsHostDestroyed(first)
        diagnostics.metalPrimitiveEffectsHostDestroyed(second)
        counts = try XCTUnwrap(
            diagnostics.snapshot()["metal_primitive_effects"] as? [String: UInt64])
        XCTAssertEqual(counts["live_hosts"], 0)
        XCTAssertEqual(counts["current_buffer_bytes"], 0)
        XCTAssertEqual(counts["hosts_destroyed"], 2)
        XCTAssertEqual(counts["peak_buffer_bytes"], 1_536)
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 0)
        try diagnostics.disable()
        XCTAssertEqual(
            diagnostics.snapshot() as NSDictionary,
            PerformanceGraphicsDiagnostics().snapshot() as NSDictionary)
    }

    func testPrimitiveEffectsRejectStaleOwnersOverflowAndInvalidClear() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeMetalPrimitiveEffects)
        let first = try XCTUnwrap(diagnostics.metalPrimitiveEffectsHostCreated())
        let second = try XCTUnwrap(diagnostics.metalPrimitiveEffectsHostCreated())
        diagnostics.metalPrimitiveEffectsDescriptorsUploaded(first, bytes: .max)
        let previous = diagnostics.snapshot()["metal_primitive_effects"] as? [String: UInt64]
        XCTAssertFalse(diagnostics.metalPrimitiveEffectsBuffersRetained(second, bytes: 1))
        diagnostics.metalPrimitiveEffectsFrameSubmitted(
            first, arrival: true, completion: false, twinkle: false, clear: true)
        XCTAssertEqual(
            diagnostics.snapshot()["metal_primitive_effects"] as? [String: UInt64], previous)
        diagnostics.metalPrimitiveEffectsHostDestroyed(first)
        diagnostics.metalPrimitiveEffectsHostDestroyed(second)
        diagnostics.metalPrimitiveEffectsDescriptorsUploaded(first, bytes: 4)
        diagnostics.metalPrimitiveEffectsFrameSubmitted(
            first, arrival: true, completion: false, twinkle: false, clear: false)
        diagnostics.metalPrimitiveEffectsHostDestroyed(first)
        diagnostics.metalPrimitiveEffectsFrameSkipped(first)
        diagnostics.metalPrimitiveEffectsFailure(first)
        diagnostics.metalPrimitiveEffectsFallback()
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 7)
        let finished = try XCTUnwrap(
            diagnostics.snapshot()["metal_primitive_effects"] as? [String: UInt64])
        XCTAssertEqual(finished["descriptor_uploads"], 1)
        XCTAssertEqual(finished["submissions"], 0)
        XCTAssertEqual(finished["failures"], 1)
        XCTAssertEqual(finished["fallbacks"], 1)
    }

    func testNewMechanismCountersAreCandidateScopedAndReset() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        let initial = diagnostics.snapshot() as NSDictionary
        diagnostics.batchedTelemetryStateEnqueued(count: 10)
        diagnostics.batchedTelemetrySnapshotMaterialized(count: 2)
        diagnostics.batchedTelemetryBatchApplied(eventCount: 2)
        diagnostics.batchedTelemetryProjectionRefreshed()
        diagnostics.recordAtomicChartScaleResolution(changed: true)
        diagnostics.recordAtomicChartScaleCacheHit()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
        for mode in PerformanceGraphicsDiagnostics.Mode.allCases {
            try diagnostics.enable(mode: mode)
            let host = diagnostics.metalPrimitiveEffectsHostCreated()
            XCTAssertEqual(host != nil, mode.usesMetalPrimitiveEffects)
            diagnostics.metalPrimitiveEffectsDescriptorsUploaded(host, bytes: 256)
            diagnostics.metalPrimitiveEffectsFrameSubmitted(
                host, arrival: true, completion: true, twinkle: true, clear: false)
            diagnostics.metalPrimitiveEffectsFrameSkipped(host)
            diagnostics.metalPrimitiveEffectsFailure(host)
            diagnostics.metalPrimitiveEffectsFallback()
            diagnostics.metalPrimitiveEffectsHostDestroyed(host)
            diagnostics.batchedTelemetryStateEnqueued(count: 10)
            diagnostics.batchedTelemetrySnapshotMaterialized(count: 2)
            diagnostics.batchedTelemetryBatchApplied(eventCount: 2)
            diagnostics.batchedTelemetryProjectionRefreshed()
            diagnostics.recordAtomicChartScaleResolution(changed: true)
            diagnostics.recordAtomicChartScaleResolution(changed: false)
            diagnostics.recordAtomicChartScaleCacheHit()
            let snapshot = diagnostics.snapshot()
            XCTAssertEqual(
                snapshot["metal_primitive_effects_enabled"] as? Bool, mode.usesMetalPrimitiveEffects
            )
            XCTAssertEqual(
                snapshot["batched_telemetry_delivery_enabled"] as? Bool,
                mode.usesBatchedTelemetryDelivery)
            XCTAssertEqual(
                snapshot["atomic_chart_scale_enabled"] as? Bool, mode.usesAtomicChartScale)
            let effects = try XCTUnwrap(snapshot["metal_primitive_effects"] as? [String: UInt64])
            XCTAssertEqual(effects["descriptor_uploads"], mode.usesMetalPrimitiveEffects ? 1 : 0)
            XCTAssertEqual(effects["submissions"], mode.usesMetalPrimitiveEffects ? 1 : 0)
            let telemetry = try XCTUnwrap(snapshot["batched_telemetry"] as? [String: UInt64])
            XCTAssertEqual(
                telemetry["compact_states_enqueued"], mode.usesBatchedTelemetryDelivery ? 10 : 0)
            XCTAssertEqual(
                telemetry["snapshots_materialized"], mode.usesBatchedTelemetryDelivery ? 2 : 0)
            XCTAssertEqual(telemetry["batches_applied"], mode.usesBatchedTelemetryDelivery ? 1 : 0)
            XCTAssertEqual(telemetry["events_applied"], mode.usesBatchedTelemetryDelivery ? 2 : 0)
            XCTAssertEqual(
                telemetry["projection_refreshes"], mode.usesBatchedTelemetryDelivery ? 1 : 0)
            let scale = try XCTUnwrap(snapshot["atomic_chart_scale"] as? [String: UInt64])
            XCTAssertEqual(scale["resolutions"], mode.usesAtomicChartScale ? 2 : 0)
            XCTAssertEqual(scale["scale_changes"], mode.usesAtomicChartScale ? 1 : 0)
            XCTAssertEqual(scale["cache_hits"], mode.usesAtomicChartScale ? 1 : 0)
            assertCounter("invalid_events", in: snapshot, equals: 0)
        }
        try diagnostics.disable()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
    }

    func testBatchedTelemetryRejectsNegativeAndEmptyInputCounts() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeTelemetryBatch)
        diagnostics.batchedTelemetryStateEnqueued(count: -1)
        diagnostics.batchedTelemetrySnapshotMaterialized(count: -1)
        diagnostics.batchedTelemetryBatchApplied(eventCount: 0)
        diagnostics.batchedTelemetryBatchApplied(eventCount: -1)
        let counts = try XCTUnwrap(diagnostics.snapshot()["batched_telemetry"] as? [String: UInt64])
        XCTAssertTrue(counts.values.allSatisfy { $0 == 0 })
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 4)
    }

    func testModesRoundTripAndRejectUnknownValues() throws {
        typealias Mode = PerformanceGraphicsDiagnostics.Mode
        XCTAssertEqual(Mode.normal.rawValue, "normal")
        XCTAssertEqual(Mode.directHost.rawValue, "direct-host")
        XCTAssertEqual(Mode.bitmapLayerDestination.rawValue, "bitmap-layer-destination")
        XCTAssertEqual(Mode.bitmapLayerBGRA.rawValue, "bitmap-layer-bgra")
        XCTAssertEqual(Mode.bitmapLayerNoDecorations.rawValue, "bitmap-layer-no-decorations")
        XCTAssertEqual(Mode.nativeGPUCanvas.rawValue, "native-gpu-canvas")
        XCTAssertEqual(Mode.noBlur.rawValue, "no-blur")
        XCTAssertEqual(Mode.cpuGlow.rawValue, "cpu-glow")
        XCTAssertEqual(Mode.noGradients.rawValue, "no-gradients")
        XCTAssertEqual(Mode.noGradientsOrBlur.rawValue, "no-gradients-or-blur")
        XCTAssertEqual(Mode.runtimeHeldStaticChart.rawValue, "runtime-held-static-chart")
        XCTAssertEqual(Mode.runtimeMetalFullChart.rawValue, "runtime-metal-full-chart")
        XCTAssertEqual(Mode.runtimeMetalCachedChart.rawValue, "runtime-metal-cached-chart")
        XCTAssertEqual(
            Mode.runtimeMetalPrimitiveEffects.rawValue, "runtime-metal-primitive-effects")
        XCTAssertEqual(Mode.runtimeTelemetryBatch.rawValue, "runtime-telemetry-batch")
        XCTAssertEqual(Mode.runtimeAtomicChartScale.rawValue, "runtime-atomic-chart-scale")
        XCTAssertEqual(Mode.runtimeEfficientEffects.rawValue, "runtime-efficient-effects")
        XCTAssertEqual(Mode.allCases.count, 41)
        for mode in Mode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(Mode.self, from: encoded), mode)
        }
        for value in ["", "directHost", "unsupported-mode"] {
            let encoded = try JSONEncoder().encode(value)
            XCTAssertThrowsError(try JSONDecoder().decode(Mode.self, from: encoded))
        }
    }

    func testLayerControlPropertiesAndMetadataDescribeEachIndependentVariable() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        let metadataKeys = [
            "layer_bitmap_pixel_format", "layer_bitmap_color_space", "rail_decorations_enabled",
        ]
        for key in metadataKeys {
            XCTAssertNil(diagnostics.snapshot()[key])
        }
        for mode in PerformanceGraphicsDiagnostics.Mode.allCases {
            try diagnostics.enable(mode: mode)
            let isLayerMode = layerModes.contains(mode)
            XCTAssertEqual(mode.usesBitmapLayerDestination, isLayerMode)
            XCTAssertEqual(mode.usesBGRA, mode == .bitmapLayerBGRA)
            XCTAssertEqual(mode.omitsRailDecorations, mode == .bitmapLayerNoDecorations)
            let snapshot = diagnostics.snapshot()
            if isLayerMode {
                XCTAssertEqual(
                    snapshot["layer_bitmap_pixel_format"] as? String,
                    mode == .bitmapLayerBGRA
                        ? "bgra8-premultiplied-first" : "rgba8-premultiplied-last")
                XCTAssertEqual(snapshot["layer_bitmap_color_space"] as? String, "device-rgb")
                XCTAssertEqual(
                    snapshot["rail_decorations_enabled"] as? Bool,
                    mode != .bitmapLayerNoDecorations)
            } else {
                for key in metadataKeys {
                    XCTAssertNil(snapshot[key], "\(mode.rawValue): \(key)")
                }
            }
        }
        try diagnostics.disable()
        for key in metadataKeys {
            XCTAssertNil(diagnostics.snapshot()[key])
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

    func testGradientSubstitutionsAreCountedOnlyForGradientControlsAndReset() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        diagnostics.recordGradientSubstitution()
        assertCounter("gradient_substitutions", in: diagnostics.snapshot(), equals: 0)
        for mode in PerformanceGraphicsDiagnostics.Mode.allCases {
            try diagnostics.enable(mode: mode)
            let expected = mode == .noGradients || mode == .noGradientsOrBlur
            XCTAssertEqual(mode.omitsGradients, expected)
            assertCounter("gradient_substitutions", in: diagnostics.snapshot(), equals: 0)
            diagnostics.recordGradientSubstitution()
            diagnostics.recordGradientSubstitution()
            assertCounter(
                "gradient_substitutions", in: diagnostics.snapshot(), equals: expected ? 2 : 0)
        }
        try diagnostics.disable()
        diagnostics.recordGradientSubstitution()
        assertCounter("gradient_substitutions", in: diagnostics.snapshot(), equals: 0)
    }

    func testDisabledDiagnosticsIgnoreAllEvents() {
        let diagnostics = PerformanceGraphicsDiagnostics()
        let initial = diagnostics.snapshot()
        XCTAssertEqual(initial["enabled"] as? Bool, false)
        XCTAssertEqual(initial["mode"] as? String, "normal")
        XCTAssertTrue(diagnostics.mode.usesNativeGPUCanvas)
        XCTAssertTrue(diagnostics.mode.usesCoalescedScalarPresentation)
        XCTAssertTrue(diagnostics.mode.usesRetainedTwinkles)
        XCTAssertTrue(diagnostics.mode.usesIncrementalHistoryOrdering)
        XCTAssertTrue(diagnostics.mode.usesOptimizedChartPreparation)
        XCTAssertTrue(diagnostics.mode.usesUnpromisedStreamBodyWrites)
        XCTAssertTrue(diagnostics.mode.usesCanvasFrameClock)
        XCTAssertFalse(diagnostics.mode.usesSharedChartPreparation)
        XCTAssertFalse(diagnostics.mode.usesStableDecorationHosts)
        XCTAssertTrue(diagnostics.mode.usesOrderedChartPublication)
        XCTAssertFalse(diagnostics.mode.usesDirectToolPlot)
        XCTAssertFalse(diagnostics.mode.usesUngroupedNativeCanvas)
        XCTAssertFalse(diagnostics.mode.omitsArrivalEffects)
        XCTAssertFalse(diagnostics.mode.usesHeldStaticChart)
        XCTAssertEqual(diagnostics.mode.chartPublicationIntervalSeconds, 1)
        XCTAssertFalse(diagnostics.mode.usesMetalArrivalBursts)
        XCTAssertNil(initial["chart_publication_interval_seconds"])
        XCTAssertEqual(initial["holds_static_chart_drawing"] as? Bool, false)
        diagnostics.scalarPresentationPublished()
        XCTAssertNil(diagnostics.retainedTwinkleHostCreated())
        diagnostics.retainedTwinkleHostUpdated(
            nil, instances: [AnyHashable(1)], animationsStarted: 4)
        diagnostics.retainedTwinkleHostDestroyed(nil)
        for key in [
            "invalid_events", "live_canvases", "peak_live_canvases",
            "live_renderers", "peak_live_renderers", "current_pixel_area",
            "peak_pixel_area", "current_bitmap_bytes", "peak_bitmap_bytes",
            "gradient_substitutions",
            "layer_bitmap_presentations", "layer_bitmap_failures", "layer_bitmap_native_draws",
            "current_layer_image_bytes", "peak_layer_image_bytes",
            "native_gpu_canvas_draws",
            "scalar_presentation_publications",
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
            diagnostics.nativeGPUCanvasDrawn(id)
            diagnostics.drawSkipped(id)
            diagnostics.bitmapBytes(id, bytes: 4_096)
            diagnostics.layerBitmapPresented(id, imageBytes: 8_192)
            diagnostics.layerBitmapCleared(id)
            diagnostics.recordLayerBitmapFailure()
            diagnostics.recordLayerBitmapNativeDraw()
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

    func testLayerImagesTrackConcurrentOwnershipAndReleaseIndependentlyFromScratchBuffers() throws {
        for mode in layerModes {
            try assertLayerImageOwnership(mode: mode)
        }
    }

    private func assertLayerImageOwnership(mode: PerformanceGraphicsDiagnostics.Mode) throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: mode)
        let chart = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
        let secondChart = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
        let cursor = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
        diagnostics.bitmapBytes(chart, bytes: 256)
        diagnostics.layerBitmapPresented(chart, imageBytes: 1_024)
        diagnostics.layerBitmapPresented(chart, imageBytes: 1_024)
        diagnostics.layerBitmapPresented(secondChart, imageBytes: 512)
        diagnostics.layerBitmapPresented(cursor, imageBytes: 2_048)
        let concurrent = diagnostics.snapshot()
        assertCounter("layer_bitmap_presentations", in: concurrent, equals: 4)
        assertCounter("current_layer_image_bytes", in: concurrent, equals: 3_584)
        assertCounter("peak_layer_image_bytes", in: concurrent, equals: 3_584)
        assertCounter("current_bitmap_bytes", in: concurrent, equals: 256)
        assertCounter(
            "current_layer_image_bytes", in: try role(.staticChart, in: concurrent), equals: 1_536)
        assertCounter(
            "peak_layer_image_bytes", in: try role(.staticChart, in: concurrent), equals: 1_536)

        diagnostics.layerBitmapPresented(chart, imageBytes: 128)
        diagnostics.layerBitmapCleared(secondChart)
        diagnostics.layerBitmapCleared(secondChart)
        let replaced = diagnostics.snapshot()
        assertCounter("layer_bitmap_presentations", in: replaced, equals: 5)
        assertCounter("current_layer_image_bytes", in: replaced, equals: 2_176)
        assertCounter("peak_layer_image_bytes", in: replaced, equals: 3_584)
        assertCounter(
            "current_layer_image_bytes", in: try role(.staticChart, in: replaced), equals: 128)
        assertCounter(
            "peak_layer_image_bytes", in: try role(.staticChart, in: replaced), equals: 1_536)

        diagnostics.canvasDestroyed(chart)
        diagnostics.canvasDestroyed(secondChart)
        let afterCharts = diagnostics.snapshot()
        assertCounter("current_layer_image_bytes", in: afterCharts, equals: 2_048)
        assertCounter("current_bitmap_bytes", in: afterCharts, equals: 0)
        diagnostics.canvasDestroyed(cursor)
        let finished = diagnostics.snapshot()
        assertCounter("current_layer_image_bytes", in: finished, equals: 0)
        assertCounter("peak_layer_image_bytes", in: finished, equals: 3_584)
        assertCounter("invalid_events", in: finished, equals: 0)
        for canvasRole in PerformanceGraphicsDiagnostics.Role.allCases {
            assertCounter(
                "current_layer_image_bytes", in: try role(canvasRole, in: finished), equals: 0)
        }
    }

    func testLayerImageOverflowRejectsTheWholePresentationAndPreservesOwnership() throws {
        for mode in layerModes {
            try assertLayerImageOverflow(mode: mode)
        }
    }

    private func assertLayerImageOverflow(mode: PerformanceGraphicsDiagnostics.Mode) throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: mode)
        let chart = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
        let secondChart = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
        let cursor = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
        diagnostics.layerBitmapPresented(chart, imageBytes: UInt64.max - 5)
        diagnostics.layerBitmapPresented(cursor, imageBytes: 5)
        diagnostics.layerBitmapPresented(secondChart, imageBytes: 1)
        diagnostics.layerBitmapPresented(cursor, imageBytes: 6)
        let rejected = diagnostics.snapshot()
        assertCounter("invalid_events", in: rejected, equals: 2)
        assertCounter("layer_bitmap_presentations", in: rejected, equals: 2)
        assertCounter("current_layer_image_bytes", in: rejected, equals: UInt64.max)
        assertCounter("peak_layer_image_bytes", in: rejected, equals: UInt64.max)
        assertCounter(
            "current_layer_image_bytes", in: try role(.staticChart, in: rejected),
            equals: UInt64.max - 5)
        assertCounter("current_layer_image_bytes", in: try role(.cursor, in: rejected), equals: 5)

        diagnostics.layerBitmapPresented(chart, imageBytes: 0)
        diagnostics.layerBitmapCleared(cursor)
        diagnostics.canvasDestroyed(chart)
        diagnostics.canvasDestroyed(secondChart)
        diagnostics.canvasDestroyed(cursor)
        assertCounter("current_layer_image_bytes", in: diagnostics.snapshot(), equals: 0)
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 2)
    }

    func testLayerDiagnosticEventsAreScopedToTheEnabledCandidateAndReset() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        for mode in PerformanceGraphicsDiagnostics.Mode.allCases {
            try diagnostics.enable(mode: mode)
            let id = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
            diagnostics.layerBitmapPresented(id, imageBytes: 1_024)
            diagnostics.recordLayerBitmapFailure()
            diagnostics.recordLayerBitmapFailure()
            diagnostics.recordLayerBitmapNativeDraw()
            let expected: UInt64 = layerModes.contains(mode) ? 1 : 0
            let snapshot = diagnostics.snapshot()
            assertCounter("layer_bitmap_presentations", in: snapshot, equals: expected)
            assertCounter("layer_bitmap_failures", in: snapshot, equals: expected * 2)
            assertCounter("layer_bitmap_native_draws", in: snapshot, equals: expected)
            assertCounter("current_layer_image_bytes", in: snapshot, equals: expected * 1_024)
            assertCounter("peak_layer_image_bytes", in: snapshot, equals: expected * 1_024)
            assertCounter("invalid_events", in: snapshot, equals: 0)
            diagnostics.canvasDestroyed(id)
        }
        try diagnostics.enable(mode: .bitmapLayerDestination)
        diagnostics.recordLayerBitmapFailure()
        diagnostics.recordLayerBitmapNativeDraw()
        try diagnostics.disable()
        XCTAssertEqual(
            diagnostics.snapshot() as NSDictionary,
            PerformanceGraphicsDiagnostics().snapshot() as NSDictionary)
    }

    func testLayerImageNilIDsAreIgnoredAndUnknownOrDestroyedIDsAreRejected() throws {
        for mode in layerModes {
            try assertLayerImageIDs(mode: mode)
        }
    }

    private func assertLayerImageIDs(mode: PerformanceGraphicsDiagnostics.Mode) throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: mode)
        let id = try XCTUnwrap(diagnostics.canvasCreated(role: .cursor))
        let initial = diagnostics.snapshot()
        diagnostics.layerBitmapPresented(nil, imageBytes: 1_024)
        diagnostics.layerBitmapCleared(nil)
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial as NSDictionary)
        diagnostics.layerBitmapPresented(UInt64.max, imageBytes: 1_024)
        diagnostics.layerBitmapCleared(UInt64.max)
        diagnostics.canvasDestroyed(id)
        diagnostics.layerBitmapPresented(id, imageBytes: 1_024)
        diagnostics.layerBitmapCleared(id)
        let finished = diagnostics.snapshot()
        assertCounter("invalid_events", in: finished, equals: 4)
        assertCounter("layer_bitmap_presentations", in: finished, equals: 0)
        assertCounter("current_layer_image_bytes", in: finished, equals: 0)
        assertCounter("peak_layer_image_bytes", in: finished, equals: 0)
    }

    func testNativeGPUCallbacksAreScopedToTheEnabledModeAndMetadataResets() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        XCTAssertNil(diagnostics.snapshot()["native_gpu_backend"])
        for mode in PerformanceGraphicsDiagnostics.Mode.allCases {
            try diagnostics.enable(mode: mode)
            let id = try XCTUnwrap(diagnostics.canvasCreated(role: .staticChart))
            diagnostics.nativeGPUCanvasDrawn(id)
            diagnostics.nativeGPUCanvasDrawn(id)
            let snapshot = diagnostics.snapshot()
            let expected: UInt64 = mode.usesNativeGPUCanvas ? 2 : 0
            assertCounter("native_gpu_canvas_draws", in: snapshot, equals: expected)
            assertCounter("draws", in: try role(.staticChart, in: snapshot), equals: expected)
            assertCounter("invalid_events", in: snapshot, equals: 0)
            if mode.usesNativeGPUCanvas {
                XCTAssertEqual(
                    snapshot["native_gpu_backend"] as? String,
                    mode.usesUngroupedNativeCanvas
                        ? "swiftui-canvas" : "swiftui-canvas-drawing-group")
                XCTAssertEqual(
                    snapshot["scalar_presentation_coalesced"] as? Bool,
                    mode.usesCoalescedScalarPresentation)
                XCTAssertEqual(
                    snapshot["retained_twinkles_enabled"] as? Bool,
                    mode.usesRetainedTwinkles)
                XCTAssertEqual(
                    snapshot["incremental_history_ordering"] as? Bool,
                    mode.usesIncrementalHistoryOrdering)
                XCTAssertEqual(
                    snapshot["optimized_chart_preparation"] as? Bool,
                    mode.usesOptimizedChartPreparation)
                XCTAssertEqual(
                    snapshot["lifecycle_effects_enabled"] as? Bool,
                    !mode.omitsLifecycleEffects)
                XCTAssertEqual(
                    snapshot["shared_chart_preparation"] as? Bool,
                    mode.usesSharedChartPreparation)
                XCTAssertEqual(
                    snapshot["stable_decoration_hosts"] as? Bool,
                    mode.usesStableDecorationHosts)
                XCTAssertEqual(
                    snapshot["unpromised_stream_body_writes"] as? Bool,
                    mode.usesUnpromisedStreamBodyWrites)
                XCTAssertEqual(
                    snapshot["canvas_frame_clock"] as? Bool,
                    mode.usesCanvasFrameClock)
                XCTAssertEqual(
                    snapshot["ordered_chart_publication"] as? Bool,
                    mode.usesOrderedChartPublication)
                XCTAssertEqual(
                    snapshot["direct_tool_plot"] as? Bool,
                    mode.usesDirectToolPlot)
                XCTAssertEqual(
                    snapshot["ungrouped_native_canvas"] as? Bool,
                    mode.usesUngroupedNativeCanvas)
                XCTAssertEqual(
                    snapshot["arrival_effects_enabled"] as? Bool,
                    !mode.omitsLifecycleEffects && !mode.omitsArrivalEffects)
                XCTAssertEqual(
                    snapshot["compact_tool_paths_enabled"] as? Bool,
                    mode.usesCompactToolPaths)
                XCTAssertEqual(
                    snapshot["deferred_tool_geometry_enabled"] as? Bool,
                    mode.usesDeferredToolGeometry)
                XCTAssertEqual(
                    snapshot["holds_static_chart_drawing"] as? Bool,
                    mode == .runtimeHeldStaticChart)
                XCTAssertEqual(
                    snapshot["metal_arrival_bursts_enabled"] as? Bool,
                    mode == .runtimeMetalArrivalBursts)
                XCTAssertEqual(
                    snapshot["arrival_backend"] as? String,
                    mode.usesMetalPrimitiveEffects
                        ? "metal-primitive-effects"
                        : (mode == .runtimeMetalArrivalBursts ? "metal-shader" : "canvas"))
                XCTAssertEqual(
                    snapshot["chart_publication_interval_seconds"] as? Double,
                    mode == .runtimeDeferredToolGeometry2Hz ? 0.5 : 1)
            } else if mode.usesMetalFullChart {
                XCTAssertEqual(snapshot["native_gpu_backend"] as? String, "metal-persistent-chart")
                XCTAssertEqual(snapshot["arrival_backend"] as? String, "metal-full-chart-shader")
                XCTAssertEqual(snapshot["canvas_frame_clock"] as? Bool, false)
                XCTAssertEqual(
                    snapshot["retained_twinkles_enabled"] as? Bool, mode == .runtimeMetalCachedChart
                )
                XCTAssertEqual(
                    snapshot["metal_static_cache_enabled"] as? Bool,
                    mode == .runtimeMetalCachedChart)
            } else {
                XCTAssertNil(snapshot["native_gpu_backend"])
                XCTAssertNil(snapshot["chart_publication_interval_seconds"])
                XCTAssertNil(snapshot["metal_arrival_bursts_enabled"])
                XCTAssertEqual(snapshot["holds_static_chart_drawing"] as? Bool, false)
                XCTAssertNil(snapshot["arrival_backend"])
            }
            diagnostics.canvasDestroyed(id)
        }
        try diagnostics.enable(mode: .nativeGPUCanvas)
        assertCounter("native_gpu_canvas_draws", in: diagnostics.snapshot(), equals: 0)
        try diagnostics.disable()
        XCTAssertEqual(
            diagnostics.snapshot() as NSDictionary,
            PerformanceGraphicsDiagnostics().snapshot() as NSDictionary)
    }

    func testNativeGPUCallbacksRequireLiveOwnersAndReconcileRolesAcrossTheirLifetimes() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .nativeGPUCanvas)
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

        try diagnostics.enable(mode: .nativeGPUCanvas)
        diagnostics.nativeGPUCanvasDrawn(replacement)
        assertCounter("native_gpu_canvas_draws", in: diagnostics.snapshot(), equals: 0)
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 1)
    }

    func testNativeOptimizationControlsChangeOnlyTheirNamedFeatures() {
        typealias Mode = PerformanceGraphicsDiagnostics.Mode
        let next: [Mode] = [
            .runtimeSharedPreparation, .runtimeStableDecorationHosts, .runtimeStreamWrites,
            .runtimeNextOptimized, .runtimeCanvasClock, .runtimeStreamCanvasClock,
            .runtimeOrderedPublication, .runtimeDirectToolPlot, .runtimeUngroupedCanvas,
            .runtimeNoArrivalEffects, .runtimeCompactToolPaths, .runtimeDeferredToolGeometry,
            .runtimeDeferredToolGeometry2Hz, .runtimeMetalArrivalBursts, .runtimeMetalFullChart,
            .runtimeMetalCachedChart, .runtimeMetalPrimitiveEffects, .runtimeTelemetryBatch,
            .runtimeAtomicChartScale, .runtimeEfficientEffects, .runtimeHeldStaticChart,
        ]
        let runtime: [Mode] =
            [
                .runtimeNoLifecycle, .runtimeHistoryOrder, .runtimeChartPreparation,
                .runtimeOptimized,
            ] + next
        for mode in Mode.allCases {
            XCTAssertEqual(
                mode.usesNativeGPUCanvas,
                ([
                    .normal, .nativeGPUCanvas, .nativeGPUCoalescedScalars,
                    .nativeGPURetainedTwinkles, .nativeGPUOptimized,
                ] + runtime).contains(mode)
                    && ![.runtimeMetalFullChart, .runtimeMetalCachedChart].contains(mode))
            XCTAssertEqual(
                mode.usesCoalescedScalarPresentation,
                ([.normal, .nativeGPUCoalescedScalars, .nativeGPUOptimized] + runtime).contains(
                    mode))
            XCTAssertEqual(
                mode.usesRetainedTwinkles,
                ([.normal, .nativeGPURetainedTwinkles, .nativeGPUOptimized] + runtime).contains(
                    mode) && mode != .runtimeMetalFullChart)
            XCTAssertEqual(
                mode.usesIncrementalHistoryOrdering,
                ([.normal, .runtimeHistoryOrder, .runtimeOptimized, .runtimeNoLifecycle] + next)
                    .contains(mode))
            XCTAssertEqual(
                mode.usesOptimizedChartPreparation,
                ([.normal, .runtimeChartPreparation, .runtimeOptimized, .runtimeNoLifecycle] + next)
                    .contains(mode))
            XCTAssertEqual(mode.omitsLifecycleEffects, mode == .runtimeNoLifecycle)
            XCTAssertEqual(
                mode.usesSharedChartPreparation,
                [.runtimeSharedPreparation, .runtimeNextOptimized].contains(mode))
            XCTAssertEqual(
                mode.usesStableDecorationHosts,
                [.runtimeStableDecorationHosts, .runtimeNextOptimized].contains(mode))
            XCTAssertEqual(
                mode.usesUnpromisedStreamBodyWrites,
                [
                    .normal, .runtimeStreamWrites, .runtimeNextOptimized, .runtimeStreamCanvasClock,
                    .runtimeOrderedPublication, .runtimeDirectToolPlot, .runtimeUngroupedCanvas,
                    .runtimeNoArrivalEffects, .runtimeCompactToolPaths,
                    .runtimeDeferredToolGeometry,
                    .runtimeDeferredToolGeometry2Hz, .runtimeMetalArrivalBursts,
                    .runtimeMetalFullChart, .runtimeMetalCachedChart, .runtimeMetalPrimitiveEffects,
                    .runtimeTelemetryBatch,
                    .runtimeAtomicChartScale, .runtimeEfficientEffects, .runtimeHeldStaticChart,
                ].contains(mode))
            XCTAssertEqual(
                mode.usesCanvasFrameClock,
                [
                    .normal, .runtimeCanvasClock, .runtimeStreamCanvasClock,
                    .runtimeOrderedPublication, .runtimeDirectToolPlot, .runtimeUngroupedCanvas,
                    .runtimeNoArrivalEffects, .runtimeCompactToolPaths,
                    .runtimeDeferredToolGeometry,
                    .runtimeDeferredToolGeometry2Hz, .runtimeMetalArrivalBursts,
                    .runtimeMetalPrimitiveEffects, .runtimeTelemetryBatch,
                    .runtimeAtomicChartScale, .runtimeEfficientEffects, .runtimeHeldStaticChart,
                ].contains(mode))
            XCTAssertEqual(
                mode.usesOrderedChartPublication,
                [
                    .normal, .runtimeSharedPreparation, .runtimeNextOptimized,
                    .runtimeOrderedPublication, .runtimeDirectToolPlot, .runtimeUngroupedCanvas,
                    .runtimeNoArrivalEffects, .runtimeCompactToolPaths,
                    .runtimeDeferredToolGeometry,
                    .runtimeDeferredToolGeometry2Hz, .runtimeMetalArrivalBursts,
                    .runtimeMetalFullChart, .runtimeMetalCachedChart, .runtimeMetalPrimitiveEffects,
                    .runtimeTelemetryBatch,
                    .runtimeAtomicChartScale, .runtimeEfficientEffects, .runtimeHeldStaticChart,
                ].contains(mode))
            XCTAssertEqual(mode.usesDirectToolPlot, mode == .runtimeDirectToolPlot)
            XCTAssertEqual(mode.usesUngroupedNativeCanvas, mode == .runtimeUngroupedCanvas)
            XCTAssertEqual(mode.omitsArrivalEffects, mode == .runtimeNoArrivalEffects)
            XCTAssertEqual(mode.usesHeldStaticChart, mode == .runtimeHeldStaticChart)
            XCTAssertEqual(mode.usesCompactToolPaths, mode == .runtimeCompactToolPaths)
            XCTAssertEqual(
                mode.usesDeferredToolGeometry,
                [.runtimeDeferredToolGeometry, .runtimeDeferredToolGeometry2Hz].contains(mode))
            XCTAssertEqual(mode.usesMetalArrivalBursts, mode == .runtimeMetalArrivalBursts)
            XCTAssertEqual(
                mode.usesMetalFullChart,
                [.runtimeMetalFullChart, .runtimeMetalCachedChart].contains(mode))
            XCTAssertEqual(mode.cachesMetalStaticChart, mode == .runtimeMetalCachedChart)
            XCTAssertEqual(
                mode.usesMetalPrimitiveEffects,
                [.runtimeMetalPrimitiveEffects, .runtimeEfficientEffects].contains(mode))
            XCTAssertEqual(
                mode.usesBatchedTelemetryDelivery,
                [.runtimeTelemetryBatch, .runtimeEfficientEffects].contains(mode))
            XCTAssertEqual(
                mode.usesAtomicChartScale,
                [.runtimeAtomicChartScale, .runtimeEfficientEffects].contains(mode))
            XCTAssertEqual(
                mode.chartPublicationIntervalSeconds,
                mode == .runtimeDeferredToolGeometry2Hz ? 0.5 : 1)
        }
    }

    func testHeldStaticDrawingCountersAreScopedToTheirDiagnosticAndReset() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        let initial = diagnostics.snapshot() as NSDictionary
        diagnostics.staticChartDrawingRequested(applied: true, reset: false)
        diagnostics.staticChartDrawingRequested(applied: false, reset: true)
        diagnostics.staticChartDrawingReset()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)

        for mode in PerformanceGraphicsDiagnostics.Mode.allCases {
            try diagnostics.enable(mode: mode)
            diagnostics.staticChartDrawingRequested(applied: true, reset: false)
            diagnostics.staticChartDrawingRequested(applied: false, reset: false)
            diagnostics.staticChartDrawingRequested(applied: false, reset: false)
            diagnostics.staticChartDrawingRequested(applied: true, reset: true)
            diagnostics.staticChartDrawingReset()
            let snapshot = diagnostics.snapshot()
            let expected: UInt64 = mode == .runtimeHeldStaticChart ? 1 : 0
            let chart = try role(.staticChart, in: snapshot)
            assertCounter("drawing_update_attempts", in: chart, equals: expected * 4)
            assertCounter("drawing_updates_applied", in: chart, equals: expected * 2)
            assertCounter("drawing_updates_held", in: chart, equals: expected * 2)
            assertCounter("drawing_hold_resets", in: chart, equals: expected * 2)
            for canvasRole in PerformanceGraphicsDiagnostics.Role.allCases
            where canvasRole != .staticChart {
                let counters = try role(canvasRole, in: snapshot)
                for key in [
                    "drawing_update_attempts", "drawing_updates_applied",
                    "drawing_updates_held", "drawing_hold_resets",
                ] {
                    assertCounter(key, in: counters, equals: 0)
                }
            }
            assertCounter("live_canvases", in: snapshot, equals: 0)
            assertCounter("native_gpu_canvas_draws", in: snapshot, equals: 0)
            assertCounter("invalid_events", in: snapshot, equals: 0)
        }
        try diagnostics.disable()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
    }

    func testRetainedTwinklesAccountForReplacementAndReleaseAcrossHosts() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .nativeGPURetainedTwinkles)
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
        try diagnostics.enable(mode: .nativeGPUOptimized)
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

    func testRetainedTwinkleEvidenceIsScopedToRequestedBackend() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        for mode in PerformanceGraphicsDiagnostics.Mode.allCases {
            try diagnostics.enable(mode: mode)
            let host = diagnostics.retainedTwinkleHostCreated()
            XCTAssertEqual(host != nil, mode.usesRetainedTwinkles)
            diagnostics.retainedTwinkleHostUpdated(host, instances: [1], animationsStarted: 4)
            diagnostics.retainedTwinkleHostDestroyed(host)
            let snapshot = diagnostics.snapshot()
            XCTAssertEqual(
                snapshot["retained_twinkle_backend"] as? String,
                mode.usesRetainedTwinkles ? "core-animation-shape-layers" : nil)
            let counters = try XCTUnwrap(snapshot["retained_twinkles"] as? [String: UInt64])
            XCTAssertEqual(counters["animation_starts"], mode.usesRetainedTwinkles ? 4 : 0)
            assertCounter("invalid_events", in: snapshot, equals: 0)
        }
    }

    func testScalarPublicationsAreScopedAndReset() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        diagnostics.scalarPresentationPublished()
        assertCounter("scalar_presentation_publications", in: diagnostics.snapshot(), equals: 0)
        for mode in PerformanceGraphicsDiagnostics.Mode.allCases {
            try diagnostics.enable(mode: mode)
            diagnostics.scalarPresentationPublished()
            diagnostics.scalarPresentationPublished()
            assertCounter(
                "scalar_presentation_publications", in: diagnostics.snapshot(),
                equals: mode.usesCoalescedScalarPresentation ? 2 : 0)
        }
        try diagnostics.disable()
        assertCounter("scalar_presentation_publications", in: diagnostics.snapshot(), equals: 0)
    }

    func testFullMetalChartCountersRecordExecutedWorkAndDrainHostResources() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        XCTAssertNil(diagnostics.metalFullChartHostCreated())
        diagnostics.metalFullChartFailure()
        try diagnostics.enable(mode: .runtimeMetalFullChart)
        let first = try XCTUnwrap(diagnostics.metalFullChartHostCreated())
        let second = try XCTUnwrap(diagnostics.metalFullChartHostCreated())
        diagnostics.metalFullChartGeometryUploaded(first, bytes: 100)
        diagnostics.metalFullChartGeometryUploaded(second, bytes: 200)
        diagnostics.metalFullChartGeometryUploaded(first, bytes: 50)
        XCTAssertTrue(diagnostics.metalFullChartBuffersRetained(first, bytes: 75))
        diagnostics.metalFullChartFrameSubmitted(
            first, staticChart: true, arrival: true, completion: false, twinkle: true)
        diagnostics.metalFullChartFrameSubmitted(
            second, staticChart: true, arrival: false, completion: true, twinkle: false)
        diagnostics.metalFullChartFrameSkipped(first)
        XCTAssertThrowsError(try diagnostics.disable())
        var counts = try XCTUnwrap(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64])
        XCTAssertEqual(counts["geometry_uploads"], 3)
        XCTAssertEqual(counts["submissions"], 2)
        XCTAssertEqual(counts["static_frames"], 2)
        XCTAssertEqual(counts["arrival_frames"], 1)
        XCTAssertEqual(counts["completion_frames"], 1)
        XCTAssertEqual(counts["twinkle_frames"], 1)
        XCTAssertEqual(counts["frames_skipped"], 1)
        XCTAssertEqual(counts["current_buffer_bytes"], 275)
        XCTAssertEqual(counts["peak_buffer_bytes"], 300)
        diagnostics.metalFullChartHostDestroyed(first)
        diagnostics.metalFullChartHostDestroyed(second)
        counts = try XCTUnwrap(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64])
        XCTAssertEqual(counts["live_hosts"], 0)
        XCTAssertEqual(counts["current_buffer_bytes"], 0)
        XCTAssertEqual(counts["hosts_created"], counts["hosts_destroyed"])
        XCTAssertEqual(counts["peak_hosts"], 2)
        try diagnostics.disable()
        XCTAssertEqual(
            diagnostics.snapshot() as NSDictionary,
            PerformanceGraphicsDiagnostics().snapshot() as NSDictionary)
    }

    func testFullMetalChartInvalidOwnersAndAllocationOverflowCannotFabricateWork() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeMetalFullChart)
        let first = try XCTUnwrap(diagnostics.metalFullChartHostCreated())
        let second = try XCTUnwrap(diagnostics.metalFullChartHostCreated())
        diagnostics.metalFullChartGeometryUploaded(first, bytes: .max)
        let prior = diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64]
        diagnostics.metalFullChartGeometryUploaded(second, bytes: 1)
        diagnostics.metalFullChartFrameSubmitted(
            .max, staticChart: true, arrival: true, completion: true, twinkle: true)
        diagnostics.metalFullChartFrameSkipped(.max)
        XCTAssertEqual(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64], prior)
        diagnostics.metalFullChartHostDestroyed(first)
        diagnostics.metalFullChartHostDestroyed(second)
        diagnostics.metalFullChartHostDestroyed(second)
        diagnostics.metalFullChartFailure()
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 4)
        XCTAssertEqual(
            (diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64])?["failures"], 1)
    }

    func testCachedMetalTexturesHaveIndependentLifecycleAndResetWithoutInventingDraws() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeMetalCachedChart)
        let first = try XCTUnwrap(diagnostics.metalFullChartHostCreated())
        let second = try XCTUnwrap(diagnostics.metalFullChartHostCreated())
        diagnostics.metalFullChartGeometryUploaded(first, bytes: 100)
        diagnostics.metalFullChartGeometryUploaded(second, bytes: 200)
        diagnostics.metalFullChartStaticCacheUsed(first, rasterized: true, bytes: 4_096)
        diagnostics.metalFullChartStaticCacheUsed(second, rasterized: true, bytes: 8_192)
        diagnostics.metalFullChartStaticCacheUsed(first, rasterized: false, bytes: 2_048)
        diagnostics.metalFullChartEffectClockTick(first)
        diagnostics.metalFullChartEffectClockTick(second)
        var counts = try XCTUnwrap(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64])
        XCTAssertEqual(counts["static_rasterizations"], 2)
        XCTAssertEqual(counts["static_cache_composites"], 3)
        XCTAssertEqual(counts["effect_clock_ticks"], 2)
        XCTAssertEqual(counts["current_texture_bytes"], 10_240)
        XCTAssertEqual(counts["peak_texture_bytes"], 12_288)
        XCTAssertEqual(counts["current_buffer_bytes"], 300)
        XCTAssertEqual(counts["geometry_uploads"], 2)
        XCTAssertEqual(counts["submissions"], 0)
        XCTAssertEqual(counts["static_frames"], 0)
        XCTAssertThrowsError(try diagnostics.enable(mode: .normal))

        // A hidden host may release its cache without encoding another frame.
        XCTAssertTrue(diagnostics.metalFullChartTexturesRetained(first, bytes: 0))
        counts = try XCTUnwrap(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64])
        XCTAssertEqual(counts["current_texture_bytes"], 8_192)
        XCTAssertEqual(counts["current_buffer_bytes"], 300)
        XCTAssertEqual(counts["static_cache_composites"], 3)
        XCTAssertEqual(counts["static_rasterizations"], 2)
        diagnostics.metalFullChartHostDestroyed(second)
        counts = try XCTUnwrap(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64])
        XCTAssertEqual(counts["current_texture_bytes"], 0)
        XCTAssertEqual(counts["current_buffer_bytes"], 100)
        XCTAssertEqual(counts["peak_texture_bytes"], 12_288)
        XCTAssertThrowsError(try diagnostics.disable())
        diagnostics.metalFullChartHostDestroyed(first)
        try diagnostics.enable(mode: .runtimeMetalCachedChart)
        counts = try XCTUnwrap(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64])
        XCTAssertTrue(counts.values.allSatisfy { $0 == 0 })
        try diagnostics.disable()
        XCTAssertEqual(
            diagnostics.snapshot() as NSDictionary,
            PerformanceGraphicsDiagnostics().snapshot() as NSDictionary)
    }

    func testCachedMetalInvalidOwnersAndTextureOverflowCannotFabricateWorkOrCorruptBuffers() throws
    {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeMetalCachedChart)
        let first = try XCTUnwrap(diagnostics.metalFullChartHostCreated())
        let second = try XCTUnwrap(diagnostics.metalFullChartHostCreated())
        diagnostics.metalFullChartGeometryUploaded(first, bytes: 123)
        diagnostics.metalFullChartStaticCacheUsed(first, rasterized: true, bytes: .max)
        let prior = diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64]
        diagnostics.metalFullChartStaticCacheUsed(second, rasterized: true, bytes: 1)
        diagnostics.metalFullChartStaticCacheUsed(.max, rasterized: true, bytes: 1)
        XCTAssertFalse(diagnostics.metalFullChartTexturesRetained(.max, bytes: 1))
        diagnostics.metalFullChartEffectClockTick(.max)
        XCTAssertEqual(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64], prior)
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 4)

        // Replacing an allocation subtracts this host's old size first, so a
        // retained maximum allocation does not falsely overflow itself.
        XCTAssertTrue(diagnostics.metalFullChartTexturesRetained(first, bytes: .max))
        diagnostics.metalFullChartHostDestroyed(first)
        diagnostics.metalFullChartHostDestroyed(second)
        let drained = diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64]
        XCTAssertEqual(drained?["current_texture_bytes"], 0)
        XCTAssertEqual(drained?["current_buffer_bytes"], 0)
        XCTAssertEqual(drained?["peak_texture_bytes"], UInt64.max)
        XCTAssertEqual(drained?["static_rasterizations"], 1)
        XCTAssertEqual(drained?["static_cache_composites"], 1)
        XCTAssertFalse(diagnostics.metalFullChartTexturesRetained(first, bytes: 0))
        diagnostics.metalFullChartStaticCacheUsed(second, rasterized: false, bytes: 0)
        diagnostics.metalFullChartEffectClockTick(first)
        XCTAssertEqual(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64], drained)
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 7)
    }

    func testCachedMetalCountersAreOptInAndNilHostEventsAreIgnored() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        let disabled = diagnostics.snapshot() as NSDictionary
        diagnostics.metalFullChartStaticCacheUsed(1, rasterized: true, bytes: 4_096)
        XCTAssertFalse(diagnostics.metalFullChartTexturesRetained(1, bytes: 4_096))
        diagnostics.metalFullChartEffectClockTick(1)
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, disabled)
        XCTAssertEqual(diagnostics.snapshot()["metal_static_cache_enabled"] as? Bool, false)

        for mode in PerformanceGraphicsDiagnostics.Mode.allCases {
            try diagnostics.enable(mode: mode)
            let host = diagnostics.metalFullChartHostCreated()
            let beforeNil = diagnostics.snapshot() as NSDictionary
            diagnostics.metalFullChartStaticCacheUsed(nil, rasterized: true, bytes: 4_096)
            XCTAssertFalse(diagnostics.metalFullChartTexturesRetained(nil, bytes: 4_096))
            diagnostics.metalFullChartEffectClockTick(nil)
            XCTAssertEqual(diagnostics.snapshot() as NSDictionary, beforeNil)
            // A non-Metal mode must ignore even a non-nil, unregistered token.
            diagnostics.metalFullChartStaticCacheUsed(host ?? 123, rasterized: true, bytes: 4_096)
            diagnostics.metalFullChartEffectClockTick(host ?? 123)
            let expected: UInt64 = mode == .runtimeMetalCachedChart ? 1 : 0
            let snapshot = diagnostics.snapshot()
            let counts = try XCTUnwrap(snapshot["metal_full_chart"] as? [String: UInt64])
            XCTAssertEqual(snapshot["metal_static_cache_enabled"] as? Bool, expected == 1)
            XCTAssertEqual(counts["static_rasterizations"], expected)
            XCTAssertEqual(counts["static_cache_composites"], expected)
            XCTAssertEqual(counts["effect_clock_ticks"], expected)
            XCTAssertEqual(counts["current_texture_bytes"], expected * 4_096)
            XCTAssertEqual(counts["peak_texture_bytes"], expected * 4_096)
            assertCounter("invalid_events", in: snapshot, equals: 0)
            diagnostics.metalFullChartHostDestroyed(host)
        }
        try diagnostics.disable()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, disabled)
    }

    func testCachedMetalSceneRevisionsRecordOverlappingCausesAndUnclassifiedWork() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeMetalCachedChart)
        diagnostics.metalFullChartSceneRevised(
            initial: true, publication: false, scale: false, layout: false, appearance: false,
            rails: false)
        diagnostics.metalFullChartSceneRevised(
            initial: false, publication: true, scale: true, layout: true, appearance: true,
            rails: true)
        diagnostics.metalFullChartSceneRevised(
            initial: false, publication: false, scale: false, layout: false, appearance: false,
            rails: false)
        var counts = try XCTUnwrap(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64])
        XCTAssertEqual(counts["static_scene_revisions"], 3)
        for key in [
            "scene_initial_revisions", "scene_publication_revisions", "scene_scale_revisions",
            "scene_layout_revisions", "scene_appearance_revisions", "scene_rail_revisions",
            "scene_unclassified_revisions",
        ] {
            XCTAssertEqual(counts[key], 1, key)
        }
        XCTAssertEqual(counts["static_rasterizations"], 0)
        XCTAssertEqual(counts["static_surface_invalidations"], 0)
        let host = try XCTUnwrap(diagnostics.metalFullChartHostCreated())
        diagnostics.metalFullChartSurfaceInvalidated(host)
        diagnostics.metalFullChartSurfaceInvalidated(host)
        diagnostics.metalFullChartSurfaceInvalidated(nil)
        diagnostics.metalFullChartSurfaceInvalidated(.max)
        diagnostics.metalFullChartHostDestroyed(host)
        diagnostics.metalFullChartSurfaceInvalidated(host)
        counts = try XCTUnwrap(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64])
        XCTAssertEqual(counts["static_surface_invalidations"], 2)
        XCTAssertEqual(counts["static_scene_revisions"], 3)
        XCTAssertEqual(counts["static_rasterizations"], 0)
        assertCounter("invalid_events", in: diagnostics.snapshot(), equals: 2)
        try diagnostics.enable(mode: .runtimeMetalCachedChart)
        counts = try XCTUnwrap(diagnostics.snapshot()["metal_full_chart"] as? [String: UInt64])
        XCTAssertTrue(counts.values.allSatisfy { $0 == 0 })
    }

    func testCachedMetalInvalidationDiagnosticsAreIgnoredWhenDisabledOrInOtherModes() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        let disabled = diagnostics.snapshot() as NSDictionary
        diagnostics.metalFullChartSceneRevised(
            initial: true, publication: true, scale: true, layout: true, appearance: true,
            rails: true)
        diagnostics.metalFullChartSurfaceInvalidated(123)
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, disabled)
        for mode in PerformanceGraphicsDiagnostics.Mode.allCases
        where mode != .runtimeMetalCachedChart {
            try diagnostics.enable(mode: mode)
            let host = diagnostics.metalFullChartHostCreated()
            let before = diagnostics.snapshot() as NSDictionary
            diagnostics.metalFullChartSceneRevised(
                initial: true, publication: true, scale: true, layout: true, appearance: true,
                rails: true)
            diagnostics.metalFullChartSceneRevised(
                initial: false, publication: false, scale: false, layout: false, appearance: false,
                rails: false)
            diagnostics.metalFullChartSurfaceInvalidated(host ?? 123)
            XCTAssertEqual(diagnostics.snapshot() as NSDictionary, before, mode.rawValue)
            diagnostics.metalFullChartHostDestroyed(host)
        }
        try diagnostics.disable()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, disabled)
    }

    private var layerModes: [PerformanceGraphicsDiagnostics.Mode] {
        [.bitmapLayerDestination, .bitmapLayerBGRA, .bitmapLayerNoDecorations]
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
