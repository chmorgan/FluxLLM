import Foundation
import Observation

/// A narrow lifecycle seam lets backend switching be tested without opening a port.
@MainActor
public protocol MonitoringProxy: AnyObject {
    func start() async throws
    func stop() async
}

extension ProxyManager: MonitoringProxy {}

/// Owns one collection session at a time. UI code never starts or restarts a proxy.
@MainActor
@Observable
public final class MonitoringCoordinator {
    public private(set) var selectedConfiguration: BackendConfiguration?
    public private(set) var isApplying = false

    private let settings: AppSettings
    private let store: MetricsStore
    private let client: any BackendClientProtocol
    private let gpuMonitor: any BackendGPUMonitoring
    private let proxyFactory: @MainActor (BackendConfiguration, UUID) -> any MonitoringProxy
    private let pollInterval: Duration
    private let discoveryInterval: Duration
    private let gpuInterval: Duration
    private var proxy: (any MonitoringProxy)?
    private var proxyStarted = false
    private var running = false
    private var revision = 0
    private var epoch = UUID()
    private var monitorTask: Task<Void, Never>?
    private var gpuTask: Task<Void, Never>?
    private var operationTask: Task<Void, Error>?

    public init(
        settings: AppSettings, store: MetricsStore,
        client: any BackendClientProtocol = HTTPBackendClient(),
        gpuMonitor: any BackendGPUMonitoring = SystemGPUMonitor(),
        proxyFactory: (@MainActor (BackendConfiguration, UUID) -> any MonitoringProxy)? = nil,
        pollInterval: Duration = .seconds(1), discoveryInterval: Duration = .seconds(5),
        gpuInterval: Duration = .seconds(1)
    ) {
        self.settings = settings
        self.store = store
        self.client = client
        self.gpuMonitor = gpuMonitor
        self.pollInterval = pollInterval
        self.discoveryInterval = discoveryInterval
        self.gpuInterval = gpuInterval
        self.proxyFactory =
            proxyFactory ?? { configuration, epoch in
                ProxyManager(
                    listenPort: configuration.proxyPort,
                    ollamaHost: AppSettings.normalizedHost(
                        configuration.baseURL.host ?? "localhost"),
                    ollamaPort: configuration.baseURL.port ?? 11434,
                    metricsStore: store, eventEpoch: epoch)
            }
    }

    public func start() async {
        guard !running else { return }
        running = true
        do { try await applySettings() } catch is CancellationError {} catch {
            store.updateConnection(.needsConfiguration, message: error.localizedDescription)
        }
    }

    /// Validation precedes shutdown; a malformed draft cannot stop a working monitor.
    public func applySettings() async throws {
        guard running else { throw CancellationError() }
        if let kind = settings.backendSelection.kind { _ = try settings.configuration(for: kind) }
        revision += 1
        let currentRevision = revision
        operationTask?.cancel()
        monitorTask?.cancel()
        gpuTask?.cancel()
        let previous = operationTask
        isApplying = true
        let operation = Task { @MainActor in
            if let previous { _ = await previous.result }
            try self.checkSession(currentRevision)
            await self.endCollector()
            try self.checkSession(currentRevision)
            await self.client.reset()
            await self.gpuMonitor.reset()
            try self.checkSession(currentRevision)
            self.selectedConfiguration = nil
            self.epoch = UUID()
            self.store.beginBackendSession(
                kind: self.settings.backendSelection.kind, epoch: self.epoch)
            self.store.updateConnection(.detecting, message: nil)
            let detections = await self.detectBackends()
            try self.checkSession(currentRevision)
            let configuration = try self.selectConfiguration(from: detections)
            if let configuration {
                await self.activate(configuration)
                _ = await self.poll(configuration, revision: currentRevision, epoch: self.epoch)
            } else {
                self.startGPUMonitoring(nil)
            }
            try self.checkSession(currentRevision)
            self.monitorTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.monitor(revision: currentRevision)
            }
        }
        operationTask = operation
        defer {
            if revision == currentRevision {
                isApplying = false
                operationTask = nil
            }
        }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Discovery refreshes Settings without interrupting an active generation.
    public func rescan() async {
        guard running else { return }
        let currentRevision = revision
        let detections = await detectBackends()
        guard running, currentRevision == revision, !Task.isCancelled else { return }
        store.setDetections(detections)
        publishSelectionNotice(detections)
    }

