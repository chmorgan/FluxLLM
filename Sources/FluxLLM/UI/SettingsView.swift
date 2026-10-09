import ServiceManagement
import SwiftUI

/// Connection drafts take effect together when applied for this session.
public struct SettingsView: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var launchAtLogin: LaunchAtLoginController
    private let store: MetricsStore?
    private let onApply: () async throws -> Void
    private let onRescan: () async -> Void
    @State private var selection: BackendSelection
    @State private var endpoints: [BackendKind: String]
    @State private var llamaCppModel: String
    @State private var proxyPort: String
    @State private var ollamaHost: String
    @State private var ollamaPort: String
    @State private var unslothMonitorToken: String
    @State private var unslothWorkerAPIKey: String
    @State private var isWorkerKeyOverrideExpanded: Bool
    @State private var isApplying = false
    @State private var isScanning = false
    @State private var applyError: String?
    @State private var didApply = false

    public init(
        settings: AppSettings, store: MetricsStore? = nil,
        launchAtLogin: LaunchAtLoginController? = nil,
        onApply: @escaping () async throws -> Void = {},
        onRescan: @escaping () async -> Void = {}
    ) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin ?? LaunchAtLoginController()
        self.store = store
        self.onApply = onApply
        self.onRescan = onRescan
        _selection = State(initialValue: settings.backendSelection)
        _endpoints = State(initialValue: settings.backendEndpoints)
        _llamaCppModel = State(initialValue: settings.llamaCppModel)
        _proxyPort = State(initialValue: String(settings.proxyPort))
        _ollamaHost = State(initialValue: settings.ollamaHost)
        _ollamaPort = State(initialValue: String(settings.ollamaPort))
        _unslothMonitorToken = State(initialValue: settings.unslothMonitorToken ?? "")
        _unslothWorkerAPIKey = State(initialValue: settings.unslothWorkerAPIKey ?? "")
        _isWorkerKeyOverrideExpanded = State(
            initialValue: settings.unslothWorkerAPIKey?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionDiscoverySection
                    Divider()
                    connectionSections
                    Divider()
                    generalSection
                    Divider()
                    menuBarSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error = draftError ?? applyError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if didApply {
                    Text("Settings applied for this session. Monitoring updates automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if isApplying { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Apply", action: apply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isApplying || draftError != nil)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: draftFingerprint) {
            applyError = nil
            didApply = false
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General").font(.headline)
            HStack {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { launchAtLogin.isRequested },
                        set: { enabled in
                            Task { @MainActor in
                                await launchAtLogin.setEnabled(enabled)
                            }
                        })
                )
                .disabled(launchAtLogin.isUpdating)
                if launchAtLogin.isUpdating { ProgressView().controlSize(.small) }
            }
            Text("Changes to launch at login take effect immediately.")
                .font(.caption).foregroundStyle(.secondary)
            Text(
                "Other settings apply only until FluxLLM quits. Existing saved preferences are read at launch."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if launchAtLogin.status == .requiresApproval {
                Text("FluxLLM won’t launch at login until you allow it in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items Settings") {
                    launchAtLogin.openSystemSettings()
                }
            }
            if let error = launchAtLogin.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let logger = store?.diagnosticLogger {
                Divider()
                Toggle(
                    "Diagnostic logging",
                    isOn: Binding(
                        get: { logger.isEnabled },
                        set: { enabled in
                            Task { @MainActor in
                                try? await logger.setEnabled(enabled)
                            }
                        })
                )
                .disabled(logger.isUpdating)
                Text(
                    "Off at every launch. Logs contain timing and counts, never prompts or responses. Files are limited to 3 MiB in ~/Library/Logs/FluxLLM."
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if logger.isUpdating { ProgressView().controlSize(.small) }
                if let error = logger.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if logger.droppedCount > 0 {
                    Text("\(logger.droppedCount) diagnostic records dropped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var connectionSections: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("LLM system").font(.headline)
                Picker("System", selection: $selection) {
                    ForEach(BackendSelection.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                if selection == .automatic {
                    Text(
                        "FluxLLM selects a detected system and remembers it while it remains available. Choose a system when several are detected."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let warning = BackendPresentation.selectionWarning(
                    selection: selection, detected: store?.detectedBackends ?? [])
                {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let notice = store?.selectionNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            if selection == .ollama {
                ollamaConfiguration
            } else if let kind = selection.kind {
                nativeConfiguration(kind)
            } else {
                if store?.backendKind == .ollama { ollamaConfiguration }
                DisclosureGroup("Discovery addresses") {
                    VStack(alignment: .leading, spacing: 16) {
                        if store?.backendKind != .ollama { ollamaConfiguration }
                        ForEach(BackendKind.allCases.filter { $0 != .ollama }) { kind in
                            nativeConfiguration(kind)
                        }
                    }.padding(.top, 12)
                }
            }

            if let store {
                DisclosureGroup("Connection details") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            store.connectionMessage
                                ?? "Connection state: \(store.connectionState.rawValue)")
                        if store.backendKind == .ollama {
                            Text("Proxy: \(store.proxyState.rawValue)")
                            Text("Client endpoint: \(store.proxyEndpoint)")
                            Text("Ollama upstream: \(store.upstreamEndpoint)")
                            if let error = store.proxyError {
                                Text(error).foregroundStyle(.red)
                            }
                            if let error = store.generationError {
                                Text(error).foregroundStyle(.red)
                            }
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("System GPU").font(.headline)
                if let store, let sample = store.backendGPUActivity,
                    store.systemGPUUtilizationPercent != nil
                {
                    Text("Source: \(sample.source)")
                } else {
                    Text(
                        store?.gpuAvailabilityMessage
                            ?? "System GPU telemetry is unavailable on this Mac.")
                }
                Text(GPUActivityPresentation.explanation)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(isApplying)
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Menu bar").font(.headline)
            Toggle("Show tokens per second", isOn: $settings.showMenuBarTokensPerSecond)
            Toggle("Show FluxLLM logo", isOn: $settings.showMenuBarLogo)
        }
        .disabled(isApplying)
    }

    private var firstDetectedUnsloth: DetectedBackend? {
        store?.detectedBackends.first { $0.kind == .unsloth }
    }

    private var unslothDetected: Bool { firstDetectedUnsloth != nil }
    private var showsUnslothCredentialsAtTop: Bool { unslothDetected || selection == .unsloth }

    private var connectionDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            detectionSection
            if selection == .unsloth && !unslothDetected {
                unslothCredentialsSection
            }
        }
        .disabled(isApplying)
    }

    private var detectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Detected systems").font(.headline)
                Spacer()
                if isScanning { ProgressView().controlSize(.small) }
                Button("Scan Again") {
                    isScanning = true
                    Task { @MainActor in
                        await onRescan()
                        isScanning = false
                    }
                }
                .disabled(isScanning || isApplying || store == nil)
            }
            if let detected = store?.detectedBackends, !detected.isEmpty {
                ForEach(detected) { backend in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(
                                systemName: backend.isReady
                                    ? "checkmark.circle" : "exclamationmark.circle"
                            )
                            .foregroundStyle(backend.isReady ? Color.green : Color.orange)
                            Text(backend.kind.title).fontWeight(.medium)
                            Text(backend.baseURL.absoluteString)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        if !backend.isReady, let detail = backend.detail, !detail.isEmpty {
                            Text(detail).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption).textSelection(.enabled)
                    if backend.kind == .unsloth, backend.id == firstDetectedUnsloth?.id {
                        unslothCredentialsSection.padding(.top, 6)
                    }
                }
            } else {
                Text(
                    store?.connectionState == .detecting
                        ? "Scanning saved and local addresses…"
                        : "No systems detected at the saved addresses."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var unslothCredentialsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unsloth credentials").font(.headline)
            Text("Automatic worker authentication").fontWeight(.medium)
            Text(
                "FluxLLM uses the current key from the verified local Unsloth worker unless you enter an override."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Manual worker key override", isExpanded: $isWorkerKeyOverrideExpanded)
            {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Worker API key override", text: $unslothWorkerAPIKey)
                    Text(
                        "Leave blank for automatic authentication. Studio keys starting with sk-unsloth belong in the Studio field below."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            }
            SecureField("Studio API key or monitor token (optional)", text: $unslothMonitorToken)
            Text(
                "Optional: a Studio API key created in Studio, or a Studio monitor token, adds recorded request history."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Manual credentials are kept only until FluxLLM quits. Click Apply to use them.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ollamaConfiguration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ollama connection").font(.headline)
            Form {
                TextField("Ollama host", text: $ollamaHost)
                TextField("Ollama port", text: $ollamaPort)
                TextField("Local proxy port", text: $proxyPort)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Configure your Ollama client to use this endpoint:")
                HStack {
                    Text(clientEndpoint).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(clientEndpoint, forType: .string)
                    }
                    .disabled(Int(proxyPort).map { !(1...65535).contains($0) } ?? true)
                }
                Text(
                    "FluxLLM starts and reconnects automatically. Changing systems or connection settings ends any active requests routed through FluxLLM."
                )
                .foregroundStyle(.secondary)
                Text(
                    "Tokens per second and Active/Idle describe requests sent through this endpoint. System GPU measures all GPU activity on this Mac, including other applications."
                )
                .foregroundStyle(.secondary)
                Link(
                    "Why a proxy? Follow Ollama’s metrics proposal ↗",
                    destination: URL(string: "https://github.com/ollama/ollama/pull/16998")!
                )
                .font(.caption2)
            }
            .font(.caption)
        }
    }

    private func nativeConfiguration(_ kind: BackendKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(kind.title) connection").font(.headline)
            TextField(
                kind == .unsloth ? "Unsloth Studio URL" : "Server URL", text: endpointBinding(kind))
            if kind == .llamaCpp {
                TextField("Model name (optional)", text: $llamaCppModel)
                Text(
                    "Start llama.cpp with --metrics. For router mode, enter the model name you want to monitor."
                )
                .font(.caption).foregroundStyle(.secondary)
            } else if kind == .unsloth {
                Text(
                    "Enter the local Studio address, normally http://127.0.0.1:8888. FluxLLM follows its GGUF inference worker automatically. Keep using Unsloth normally; no client proxy is needed."
                )
                .font(.caption).foregroundStyle(.secondary)
                if !showsUnslothCredentialsAtTop { unslothCredentialsSection }
                Text(
                    "Studio’s monitor endpoint does not expose structured tool activity. System GPU measures this Mac."
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(
                    "FluxLLM reads server metrics directly. Existing clients keep using this server."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func endpointBinding(_ kind: BackendKind) -> Binding<String> {
        Binding(get: { endpoints[kind] ?? kind.defaultEndpoint }, set: { endpoints[kind] = $0 })
    }

    private var clientEndpoint: String { "http://127.0.0.1:\(proxyPort)" }
    private var draftFingerprint: [String] {
        [
            selection.rawValue, proxyPort, ollamaHost, ollamaPort, llamaCppModel,
            unslothMonitorToken, unslothWorkerAPIKey,
        ]
            + BackendKind.allCases.map { endpoints[$0] ?? "" }
    }
    private var draftError: String? {
        Self.validationError(
            selection: selection, proxyPort: proxyPort, ollamaHost: ollamaHost,
            ollamaPort: ollamaPort, endpoints: endpoints, unslothWorkerAPIKey: unslothWorkerAPIKey,
            unslothDetected: unslothDetected)
    }

    static func validationError(
        selection: BackendSelection, proxyPort: String, ollamaHost: String,
        ollamaPort: String, endpoints: [BackendKind: String], unslothWorkerAPIKey: String = "",
        unslothDetected: Bool = false
    ) -> String? {
        if selection == .automatic || selection == .ollama {
            guard let localPort = Int(proxyPort), let upstreamPort = Int(ollamaPort) else {
                return "Ports must be whole numbers between 1 and 65535."
            }
            if let error = AppSettings.validationError(
                proxyPort: localPort, ollamaHost: ollamaHost, ollamaPort: upstreamPort)
            {
                return error
            }
        }
        if selection == .automatic || selection == .unsloth || unslothDetected {
            do {
                _ = try AppSettings.normalizedUnslothWorkerAPIKey(unslothWorkerAPIKey)
            } catch {
                return "Unsloth: \(error.localizedDescription)"
            }
        }
        let kinds =
            selection == .automatic
            ? BackendKind.allCases.filter { $0 != .ollama }
            : selection.kind.map { $0 == .ollama ? [] : [$0] } ?? []
        for kind in kinds {
            do {
                let url = try AppSettings.endpointURL(endpoints[kind] ?? kind.defaultEndpoint)
                if kind == .unsloth {
                    try AppSettings.validateUnslothEndpoint(url)
                }
            } catch {
                return "\(kind.title): \(error.localizedDescription)"
            }
        }
        return nil
    }

    private func apply() {
        guard draftError == nil else { return }
        if selection == .automatic || selection == .unsloth || unslothDetected {
            do {
                try settings.applyUnslothCredentials(
                    workerAPIKey: unslothWorkerAPIKey, monitorToken: unslothMonitorToken)
            } catch {
                applyError = error.localizedDescription
                return
            }
        }
        if selection == .automatic || selection == .ollama,
            let localPort = Int(proxyPort), let upstreamPort = Int(ollamaPort)
        {
            settings.proxyPort = localPort
            settings.ollamaHost = AppSettings.normalizedHost(ollamaHost)
            settings.ollamaPort = upstreamPort
        }
        if selection == .automatic {
            settings.backendEndpoints = endpoints
        } else if let kind = selection.kind, kind != .ollama {
            settings.backendEndpoints[kind] = endpoints[kind] ?? kind.defaultEndpoint
        }
        if selection == .automatic || selection == .llamaCpp {
            settings.llamaCppModel = llamaCppModel
        }
        settings.backendSelection = selection
        isApplying = true
        applyError = nil
        didApply = false
        Task { @MainActor in
            defer { isApplying = false }
            do {
                try await onApply()
                didApply = true
            } catch is CancellationError {
                // App shutdown owns cancellation and closes this window.
            } catch {
                applyError = error.localizedDescription
            }
        }
    }
}

#Preview {
    SettingsView(settings: AppSettings())
}
