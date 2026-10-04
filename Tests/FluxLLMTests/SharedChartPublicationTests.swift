import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class SharedChartPublicationTests: XCTestCase {
    func testOrderedPublicationsPreserveSingleAndDisjointQueriesAndWinnerOwnership() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MetricsStore(clock: { now })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.setChartPresentationDemand(false, consumer: .dashboard)
        let reusedEventID = UUID()
        for index in 0..<6 {
            let start = now.addingTimeInterval(Double(index * 80 - 480))
            let request = GenerationRequest(model: "publication-test", startedAt: start)
            store.apply(.began(request), epoch: epoch)
            store.apply(
                .toolActivity(
                    requestID: request.id,
                    events: [
                        ToolActivityEvent(id: UUID(), kind: .call, name: "first", timestamp: start),
                        ToolActivityEvent(id: UUID(), kind: .call, name: "tied", timestamp: start),
                        ToolActivityEvent(
                            id: reusedEventID, kind: .call, name: "reused-id",
                            callID: "call-\(index)", timestamp: start),
                    ]), epoch: epoch)
            store.apply(.cancelled(requestID: request.id), epoch: epoch)
        }
        store.sample(at: now)
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        let counters = PerformancePresentationCounters.shared
        counters.enable()
        try diagnostics.enable(mode: .normal)
        defer { try? diagnostics.disable() }
        for pinned in [false, true] {
            store.setChartPresentationDemand(false, consumer: .dashboard)
            store.setChartPresentationDemand(false, consumer: .popover)
            store.setChartPresentationViewport(
                pinned
                    ? .fixed(DateInterval(start: now.addingTimeInterval(-420), duration: 60))
                    : .live(duration: 600), consumer: .dashboard)
            store.setChartPresentationDemand(true, consumer: .dashboard)
            let before = counters.snapshot()
            store.setChartPresentationDemand(true, consumer: .popover)
            assertQueryWork(since: before, fastQueries: pinned ? 0 : 2, fullSorts: pinned ? 2 : 0)
            let published = store.chartPresentation
            XCTAssertEqual(
                Set(published.historicalToolActivity.map(\.id)).count,
                published.historicalToolActivity.count)
            let winner = try XCTUnwrap(
                published.historicalToolActivity.first { $0.id == reusedEventID })
            XCTAssertEqual(winner.timestamp, now.addingTimeInterval(pinned ? -400 : -80))
            XCTAssertEqual(winner.name, "reused-id")
            XCTAssertNotNil(winner.requestID)
            store.setChartPresentationDemand(false, consumer: .dashboard)
            store.setChartPresentationDemand(false, consumer: .popover)
        }
    }

    func testEqualTimeHistoryEventsKeepCanonicalPublicationOrder() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ id: Int, _ second: Double) -> ToolActivityEvent {
            ToolActivityEvent(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
                kind: .call, timestamp: start.addingTimeInterval(second))
        }
        let ordered = [event(9, 0), event(8, 1), event(2, 1), event(5, 1), event(1, 2)]
        XCTAssertEqual(
            MetricsStore.canonicalToolEvents(ordered),
            [event(9, 0), event(2, 1), event(5, 1), event(8, 1), event(1, 2)])
        XCTAssertEqual(MetricsStore.canonicalToolEvents([]), [])
    }

    func testCanonicalOrderedEventsKeepLastReusedUUIDIncludingKindAndOwner() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reused = UUID()
        let firstOwner = UUID()
        let lastOwner = UUID()
        let first = ToolActivityEvent(
            id: reused, kind: .call, name: "old", timestamp: start, requestID: firstOwner)
        let other = ToolActivityEvent(
            kind: .call, name: "distinct", timestamp: start.addingTimeInterval(1),
            requestID: firstOwner)
        let winner = ToolActivityEvent(
            id: reused, kind: .resultSubmission, name: "corrected",
            timestamp: start.addingTimeInterval(2), requestID: lastOwner)
        let canonical = MetricsStore.canonicalToolEvents([first, other, winner])
        XCTAssertEqual(canonical, [other, winner])
        XCTAssertEqual(canonical.map(\.requestID), [firstOwner, lastOwner])
        XCTAssertEqual(canonical.last?.kind, .resultSubmission)
    }

    func testGPUSourceChangeClearsGPUHistoryWithoutChangingRequestPublication() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        try diagnostics.enable(mode: .normal)
        defer { try? diagnostics.disable() }
        let store = MetricsStore(clock: { now })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        let request = GenerationRequest(
            model: "GPU reset request", startedAt: now.addingTimeInterval(-1))
        store.apply(.began(request), epoch: epoch)
        store.apply(
            .toolActivity(
                requestID: request.id,
                events: [
                    ToolActivityEvent(
                        kind: .call, name: "preserved", timestamp: now.addingTimeInterval(-0.5))
                ]), epoch: epoch)
        store.apply(.cancelled(requestID: request.id), epoch: epoch)
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: now, activityPercent: 20,
                source: "first", scope: .system), epoch: epoch)
        store.sample(at: now.addingTimeInterval(1))
        XCTAssertFalse(store.chartPresentation.systemGPU.isEmpty)
        let before = store.chartPresentation
        XCTAssertFalse(before.requestLanes.isEmpty)
        XCTAssertFalse(before.toolActivity.isEmpty)
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: now.addingTimeInterval(1), activityPercent: 30,
                source: "second", scope: .system), epoch: epoch)
        XCTAssertTrue(store.chartPresentation.systemGPU.isEmpty)
        XCTAssertEqual(store.chartPresentation.requestLanes, before.requestLanes)
        XCTAssertEqual(
            store.chartPresentation.historicalRequestLanes, before.historicalRequestLanes)
        XCTAssertEqual(store.chartPresentation.toolActivity, before.toolActivity)
        XCTAssertEqual(
            store.chartPresentation.historicalToolActivity, before.historicalToolActivity)
        XCTAssertEqual(
            store.chartPresentation.toolActivityRequestIDs, before.toolActivityRequestIDs)
    }

    private func assertQueryWork(
        since before: [String: UInt64], fastQueries: UInt64, fullSorts: UInt64,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let after = PerformancePresentationCounters.shared.snapshot()
        XCTAssertEqual(
            after["ordered_chart_publication_queries", default: 0]
                - before["ordered_chart_publication_queries", default: 0],
            fastQueries, file: file, line: line)
        XCTAssertEqual(
            after["chart_publication_full_sorts", default: 0]
                - before["chart_publication_full_sorts", default: 0],
            fullSorts, file: file, line: line)
    }
}
