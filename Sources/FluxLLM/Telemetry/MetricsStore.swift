import Foundation
import SwiftUI

/// Shared presentation state. Request events and aggregate backend measurements
/// retain their different meanings; history advances independently of delivery.
@MainActor
@Observable
public final class MetricsStore {
    public private(set) var activeGeneration: ActiveGeneration?
    public private(set) var currentTPS: Double = 0
    /// The numeric rate and meter deliberately update more slowly than raw
    /// streamed telemetry. Chart history continues to use `currentTPS`.
    public private(set) var displayTPS: Double?
    public private(set) var displayRateIsEstimated = false
    public private(set) var displayUpdatedAt: Date?
    public private(set) var currentModel: String?
    public private(set) var promptTokens: Int?
    public private(set) var outputTokens: Int = 0
    public private(set) var outputIsEstimated = false
    public private(set) var lastMeasuredTPS: Double?
    public private(set) var generationError: String?

    public private(set) var backendKind: BackendKind?
    public private(set) var monitoringEpoch = UUID()
    public private(set) var connectionState: BackendConnectionState = .detecting
    public private(set) var connectionMessage: String?
    public private(set) var detectedBackends: [DetectedBackend] = []
    public private(set) var selectionNotice: String?
    public private(set) var throughputBasis: ThroughputBasis = .estimated
    public private(set) var rateIsAvailable = false
    public private(set) var backendOutputTokens: Int?
    public private(set) var backendPromptTokens: Int?
    public private(set) var runningRequests: Int?
    public private(set) var queuedRequests: Int?
    public private(set) var inferenceGPUPercent: Double?
    public private(set) var gpuSource: String?
    public private(set) var backendGPUActivity: GPUActivitySample?
    public private(set) var gpuAvailabilityMessage =
        "Waiting for macOS GPU utilization…"
    public private(set) var gpuHistory: [TimeSeriesPoint] = []
    public var historyRange: HistoryRange = .automatic
    public var usageScope: UsageScope = .sinceLaunch
    public private(set) var historySource = BackendKind.ollama.rawValue
    private var usageRevision: UInt64 = 0
    @ObservationIgnored private let usageHistory: UsageHistory
    @ObservationIgnored private let chartArchive: ChartHistoryArchive

    /// Device utilization is a different measurement from process execution time.
    /// Only scoped system samples can enter the percentage-based presentation.
    public var systemGPUUtilizationPercent: Double? {
        guard backendGPUActivity?.scope == .system else { return nil }
        return backendGPUActivity?.activityPercent
    }

    public var systemGPUHistory: [TimeSeriesPoint] {
        gpuHistoryScope == .system ? gpuHistory : []
    }

    public var isRateEstimated: Bool {
        throughputBasis == .estimated
            && (activeGeneration?.state == .running || currentTPS > 0)
    }

    public var backendActivity: BackendActivity {
        if backendKind == nil || backendKind == .ollama {
            if let startedAt = activityRequestStartedAt {
                return .observedRequests(
                    count: openProxyRequests.count, startedAt: startedAt,
                    hasOutput: openProxyRequests.values.contains { $0.hasOutput })
            }
            return connectionState == .ready ? .idle : .unknown
        }
        return nativeActivity
    }

    public var isBackendActive: Bool { backendActivity.isActive }

    /// Only proxy lifecycles supply a real start time; native counts never do.
    public var activityRequestStartedAt: Date? {
        openProxyRequests.values.map(\.startedAt).min()
    }

    public var historyAge: TimeInterval {
        guard let start = historyStartedAt else { return 0 }
        return max(0, sampleDate.timeIntervalSince(start))
    }

    public var visibleHistoryDuration: TimeInterval {
        historyRange.duration(historyAge: historyAge)
    }

    /// Range selection is immediate, but automatic growth follows the same held
    /// time as the plotted samples rather than the faster collection clock.
    public var chartHistoryDuration: TimeInterval {
        historyRange.duration(historyAge: chartHistoryAge)
    }

    public var chartHistoryAge: TimeInterval {
        historyStartedAt.map {
            max(0, chartPresentation.timestamp.timeIntervalSince($0))
        } ?? 0
    }

    /// Listener state is separate from the outcome of an upstream request.
    public var proxyState: ProxyState = .stopped
    public var proxyError: String?
    public var proxyEndpoint = "http://127.0.0.1:11435"
    public var upstreamEndpoint = "http://localhost:11434"

    /// Oldest first, with timestamps so both charts share a real time axis.
    public private(set) var tpsHistory: [TimeSeriesPoint] = []
    public private(set) var toolActivityEvents: [ToolActivityEvent] = []
    public private(set) var toolObservationHistory: [TimeSeriesPoint] = []
    public private(set) var sampleDate = Date()
    /// All chart series and their time axis advance together once per second.
    /// The raw half-second histories above retain every captured peak and gap.
    public private(set) var chartPresentation: ChartPresentationSnapshot

