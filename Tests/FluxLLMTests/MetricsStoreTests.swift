import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class MetricsStoreTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testEmptyStoreHasNoRequestOrMeasuredUsage() {
        let store = MetricsStore()
        XCTAssertNil(store.activeGeneration)
        XCTAssertNil(store.promptTokens)
        XCTAssertNil(store.lastMeasuredTPS)
        XCTAssertEqual(store.outputTokens, 0)
        XCTAssertEqual(store.currentTPS, 0)
        XCTAssertTrue(store.tpsHistory.isEmpty)
    }

    func testLiveAndFinalRatesHaveDistinctMeaning() {
        let store = MetricsStore()
        let request = GenerationRequest(model: "llama3", startedAt: origin)
        store.apply(.began(request))
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    model: "llama3", outputTokens: 8, liveTPS: 4, timestamp: origin)))
        XCTAssertEqual(store.activeGeneration?.state, .running)
        XCTAssertEqual(store.currentTPS, 4)
        XCTAssertTrue(store.outputIsEstimated)
        XCTAssertNil(store.promptTokens)
        XCTAssertNil(store.lastMeasuredTPS)
        store.apply(.updated(requestID: request.id, snapshot: finalSnapshot(tokens: 12)))
        XCTAssertEqual(store.activeGeneration?.state, .completed)
        XCTAssertEqual(store.outputTokens, 12)
        XCTAssertEqual(store.promptTokens, 3)
        XCTAssertFalse(store.outputIsEstimated)
        XCTAssertEqual(store.currentTPS, 0, "Completed throughput is not current activity")
        XCTAssertEqual(store.lastMeasuredTPS, 20)
    }

    func testSecondRequestResetsUsageAndGetsNewIdentity() {
        let store = MetricsStore()
        let first = GenerationRequest(model: "first", startedAt: origin)
        store.apply(.began(first))
        store.apply(.updated(requestID: first.id, snapshot: finalSnapshot(tokens: 50)))
        let second = GenerationRequest(model: "second", startedAt: origin.addingTimeInterval(2))
        store.apply(.began(second))
        XCTAssertEqual(store.activeGeneration?.id, second.id)
        XCTAssertEqual(store.activeGeneration?.startedAt, second.startedAt)
        XCTAssertEqual(store.activeGeneration?.state, .running)
        XCTAssertEqual(store.currentModel, "second")
        XCTAssertEqual(store.outputTokens, 0)
        XCTAssertNil(store.promptTokens)
        XCTAssertNil(store.lastMeasuredTPS)
        XCTAssertNil(store.generationError)
        XCTAssertEqual(store.currentTPS, 0)
    }

    func testOlderOverlappingRequestCannotOverwriteNewestSession() {
        let store = MetricsStore()
        let old = GenerationRequest(model: "old", startedAt: origin)
        let newest = GenerationRequest(model: "new", startedAt: origin.addingTimeInterval(1))
        store.apply(.began(old))
        store.apply(.began(newest))
        store.apply(
            .updated(
                requestID: newest.id,
                snapshot: GenerationSnapshot(
                    model: "new", outputTokens: 7, liveTPS: 3.5, timestamp: newest.startedAt)))
        store.apply(.updated(requestID: old.id, snapshot: finalSnapshot(tokens: 999)))
        store.apply(.failed(requestID: old.id, message: "Old request failed"))
        store.apply(.cancelled(requestID: old.id))
        store.apply(.began(old))
        XCTAssertEqual(store.activeGeneration?.id, newest.id)
        XCTAssertEqual(store.activeGeneration?.state, .running)
        XCTAssertEqual(store.currentModel, "new")
        XCTAssertEqual(store.outputTokens, 7)
        XCTAssertEqual(store.currentTPS, 3.5)
        XCTAssertNil(store.generationError)
        XCTAssertNil(store.lastMeasuredTPS)
    }

    func testConcurrentRequestsSumThroughputButKeepOwnerScopedUsage() {
        let store = MetricsStore()
        let first = GenerationRequest(model: "alpha", startedAt: origin)
        let second = GenerationRequest(model: "beta", startedAt: origin.addingTimeInterval(1))
        store.apply(.began(first))
        store.apply(
            .updated(
                requestID: first.id,
                snapshot: GenerationSnapshot(
                    model: "alpha", outputTokens: 10, liveTPS: 41, timestamp: origin)))
        // A single open request contributes its own rate to the sum.
        XCTAssertEqual(store.currentTPS, 41)
        XCTAssertEqual(store.outputTokens, 10)

        // The second request starts later, so it owns the displayed identity, but
        // both rates add together instead of one overwriting the other.
        store.apply(.began(second))
        store.apply(
            .updated(
                requestID: second.id,
                snapshot: GenerationSnapshot(
                    model: "beta", outputTokens: 27, liveTPS: 27,
                    timestamp: second.startedAt)))
        XCTAssertEqual(store.currentTPS, 68, "Concurrent streams sum their live rates")
        XCTAssertEqual(store.activeGeneration?.id, second.id)
        XCTAssertEqual(store.currentModel, "beta")
        // Usage stays owner-scoped, not summed, while the rate is aggregated.
        XCTAssertEqual(store.outputTokens, 27)

        // Finishing one request drops only its contribution from the sum.
        store.apply(
            .updated(requestID: second.id, snapshot: GenerationSnapshot(finished: true)))
        XCTAssertEqual(store.currentTPS, 41)
        XCTAssertTrue(store.isBackendActive, "The older request is still generating")

        // The last open request finishing leaves no summed rate.
        store.apply(
            .updated(
                requestID: first.id,
                snapshot: GenerationSnapshot(outputTokens: 10, finished: true)))
        XCTAssertEqual(store.currentTPS, 0)
    }

    func testStalledOpenRequestDropsOutOfSummedThroughput() {
        let store = MetricsStore(clock: { self.origin })
        let first = GenerationRequest(model: "alpha", startedAt: origin)
        let second = GenerationRequest(model: "beta", startedAt: origin.addingTimeInterval(1))
        store.apply(.began(first))
        store.apply(
            .updated(
                requestID: first.id,
                snapshot: GenerationSnapshot(
                    model: "alpha", outputTokens: 10, liveTPS: 41, timestamp: origin)))
        store.apply(.began(second))
        store.apply(
            .updated(
                requestID: second.id,
                snapshot: GenerationSnapshot(
                    model: "beta", outputTokens: 27, liveTPS: 27,
                    timestamp: second.startedAt)))
        // Both open and fresh: the sum includes both live rates.
        XCTAssertEqual(store.currentTPS, 68)

        // The second request keeps streaming, so it stays fresh; the first has
        // not sent a chunk. As the second updates past the first's
        // `freshnessInterval`, the first expires from the sum.
        store.apply(
            .updated(
                requestID: second.id,
                snapshot: GenerationSnapshot(
                    model: "beta", outputTokens: 40, liveTPS: 27,
                    timestamp: origin.addingTimeInterval(6.2))))
        XCTAssertEqual(store.currentTPS, 27, "The stalled request drops out of the sum")

        // A fresh chunk from the first request re-includes it in the sum.
        store.apply(
            .updated(
                requestID: first.id,
                snapshot: GenerationSnapshot(
                    model: "alpha", outputTokens: 30, liveTPS: 41,
                    timestamp: origin.addingTimeInterval(7))))
        XCTAssertEqual(store.currentTPS, 68, "A fresh chunk re-includes the request")
    }

    func testTerminalSessionIgnoresLateChunksErrorsAndDuplicateBegan() {
        let store = MetricsStore()
        let request = GenerationRequest(model: "llama3", startedAt: origin)
        store.apply(.began(request))
        store.apply(.updated(requestID: request.id, snapshot: finalSnapshot(tokens: 12)))
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 999, liveTPS: 999)))
        store.apply(.failed(requestID: request.id, message: "Late transport close"))
        store.apply(.cancelled(requestID: request.id))
        store.apply(.began(request))
        XCTAssertEqual(store.activeGeneration?.state, .completed)
        XCTAssertEqual(store.outputTokens, 12)
        XCTAssertEqual(store.lastMeasuredTPS, 20)
        XCTAssertNil(store.generationError)
        XCTAssertEqual(store.currentTPS, 0)
    }

    func testUnknownRequestUpdateDoesNotCreateGeneration() {
        let store = MetricsStore()
        store.apply(.updated(requestID: UUID(), snapshot: finalSnapshot(tokens: 12)))
        XCTAssertNil(store.activeGeneration)
        XCTAssertEqual(store.outputTokens, 0)
    }

    func testFailureAndCancellationStopLiveRateWithoutMeasuredSuccess() {
        for cancel in [false, true] {
            let store = MetricsStore()
            let request = GenerationRequest(model: "llama3", startedAt: origin)
            store.apply(.began(request))
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: 4, liveTPS: 8)))
            store.apply(
                cancel
                    ? .cancelled(requestID: request.id)
                    : .failed(requestID: request.id, message: "Ollama disconnected"))
            XCTAssertEqual(store.activeGeneration?.state, cancel ? .cancelled : .errored)
            XCTAssertEqual(store.currentTPS, 0)
            XCTAssertNil(store.lastMeasuredTPS)
            XCTAssertEqual(store.outputTokens, 4)
            XCTAssertEqual(store.generationError, cancel ? nil : "Ollama disconnected")
        }
    }

    func testSnapshotErrorWinsOverFinishedFlag() {
        let store = MetricsStore()
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 3, authoritativeTPS: 20, finished: true, error: "Truncated stream"
                )))
        XCTAssertEqual(store.activeGeneration?.state, .errored)
        XCTAssertNil(store.lastMeasuredTPS)
        XCTAssertEqual(store.currentTPS, 0)
        XCTAssertEqual(store.generationError, "Truncated stream")
    }

    func testHistoryUsesClockSamplesRatherThanResponseFrequency() {
        let store = MetricsStore()
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        for value in 1...10 {
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: value, liveTPS: Double(value))))
        }
        XCTAssertTrue(store.tpsHistory.isEmpty)
        store.sample(at: origin)
        store.sample(at: origin.addingTimeInterval(0.5))
        XCTAssertEqual(
            store.tpsHistory,
            [
                TimeSeriesPoint(timestamp: origin, value: 10),
                TimeSeriesPoint(timestamp: origin.addingTimeInterval(0.5), value: 10),
            ])
    }

    func testLoadingWithoutASelectedBackendKeepsAvailableZeroSamples() {
        let store = MetricsStore(clock: { self.origin })
        store.apply(.began(GenerationRequest(startedAt: origin)))
        for index in 0...20 {
            store.sample(at: origin.addingTimeInterval(Double(index) / 2))
        }
        XCTAssertEqual(store.tpsHistory.count, 21)
        XCTAssertTrue(store.tpsHistory.allSatisfy { $0.isAvailable && $0.value == 0 })
        XCTAssertEqual(store.displayTPS, 0)
    }

    func testLaterZeroSnapshotCannotEraseOutputEvidenceButNewRequestCanLoad() {
        for (tokens, rate) in [(1, 0.0), (0, 10.0)] {
            let store = MetricsStore(clock: { self.origin })
            let request = GenerationRequest(startedAt: origin)
            store.apply(.began(request))
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: tokens, liveTPS: rate, timestamp: origin)))
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: 0, liveTPS: 0, timestamp: origin.addingTimeInterval(1))))
            for index in 2...13 {
                store.sample(at: origin.addingTimeInterval(Double(index) / 2))
            }
            XCTAssertFalse(store.tpsHistory.last!.isAvailable)
            XCTAssertNil(store.displayTPS)

            store.apply(.began(GenerationRequest(startedAt: origin.addingTimeInterval(7))))
            for index in 14...26 {
                store.sample(at: origin.addingTimeInterval(Double(index) / 2))
            }
            XCTAssertTrue(
                store.tpsHistory.suffix(13).allSatisfy { $0.isAvailable && $0.value == 0 })
            XCTAssertEqual(store.displayTPS, 0)
        }
    }

    func testHistoryAgesOutDuringIdleWithInclusiveOneHourBoundary() {
        let store = MetricsStore()
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        store.apply(.updated(requestID: request.id, snapshot: GenerationSnapshot(liveTPS: 8)))
        store.sample(at: origin)
        store.apply(.updated(requestID: request.id, snapshot: finalSnapshot(tokens: 12)))
        store.sample(at: origin.addingTimeInterval(MetricsStore.chartWindow))
        XCTAssertEqual(store.tpsHistory.filter(\.isAvailable).map(\.value), [8, 0])
        store.sample(at: origin.addingTimeInterval(MetricsStore.chartWindow + 0.5))
        XCTAssertEqual(store.tpsHistory.filter(\.isAvailable).map(\.value), [0, 0])
        XCTAssertEqual(store.sampleDate, origin.addingTimeInterval(MetricsStore.chartWindow + 0.5))
    }

    func testHistoryIsBoundedAndRejectsBackwardsTimestamps() {
        let store = MetricsStore()
        let count = MetricsStore.maxHistorySamples + 100
        for index in 0..<count {
            store.sample(at: origin.addingTimeInterval(Double(index) / 10))
        }
        XCTAssertEqual(store.tpsHistory.count, MetricsStore.maxHistorySamples)
        let lastDate = origin.addingTimeInterval(Double(count - 1) / 10)
        XCTAssertEqual(store.tpsHistory.last?.timestamp, lastDate)
        let before = store.tpsHistory
        store.sample(at: origin)
        XCTAssertEqual(store.tpsHistory, before)
        store.sample(at: lastDate)
        XCTAssertEqual(store.tpsHistory, before, "Identical time replaces rather than appends")
    }

    func testInvalidLiveRatesCannotPoisonChartSamples() {
        let store = MetricsStore()
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        for (index, rate) in [Double.nan, .infinity, -.infinity, -1].enumerated() {
            store.apply(
                .updated(requestID: request.id, snapshot: GenerationSnapshot(liveTPS: rate)))
            store.sample(at: origin.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(store.tpsHistory.map(\.value), [0, 0, 0, 0])
        XCTAssertTrue(store.tpsHistory.allSatisfy { !$0.isAvailable })
    }

    func testHiddenConsumersCollectSamplesWithoutPublishingAndReopenImmediately() {
        var now = origin
        let store = MetricsStore(clock: { now })
        store.setChartPresentationDemand(false, consumer: .dashboard)
        store.setChartPresentationDemand(false, consumer: .popover)
        let hidden = store.chartPresentation
        for index in 0..<40 {
            now = origin.addingTimeInterval(Double(index) / 2)
            store.sample()
        }
        XCTAssertEqual(store.tpsHistory.count, 40)
        XCTAssertEqual(store.chartPresentation, hidden)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        XCTAssertEqual(store.chartPresentation.timestamp, now)
        XCTAssertEqual(store.chartPresentation.throughput, store.tpsHistory)
        store.setChartPresentationDemand(true, consumer: .popover)
        store.setChartPresentationDemand(false, consumer: .dashboard)
        now = now.addingTimeInterval(1)
        store.sample()
        XCTAssertEqual(
            store.chartPresentation.timestamp, now,
            "The remaining visible consumer keeps publication active")
        store.setChartPresentationDemand(false, consumer: .popover)
        XCTAssertTrue(
            store.chartPresentation.throughput.isEmpty,
            "Closed surfaces release their presentation arrays")
        now = now.addingTimeInterval(1)
        store.sample()
        store.setChartPresentationDemand(true, consumer: .popover)
        XCTAssertEqual(store.chartPresentation.timestamp, now)
        XCTAssertEqual(store.chartPresentation.throughput, store.tpsHistory)
    }

    func testSampleRingsWrapPreservePublishedSnapshotsAndReplaceLatestTimestamp() {
        let store = MetricsStore(clock: { self.origin })
        store.proxyState = .listening
        store.setChartPresentationDemand(false, consumer: .dashboard)
        for index in 0..<100 {
            store.sample(at: origin.addingTimeInterval(Double(index) / 2))
        }
        store.setChartPresentationDemand(true, consumer: .dashboard)
        let saved = store.chartPresentation
        store.setChartPresentationDemand(false, consumer: .dashboard)
        let total = MetricsStore.maxHistorySamples * 3
        for index in 100..<total {
            store.sample(at: origin.addingTimeInterval(Double(index) / 2))
        }
        let expected = (total - MetricsStore.maxHistorySamples..<total).map {
            origin.addingTimeInterval(Double($0) / 2)
        }
        XCTAssertEqual(store.tpsHistory.map(\.timestamp), expected)
        XCTAssertEqual(store.gpuHistory.map(\.timestamp), expected)
        XCTAssertEqual(store.toolObservationHistory.map(\.timestamp), expected)
        XCTAssertEqual(saved.throughput.count, 100)
        XCTAssertEqual(saved.throughput.first?.timestamp, origin)
        let current = store.tpsHistory
        store.sample(at: expected.last!)
        XCTAssertEqual(store.tpsHistory, current)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        XCTAssertEqual(store.chartPresentation.throughput, current)
        store.sample(at: expected.last!.addingTimeInterval(MetricsStore.chartWindow + 10))
        XCTAssertEqual(store.tpsHistory.count, 1)
        XCTAssertEqual(store.toolObservationHistory.count, 1)
    }

    func testLegacyHistoryLocationIsUntouchedAcrossSessionsAndShutdownHooks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MetricsStore-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetricsStore(clock: { self.origin }, historyDirectory: directory)
        await store.prepareHistory()
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        let request = GenerationRequest(startedAt: origin)
        store.apply(.began(request))
        store.apply(.updated(requestID: request.id, snapshot: finalSnapshot(tokens: 12)))
        store.sample(at: origin.addingTimeInterval(1))
        store.beginBackendSession(kind: .vllm, epoch: UUID())
        await store.flushHistory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let fresh = MetricsStore(clock: { self.origin }, historyDirectory: directory)
        XCTAssertEqual(
            fresh.usageSummary(in: DateInterval(start: origin, duration: 10)).requests, 0)
        XCTAssertTrue(fresh.chartPresentation.throughput.isEmpty)
    }

    func testBackendSwitchDoesNotRestoreArchivedPresentationWhileHidden() {
        var now = origin
        let store = MetricsStore(clock: { now })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch, sourceID: "A")
        for index in 0...240 {
            now = origin.addingTimeInterval(Double(index) / 2)
            store.applyBackendSample(
                BackendSample(kind: .vllm, timestamp: now, currentTPS: 7, runningRequests: 1),
                epoch: epoch)
            store.sample()
        }
        store.setChartPresentationDemand(false, consumer: .dashboard)
        store.setChartPresentationDemand(false, consumer: .popover)
        now = now.addingTimeInterval(1)
        store.beginBackendSession(kind: .vllm, epoch: UUID(), sourceID: "B")
        now = now.addingTimeInterval(1)
        store.beginBackendSession(kind: .vllm, epoch: UUID(), sourceID: "A")
        XCTAssertEqual(store.chartPresentation.archive, .empty)
        XCTAssertTrue(store.chartPresentation.throughput.isEmpty)
        XCTAssertEqual(store.historyAge, now.timeIntervalSince(origin))
        store.setChartPresentationDemand(true, consumer: .dashboard)
        XCTAssertFalse(store.chartPresentation.archive.throughput.isEmpty)
        XCTAssertEqual(store.chartPresentation.archive.availableSince, origin)
    }

    func testScalarThroughputPeakMatchesInclusiveRawIntervalAndExcludesFutureSamples() {
        var now = origin
        let store = MetricsStore(clock: { now })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.setChartPresentationDemand(false, consumer: .dashboard)
        for index in 0..<80 {
            now = origin.addingTimeInterval(Double(index) / 2)
            store.applyBackendSample(
                BackendSample(
                    kind: .vllm, timestamp: now,
                    currentTPS: index.isMultiple(of: 7) ? nil : Double(index), runningRequests: 1),
                epoch: epoch)
            store.sample()
        }
        let intervals = [
            DateInterval(start: origin.addingTimeInterval(-10), end: origin.addingTimeInterval(-1)),
            DateInterval(start: origin, end: origin.addingTimeInterval(9.5)),
            DateInterval(start: origin.addingTimeInterval(10), end: origin.addingTimeInterval(15)),
            DateInterval(start: origin.addingTimeInterval(20), end: now),
        ]
        let samples = store.tpsHistory
        for interval in intervals {
            let expected = samples.filter {
                $0.timestamp >= interval.start && $0.timestamp <= interval.end
                    && $0.isAvailable && $0.value.isFinite && $0.value >= 0
            }.map(\.value).max()
            XCTAssertEqual(store.peakThroughput(in: interval), expected)
        }
    }

    private func finalSnapshot(tokens: Int) -> GenerationSnapshot {
        GenerationSnapshot(
            outputTokens: tokens, promptTokens: 3, isEstimated: false,
            liveTPS: 2, authoritativeTPS: 20, finished: true, elapsed: 1,
            timestamp: origin.addingTimeInterval(1))
    }
}
