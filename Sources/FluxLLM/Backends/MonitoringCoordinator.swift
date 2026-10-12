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
    private var applyRevision = 0
    private var epoch = UUID()
    private var monitorTask: Task<Void, Never>?
    private var monitorDelayTask: Task<Void, Error>?
    private var pollRequested = false
    private var gpuTask: Task<Void, Never>?
    private var operationTask: Task<Void, Error>?
    private var appliedSettings: SettingsSnapshot?

    /// Capture every connection draft before discovery suspends on network or process reads.
    private struct SettingsSnapshot {
        let selection: BackendSelection
        let lastAutomaticBackendID: String?
        let configurations: [BackendKind: Result<BackendConfiguration, Error>]

        @MainActor
        init(_ settings: AppSettings) {
            selection = settings.backendSelection
            lastAutomaticBackendID = settings.lastAutomaticBackendID
            configurations = Dictionary(
                uniqueKeysWithValues: BackendKind.allCases.map { kind in
                    (kind, Result { try settings.configuration(for: kind) })
                })
        }

        func configuration(for kind: BackendKind) throws -> BackendConfiguration {
            try configurations[kind]!.get()
        }
    }

    private struct Selection {
        let configuration: BackendConfiguration?
        var message: String? = nil
        var automaticBackendID: String? = nil
    }

    public init(
        settings: AppSettings, store: MetricsStore,
        client: any BackendClientProtocol = UnslothBackendClient(),
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
        let snapshot = SettingsSnapshot(settings)
        if let kind = snapshot.selection.kind { _ = try snapshot.configuration(for: kind) }
        applyRevision += 1
        let currentApply = applyRevision
        operationTask?.cancel()
        let previous = operationTask
        isApplying = true
        let operation = Task { @MainActor in
            if let previous { _ = await previous.result }
            try self.checkApply(currentApply)
            if self.canKeepCollector(using: snapshot) {
                self.appliedSettings = snapshot
                self.publishSelectionNotice(
                    self.store.detectedBackends, selection: snapshot.selection)
                self.requestPollIfUnhealthy()
                return
            }
            let detections = await self.detectBackends(using: snapshot)
            try self.checkApply(currentApply)
            let selection = try self.selectConfiguration(from: detections, using: snapshot)
            self.publishSelection(selection, detections: detections, using: snapshot)

            if let configuration = selection.configuration,
                let active = self.selectedConfiguration,
                self.hasStableCollector, Self.equivalent(configuration, active)
            {
                // Keep request identity, rates, history, and ordinary failure retries intact.
                self.appliedSettings = snapshot
                self.requestPollIfUnhealthy()
                return
            }
            if selection.configuration == nil, self.canKeepAutomaticTarget(using: snapshot) {
                // Changes to other backends cannot turn a failed rescan into a session boundary.
                self.appliedSettings = snapshot
                self.requestPollIfUnhealthy()
                return
            }

            self.revision += 1
            let currentRevision = self.revision
            await self.endCollector()
            try self.checkApply(currentApply)
            await self.client.reset()
            try self.checkApply(currentApply)
            await self.gpuMonitor.reset()
            try self.checkApply(currentApply)
            self.appliedSettings = snapshot
            self.selectedConfiguration = nil
            if let configuration = selection.configuration {
                await self.activate(configuration)
                try self.checkApply(currentApply)
                _ = await self.poll(configuration, revision: currentRevision, epoch: self.epoch)
            } else {
                self.epoch = UUID()
                self.store.beginBackendSession(kind: snapshot.selection.kind, epoch: self.epoch)
                self.store.updateConnection(.needsConfiguration, message: selection.message)
                self.startGPUMonitoring(nil)
            }
            try self.checkApply(currentApply)
            self.monitorTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.monitor(revision: currentRevision)
            }
        }
        operationTask = operation
        defer {
            if applyRevision == currentApply {
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
        let currentApply = applyRevision
        let snapshot = appliedSettings ?? SettingsSnapshot(settings)
        let detections = await detectBackends(using: snapshot)
        guard running, currentRevision == revision, currentApply == applyRevision,
            !Task.isCancelled
        else { return }
        store.setDetections(detections)
        publishSelectionNotice(detections, selection: snapshot.selection)
    }

    public func stop() async {
        running = false
        revision += 1
        applyRevision += 1
        operationTask?.cancel()
        monitorTask?.cancel()
        monitorDelayTask?.cancel()
        gpuTask?.cancel()
        if let operationTask { _ = await operationTask.result }
        self.operationTask = nil
        await endCollector()
        selectedConfiguration = nil
        appliedSettings = nil
        isApplying = false
        epoch = UUID()
        store.beginBackendSession(kind: nil, epoch: epoch)
    }

    private func checkSession(_ expected: Int) throws {
        try Task.checkCancellation()
        guard running, revision == expected else { throw CancellationError() }
    }

    private func checkApply(_ expected: Int) throws {
        try Task.checkCancellation()
        guard running, applyRevision == expected else { throw CancellationError() }
    }

    private func endCollector() async {
        let oldMonitor = monitorTask
        monitorTask = nil
        oldMonitor?.cancel()
        let oldDelay = monitorDelayTask
        monitorDelayTask = nil
        oldDelay?.cancel()
        pollRequested = false
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
            if !pollRequested {
                let sleep = Task { try await Task.sleep(for: delay) }
                monitorDelayTask = sleep
                do { try await sleep.value } catch {
                    if Task.isCancelled { return }
                }
                monitorDelayTask = nil
            }
            guard running, revision == expected, !Task.isCancelled else { return }
            // Every Apply received during the same sleep is satisfied by this one poll.
            pollRequested = false
            if selectedConfiguration == nil {
                guard let snapshot = appliedSettings else { return }
                let detections = await detectBackends(using: snapshot)
                guard running, revision == expected, !Task.isCancelled else { return }
                do {
                    let selection = try selectConfiguration(from: detections, using: snapshot)
                    publishSelection(selection, detections: detections, using: snapshot)
                    if let configuration = selection.configuration {
                        await activate(configuration)
                    } else {
                        store.updateConnection(.needsConfiguration, message: selection.message)
                    }
                } catch {
                    store.updateConnection(.needsConfiguration, message: error.localizedDescription)
                }
            }
            if let configuration = selectedConfiguration {
                let success = await poll(configuration, revision: expected, epoch: epoch)
                failures = success ? 0 : min(failures + 1, 5)
                if success, store.connectionState == .ready { pollRequested = false }
            }
        }
    }

    private func requestPollIfUnhealthy() {
        guard store.connectionState != .ready else { return }
        pollRequested = true
        monitorDelayTask?.cancel()
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
            guard running, revision == expected, self.epoch == epoch, !Task.isCancelled else {
                return false
            }
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

    private func selectConfiguration(
        from detections: [DetectedBackend], using snapshot: SettingsSnapshot
    ) throws -> Selection {
        if let kind = snapshot.selection.kind {
            let configuration = try snapshot.configuration(for: kind)
            if let different = detections.first(where: {
                Self.endpointKey($0.baseURL) == Self.endpointKey(configuration.baseURL)
                    && $0.kind != kind
            }) {
                return Selection(
                    configuration: nil,
                    message:
                        "This endpoint is \(different.kind.title), but \(kind.title) is selected. Open Settings to choose the matching system."
                )
            }
            return Selection(configuration: configuration)
        }
        let chosen: DetectedBackend?
        if detections.count == 1 {
            chosen = detections.first
        } else {
            chosen = detections.first { $0.id == snapshot.lastAutomaticBackendID }
        }
        guard let chosen else {
            return Selection(
                configuration: nil,
                message: detections.isEmpty
                    ? "No supported LLM backend was found. Open Settings to configure one."
                    : "Several LLM backends were found. Choose one in Settings.")
        }
        let template = try snapshot.configuration(for: chosen.kind)
        return Selection(
            configuration: configuration(template, at: chosen.baseURL),
            automaticBackendID: chosen.id)
    }

    private func publishSelection(
        _ selection: Selection, detections: [DetectedBackend], using snapshot: SettingsSnapshot
    ) {
        store.setDetections(detections)
        publishSelectionNotice(detections, selection: snapshot.selection)
        if let id = selection.automaticBackendID { settings.lastAutomaticBackendID = id }
    }

    private func publishSelectionNotice(
        _ detections: [DetectedBackend], selection: BackendSelection
    ) {
        guard let kind = selection.kind else {
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

    private func detectBackends(using snapshot: SettingsSnapshot) async -> [DetectedBackend] {
        let urls = detectionURLs(using: snapshot)
        var candidates = BackendKind.allCases.compactMap {
            try? snapshot.configuration(for: $0)
        }
        if let active = selectedConfiguration,
            let template = try? snapshot.configuration(for: active.kind)
        {
            // Automatic discovery may use an address different from its saved template.
            // Probe that address with the new credentials, never the old session's key.
            candidates.removeAll {
                $0.kind == active.kind
                    && Self.endpointKey($0.baseURL) == Self.endpointKey(active.baseURL)
            }
            candidates.insert(configuration(template, at: active.baseURL), at: 0)
        }
        let configurations = candidates
        let client = client
        async let local = client.discoverLocalBackends(configurations: configurations)
        let probed = await withTaskGroup(of: DetectedBackend?.self) { group in
            for url in urls {
                let configuration = configurations.first {
                    $0.kind == .unsloth
                        && Self.endpointKey($0.baseURL) == Self.endpointKey(url)
                }
                group.addTask {
                    if let configuration { return try? await client.detect(configuration) }
                    return try? await client.detect(at: url)
                }
            }
            var found: [DetectedBackend] = []
            for await result in group {
                if let result { found.append(result) }
            }
            return found.sorted { $0.id < $1.id }
        }
        let found = await local + probed
        return Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.id < $1.id }
    }

    /// Saved endpoints and known loopback defaults. Never scan a network.
    func detectionURLs() -> [URL] {
        detectionURLs(using: SettingsSnapshot(settings))
    }

    private func detectionURLs(using snapshot: SettingsSnapshot) -> [URL] {
        let configured = BackendKind.allCases.compactMap {
            try? snapshot.configuration(for: $0).baseURL
        }
        let defaults = BackendKind.allCases.compactMap { URL(string: $0.defaultEndpoint) }
        var seen = Set<String>()
        return (configured + defaults).filter { seen.insert(Self.endpointKey($0)).inserted }
    }

    private func configuration(_ template: BackendConfiguration, at url: URL)
        -> BackendConfiguration
    {
        BackendConfiguration(
            kind: template.kind, baseURL: url, model: template.model, proxyPort: template.proxyPort,
            studioMonitorToken: template.studioMonitorToken, workerAPIKey: template.workerAPIKey)
    }

    private var hasStableCollector: Bool {
        monitorTask.map { !$0.isCancelled } == true && epoch == store.monitoringEpoch
    }

    private func canKeepCollector(using snapshot: SettingsSnapshot) -> Bool {
        guard hasStableCollector, let active = selectedConfiguration else { return false }
        if let kind = snapshot.selection.kind,
            let requested = try? snapshot.configuration(for: kind)
        {
            return Self.equivalent(requested, active)
        }
        guard let appliedSettings, appliedSettings.selection == .automatic,
            snapshot.lastAutomaticBackendID
                == DetectedBackend(
                    kind: active.kind, baseURL: active.baseURL
                ).id
        else { return false }
        // Unchanged automatic preferences do not require successful rediscovery.
        // In particular, a transient failure must keep the current retry loop and history.
        return BackendKind.allCases.allSatisfy { kind in
            switch (snapshot.configurations[kind]!, appliedSettings.configurations[kind]!) {
            case (.success(let requested), .success(let applied)):
                return Self.equivalent(requested, applied)
            case (.failure(let requested), .failure(let applied)):
                return requested.localizedDescription == applied.localizedDescription
            default:
                return false
            }
        }
    }

    private func canKeepAutomaticTarget(using snapshot: SettingsSnapshot) -> Bool {
        guard hasStableCollector, snapshot.selection == .automatic,
            let active = selectedConfiguration,
            let appliedSettings, appliedSettings.selection == .automatic,
            snapshot.lastAutomaticBackendID
                == DetectedBackend(
                    kind: active.kind, baseURL: active.baseURL
                ).id,
            let requested = try? snapshot.configuration(for: active.kind),
            let applied = try? appliedSettings.configuration(for: active.kind)
        else { return false }
        return Self.equivalent(requested, applied)
            && Self.equivalent(configuration(requested, at: active.baseURL), active)
    }

    private static func equivalent(_ lhs: BackendConfiguration, _ rhs: BackendConfiguration) -> Bool
    {
        guard lhs.kind == rhs.kind, endpointKey(lhs.baseURL) == endpointKey(rhs.baseURL) else {
            return false
        }
        switch lhs.kind {
        case .ollama: return lhs.proxyPort == rhs.proxyPort
        case .llamaCpp: return lhs.model == rhs.model
        case .unsloth:
            return lhs.studioMonitorToken == rhs.studioMonitorToken
                && lhs.workerAPIKey == rhs.workerAPIKey
        case .vllm, .rapidMLX: return true
        }
    }

    private static func endpointKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if ["localhost", "localhost."].contains(components.host ?? "") {
            components.host = "127.0.0.1"
        }
        if (components.scheme == "http" && components.port == 80)
            || (components.scheme == "https" && components.port == 443)
        {
            components.port = nil
        }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string ?? url.absoluteString
    }
}