    public static let chartWindow: TimeInterval = 3600
    public static let maxHistorySamples = 7201
    public static let maxToolActivityEvents = 10_000
    public static let freshnessInterval: TimeInterval = 5
    private static let maxRetiredProxyRequestIDs = 2048
    /// Bounds the number of finished request lanes kept for the chart.
    private static let maxRetiredRequestLanes = 256

    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var lastBackendSampleAt: Date?
    @ObservationIgnored private var lastRequestSampleAt: Date?
    @ObservationIgnored private var lastSuccessfulStreamAt: Date?
    @ObservationIgnored private var lastSuccessfulHealthAt: Date?
    @ObservationIgnored private var healthConnectionState: BackendConnectionState = .detecting
    @ObservationIgnored private var healthConnectionMessage: String?
    @ObservationIgnored private var generationElapsed: TimeInterval = 0
    @ObservationIgnored private var requestHasInvalidRate = false
    @ObservationIgnored private var requestHasOutputEvidence = false
    private struct ObservedProxyRequest {
        let startedAt: Date
        var hasOutput = false
        /// Timestamp of this request's most recent chunk. A request that has
        /// begun but is still loading a model carries no output yet, so its
        /// staleness is measured from its last update rather than from begin;
        /// a non-terminal request whose last update is older than
        /// `freshnessInterval` stops contributing to the summed rate.
        var lastUpdateAt: Date
        /// This request's own live rate and count. The displayed throughput is
        /// the sum of every open request, so concurrent streams add together
        /// instead of one overwriting the other. Counts and their provenance are
        /// also kept for each lane's full-request average, including final usage.
        var liveTPS: Double = 0
        var outputTokens: Int = 0
        var outputIsEstimated = true
        var model: String?
    }
    private var openProxyRequests: [UUID: ObservedProxyRequest] = [:]
    /// Terminal lanes that finished within the chart window, newest first, kept
    /// so a request's lane stays visible as it scrolls off the time axis.
    @ObservationIgnored private var retiredRequestLanes: [RequestLane] = []
    @ObservationIgnored private var seenProxyRequestIDs: Set<UUID> = []
    @ObservationIgnored private var retiredProxyRequestIDs: [UUID] = []
    private var nativeActivity: BackendActivity = .unknown
    @ObservationIgnored private var nativeActivityObservedAt: Date?
    @ObservationIgnored private var lastRatePublicationAt: Date?
    @ObservationIgnored private var lastChartPublicationAt: Date?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var lastGPUSampleAt: Date?
    private var gpuHistoryScope: GPUActivityScope?
    private var gpuHistorySource: String?
    @ObservationIgnored private var historyStartedAt: Date?
    @ObservationIgnored private var retainedToolEventIDs: Set<UUID> = []
    @ObservationIgnored private var toolHistoryTruncatedThrough: Date?

    public init(clock: @escaping () -> Date = Date.init, historyDirectory: URL? = nil) {
        self.clock = clock
        let now = clock()
        usageHistory = UsageHistory(directory: historyDirectory, now: now)
        chartArchive = ChartHistoryArchive(directory: historyDirectory, now: now)
        sampleDate = now
        chartPresentation = ChartPresentationSnapshot(timestamp: now)
    }

    public func prepareHistory() async {
        await chartArchive.prepare()
    }

    public func flushHistory() async {
        usageHistory.flush()
        await usageHistory.waitForPendingWrites()
        await chartArchive.flushAndWait()
    }

    public func usageSummary(in interval: DateInterval) -> UsageSummary {
        _ = usageRevision
        return usageHistory.summary(
            scope: usageScope, source: historySource, interval: interval, now: sampleDate)
    }

    public var historyPersistenceError: String? {
        _ = usageRevision
        _ = chartPresentation.publicationID
        return usageHistory.persistenceError ?? chartArchive.persistenceError
    }

    deinit {
        samplingTask?.cancel()
    }

