import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class SharedChartPublicationTests: XCTestCase {
    func testSharedPublicationPreservesSingleAndDisjointViewportQueriesAndReleasesMetadata() throws
    {
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
        defer { try? diagnostics.disable() }
        for pinned in [false, true] {
            store.setChartPresentationDemand(false, consumer: .dashboard)
            store.setChartPresentationDemand(false, consumer: .popover)
            store.setChartPresentationViewport(
                pinned
                    ? .fixed(DateInterval(start: now.addingTimeInterval(-420), duration: 60))
                    : .live(duration: 600), consumer: .dashboard)
            try diagnostics.enable(mode: .normal)
            store.setChartPresentationDemand(true, consumer: .dashboard)
            store.setChartPresentationDemand(true, consumer: .popover)
            let reference = store.chartPresentation
            XCTAssertNil(reference.sharedPreparationMetadata)
            store.setChartPresentationDemand(false, consumer: .dashboard)
            store.setChartPresentationDemand(false, consumer: .popover)
            try diagnostics.enable(mode: .runtimeSharedPreparation)
            store.setChartPresentationDemand(true, consumer: .dashboard)
            store.setChartPresentationDemand(true, consumer: .popover)
            XCTAssertEqual(store.chartPresentation, reference)
            XCTAssertEqual(
                store.chartPresentation.historicalToolActivity.map(\.requestID),
                reference.historicalToolActivity.map(\.requestID))
            XCTAssertEqual(
                Set(store.chartPresentation.historicalToolActivity.map(\.id)).count,
                store.chartPresentation.historicalToolActivity.count)
            weak var metadata = store.chartPresentation.sharedPreparationMetadata
            XCTAssertNotNil(metadata)
            store.setChartPresentationDemand(false, consumer: .dashboard)
            store.setChartPresentationDemand(false, consumer: .popover)
            XCTAssertNil(store.chartPresentation.sharedPreparationMetadata)
            XCTAssertNil(metadata)
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

    func testGPUSourceChangePreservesSharedRequestMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        try diagnostics.enable(mode: .runtimeSharedPreparation)
        defer { try? diagnostics.disable() }
        let store = MetricsStore(clock: { now })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: now, activityPercent: 20,
                source: "first", scope: .system), epoch: epoch)
        store.sample(at: now.addingTimeInterval(1))
        XCTAssertFalse(store.chartPresentation.systemGPU.isEmpty)
        let metadata = try XCTUnwrap(store.chartPresentation.sharedPreparationMetadata)
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: now.addingTimeInterval(1), activityPercent: 30,
                source: "second", scope: .system), epoch: epoch)
        XCTAssertTrue(store.chartPresentation.systemGPU.isEmpty)
        XCTAssertTrue(store.chartPresentation.sharedPreparationMetadata === metadata)
    }
}
