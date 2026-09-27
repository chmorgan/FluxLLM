import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LaunchAtLoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSystemSettings()
}

/// Keeps the login preference in sync with macOS rather than storing a separate preference.
@MainActor
public final class LaunchAtLoginController: ObservableObject {
    @Published public private(set) var status: SMAppService.Status
    @Published public private(set) var isUpdating = false
    @Published public private(set) var errorMessage: String?

    private let service: any LaunchAtLoginService

    public var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    public convenience init() {
        self.init(service: MainAppLoginService())
    }

    init(service: any LaunchAtLoginService) {
        self.service = service
        status = service.status
    }

    public func refresh() {
        let currentStatus = service.status
        guard currentStatus != status else { return }
        status = currentStatus
        errorMessage = nil
    }

    public func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        refresh()
        errorMessage = nil
        guard enabled != isRequested else { return }

        if enabled {
            switch status {
            case .notRegistered, .notFound:
                // macOS may not know this service until the first registration attempt.
                break
            case .enabled, .requiresApproval:
                return
            @unknown default:
                errorMessage = "macOS could not determine whether launch at login is available."
                return
            }
        }

        isUpdating = true
        defer { isUpdating = false }

        do {
            if enabled {
                try service.register()
            } else {
                try await service.unregister()
            }
            refresh()
        } catch {
            // ServiceManagement can change status even when an operation reports an error.
            refresh()
            let action = enabled ? "enable" : "disable"
            errorMessage = "Could not \(action) launch at login. \(error.localizedDescription)"
        }
    }

    public func openSystemSettings() {
        service.openSystemSettings()
    }
}

@MainActor
private final class MainAppLoginService: LaunchAtLoginService {
    private let service = SMAppService.mainApp

    var status: SMAppService.Status { service.status }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        // Keep SMAppService on the main actor; its completion runs on a background queue.
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let completion: @Sendable (Error?) -> Void = { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
            service.unregister(completionHandler: completion)
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