    public func stop() async {
        running = false
        revision += 1
        operationTask?.cancel()
        monitorTask?.cancel()
        gpuTask?.cancel()
        if let operationTask { _ = await operationTask.result }
        self.operationTask = nil
        await endCollector()
        selectedConfiguration = nil
        isApplying = false
        epoch = UUID()
        store.beginBackendSession(kind: nil, epoch: epoch)
    }

    private func checkSession(_ expected: Int) throws {
        try Task.checkCancellation()
        guard running, revision == expected else { throw CancellationError() }
    }

    private func endCollector() async {
        let oldMonitor = monitorTask
        monitorTask = nil
        oldMonitor?.cancel()
        let oldGPU = gpuTask
        gpuTask = nil
        oldGPU?.cancel()
        await oldMonitor?.value
        await oldGPU?.value
        if let proxy { await proxy.stop() }
        proxy = nil
        proxyStarted = false
    }

    private func activate(_ configuration: BackendConfiguration) async {
        // A system GPU loop can already be running while no backend is selected.
        // Await its cancellation before publishing the new session's epoch.
        let oldGPU = gpuTask
        gpuTask = nil
        oldGPU?.cancel()
        await oldGPU?.value
        guard running, !Task.isCancelled else { return }
        selectedConfiguration = configuration
        epoch = UUID()
        var sourceURL = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        sourceURL?.user = nil
        sourceURL?.password = nil
        sourceURL?.query = nil
        sourceURL?.fragment = nil
        let sourceID =
            "\(configuration.kind.rawValue)|\(sourceURL?.string ?? configuration.kind.rawValue)|\(configuration.model ?? "")"
        store.beginBackendSession(kind: configuration.kind, epoch: epoch, sourceID: sourceID)
        store.updateConnection(.connecting, message: nil)
        if configuration.kind == .ollama {
            proxy = proxyFactory(configuration, epoch)
        }
        startGPUMonitoring(configuration)
    }

