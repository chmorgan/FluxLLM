import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class PerformanceReuseGraphicsDiagnosticsTests: XCTestCase {
    func testEachCacheModeChangesOnlyItsApprovedFlags() throws {
        typealias Mode = PerformanceGraphicsDiagnostics.Mode
        let modes: [Mode] = [
            .runtimeCompletedLaneCache, .runtimeCachedRailGeometry, .runtimeReuseCaches,
        ]
        for mode in modes {
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
            XCTAssertFalse(mode.usesMetalArrivalBursts)
            XCTAssertFalse(mode.usesMetalFullChart)
            XCTAssertFalse(mode.usesMetalPrimitiveEffects)
            XCTAssertFalse(mode.usesBatchedTelemetryDelivery)
            XCTAssertFalse(mode.usesAtomicChartScale)
            XCTAssertFalse(mode.omitsLifecycleEffects)
            XCTAssertFalse(mode.omitsArrivalEffects)
            XCTAssertFalse(mode.usesHeldStaticChart)
            XCTAssertEqual(mode.usesCompletedLaneCache, mode != .runtimeCachedRailGeometry)
            XCTAssertEqual(mode.usesCachedRailGeometry, mode != .runtimeCompletedLaneCache)
            XCTAssertEqual(
                try JSONDecoder().decode(Mode.self, from: JSONEncoder().encode(mode)), mode)
        }
        XCTAssertEqual(Mode.runtimeCompletedLaneCache.rawValue, "runtime-completed-lane-cache")
        XCTAssertEqual(Mode.runtimeCachedRailGeometry.rawValue, "runtime-cached-rail-geometry")
        XCTAssertEqual(Mode.runtimeReuseCaches.rawValue, "runtime-reuse-caches")
        XCTAssertFalse(Mode.normal.usesCompletedLaneCache)
        XCTAssertFalse(Mode.normal.usesCachedRailGeometry)
    }

    func testCountersRemainDisabledOutsideTheirOwnCandidate() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        let owner = UUID()
        let initial = diagnostics.snapshot() as NSDictionary
        recordWork(diagnostics, owner: owner)
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
        for mode in PerformanceGraphicsDiagnostics.Mode.allCases {
            try diagnostics.enable(mode: mode)
            recordWork(diagnostics, owner: owner)
            let snapshot = diagnostics.snapshot()
            XCTAssertEqual(
                snapshot["completed_lane_cache_enabled"] as? Bool, mode.usesCompletedLaneCache)
            XCTAssertEqual(
                snapshot["rail_geometry_cache_enabled"] as? Bool, mode.usesCachedRailGeometry)
            XCTAssertEqual(
                snapshot["rail_geometry_cache_used"] as? Bool, mode.usesCachedRailGeometry)
            let lanes = try XCTUnwrap(snapshot["completed_lane_cache"] as? [String: UInt64])
            let geometry = try XCTUnwrap(snapshot["rail_geometry_cache"] as? [String: UInt64])
            XCTAssertEqual(lanes["builds"], mode.usesCompletedLaneCache ? 2 : 0)
            XCTAssertEqual(lanes["hits"], mode.usesCompletedLaneCache ? 7 : 0)
            XCTAssertEqual(lanes["visited_records"], mode.usesCompletedLaneCache ? 480 : 0)
            XCTAssertEqual(lanes["current_entries"], mode.usesCompletedLaneCache ? 240 : 0)
            XCTAssertEqual(lanes["peak_entries"], mode.usesCompletedLaneCache ? 240 : 0)
            XCTAssertEqual(geometry["builds"], mode.usesCachedRailGeometry ? 1 : 0)
            XCTAssertEqual(geometry["hits"], mode.usesCachedRailGeometry ? 1 : 0)
            XCTAssertEqual(geometry["current_entries"], mode.usesCachedRailGeometry ? 2 : 0)
            XCTAssertEqual(geometry["peak_entries"], mode.usesCachedRailGeometry ? 2 : 0)
            XCTAssertEqual(geometry["current_caches"], mode.usesCachedRailGeometry ? 1 : 0)
            XCTAssertEqual(geometry["peak_caches"], mode.usesCachedRailGeometry ? 1 : 0)
            XCTAssertEqual(geometry["max_entries_per_cache"], 24)
            XCTAssertEqual(snapshot["invalid_events"] as? UInt64, 0)
        }
        try diagnostics.disable()
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
    }

    func testLaneCleanupPreservesCumulativeWorkAndPeak() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeCompletedLaneCache)
        diagnostics.completedLaneCachePrepared(
            builds: 1, hits: 3, visitedRecords: 240, entries: 240)
        diagnostics.completedLaneCachePrepared(
            builds: 2, hits: 4, visitedRecords: 360, entries: 120)
        diagnostics.completedLaneCachePrepared(builds: 2, hits: 4, visitedRecords: 360, entries: 0)
        let counts = try XCTUnwrap(
            diagnostics.snapshot()["completed_lane_cache"] as? [String: UInt64])
        XCTAssertEqual(
            counts,
            [
                "builds": 2, "hits": 4, "visited_records": 360, "current_entries": 0,
                "peak_entries": 240,
            ])
    }

    func testLaneNegativeOversizedOrRegressingInputCannotChangeValidSnapshot() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeCompletedLaneCache)
        diagnostics.completedLaneCachePrepared(
            builds: 2, hits: 3, visitedRecords: 240, entries: 240)
        let previous = diagnostics.snapshot()["completed_lane_cache"] as? [String: UInt64]
        for value in [
            (UInt64(1), UInt64(3), UInt64(240), 240), (2, 2, 240, 240), (2, 3, 239, 240),
            (2, 3, 240, -1), (2, 3, 240, 20_001),
        ] {
            diagnostics.completedLaneCachePrepared(
                builds: value.0, hits: value.1, visitedRecords: value.2, entries: value.3)
            XCTAssertEqual(
                diagnostics.snapshot()["completed_lane_cache"] as? [String: UInt64], previous)
        }
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 5)
    }

    func testGeometryCapacityAndCleanupAreBounded() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        let owner = UUID()
        try diagnostics.enable(mode: .runtimeCachedRailGeometry)
        diagnostics.recordRailGeometryCacheBuild(owner: owner, entries: 24)
        diagnostics.recordRailGeometryCacheHit(owner: owner)
        diagnostics.recordRailGeometryCacheEntries(owner: owner, 3)
        diagnostics.recordRailGeometryCacheEntries(owner: owner, 0)
        let counts = try XCTUnwrap(
            diagnostics.snapshot()["rail_geometry_cache"] as? [String: UInt64])
        XCTAssertEqual(
            counts,
            [
                "builds": 1, "hits": 1, "current_entries": 0, "peak_entries": 24,
                "current_caches": 0, "peak_caches": 1, "max_entries_per_cache": 24,
            ])
        XCTAssertEqual(diagnostics.snapshot()["rail_geometry_cache_used"] as? Bool, true)
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 0)
    }

    func testGeometryInvalidCapacityDoesNotCountBuildsOrReplaceCurrentEntries() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        let owner = UUID()
        try diagnostics.enable(mode: .runtimeCachedRailGeometry)
        diagnostics.recordRailGeometryCacheBuild(owner: owner, entries: 2)
        let previous = diagnostics.snapshot()["rail_geometry_cache"] as? [String: UInt64]
        diagnostics.recordRailGeometryCacheBuild(owner: owner, entries: -1)
        diagnostics.recordRailGeometryCacheBuild(owner: owner, entries: 25)
        diagnostics.recordRailGeometryCacheEntries(owner: owner, -1)
        diagnostics.recordRailGeometryCacheEntries(owner: owner, 25)
        XCTAssertEqual(diagnostics.snapshot()["rail_geometry_cache"] as? [String: UInt64], previous)
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 4)
    }

    func testGeometryCleanupOfOneOwnerCannotHideAnotherLiveCache() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeCachedRailGeometry)
        let first = UUID()
        let second = UUID()
        diagnostics.recordRailGeometryCacheBuild(owner: first, entries: 24)
        diagnostics.recordRailGeometryCacheBuild(owner: second, entries: 24)
        diagnostics.recordRailGeometryCacheEntries(owner: first, 0)
        var counts = try XCTUnwrap(
            diagnostics.snapshot()["rail_geometry_cache"] as? [String: UInt64])
        XCTAssertEqual(counts["current_entries"], 24)
        XCTAssertEqual(counts["current_caches"], 1)
        XCTAssertEqual(counts["peak_entries"], 48)
        XCTAssertEqual(counts["peak_caches"], 2)
        diagnostics.recordRailGeometryCacheHit(owner: first)
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 1)
        diagnostics.recordRailGeometryCacheHit(owner: second)
        diagnostics.recordRailGeometryCacheEntries(owner: second, 0)
        counts = try XCTUnwrap(diagnostics.snapshot()["rail_geometry_cache"] as? [String: UInt64])
        XCTAssertEqual(counts["current_entries"], 0)
        XCTAssertEqual(counts["current_caches"], 0)
        XCTAssertEqual(counts["hits"], 1)
    }

    private func recordWork(_ diagnostics: PerformanceGraphicsDiagnostics, owner: UUID) {
        diagnostics.completedLaneCachePrepared(
            builds: 2, hits: 7, visitedRecords: 480, entries: 240)
        diagnostics.recordRailGeometryCacheBuild(owner: owner, entries: 2)
        diagnostics.recordRailGeometryCacheHit(owner: owner)
    }
}
