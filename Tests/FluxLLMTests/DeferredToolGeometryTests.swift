import Dispatch
import Foundation
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class DeferredToolGeometryTests: XCTestCase {
    private typealias Cache = LuminousChartGeometryCache
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let requestID = UUID()
    private let counterKeys = [
        "legacy_tool_plot_builds", "direct_tool_plot_builds",
        "tool_path_input_points", "tool_path_output_points",
    ]

    func testUnusedDeferredFramesDoNoToolWorkAndReleaseAfterReplacementAndOwnerRelease() {
        let counters = PerformancePresentationCounters.shared
        counters.enable()
        var cache: Cache? = Cache()
        let history = history()
        let tools = [requestID: toolHistory()]
        weak var discarded: Cache.Frame?
        do {
            let frame = cache!.frame(
                for: key(), throughput: history, gpu: history, requestTools: tools,
                deferredToolGeometry: true)
            discarded = frame
            XCTAssertTrue(frame.deferredToolGeometry)
            XCTAssertFalse(frame.generated.isEmpty)
            XCTAssertFalse(frame.device.isEmpty)
            XCTAssertNotNil(frame.generatedEndpoint)
        }
        XCTAssertNotNil(discarded, "The cache still owns its current frame")
        assertNoToolWork()
        weak var replacement: Cache.Frame?
        do {
            let frame = cache!.frame(
                for: key(), throughput: history, gpu: history, requestTools: tools,
                directToolPlot: true, compactToolPaths: true, deferredToolGeometry: true)
            replacement = frame
        }
        XCTAssertNil(discarded, "The deferred factory must not retain its owning frame")
        XCTAssertNotNil(replacement)
        assertNoToolWork()
        cache = nil
        XCTAssertNil(replacement)
        assertNoToolWork()
    }

    func testFirstAccessBuildsOnceAndCacheHitsNeitherForceNorRepeatConstruction() {
        let counters = PerformancePresentationCounters.shared
        let history = history()
        let tools = [requestID: toolHistory(), UUID(): toolHistory()]
        for direct in [false, true] {
            counters.enable()
            let cache = Cache()
            let key = key()
            func frame() -> Cache.Frame {
                cache.frame(
                    for: key, throughput: history, gpu: history, requestTools: tools,
                    directToolPlot: direct, compactToolPaths: true, deferredToolGeometry: true)
            }
            let deferred = frame()
            for _ in 0..<5 { XCTAssertTrue(frame() === deferred) }
            assertNoToolWork()
            let tracks = deferred.requestTools
            XCTAssertEqual(tracks.count, tools.count)
            let afterFirstAccess = counters.snapshot()
            XCTAssertEqual(
                afterFirstAccess[direct ? "direct_tool_plot_builds" : "legacy_tool_plot_builds"], 2)
            XCTAssertEqual(
                afterFirstAccess[direct ? "legacy_tool_plot_builds" : "direct_tool_plot_builds"], 0)
            XCTAssertGreaterThan(afterFirstAccess["tool_path_input_points"] ?? 0, 0)
            XCTAssertGreaterThan(afterFirstAccess["tool_path_output_points"] ?? 0, 0)
            XCTAssertLessThan(
                afterFirstAccess["tool_path_output_points"] ?? 0,
                afterFirstAccess["tool_path_input_points"] ?? 0)
            for _ in 0..<5 {
                let cached = frame()
                XCTAssertTrue(cached === deferred)
                XCTAssertEqual(
                    cached.requestTools[requestID]?.resultPoints, tracks[requestID]?.resultPoints)
                XCTAssertEqual(
                    cached.requestTools[requestID]?.segments.map(\.trace),
                    tracks[requestID]?.segments.map(\.trace))
            }
            assertToolCountersEqual(counters.snapshot(), afterFirstAccess)
        }
    }

    func testEagerDefaultBuildsImmediatelyAndDeferralChangesFrameIdentity() {
        let counters = PerformancePresentationCounters.shared
        counters.enable()
        let cache = Cache()
        let key = key()
        let history = history()
        let tools = [requestID: toolHistory()]
        let eager = cache.frame(for: key, throughput: history, gpu: history, requestTools: tools)
        XCTAssertFalse(eager.deferredToolGeometry)
        XCTAssertEqual(counters.snapshot()["legacy_tool_plot_builds"], 1)
        XCTAssertGreaterThan(counters.snapshot()["tool_path_input_points"] ?? 0, 0)
        XCTAssertTrue(
            cache.frame(for: key, throughput: history, gpu: history, requestTools: tools) === eager)
        let afterEager = counters.snapshot()
        let deferred = cache.frame(
            for: key, throughput: history, gpu: history, requestTools: tools,
            deferredToolGeometry: true)
        XCTAssertTrue(deferred.deferredToolGeometry)
        XCTAssertFalse(deferred === eager)
        XCTAssertEqual(deferred.key, eager.key)
        XCTAssertTrue(
            cache.frame(
                for: key, throughput: history, gpu: history, requestTools: tools,
                deferredToolGeometry: true) === deferred)
        assertToolCountersEqual(counters.snapshot(), afterEager)
        let restored = cache.frame(for: key, throughput: history, gpu: history, requestTools: tools)
        XCTAssertFalse(restored.deferredToolGeometry)
        XCTAssertFalse(restored === deferred)
        XCTAssertEqual(counters.snapshot()["legacy_tool_plot_builds"], 2)
    }

    func testDeferredAndEagerGeometryMatchAcrossDirectAndCompactStrategies() throws {
        let history = history()
        let tools = [requestID: toolHistory()]
        for direct in [false, true] {
            for compact in [false, true] {
                let key = key()
                let cache = Cache()
                let eager = cache.frame(
                    for: key, throughput: history, gpu: history, requestTools: tools,
                    directToolPlot: direct, compactToolPaths: compact)
                let deferred = cache.frame(
                    for: key, throughput: history, gpu: history, requestTools: tools,
                    directToolPlot: direct, compactToolPaths: compact, deferredToolGeometry: true)
                XCTAssertEqual(deferred.directToolPlot, direct)
                XCTAssertEqual(deferred.compactToolPaths, compact)
                XCTAssertEqual(deferred.generated.map(\.trace), eager.generated.map(\.trace))
                XCTAssertEqual(deferred.device.map(\.trace), eager.device.map(\.trace))
                XCTAssertEqual(deferred.generatedEndpoint, eager.generatedEndpoint)
                XCTAssertEqual(deferred.deviceEndpoint, eager.deviceEndpoint)
                let expected = try XCTUnwrap(eager.requestTools[requestID])
                let actual = try XCTUnwrap(deferred.requestTools[requestID])
                assertEqual(actual, expected)
                XCTAssertFalse(actual.resultPoints.isEmpty)
                XCTAssertTrue(
                    actual.segments.contains { segment in
                        zip(segment.points, segment.points.dropFirst()).contains { pair in
                            pair.0.x == pair.1.x && pair.0.y != pair.1.y
                        }
                    }, "The fixture must exercise vertical rate transitions")
            }
        }
    }

    func testDeferredFactoryFreezesCallerDictionaryAndOriginalHistoryValues() throws {
        let key = key()
        let history = history()
        var tools = [requestID: toolHistory()]
        let expectedFrame = Cache().frame(
            for: key, throughput: history, gpu: history, requestTools: tools)
        let deferred = Cache().frame(
            for: key, throughput: history, gpu: history, requestTools: tools,
            deferredToolGeometry: true)
        tools[requestID] = ToolActivityHistory(
            events: [], observations: [], now: date(20), duration: 20)
        let laterRequestID = UUID()
        tools[laterRequestID] = toolHistory()
        XCTAssertEqual(tools.count, 2)
        let actualTracks = deferred.requestTools
        XCTAssertEqual(Set(actualTracks.keys), Set([requestID]))
        XCTAssertNil(actualTracks[laterRequestID])
        let actual = try XCTUnwrap(actualTracks[requestID])
        let expected = try XCTUnwrap(expectedFrame.requestTools[requestID])
        assertEqual(actual, expected)
        XCTAssertFalse(actual.resultPoints.isEmpty)
    }

    func testMaterializedDeferredFrameAlsoReleasesWithItsCacheOwner() {
        var cache: Cache? = Cache()
        weak var retained: Cache.Frame?
        do {
            let frame = cache!.frame(
                for: key(), throughput: history(), gpu: history(),
                requestTools: [requestID: toolHistory()], deferredToolGeometry: true)
            XCTAssertFalse(frame.requestTools.isEmpty)
            retained = frame
        }
        XCTAssertNotNil(retained)
        cache = nil
        XCTAssertNil(retained)
    }

    func testConcurrentFirstAccessBuildsExactlyOnce() {
        let counters = PerformancePresentationCounters.shared
        counters.enable()
        let history = history()
        let frame = Cache().frame(
            for: key(), throughput: history, gpu: history,
            requestTools: [requestID: toolHistory(), UUID(): toolHistory()],
            directToolPlot: true, compactToolPaths: true, deferredToolGeometry: true)
        let access = ConcurrentAccess(frame: frame)
        assertNoToolWork()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in access.readTracks() }
        XCTAssertEqual(access.trackCounts, Array(repeating: 2, count: 8))
        XCTAssertEqual(counters.snapshot()["direct_tool_plot_builds"], 2)
        XCTAssertEqual(counters.snapshot()["legacy_tool_plot_builds"], 0)
        let segments = frame.requestTools.values.flatMap(\.segments)
        XCTAssertEqual(
            counters.snapshot()["tool_path_input_points"],
            UInt64(segments.reduce(0) { $0 + $1.points.count }))
        XCTAssertEqual(
            counters.snapshot()["tool_path_output_points"],
            UInt64(segments.reduce(0) { $0 + $1.tracePointCount }))
    }

    /// This box shares only the frame's synchronized tool getter. Result storage
    /// has its own lock; unrelated frame state is never touched concurrently.
    private final class ConcurrentAccess: @unchecked Sendable {
        let frame: Cache.Frame
        private let lock = NSLock()
        private var counts: [Int] = []

        init(frame: Cache.Frame) { self.frame = frame }

        func readTracks() {
            let count = frame.requestTools.count
            lock.lock()
            counts.append(count)
            lock.unlock()
        }

        var trackCounts: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return counts
        }
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
            actual.segments.map(\.area), expected.segments.map(\.area), file: file, line: line)
        XCTAssertEqual(
            actual.segments.map(\.spans), expected.segments.map(\.spans), file: file, line: line)
        XCTAssertEqual(
            actual.segments.map(\.tracePointCount), expected.segments.map(\.tracePointCount),
            file: file, line: line)
        XCTAssertEqual(actual.resultPoints, expected.resultPoints, file: file, line: line)
        XCTAssertEqual(actual.resultDiamonds, expected.resultDiamonds, file: file, line: line)
    }

    private func assertNoToolWork(file: StaticString = #filePath, line: UInt = #line) {
        let values = PerformancePresentationCounters.shared.snapshot()
        for key in counterKeys { XCTAssertEqual(values[key], 0, key, file: file, line: line) }
    }

    private func assertToolCountersEqual(
        _ actual: [String: UInt64], _ expected: [String: UInt64],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for key in counterKeys {
            XCTAssertEqual(actual[key], expected[key], key, file: file, line: line)
        }
    }

    private func key() -> Cache.Key {
        Cache.Key(
            publicationID: UUID(), now: date(20), duration: 20,
            size: CGSize(width: 401.5, height: 247.25), compact: false,
            hasTools: true, tokenUpperBound: 100, toolUpperBound: 120)
    }

    private func history() -> ChartDisplayHistory {
        ChartDisplayHistory(samples: observations, now: date(20), duration: 20)
    }

    private func toolHistory() -> ToolActivityHistory {
        ToolActivityHistory(
            events: [
                ToolActivityEvent(kind: .call, timestamp: date(3), requestID: requestID),
                ToolActivityEvent(kind: .call, timestamp: date(16), requestID: requestID),
                ToolActivityEvent(
                    kind: .resultSubmission, timestamp: date(16.5), requestID: requestID),
            ], observations: observations, now: date(20), duration: 20)
    }

    private var observations: [TimeSeriesPoint] {
        (0...40).map {
            TimeSeriesPoint(
                timestamp: date(Double($0) / 2), value: Double($0 % 13), isAvailable: $0 != 19)
        }
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
}
