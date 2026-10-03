import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class MetricsStoreBatchTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testOrderedBatchMatchesSequentialConcurrentLifecycleUsageToolsAndHistory() throws {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        let previousMode = diagnostics.mode
        let wasEnabled = diagnostics.isEnabled
        try diagnostics.enable(mode: .runtimeTelemetryBatch)
        defer { restore(diagnostics, mode: previousMode, wasEnabled: wasEnabled) }
        let now = origin.addingTimeInterval(10)
        let sequential = MetricsStore(clock: { now })
        let batched = MetricsStore(clock: { now })
        let epoch = UUID()
        for store in [sequential, batched] {
            store.beginBackendSession(kind: .ollama, epoch: epoch)
            store.applyBackendSample(BackendSample(kind: .ollama, timestamp: now), epoch: epoch)
            store.setChartPresentationDemand(true, consumer: .dashboard)
        }
        let older = GenerationRequest(model: "older", startedAt: origin)
        let latest = GenerationRequest(model: "latest", startedAt: origin.addingTimeInterval(1))
        let call = ToolActivityEvent(
            kind: .call, name: "read", timestamp: origin.addingTimeInterval(1.5))
        let result = ToolActivityEvent(
            kind: .resultSubmission, name: "read", timestamp: origin.addingTimeInterval(2))
        let batches: [[GenerationEvent]] = [
            [
                .began(older), update(older, count: 5, rate: 11, at: 0.5),
                .began(latest), update(latest, count: 8, rate: 7, at: 1.1),
                .toolActivity(requestID: older.id, events: [call]),
            ],
            [
                update(older, count: 20, rate: 13, at: 2),
                .toolActivity(requestID: latest.id, events: [result, result]),
                .updated(
                    requestID: older.id,
                    snapshot: GenerationSnapshot(
                        model: "resolved", outputTokens: 17, promptTokens: 3, isEstimated: false,
                        authoritativeTPS: 8.5, finished: true,
                        timestamp: origin.addingTimeInterval(2))),
            ],
            [
                update(latest, count: 11, rate: 9, at: 3), .cancelled(requestID: latest.id),
                .failed(requestID: latest.id, message: "late failure"),
                update(latest, count: 999, rate: 999, at: 4), .began(latest),
            ],
        ]
        for (index, events) in batches.enumerated() {
            for event in events { sequential.apply(event, epoch: epoch) }
            batched.applyBatch(events, epoch: epoch)
            assertEquivalent(sequential, batched, includePresentation: false)
            let timestamp = origin.addingTimeInterval(Double(index + 1) * 0.5)
            sequential.sample(at: timestamp)
            batched.sample(at: timestamp)
            assertEquivalent(sequential, batched, includePresentation: true)
        }
        XCTAssertEqual(batched.activeGeneration?.id, latest.id)
        XCTAssertEqual(batched.activeGeneration?.state, .cancelled)
        XCTAssertEqual(batched.outputTokens, 11)
        XCTAssertEqual(batched.currentTPS, 0)
        XCTAssertEqual(batched.toolActivityEvents.map(\.id), [call.id, result.id])
        let summary = batched.usageSummary(in: DateInterval(start: origin, duration: 20))
        XCTAssertEqual(summary.requests, 2)
        XCTAssertEqual(summary.activeRequests, 0)
        XCTAssertEqual(
            summary.outputTokens, 28, "Authoritative correction replaces the older estimate")
        XCTAssertEqual(summary.inputTokens, 3)
    }

    func testOneBatchRefreshesProjectionAndPublishesBoundaryScalarsOnce() throws {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        let previousMode = diagnostics.mode
        let wasEnabled = diagnostics.isEnabled
        try diagnostics.enable(mode: .runtimeTelemetryBatch)
        defer { restore(diagnostics, mode: previousMode, wasEnabled: wasEnabled) }
        let store = MetricsStore(clock: { self.origin.addingTimeInterval(10) })
        store.setChartPresentationDemand(true, consumer: .dashboard)
        let beforeScalars =
            diagnostics.snapshot()["scalar_presentation_publications"] as? UInt64 ?? 0
        let request = GenerationRequest(startedAt: origin)
        let events: [GenerationEvent] = [
            .began(request), update(request, count: 100, rate: 10, at: 1),
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 92, promptTokens: 8, isEstimated: false,
                    finished: true, timestamp: origin.addingTimeInterval(2))),
        ]
        store.applyBatch(events)
        let counters = try XCTUnwrap(
            diagnostics.snapshot()["batched_telemetry"] as? [String: UInt64])
        XCTAssertEqual(counters["batches_applied"], 1)
        XCTAssertEqual(counters["events_applied"], 3)
        XCTAssertEqual(counters["projection_refreshes"], 1)
        XCTAssertEqual(
            diagnostics.snapshot()["scalar_presentation_publications"] as? UInt64,
            beforeScalars + 1)
        XCTAssertEqual(store.dashboardScalarPresentation.latestResponse?.outputTokens, 92)
        XCTAssertEqual(store.dashboardScalarPresentation.usage.outputTokens, 92)
        XCTAssertFalse(store.isBackendActive)
    }

    func testEmptyStaleEpochAndForeignBackendBatchesDoNotApplyOrRefresh() throws {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        let previousMode = diagnostics.mode
        let wasEnabled = diagnostics.isEnabled
        try diagnostics.enable(mode: .runtimeTelemetryBatch)
        defer { restore(diagnostics, mode: previousMode, wasEnabled: wasEnabled) }
        let store = MetricsStore(clock: { self.origin })
        let oldEpoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: oldEpoch)
        let request = GenerationRequest(startedAt: origin)
        store.applyBatch([], epoch: oldEpoch)
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        store.applyBatch(
            [.began(request), update(request, count: 10, rate: 1, at: 1)], epoch: oldEpoch)
        let epoch = UUID()
        store.beginBackendSession(kind: .llamaCpp, epoch: epoch)
        store.applyBatch([.began(request)], epoch: epoch)
        XCTAssertNil(store.activeGeneration)
        XCTAssertTrue(store.requestLanes.isEmpty)
        let counters = try XCTUnwrap(
            diagnostics.snapshot()["batched_telemetry"] as? [String: UInt64])
        XCTAssertEqual(counters["batches_applied"], 0)
        XCTAssertEqual(counters["events_applied"], 0)
        XCTAssertEqual(counters["projection_refreshes"], 0)
    }

    private func update(
        _ request: GenerationRequest, count: Int, rate: Double, at offset: TimeInterval
    ) -> GenerationEvent {
        .updated(
            requestID: request.id,
            snapshot: GenerationSnapshot(
                outputTokens: count, liveTPS: rate, timestamp: origin.addingTimeInterval(offset)))
    }

    private func restore(
        _ diagnostics: PerformanceGraphicsDiagnostics,
        mode: PerformanceGraphicsDiagnostics.Mode, wasEnabled: Bool
    ) {
        if wasEnabled { try? diagnostics.enable(mode: mode) } else { try? diagnostics.disable() }
    }

    private func assertEquivalent(
        _ lhs: MetricsStore, _ rhs: MetricsStore, includePresentation: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(lhs.activeGeneration, rhs.activeGeneration, file: file, line: line)
        XCTAssertEqual(lhs.currentModel, rhs.currentModel, file: file, line: line)
        XCTAssertEqual(lhs.currentTPS, rhs.currentTPS, file: file, line: line)
        XCTAssertEqual(lhs.outputTokens, rhs.outputTokens, file: file, line: line)
        XCTAssertEqual(lhs.promptTokens, rhs.promptTokens, file: file, line: line)
        XCTAssertEqual(lhs.outputIsEstimated, rhs.outputIsEstimated, file: file, line: line)
        XCTAssertEqual(lhs.lastMeasuredTPS, rhs.lastMeasuredTPS, file: file, line: line)
        XCTAssertEqual(lhs.generationError, rhs.generationError, file: file, line: line)
        XCTAssertEqual(lhs.backendActivity, rhs.backendActivity, file: file, line: line)
        XCTAssertEqual(lhs.connectionState, rhs.connectionState, file: file, line: line)
        XCTAssertEqual(lhs.rateIsAvailable, rhs.rateIsAvailable, file: file, line: line)
        XCTAssertEqual(lhs.requestLanes, rhs.requestLanes, file: file, line: line)
        XCTAssertEqual(lhs.toolActivityEvents, rhs.toolActivityEvents, file: file, line: line)
        if includePresentation {
            XCTAssertEqual(
                lhs.dashboardScalarPresentation, rhs.dashboardScalarPresentation, file: file,
                line: line)
        }
        XCTAssertEqual(lhs.tpsHistory, rhs.tpsHistory, file: file, line: line)
        XCTAssertEqual(
            lhs.toolObservationHistory, rhs.toolObservationHistory, file: file, line: line)
        XCTAssertEqual(lhs.chartPresentation, rhs.chartPresentation, file: file, line: line)
        let interval = DateInterval(start: origin, duration: 20)
        XCTAssertEqual(
            lhs.usageSummary(in: interval), rhs.usageSummary(in: interval), file: file, line: line)
    }
}