    /// The most recently started request owns the dashboard. Once it reaches a
    /// terminal state, delayed events cannot reopen or change that session.
    public func apply(_ event: GenerationEvent, epoch: UUID? = nil) {
        guard epoch == nil || epoch == monitoringEpoch,
            backendKind == nil || backendKind == .ollama
        else { return }
        usageHistory.apply(event, source: historySource, at: clock())
        usageRevision &+= 1
        switch event {
        case .began(let request):
            // The displayed identity remains authoritative even after its
            // bounded duplicate-event history has been retired.
            guard activeGeneration?.id != request.id,
                seenProxyRequestIDs.insert(request.id).inserted
            else { return }
            openProxyRequests[request.id] = ObservedProxyRequest(
                startedAt: request.startedAt, lastUpdateAt: request.startedAt, model: request.model)
            if let activeGeneration {
                guard request.id != activeGeneration.id,
                    request.startedAt >= activeGeneration.startedAt
                else { return }
            }
            activeGeneration = ActiveGeneration(
                id: request.id,
                model: request.model ?? "unknown",
                startedAt: request.startedAt,
                state: .running)
            lastRequestSampleAt = request.startedAt
            currentModel = request.model
            recomputeAggregateRate(at: request.startedAt)
            clearDisplayRate()
            generationElapsed = 0
            requestHasInvalidRate = false
            requestHasOutputEvidence = false
            outputTokens = 0
            promptTokens = nil
            outputIsEstimated = true
            lastMeasuredTPS = nil
            generationError = nil
            throughputBasis = .estimated
            rateIsAvailable = true
            if backendKind == nil || connectionState == .ready {
                displayIdleRate(at: request.startedAt)
            }

        case .toolActivity(let requestID, let events):
            // A request's tool activity belongs to that request for the whole
            // window, even after a newer request has become the owner: every
            // request is drawn as its own lane, so an older request's tool
            // calls are not dropped just because a sibling started later.
            let owningRequestID = requestID
            for event in events {
                guard event.timestamp.timeIntervalSince1970.isFinite,
                    retainedToolEventIDs.insert(event.id).inserted,
                    let start = requestStartedAt(for: owningRequestID),
                    event.timestamp >= start
                else { continue }
                toolActivityEvents.append(event.withRequestID(owningRequestID))
            }
            toolActivityEvents.sort { $0.timestamp < $1.timestamp }
            trimToolActivity(at: sampleDate)

        case .updated(let requestID, let snapshot):
            let liveRate = validRate(snapshot.liveTPS)
            let rate = liveRate ?? 0
            if var observed = openProxyRequests[requestID] {
                // Final usage may arrive without a live snapshot, or correct a
                // larger live estimate. Keep it before retiring the lane.
                if let model = snapshot.model { observed.model = model }
                observed.outputTokens = max(0, snapshot.outputTokens)
                observed.outputIsEstimated = snapshot.isEstimated
                if !snapshot.finished, snapshot.error == nil {
                    // Only open requests contribute their live rate to the sum.
                    observed.hasOutput =
                        observed.hasOutput || observed.outputTokens > 0 || rate > 0
                    observed.liveTPS = rate
                    observed.lastUpdateAt = snapshot.timestamp
                }
                openProxyRequests[requestID] = observed
            }
            if snapshot.finished || snapshot.error != nil {
                // A terminal request stops contributing to the summed rate.
                closeObservedRequest(requestID, at: snapshot.timestamp)
                recomputePlainSum()
            } else if openProxyRequests[requestID] != nil {
                recomputeAggregateRate(at: snapshot.timestamp)
            }
            guard ownsRunningGeneration(requestID) else { return }
            lastRequestSampleAt = snapshot.timestamp
            if backendKind == .ollama, snapshot.error == nil {
                // A valid streamed response is direct evidence that the selected
                // backend is serving, even if the last health probe failed.
                lastSuccessfulStreamAt = max(
                    lastSuccessfulStreamAt ?? snapshot.timestamp, snapshot.timestamp)
                refreshOllamaConnection(at: snapshot.timestamp)
            }
            generationElapsed = snapshot.elapsed
            if let model = snapshot.model {
                currentModel = model
                activeGeneration?.model = model
            }
            outputTokens = max(0, snapshot.outputTokens)
            promptTokens = snapshot.promptTokens.map { max(0, $0) }
            outputIsEstimated = snapshot.isEstimated
            requestHasOutputEvidence =
                requestHasOutputEvidence || outputTokens > 0 || rate > 0
            requestHasInvalidRate = !snapshot.finished && liveRate == nil
            rateIsAvailable =
                snapshot.error == nil
                && (snapshot.finished || liveRate != nil)

            if let error = snapshot.error {
                generationError = error
                activeGeneration?.state = .errored
                clearDisplayRate()
            } else if snapshot.finished {
                lastMeasuredTPS = validRate(snapshot.authoritativeTPS)
                activeGeneration?.state = .completed
                displayIdleRate(at: snapshot.timestamp)
            } else {
                if !rateIsAvailable { clearDisplayRate() }
            }

        case .failed(let requestID, let message):
            closeObservedRequest(requestID, at: clock())
            recomputePlainSum()
            guard ownsRunningGeneration(requestID) else { return }
            generationError = message
            activeGeneration?.state = .errored
            rateIsAvailable = false
            clearDisplayRate()

        case .cancelled(let requestID):
            closeObservedRequest(requestID, at: clock())
            recomputePlainSum()
            guard ownsRunningGeneration(requestID) else { return }
            activeGeneration?.state = .cancelled
            rateIsAvailable = true
            displayIdleRate(at: clock())
        }
        if backendKind == .ollama, connectionState == .needsConfiguration {
            // A late stream event may still contribute final usage, but it must
            // not temporarily restore rates behind an explicit configuration fault.
            setEffectiveConnection(.needsConfiguration, message: connectionMessage)
        }
    }

