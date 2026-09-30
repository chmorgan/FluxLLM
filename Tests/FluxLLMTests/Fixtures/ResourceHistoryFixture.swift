import Foundation

@testable import FluxLLM

/// Aged telemetry for the resource regression harness. Build it before opening
/// the measured interval, using the same public ingestion and persistence paths
/// as the application. The caller owns and removes the temporary directory.
@MainActor
enum ResourceHistoryFixture {
    static let model = "resource-fixture"
    static let gpuSource = "Resource fixture system GPU"
    static let gpuPercent = 42.0
    static let persistentRequestCount = 19_000
    static let persistentToolEventCount = persistentRequestCount * 2
    static let persistentOutputTokens = 128
    static let rawRequestCount = 256
    static let rawToolEventCount = rawRequestCount * 2
    static let rawSampleCount = MetricsStore.maxHistorySamples
    static let rawRequestOutputTokens = 520

    /// Populate a fresh, caller-scoped temporary directory. Retained usage spans
    /// seven days; all requests finish before the later raw one-hour fixture.
    /// Initializing at endingAt keeps retention fixed while replaying old events,
    /// so fixture construction does not simulate seven days of pruning timers.
    static func seedPersistentHistory(directory: URL, source: String, endingAt: Date) async throws {
        let fileManager = FileManager.default
        for name in ["usage-history.json", "chart-history.json"] {
            guard !fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
            else {
                throw FixtureError.existingHistory(name)
            }
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let history = UsageHistory(directory: directory, now: endingAt)
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
        // This method supplies its own flush; calling flush first would enqueue
        // a second full snapshot and needlessly inflate fixture setup writes.
        await history.waitForPendingWrites()
        if let error = history.persistenceError { throw FixtureError.persistence(error) }

        let archive = ChartHistoryArchive(directory: directory, now: endingAt)
        await archive.prepare()
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
        await archive.flushAndWait()
        if let error = archive.persistenceError { throw FixtureError.persistence(error) }
    }

    /// Fill an already-selected Ollama session without suspending the main actor.
    /// Initialize the injected clock at endingAt - chartWindow before starting
    /// the coordinator, and start normal sampling after this method returns.
    /// Any initial coordinator GPU sample must use that same clock/source; newer
    /// timestamps would correctly cause the store to reject this historical data.
    static func seedRawHistory(
        store: MetricsStore, endingAt: Date, setClock: (Date) -> Void
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
            store.sample(at: timestamp)
        }
        precondition(request == nil, "The fixture must leave no generation open")
        setClock(endingAt)
        store.updateConnection(.ready, at: endingAt)
    }

    /// Stable fixture identities; namespaces distinguish persisted requests,
    /// raw requests, and each kind of tool event without sharing dedupe keys.
    static func fixedID(namespace: UInt16, index: Int) -> UUID {
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

    private enum FixtureError: Error {
        case existingHistory(String)
        case persistence(String)
    }
}
