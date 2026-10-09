import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class WorkerAuthenticationTests: XCTestCase {
    private let studio = URL(string: "http://127.0.0.1:8888")!
    private let worker = URL(string: "http://127.0.0.1:54234")!

    func testConfiguredWorkerKeyAuthenticatesDetectionMetricsPropertiesAndSlotsWithoutAutoload()
        async throws
    {
        let transport = AuthenticatedWorkerTransport(key: "worker-key")
        let clock = WorkerAuthenticationClock()
        let client: any BackendClientProtocol = HTTPBackendClient(
            transport: { try await transport.respond($0) }, monotonicTime: { clock.now() })
        let configuration = BackendConfiguration(
            kind: .llamaCpp, baseURL: worker, model: "selected/model", workerAPIKey: "worker-key")
        let detected = try await client.detect(configuration)
        XCTAssertEqual(detected?.kind, .llamaCpp)
        let first = try await client.sample(configuration)
        XCTAssertEqual(first.throughputState, .warmingUp)
        clock.advance()
        let second = try await client.sample(configuration)
        XCTAssertEqual(second.currentTPS, 50)
        let requests = await transport.requests
        XCTAssertEqual(
            requests.map { $0.url?.path },
            ["/metrics", "/metrics", "/props", "/slots", "/metrics", "/slots"])
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer worker-key")
            let queries = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems
            XCTAssertEqual(queries?.first { $0.name == "autoload" }?.value, "false")
            XCTAssertEqual(queries?.first { $0.name == "model" }?.value, "selected/model")
        }
    }

    func testKnownWorkerDiscoveryPreservesMissingAndRejectedAuthenticationWithoutOtherProbes()
        async throws
    {
        for key in [nil, "rejected-key"] as [String?] {
            let transport = AuthenticatedWorkerTransport(key: "current-key")
            let client = HTTPBackendClient(transport: { try await transport.respond($0) })
            do {
                _ = try await client.detect(
                    .init(kind: .llamaCpp, baseURL: worker, workerAPIKey: key))
                XCTFail("An authenticated worker must require the current key")
            } catch { XCTAssertEqual(error as? BackendClientError, .httpStatus(401)) }
            let requests = await transport.requests
            XCTAssertEqual(requests.map { $0.url?.path }, ["/metrics"])
        }
    }

    func testPropertiesAndSlotsAuthenticationFailuresStayExplicit() async throws {
        for path in ["/props", "/slots"] {
            let transport = AuthenticatedWorkerTransport(key: "current-key", statuses: [path: 403])
            let client = HTTPBackendClient(transport: { try await transport.respond($0) })
            do {
                _ = try await client.sample(
                    .init(kind: .llamaCpp, baseURL: worker, workerAPIKey: "current-key"))
                XCTFail("A protected monitoring route must report rejected authentication")
            } catch { XCTAssertEqual(error as? BackendClientError, .httpStatus(403)) }
            let requests = await transport.requests
            XCTAssertEqual(requests.last?.url?.path, path)
            XCTAssertTrue(
                requests.allSatisfy {
                    $0.value(forHTTPHeaderField: "Authorization") == "Bearer current-key"
                })
        }
    }

    func testUnauthenticatedNativeLlamaKeepsMetricsWhenOptionalEndpointsRejectAuthentication()
        async throws
    {
        for path in ["/props", "/slots"] {
            let transport = AuthenticatedWorkerTransport(key: nil, statuses: [path: 401])
            let client = HTTPBackendClient(transport: { try await transport.respond($0) })
            let sample = try await client.sample(.init(kind: .llamaCpp, baseURL: worker))
            XCTAssertTrue(sample.isReady)
            XCTAssertEqual(sample.currentTPS, 0)
            XCTAssertEqual(sample.basis, .serverReportedAverage)
            XCTAssertNil(sample.nativeRequests)
            let requests = await transport.requests
            XCTAssertEqual(requests.last?.url?.path, path)
            XCTAssertTrue(
                requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        }
    }

    func testPropertiesDiscoveryAuthenticationFailureDoesNotBecomeMetricsDisabled() async throws {
        let transport = AuthenticatedWorkerTransport(
            key: "current-key", statuses: ["/metrics": 404, "/props": 403])
        let client = HTTPBackendClient(transport: { try await transport.respond($0) })
        do {
            _ = try await client.detect(
                .init(kind: .llamaCpp, baseURL: worker, workerAPIKey: "current-key"))
            XCTFail("Properties authentication must stay explicit")
        } catch { XCTAssertEqual(error as? BackendClientError, .httpStatus(403)) }
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/metrics", "/props"])
    }

    func testWorkerKeyNeverReachesGenericDetectionOtherBackendsOrRouterListing() async throws {
        let transport = AuthenticatedWorkerTransport(
            key: "worker-key", statuses: ["/metrics": 404, "/props": 404])
        let client = HTTPBackendClient(transport: { try await transport.respond($0) })
        _ = try await client.detect(
            .init(kind: .llamaCpp, baseURL: worker, workerAPIKey: "worker-key"))
        _ = try await client.detect(at: worker)
        _ = try await client.detect(.init(kind: .vllm, baseURL: worker, workerAPIKey: "worker-key"))
        do {
            _ = try await client.sample(
                .init(kind: .ollama, baseURL: worker, workerAPIKey: "worker-key"))
            XCTFail("Synthetic worker has no Ollama endpoint")
        } catch { XCTAssertEqual(error as? BackendClientError, .httpStatus(404)) }
        let requests = await transport.requests
        XCTAssertEqual(
            requests.prefix(2).map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer worker-key", "Bearer worker-key"])
        XCTAssertTrue(
            requests.dropFirst(2).allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == nil
            })
        XCTAssertTrue(requests.contains { $0.url?.path == "/models" })
        XCTAssertTrue(requests.contains { $0.url?.path == "/api/version" })
    }

    func testInvalidWorkerKeyHeaderValuesFailBeforeAnyRequest() async throws {
        let transport = AuthenticatedWorkerTransport(key: "current-key")
        let client = HTTPBackendClient(transport: { try await transport.respond($0) })
        for key in [
            "key\r\nInjected: header", "key\u{0}", "key with space", "key\tvalue", "café",
            String(repeating: "a", count: 16_385),
        ] {
            for discovery in [true, false] {
                do {
                    let configuration = BackendConfiguration(
                        kind: .llamaCpp, baseURL: worker, workerAPIKey: key)
                    if discovery {
                        _ = try await client.detect(configuration)
                    } else {
                        _ = try await client.sample(configuration)
                    }
                    XCTFail("An invalid header value must be rejected")
                } catch {
                    guard case .configurationRequired(let message) = error as? BackendClientError
                    else {
                        return XCTFail("Expected key validation guidance")
                    }
                    XCTAssertFalse(message.contains(key))
                }
            }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testWorkerKeyRejectsRemoteHostnamePathAndURLCredentialTargetsBeforeRequests() async throws
    {
        let transport = AuthenticatedWorkerTransport(key: "current-key")
        let client = HTTPBackendClient(transport: { try await transport.respond($0) })
        for address in [
            "http://remote.example:54234", "http://localhost:54234", "http://127.0.0.2:54234",
            "http://127.0.0.1:54234/api", "http://user:password@127.0.0.1:54234",
            "http://127.0.0.1:54234?key=value", "http://127.0.0.1:54234#fragment",
            "https://127.0.0.1:54234",
        ] {
            let configuration = BackendConfiguration(
                kind: .llamaCpp, baseURL: URL(string: address)!, workerAPIKey: "current-key")
            for discovery in [true, false] {
                do {
                    if discovery {
                        _ = try await client.detect(configuration)
                    } else {
                        _ = try await client.sample(configuration)
                    }
                    XCTFail("A worker key must be scoped to a literal local HTTP root")
                } catch { XCTAssertTrue(error is BackendClientError) }
            }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testIPv6LiteralWorkerRootSupportsScopedAuthentication() async throws {
        let transport = AuthenticatedWorkerTransport(key: "current-key")
        let client = HTTPBackendClient(transport: { try await transport.respond($0) })
        let detected = try await client.detect(
            .init(
                kind: .llamaCpp, baseURL: URL(string: "http://[::1]:54234/")!,
                workerAPIKey: "current-key"))
        XCTAssertEqual(detected?.kind, .llamaCpp)
        let requests = await transport.requests
        XCTAssertEqual(
            requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer current-key")
    }

    func testUnslothUsesCanonicalConfiguredStudioKeyOnlyForItsVerifiedWorker() async throws {
        let transport = AuthenticatedWorkerTransport(key: "worker-key")
        let client: any BackendClientProtocol = makeUnsloth(transport)
        let configuration = BackendConfiguration(
            kind: .unsloth, baseURL: URL(string: "http://localhost:8888/")!,
            studioMonitorToken: "studio-token", workerAPIKey: "worker-key")
        let detected = await client.discoverLocalBackends(configurations: [configuration])
        XCTAssertEqual(detected.first?.baseURL, studio)
        XCTAssertTrue(detected.first?.isReady == true)
        let sample = try await client.sample(configuration)
        XCTAssertEqual(sample.kind, .unsloth)
        XCTAssertEqual(sample.model, "worker-model")
        XCTAssertTrue(sample.detail?.contains("Studio request history is unavailable") == true)
        let requests = await transport.requests
        let workerRequests = requests.filter { $0.url?.port == 54234 }
        XCTAssertEqual(
            workerRequests.map { $0.url?.path }, ["/metrics", "/metrics", "/props", "/slots"])
        XCTAssertTrue(
            workerRequests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer worker-key"
            })
        let studioRequests = requests.filter { $0.url?.port == 8888 }
        XCTAssertEqual(studioRequests.map { $0.url?.path }, ["/api/inference/monitor"])
        XCTAssertEqual(
            studioRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer studio-token")
    }

    func testAutomaticWorkerKeyAuthenticatesDiscoveryAndSamplingWithoutEnteringSettings()
        async throws
    {
        let transport = AuthenticatedWorkerTransport(key: "automatic-key")
        let reader = AutomaticWorkerKeyStub(key: "automatic-key")
        let server = verifiedServer(workerKeySource: automaticSource())
        let client = makeUnsloth(transport, servers: [server], workerKeyReader: reader)
        let configuration = BackendConfiguration(
            kind: .unsloth, baseURL: studio, studioMonitorToken: "studio-token")
        let detections = await client.discoverLocalBackends(configurations: [configuration])
        XCTAssertTrue(detections.first?.isReady == true)
        let sample = try await client.sample(configuration)
        XCTAssertEqual(sample.kind, .unsloth)
        XCTAssertEqual(sample.model, "worker-model")
        XCTAssertNil(configuration.workerAPIKey)
        let reads = await reader.servers
        XCTAssertEqual(reads, [server, server])
        let requests = await transport.requests
        let workerRequests = requests.filter { $0.url?.port == 54234 }
        XCTAssertEqual(
            workerRequests.map { $0.url?.path }, ["/metrics", "/metrics", "/props", "/slots"])
        XCTAssertTrue(
            workerRequests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer automatic-key"
                    && $0.httpMethod == "GET"
            })
        let studioRequests = requests.filter { $0.url?.port == 8888 }
        XCTAssertEqual(studioRequests.map { $0.url?.path }, ["/api/inference/monitor"])
        XCTAssertEqual(
            studioRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer studio-token")
    }

    func testManualWorkerOverrideTakesPrecedenceAndBlankRestoresAutomaticLookup() async throws {
        let transport = AuthenticatedWorkerTransport(key: "override-key")
        let reader = AutomaticWorkerKeyStub(key: "automatic-key")
        let client = makeUnsloth(
            transport, servers: [verifiedServer(workerKeySource: automaticSource())],
            workerKeyReader: reader)
        let manual = BackendConfiguration(
            kind: .unsloth, baseURL: studio, workerAPIKey: "override-key")
        _ = try await client.sample(manual)
        let manualReads = await reader.servers
        XCTAssertTrue(manualReads.isEmpty)
        await transport.replaceKey("automatic-key", model: "automatic-model")
        let automatic = try await client.sample(
            .init(kind: .unsloth, baseURL: studio, workerAPIKey: " \t\r\n"))
        XCTAssertEqual(automatic.model, "automatic-model")
        XCTAssertEqual(automatic.throughputState, .warmingUp)
        let automaticReads = await reader.servers
        XCTAssertEqual(automaticReads.count, 1)
        let requests = await transport.requests
        XCTAssertTrue(
            requests.prefix(4).allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer override-key"
            })
        XCTAssertTrue(
            requests.suffix(4).allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer automatic-key"
            })
    }

    func testAutomaticLookupFailureStopsRequestsAndExplicitOverrideCanRecover() async throws {
        let transport = AuthenticatedWorkerTransport(key: "override-key")
        let reader = AutomaticWorkerKeyStub(key: nil, unavailable: true)
        let client = makeUnsloth(
            transport, servers: [verifiedServer(workerKeySource: .unavailable)],
            workerKeyReader: reader)
        let automatic = BackendConfiguration(kind: .unsloth, baseURL: studio)
        let detected = try await client.detect(automatic)
        XCTAssertFalse(detected?.isReady ?? true)
        XCTAssertTrue(detected?.detail?.localizedCaseInsensitiveContains("automatic") == true)
        do {
            _ = try await client.sample(automatic)
            XCTFail("An unavailable automatic key must not produce unauthenticated probes")
        } catch {
            guard case .configurationRequired(let message) = error as? BackendClientError else {
                return XCTFail("Expected safe lookup guidance")
            }
            XCTAssertTrue(message.contains("override"))
        }
        let failedRequests = await transport.requests
        XCTAssertTrue(failedRequests.isEmpty)
        let recovered = try await client.sample(
            .init(kind: .unsloth, baseURL: studio, workerAPIKey: "override-key"))
        XCTAssertEqual(recovered.kind, .unsloth)
        let reads = await reader.servers
        XCTAssertEqual(reads.count, 2, "The manual override must not consult the failing reader")
    }

    func testAutomaticKeyRotationRefreshesCapabilitiesAndThroughputWithoutSettingsChanges()
        async throws
    {
        let transport = AuthenticatedWorkerTransport(key: "first-key")
        let reader = AutomaticWorkerKeyStub(key: "first-key")
        let clock = WorkerAuthenticationClock()
        let client = makeUnsloth(
            transport, clock: clock,
            servers: [verifiedServer(workerKeySource: automaticSource())], workerKeyReader: reader)
        let configuration = BackendConfiguration(kind: .unsloth, baseURL: studio)
        let first = try await client.sample(configuration)
        clock.advance()
        let measured = try await client.sample(configuration)
        XCTAssertEqual(measured.currentTPS, 50)
        await reader.replaceKey("second-key")
        await transport.replaceKey("second-key", model: "reloaded-model")
        clock.advance()
        let rotated = try await client.sample(configuration)
        XCTAssertEqual(rotated.model, "reloaded-model")
        XCTAssertEqual(rotated.throughputState, .warmingUp)
        XCTAssertNil(rotated.currentTPS)
        XCTAssertNotEqual(rotated.nativeRequests?.sourceEpoch, first.nativeRequests?.sourceEpoch)
        XCTAssertNil(configuration.workerAPIKey)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/props" }.count, 2)
        XCTAssertTrue(
            requests.suffix(4).allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer second-key"
            })
    }

    func testSupersededAutomaticLookupCannotInvalidateNewCredentials() async throws {
        let gate = WorkerAuthenticationGate()
        let transport = AuthenticatedWorkerTransport(key: "first-key")
        let reader = AutomaticWorkerKeyStub(key: "first-key", initialGate: gate)
        let client = makeUnsloth(
            transport, servers: [verifiedServer(workerKeySource: automaticSource())],
            workerKeyReader: reader)
        let configuration = BackendConfiguration(kind: .unsloth, baseURL: studio)
        let old = Task { try await client.sample(configuration) }
        await gate.waitUntilStarted()
        await reader.replaceKey("second-key")
        await transport.replaceKey("second-key", model: "replacement-model")
        let current = try await client.sample(configuration)
        XCTAssertEqual(current.model, "replacement-model")
        await gate.release()
        do {
            _ = try await old.value
            XCTFail("A superseded automatic lookup must be cancelled")
        } catch { XCTAssertTrue(error is CancellationError) }
        let recovered = try await client.sample(configuration)
        XCTAssertEqual(recovered.model, "replacement-model")
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/props" }.count, 1)
        XCTAssertTrue(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer second-key"
            })
    }

    func testResetRejectsDelayedAutomaticKeyBeforeMakingAnyRequests() async throws {
        let gate = WorkerAuthenticationGate()
        let transport = AuthenticatedWorkerTransport(key: "first-key")
        let reader = AutomaticWorkerKeyStub(key: "first-key", initialGate: gate)
        let client = makeUnsloth(
            transport, servers: [verifiedServer(workerKeySource: automaticSource())],
            workerKeyReader: reader)
        let configuration = BackendConfiguration(kind: .unsloth, baseURL: studio)
        let old = Task { try await client.sample(configuration) }
        await gate.waitUntilStarted()
        await client.reset()
        await reader.replaceKey("second-key")
        await transport.replaceKey("second-key", model: "replacement-model")
        _ = try await client.sample(configuration)
        await gate.release()
        do {
            _ = try await old.value
            XCTFail("Reset must reject a delayed automatic key")
        } catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertTrue(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer second-key"
            })
    }

    func testAutomaticKeyReaderIsNotUsedForKeylessUnverifiedOrOtherBackends() async throws {
        let keylessTransport = AuthenticatedWorkerTransport(key: nil)
        let reader = AutomaticWorkerKeyStub(key: "automatic-key", unavailable: true)
        let keyless = makeUnsloth(keylessTransport, workerKeyReader: reader)
        _ = try await keyless.sample(.init(kind: .unsloth, baseURL: studio))
        for server in [
            verifiedServer(workerURL: studio, workerKeySource: automaticSource()),
            verifiedServer(
                workerURL: URL(string: "http://remote.example:54234")!,
                workerKeySource: automaticSource()),
            verifiedServer(workerIdentity: nil, workerKeySource: automaticSource()),
        ] {
            let client = makeUnsloth(keylessTransport, servers: [server], workerKeyReader: reader)
            do {
                _ = try await client.sample(.init(kind: .unsloth, baseURL: studio))
                XCTFail("Unverified worker bindings must not retrieve a key")
            } catch { XCTAssertTrue(error is BackendClientError) }
        }
        _ = try await keyless.detect(.init(kind: .vllm, baseURL: worker))
        _ = try await keyless.detect(at: URL(string: "http://127.0.0.1:9999")!)
        let reads = await reader.servers
        XCTAssertTrue(reads.isEmpty)
        let requests = await keylessTransport.requests
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testUnslothDiscoveryDoesNotBorrowKeysFromOtherKindsOrStudioPorts() async throws {
        for configurations in [
            [BackendConfiguration(kind: .llamaCpp, baseURL: studio, workerAPIKey: "worker-key")],
            [
                BackendConfiguration(
                    kind: .unsloth, baseURL: URL(string: "http://localhost:9999")!,
                    workerAPIKey: "worker-key")
            ],
            [],
        ] {
            let transport = AuthenticatedWorkerTransport(key: "worker-key")
            let client = makeUnsloth(transport)
            let results = await client.discoverLocalBackends(configurations: configurations)
            XCTAssertTrue(results.first?.detail?.contains("worker API key in Settings") == true)
            XCTAssertFalse(results.first?.detail?.contains("metrics disabled") == true)
            let requests = await transport.requests
            XCTAssertEqual(requests.map { $0.url?.path }, ["/metrics"])
            XCTAssertTrue(
                requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        }
    }

    func testUnslothMissingAndRejectedWorkerKeyGiveConfigureGuidanceThenRecover() async throws {
        for key in [nil, "rejected-key"] as [String?] {
            let transport = AuthenticatedWorkerTransport(key: "current-key")
            let client = makeUnsloth(transport)
            let invalid = BackendConfiguration(kind: .unsloth, baseURL: studio, workerAPIKey: key)
            let detected = try await client.detect(invalid)
            XCTAssertFalse(detected?.isReady ?? true)
            XCTAssertTrue(detected?.detail?.contains("HTTP 401") == true)
            do {
                _ = try await client.sample(invalid)
                XCTFail("Worker authentication must require configuration")
            } catch {
                guard case .configurationRequired(let message) = error as? BackendClientError else {
                    return XCTFail("Expected authentication guidance")
                }
                XCTAssertTrue(message.contains("worker API key in Settings"))
                XCTAssertTrue(message.contains("restarts"))
                XCTAssertTrue(message.contains("Studio monitor token is separate"))
                if let key { XCTAssertFalse(message.contains(key)) }
            }
            let recovered = try await client.sample(
                .init(kind: .unsloth, baseURL: studio, workerAPIKey: "current-key"))
            XCTAssertEqual(recovered.kind, .unsloth)
            XCTAssertEqual(recovered.throughputState, .warmingUp)
        }
    }

    func testUnslothKeyRotationRevalidatesCapabilitiesModelAndSlotBaselines() async throws {
        let transport = AuthenticatedWorkerTransport(key: "first-key")
        let clock = WorkerAuthenticationClock()
        let client = makeUnsloth(transport, clock: clock)
        let firstConfiguration = BackendConfiguration(
            kind: .unsloth, baseURL: studio, workerAPIKey: "first-key")
        let first = try await client.sample(firstConfiguration)
        clock.advance()
        let measured = try await client.sample(firstConfiguration)
        XCTAssertEqual(measured.currentTPS, 50)
        await transport.replaceKey("second-key", model: "replacement-model")
        clock.advance()
        let rotated = try await client.sample(
            .init(kind: .unsloth, baseURL: studio, workerAPIKey: "second-key"))
        XCTAssertEqual(rotated.model, "replacement-model")
        XCTAssertEqual(rotated.throughputState, .warmingUp)
        XCTAssertNil(rotated.currentTPS)
        XCTAssertNotEqual(rotated.nativeRequests?.sourceEpoch, first.nativeRequests?.sourceEpoch)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/props" }.count, 2)
        XCTAssertEqual(requests.filter { $0.url?.path == "/metrics" }.count, 5)
        XCTAssertEqual(
            requests.suffix(4).map { $0.value(forHTTPHeaderField: "Authorization") },
            Array(repeating: "Bearer second-key", count: 4))
    }

    func testUnslothCredentialRotationCancelsInitialInflightCapabilityProbe() async throws {
        let gate = WorkerAuthenticationGate()
        let transport = AuthenticatedWorkerTransport(key: "first-key", initialGate: gate)
        let client = makeUnsloth(transport)
        let old = Task {
            try await client.sample(
                .init(kind: .unsloth, baseURL: studio, workerAPIKey: "first-key"))
        }
        await gate.waitUntilStarted()
        await transport.replaceKey("second-key", model: "replacement-model")
        let updated = try await client.sample(
            .init(kind: .unsloth, baseURL: studio, workerAPIKey: "second-key"))
        XCTAssertEqual(updated.model, "replacement-model")
        await gate.release()
        do {
            _ = try await old.value
            XCTFail("An old key must not publish after replacement")
        } catch { XCTAssertTrue(error is CancellationError) }
        let recovered = try await client.sample(
            .init(kind: .unsloth, baseURL: studio, workerAPIKey: "second-key"))
        XCTAssertEqual(recovered.model, "replacement-model")
    }

    func testUnslothRejectsUnverifiedOrStudioWorkerBindingBeforeSendingKey() async throws {
        for server in [
            verifiedServer(workerURL: studio),
            verifiedServer(workerURL: URL(string: "http://remote.example:54234")!),
            verifiedServer(workerURL: URL(string: "http://localhost:54234")!),
            verifiedServer(workerURL: worker, workerIdentity: nil),
        ] {
            let transport = AuthenticatedWorkerTransport(key: "current-key")
            let client = makeUnsloth(transport, servers: [server])
            do {
                _ = try await client.sample(
                    .init(kind: .unsloth, baseURL: studio, workerAPIKey: "current-key"))
                XCTFail("A worker key requires a verified distinct local worker")
            } catch { XCTAssertTrue(error is BackendClientError) }
            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    private func makeUnsloth(
        _ transport: AuthenticatedWorkerTransport,
        clock: WorkerAuthenticationClock = WorkerAuthenticationClock(),
        servers: [UnslothServer]? = nil,
        workerKeyReader: any UnslothWorkerKeyReading = UnslothWorkerKeyReader()
    ) -> UnslothBackendClient {
        UnslothBackendClient(
            normal: HTTPBackendClient(
                transport: { try await transport.respond($0) }, monotonicTime: { clock.now() }),
            discovery: WorkerAuthenticationDiscovery(servers ?? [verifiedServer()]),
            workerKeyReader: workerKeyReader,
            studioMonitorTransport: { try await transport.respond($0) })
    }

    private func verifiedServer(
        workerURL: URL? = URL(string: "http://127.0.0.1:54234")!,
        workerIdentity: GPUProcessIdentity? = .init(pid: 202, startTimeMicroseconds: 200),
        workerKeySource: UnslothWorkerKeySource = .none
    ) -> UnslothServer {
        .init(
            studioURL: studio, workerURL: workerURL,
            studioIdentity: .init(pid: 101, startTimeMicroseconds: 100),
            workerIdentity: workerIdentity, workerKeySource: workerKeySource)
    }

    private func automaticSource() -> UnslothWorkerKeySource {
        let directory = URL(fileURLWithPath: "/Users/example/.unsloth/studio/auth")
        return .file(
            .init(
                fileURL: directory.appendingPathComponent("llama_api_key_0123456789abcdef"),
                authDirectoryURL: directory))
    }
}

private actor AutomaticWorkerKeyStub: UnslothWorkerKeyReading {
    private var key: String?
    private let unavailable: Bool
    private var initialGate: WorkerAuthenticationGate?
    private(set) var servers: [UnslothServer] = []

    init(key: String?, unavailable: Bool = false, initialGate: WorkerAuthenticationGate? = nil) {
        self.key = key
        self.unavailable = unavailable
        self.initialGate = initialGate
    }

    func replaceKey(_ key: String) { self.key = key }

    func key(for server: UnslothServer) async throws -> String? {
        servers.append(server)
        if unavailable {
            throw BackendClientError.configurationRequired(
                "Automatic worker authentication is unavailable; enter a manual override.")
        }
        let result = key
        if let gate = initialGate {
            initialGate = nil
            await gate.hold()
        }
        return result
    }
}

private actor AuthenticatedWorkerTransport {
    private var key: String?
    private var model = "worker-model"
    private let statuses: [String: Int]
    private var decoded = 0
    private var initialGate: WorkerAuthenticationGate?
    private(set) var requests: [URLRequest] = []

    init(key: String?, statuses: [String: Int] = [:], initialGate: WorkerAuthenticationGate? = nil)
    {
        self.key = key
        self.statuses = statuses
        self.initialGate = initialGate
    }

    func replaceKey(_ key: String, model: String) {
        self.key = key
        self.model = model
    }

    func respond(_ request: URLRequest) async throws -> BackendHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        if path == "/metrics", let gate = initialGate {
            initialGate = nil
            await gate.hold()
        }
        if let status = statuses[path] { return .init(statusCode: status, data: Data()) }
        guard request.url?.port == 54234, ["/metrics", "/props", "/slots"].contains(path) else {
            return .init(statusCode: 404, data: Data())
        }
        guard request.value(forHTTPHeaderField: "Authorization") == key.map({ "Bearer \($0)" })
        else {
            return .init(statusCode: 401, data: Data())
        }
        let text: String
        switch path {
        case "/metrics":
            text =
                "llamacpp:requests_processing 1\nllamacpp:predicted_tokens_seconds 0\nprocess_start_time_seconds 100"
        case "/props":
            text = """
                {"model_alias":"\(model)","default_generation_settings":{},"total_slots":1,
                 "endpoint_metrics":true,"endpoint_slots":true}
                """
        default:
            decoded += 50
            text = """
                [{"id":3,"id_task":5893,"is_processing":true,"next_token":[{"n_decoded":\(decoded)}]}]
                """
        }
        return .init(statusCode: 200, data: Data(text.utf8))
    }
}

private actor WorkerAuthenticationDiscovery: UnslothDiscovering {
    private let values: [UnslothServer]
    init(_ values: [UnslothServer]) { self.values = values }
    func servers() async -> [UnslothServer] { values }
}

private final class WorkerAuthenticationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 1 } }
}

private actor WorkerAuthenticationGate {
    private var started = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        started = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        blocked?.resume()
        blocked = nil
    }
}