    /// Changing sources never joins unrelated rates into one continuous trace.
    public func beginBackendSession(kind: BackendKind?, epoch: UUID, sourceID: String? = nil) {
        let now = clock()
        usageHistory.finishOpenRequests(source: historySource, at: now)
        chartArchive.endSession(source: historySource, at: now)
        usageHistory.flush()
        chartArchive.flush()
        usageRevision &+= 1
        historySource = sourceID ?? kind?.rawValue ?? "unconfigured"
        monitoringEpoch = epoch
        backendKind = kind
        connectionState = kind == nil ? .detecting : .connecting
        healthConnectionState = connectionState
        healthConnectionMessage = nil
        connectionMessage = nil
        activeGeneration = nil
        openProxyRequests.removeAll(keepingCapacity: true)
        retiredRequestLanes.removeAll(keepingCapacity: true)
        seenProxyRequestIDs.removeAll(keepingCapacity: true)
        retiredProxyRequestIDs.removeAll(keepingCapacity: true)
        nativeActivity = .unknown
        nativeActivityObservedAt = nil
        currentTPS = 0
        clearDisplayRate()
        generationElapsed = 0
        requestHasInvalidRate = false
        requestHasOutputEvidence = false
        currentModel = nil
        promptTokens = nil
        outputTokens = 0
        outputIsEstimated = kind == .ollama
        lastMeasuredTPS = nil
        generationError = nil
        throughputBasis = kind == .ollama ? .estimated : .serverAggregate
        rateIsAvailable = false
        backendOutputTokens = nil
        backendPromptTokens = nil
        runningRequests = nil
        queuedRequests = nil
        inferenceGPUPercent = nil
        gpuSource = nil
        lastBackendSampleAt = nil
        lastRequestSampleAt = nil
        lastSuccessfulStreamAt = nil
        lastSuccessfulHealthAt = nil
        lastGPUSampleAt = nil
        backendGPUActivity = nil
        gpuAvailabilityMessage = "Waiting for macOS GPU utilization…"
        gpuHistoryScope = nil
        gpuHistorySource = nil
        gpuHistory.removeAll(keepingCapacity: true)
        historyStartedAt = nil
        tpsHistory.removeAll(keepingCapacity: true)
        toolActivityEvents.removeAll(keepingCapacity: true)
        toolObservationHistory.removeAll(keepingCapacity: true)
        retainedToolEventIDs.removeAll(keepingCapacity: true)
        toolHistoryTruncatedThrough = nil
        sampleDate = clock()
        let archived = chartArchive.history(
            source: historySource, before: sampleDate, now: sampleDate)
        historyStartedAt = archived.availableSince
        chartPresentation = ChartPresentationSnapshot(
            timestamp: sampleDate, supportsToolActivity: kind == .ollama, archive: archived)
        lastChartPublicationAt = nil
    }

    public func updateConnection(
        _ state: BackendConnectionState, message: String? = nil, at date: Date? = nil
    ) {
        let date = date ?? clock()
        expireNativeActivity(at: date)
        healthConnectionState = state
        healthConnectionMessage = message
        if state == .ready { lastSuccessfulHealthAt = date }
        if backendKind == .ollama {
            refreshOllamaConnection(at: date)
        } else {
            setEffectiveConnection(state, message: message)
        }
    }

    public func setDetections(_ backends: [DetectedBackend]) {
        detectedBackends = backends.sorted { $0.id < $1.id }
    }

    public func setSelectionNotice(_ message: String?) {
        selectionNotice = message
    }

    /// Local GPU samples have their own cadence and freshness; a successful
    /// backend health response cannot keep an old GPU measurement alive.
    public func applyGPUSample(_ sample: GPUActivitySample, epoch: UUID) {
        guard epoch == monitoringEpoch, backendKind != nil || sample.scope == .system,
            lastGPUSampleAt.map({ sample.timestamp >= $0 }) ?? true
        else { return }
        lastGPUSampleAt = sample.timestamp
        if gpuHistoryScope != sample.scope
            || (sample.activityPercent != nil && gpuHistorySource != sample.source)
        {
            gpuHistory.removeAll(keepingCapacity: true)
            gpuHistoryScope = sample.scope
            gpuHistorySource = sample.source
            // Never keep another source's trace visible until the next tick.
            // Preserve the TPS trace, time axis, and publication deadline.
            if !chartPresentation.systemGPU.isEmpty {
                chartPresentation = ChartPresentationSnapshot(
                    timestamp: chartPresentation.timestamp,
                    throughput: chartPresentation.throughput,
                    toolActivity: chartPresentation.toolActivity,
                    requestLanes: chartPresentation.requestLanes,
                    toolObservation: chartPresentation.toolObservation,
                    supportsToolActivity: chartPresentation.supportsToolActivity,
                    archive: chartPresentation.archive,
                    historicalRequestLanes: chartPresentation.historicalRequestLanes,
                    historicalToolActivity: chartPresentation.historicalToolActivity)
            }
        }
        let validScope: Bool
        switch sample.scope {
        case .system:
            validScope =
                sample.activityPercent.map { $0 <= 100 } == true && sample.processIDs.isEmpty
        case .backendProcesses:
            validScope = !sample.processIDs.isEmpty
        }
        if let value = sample.activityPercent, value.isFinite, value >= 0,
            validScope, !sample.source.isEmpty
        {
            // Legacy process diagnostics may exceed 100; system utilization cannot.
            backendGPUActivity = sample
            gpuAvailabilityMessage = ""
        } else {
            backendGPUActivity = nil
            gpuAvailabilityMessage =
                sample.unavailableReason
                ?? "macOS GPU utilization is unavailable."
        }
    }

