import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class LuminousChartGeometryCacheTests: XCTestCase {
    private typealias Cache = LuminousChartGeometryCache
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let publicationID = UUID()
    private let requestID = UUID()

    func testRepeatedPublicationRetainsTheSameProjectedFrame() {
        let cache = Cache()
        let key = key()
        let initial = frame(cache, key: key)
        // Reconstruct equivalent history values as a parent redraw can do.
        // The publication key, rather than array allocation, owns reuse.
        for _ in 0..<20 {
            XCTAssertTrue(frame(cache, key: key) === initial)
        }
    }

    func testEveryProjectionInputInvalidatesTheFrame() {
        let originalKey = key()
        let changes = [
            key(publicationID: UUID()), key(now: date(121)), key(duration: 75.25),
            key(size: CGSize(width: 641, height: 320)),
            key(size: CGSize(width: 640, height: 321)),
            key(compact: true), key(hasTools: false),
            key(tokenUpperBound: 250), key(toolUpperBound: 120),
        ]
        for changed in changes {
            let cache = Cache()
            let initial = frame(cache, key: originalKey)
            let replacement = frame(cache, key: changed)
            XCTAssertFalse(replacement === initial)
            XCTAssertEqual(replacement.key, changed)
            XCTAssertTrue(frame(cache, key: changed) === replacement)
        }
    }

    func testToolPlotStrategyChangesInvalidateAndUnchangedStrategyReusesTheFrame() {
        let cache = Cache()
        let key = key()
        let legacy = frame(cache, key: key)
        XCTAssertFalse(legacy.directToolPlot)
        XCTAssertTrue(frame(cache, key: key) === legacy)
        let direct = frame(cache, key: key, directToolPlot: true)
        XCTAssertTrue(direct.directToolPlot)
        XCTAssertFalse(direct === legacy)
        XCTAssertEqual(direct.key, legacy.key)
        XCTAssertTrue(frame(cache, key: key, directToolPlot: true) === direct)
        let restored = frame(cache, key: key)
        XCTAssertFalse(restored.directToolPlot)
        XCTAssertFalse(restored === direct)
        XCTAssertTrue(frame(cache, key: key) === restored)
    }

    func testToolPlotCountersCountActualBuildsRatherThanCacheLookups() {
        let counters = PerformancePresentationCounters.shared
        counters.enable()
        let cache = Cache()
        let key = key()
        let history = history()
        let tools = [requestID: toolHistory(), UUID(): toolHistory()]
        func build(_ direct: Bool) -> Cache.Frame {
            cache.frame(
                for: key, throughput: history, gpu: history,
                requestTools: tools, directToolPlot: direct)
        }
        let legacy = build(false)
        XCTAssertEqual(counters.snapshot()["legacy_tool_plot_builds"], 2)
        XCTAssertEqual(counters.snapshot()["direct_tool_plot_builds"], 0)
        for _ in 0..<5 { XCTAssertTrue(build(false) === legacy) }
        XCTAssertEqual(counters.snapshot()["legacy_tool_plot_builds"], 2)
        let direct = build(true)
        XCTAssertEqual(counters.snapshot()["legacy_tool_plot_builds"], 2)
        XCTAssertEqual(counters.snapshot()["direct_tool_plot_builds"], 2)
        for _ in 0..<5 { XCTAssertTrue(build(true) === direct) }
        XCTAssertEqual(counters.snapshot()["direct_tool_plot_builds"], 2)
        _ = Cache().frame(
            for: key, throughput: history, gpu: history, requestTools: [:], directToolPlot: true)
        XCTAssertEqual(
            counters.snapshot()["direct_tool_plot_builds"], 2,
            "A chart without request tool overlays has no tool plot builds")
        _ = build(false)
        XCTAssertEqual(counters.snapshot()["legacy_tool_plot_builds"], 4)
    }

    func testCacheRetainsOnlyOneFrameAndReleasesItWithItsOwner() {
        var cache: Cache? = Cache()
        weak var previous: Cache.Frame? = frame(cache!, key: key())
        XCTAssertNotNil(previous)
        weak var current: Cache.Frame? = frame(cache!, key: key(publicationID: UUID()))
        XCTAssertNil(previous)
        XCTAssertNotNil(current)
        cache = nil
        XCTAssertNil(current)
    }

    func testLegacyViewInputsGetFreshIdentityEvenWhenWindowAndPeakMatch() {
        let throughput = history()
        let originalGPU = ChartDisplayHistory(
            samples: [sample(119, 10), sample(120, 90)], now: date(120), duration: 60)
        let changedGPU = ChartDisplayHistory(
            samples: [sample(119, 80), sample(120, 90)], now: date(120), duration: 60)
        let first = LuminousActivityChart(
            throughput: throughput, gpu: originalGPU, tools: nil,
            now: date(120), duration: 60, compact: false)
        let changed = LuminousActivityChart(
            throughput: throughput, gpu: changedGPU, tools: nil,
            now: date(120), duration: 60, compact: false)
        XCTAssertEqual(originalGPU.peak, changedGPU.peak)
        XCTAssertNotEqual(first.geometryPublicationID, changed.geometryPublicationID)
        let cache = Cache()
        let original = cache.frame(
            for: key(publicationID: first.geometryPublicationID),
            throughput: throughput, gpu: originalGPU, requestTools: [:])
        let replacement = cache.frame(
            for: key(publicationID: changed.geometryPublicationID),
            throughput: throughput, gpu: changedGPU, requestTools: [:])
        XCTAssertFalse(original === replacement)
        XCTAssertNotEqual(original.device.map(\.points), replacement.device.map(\.points))

        let published = LuminousActivityChart(
            throughput: throughput, gpu: originalGPU, tools: nil,
            now: date(120), duration: 60, compact: false, publicationID: publicationID)
        XCTAssertEqual(published.geometryPublicationID, publicationID)
    }

    func testCachedPointsPathsAndMarkersMatchUncachedProjectionAcrossLayoutsAndRanges() throws {
        for compact in [false, true] {
            for hasTools in [false, true] {
                for duration in [60.0, 75.25, 300] {
                    let key = key(duration: duration, compact: compact, hasTools: hasTools)
                    let history = history(duration: duration)
                    let tools = toolHistory(duration: duration)
                    let frame = Cache().frame(
                        for: key, throughput: history, gpu: history,
                        requestTools: [requestID: tools])
                    assertEquivalent(
                        frame.generated, to: history.zeroFilledPlotSegments,
                        key: key, rect: frame.layout.main, upperBound: key.tokenUpperBound,
                        smoothed: true)
                    assertEquivalent(
                        frame.device, to: history.plotSegments,
                        key: key, rect: frame.layout.main, upperBound: 100, smoothed: true)
                    XCTAssertEqual(frame.generatedEndpoint, frame.generated.last?.points.last)
                    XCTAssertEqual(
                        frame.deviceEndpoint,
                        history.current.map {
                            project(
                                ChartDisplayPoint(timestamp: $0.timestamp, value: $0.value),
                                key: key, rect: frame.layout.main, upperBound: 100)
                        })
                    let track = try XCTUnwrap(frame.requestTools[requestID])
                    assertEquivalent(
                        track.segments, to: tools.zeroFilledPlotSegments,
                        key: key, rect: frame.layout.tools, upperBound: key.toolUpperBound,
                        smoothed: false)
                    let results = tools.resultMarkers.map {
                        project(
                            ChartDisplayPoint(timestamp: $0.timestamp, value: 0),
                            key: key, rect: frame.layout.tools, upperBound: 1)
                    }
                    XCTAssertEqual(track.resultPoints, results)
                    XCTAssertEqual(track.resultDiamonds.count, results.count)
                    for (diamond, point) in zip(track.resultDiamonds, results) {
                        var expected = Path()
                        expected.move(to: CGPoint(x: point.x, y: point.y - 3))
                        expected.addLine(to: CGPoint(x: point.x + 3, y: point.y))
                        expected.addLine(to: CGPoint(x: point.x, y: point.y + 3))
                        expected.addLine(to: CGPoint(x: point.x - 3, y: point.y))
                        expected.closeSubpath()
                        XCTAssertEqual(diamond, expected)
                    }
                }
            }
        }
    }

    func testDirectToolPlotsPreserveProjectedPointsPathsAndMarkersAcrossLayoutsAndRanges() throws {
        for compact in [false, true] {
            for hasTools in [false, true] {
                for size in [CGSize(width: 640, height: 320), CGSize(width: 401.5, height: 247.25)]
                {
                    for duration in [60.0, 75.25, 300] {
                        let key = key(
                            duration: duration, size: size, compact: compact, hasTools: hasTools)
                        let cache = Cache()
                        let history = history(duration: duration)
                        let tools = toolHistory(duration: duration)
                        let legacy = cache.frame(
                            for: key, throughput: history, gpu: history,
                            requestTools: [requestID: tools])
                        let direct = cache.frame(
                            for: key, throughput: history, gpu: history,
                            requestTools: [requestID: tools], directToolPlot: true)
                        XCTAssertFalse(direct === legacy)
                        let actual = try XCTUnwrap(direct.requestTools[requestID])
                        let expected = try XCTUnwrap(legacy.requestTools[requestID])
                        assertEquivalent(
                            actual.segments, to: tools.zeroFilledPlotSegments,
                            key: key, rect: direct.layout.tools,
                            upperBound: key.toolUpperBound, smoothed: false)
                        XCTAssertEqual(
                            actual.segments.map(\.points), expected.segments.map(\.points))
                        XCTAssertEqual(actual.segments.map(\.trace), expected.segments.map(\.trace))
                        XCTAssertEqual(actual.resultPoints, expected.resultPoints)
                        XCTAssertEqual(actual.resultDiamonds, expected.resultDiamonds)
                        XCTAssertEqual(direct.generated.map(\.trace), legacy.generated.map(\.trace))
                        XCTAssertEqual(direct.device.map(\.trace), legacy.device.map(\.trace))
                    }
                }
            }
        }
    }

    func testCachedInspectionPreservesVerticalStepsSingletonsAndGaps() {
        let points: [CGPoint] = [
            .init(x: 0, y: 20), .init(x: 2, y: 20), .init(x: 2, y: 80),
            .init(x: 4, y: 40), .init(x: 6, y: 40),
        ]
        let segment = Cache.Segment(points: points, smoothed: true, baseline: 100)
        XCTAssertEqual(segment.inspectedY(atX: 2), 80)
        XCTAssertEqual(segment.inspectedY(atX: 5), 40)
        XCTAssertNil(segment.inspectedY(atX: -0.1))
        XCTAssertNil(segment.inspectedY(atX: 6.1))
        XCTAssertNil(segment.inspectedY(atX: .nan))
        let singleton = Cache.Segment(
            points: [.init(x: 10, y: 50)], smoothed: true, baseline: 100)
        XCTAssertEqual(singleton.inspectedY(atX: 10), 50)
        XCTAssertNil(singleton.inspectedY(atX: 9.9))
        XCTAssertNil(singleton.area)
        let empty = Cache.Segment(points: [], smoothed: true, baseline: 100)
        XCTAssertTrue(empty.trace.isEmpty)
        XCTAssertNil(empty.area)
        XCTAssertNil(empty.inspectedY(atX: 0))
    }

    func testGPUWithoutFreshObservationHasNoCurrentMarker() {
        let key = key(now: date(130))
        let history = ChartDisplayHistory(samples: [sample(110, 40)], now: key.now, duration: 60)
        let frame = Cache().frame(for: key, throughput: history, gpu: history, requestTools: [:])
        XCTAssertNil(history.current)
        XCTAssertNil(frame.deviceEndpoint)
        XCTAssertFalse(frame.device.isEmpty)
    }

    private func assertEquivalent(
        _ actual: [Cache.Segment], to source: [[ChartDisplayPoint]],
        key: Cache.Key, rect: CGRect, upperBound: Double, smoothed: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = source.map { points in
            points.map { project($0, key: key, rect: rect, upperBound: upperBound) }
        }
        XCTAssertEqual(actual.map(\.points), expected, file: file, line: line)
        for (segment, points) in zip(actual, expected) {
            let trace = referencePath(points, smoothed: smoothed)
            XCTAssertEqual(segment.trace, trace, file: file, line: line)
            if smoothed, points.count > 1, let first = points.first, let last = points.last {
                var area = trace
                area.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                area.addLine(to: CGPoint(x: first.x, y: rect.maxY))
                area.closeSubpath()
                XCTAssertEqual(segment.area, area, file: file, line: line)
            } else {
                XCTAssertNil(segment.area, file: file, line: line)
            }
            if smoothed {
                let spans = ChartCurveGeometry.spans(points: points)
                XCTAssertEqual(segment.spans, spans, file: file, line: line)
                for x in stride(from: rect.minX - 1, through: rect.maxX + 1, by: 0.5) {
                    let expectedY =
                        points.count == 1 && points.first?.x == x
                        ? points.first?.y : ChartCurveGeometry.value(atX: x, spans: spans)
                    XCTAssertEqual(segment.inspectedY(atX: x), expectedY, file: file, line: line)
                }
            } else {
                XCTAssertTrue(segment.spans.isEmpty, file: file, line: line)
            }
        }
    }

    /// Reference rendering sequence from the original uncached chart.
    private func referencePath(_ points: [CGPoint], smoothed: Bool) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            if smoothed {
                for span in ChartCurveGeometry.spans(points: points) {
                    if span.isVertical {
                        path.addLine(to: span.end)
                    } else {
                        path.addCurve(
                            to: span.end, control1: span.control1, control2: span.control2)
                    }
                }
            } else {
                for point in points.dropFirst() { path.addLine(to: point) }
            }
        }
    }

    private func project(
        _ point: ChartDisplayPoint, key: Cache.Key, rect: CGRect, upperBound: Double
    ) -> CGPoint {
        let fraction = min(max(point.timestamp.timeIntervalSince(key.now) / key.duration + 1, 0), 1)
        return CGPoint(
            x: rect.minX + CGFloat(fraction) * rect.width,
            y: rect.maxY - CGFloat(min(max(point.value / upperBound, 0), 1)) * rect.height)
    }

    private func key(
        publicationID: UUID? = nil, now: Date? = nil, duration: TimeInterval = 60,
        size: CGSize = CGSize(width: 640, height: 320), compact: Bool = false,
        hasTools: Bool = true, tokenUpperBound: Double = 200, toolUpperBound: Double = 60
    ) -> Cache.Key {
        Cache.Key(
            publicationID: publicationID ?? self.publicationID, now: now ?? date(120),
            duration: duration, size: size, compact: compact, hasTools: hasTools,
            tokenUpperBound: tokenUpperBound, toolUpperBound: toolUpperBound)
    }

    private func frame(_ cache: Cache, key: Cache.Key, directToolPlot: Bool = false) -> Cache.Frame
    {
        cache.frame(
            for: key, throughput: history(), gpu: history(),
            requestTools: [requestID: toolHistory()], directToolPlot: directToolPlot)
    }

    private func history(duration: TimeInterval = 60) -> ChartDisplayHistory {
        ChartDisplayHistory(samples: observations, now: date(120), duration: duration)
    }

    private func toolHistory(duration: TimeInterval = 60) -> ToolActivityHistory {
        ToolActivityHistory(
            events: [
                ToolActivityEvent(kind: .call, timestamp: date(73), requestID: requestID),
                ToolActivityEvent(kind: .call, timestamp: date(119.5), requestID: requestID),
                ToolActivityEvent(
                    kind: .resultSubmission, timestamp: date(119.75), requestID: requestID),
            ], observations: observations, now: date(120), duration: duration)
    }

    private var observations: [TimeSeriesPoint] {
        [
            sample(0, 0), sample(40, 250), sample(45, 20), sample(72, 0), sample(73, 45),
            sample(74, 10, available: false), sample(90, 80), sample(119, 40), sample(120, 100),
        ]
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }

    private func sample(_ offset: TimeInterval, _ value: Double, available: Bool = true)
        -> TimeSeriesPoint
    {
        TimeSeriesPoint(timestamp: date(offset), value: value, isAvailable: available)
    }
}
