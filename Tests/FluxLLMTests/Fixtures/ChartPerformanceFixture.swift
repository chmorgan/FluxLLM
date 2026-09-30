import Foundation

@testable import FluxLLM

/// Stable input shared by correctness checks and the opt-in chart benchmark.
/// Publication UUIDs are deliberately fresh; all observable data and request/event
/// identities are deterministic. Building these arrays is outside the timed work.
enum ChartPerformanceFixture {
    static let version = 1
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    static let initialNow = origin.addingTimeInterval(3_600)
    static let visibleDuration: TimeInterval = 60
    static let publicationCount = 30

    static func publications(
        retainedSeconds: Int, laneCount: Int, count: Int = publicationCount
    ) -> [ChartPresentationSnapshot] {
        precondition(retainedSeconds >= 60 && retainedSeconds <= 3_600)
        precondition(laneCount > 0 && laneCount <= 256 && count > 0)
        var nextIndex = 7_201
        let initialIndices = (7_200 - retainedSeconds * 2)...7_200
        var throughput = initialIndices.map { sample(index: $0, series: .throughput) }
        var gpu = initialIndices.map { sample(index: $0, series: .gpu) }
        var observations = initialIndices.map { sample(index: $0, series: .observation) }
        let events = toolEvents(laneCount: laneCount)
        var result: [ChartPresentationSnapshot] = []

        for publication in 0..<count {
            result.append(
                ChartPresentationSnapshot(
                    timestamp: initialNow.addingTimeInterval(Double(publication)),
                    throughput: throughput, systemGPU: gpu, toolActivity: events,
                    requestLanes: lanes(count: laneCount, publication: publication),
                    toolObservation: observations, supportsToolActivity: true))
            guard publication + 1 < count else { break }
            // Two new 500 ms observations and two expired observations per second.
            throughput.removeFirst(2)
            gpu.removeFirst(2)
            observations.removeFirst(2)
            for index in nextIndex..<(nextIndex + 2) {
                throughput.append(sample(index: index, series: .throughput))
                gpu.append(sample(index: index, series: .gpu))
                observations.append(sample(index: index, series: .observation))
            }
            nextIndex += 2
        }
        return result
    }

    /// Retain the complete leftmost 3-second bucket. A strict sliding 121-point
    /// minute loses up to four contributors and intentionally omits that bucket;
    /// comparing it to an hour would mistake different output for wasted work.
    /// These paired inputs contain 121...125 samples for the same visible minute.
    static func alignedVisibleHistory(
        from snapshot: ChartPresentationSnapshot
    ) -> ChartPresentationSnapshot {
        let cutoff = snapshot.timestamp.addingTimeInterval(-visibleDuration)
        let alignedCutoff = Date(
            timeIntervalSince1970: (cutoff.timeIntervalSince1970 / 3).rounded(.down) * 3)
        return ChartPresentationSnapshot(
            timestamp: snapshot.timestamp,
            throughput: snapshot.throughput.filter { $0.timestamp >= alignedCutoff },
            systemGPU: snapshot.systemGPU.filter { $0.timestamp >= alignedCutoff },
            toolActivity: snapshot.toolActivity, requestLanes: snapshot.requestLanes,
            toolObservation: snapshot.toolObservation.filter { $0.timestamp >= alignedCutoff },
            supportsToolActivity: snapshot.supportsToolActivity)
    }

    static func withObservationGap(
        _ snapshot: ChartPresentationSnapshot, at timestamp: Date
    ) -> ChartPresentationSnapshot {
        func markingUnavailable(_ samples: [TimeSeriesPoint]) -> [TimeSeriesPoint] {
            samples.map {
                TimeSeriesPoint(
                    timestamp: $0.timestamp, value: $0.value,
                    isAvailable: $0.timestamp == timestamp ? false : $0.isAvailable)
            }
        }
        return ChartPresentationSnapshot(
            timestamp: snapshot.timestamp,
            throughput: markingUnavailable(snapshot.throughput),
            systemGPU: markingUnavailable(snapshot.systemGPU),
            toolActivity: snapshot.toolActivity, requestLanes: snapshot.requestLanes,
            toolObservation: markingUnavailable(snapshot.toolObservation),
            supportsToolActivity: snapshot.supportsToolActivity)
    }

    private enum Series { case throughput, gpu, observation }

    private static func sample(index: Int, series: Series) -> TimeSeriesPoint {
        let value: Double
        switch series {
        case .throughput: value = Double(11 + (index * 7) % 89)
        case .gpu: value = Double((index * 3) % 101)
        case .observation: value = 0
        }
        return TimeSeriesPoint(
            timestamp: origin.addingTimeInterval(Double(index) / 2), value: value)
    }

    private static func lanes(count: Int, publication: Int) -> [RequestLane] {
        (0..<count).map { index in
            let active = index == 0
            return RequestLane(
                id: identity(index + 1),
                startedAt: initialNow.addingTimeInterval(-24 + Double(index) / 20),
                endedAt: active ? nil : initialNow.addingTimeInterval(-3),
                model: "synthetic-chart-model",
                outputTokens: 100 + index + (active ? publication * 20 : 0),
                outputIsEstimated: active, liveTPS: active ? 20 : 0, terminal: !active)
        }
    }

    private static func toolEvents(laneCount: Int) -> [ToolActivityEvent] {
        (0..<laneCount).flatMap { index in
            let callTime = initialNow.addingTimeInterval(-22 + Double(index) / 20)
            let requestID = identity(index + 1)
            let callID = "synthetic-call-\(index)"
            return [
                ToolActivityEvent(
                    id: identity(10_000 + index * 2), kind: .call, name: "read_file",
                    callID: callID, timestamp: callTime, requestID: requestID),
                ToolActivityEvent(
                    id: identity(10_001 + index * 2), kind: .resultSubmission,
                    name: "read_file", callID: callID,
                    timestamp: callTime.addingTimeInterval(0.5), requestID: requestID),
            ]
        }
    }

    private static func identity(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", Int64(value)))!
    }
}
