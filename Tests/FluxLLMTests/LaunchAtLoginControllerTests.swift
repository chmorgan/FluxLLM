import Foundation
import ServiceManagement
import XCTest

@testable import FluxLLM

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testInitializationAndRefreshOnlyReadSystemStatus() {
        for status in [
            SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound,
        ] {
            let service = LoginServiceFixture(status: status)
            let controller = LaunchAtLoginController(service: service)

            controller.refresh()

            XCTAssertEqual(controller.status, status)
            XCTAssertEqual(
                controller.isRequested, status == .enabled || status == .requiresApproval)
            XCTAssertFalse(controller.isUpdating)
            XCTAssertNil(controller.errorMessage)
            XCTAssertEqual(service.registerCalls, 0)
            XCTAssertEqual(service.unregisterCalls, 0)
        }
    }

    func testEnablingAndDisablingReadsTheResultingSystemStatus() async {
        let service = LoginServiceFixture(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isRequested)
        XCTAssertFalse(controller.isUpdating)

        await controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isRequested)
        XCTAssertFalse(controller.isUpdating)
        XCTAssertNil(controller.errorMessage)
    }

    func testPendingApprovalRemainsRequestedAndCanBeDisabled() async {
        let service = LoginServiceFixture(status: .notRegistered)
        service.registrationStatus = .requiresApproval
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)
        await controller.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isRequested)

        await controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isRequested)
    }

    func testRequestsMatchingTheSystemStatusDoNotMutateRegistration() async {
        for status in [SMAppService.Status.notRegistered, .enabled, .requiresApproval] {
            let service = LoginServiceFixture(status: status)
            let controller = LaunchAtLoginController(service: service)

            await controller.setEnabled(status != .notRegistered)

            XCTAssertEqual(service.registerCalls, 0)
            XCTAssertEqual(service.unregisterCalls, 0)
        }
    }

    func testRefreshReflectsExternalChangesWithoutMutatingRegistration() {
        let service = LoginServiceFixture(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        service.status = .requiresApproval
        controller.refresh()
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isRequested)

        service.status = .notRegistered
        controller.refresh()
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isRequested)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testActionsRefreshStatusBeforeDecidingWhetherToRegister() async {
        let service = LoginServiceFixture(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        service.status = .enabled
        await controller.setEnabled(true)

        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(service.registerCalls, 0)

        service.status = .notRegistered
        await controller.setEnabled(false)

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertEqual(service.unregisterCalls, 0)

        service.status = .requiresApproval
        await controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(controller.status, .notRegistered)
    }

    func testRegistrationFailurePreservesSystemStatusAndReportsError() async {
        let service = LoginServiceFixture(status: .notRegistered)
        service.registrationError = .registration
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isRequested)
        XCTAssertFalse(controller.isUpdating)
        XCTAssertEqual(
            controller.errorMessage,
            "Could not enable launch at login. Registration failed.")
    }

    func testRegistrationErrorStillReflectsChangedSystemStatus() async {
        let service = LoginServiceFixture(status: .notRegistered)
        service.registrationError = .registration
        service.registrationErrorStatus = .requiresApproval
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isRequested)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isUpdating)
    }

    func testUnregistrationFailurePreservesSystemStatusAndReportsError() async {
        let service = LoginServiceFixture(status: .enabled)
        service.unregistrationError = .unregistration
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(false)

        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isRequested)
        XCTAssertFalse(controller.isUpdating)
        XCTAssertEqual(
            controller.errorMessage,
            "Could not disable launch at login. Unregistration failed.")
    }

    func testUnregistrationErrorStillReflectsChangedSystemStatus() async {
        let service = LoginServiceFixture(status: .enabled)
        service.unregistrationError = .unregistration
        service.unregistrationErrorStatus = .notRegistered
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(false)

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isRequested)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isUpdating)
    }

    func testErrorSurvivesUnchangedRefreshAndClearsOnExternalStatusChange() async {
        let service = LoginServiceFixture(status: .notRegistered)
        service.registrationError = .registration
        let controller = LaunchAtLoginController(service: service)
        await controller.setEnabled(true)
        let error = controller.errorMessage

        controller.refresh()
        XCTAssertEqual(controller.errorMessage, error)

        service.status = .enabled
        controller.refresh()
        XCTAssertNil(controller.errorMessage)
    }

    func testRetryClearsAnEarlierError() async {
        let service = LoginServiceFixture(status: .notRegistered)
        service.registrationError = .registration
        let controller = LaunchAtLoginController(service: service)
        await controller.setEnabled(true)

        service.registrationError = nil
        await controller.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 2)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testNotFoundServiceCanRegisterAndReflectTheResultingSystemStatus() async {
        for resultingStatus in [SMAppService.Status.enabled, .requiresApproval] {
            let service = LoginServiceFixture(status: .notFound)
            service.registrationStatus = resultingStatus
            let controller = LaunchAtLoginController(service: service)

            await controller.setEnabled(false)

            XCTAssertEqual(service.registerCalls, 0)
            XCTAssertEqual(service.unregisterCalls, 0)
            XCTAssertEqual(controller.status, .notFound)
            XCTAssertFalse(controller.isRequested)
            XCTAssertNil(controller.errorMessage)

            await controller.setEnabled(true)

            XCTAssertEqual(service.registerCalls, 1)
            XCTAssertEqual(controller.status, resultingStatus)
            XCTAssertTrue(controller.isRequested)
            XCTAssertFalse(controller.isUpdating)
            XCTAssertNil(controller.errorMessage)
        }
    }

    func testNotFoundRegistrationFailureCanBeRetriedWithoutAnExternalStatusChange() async {
        let service = LoginServiceFixture(status: .notFound)
        service.registrationError = .registration
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(controller.status, .notFound)
        XCTAssertFalse(controller.isRequested)
        XCTAssertFalse(controller.isUpdating)
        XCTAssertEqual(
            controller.errorMessage,
            "Could not enable launch at login. Registration failed.")

        service.registrationError = nil
        await controller.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 2)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isRequested)
        XCTAssertFalse(controller.isUpdating)
        XCTAssertNil(controller.errorMessage)
    }

    func testConcurrentRequestsDoNotRaceAnUnregistrationInProgress() async throws {
        let service = LoginServiceFixture(status: .enabled)
        service.holdUnregistration = true
        let controller = LaunchAtLoginController(service: service)
        let disabling = Task { await controller.setEnabled(false) }
        defer { service.releaseUnregistration() }
        try await eventually { service.unregistrationContinuation != nil }

        XCTAssertTrue(controller.isUpdating)
        await controller.setEnabled(false)
        await controller.setEnabled(true)
        controller.refresh()
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertTrue(controller.isUpdating)

        service.releaseUnregistration()
        await disabling.value

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isUpdating)
        XCTAssertNil(controller.errorMessage)

        await controller.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(controller.status, .enabled)
    }

    func testOpenSystemSettingsDoesNotMutateRegistration() {
        let service = LoginServiceFixture(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        controller.openSystemSettings()

        XCTAssertEqual(service.openSettingsCalls, 1)
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 0)
        XCTAssertEqual(controller.status, .requiresApproval)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Login service did not begin unregistering")
                throw CancellationError()
            }
            await Task.yield()
        }
    }
}