    public func applyBackendSample(_ sample: BackendSample, epoch: UUID) {
        guard epoch == monitoringEpoch, sample.kind == backendKind,
            lastBackendSampleAt.map({ sample.timestamp >= $0 }) ?? true
        else { return }
        lastBackendSampleAt = sample.timestamp
        updateConnection(
            sample.isReady ? .ready : .connecting, message: sample.detail, at: sample.timestamp)
        if sample.kind != .ollama {
            // Counts from the scrape remain direct activity evidence even when
            // that provider's separate readiness endpoint is failing.
            nativeActivity = .native(
                running: sample.runningRequests.flatMap { $0 >= 0 ? $0 : nil },
                queued: sample.queuedRequests.flatMap { $0 >= 0 ? $0 : nil })
            nativeActivityObservedAt = sample.timestamp
        }
        guard sample.isReady else { return }
        if sample.kind == .ollama {
            // Model residency is not activity. Request events own Ollama rates.
            if activeGeneration == nil { currentModel = sample.model }
            if activeGeneration?.state != .running {
                currentTPS = 0
                rateIsAvailable = true
                displayIdleRate(at: sample.timestamp)
            }
            return
        }
        currentModel = sample.model
        throughputBasis = sample.basis
        outputIsEstimated = sample.basis == .estimated
        runningRequests = sample.runningRequests.map { max(0, $0) }
        queuedRequests = sample.queuedRequests.map { max(0, $0) }
        backendOutputTokens = sample.outputTokens.flatMap { $0 >= 0 ? $0 : nil }
        backendPromptTokens = sample.promptTokens.flatMap { $0 >= 0 ? $0 : nil }
        let rate = validRate(sample.currentTPS)
        rateIsAvailable = rate != nil
        // Some backends retain their last average while idle. Keep this separate
        // from current activity, and let a counter collector supply real deltas.
        if sample.basis == .serverReportedAverage, runningRequests == 0 {
            lastMeasuredTPS = rate
            currentTPS = 0
        } else {
            currentTPS = rate ?? 0
        }
        if !rateIsAvailable {
            clearDisplayRate()
        } else if currentTPS == 0, runningRequests == 0, (queuedRequests ?? 0) == 0 {
            displayIdleRate(at: sample.timestamp)
        }
        if let percent = sample.inferenceGPUPercent, percent.isFinite,
            (0...100).contains(percent), let source = sample.gpuSource, !source.isEmpty
        {
            inferenceGPUPercent = percent
            gpuSource = source
        } else {
            inferenceGPUPercent = nil
            gpuSource = nil
        }
    }

    /// Sample explicitly for deterministic tests, or let `startSampling()` call
    /// this twice per second. The inclusive window retains its boundary point.
    /// A repeated timestamp replaces its point; older timestamps are ignored.
    public func sample(at date: Date? = nil) {
        let date = date ?? clock()
        let replacingLatest = tpsHistory.last?.timestamp == date
        if let last = tpsHistory.last {
            guard date >= last.timestamp else { return }
            if date == last.timestamp {
                tpsHistory.removeLast()
                if gpuHistory.last?.timestamp == date { gpuHistory.removeLast() }
                if toolObservationHistory.last?.timestamp == date {
                    toolObservationHistory.removeLast()
                }
            }
        }
        sampleDate = date
        expireNativeActivity(at: date)
        // In proxy/ollama mode the displayed rate is the sum of every open
        // request's live rate. Refresh it against this sample time so a stalled
        // request (no chunk in `freshnessInterval`) drops out of the trace. The
        // zeroing branches below can still override it when the active request is
        // loading or has itself gone stale. Native backends own `currentTPS`
        // through `applyBackendSample`, so the proxy sum must not clobber it.
        if backendKind == nil || backendKind == .ollama {
            recomputeAggregateRate(at: date)
        }
        if let lastGPUSampleAt,
            date.timeIntervalSince(lastGPUSampleAt) > Self.freshnessInterval
        {
            backendGPUActivity = nil
            gpuAvailabilityMessage = "GPU activity is no longer updating."
        }
        if backendKind == .ollama {
            refreshOllamaConnection(at: date)
        } else if let lastBackendSampleAt, backendKind != nil, connectionState == .ready,
            date.timeIntervalSince(lastBackendSampleAt) > Self.freshnessInterval
        {
            updateConnection(
                .unavailable, message: "Backend telemetry is no longer updating.", at: date)
        }
        if requestIsAwaitingOutput, backendKind == nil || connectionState == .ready {
            // A healthy request produces zero response tokens while loading.
            // Keep history and the displayed rate consistent through this wait.
            currentTPS = 0
            rateIsAvailable = true
        } else if activeGeneration?.state == .running, let lastRequestSampleAt,
            date.timeIntervalSince(lastRequestSampleAt) > Self.freshnessInterval
        {
            // After output begins, health polls cannot refresh an older estimate.
            currentTPS = 0
            rateIsAvailable = false
            clearDisplayRate()
        }
        publishDisplayRateIfDue(at: date)
        if historyStartedAt == nil { historyStartedAt = date }
        // Sleep or delayed sampling must not look like a continuous measurement.
        if !replacingLatest, let last = tpsHistory.last, date.timeIntervalSince(last.timestamp) > 2
        {
            tpsHistory.append(
                TimeSeriesPoint(
                    timestamp: last.timestamp.addingTimeInterval(0.5), value: 0, isAvailable: false)
            )
        }
        let cutoff = date.addingTimeInterval(-Self.chartWindow)
        if !replacingLatest, let last = gpuHistory.last, date.timeIntervalSince(last.timestamp) > 2
        {
            gpuHistory.append(
                TimeSeriesPoint(
                    timestamp: last.timestamp.addingTimeInterval(0.5), value: 0, isAvailable: false)
            )
        }
        tpsHistory.removeAll { $0.timestamp < cutoff }
        tpsHistory.append(
            TimeSeriesPoint(
                timestamp: date, value: currentTPS, isAvailable: rateIsAvailable))
        if tpsHistory.count > Self.maxHistorySamples {
            tpsHistory.removeFirst(tpsHistory.count - Self.maxHistorySamples)
        }
        gpuHistory.removeAll { $0.timestamp < cutoff }
        let gpuValue = backendGPUActivity?.activityPercent
        gpuHistory.append(
            TimeSeriesPoint(
                timestamp: date, value: gpuValue ?? 0, isAvailable: gpuValue != nil))
        if gpuHistory.count > Self.maxHistorySamples {
            gpuHistory.removeFirst(gpuHistory.count - Self.maxHistorySamples)
        }
        if !replacingLatest, let last = toolObservationHistory.last,
            date.timeIntervalSince(last.timestamp) > 2
        {
            toolObservationHistory.append(
                TimeSeriesPoint(
                    timestamp: last.timestamp.addingTimeInterval(0.5), value: 0,
                    isAvailable: false))
        }
        if supportsToolActivity || !toolObservationHistory.isEmpty {
            let observingTools =
                supportsToolActivity && proxyState == .listening
                && (backendKind == nil || connectionState == .ready)
            toolObservationHistory.append(
                TimeSeriesPoint(timestamp: date, value: 0, isAvailable: observingTools))
        }
        trimToolActivity(at: date)
        trimRetiredRequestLanes(at: date)
        chartArchive.record(
            source: historySource, at: date,
            throughput: TimeSeriesPoint(
                timestamp: date, value: currentTPS, isAvailable: rateIsAvailable),
            gpu: TimeSeriesPoint(
                timestamp: date, value: systemGPUUtilizationPercent ?? 0,
                isAvailable: systemGPUUtilizationPercent != nil),
            toolObservation: TimeSeriesPoint(
                timestamp: date, value: 0,
                isAvailable: supportsToolActivity && proxyState == .listening
                    && (backendKind == nil || connectionState == .ready)))
        publishChartPresentationIfDue(at: date)
    }

