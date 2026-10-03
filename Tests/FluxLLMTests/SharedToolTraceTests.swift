import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class SharedToolTraceTests: XCTestCase {
    private typealias Cache = LuminousChartGeometryCache
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testEqualRatesShareGeometryWithoutSharingRequestMetadataOrResultMarkers() throws {
        let observation = observation()
        let firstID = UUID()
        let secondID = UUID()
        let first = history(
            [
                call(1.2, request: firstID, name: "search"),
                result(2, request: firstID), call(4.2, request: firstID, name: "read"),
            ], observation: observation)
        let second = history(
            [
                call(1.8, request: secondID, name: "write"),
                call(4.8, request: secondID, name: "list"), result(9, request: secondID),
            ], observation: observation)
        XCTAssertEqual(try XCTUnwrap(first.reusablePlotKey), try XCTUnwrap(second.reusablePlotKey))
        XCTAssertNotEqual(first.buckets.map(\.toolNames), second.buckets.map(\.toolNames))

        PerformancePresentationCounters.shared.enable()
        let tracks = frame([firstID: first, secondID: second]).requestTools
        assertBuilds(unique: 1, reused: 1)
        let firstTrack = try XCTUnwrap(tracks[firstID])
        let secondTrack = try XCTUnwrap(tracks[secondID])
        XCTAssertEqual(firstTrack.segments.map(\.points), secondTrack.segments.map(\.points))
        XCTAssertEqual(firstTrack.segments.map(\.trace), secondTrack.segments.map(\.trace))
        XCTAssertEqual(firstTrack.resultPoints.count, 1)
        XCTAssertEqual(secondTrack.resultPoints.count, 1)
        XCTAssertNotEqual(firstTrack.resultPoints, secondTrack.resultPoints)
        XCTAssertNotEqual(firstTrack.resultDiamonds, secondTrack.resultDiamonds)
        XCTAssertEqual(first.resultMarkers.map(\.requestID), [firstID])
        XCTAssertEqual(second.resultMarkers.map(\.requestID), [secondID])
    }

    func testChangedBucketCountsAndPositiveBucketPositionsCannotShareTraces() throws {
        let observation = observation()
        let histories = [
            history([call(1)], observation: observation),
            history([call(1), call(2)], observation: observation),
            history([call(4)], observation: observation),
        ]
        let keys = try histories.map { try XCTUnwrap($0.reusablePlotKey) }
        XCTAssertEqual(Set(keys).count, histories.count)
        let tools = Dictionary(uniqueKeysWithValues: histories.map { (UUID(), $0) })
        PerformancePresentationCounters.shared.enable()
        let tracks = frame(tools).requestTools
        assertBuilds(unique: 3, reused: 0)
        let projected = tracks.values.map { $0.segments.map(\.points) }
        for first in projected.indices {
            for second in projected.indices where first < second {
                XCTAssertNotEqual(projected[first], projected[second])
            }
        }
    }

    func testObservationCopiesShareIdentityButIndependentCoverageAndWindowsDoNot() throws {
        let original = observation()
        let copy = original
        let events = [call(1), call(9)]
        let first = history(events, observation: original)
        let copied = history(events, observation: copy)
        XCTAssertEqual(try XCTUnwrap(first.reusablePlotKey), try XCTUnwrap(copied.reusablePlotKey))
        let differentBases = [
            observation(),
            observation(samples: samples(0.5, through: 12.5)),
            observation(samples: samples(0, through: 5) + samples(11, through: 12.5)),
            observation(now: 13.5),
            observation(duration: 75.25),
        ]
        // Use no calls for the gap fixture: pending evidence has a separate test.
        let emptyFirst = history([], observation: original)
        let emptyHistories = differentBases.map { history([], observation: $0) }
        for changed in emptyHistories {
            XCTAssertNotEqual(
                try XCTUnwrap(emptyFirst.reusablePlotKey), try XCTUnwrap(changed.reusablePlotKey))
        }
        var tools = Dictionary(uniqueKeysWithValues: emptyHistories.map { (UUID(), $0) })
        tools[UUID()] = emptyFirst
        tools[UUID()] = history([], observation: copy)
        PerformancePresentationCounters.shared.enable()
        _ = frame(tools).requestTools
        assertBuilds(unique: 6, reused: 1)
    }

    func testCurrentTailStatePreventsReuseAfterTerminalInstantaneousCall() throws {
        let observation = observation(samples: samples(0, through: 6), now: 6.5)
        let extending = history([call(4)], observation: observation)
        let stopped = history([call(4), call(6)], observation: observation)
        let moreInstantaneousCalls = history([call(4), call(6), call(6)], observation: observation)
        XCTAssertNotNil(extending.current)
        XCTAssertNil(stopped.current)
        XCTAssertEqual(
            try XCTUnwrap(extending.reusablePlotKey).nonzeroBuckets,
            try XCTUnwrap(stopped.reusablePlotKey).nonzeroBuckets)
        XCTAssertNotEqual(extending.reusablePlotKey, stopped.reusablePlotKey)
        XCTAssertNotEqual(extending.zeroFilledPlotSegments, stopped.zeroFilledPlotSegments)
        XCTAssertEqual(stopped.reusablePlotKey, moreInstantaneousCalls.reusablePlotKey)
        XCTAssertEqual(
            stopped.zeroFilledPlotSegments, moreInstantaneousCalls.zeroFilledPlotSegments)
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let expectedStopped = try XCTUnwrap(
            frame([secondID: stopped], key: key(now: 6.5)).requestTools[secondID])
        PerformancePresentationCounters.shared.enable()
        let tracks = frame(
            [firstID: extending, secondID: stopped, thirdID: moreInstantaneousCalls],
            key: key(now: 6.5)
        ).requestTools
        assertBuilds(unique: 2, reused: 1)
        XCTAssertNotEqual(
            tracks[firstID]?.segments.map(\.trace), tracks[secondID]?.segments.map(\.trace))
        assertEqual(try XCTUnwrap(tracks[secondID]), expectedStopped)
        assertEqual(try XCTUnwrap(tracks[thirdID]), expectedStopped)
    }

    func testPendingAndInvalidHistoriesAlwaysUseIndependentConstruction() {
        let observation = observation(samples: samples(0, through: 6), now: 6.5)
        let pending = history([call(4), call(6.25)], observation: observation)
        let gapObservation = self.observation(
            samples: samples(0, through: 1) + samples(10, through: 12.5))
        let gap = history([call(5)], observation: gapObservation)
        let invalid = history([], observation: self.observation(duration: 0))
        XCTAssertNil(pending.reusablePlotKey)
        XCTAssertNil(gap.reusablePlotKey)
        XCTAssertNil(invalid.reusablePlotKey)
        let tools = [
            UUID(): pending, UUID(): pending, UUID(): gap, UUID(): gap,
            UUID(): invalid, UUID(): invalid,
        ]
        PerformancePresentationCounters.shared.enable()
        XCTAssertEqual(frame(tools).requestTools.count, 6)
        assertBuilds(unique: 6, reused: 0)
    }

    func testAllZeroHistoriesShareWhileResultMarkersStayIndependent() throws {
        let observation = observation()
        let noEvents = history([], observation: observation)
        let resultOnly = history([result(4)], observation: observation)
        XCTAssertEqual(
            try XCTUnwrap(noEvents.reusablePlotKey), try XCTUnwrap(resultOnly.reusablePlotKey))
        let emptyID = UUID()
        let resultID = UUID()
        PerformancePresentationCounters.shared.enable()
        let tracks = frame([emptyID: noEvents, resultID: resultOnly]).requestTools
        assertBuilds(unique: 1, reused: 1)
        XCTAssertEqual(
            tracks[emptyID]?.segments.map(\.trace), tracks[resultID]?.segments.map(\.trace))
        XCTAssertEqual(tracks[emptyID]?.resultPoints.count, 0)
        XCTAssertEqual(tracks[resultID]?.resultPoints.count, 1)
    }

    func testSharedTracksMatchIndependentConstructionForEveryDrawingStrategy() throws {
        let observation = observation()
        let firstID = UUID()
        let secondID = UUID()
        let first = history([call(1), call(4), call(4.5), result(2)], observation: observation)
        let second = history([call(2), call(3.5), call(5), result(9)], observation: observation)
        for direct in [false, true] {
            for compact in [false, true] {
                for deferred in [false, true] {
                    let expectedFirst = try XCTUnwrap(
                        frame(
                            [firstID: first], direct: direct, compact: compact
                        ).requestTools[firstID])
                    let expectedSecond = try XCTUnwrap(
                        frame(
                            [secondID: second], direct: direct, compact: compact
                        ).requestTools[secondID])
                    PerformancePresentationCounters.shared.enable()
                    let combined = frame(
                        [firstID: first, secondID: second], direct: direct, compact: compact,
                        deferred: deferred)
                    assertBuilds(unique: deferred ? 0 : 1, reused: deferred ? 0 : 1)
                    let tracks = combined.requestTools
                    assertBuilds(unique: 1, reused: 1)
                    assertEqual(try XCTUnwrap(tracks[firstID]), expectedFirst)
                    assertEqual(try XCTUnwrap(tracks[secondID]), expectedSecond)
                    // Overlay work counters continue to describe all drawn paths,
                    // even though their immutable geometry was constructed once.
                    let counters = PerformancePresentationCounters.shared.snapshot()
                    XCTAssertEqual(
                        counters[direct ? "direct_tool_plot_builds" : "legacy_tool_plot_builds"], 2)
                    XCTAssertEqual(
                        counters["tool_path_input_points"],
                        UInt64(
                            tracks.values.reduce(0) {
                                $0 + $1.segments.reduce(0) { $0 + $1.points.count }
                            }))
                    XCTAssertEqual(
                        counters["tool_path_output_points"],
                        UInt64(
                            tracks.values.reduce(0) {
                                $0 + $1.segments.reduce(0) { $0 + $1.tracePointCount }
                            }))
                    for _ in 0..<3 { _ = combined.requestTools }
                    XCTAssertEqual(PerformancePresentationCounters.shared.snapshot(), counters)
                }
            }
        }
    }

    func testDeferredFrameBuildsOnlyWhenReadAndNewProjectionOwnsNewSharedGeometry() throws {
        let observation = observation()
        let firstID = UUID()
        let secondID = UUID()
        let tools = [
            firstID: history([call(1)], observation: observation),
            secondID: history([call(2)], observation: observation),
        ]
        let cache = Cache()
        let chart = chartHistory()
        let projection = key()
        func deferred(_ key: Cache.Key) -> Cache.Frame {
            cache.frame(
                for: key, throughput: chart, gpu: chart, requestTools: tools,
                deferredToolGeometry: true)
        }
        PerformancePresentationCounters.shared.enable()
        let initial = deferred(projection)
        XCTAssertTrue(deferred(projection) === initial)
        assertBuilds(unique: 0, reused: 0)
        let initialTrack = try XCTUnwrap(initial.requestTools[firstID])
        assertBuilds(unique: 1, reused: 1)
        for changed in [
            key(size: CGSize(width: 801, height: 420)), key(toolUpperBound: 120),
            key(now: 14), key(duration: 75.25),
        ] {
            PerformancePresentationCounters.shared.enable()
            let replacement = deferred(changed)
            XCTAssertFalse(replacement === initial)
            assertBuilds(unique: 0, reused: 0)
            let track = try XCTUnwrap(replacement.requestTools[firstID])
            assertBuilds(unique: 1, reused: 1)
            XCTAssertNotEqual(track.segments.map(\.points), initialTrack.segments.map(\.points))
            let independent = try XCTUnwrap(
                frame([firstID: tools[firstID]!], key: changed).requestTools[firstID])
            assertEqual(track, independent)
        }
    }

    private func assertBuilds(
        unique: UInt64, reused: UInt64, file: StaticString = #filePath, line: UInt = #line
    ) {
        let counters = PerformancePresentationCounters.shared.snapshot()
        XCTAssertEqual(counters["unique_tool_trace_builds"], unique, file: file, line: line)
        XCTAssertEqual(counters["reused_tool_trace_builds"], reused, file: file, line: line)
    }

    private func assertEqual(
        _ actual: Cache.ToolTrack, _ expected: Cache.ToolTrack,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.segments.map(\.points), expected.segments.map(\.points), file: file, line: line)
        XCTAssertEqual(
            actual.segments.map(\.trace), expected.segments.map(\.trace), file: file, line: line)
        XCTAssertEqual(
            actual.segments.map(\.tracePointCount), expected.segments.map(\.tracePointCount),
            file: file, line: line)
        XCTAssertEqual(
            actual.segments.map(\.spans), expected.segments.map(\.spans), file: file, line: line)
        XCTAssertEqual(
            actual.segments.map(\.area), expected.segments.map(\.area), file: file, line: line)
        XCTAssertEqual(actual.resultPoints, expected.resultPoints, file: file, line: line)
        XCTAssertEqual(actual.resultDiamonds, expected.resultDiamonds, file: file, line: line)
    }

    private func frame(
        _ tools: [UUID: ToolActivityHistory], key: Cache.Key? = nil,
        direct: Bool = false, compact: Bool = false, deferred: Bool = false
    ) -> Cache.Frame {
        let history = chartHistory()
        return Cache().frame(
            for: key ?? self.key(), throughput: history, gpu: history, requestTools: tools,
            directToolPlot: direct, compactToolPaths: compact, deferredToolGeometry: deferred)
    }

    private func key(
        now: TimeInterval = 13, duration: TimeInterval = 60,
        size: CGSize = CGSize(width: 640, height: 320), toolUpperBound: Double = 60
    ) -> Cache.Key {
        Cache.Key(
            publicationID: UUID(), now: date(now), duration: duration, size: size,
            compact: false, hasTools: true, tokenUpperBound: 200, toolUpperBound: toolUpperBound)
    }

    private func chartHistory() -> ChartDisplayHistory {
        ChartDisplayHistory(samples: samples(0, through: 12.5), now: date(13), duration: 60)
    }

    private func observation(
        samples: [TimeSeriesPoint]? = nil, now: TimeInterval = 13, duration: TimeInterval = 60
    ) -> ToolActivityObservation {
        ToolActivityObservation(
            observations: samples ?? self.samples(0, through: 12.5),
            now: date(now), duration: duration)
    }

    private func history(
        _ events: [ToolActivityEvent], observation: ToolActivityObservation
    ) -> ToolActivityHistory {
        ToolActivityHistory(
            preparedEvents: ToolActivityHistory.normalizedEvents(events, through: observation.now),
            observation: observation)
    }

    private func call(_ offset: TimeInterval, request: UUID = UUID(), name: String? = nil)
        -> ToolActivityEvent
    {
        ToolActivityEvent(
            kind: .call, name: name, callID: UUID().uuidString,
            timestamp: date(offset), requestID: request)
    }

    private func result(_ offset: TimeInterval, request: UUID = UUID()) -> ToolActivityEvent {
        ToolActivityEvent(kind: .resultSubmission, timestamp: date(offset), requestID: request)
    }

    private func samples(_ start: TimeInterval, through end: TimeInterval) -> [TimeSeriesPoint] {
        stride(from: start, through: end, by: 0.5).map {
            TimeSeriesPoint(timestamp: date($0), value: 1)
        }
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
}