@MainActor
private final class LoginServiceFixture: LaunchAtLoginService {
    var status: SMAppService.Status
    var registrationStatus: SMAppService.Status = .enabled
    var registrationError: LoginServiceFixtureError?
    var registrationErrorStatus: SMAppService.Status?
    var unregistrationError: LoginServiceFixtureError?
    var unregistrationErrorStatus: SMAppService.Status?
    var registerCalls = 0
    var unregisterCalls = 0
    var openSettingsCalls = 0
    var holdUnregistration = false
    var unregistrationContinuation: CheckedContinuation<Void, Never>?

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let registrationError {
            if let registrationErrorStatus { status = registrationErrorStatus }
            throw registrationError
        }
        status = registrationStatus
    }

    func unregister() async throws {
        unregisterCalls += 1
        if holdUnregistration {
            await withCheckedContinuation { unregistrationContinuation = $0 }
        }
        if let unregistrationError {
            if let unregistrationErrorStatus { status = unregistrationErrorStatus }
            throw unregistrationError
        }
        status = .notRegistered
    }

    func openSystemSettings() {
        openSettingsCalls += 1
    }

    func releaseUnregistration() {
        unregistrationContinuation?.resume()
        unregistrationContinuation = nil
        holdUnregistration = false
    }
}

private enum LoginServiceFixtureError: LocalizedError {
    case registration
    case unregistration

    var errorDescription: String? {
        switch self {
        case .registration: "Registration failed."
        case .unregistration: "Unregistration failed."
        }
    }
}