    /// Sampling continues while idle so completed activity ages off the chart.
    /// The task holds the store weakly while sleeping and is safe to restart.
    public func startSampling() {
        guard samplingTask == nil else { return }
        sample()
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.sample()
            }
        }
    }

    public func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    /// A successful stream can outlive a delayed or failed health probe, but its
    /// evidence expires independently. Explicit configuration errors still win.
    private func refreshOllamaConnection(at date: Date) {
        guard healthConnectionState != .needsConfiguration,
            healthConnectionState != .detecting
        else {
            setEffectiveConnection(healthConnectionState, message: healthConnectionMessage)
            return
        }
        let freshStream = isFresh(lastSuccessfulStreamAt, at: date)
        let freshHealth =
            healthConnectionState == .ready && isFresh(lastSuccessfulHealthAt, at: date)
        if freshStream || freshHealth {
            setEffectiveConnection(.ready, message: healthConnectionMessage)
        } else if lastSuccessfulStreamAt != nil || lastSuccessfulHealthAt != nil {
            setEffectiveConnection(
                .unavailable,
                message: healthConnectionMessage ?? "Backend telemetry is no longer updating.")
        } else {
            setEffectiveConnection(healthConnectionState, message: healthConnectionMessage)
        }
    }

    private func isFresh(_ evidence: Date?, at date: Date) -> Bool {
        guard let evidence else { return false }
        return date.timeIntervalSince(evidence) <= Self.freshnessInterval
    }

    private func setEffectiveConnection(_ state: BackendConnectionState, message: String?) {
        connectionState = state
        connectionMessage = message
        if state != .ready {
            currentTPS = 0
            rateIsAvailable = false
            clearDisplayRate()
            runningRequests = nil
            queuedRequests = nil
            inferenceGPUPercent = nil
            gpuSource = nil
        }
    }

    private func clearDisplayRate() {
        displayTPS = nil
        displayRateIsEstimated = false
        displayUpdatedAt = nil
        lastRatePublicationAt = nil
    }

    private func displayIdleRate(at date: Date) {
        displayTPS = 0
        displayRateIsEstimated = false
        displayUpdatedAt = date
        lastRatePublicationAt = nil
    }

    private func publishDisplayRateIfDue(at date: Date) {
        guard backendKind == nil || connectionState == .ready else {
            clearDisplayRate()
            return
        }
        guard rateIsAvailable else {
            clearDisplayRate()
            return
        }
        if backendKind != nil, backendKind != .ollama,
            currentTPS == 0, runningRequests == 0, (queuedRequests ?? 0) == 0
        {
            displayIdleRate(at: date)
            return
        }
        if backendKind == nil || backendKind == .ollama {
            guard activeGeneration?.state == .running else {
                displayIdleRate(at: date)
                return
            }
            // Snapshot elapsed starts with generated text, so model loading does
            // not consume the estimate's one-second settling period. Retain zero
            // during that brief interval instead of flashing an unavailable mark.
            guard generationElapsed >= 1, outputTokens > 0 else {
                displayIdleRate(at: date)
                return
            }
        }
        guard lastRatePublicationAt.map({ date.timeIntervalSince($0) >= 1 }) ?? true else {
            return
        }
        displayTPS = currentTPS
        displayRateIsEstimated = isRateEstimated
        displayUpdatedAt = date
        lastRatePublicationAt = date
    }

    private func publishChartPresentationIfDue(at date: Date) {
        guard lastChartPublicationAt.map({ date.timeIntervalSince($0) >= 1 }) ?? true else {
            return
        }
        let firstRaw =
            [
                tpsHistory.first?.timestamp, gpuHistory.first?.timestamp,
                toolObservationHistory.first?.timestamp,
            ].compactMap { $0 }.min() ?? date
        let archived = chartArchive.history(source: historySource, before: firstRaw, now: date)
        let historyInterval = DateInterval(start: date.addingTimeInterval(-86_400), end: date)
        let savedLanes = usageHistory.requestLanes(source: historySource, interval: historyInterval)
        let savedTools = usageHistory.toolEvents(source: historySource, interval: historyInterval)
        chartPresentation = ChartPresentationSnapshot(
            timestamp: date, throughput: tpsHistory, systemGPU: systemGPUHistory,
            toolActivity: toolActivityEvents, requestLanes: requestLanes,
            toolObservation: toolObservationHistory, supportsToolActivity: supportsToolActivity,
            archive: archived, historicalRequestLanes: savedLanes,
            historicalToolActivity: savedTools)
        lastChartPublicationAt = date
    }

    private var supportsToolActivity: Bool {
        backendKind == .ollama || (backendKind == nil && proxyState == .listening)
    }

    /// Bound retained metadata as well as time. If a burst exceeds the cap, drop
    /// observation coverage through the discarded events instead of charting a
    /// falsely low rate from an incomplete interval.
    private func trimToolActivity(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.chartWindow)
        toolActivityEvents.removeAll { $0.timestamp < cutoff }
        if toolActivityEvents.count > Self.maxToolActivityEvents {
            let excess = toolActivityEvents.count - Self.maxToolActivityEvents
            let through = toolActivityEvents[excess - 1].timestamp
            toolHistoryTruncatedThrough = max(toolHistoryTruncatedThrough ?? through, through)
        }
        if let through = toolHistoryTruncatedThrough {
            toolActivityEvents.removeAll { $0.timestamp <= through }
            toolObservationHistory.removeAll { $0.timestamp <= through }
        }
        retainedToolEventIDs = Set(toolActivityEvents.map(\.id))
        toolObservationHistory.removeAll { $0.timestamp < cutoff }
        if toolObservationHistory.count > Self.maxHistorySamples {
            toolObservationHistory.removeFirst(
                toolObservationHistory.count - Self.maxHistorySamples)
        }
    }

    private func ownsRunningGeneration(_ requestID: UUID) -> Bool {
        activeGeneration?.id == requestID && activeGeneration?.state == .running
    }

    /// The displayed throughput is the sum of every open request's own live
    /// rate, so concurrent streams add together instead of one overwriting the
    /// other. A terminal request is already removed from `openProxyRequests`
    /// before this is called, so finished work stops contributing immediately.
    /// A non-terminal request that has not sent a chunk in `freshnessInterval`
    /// has stalled (10 missed 500 ms samples) and drops out of the sum, matching
    /// the judgment `sample()` already applies to the active request. The active
    /// request is additionally protected while it is still loading a model
    /// (`requestIsAwaitingOutput`); a slow initial load may briefly drop another
    /// open request from the sum until its first chunk refreshes its timestamp.
    private func recomputeAggregateRate(at date: Date) {
        currentTPS = openProxyRequests.values.reduce(0) { total, request in
            guard date.timeIntervalSince(request.lastUpdateAt) <= Self.freshnessInterval
            else { return total }
            return total + request.liveTPS
        }
    }

    /// Terminal, failure, and cancellation events remove one request from the
    /// sum without applying time-based staleness to the survivors: a sibling that
    /// is still actively streaming must not be aged out merely because another
    /// request finished. Only the time-driven sampling loop can age a still-open
    /// request out of the summed rate.
    private func recomputePlainSum() {
        currentTPS = openProxyRequests.values.reduce(0) { $0 + $1.liveTPS }
    }

    private func closeObservedRequest(_ requestID: UUID, at end: Date) {
        guard let observed = openProxyRequests.removeValue(forKey: requestID) else { return }
        // Keep the request as a finished lane so it stays visible on the chart
        // until its end time scrolls past the window cutoff.
        retiredRequestLanes.append(
            RequestLane(
                id: requestID, startedAt: observed.startedAt, endedAt: end,
                model: observed.model, outputTokens: observed.outputTokens,
                outputIsEstimated: observed.outputIsEstimated,
                liveTPS: observed.liveTPS, terminal: true))
        trimRetiredRequestLanes(at: end)
        // Keep recent terminal identities to reject duplicate begins without
        // accumulating every request ID throughout a long-running app session.
        retiredProxyRequestIDs.append(requestID)
        if retiredProxyRequestIDs.count > Self.maxRetiredProxyRequestIDs {
            let trimCount = Self.maxRetiredProxyRequestIDs / 2
            for id in retiredProxyRequestIDs.prefix(trimCount) {
                seenProxyRequestIDs.remove(id)
            }
            retiredProxyRequestIDs.removeFirst(trimCount)
        }
    }

    /// The start time of a request the store still knows about, open or
    /// recently finished, so a request's tool activity is validated against
    /// its own lane rather than the current owner's.
    private func requestStartedAt(for requestID: UUID) -> Date? {
        if let open = openProxyRequests[requestID] { return open.startedAt }
        return retiredRequestLanes.first(where: { $0.id == requestID })?.startedAt
    }

    /// Drop finished lanes whose end time has scrolled past the window cutoff,
    /// then bound the count. Oldest finished lanes are evicted first.
    private func trimRetiredRequestLanes(at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.chartWindow)
        retiredRequestLanes.removeAll { $0.endedAt.map { $0 < cutoff } ?? false }
        if retiredRequestLanes.count > Self.maxRetiredRequestLanes {
            let excess = retiredRequestLanes.count - Self.maxRetiredRequestLanes
            for lane in retiredRequestLanes.prefix(excess) {
                seenProxyRequestIDs.remove(lane.id)
            }
            retiredRequestLanes.removeFirst(excess)
        }
    }

    /// Every in-flight request plus any finished request still within the
    /// chart window, oldest first, each drawn as its own lane.
    public var requestLanes: [RequestLane] {
        let cutoff = sampleDate.addingTimeInterval(-Self.chartWindow)
        let open = openProxyRequests.map { (id, request) in
            RequestLane(
                id: id, startedAt: request.startedAt, endedAt: nil,
                model: request.model, outputTokens: request.outputTokens,
                outputIsEstimated: request.outputIsEstimated,
                liveTPS: request.liveTPS, terminal: false)
        }
        let retired = retiredRequestLanes.filter { $0.isVisible(at: cutoff) }
        return (open + retired).sorted { $0.startedAt < $1.startedAt }
    }

    private func expireNativeActivity(at date: Date) {
        guard let nativeActivityObservedAt,
            date.timeIntervalSince(nativeActivityObservedAt) > Self.freshnessInterval
        else { return }
        nativeActivity = .unknown
    }

    private var requestIsAwaitingOutput: Bool {
        (backendKind == nil || backendKind == .ollama)
            && activeGeneration?.state == .running
            && !requestHasOutputEvidence && !requestHasInvalidRate
    }

    private func validRate(_ rate: Double?) -> Double? {
        guard let rate, rate.isFinite, rate >= 0 else { return nil }
        return rate
    }
}

