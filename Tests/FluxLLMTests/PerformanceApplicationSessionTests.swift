import AppKit
import Foundation
import XCTest

@testable import FluxLLM
@testable import FluxLLMPerformanceSupport

@MainActor
final class PerformanceApplicationSessionTests: XCTestCase {
    func testScopedNIOAccountingRequiresDirectThreadRegistrationBeforeStartup() async throws {
        do {
            _ = try await PerformanceApplicationSession.start(
                upstream: URL(string: "http://127.0.0.1:1")!,
                historyDirectory: FileManager.default.temporaryDirectory,
                preferencesSuite: "FluxLLM.Performance.InvalidNIO.\(UUID().uuidString)",
                populated: false, nioCPUAccountingEnabled: true)
            XCTFail("Scoped accounting must reject a missing direct thread registration")
        } catch {
            XCTAssertTrue(String(describing: error).contains("requires direct thread"))
        }
    }

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
            XCTAssertNil(started.snapshot()["thread_cpu_registration"])
            XCTAssertNil(started.snapshot()["nio_cpu"])
            try await started.refreshPerformanceNIODiagnostics()
            XCTAssertNil(started.snapshot()["nio_cpu"])
            XCTAssertEqual(started.snapshot()["popover_animations_enabled"] as? Bool, true)
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

    func testUnslothSessionRejectsInventedRetainedRequestHistoryAndNIOAccounting() async throws {
        for (populated, nio) in [(true, false), (false, true)] {
            let preferencesSuite = "FluxLLM.Performance.SessionTests.\(UUID().uuidString)"
            do {
                let session = try await PerformanceApplicationSession.start(
                    upstream: URL(string: "http://127.0.0.1:49152")!,
                    historyDirectory: FileManager.default.temporaryDirectory,
                    preferencesSuite: preferencesSuite, populated: populated,
                    backendKind: .unsloth, threadCPUAccountingEnabled: nio,
                    nioCPUAccountingEnabled: nio)
                await session.stop()
                XCTFail(
                    "A native-only session must reject unsupported retained-request/NIO evidence")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains(populated ? "fresh history" : "NIO"))
                XCTAssertNil(
                    UserDefaults(suiteName: preferencesSuite)?.persistentDomain(
                        forName: preferencesSuite))
                XCTAssertFalse(PerformanceGraphicsDiagnostics.shared.isEnabled)
            }
        }
    }

    func testFreshUnslothSessionUsesNativeMetricsWithoutCreatingProxyOrRequestHistory() async throws
    {
        _ = NSApplication.shared
        defer { XCTAssertNoThrow(try PerformanceGraphicsDiagnostics.shared.disable()) }
        let metrics = """
            llamacpp:requests_processing 2
            llamacpp:requests_deferred 0
            llamacpp:tokens_predicted_total 100
            llamacpp:prompt_tokens_total 46
            llamacpp:predicted_tokens_seconds 160
            """
        let upstream = MockOllamaServer(
            response: MockOllamaResponse(
                contentType: "text/plain", firstBytes: Array(metrics.utf8)))
        try await upstream.start()
        let runID = UUID().uuidString
        let preferencesSuite = "FluxLLM.Performance.SessionTests.\(runID)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PerformanceSession-\(runID)")
        defer {
            UserDefaults(suiteName: preferencesSuite)?.removePersistentDomain(
                forName: preferencesSuite)
        }
        var session: PerformanceApplicationSession?
        do {
            let started = try await PerformanceApplicationSession.start(
                upstream: URL(string: "http://127.0.0.1:\(upstream.port)")!,
                historyDirectory: directory, preferencesSuite: preferencesSuite, populated: false,
                backendKind: .unsloth, threadCPUAccountingEnabled: true)
            session = started
            let snapshot = started.snapshot()
            XCTAssertEqual(started.settings.backendSelection, .unsloth)
            XCTAssertEqual(started.store.backendKind, .unsloth)
            XCTAssertEqual(started.store.connectionState, .ready)
            XCTAssertEqual(started.proxyPort, 0)
            XCTAssertEqual(started.store.proxyState, .stopped)
            XCTAssertEqual(snapshot["backend_output_tokens"] as? Int, 100)
            XCTAssertEqual(snapshot["backend_prompt_tokens"] as? Int, 46)
            XCTAssertEqual(snapshot["running_requests"] as? Int, 2)
            XCTAssertEqual(snapshot["current_tps"] as? Double, 160)
            XCTAssertEqual(snapshot["throughput_basis"] as? String, "serverReportedAverage")
            XCTAssertEqual(
                snapshot["request_observation"] as? String, "unavailable-native-aggregate")
            XCTAssertEqual(snapshot["discovery_scope"] as? String, "synthetic-stable-loopback")
            for field in [
                "requests", "tool_calls", "tool_results", "active_requests", "seed_raw_requests",
                "seed_tool_events",
            ] {
                XCTAssertEqual(snapshot[field] as? Int, 0, field)
            }
            XCTAssertTrue(started.store.requestLanes.isEmpty)
            XCTAssertTrue(started.store.toolActivityEvents.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            let registration = try XCTUnwrap(snapshot["thread_cpu_registration"] as? [String: Any])
            let roles = try XCTUnwrap(registration["roles"] as? [String: UInt64])
            XCTAssertEqual(Set(roles.keys), ["main"])
            XCTAssertNil(snapshot["nio_cpu"])
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
                historyDirectory: directory, preferencesSuite: preferencesSuite, populated: true,
                popoverAnimationsEnabled: false, threadCPUAccountingEnabled: true,
                nioCPUAccountingEnabled: true)
            session = started
            let registration = try XCTUnwrap(
                started.snapshot()["thread_cpu_registration"] as? [String: Any])
            let roles = try XCTUnwrap(registration["roles"] as? [String: UInt64])
            XCTAssertEqual(registration["schema_version"] as? Int, 1)
            XCTAssertEqual(registration["process_id"] as? Int32, getpid())
            XCTAssertEqual(roles["main"], try PerformanceThreadIdentity.current())
            XCTAssertGreaterThan(try XCTUnwrap(roles["nio"]), 0)
            XCTAssertNotEqual(roles["main"], roles["nio"])
            let nio = try XCTUnwrap(started.snapshot()["nio_cpu"] as? [String: Any])
            XCTAssertEqual(nio["available"] as? Bool, true)
            XCTAssertEqual(nio["thread_id"] as? UInt64, roles["nio"])
            try await started.refreshPerformanceNIODiagnostics()
            let refreshed = try XCTUnwrap(started.snapshot()["nio_cpu"] as? [String: Any])
            XCTAssertGreaterThan(
                try XCTUnwrap(refreshed["sequence"] as? UInt64),
                try XCTUnwrap(nio["sequence"] as? UInt64))
            XCTAssertEqual(
                (started.snapshot()["thread_cpu_registration"] as? [String: Any])?["roles"]
                    as? [String: UInt64], roles)
            XCTAssertEqual(started.snapshot()["popover_animations_enabled"] as? Bool, false)
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
