import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class UsageStoreIntegrationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testUsageSurvivesChartRangeChangesAndSameSourceReconnect() {
        let now = date(20)
        let store = MetricsStore(clock: { now })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch, sourceID: "local")
        let request = GenerationRequest(model: "fixture", startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        store.apply(completion(request, at: 10, input: 12, output: 25), epoch: epoch)
        let expected = store.usageSummary(in: interval(0, 20))

        for range in HistoryRange.allCases {
            store.historyRange = range
            XCTAssertEqual(store.usageSummary(in: interval(15, 20)), expected)
        }
        store.beginBackendSession(kind: .ollama, epoch: UUID(), sourceID: "local")

        XCTAssertEqual(store.usageSummary(in: interval(15, 20)), expected)
        XCTAssertEqual(expected.inputTokens, 12)
        XCTAssertEqual(expected.outputTokens, 25)
        XCTAssertEqual(expected.requests, 1)
        XCTAssertEqual(expected.activeRequests, 0)
    }

    func testUsageIsIsolatedBySourceAndRestoredWhenReturningToIt() {
        let now = date(20)
        let store = MetricsStore(clock: { now })
        let request = GenerationRequest(model: "fixture", startedAt: origin)
        let localEpoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: localEpoch, sourceID: "local")
        store.apply(.began(request), epoch: localEpoch)
        store.apply(completion(request, at: 5, input: 10, output: 20), epoch: localEpoch)

        let remoteEpoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: remoteEpoch, sourceID: "remote")
        XCTAssertEqual(store.usageSummary(in: interval(0, 20)).requests, 0)
        // Request UUIDs only have meaning within their source.
        store.apply(.began(request), epoch: remoteEpoch)
        store.apply(completion(request, at: 5, input: 30, output: 40), epoch: remoteEpoch)
        XCTAssertEqual(store.usageSummary(in: interval(0, 20)).outputTokens, 40)

        store.beginBackendSession(kind: .ollama, epoch: UUID(), sourceID: "local")
        let local = store.usageSummary(in: interval(0, 20))
        XCTAssertEqual(local.inputTokens, 10)
        XCTAssertEqual(local.outputTokens, 20)
        XCTAssertEqual(local.requests, 1)
    }

    func testOldEpochCannotChangeUsageAfterReconnectingToSameSource() {
        let now = date(20)
        let store = MetricsStore(clock: { now })
        let oldEpoch = UUID()
        let currentEpoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: oldEpoch, sourceID: "local")
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request), epoch: oldEpoch)
        store.apply(completion(request, at: 5, input: 10, output: 20), epoch: oldEpoch)
        store.beginBackendSession(kind: .ollama, epoch: currentEpoch, sourceID: "local")
        let expected = store.usageSummary(in: interval(0, 20))

        let stale = GenerationRequest(startedAt: date(10))
        store.apply(.began(stale), epoch: oldEpoch)
        store.apply(completion(stale, at: 15, input: 50, output: 100), epoch: oldEpoch)
        store.apply(completion(request, at: 15, input: 70, output: 200), epoch: oldEpoch)
        store.apply(
            .toolActivity(
                requestID: request.id,
                events: [ToolActivityEvent(kind: .call, timestamp: date(15))]), epoch: oldEpoch)

        XCTAssertEqual(store.usageSummary(in: interval(0, 20)), expected)
    }

    func testRepeatedTerminalAndToolEventsDoNotIncreaseTotals() {
        let now = date(20)
        let store = MetricsStore(clock: { now })
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        let call = ToolActivityEvent(kind: .call, callID: "call-1", timestamp: date(2))
        let result = ToolActivityEvent(
            kind: .resultSubmission, callID: "call-1", timestamp: date(3))
        let terminal = completion(request, at: 5, input: 10, output: 20)
        for _ in 0..<3 {
            store.apply(.toolActivity(requestID: request.id, events: [call, result]))
            store.apply(terminal)
        }

        let summary = store.usageSummary(in: interval(0, 20))
        XCTAssertEqual(summary.inputTokens, 10)
        XCTAssertEqual(summary.outputTokens, 20)
        XCTAssertFalse(summary.outputIsEstimated)
        XCTAssertEqual(summary.requests, 1)
        XCTAssertEqual(summary.toolCalls, 1)
        XCTAssertEqual(summary.activeRequests, 0)
    }

    func testOlderConcurrentRequestContributesItsInputAndFinalOutput() {
        let now = date(20)
        let store = MetricsStore(clock: { now })
        let older = GenerationRequest(model: "older", startedAt: origin)
        let newer = GenerationRequest(model: "newer", startedAt: date(2))
        store.apply(.began(older))
        store.apply(.began(newer))
        store.apply(completion(newer, at: 5, input: 30, output: 40))
        store.apply(completion(older, at: 10, input: 50, output: 60))

        let all = store.usageSummary(in: interval(0, 20))
        XCTAssertEqual(all.inputTokens, 80)
        XCTAssertEqual(all.outputTokens, 100)
        XCTAssertEqual(all.unknownInputRequests, 0)
        XCTAssertEqual(all.requests, 2)
        XCTAssertEqual(store.activeGeneration?.id, newer.id)
        XCTAssertEqual(store.promptTokens, 30)

        store.usageScope = .selectedPeriod
        let first = store.usageSummary(in: interval(0, 10))
        let second = store.usageSummary(in: interval(10, 20))
        XCTAssertEqual(first.inputTokens, 30)
        XCTAssertEqual(first.outputTokens, 40)
        XCTAssertEqual(first.requests, 1)
        XCTAssertEqual(second.inputTokens, 50)
        XCTAssertEqual(second.outputTokens, 60)
        XCTAssertEqual(second.requests, 1)
    }

    func testHistoricalMetadataAndUsageSurviveRawChartRetention() {
        var now = origin
        let store = MetricsStore(clock: { now })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        let request = GenerationRequest(model: "fixture", startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        let call = ToolActivityEvent(kind: .call, name: "read_file", timestamp: date(1))
        store.apply(.toolActivity(requestID: request.id, events: [call]), epoch: epoch)
        store.apply(completion(request, at: 2, input: 12, output: 25), epoch: epoch)
        now = date(3)
        store.sample(at: now)
        now = date(MetricsStore.chartWindow + 10)
        store.sample(at: now)

        XCTAssertTrue(store.chartPresentation.requestLanes.isEmpty)
        XCTAssertTrue(store.chartPresentation.toolActivity.isEmpty)
        XCTAssertEqual(store.chartPresentation.historicalRequestLanes.map(\.id), [request.id])
        XCTAssertEqual(store.chartPresentation.historicalToolActivity.map(\.id), [call.id])
        let summary = store.usageSummary(in: interval(0, now.timeIntervalSince(origin)))
        XCTAssertEqual(summary.outputTokens, 25)
        XCTAssertEqual(summary.inputTokens, 12)
        XCTAssertEqual(summary.toolCalls, 1)
    }

    private func completion(
        _ request: GenerationRequest, at offset: TimeInterval, input: Int, output: Int
    ) -> GenerationEvent {
        .updated(
            requestID: request.id,
            snapshot: GenerationSnapshot(
                outputTokens: output, promptTokens: input, isEstimated: false,
                finished: true, timestamp: date(offset)))
    }

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    private func interval(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval {
        DateInterval(start: date(start), end: date(end))
    }
}
