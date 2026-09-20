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

    func testMenuBarPreferencesPersistEveryVisibilityCombinationImmediately() throws {
        for showTokens in [false, true] {
            for showLogo in [false, true] {
                try withDefaults { defaults in
                    let settings = AppSettings(defaults: defaults)
                    settings.showMenuBarTokensPerSecond = showTokens

                    let afterTokens = AppSettings(defaults: defaults)
                    XCTAssertEqual(afterTokens.showMenuBarTokensPerSecond, showTokens)
                    XCTAssertTrue(afterTokens.showMenuBarLogo)

                    settings.showMenuBarLogo = showLogo
                    let reloaded = AppSettings(defaults: defaults)
                    XCTAssertEqual(reloaded.showMenuBarTokensPerSecond, showTokens)
                    XCTAssertEqual(reloaded.showMenuBarLogo, showLogo)

                    let data = try XCTUnwrap(defaults.data(forKey: "appSettings"))
                    let snapshot = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: data) as? [String: Any])
                    XCTAssertEqual(snapshot["showMenuBarTokensPerSecond"] as? Bool, showTokens)
                    XCTAssertEqual(snapshot["showMenuBarLogo"] as? Bool, showLogo)
                }
            }
        }
    }

    func testPreferencesRoundTripInIsolatedDefaultsSuite() throws {
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
            XCTAssertEqual(reloaded.proxyPort, 12035)
            XCTAssertEqual(reloaded.ollamaHost, "127.0.0.1")
            XCTAssertEqual(reloaded.ollamaPort, 11499)
            XCTAssertFalse(reloaded.autoStartProxy)
            XCTAssertNil(reloaded.configurationError)
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

    func testBackendSelectionAndEndpointsRoundTrip() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.backendSelection = .llamaCpp
            settings.backendEndpoints[.llamaCpp] = "https://inference.example/llama/"
            settings.llamaCppModel = "test-model"
            settings.lastAutomaticBackendID = "vllm|http://127.0.0.1:8000"
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertEqual(reloaded.backendSelection, .llamaCpp)
            XCTAssertEqual(reloaded.lastAutomaticBackendID, settings.lastAutomaticBackendID)
            let configuration = try reloaded.configuration(for: .llamaCpp)
            XCTAssertEqual(configuration.baseURL.absoluteString, "https://inference.example/llama")
            XCTAssertEqual(configuration.model, "test-model")
        }
    }

    func testBrandMigrationCopiesValidPreferencesOnce() throws {
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
                XCTAssertNotNil(current.data(forKey: "appSettings"))
                migrated.backendSelection = .vllm
                migrated.showMenuBarTokensPerSecond = false
                migrated.showMenuBarLogo = false
                let retained = AppSettings(defaults: current, legacyDefaults: legacy)
                XCTAssertEqual(retained.backendSelection, .vllm)
                XCTAssertFalse(retained.showMenuBarTokensPerSecond)
                XCTAssertFalse(retained.showMenuBarLogo)
                XCTAssertNotNil(legacy.data(forKey: "appSettings"))
            }
        }
    }

    func testBrandMigrationPreservesExplicitMenuBarPreferences() throws {
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

                let reloaded = AppSettings(defaults: current)
                XCTAssertFalse(reloaded.showMenuBarTokensPerSecond)
                XCTAssertFalse(reloaded.showMenuBarLogo)
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

    func testMenuBarPreferencesPersistWhileBackendDraftIsInvalid() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.proxyPort = 0
            settings.backendSelection = .vllm
            settings.backendEndpoints[.vllm] = "file:///tmp/server"
            XCTAssertThrowsError(try settings.configuration(for: .ollama))
            XCTAssertThrowsError(try settings.configuration(for: .vllm))

            settings.showMenuBarTokensPerSecond = false
            settings.showMenuBarLogo = false
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertFalse(reloaded.showMenuBarTokensPerSecond)
            XCTAssertFalse(reloaded.showMenuBarLogo)
            XCTAssertEqual(reloaded.proxyPort, 0)
            XCTAssertEqual(reloaded.backendSelection, .vllm)
            XCTAssertEqual(reloaded.backendEndpoints[.vllm], "file:///tmp/server")
            XCTAssertThrowsError(try reloaded.configuration(for: .ollama))
            XCTAssertThrowsError(try reloaded.configuration(for: .vllm))

            reloaded.showMenuBarTokensPerSecond = true
            reloaded.showMenuBarLogo = true
            let restored = AppSettings(defaults: defaults)
            XCTAssertTrue(restored.showMenuBarTokensPerSecond)
            XCTAssertTrue(restored.showMenuBarLogo)
            XCTAssertThrowsError(try restored.configuration(for: .vllm))
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