    private func startGPUMonitoring(_ configuration: BackendConfiguration?) {
        let expectedRevision = revision
        let expectedEpoch = epoch
        gpuTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.running, self.revision == expectedRevision, !Task.isCancelled {
                let sample = await self.gpuMonitor.sample(configuration)
                guard self.running, self.revision == expectedRevision,
                    self.epoch == expectedEpoch, !Task.isCancelled
                else { return }
                self.store.applyGPUSample(sample, epoch: expectedEpoch)
                do { try await Task.sleep(for: self.gpuInterval) } catch { return }
            }
        }
    }

    private func monitor(revision expected: Int) async {
        var failures = 0
        while running, revision == expected, !Task.isCancelled {
            let delay =
                selectedConfiguration == nil
                ? discoveryInterval
                : failures == 0 ? pollInterval : .seconds(min(30, 1 << min(failures, 5)))
            do { try await Task.sleep(for: delay) } catch { return }
            guard running, revision == expected, !Task.isCancelled else { return }
            if selectedConfiguration == nil {
                let detections = await detectBackends()
                guard running, revision == expected, !Task.isCancelled else { return }
                do {
                    if let configuration = try selectConfiguration(from: detections) {
                        await activate(configuration)
                    }
                } catch {
                    store.updateConnection(.needsConfiguration, message: error.localizedDescription)
                }
            }
            if let configuration = selectedConfiguration {
                let success = await poll(configuration, revision: expected, epoch: epoch)
                failures = success ? 0 : min(failures + 1, 5)
            }
        }
    }

    private func poll(_ configuration: BackendConfiguration, revision expected: Int, epoch: UUID)
        async -> Bool
    {
        do {
            if let proxy, !proxyStarted {
                try await proxy.start()
                try checkSession(expected)
                proxyStarted = true
            }
            let sample = try await client.sample(configuration)
            try checkSession(expected)
            guard self.epoch == epoch else { return false }
            store.applyBackendSample(sample, epoch: epoch)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard running, revision == expected, self.epoch == epoch else { return false }
            store.updateConnection(Self.failureState(error), message: error.localizedDescription)
            return false
        }
    }

    private static func failureState(_ error: Error) -> BackendConnectionState {
        guard let error = error as? BackendClientError else { return .unavailable }
        switch error {
        case .invalidEndpoint, .unsupportedMetrics, .configurationRequired:
            return .needsConfiguration
        case .httpStatus(let status) where [400, 401, 403, 404, 501].contains(status):
            return .needsConfiguration
        default:
            return .unavailable
        }
    }

    private func selectConfiguration(from detections: [DetectedBackend]) throws
        -> BackendConfiguration?
    {
        store.setDetections(detections)
        publishSelectionNotice(detections)
        if let kind = settings.backendSelection.kind {
            let configuration = try settings.configuration(for: kind)
            if let different = detections.first(where: {
                Self.endpointKey($0.baseURL) == Self.endpointKey(configuration.baseURL)
                    && $0.kind != kind
            }) {
                store.updateConnection(
                    .needsConfiguration,
                    message:
                        "This endpoint is \(different.kind.title), but \(kind.title) is selected. Open Settings to choose the matching system."
                )
                return nil
            }
            return configuration
        }
        let chosen: DetectedBackend?
        if detections.count == 1 {
            chosen = detections.first
        } else {
            chosen = detections.first { $0.id == settings.lastAutomaticBackendID }
        }
        guard let chosen else {
            store.updateConnection(
                .needsConfiguration,
                message: detections.isEmpty
                    ? "No supported LLM backend was found. Open Settings to configure one."
                    : "Several LLM backends were found. Choose one in Settings.")
            return nil
        }
        settings.lastAutomaticBackendID = chosen.id
        let template = try settings.configuration(for: chosen.kind)
        return BackendConfiguration(
            kind: chosen.kind, baseURL: chosen.baseURL,
            model: template.model, proxyPort: template.proxyPort)
    }

    private func publishSelectionNotice(_ detections: [DetectedBackend]) {
        guard let kind = settings.backendSelection.kind else {
            store.setSelectionNotice(nil)
            return
        }
        let others = Set(detections.filter { $0.kind != kind }.map { $0.kind.title }).sorted()
        store.setSelectionNotice(
            others.isEmpty
                ? nil
                : "\(others.joined(separator: ", ")) detected. \(kind.title) remains your selected system."
        )
    }

    private func detectBackends() async -> [DetectedBackend] {
        let urls = detectionURLs()
        let client = client
        return await withTaskGroup(of: DetectedBackend?.self) { group in
            for url in urls {
                group.addTask { try? await client.detect(at: url) }
            }
            var found: [DetectedBackend] = []
            for await result in group {
                if let result { found.append(result) }
            }
            return found.sorted { $0.id < $1.id }
        }
    }

    /// Saved endpoints first, then three known loopback ports. Never scan a network.
    func detectionURLs() -> [URL] {
        let configured = BackendKind.allCases.compactMap {
            try? settings.configuration(for: $0).baseURL
        }
        let defaults = BackendKind.allCases.compactMap { URL(string: $0.defaultEndpoint) }
        var seen = Set<String>()
        return (configured + defaults).filter { seen.insert(Self.endpointKey($0)).inserted }
    }

    private static func endpointKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        if ["localhost", "localhost."].contains(components.host?.lowercased() ?? "") {
            components.host = "127.0.0.1"
        }
        return components.string ?? url.absoluteString
    }
}
