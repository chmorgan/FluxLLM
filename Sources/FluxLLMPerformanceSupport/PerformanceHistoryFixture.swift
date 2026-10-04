import CryptoKit
import FluxLLM
import Foundation

/// Aged telemetry shared by the resource regression harness and isolated app playback.
/// Usage/request accounting follows production ingestion. Raw observations are
/// restored in one common instrumentation step, then published normally.
@MainActor
public enum PerformanceHistoryFixture {
    public static let schemaVersion = 2
    public static let model = "resource-fixture"
    public static let gpuSource = "Resource fixture system GPU"
    public static let gpuPercent = 42.0
    public static let persistentRequestCount = 19_000
    public static let persistentToolEventCount = persistentRequestCount * 2
    public static let persistentOutputTokens = 128
    public static let rawRequestCount = 256
    public static let rawToolEventCount = rawRequestCount * 2
    public static let rawSampleCount = MetricsStore.maxHistorySamples
    public static let rawRequestOutputTokens = 520

    public struct SessionHistory {
        public let usage: UsageHistory
        public let archive: ChartHistoryArchive
    }

    /// Seven days of completed usage and four older chart hours. Initializing at
    /// endingAt holds retention fixed while replaying events, rather than
    /// simulating seven days of pruning work during fixture construction.
    public static func makeSessionHistory(source: String, endingAt: Date) -> SessionHistory {
        let history = UsageHistory(now: endingAt)
        let firstStart = endingAt.addingTimeInterval(-7 * 24 * 3_600)
        let lastStart = endingAt.addingTimeInterval(-3_605)
        let spacing = lastStart.timeIntervalSince(firstStart) / Double(persistentRequestCount - 1)
        for index in 0..<persistentRequestCount {
            let startedAt = firstStart.addingTimeInterval(Double(index) * spacing)
            let request = GenerationRequest(
                id: fixedID(namespace: 1, index: index), model: model, startedAt: startedAt)
            history.apply(.began(request), source: source, at: startedAt)
            let call = toolEvent(
                namespace: 2, index: index, kind: .call,
                requestID: request.id, timestamp: startedAt.addingTimeInterval(1))
            let result = toolEvent(
                namespace: 3, index: index, kind: .resultSubmission,
                requestID: request.id, timestamp: startedAt.addingTimeInterval(2))
            history.apply(
                .toolActivity(requestID: request.id, events: [call, result]),
                source: source, at: result.timestamp)
            let endedAt = startedAt.addingTimeInterval(3)
            history.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        model: model, outputTokens: persistentOutputTokens, promptTokens: 32,
                        isEstimated: false, finished: true, elapsed: 3, timestamp: endedAt)),
                source: source, at: endedAt)
        }
        let archive = ChartHistoryArchive(now: endingAt)
        let archiveStart = endingAt.addingTimeInterval(-5 * 3_600)
        // Four older hours at the largest cadence that preserves an archive
        // segment. The raw fixture adds the most recent hour at 2 Hz afterward.
        for index in 0..<(4 * 3_600 / 5) {
            let timestamp = archiveStart.addingTimeInterval(Double(index) * 5)
            archive.record(
                source: source, at: timestamp,
                throughput: TimeSeriesPoint(timestamp: timestamp, value: 40),
                gpu: TimeSeriesPoint(timestamp: timestamp, value: gpuPercent),
                toolObservation: TimeSeriesPoint(timestamp: timestamp, value: 0))
        }
        return SessionHistory(usage: history, archive: archive)
    }

    /// Restore a completed observation window without replaying its historical
    /// chart publications. Request, tool, health and GPU ingestion is unchanged;
    /// all construction and the first ordinary publication remain measured.
    /// `replaySamples` retains the previous setup path for equivalence tests.
    /// Fill an already-selected Ollama session without suspending the main actor.
    /// Initialize the injected clock at endingAt - chartWindow before starting
    /// the coordinator, and start normal sampling after this method returns.
    /// Any initial coordinator GPU sample must use that same clock/source; newer
    /// timestamps would correctly cause the store to reject this historical data.
    public static func seedRawHistory(
        store: MetricsStore, endingAt: Date, replaySamples: Bool = false, setClock: (Date) -> Void
    ) {
        let start = endingAt.addingTimeInterval(-MetricsStore.chartWindow)
        precondition(store.backendKind == .ollama, "Select the fixture's Ollama session first")
        precondition(
            store.tpsHistory.last.map { $0.timestamp <= start } ?? true,
            "Seed raw history before sampling beyond the fixture's start")
        precondition(
            store.backendGPUActivity.map { $0.timestamp <= start } ?? true,
            "The initial GPU sample must use the fixture clock")

        let epoch = store.monitoringEpoch
        store.proxyState = .listening
        var request: GenerationRequest?
        var throughput: [TimeSeriesPoint] = []
        var gpu: [TimeSeriesPoint] = []
        var tools: [TimeSeriesPoint] = []
        throughput.reserveCapacity(rawSampleCount - 1)
        gpu.reserveCapacity(rawSampleCount - 1)
        tools.reserveCapacity(rawSampleCount - 1)
        for sampleIndex in 0..<rawSampleCount {
            let timestamp = start.addingTimeInterval(Double(sampleIndex) * 0.5)
            setClock(timestamp)
            store.updateConnection(.ready, at: timestamp)
            store.applyGPUSample(
                GPUActivitySample(
                    timestamp: timestamp, activityPercent: gpuPercent,
                    source: gpuSource, scope: .system), epoch: epoch)

            let requestIndex = sampleIndex / 28
            let phase = sampleIndex % 28
            if phase == 0, requestIndex < rawRequestCount {
                let next = GenerationRequest(
                    id: fixedID(namespace: 4, index: requestIndex),
                    model: model, startedAt: timestamp)
                request = next
                store.apply(.began(next), epoch: epoch)
            }
            if let current = request {
                if phase == 8 || phase == 12 {
                    let isCall = phase == 8
                    let event = toolEvent(
                        namespace: isCall ? 5 : 6, index: requestIndex,
                        kind: isCall ? .call : .resultSubmission,
                        requestID: current.id, timestamp: timestamp)
                    store.apply(
                        .toolActivity(requestID: current.id, events: [event]), epoch: epoch)
                }
                if phase > 0 {
                    let finished = phase == 26
                    store.apply(
                        .updated(
                            requestID: current.id,
                            snapshot: GenerationSnapshot(
                                model: model, outputTokens: phase * 20,
                                promptTokens: finished ? 32 : nil, isEstimated: !finished,
                                liveTPS: 40, authoritativeTPS: finished ? 40 : nil,
                                finished: finished, elapsed: Double(phase) * 0.5,
                                timestamp: timestamp)), epoch: epoch)
                    if finished { request = nil }
                }
            }
            if replaySamples {
                // Reference playback retained for equivalence tests only.
                store.sample(at: timestamp)
            } else if sampleIndex < rawSampleCount - 1 {
                let active = requestIndex < rawRequestCount && (1...25).contains(phase)
                throughput.append(TimeSeriesPoint(timestamp: timestamp, value: active ? 40 : 0))
                gpu.append(TimeSeriesPoint(timestamp: timestamp, value: gpuPercent))
                tools.append(TimeSeriesPoint(timestamp: timestamp, value: 0))
            }
        }
        precondition(request == nil, "The fixture must leave no generation open")
        setClock(endingAt)
        store.updateConnection(.ready, at: endingAt)
        if !replaySamples {
            store.restorePerformanceFixtureSamples(
                throughput: throughput, gpu: gpu, toolObservation: tools)
            // Include the ordinary first publication and all UI consequences in
            // the measured process, without replaying an hour of publications.
            store.sample(at: endingAt)
        }
    }

    public struct EquivalenceManifest: Equatable {
        public let sha256: String
        public let components: [String: String]
    }

    /// Digest actual seeded state, not expected constants. Relative microsecond
    /// coordinates remove wall-clock/source identity; UUIDs, values, availability,
    /// terminal state and each selected hour's authoritative usage remain exact.
    /// Calendar minute bucket boundaries vary with launch time, so the archive
    /// component compares observation counts and weighted sums for all series.
    public static func equivalenceManifest(
        store: MetricsStore, endingAt: Date, populated: Bool
    ) -> EquivalenceManifest {
        func offset(_ date: Date) -> Int64 {
            Int64((date.timeIntervalSince(endingAt) * 1_000_000).rounded())
        }
        func digest(_ visit: (inout SHA256) -> Void) -> String {
            var hash = SHA256()
            visit(&hash)
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func row(_ hash: inout SHA256, _ value: String) {
            hash.update(data: Data((value + "\n").utf8))
        }
        var components: [String: String] = [:]
        components["raw_samples"] = digest { hash in
            for (name, points) in [
                ("throughput", store.tpsHistory), ("gpu", store.systemGPUHistory),
                ("tools", store.toolObservationHistory),
            ] {
                row(&hash, "\(name)|\(points.count)")
                for point in points {
                    row(
                        &hash,
                        "\(offset(point.timestamp))|\(point.value.bitPattern)|\(point.isAvailable)")
                }
            }
        }
        components["request_lanes"] = digest { hash in
            for lane in store.requestLanes.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                row(
                    &hash,
                    [
                        lane.id.uuidString, String(offset(lane.startedAt)),
                        lane.endedAt.map { String(offset($0)) } ?? "nil", lane.model ?? "nil",
                        String(lane.outputTokens), String(lane.outputIsEstimated),
                        String(lane.liveTPS.bitPattern), String(lane.terminal),
                    ].joined(separator: "|"))
            }
        }
        components["tool_events"] = digest { hash in
            for event in store.toolActivityEvents.sorted(by: { $0.id.uuidString < $1.id.uuidString }
            ) {
                row(
                    &hash,
                    [
                        event.id.uuidString, event.kind == .call ? "call" : "result",
                        event.requestID?.uuidString ?? "nil", event.name ?? "nil",
                        event.callID ?? "nil",
                        String(offset(event.timestamp)),
                    ].joined(separator: "|"))
            }
        }
        let originalScope = store.usageScope
        store.usageScope = .selectedPeriod
        components["hourly_usage"] = digest { hash in
            for hour in 0..<168 {
                let summary = store.usageSummary(
                    in: DateInterval(
                        start: endingAt.addingTimeInterval(Double(hour - 168) * 3_600),
                        duration: 3_600))
                row(
                    &hash,
                    [
                        String(hour), String(summary.requests), String(summary.activeRequests),
                        summary.inputTokens.map(String.init) ?? "nil",
                        String(summary.unknownInputRequests),
                        String(summary.outputTokens), String(summary.outputIsEstimated),
                        String(summary.toolCalls), String(summary.isPartial),
                    ].joined(separator: "|"))
            }
        }
        store.usageScope = originalScope
        let archive = store.performanceFixtureArchive(endingAt: endingAt)
        components["archive_observations"] = digest { hash in
            for (name, segments) in [
                ("throughput", archive.throughput), ("gpu", archive.systemGPU),
                ("tools", archive.toolObservation),
            ] {
                var count = 0
                var weightedSum = 0.0
                for segment in segments {
                    for bucket in segment {
                        count += bucket.count
                        weightedSum += bucket.value * Double(bucket.count)
                    }
                }
                row(&hash, "\(name)|\(count)|\(Int64((weightedSum * 1_000).rounded()))")
            }
        }
        let hash = digest { hash in
            row(&hash, "fixture-schema|\(schemaVersion)|\(populated ? "populated" : "fresh")")
            for key in components.keys.sorted() { row(&hash, "\(key)|\(components[key]!)") }
        }
        return EquivalenceManifest(sha256: hash, components: components)
    }

    /// Stable fixture identities; namespaces distinguish older session requests,
    /// raw requests, and each kind of tool event without sharing dedupe keys.
    nonisolated public static func fixedID(namespace: UInt16, index: Int) -> UUID {
        precondition(index >= 0)
        let value = UInt64(index)
        return UUID(
            uuid: (
                0x52, 0x45, 0x53, 0x46, 0, 0,
                UInt8(truncatingIfNeeded: namespace >> 8), UInt8(truncatingIfNeeded: namespace),
                UInt8(truncatingIfNeeded: value >> 56), UInt8(truncatingIfNeeded: value >> 48),
                UInt8(truncatingIfNeeded: value >> 40), UInt8(truncatingIfNeeded: value >> 32),
                UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)
            ))
    }

    private static func toolEvent(
        namespace: UInt16, index: Int, kind: ToolActivityEvent.Kind,
        requestID: UUID, timestamp: Date
    ) -> ToolActivityEvent {
        ToolActivityEvent(
            id: fixedID(namespace: namespace, index: index), kind: kind,
            name: "read_file", callID: "fixture-\(requestID.uuidString)",
            timestamp: timestamp, requestID: requestID)
    }

}
