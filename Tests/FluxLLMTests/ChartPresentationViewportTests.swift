import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class ChartPresentationViewportTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecentPopoverCopiesOnlyItsBinsAndPreservesFullHistoryOutput() {
        let store = makePopulatedStore()
        let full = store.chartPresentation
        store.setChartPresentationDemand(false, consumer: .dashboard)
        store.setChartPresentationDemand(true, consumer: .popover)
        let selected = store.chartPresentation
        XCTAssertEqual(store.throughputSampleCount, 7_201)
        XCTAssertLessThan(selected.throughput.count, 130)
        XCTAssertLessThan(selected.systemGPU.count, 130)
        XCTAssertLessThan(selected.toolObservation.count, 130)
        XCTAssertEqual(selected.throughput.first, full.throughput.first)
        XCTAssertLessThan(selected.historicalToolActivity.count, full.historicalToolActivity.count)
        assertEquivalent(
            selected, full, interval: DateInterval(start: date(3_540.5), end: date(3_600.5)))
    }

    func testPinnedWindowsAndEveryRangeMatchFullHistoryWithArchiveAndGaps() {
        let store = makePopulatedStore(archived: true)
        let full = store.chartPresentation
        store.setChartPresentationDemand(false, consumer: .dashboard)
        for duration in [1.0, 60, 75.25, 300, 302.3, 900, 1_800, 3_600, 21_600, 86_400] {
            for end in [3_600.5, 3_591.25, 60.5, 4.5, -60.25] {
                let interval = DateInterval(start: date(end - duration), end: date(end))
                // The navigation contract bounds all ranges to retained day.
                let bounded = ChartPresentationViewport.fixed(interval).interval(
                    at: full.timestamp, range: .custom, historyAge: store.historyAge)
                store.setChartPresentationViewport(.fixed(interval), consumer: .dashboard)
                store.setChartPresentationDemand(true, consumer: .dashboard)
                assertEquivalent(store.chartPresentation, full, interval: bounded)
            }
        }
    }

    func testFirstShowUsesSelectedPresetAndAutomaticGrowthRebuildsEnoughHistory() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.setChartPresentationDemand(false, consumer: .dashboard)
        for offset in stride(from: 0.5, through: 59.5, by: 0.5) {
            collect(store, epoch: epoch, offset: offset)
        }
        store.setChartPresentationDemand(true, consumer: .dashboard)
        XCTAssertEqual(store.chartHistoryDuration, 60)
        XCTAssertEqual(store.chartPresentation.throughput, store.tpsHistory)
        for offset in stride(from: 60.0, through: 61.5, by: 0.5) {
            collect(store, epoch: epoch, offset: offset)
        }
        XCTAssertEqual(store.chartHistoryDuration, 300)
        XCTAssertEqual(store.chartPresentation.throughput, store.tpsHistory)

        let populated = makePopulatedStore(archived: true)
        populated.historyRange = .minute
        populated.setChartPresentationDemand(false, consumer: .dashboard)
        populated.setChartPresentationDemand(true, consumer: .dashboard)
        XCTAssertLessThan(populated.chartPresentation.throughput.count, 130)
        XCTAssertEqual(populated.chartPresentation.archive, .empty)
        populated.historyRange = .hour
        XCTAssertGreaterThan(populated.chartPresentation.throughput.count, 7_000)
    }

    func testSimultaneousConsumersUnionTheirRangesThenReleaseHiddenDemand() {
        let store = makePopulatedStore()
        let full = store.chartPresentation
        let frozen = DateInterval(start: date(3_000), end: date(3_060))
        let live = DateInterval(start: date(3_540.5), end: full.timestamp)
        store.setChartPresentationDemand(false, consumer: .dashboard)
        store.setChartPresentationViewport(.fixed(frozen), consumer: .dashboard)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        let pinnedOnlyCount = store.chartPresentation.throughput.count
        store.setChartPresentationDemand(true, consumer: .popover)
        XCTAssertGreaterThan(store.chartPresentation.throughput.count, pinnedOnlyCount)
        XCTAssertLessThan(store.chartPresentation.throughput.count, 260)
        assertEquivalent(store.chartPresentation, full, interval: frozen)
        assertEquivalent(store.chartPresentation, full, interval: live)
        let prepared = PreparedDashboardCharts(
            snapshot: store.chartPresentation, duration: 60, windowEnd: frozen.end)
        XCTAssertFalse(
            prepared.requestTools.isEmpty,
            "Later tool events must preserve a known request's observed zero overlay")
        store.setChartPresentationDemand(false, consumer: .popover)
        XCTAssertEqual(store.chartPresentation.throughput.count, pinnedOnlyCount)
        assertEquivalent(store.chartPresentation, full, interval: frozen)

        store.setChartPresentationDemand(false, consumer: .dashboard)
        XCTAssertTrue(store.chartPresentation.throughput.isEmpty)
        let hiddenID = store.chartPresentation.publicationID
        store.sample(at: date(3_601))
        XCTAssertEqual(store.chartPresentation.publicationID, hiddenID)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        XCTAssertEqual(store.chartPresentation.timestamp, date(3_601))
        assertEquivalent(store.chartPresentation, full, interval: frozen)
    }

    func testLongRunningRequestDoesNotGainAnOverlayForToolsOutsideThePresentationDay() {
        let store = MetricsStore(clock: { self.origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        let request = GenerationRequest(model: "old-tool", startedAt: date(-100_000))
        store.apply(.began(request), epoch: epoch)
        store.apply(
            .toolActivity(
                requestID: request.id,
                events: [ToolActivityEvent(kind: .call, timestamp: date(-90_000))]), epoch: epoch)
        store.sample(at: origin)
        let full = store.chartPresentation
        store.setChartPresentationDemand(true, consumer: .dashboard)
        XCTAssertTrue(store.chartPresentation.toolActivityRequestIDs?.isEmpty == true)
        assertEquivalent(
            store.chartPresentation, full,
            interval: DateInterval(start: date(-60), end: origin))
    }

    func testNavigationDemandRetainsPinnedAndGoLiveWidthThenResumesAutomaticGrowth() {
        var navigation = HistoryNavigation()
        XCTAssertEqual(navigation.presentationViewport, .historyRange)
        navigation.pan(by: -1, now: date(60), historyAge: 60)
        let pinned = navigation.interval(now: date(61), historyAge: 61)
        XCTAssertEqual(navigation.presentationViewport, .fixed(pinned))
        navigation.goLive()
        XCTAssertEqual(navigation.presentationViewport, .live(duration: 60))
        XCTAssertEqual(
            navigation.presentationViewport.interval(
                at: date(300), range: .automatic, historyAge: 300),
            navigation.interval(now: date(300), historyAge: 300))
        navigation.selectPreset(.automatic, now: date(300), historyAge: 300)
        XCTAssertEqual(navigation.presentationViewport, .historyRange)
        XCTAssertEqual(
            navigation.presentationViewport.interval(
                at: date(301), range: .automatic, historyAge: 301
            ).duration, 900)
        navigation.select(DateInterval(start: date(200), end: date(245)), now: date(300))
        navigation.goLive()
        XCTAssertEqual(navigation.presentationViewport, .live(duration: 45))
    }

    private func makePopulatedStore(archived: Bool = false) -> MetricsStore {
        let archive = ChartHistoryArchive(now: origin)
        if archived {
            for offset in stride(from: -7_200.0, through: -0.5, by: 0.5) {
                let point = TimeSeriesPoint(
                    timestamp: date(offset), value: 15, isAvailable: Int(offset * 2) % 137 != 0)
                archive.record(
                    source: "fixture", at: point.timestamp, throughput: point, gpu: point,
                    toolObservation: point)
            }
        }
        let store = MetricsStore(clock: { self.origin }, chartArchive: archive)
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch, sourceID: "fixture")
        let request = GenerationRequest(model: "fixture", startedAt: date(-8_000))
        store.apply(.began(request), epoch: epoch)
        let events = stride(from: -7_199.0, through: 3_599, by: 11).enumerated().map {
            index, offset in
            ToolActivityEvent(
                kind: index % 3 == 0 ? .resultSubmission : .call,
                name: "tool-\(index % 3)", timestamp: date(offset))
        }
        store.apply(.toolActivity(requestID: request.id, events: events), epoch: epoch)
        let futureToolRequest = GenerationRequest(model: "future-tool", startedAt: date(3_000))
        store.apply(.began(futureToolRequest), epoch: epoch)
        store.apply(
            .toolActivity(
                requestID: futureToolRequest.id,
                events: [ToolActivityEvent(kind: .call, name: "later", timestamp: date(3_550))]),
            epoch: epoch)
        store.applyGPUSample(
            GPUActivitySample(timestamp: date(3_600.5), activityPercent: 35, scope: .system),
            epoch: epoch)
        let samples = (1...7_200).map { index in
            TimeSeriesPoint(
                timestamp: date(Double(index) / 2), value: Double(index % 97),
                isAvailable: index % 137 != 0)
        }
        store.restorePerformanceFixtureSamples(
            throughput: samples, gpu: samples, toolObservation: samples)
        store.sample(at: date(3_600.5))
        return store
    }

    private func collect(_ store: MetricsStore, epoch: UUID, offset: Double) {
        store.applyBackendSample(
            BackendSample(kind: .vllm, timestamp: date(offset), currentTPS: offset), epoch: epoch)
        store.applyGPUSample(
            GPUActivitySample(timestamp: date(offset), activityPercent: 30, scope: .system),
            epoch: epoch)
        store.sample(at: date(offset))
    }

    private func assertEquivalent(
        _ selected: ChartPresentationSnapshot, _ full: ChartPresentationSnapshot,
        interval: DateInterval, file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = PreparedDashboardCharts(
            snapshot: selected, duration: interval.duration, windowEnd: interval.end, isLive: false)
        let reference = PreparedDashboardCharts(
            snapshot: full, duration: interval.duration, windowEnd: interval.end, isLive: false)
        for (lhs, rhs) in [(actual.throughput, reference.throughput), (actual.gpu, reference.gpu)] {
            XCTAssertEqual(lhs.interval, rhs.interval, file: file, line: line)
            XCTAssertEqual(lhs.segments, rhs.segments, file: file, line: line)
            XCTAssertEqual(
                lhs.zeroFilledPlotSegments, rhs.zeroFilledPlotSegments, file: file, line: line)
            XCTAssertEqual(lhs.current, rhs.current, file: file, line: line)
            for fraction in [0.0, 0.001, 0.02, 0.25, 0.5, 0.99, 1.0] {
                let timestamp = interval.start.addingTimeInterval(interval.duration * fraction)
                XCTAssertEqual(
                    lhs.bucket(at: timestamp), rhs.bucket(at: timestamp), file: file, line: line)
            }
        }
        XCTAssertEqual(actual.lanes, reference.lanes, file: file, line: line)
        XCTAssertEqual(
            actual.toolActivity?.segments, reference.toolActivity?.segments, file: file, line: line)
        XCTAssertEqual(
            actual.toolActivity?.resultMarkers, reference.toolActivity?.resultMarkers, file: file,
            line: line)
        XCTAssertEqual(
            actual.toolActivity?.current, reference.toolActivity?.current, file: file, line: line)
        XCTAssertEqual(
            Set(actual.requestTools.keys), Set(reference.requestTools.keys), file: file, line: line)
        for (id, tools) in actual.requestTools {
            XCTAssertEqual(
                tools.segments, reference.requestTools[id]?.segments, file: file, line: line)
            XCTAssertEqual(
                tools.resultMarkers, reference.requestTools[id]?.resultMarkers, file: file,
                line: line)
        }
    }

    private func date(_ offset: Double) -> Date { origin.addingTimeInterval(offset) }
}
