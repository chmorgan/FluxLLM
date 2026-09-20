import Foundation
import XCTest

@testable import FluxLLM

final class ChartInspectionContentTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testPlotDistinguishesMissingGPUFromMeasuredZeroAndKeepsDenseRequestsBounded() {
        let missing = ChartInspectionContent.plot(
            at: origin, generated: 42.26, gpu: nil, requestCount: 0)
        let zero = ChartInspectionContent.plot(
            at: origin, generated: 42.26, gpu: 0, requestCount: 250)

        XCTAssertNil(missing.badge)
        XCTAssertNil(zero.badge)
        XCTAssertEqual(missing.rows.first { $0.label == "Generated" }?.value, "42.3 tok/s")
        XCTAssertEqual(missing.rows.first { $0.label == "GPU" }?.value, "—")
        XCTAssertEqual(zero.rows.first { $0.label == "GPU" }?.value, "0%")
        XCTAssertNil(missing.rows.first { $0.label == "Requests" })
        XCTAssertEqual(zero.rows.first { $0.label == "Requests" }?.value, "250")
        XCTAssertEqual(missing.rows.count, 2)
        XCTAssertEqual(
            zero.rows.count, 3, "Concurrency must add one summary, not one row per request")
    }

    func testEndedRequestUsesFullDurationAndTotalTokensRegardlessOfCursorTime() throws {
        let id = UUID()
        let lane = RequestLane(
            id: id, startedAt: origin, endedAt: date(12.4), model: "provider/model-large",
            outputTokens: 645, outputIsEstimated: false, liveTPS: 987.6, terminal: true)
        let historical = ChartInspectionContent.request(lane, at: date(3))
        let afterEnd = ChartInspectionContent.request(lane, at: date(20))
        let beforeStart = ChartInspectionContent.request(lane, at: date(-1))
        let metrics = try XCTUnwrap(historical.requestMetrics)

        XCTAssertEqual(historical.title, "model-large")
        XCTAssertEqual(historical.accent, .request(id))
        XCTAssertEqual(historical.badge, "Ended")
        XCTAssertTrue(historical.rows.isEmpty)
        XCTAssertEqual(metrics.duration, "12.4 s")
        XCTAssertEqual(metrics.outputTokens, "645 tok")
        XCTAssertEqual(
            metrics.averageRate, "52.0 tok/s", "Average must ignore the retained live rate")
        XCTAssertEqual(afterEnd.requestMetrics, metrics)
        XCTAssertEqual(beforeStart.requestMetrics, metrics)
    }

    func testActiveRequestAverageIncludesWaitingTimeAndMarksEstimatedTokens() throws {
        let waiting = RequestLane(id: UUID(), startedAt: origin)
        let generating = RequestLane(
            id: waiting.id, startedAt: origin, outputTokens: 150, liveTPS: 50)
        let waitingContent = ChartInspectionContent.request(waiting, at: date(5))
        let generatingContent = ChartInspectionContent.request(generating, at: date(15))
        let waitingMetrics = try XCTUnwrap(waitingContent.requestMetrics)
        let generatingMetrics = try XCTUnwrap(generatingContent.requestMetrics)

        XCTAssertEqual(waitingContent.badge, "In progress")
        XCTAssertEqual(waitingMetrics.duration, "5.0 s")
        XCTAssertEqual(waitingMetrics.averageRate, "~0.0 tok/s")
        XCTAssertEqual(waitingMetrics.outputTokens, "~0 tok")
        XCTAssertEqual(generatingContent.badge, "In progress")
        XCTAssertEqual(generatingMetrics.duration, "15.0 s")
        XCTAssertEqual(generatingMetrics.averageRate, "~10.0 tok/s")
        XCTAssertEqual(generatingMetrics.outputTokens, "~150 tok")
    }

    func testEndedRequestKeepsEstimateMarkerWithoutAuthoritativeUsage() throws {
        let lane = RequestLane(
            id: UUID(), startedAt: origin, endedAt: date(10), outputTokens: 125,
            terminal: true)
        let content = ChartInspectionContent.request(lane, at: date(20))
        let metrics = try XCTUnwrap(content.requestMetrics)

        XCTAssertEqual(content.badge, "Ended")
        XCTAssertEqual(metrics.duration, "10.0 s")
        XCTAssertEqual(metrics.averageRate, "~12.5 tok/s")
        XCTAssertEqual(metrics.outputTokens, "~125 tok")
    }

    func testZeroMissingAndInvalidDurationNeverProduceAnInvalidAverage() throws {
        let zero = RequestLane(
            id: UUID(), startedAt: origin, endedAt: origin, outputTokens: 100,
            terminal: true)
        let zeroMetrics = try XCTUnwrap(
            ChartInspectionContent.request(zero, at: date(20)).requestMetrics)
        XCTAssertEqual(zeroMetrics.duration, "0.0 s")
        XCTAssertEqual(zeroMetrics.averageRate, "—")

        let invalidLanes = [
            RequestLane(id: UUID(), startedAt: origin, outputTokens: 100, terminal: true),
            RequestLane(id: UUID(), startedAt: origin, endedAt: date(-1), outputTokens: 100),
            RequestLane(id: UUID(), startedAt: origin, endedAt: date(.infinity), outputTokens: 100),
            RequestLane(id: UUID(), startedAt: date(.nan), endedAt: date(10), outputTokens: 100),
        ]
        for lane in invalidLanes {
            let metrics = try XCTUnwrap(
                ChartInspectionContent.request(lane, at: date(20)).requestMetrics)
            XCTAssertEqual(metrics.duration, "—")
            XCTAssertEqual(metrics.averageRate, "—")
        }
    }

    func testLongRequestDurationUsesCompactMinutesAndHours() throws {
        for (elapsed, expected) in [(90.0, "1.5 min"), (5_400.0, "1.5 h")] {
            let lane = RequestLane(id: UUID(), startedAt: origin, endedAt: date(elapsed))
            let metrics = try XCTUnwrap(
                ChartInspectionContent.request(lane, at: date(elapsed)).requestMetrics)
            XCTAssertEqual(metrics.duration, expected)
        }
    }

    func testRequestUsesNeutralEndedStateAndHandlesMissingModel() {
        let open = RequestLane(id: UUID(), startedAt: origin)
        let terminalWithoutEnd = RequestLane(
            id: UUID(), startedAt: origin, model: "", terminal: true)
        let endedWithoutFlag = RequestLane(id: UUID(), startedAt: origin, endedAt: date(1))

        for lane in [open, terminalWithoutEnd, endedWithoutFlag] {
            let content = ChartInspectionContent.request(lane, at: date(2))
            XCTAssertEqual(content.title, "Unknown model")
            XCTAssertEqual(
                content.badge,
                lane.id == open.id ? "In progress" : "Ended",
                "Terminal status alone does not distinguish success, cancellation, or failure")
        }
    }

    func testToolRateCountAndObservedDurationDescribeOneBucket() {
        let bucket = ToolActivityBucket(
            start: origin, end: date(3), callCount: 2, callsPerMinute: 40,
            toolNames: ["search", "read_file", "search"])
        let content = ChartInspectionContent.tools(at: date(2), bucket: bucket, results: [])

        XCTAssertEqual(content.rows.first { $0.label == "Tool calls" }?.value, "40.0/min")
        XCTAssertEqual(content.rows.first { $0.label == "Observed" }?.value, "2 calls / 3.0s")
        XCTAssertEqual(content.rows.first { $0.label == "Tools" }?.value, "read_file, search")
        XCTAssertEqual(content.rows.count, 3)
    }

    func testToolCallWithoutObservedTimeStaysPendingAndResultSubmissionsAreSeparate() {
        let bucket = ToolActivityBucket(
            start: origin, end: origin, callCount: 1, callsPerMinute: 0,
            toolNames: ["search"])
        let result = ToolActivityEvent(kind: .resultSubmission, timestamp: origin)
        let pending = ChartInspectionContent.tools(at: origin, bucket: bucket, results: [result])
        let resultOnly = ChartInspectionContent.tools(at: origin, bucket: nil, results: [result])

        XCTAssertEqual(pending.rows.first { $0.label == "Tool calls" }?.value, "Pending")
        XCTAssertEqual(pending.rows.first { $0.label == "Observed" }?.value, "1 call / 0.0s")
        XCTAssertEqual(pending.rows.first { $0.label == "◇ Submitted" }?.value, "1 result")
        XCTAssertEqual(resultOnly.rows.first { $0.label == "Tool calls" }?.value, "0.0/min")
        XCTAssertNil(resultOnly.rows.first { $0.label == "Observed" })
        XCTAssertEqual(resultOnly.rows.first { $0.label == "◇ Submitted" }?.value, "1 result")
        XCTAssertLessThanOrEqual(pending.rows.count, 4)
    }

    func testDenseToolNamesAndResultsCannotAddUnboundedRows() {
        let names = (0..<100).map { String(format: "tool_%03d", $0) }
        let bucket = ToolActivityBucket(
            start: origin, end: date(5), callCount: 100, callsPerMinute: 1_200,
            toolNames: Array(names.reversed()) + [names[0]])
        let results = (0..<100).map { _ in
            ToolActivityEvent(kind: .resultSubmission, timestamp: origin)
        }
        let content = ChartInspectionContent.tools(at: origin, bucket: bucket, results: results)

        XCTAssertEqual(content.rows.first { $0.label == "Tools" }?.value, "tool_000, tool_001 +98")
        XCTAssertEqual(content.rows.first { $0.label == "◇ Submitted" }?.value, "100 results")
        XCTAssertEqual(content.rows.count, 4)
    }

    func testOverflowCountsRequestsButSummarizesDistinctModelNames() {
        let lanes = (0..<200).map { index in
            RequestLane(
                id: UUID(), startedAt: origin,
                model: "provider/model-\(index % 4)")
        }
        let content = ChartInspectionContent.overflow(at: origin, lanes: Array(lanes.reversed()))

        XCTAssertEqual(content.rows.first { $0.label == "Requests" }?.value, "200")
        XCTAssertEqual(content.rows.first { $0.label == "Models" }?.value, "model-0, model-1 +2")
        XCTAssertEqual(content.rows.count, 2)
    }

    func testFreshToolTailKeepsOriginalCountAndExposureInsteadOfExtendingMeasurement() throws {
        let history = ToolActivityHistory(
            events: [ToolActivityEvent(kind: .call, name: "search", timestamp: date(3.25))],
            observations: (0...7).map {
                TimeSeriesPoint(timestamp: date(Double($0) / 2), value: 0)
            },
            now: date(4), duration: 60)
        XCTAssertNil(history.bucket(at: date(3.75)))
        let bucket = try XCTUnwrap(
            ChartInspectionContent.toolBucket(at: date(3.75), in: history, now: date(4)))

        XCTAssertEqual(bucket, history.current)
        XCTAssertEqual(bucket.end, date(3.5))
        XCTAssertEqual(bucket.observedDuration, 0.5)
        XCTAssertEqual(bucket.callCount, 1)
        XCTAssertEqual(bucket.callsPerMinute, 120)
        let content = ChartInspectionContent.tools(at: date(3.75), bucket: bucket, results: [])
        XCTAssertEqual(content.rows.first { $0.label == "Observed" }?.value, "1 call / 0.5s")
        XCTAssertNil(ChartInspectionContent.toolBucket(at: date(4.01), in: history, now: date(4)))
    }

    func testToolResolverDoesNotFillStaleHistoryOrInternalObservationGaps() {
        let stale = ToolActivityHistory(
            events: [],
            observations: [0.0, 1.0].map { TimeSeriesPoint(timestamp: date($0), value: 0) },
            now: date(7), duration: 60)
        let gapped = ToolActivityHistory(
            events: [],
            observations: [0.0, 1.0, 10.0, 11.0].map {
                TimeSeriesPoint(timestamp: date($0), value: 0)
            }, now: date(11), duration: 60)
        let pending = ToolActivityHistory(
            events: [ToolActivityEvent(kind: .call, timestamp: date(3.75))],
            observations: [3.0, 3.5].map { TimeSeriesPoint(timestamp: date($0), value: 0) },
            now: date(4), duration: 60)

        XCTAssertNil(ChartInspectionContent.toolBucket(at: date(2), in: stale, now: date(7)))
        XCTAssertNil(ChartInspectionContent.toolBucket(at: date(5), in: gapped, now: date(11)))
        XCTAssertNil(ChartInspectionContent.toolBucket(at: date(3.9), in: pending, now: date(4)))
        XCTAssertEqual(
            ChartInspectionContent.toolBucket(at: date(3.75), in: pending, now: date(4))?.callCount,
            1, "An instantaneous call remains inspectable without inventing an observed interval")
    }

    private func date(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }
}
