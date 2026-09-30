import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class AppSettingsTests: XCTestCase {
    func testMenuBarPreferencesDefaultToVisible() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            XCTAssertTrue(settings.showMenuBarTokensPerSecond)
            XCTAssertTrue(settings.showMenuBarLogo)
        }
    }

    func testMenuBarPreferencesChangeOnlyInTheCurrentSession() throws {
        for showTokens in [false, true] {
            for showLogo in [false, true] {
                try withDefaults { defaults in
                    let settings = AppSettings(defaults: defaults)
                    settings.showMenuBarTokensPerSecond = showTokens

                    settings.showMenuBarLogo = showLogo
                    XCTAssertEqual(settings.showMenuBarTokensPerSecond, showTokens)
                    XCTAssertEqual(settings.showMenuBarLogo, showLogo)
                    let reloaded = AppSettings(defaults: defaults)
                    XCTAssertTrue(reloaded.showMenuBarTokensPerSecond)
                    XCTAssertTrue(reloaded.showMenuBarLogo)
                    XCTAssertNil(defaults.data(forKey: "appSettings"))
                }
            }
        }
    }

    func testConnectionPreferencesDoNotWriteDefaults() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.proxyPort, 11435)
            XCTAssertEqual(settings.ollamaPort, 11434)
            XCTAssertTrue(settings.autoStartProxy)
            settings.proxyPort = 12035
            settings.ollamaHost = "127.0.0.1"
            settings.ollamaPort = 11499
            settings.autoStartProxy = false
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.proxyPort, 12035)
            XCTAssertEqual(settings.ollamaHost, "127.0.0.1")
            XCTAssertEqual(settings.ollamaPort, 11499)
            XCTAssertFalse(settings.autoStartProxy)
            XCTAssertEqual(reloaded.proxyPort, 11435)
            XCTAssertEqual(reloaded.ollamaHost, "localhost")
            XCTAssertEqual(reloaded.ollamaPort, 11434)
            XCTAssertTrue(reloaded.autoStartProxy)
            XCTAssertNil(reloaded.configurationError)
            XCTAssertNil(defaults.data(forKey: "appSettings"))
        }
    }

    func testLegacySnapshotRetainsProxySettingsAndIgnoresRemovedFields() throws {
        try withDefaults { defaults in
            let legacy = """
                {"proxyPort":12035,"ollamaHost":"localhost","ollamaPort":11499,
                 "autoStartProxy":false,"theme":"dark","telemetryInterval":2.0,
                 "showGPU":true,"showCPU":false}
                """
            defaults.set(Data(legacy.utf8), forKey: "appSettings")
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.proxyPort, 12035)
            XCTAssertEqual(settings.ollamaHost, "localhost")
            XCTAssertEqual(settings.ollamaPort, 11499)
            XCTAssertFalse(settings.autoStartProxy)
            XCTAssertTrue(settings.showMenuBarTokensPerSecond)
            XCTAssertTrue(settings.showMenuBarLogo)
        }
    }

    func testCurrentSnapshotWithoutMenuBarPreferencesRetainsBackendSettings() throws {
        try withDefaults { defaults in
            let snapshot = """
                {"proxyPort":12035,"ollamaHost":"localhost","ollamaPort":11499,
                 "autoStartProxy":false,"backendSelection":"llamaCpp",
                 "backendEndpoints":{"llamaCpp":"https://inference.example/llama/"},
                 "llamaCppModel":"test-model","lastAutomaticBackendID":"last-backend"}
                """
            defaults.set(Data(snapshot.utf8), forKey: "appSettings")

            let settings = AppSettings(defaults: defaults)
            XCTAssertTrue(settings.showMenuBarTokensPerSecond)
            XCTAssertTrue(settings.showMenuBarLogo)
            XCTAssertEqual(settings.backendSelection, .llamaCpp)
            XCTAssertEqual(settings.lastAutomaticBackendID, "last-backend")
            let configuration = try settings.configuration(for: .llamaCpp)
            XCTAssertEqual(configuration.baseURL.absoluteString, "https://inference.example/llama")
            XCTAssertEqual(configuration.model, "test-model")
        }
    }

    func testMissingMenuBarPreferenceDefaultsIndependently() throws {
        for (storedKey, expectedTokens, expectedLogo) in [
            ("showMenuBarTokensPerSecond", false, true),
            ("showMenuBarLogo", true, false),
        ] {
            try withDefaults { defaults in
                let snapshot = """
                    {"proxyPort":12035,"ollamaHost":"localhost","ollamaPort":11499,
                     "autoStartProxy":false,"\(storedKey)":false}
                    """
                defaults.set(Data(snapshot.utf8), forKey: "appSettings")

                let settings = AppSettings(defaults: defaults)
                XCTAssertEqual(settings.showMenuBarTokensPerSecond, expectedTokens, storedKey)
                XCTAssertEqual(settings.showMenuBarLogo, expectedLogo, storedKey)
                XCTAssertEqual(settings.proxyPort, 12035)
            }
        }
    }

    func testMalformedSnapshotFallsBackToUsableDefaults() throws {
        try withDefaults { defaults in
            defaults.set(Data("not JSON".utf8), forKey: "appSettings")
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.proxyPort, 11435)
            XCTAssertEqual(settings.ollamaPort, 11434)
            XCTAssertNil(settings.configurationError)
            XCTAssertTrue(settings.showMenuBarTokensPerSecond)
            XCTAssertTrue(settings.showMenuBarLogo)
        }
    }

    func testChangingEveryPreferenceLeavesExistingSavedDataUntouched() throws {
        try withDefaults { defaults in
            let original = Data(
                """
                {"proxyPort":12035,"ollamaHost":"localhost","ollamaPort":11499,
                 "autoStartProxy":false,"showMenuBarLogo":false}
                """.utf8)
            defaults.set(original, forKey: "appSettings")
            let settings = AppSettings(defaults: defaults)
            settings.proxyPort = 13035
            settings.ollamaHost = "remote.example"
            settings.ollamaPort = 13034
            settings.autoStartProxy = true
            settings.showMenuBarTokensPerSecond = false
            settings.showMenuBarLogo = true
            settings.backendSelection = .llamaCpp
            settings.backendEndpoints[.llamaCpp] = "https://example.com/inference"
            settings.llamaCppModel = "session-model"
            settings.lastAutomaticBackendID = "session-backend"
            XCTAssertEqual(defaults.data(forKey: "appSettings"), original)
            let nextSession = AppSettings(defaults: defaults)
            XCTAssertEqual(nextSession.proxyPort, 12035)
            XCTAssertFalse(nextSession.showMenuBarLogo)
            XCTAssertEqual(nextSession.backendSelection, .automatic)
            XCTAssertNil(nextSession.lastAutomaticBackendID)
        }
    }

    func testInvalidPortsAreRejectedAndEphemeralPortRequiresOptIn() {
        for port in [-1, 0, 65_536] {
            XCTAssertNotNil(
                AppSettings.validationError(
                    proxyPort: port, ollamaHost: "localhost", ollamaPort: 11434))
            XCTAssertNotNil(
                AppSettings.validationError(
                    proxyPort: 11435, ollamaHost: "localhost", ollamaPort: port))
        }
        XCTAssertNil(
            AppSettings.validationError(
                proxyPort: 0, ollamaHost: "localhost", ollamaPort: 11434,
                allowsEphemeralPort: true))
        XCTAssertNotNil(
            AppSettings.validationError(
                proxyPort: 0, ollamaHost: "localhost", ollamaPort: 0,
                allowsEphemeralPort: true))
    }

    func testHostRejectsURLAuthorityAndPathSyntax() {
        for host in [
            "", "  ", "http://localhost", "localhost:11434", "localhost/api",
            "user@localhost", "localhost?x=1", "localhost#x", "host name",
        ] {
            XCTAssertNotNil(
                AppSettings.validationError(
                    proxyPort: 11435, ollamaHost: host, ollamaPort: 11434), host)
        }
    }

    func testIPv6AndWhitespaceNormalization() {
        for host in ["localhost", "127.0.0.1", "::1", "[::1]", "  localhost\n"] {
            XCTAssertNil(
                AppSettings.validationError(
                    proxyPort: 11435, ollamaHost: host, ollamaPort: 11434), host)
        }
        XCTAssertEqual(AppSettings.normalizedHost(" \n[::1]  "), "::1")
        XCTAssertEqual(AppSettings.normalizedHost(" localhost\n"), "localhost")
    }

    func testLocalEqualPortsAreRejectedWithoutRejectingRemoteEqualPorts() {
        for host in ["localhost", "LOCALHOST", "localhost.", "127.0.0.1", "::1", "[::1]"] {
            XCTAssertNotNil(
                AppSettings.validationError(
                    proxyPort: 11435, ollamaHost: host, ollamaPort: 11435), host)
        }
        XCTAssertNil(
            AppSettings.validationError(
                proxyPort: 11435, ollamaHost: "ollama.example", ollamaPort: 11435))
    }

    func testBackendSelectionAndEndpointsRemainSessionOnly() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.backendSelection = .llamaCpp
            settings.backendEndpoints[.llamaCpp] = "https://inference.example/llama/"
            settings.llamaCppModel = "test-model"
            settings.lastAutomaticBackendID = "vllm|http://127.0.0.1:8000"
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertEqual(reloaded.backendSelection, .automatic)
            XCTAssertNil(reloaded.lastAutomaticBackendID)
            let configuration = try settings.configuration(for: .llamaCpp)
            XCTAssertEqual(configuration.baseURL.absoluteString, "https://inference.example/llama")
            XCTAssertEqual(configuration.model, "test-model")
            XCTAssertNil(defaults.data(forKey: "appSettings"))
        }
    }

    func testLegacyPreferencesAreReadWithoutMigrationWrites() throws {
        try withDefaults { current in
            try withDefaults { legacy in
                legacy.set(
                    Data(
                        """
                        {"proxyPort":12035,"ollamaHost":"custom.example","ollamaPort":12034,"autoStartProxy":false}
                        """.utf8), forKey: "appSettings")
                let migrated = AppSettings(defaults: current, legacyDefaults: legacy)
                XCTAssertEqual(migrated.ollamaHost, "custom.example")
                XCTAssertEqual(migrated.proxyPort, 12035)
                XCTAssertEqual(migrated.backendSelection, .automatic)
                XCTAssertTrue(migrated.showMenuBarTokensPerSecond)
                XCTAssertTrue(migrated.showMenuBarLogo)
                XCTAssertNil(current.data(forKey: "appSettings"))
                migrated.backendSelection = .vllm
                migrated.showMenuBarTokensPerSecond = false
                migrated.showMenuBarLogo = false
                let retained = AppSettings(defaults: current, legacyDefaults: legacy)
                XCTAssertEqual(retained.backendSelection, .automatic)
                XCTAssertTrue(retained.showMenuBarTokensPerSecond)
                XCTAssertTrue(retained.showMenuBarLogo)
                XCTAssertNil(current.data(forKey: "appSettings"))
                XCTAssertNotNil(legacy.data(forKey: "appSettings"))
            }
        }
    }

    func testLegacyReadsPreservePreferencesWithoutCopyingThem() throws {
        try withDefaults { current in
            try withDefaults { legacy in
                let snapshot = """
                    {"proxyPort":12035,"ollamaHost":"custom.example","ollamaPort":12034,
                     "autoStartProxy":false,"showMenuBarTokensPerSecond":false,"showMenuBarLogo":false}
                    """
                legacy.set(Data(snapshot.utf8), forKey: "appSettings")

                let migrated = AppSettings(defaults: current, legacyDefaults: legacy)
                XCTAssertFalse(migrated.showMenuBarTokensPerSecond)
                XCTAssertFalse(migrated.showMenuBarLogo)

                let reloaded = AppSettings(defaults: current, legacyDefaults: legacy)
                XCTAssertFalse(reloaded.showMenuBarTokensPerSecond)
                XCTAssertFalse(reloaded.showMenuBarLogo)
                XCTAssertNil(current.data(forKey: "appSettings"))
                XCTAssertEqual(legacy.data(forKey: "appSettings"), Data(snapshot.utf8))
            }
        }
    }

    func testInvalidLegacyPreferencesAreNotMigrated() throws {
        try withDefaults { current in
            try withDefaults { legacy in
                legacy.set(
                    Data(
                        """
                        {"proxyPort":-1,"ollamaHost":"localhost","ollamaPort":11434,"autoStartProxy":true}
                        """.utf8), forKey: "appSettings")
                let settings = AppSettings(defaults: current, legacyDefaults: legacy)
                XCTAssertEqual(settings.proxyPort, 11435)
                XCTAssertNil(current.data(forKey: "appSettings"))
            }
        }
    }

    func testExistingNewPreferencesAreNeverReplacedByLegacyDomain() throws {
        try withDefaults { current in
            try withDefaults { legacy in
                current.set(Data("invalid current preferences".utf8), forKey: "appSettings")
                legacy.set(
                    Data(
                        """
                        {"proxyPort":12035,"ollamaHost":"custom.example","ollamaPort":12034,"autoStartProxy":true}
                        """.utf8), forKey: "appSettings")
                let settings = AppSettings(defaults: current, legacyDefaults: legacy)
                XCTAssertEqual(settings.proxyPort, 11435)
                XCTAssertEqual(settings.ollamaHost, "localhost")
                XCTAssertEqual(
                    current.data(forKey: "appSettings"), Data("invalid current preferences".utf8))
            }
        }
    }

    func testNativeConfigurationDoesNotDependOnUnusedProxyPorts() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.proxyPort = 0
            XCTAssertNoThrow(try settings.configuration(for: .vllm))
            XCTAssertThrowsError(try settings.configuration(for: .ollama))
        }
    }

    func testMenuBarPreferencesApplyWithoutSavingInvalidBackendDraft() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.proxyPort = 0
            settings.backendSelection = .vllm
            settings.backendEndpoints[.vllm] = "file:///tmp/server"
            XCTAssertThrowsError(try settings.configuration(for: .ollama))
            XCTAssertThrowsError(try settings.configuration(for: .vllm))

            settings.showMenuBarTokensPerSecond = false
            settings.showMenuBarLogo = false
            XCTAssertFalse(settings.showMenuBarTokensPerSecond)
            XCTAssertFalse(settings.showMenuBarLogo)
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertTrue(reloaded.showMenuBarTokensPerSecond)
            XCTAssertTrue(reloaded.showMenuBarLogo)
            XCTAssertEqual(reloaded.proxyPort, 11435)
            XCTAssertEqual(reloaded.backendSelection, .automatic)
            XCTAssertNoThrow(try reloaded.configuration(for: .ollama))
            XCTAssertNoThrow(try reloaded.configuration(for: .vllm))
            XCTAssertNil(defaults.data(forKey: "appSettings"))
        }
    }

    func testBackendURLsRejectCredentialsQueriesAndUnsupportedSchemes() {
        for text in [
            "localhost:8000", "file:///tmp/server", "https://user:password@example.com",
            "http://example.com?key=secret", "https://example.com#fragment",
            "http://example.com:70000",
        ] {
            XCTAssertThrowsError(try AppSettings.endpointURL(text), text)
        }
        XCTAssertEqual(
            try AppSettings.endpointURL(" https://example.com/service/ ").absoluteString,
            "https://example.com/service")
        XCTAssertNoThrow(try AppSettings.endpointURL("http://[::1]:8000"))
    }

    private func withDefaults(_ operation: (UserDefaults) throws -> Void) throws {
        let suite = "com.cmorgan.FluxLLM.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try operation(defaults)
    }
}
