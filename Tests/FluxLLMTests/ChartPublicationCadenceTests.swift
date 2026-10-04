import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class ChartPublicationCadenceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let interval: TimeInterval = 1

    func testHalfSecondSamplesPublishAtOneHertzWithoutChangingRawHistory() {
        let (store, epoch) = makeStore()
        var publications: [Date] = []
        var previousID: UUID?
        for index in 0...4 {
            let offset = Double(index) / 2
            collect(store, epoch: epoch, at: offset, rate: Double(index + 1) * 10)
            if store.chartPresentation.publicationID != previousID {
                publications.append(store.chartPresentation.timestamp)
                previousID = store.chartPresentation.publicationID
                XCTAssertEqual(store.chartPresentation.throughput, store.tpsHistory)
                XCTAssertEqual(store.chartPresentation.systemGPU, store.systemGPUHistory)
            }
        }
        XCTAssertEqual(publications, [0.0, 1, 2].map(date))
        XCTAssertEqual(store.tpsHistory.map(\.timestamp), [0.0, 0.5, 1, 1.5, 2].map(date))
        XCTAssertEqual(store.tpsHistory.map(\.value), [10, 20, 30, 40, 50])
        XCTAssertEqual(store.systemGPUHistory.map(\.value), [5, 10, 15, 20, 25])
    }

    func testEarlyRepeatedAndOlderSamplesCannotAdvancePublication() {
        let (store, epoch) = makeStore()
        collect(store, epoch: epoch, at: 0, rate: 10)
        let initial = store.chartPresentation
        for offset in [0, interval / 2, interval - 0.001] {
            store.sample(at: date(offset))
            XCTAssertEqual(store.chartPresentation.publicationID, initial.publicationID)
            XCTAssertEqual(store.chartPresentation.timestamp, origin)
        }
        store.sample(at: date(0))
        XCTAssertEqual(store.chartPresentation.publicationID, initial.publicationID)
        store.sample(at: date(interval))
        let next = store.chartPresentation
        XCTAssertNotEqual(next.publicationID, initial.publicationID)
        XCTAssertEqual(next.timestamp, date(interval))
        for offset in [interval, interval - 0.001, 2 * interval - 0.001] {
            store.sample(at: date(offset))
            XCTAssertEqual(store.chartPresentation.publicationID, next.publicationID)
        }
        store.sample(at: date(2 * interval))
        XCTAssertNotEqual(store.chartPresentation.publicationID, next.publicationID)
        XCTAssertEqual(store.chartPresentation.timestamp, date(2 * interval))
    }

    func testViewportAndReopeningForcePublicationAndResetTheDeadline() {
        let (store, epoch) = makeStore()
        collect(store, epoch: epoch, at: 0, rate: 10)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        let initialID = store.chartPresentation.publicationID
        collect(store, epoch: epoch, at: 0.125, rate: 20)
        XCTAssertEqual(store.chartPresentation.publicationID, initialID)

        store.setChartPresentationViewport(.live(duration: 120), consumer: .dashboard)
        XCTAssertNotEqual(store.chartPresentation.publicationID, initialID)
        XCTAssertEqual(store.chartPresentation.timestamp, date(0.125))
        XCTAssertEqual(store.chartPresentation.throughput.last?.value, 20)

        store.setChartPresentationDemand(false, consumer: .dashboard)
        let hiddenID = store.chartPresentation.publicationID
        collect(store, epoch: epoch, at: 0.25, rate: 30)
        XCTAssertEqual(store.chartPresentation.publicationID, hiddenID)
        XCTAssertTrue(store.chartPresentation.throughput.isEmpty)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        let reopened = store.chartPresentation
        XCTAssertNotEqual(reopened.publicationID, hiddenID)
        XCTAssertEqual(reopened.timestamp, date(0.25))
        XCTAssertEqual(reopened.throughput.last?.value, 30)

        store.sample(at: date(0.25 + interval - 0.001))
        XCTAssertEqual(store.chartPresentation.publicationID, reopened.publicationID)
        store.sample(at: date(0.25 + interval))
        XCTAssertNotEqual(store.chartPresentation.publicationID, reopened.publicationID)
        XCTAssertEqual(store.chartPresentation.timestamp, date(0.25 + interval))
    }

    func testBackendSessionResetStillPublishesItsFirstSampleImmediately() {
        var now = origin
        let store = MetricsStore(clock: { now })
        let firstEpoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: firstEpoch, sourceID: "first")
        collect(store, epoch: firstEpoch, at: 0, rate: 10)
        now = date(0.125)
        let nextEpoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: nextEpoch, sourceID: "second")
        let resetID = store.chartPresentation.publicationID
        collect(store, epoch: nextEpoch, at: 0.125, rate: 40)
        XCTAssertNotEqual(store.chartPresentation.publicationID, resetID)
        XCTAssertEqual(store.chartPresentation.timestamp, now)
        XCTAssertEqual(store.chartPresentation.throughput.map(\.value), [40])
    }

    private func makeStore() -> (MetricsStore, UUID) {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        return (store, epoch)
    }

    private func collect(_ store: MetricsStore, epoch: UUID, at offset: TimeInterval, rate: Double)
    {
        let timestamp = date(offset)
        store.applyBackendSample(
            BackendSample(kind: .vllm, timestamp: timestamp, currentTPS: rate, runningRequests: 1),
            epoch: epoch)
        store.applyGPUSample(
            GPUActivitySample(timestamp: timestamp, activityPercent: rate / 2, scope: .system),
            epoch: epoch)
        store.sample(at: timestamp)
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
}