public struct ChartPresentationSnapshot: Sendable, Equatable {
    /// Identifies a held publication without comparing entire raw histories.
    let publicationID = UUID()
    public let timestamp: Date
    public let throughput: [TimeSeriesPoint]
    public let systemGPU: [TimeSeriesPoint]
    public let toolActivity: [ToolActivityEvent]
    /// One lane per in-flight or recently-finished request, oldest first.
    public let requestLanes: [RequestLane]
    /// Zero-valued samples describe when observing tool activity was available.
    public let toolObservation: [TimeSeriesPoint]
    public let supportsToolActivity: Bool
    public let archive: ArchivedChartHistory
    public let historicalRequestLanes: [RequestLane]
    public let historicalToolActivity: [ToolActivityEvent]

    public init(
        timestamp: Date, throughput: [TimeSeriesPoint] = [], systemGPU: [TimeSeriesPoint] = [],
        toolActivity: [ToolActivityEvent] = [], requestLanes: [RequestLane] = [],
        toolObservation: [TimeSeriesPoint] = [], supportsToolActivity: Bool = false,
        archive: ArchivedChartHistory = .empty, historicalRequestLanes: [RequestLane] = [],
        historicalToolActivity: [ToolActivityEvent] = []
    ) {
        self.timestamp = timestamp
        self.throughput = throughput
        self.systemGPU = systemGPU
        self.toolActivity = toolActivity
        self.requestLanes = requestLanes
        self.toolObservation = toolObservation
        self.supportsToolActivity = supportsToolActivity
        self.archive = archive
        self.historicalRequestLanes = historicalRequestLanes
        self.historicalToolActivity = historicalToolActivity
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.timestamp == rhs.timestamp && lhs.throughput == rhs.throughput
            && lhs.systemGPU == rhs.systemGPU
            && lhs.toolActivity == rhs.toolActivity && lhs.requestLanes == rhs.requestLanes
            && lhs.toolObservation == rhs.toolObservation
            && lhs.supportsToolActivity == rhs.supportsToolActivity
            && lhs.archive == rhs.archive
            && lhs.historicalRequestLanes == rhs.historicalRequestLanes
            && lhs.historicalToolActivity == rhs.historicalToolActivity
    }
}

public struct ActiveGeneration: Sendable, Equatable {
    public let id: UUID
    public var model: String
    public let startedAt: Date
    public var state: GenerationState

    public init(
        id: UUID = UUID(), model: String, startedAt: Date, state: GenerationState
    ) {
        self.id = id
        self.model = model
        self.startedAt = startedAt
        self.state = state
    }
}

public enum GenerationState: String, Sendable {
    case running, completed, errored, cancelled
}
