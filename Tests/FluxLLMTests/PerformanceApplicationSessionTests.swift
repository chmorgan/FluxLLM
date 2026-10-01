import AppKit
import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class PerformanceApplicationSessionTests: XCTestCase {
    func testBulkFixtureMatchesEveryReferenceObservationAndAccountingState() {
        let end = Date(timeIntervalSince1970: 1_800_000_017.25)
        var replayClock = end.addingTimeInterval(-3_600)
        var restoredClock = replayClock
        let replay = MetricsStore(clock: { replayClock })
        let restored = MetricsStore(clock: { restoredClock })
        for store in [replay, restored] {
            store.beginBackendSession(kind: .ollama, epoch: UUID(), sourceID: "fixture-equivalence")
        }
        PerformanceHistoryFixture.seedRawHistory(store: replay, endingAt: end, replaySamples: true)
        {
            replayClock = $0
        }
        PerformanceHistoryFixture.seedRawHistory(store: restored, endingAt: end) {
            restoredClock = $0
        }
        XCTAssertEqual(restored.tpsHistory, replay.tpsHistory)
        XCTAssertEqual(restored.systemGPUHistory, replay.systemGPUHistory)
        XCTAssertEqual(restored.toolObservationHistory, replay.toolObservationHistory)
        XCTAssertEqual(restored.tpsHistory.count, 7_201)
        XCTAssertEqual(restored.requestLanes, replay.requestLanes)
        XCTAssertEqual(restored.requestLanes.count, 256)
        XCTAssertEqual(restored.toolActivityEvents, replay.toolActivityEvents)
        XCTAssertEqual(
            restored.toolActivityEvents.map(\.requestID), replay.toolActivityEvents.map(\.requestID)
        )
        XCTAssertEqual(restored.toolActivityEvents.count, 512)
        XCTAssertEqual(restored.activeGeneration, replay.activeGeneration)
        XCTAssertEqual(restored.currentTPS, replay.currentTPS)
        XCTAssertEqual(restored.displayTPS, replay.displayTPS)
        XCTAssertEqual(restored.outputTokens, replay.outputTokens)
        XCTAssertEqual(restored.promptTokens, replay.promptTokens)
        XCTAssertEqual(restored.lastMeasuredTPS, replay.lastMeasuredTPS)
        XCTAssertEqual(restored.connectionState, replay.connectionState)
        XCTAssertEqual(restored.chartPresentation, replay.chartPresentation)
        XCTAssertEqual(
            restored.performanceFixtureArchive(endingAt: end),
            replay.performanceFixtureArchive(endingAt: end))
        XCTAssertEqual(
            PerformanceHistoryFixture.equivalenceManifest(
                store: restored, endingAt: end, populated: true),
            PerformanceHistoryFixture.equivalenceManifest(
                store: replay, endingAt: end, populated: true))
        restored.usageScope = .selectedPeriod
        let usage = restored.usageSummary(
            in: DateInterval(start: end.addingTimeInterval(-3_600), end: end))
        XCTAssertEqual(usage.requests, 256)
        XCTAssertEqual(usage.toolCalls, 256)
        XCTAssertEqual(usage.inputTokens, 8_192)
        XCTAssertEqual(usage.outputTokens, 133_120)
        XCTAssertEqual(usage.activeRequests, 0)

        // The semantic digest must survive a changed launch timestamp/source,
        // including different calendar minute bucket boundaries.
        let shiftedEnd = end.addingTimeInterval(123.5)
        var shiftedClock = shiftedEnd.addingTimeInterval(-3_600)
        let shifted = MetricsStore(clock: { shiftedClock })
        shifted.beginBackendSession(kind: .ollama, epoch: UUID(), sourceID: "another-fixture-port")
        PerformanceHistoryFixture.seedRawHistory(store: shifted, endingAt: shiftedEnd) {
            shiftedClock = $0
        }
        XCTAssertEqual(
            PerformanceHistoryFixture.equivalenceManifest(
                store: restored, endingAt: end, populated: true),
            PerformanceHistoryFixture.equivalenceManifest(
                store: shifted, endingAt: shiftedEnd, populated: true))
    }

    func testFreshSessionHealthRemainsReadyWhenWallClockSamplingStarts() async throws {
        _ = NSApplication.shared
        defer { XCTAssertNoThrow(try PerformanceGraphicsDiagnostics.shared.disable()) }
        let response = MockOllamaResponse(
            firstBytes: Array(
                #"{"version":"0.0.0-fixture","models":[{"model":"resource-fixture"}]}"#.utf8))
        let upstream = MockOllamaServer(response: response)
        try await upstream.start()
        let runID = UUID().uuidString
        let preferencesSuite = "FluxLLM.Performance.SessionTests.\(runID)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceSession-\(runID)", isDirectory: true)
        defer {
            UserDefaults(suiteName: preferencesSuite)?.removePersistentDomain(
                forName: preferencesSuite)
        }

        var session: PerformanceApplicationSession?
        do {
            let started = try await PerformanceApplicationSession.start(
                upstream: URL(string: "http://127.0.0.1:\(upstream.port)")!,
                historyDirectory: directory, preferencesSuite: preferencesSuite, populated: false)
            session = started
            // Fresh startup must not timestamp its health sample an hour in
            // the past, then immediately expire it on the first real tick.
            started.store.sample()
            XCTAssertEqual(started.store.connectionState, .ready)
            XCTAssertEqual(started.snapshot()["connection_state"] as? String, "ready")
            XCTAssertEqual(started.store.currentModel, "resource-fixture")
            XCTAssertEqual(started.snapshot()["requests"] as? Int, 0)
            XCTAssertFalse(started.store.isBackendActive)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            await started.stop()
            XCTAssertNil(started.shutdownError)
            await upstream.stop()
        } catch {
            await session?.stop()
            await upstream.stop()
            throw error
        }
    }

    func testPopulatedSessionStartsThroughProductionLifecycleWithoutHiddenSnapshots() async throws {
        _ = NSApplication.shared
        defer { XCTAssertNoThrow(try PerformanceGraphicsDiagnostics.shared.disable()) }
        let response = MockOllamaResponse(
            firstBytes: Array(
                #"{"version":"0.0.0-fixture","models":[{"model":"resource-fixture"}]}"#.utf8))
        let upstream = MockOllamaServer(response: response)
        try await upstream.start()
        let runID = UUID().uuidString
        let preferencesSuite = "FluxLLM.Performance.SessionTests.\(runID)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceSession-\(runID)", isDirectory: true)
        defer {
            UserDefaults(suiteName: preferencesSuite)?.removePersistentDomain(
                forName: preferencesSuite)
        }

        var session: PerformanceApplicationSession?
        do {
            let startedAt = ContinuousClock.now
            let started = try await PerformanceApplicationSession.start(
                upstream: URL(string: "http://127.0.0.1:\(upstream.port)")!,
                historyDirectory: directory, preferencesSuite: preferencesSuite, populated: true)
            session = started
            // The broken adapter left the store in standalone publication mode
            // during seeding and exceeded the app harness's 20-second timeout.
            XCTAssertLessThan(startedAt.duration(to: ContinuousClock.now), .seconds(10))
            let snapshot = started.snapshot()
            XCTAssertEqual(started.store.connectionState, .ready)
            XCTAssertGreaterThan(started.proxyPort, 0)
            XCTAssertEqual(snapshot["requests"] as? Int, 19_256)
            XCTAssertEqual(snapshot["tool_calls"] as? Int, 19_256)
            XCTAssertEqual(snapshot["tool_results"] as? Int, 0)
            XCTAssertEqual(snapshot["active_requests"] as? Int, 0)
            XCTAssertEqual(snapshot["history_verified"] as? Bool, true)
            XCTAssertFalse(started.menuBarController.performanceVisibility.dashboard)
            XCTAssertFalse(started.menuBarController.performanceVisibility.popover)
            XCTAssertTrue(started.store.chartPresentation.throughput.isEmpty)
            XCTAssertTrue(started.store.chartPresentation.requestLanes.isEmpty)
            XCTAssertEqual(started.store.chartPresentation.archive, .empty)
            // The production sampling task may already have aged a few oldest
            // points when this async call returns. The exact injected count is
            // covered by the synchronous fixture dimension test.
            XCTAssertGreaterThan(started.store.throughputSampleCount, 7_000)
            XCTAssertGreaterThanOrEqual(started.store.archivedThroughputBucketCount, 200)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertFalse(started.store.diagnosticLogger.isEnabled)
            await started.stop()
            XCTAssertNil(started.shutdownError)
            XCTAssertEqual(started.store.proxyState, .stopped)
            await upstream.stop()
        } catch {
            await session?.stop()
            await upstream.stop()
            throw error
        }
    }
}
