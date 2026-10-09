import Foundation
import XCTest

@testable import FluxLLM

/// Synthetic Studio ownership and native responses precede the adapter implementation.
/// No test needs a model, credentials, a generation endpoint, or the user's Studio.
@MainActor
final class UnslothBackendClientTests: XCTestCase {
    private let studio = URL(string: "http://127.0.0.1:8888")!
    private let worker = URL(string: "http://127.0.0.1:54234")!

    func testDiscoveryKeepsStudioEndpointWhileVerifyingItsWorker() async throws {
        let backend = UnslothUnderlyingStub(
            detection: .init(
                kind: .llamaCpp, baseURL: worker, version: "native-build"))
        let discovery = UnslothDiscoveryStub([server()])
        let client = UnslothBackendClient(normal: backend, discovery: discovery)
        let detected = await client.discoverLocalBackends()
        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first?.kind, .unsloth)
        XCTAssertEqual(detected.first?.baseURL, studio)
        XCTAssertEqual(detected.first?.version, "native-build")
        XCTAssertTrue(detected.first?.isReady == true)
        let urls = await backend.detectedURLs
        XCTAssertEqual(urls, [worker])
    }

    func testUnloadedStudioIsDiscoverableWithoutProbingAnInventedWorker() async throws {
        let backend = UnslothUnderlyingStub()
        let discovery = UnslothDiscoveryStub([server(workerURL: nil, workerPID: nil)])
        let client = UnslothBackendClient(normal: backend, discovery: discovery)
        let detected = await client.discoverLocalBackends()
        XCTAssertEqual(detected.first?.kind, .unsloth)
        XCTAssertFalse(detected.first?.isReady ?? true)
        XCTAssertFalse(detected.first?.supportsLiveMetrics ?? true)
        XCTAssertTrue(detected.first?.detail?.contains("Load") == true)
        await assertConfigurationError(client, containing: "Load")
        let detects = await backend.detectedURLs
        let samples = await backend.configurations
        XCTAssertTrue(detects.isEmpty)
        XCTAssertTrue(samples.isEmpty)
    }

    func testActiveAndIdleSamplesUseOnlyNativeReadOnlyMetricsAndCacheModel() async throws {
        let active = """
            llamacpp:tokens_predicted_total 1000
            llamacpp:prompt_tokens_total 2000
            llamacpp:predicted_tokens_seconds 25.5
            llamacpp:requests_processing 2
            llamacpp:requests_deferred 1
            """
        let idle = """
            llamacpp:tokens_predicted_total 1000
            llamacpp:predicted_tokens_seconds 25.5
            llamacpp:requests_processing 0
            """
        let transport = UnslothTransportStub([
            "/metrics": [.ok(active), .ok(active), .ok(idle)],
            "/props": [.ok(#"{"model_alias":"local-unsloth-model","endpoint_metrics":true}"#)],
        ])
        let client = UnslothBackendClient(
            normal: HTTPBackendClient(transport: { try await transport.respond($0) }),
            discovery: UnslothDiscoveryStub([server()]))
        let activeSample = try await client.sample(configuration())
        XCTAssertEqual(activeSample.kind, .unsloth)
        XCTAssertEqual(activeSample.model, "local-unsloth-model")
        XCTAssertEqual(activeSample.currentTPS, 25.5)
        XCTAssertEqual(activeSample.basis, .serverReportedAverage)
        XCTAssertEqual(activeSample.runningRequests, 2)
        XCTAssertEqual(activeSample.queuedRequests, 1)
        XCTAssertEqual(activeSample.outputTokens, 1000)
        XCTAssertEqual(activeSample.promptTokens, 2000)
        XCTAssertNil(activeSample.inferenceGPUPercent)
        let idleSample = try await client.sample(configuration())
        XCTAssertEqual(idleSample.runningRequests, 0)
        XCTAssertEqual(
            idleSample.currentTPS, 25.5, "The persistent gauge remains a reported average")
        XCTAssertNil(idleSample.queuedRequests)
        XCTAssertNil(idleSample.promptTokens)
        let requests = await transport.requests
        XCTAssertEqual(
            requests.map { $0.url?.path }, ["/metrics", "/metrics", "/props", "/metrics"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.port == 54234 })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertTrue(
            requests.allSatisfy { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "autoload" })?.value == "false"
            })
    }

    func testEveryOptionalFieldIsPreservedWithoutInventingMeasurements() async throws {
        let timestamp = Date(timeIntervalSince1970: 1234)
        let source = BackendSample(
            kind: .llamaCpp, timestamp: timestamp, model: "model", isReady: false,
            currentTPS: 42, basis: .serverAggregate,
            throughputState: .measured, measurementDuration: 1.25, runningRequests: 3,
            queuedRequests: 4, outputTokens: 50, promptTokens: 60,
            inferenceGPUPercent: 7, gpuSource: "explicit server measurement",
            detail: "native detail")
        let backend = UnslothUnderlyingStub(
            detection: .init(kind: .llamaCpp, baseURL: worker), samples: [source])
        let client = UnslothBackendClient(
            normal: backend, discovery: UnslothDiscoveryStub([server()]))
        let sample = try await client.sample(configuration())
        XCTAssertEqual(sample.kind, .unsloth)
        XCTAssertEqual(sample.timestamp, timestamp)
        XCTAssertEqual(sample.model, source.model)
        XCTAssertEqual(sample.isReady, source.isReady)
        XCTAssertEqual(sample.currentTPS, source.currentTPS)
        XCTAssertEqual(sample.basis, source.basis)
        XCTAssertEqual(sample.throughputState, source.throughputState)
        XCTAssertEqual(sample.measurementDuration, source.measurementDuration)
        XCTAssertEqual(sample.runningRequests, source.runningRequests)
        XCTAssertEqual(sample.queuedRequests, source.queuedRequests)
        XCTAssertEqual(sample.outputTokens, source.outputTokens)
        XCTAssertEqual(sample.promptTokens, source.promptTokens)
        XCTAssertEqual(sample.inferenceGPUPercent, source.inferenceGPUPercent)
        XCTAssertEqual(sample.gpuSource, source.gpuSource)
        XCTAssertEqual(sample.detail, source.detail)

        await backend.replaceSamples([.init(kind: .llamaCpp)])
        let unknown = try await client.sample(configuration())
        XCTAssertNil(unknown.currentTPS)
        XCTAssertEqual(unknown.throughputState, .unavailable)
        XCTAssertNil(unknown.measurementDuration)
        XCTAssertNil(unknown.model)
        XCTAssertNil(unknown.runningRequests)
        XCTAssertNil(unknown.queuedRequests)
        XCTAssertNil(unknown.outputTokens)
        XCTAssertNil(unknown.promptTokens)
        XCTAssertNil(unknown.inferenceGPUPercent)
        XCTAssertNil(unknown.gpuSource)

        await backend.replaceSamples([
            .init(kind: .llamaCpp, throughputState: .warmingUp, runningRequests: 1)
        ])
        let warmup = try await client.sample(configuration())
        XCTAssertEqual(warmup.throughputState, .warmingUp)
        XCTAssertNil(warmup.currentTPS)
        XCTAssertNil(warmup.measurementDuration)
    }

    func testLiveSlotCountsReachDisplayWhileReportedGaugeIsZeroAndClearOnIdle() async throws {
        let active = """
            llamacpp:tokens_predicted_total 1000
            llamacpp:prompt_tokens_total 2000
            llamacpp:predicted_tokens_seconds 0
            llamacpp:requests_processing 1
            llamacpp:requests_deferred 0
            """
        let idle = """
            llamacpp:tokens_predicted_total 1137
            llamacpp:prompt_tokens_total 2000
            llamacpp:predicted_tokens_seconds 56
            llamacpp:requests_processing 0
            llamacpp:requests_deferred 0
            """
        let transport = UnslothTransportStub([
            "/metrics": [.ok(active), .ok(active), .ok(active), .ok(idle)],
            "/props": [
                .ok(
                    #"""
                    {"model_alias":"local-unsloth-model",
                    "endpoint_metrics":true,"endpoint_slots":true}
                    """#)
            ],
            "/slots": [
                .ok(
                    #"""
                    [{"id":3,"id_task":5893,"is_processing":true,
                    "next_token":[{"n_decoded":81}]}]
                    """#),
                .ok(
                    #"""
                    [{"id":3,"id_task":5893,"is_processing":true,
                    "next_token":[{"n_decoded":137}]}]
                    """#),
            ],
        ])
        let clock = UnslothSlotTestClock()
        let client = UnslothBackendClient(
            normal: HTTPBackendClient(
                transport: { try await transport.respond($0) },
                monotonicTime: { clock.now() }, wallClock: { clock.date() }),
            discovery: UnslothDiscoveryStub([server()]))
        let store = MetricsStore(clock: { clock.date() })
        let epoch = UUID()
        store.beginBackendSession(kind: .unsloth, epoch: epoch)

        let baseline = try await client.sample(configuration())
        store.applyBackendSample(baseline, epoch: epoch)
        store.sample(at: clock.date())
        XCTAssertEqual(baseline.basis, .serverAggregate)
        XCTAssertNil(baseline.currentTPS)
        XCTAssertEqual(baseline.throughputState, .warmingUp)
        XCTAssertNil(baseline.measurementDuration)
        XCTAssertEqual(store.displayTPS, 0)
        XCTAssertFalse(store.rateIsAvailable)
        XCTAssertEqual(store.tpsHistory.last?.isAvailable, false)
        XCTAssertNil(store.lastMeasuredTPS)
        XCTAssertTrue(store.isBackendActive)
        XCTAssertEqual(store.requestLanes.count, 1)
        let baselineLane = try XCTUnwrap(store.requestLanes.first)
        XCTAssertEqual(baselineLane.outputTokens, 81)

        clock.advance(1)
        let generating = try await client.sample(configuration())
        store.applyBackendSample(generating, epoch: epoch)
        store.sample(at: clock.date())
        XCTAssertEqual(generating.currentTPS, 56)
        XCTAssertEqual(generating.throughputState, .measured)
        XCTAssertEqual(generating.measurementDuration, 1)
        XCTAssertEqual(generating.outputTokens, 1000, "Batched totals cannot supply the live rate")
        XCTAssertEqual(store.displayTPS, 56)
        XCTAssertEqual(store.throughputBasis, .serverAggregate)
        XCTAssertNil(
            store.activeGeneration, "Slot polling must not create authoritative proxy generation")
        XCTAssertEqual(store.requestLanes.count, 1)
        XCTAssertEqual(store.requestLanes.first?.id, baselineLane.id)
        XCTAssertEqual(store.requestLanes.first?.outputTokens, 137)

        clock.advance(1)
        let finished = try await client.sample(configuration())
        store.applyBackendSample(finished, epoch: epoch)
        XCTAssertEqual(store.displayTPS, 0)
        XCTAssertEqual(store.lastMeasuredTPS, 56)
        XCTAssertFalse(store.isBackendActive)
        XCTAssertEqual(store.requestLanes.count, 1)
        XCTAssertTrue(store.requestLanes.first?.terminal == true)
        XCTAssertNotNil(store.requestLanes.first?.endedAt)
        let usage = store.usageSummary(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 99), end: clock.date()))
        XCTAssertEqual(usage.requests, 0)
        XCTAssertEqual(usage.outputTokens, 0)

        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/slots" }.count, 2)
        XCTAssertEqual(requests.filter { $0.url?.path == "/props" }.count, 1)
    }

    func testVerifiedWorkerReplacementAtSamePortResetsLiveSlotBaseline() async throws {
        let active = """
            llamacpp:predicted_tokens_seconds 0
            llamacpp:requests_processing 1
            """
        let transport = UnslothTransportStub([
            "/metrics": Array(repeating: .ok(active), count: 6),
            "/props": [
                .ok(#"{"model_alias":"first","endpoint_slots":true}"#),
                .ok(#"{"model_alias":"second","endpoint_slots":true}"#),
            ],
            "/slots": [100, 156, 10000, 10056].map { count in
                .ok(
                    "[{\"id\":3,\"id_task\":5893,\"is_processing\":true,"
                        + "\"next_token\":[{\"n_decoded\":\(count)}]}]")
            },
        ])
        let clock = UnslothSlotTestClock()
        let discovery = UnslothDiscoveryStub([server()])
        let client = UnslothBackendClient(
            normal: HTTPBackendClient(
                transport: { try await transport.respond($0) },
                monotonicTime: { clock.now() }),
            discovery: discovery)
        let baseline = try await client.sample(configuration())
        XCTAssertNil(baseline.currentTPS)
        XCTAssertEqual(baseline.throughputState, .warmingUp)
        clock.advance(1)
        let firstWorkerRate = try await client.sample(configuration())
        XCTAssertEqual(firstWorkerRate.currentTPS, 56)
        let firstSource = try XCTUnwrap(firstWorkerRate.nativeRequests?.sourceEpoch)

        // PID, port, slot and task IDs can all be reused; process birth proves replacement.
        await discovery.replace([server(workerBirth: 300)])
        clock.advance(1)
        let replaced = try await client.sample(configuration())
        XCTAssertNil(replaced.currentTPS, "The new worker's cumulative count needs a baseline")
        XCTAssertEqual(replaced.throughputState, .warmingUp)
        XCTAssertNil(replaced.measurementDuration)
        XCTAssertEqual(replaced.model, "second")
        XCTAssertNotEqual(replaced.nativeRequests?.sourceEpoch, firstSource)
        clock.advance(1)
        let secondWorkerRate = try await client.sample(configuration())
        XCTAssertEqual(secondWorkerRate.currentTPS, 56)

        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/props" }.count, 2)
    }

    func testOrdinaryBackendDetectionAndSamplingRemainDelegated() async throws {
        let remote = URL(string: "https://server.example:8000/prefix")!
        let native = DetectedBackend(kind: .vllm, baseURL: remote)
        let backend = UnslothUnderlyingStub(
            detection: native, samples: [.init(kind: .vllm, currentTPS: 12)])
        let discovery = UnslothDiscoveryStub([server()])
        let client = UnslothBackendClient(normal: backend, discovery: discovery)
        let detected = try await client.detect(at: remote)
        XCTAssertEqual(detected, native)
        let config = BackendConfiguration(
            kind: .vllm, baseURL: remote, model: "chosen", proxyPort: 9999)
        let sample = try await client.sample(config)
        XCTAssertEqual(sample.kind, .vllm)
        XCTAssertEqual(sample.currentTPS, 12)
        let configs = await backend.configurations
        let calls = await discovery.calls
        XCTAssertEqual(configs, [config])
        XCTAssertEqual(calls, 0)
    }

    func testExplicitStudioTokenSelectsMonitorHistoryAndUsesReadCompletionTimestamp() async throws {
        let clock = UnslothSlotTestClock()
        let source = nativeSlotSample(at: clock.date())
        let backend = UnslothUnderlyingStub(
            detection: .init(kind: .llamaCpp, baseURL: worker), samples: [source])
        let monitor = UnslothTransportStub([
            "/api/inference/monitor": [
                .ok(
                    #"""
                    {"logging_enabled":true,"entries":[{"id":"studio-request","status":"completed",
                     "model":"studio-model","started_at":101,"finished_at":101.5,
                     "completion_tokens":90,"prompt_tokens":50,"prompt_preview":"discard me"}]}
                    """#)
            ]
        ])
        let client = UnslothBackendClient(
            normal: backend, discovery: UnslothDiscoveryStub([server()]),
            studioMonitorTransport: {
                clock.advance(2)
                return try await monitor.respond($0)
            }, wallClock: { clock.date() })
        let configuration = BackendConfiguration(
            kind: .unsloth, baseURL: studio, studioMonitorToken: "explicit-test-token")
        let sample = try await client.sample(configuration)
        XCTAssertEqual(sample.timestamp, Date(timeIntervalSince1970: 102))
        XCTAssertEqual(sample.currentTPS, source.currentTPS)
        XCTAssertEqual(sample.measurementDuration, source.measurementDuration)
        XCTAssertEqual(sample.outputTokens, source.outputTokens)
        XCTAssertEqual(sample.nativeRequests?.source, .studioMonitor)
        XCTAssertFalse(sample.nativeRequests?.isComplete == true)
        XCTAssertEqual(sample.nativeRequests?.requests.first?.id, "studio-request")
        let workerConfigurations = await backend.configurations
        XCTAssertNil(
            workerConfigurations.first?.studioMonitorToken, "Studio token never reaches the worker")
        let store = MetricsStore(clock: { clock.date() })
        let epoch = UUID()
        store.beginBackendSession(kind: .unsloth, epoch: epoch)
        store.applyBackendSample(sample, epoch: epoch)
        XCTAssertEqual(store.requestLanes.count, 1)
        XCTAssertEqual(store.requestLanes.first?.startedAt, Date(timeIntervalSince1970: 101))
        XCTAssertEqual(store.requestLanes.first?.endedAt, Date(timeIntervalSince1970: 101.5))
        XCTAssertNil(store.activeGeneration)
        let usage = store.usageSummary(
            in: DateInterval(
                start: Date(timeIntervalSince1970: 99), end: clock.date()))
        XCTAssertEqual(usage.requests, 0)
        XCTAssertEqual(usage.outputTokens, 0)
    }

    func testStudioMonitorIsNeverReadWithoutAnExplicitToken() async throws {
        let source = nativeSlotSample()
        let backend = UnslothUnderlyingStub(
            detection: .init(kind: .llamaCpp, baseURL: worker), samples: [source])
        let monitor = UnslothTransportStub([:])
        let client = UnslothBackendClient(
            normal: backend, discovery: UnslothDiscoveryStub([server()]),
            studioMonitorTransport: { try await monitor.respond($0) })
        let sample = try await client.sample(configuration())
        XCTAssertEqual(sample.nativeRequests?.source, .slotPolling)
        XCTAssertEqual(sample.nativeRequests?.sourceEpoch, source.nativeRequests?.sourceEpoch)
        let requests = await monitor.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testStudioFailuresAndDisabledLoggingKeepSlotObservationsWithGenericDetail() async throws {
        let responses: [BackendHTTPResponse] = [
            .init(statusCode: 401, data: Data("secret-server-error".utf8)),
            .init(statusCode: 404, data: Data()),
            .ok(#"{"logging_enabled":false,"entries":[]}"#),
            .ok("not JSON"),
        ]
        for response in responses {
            let source = nativeSlotSample()
            let backend = UnslothUnderlyingStub(
                detection: .init(kind: .llamaCpp, baseURL: worker), samples: [source])
            let monitor = UnslothTransportStub(["/api/inference/monitor": [response]])
            let client = UnslothBackendClient(
                normal: backend, discovery: UnslothDiscoveryStub([server()]),
                studioMonitorTransport: { try await monitor.respond($0) })
            let sample = try await client.sample(
                .init(
                    kind: .unsloth, baseURL: studio, studioMonitorToken: "explicit-test-token"))
            XCTAssertEqual(sample.nativeRequests?.source, .slotPolling)
            XCTAssertEqual(sample.nativeRequests?.sourceEpoch, source.nativeRequests?.sourceEpoch)
            XCTAssertEqual(sample.timestamp, source.timestamp)
            let detail = try XCTUnwrap(sample.detail)
            XCTAssertTrue(detail.contains("sampled worker monitoring"))
            XCTAssertFalse(detail.contains("explicit-test-token"))
            XCTAssertFalse(detail.contains("secret-server-error"))
        }
    }

    func testStudioMonitorEpochSeparatesCredentialsAndProcessBirthAndExplicitReset() async throws {
        let backend = UnslothUnderlyingStub(
            detection: .init(kind: .llamaCpp, baseURL: worker), samples: [nativeSlotSample()])
        let discovery = UnslothDiscoveryStub([server()])
        let response = BackendHTTPResponse.ok(
            #"{"logging_enabled":true,"entries":[{"id":"same-id","status":"running"}]}"#)
        let monitor = UnslothTransportStub([
            "/api/inference/monitor": Array(repeating: response, count: 5)
        ])
        let client = UnslothBackendClient(
            normal: backend, discovery: discovery,
            studioMonitorTransport: { try await monitor.respond($0) })
        let firstConfiguration = BackendConfiguration(
            kind: .unsloth, baseURL: studio, studioMonitorToken: "first-token")
        let first = try await client.sample(firstConfiguration)
        let repeated = try await client.sample(firstConfiguration)
        XCTAssertEqual(repeated.nativeRequests?.sourceEpoch, first.nativeRequests?.sourceEpoch)
        let changedToken = try await client.sample(
            .init(
                kind: .unsloth, baseURL: studio, studioMonitorToken: "second-token"))
        XCTAssertNotEqual(
            changedToken.nativeRequests?.sourceEpoch, first.nativeRequests?.sourceEpoch)
        await discovery.replace([
            .init(
                studioURL: studio, workerURL: worker,
                studioIdentity: .init(pid: 101, startTimeMicroseconds: 999),
                workerIdentity: .init(pid: 202, startTimeMicroseconds: 200))
        ])
        let restarted = try await client.sample(firstConfiguration)
        XCTAssertNotEqual(restarted.nativeRequests?.sourceEpoch, first.nativeRequests?.sourceEpoch)
        await client.reset()
        let reset = try await client.sample(firstConfiguration)
        XCTAssertNotEqual(reset.nativeRequests?.sourceEpoch, restarted.nativeRequests?.sourceEpoch)
    }

    func testResetDuringStudioMonitorReadRejectsLateHistory() async throws {
        let backend = UnslothUnderlyingStub(
            detection: .init(kind: .llamaCpp, baseURL: worker), samples: [nativeSlotSample()])
        let gate = UnslothSampleGate()
        let client = UnslothBackendClient(
            normal: backend, discovery: UnslothDiscoveryStub([server()]),
            studioMonitorTransport: { _ in
                await gate.hold()
                return .ok(#"{"logging_enabled":true,"entries":[]}"#)
            })
        let configuration = BackendConfiguration(
            kind: .unsloth, baseURL: studio, studioMonitorToken: "test-token")
        let pending = Task { try await client.sample(configuration) }
        await gate.waitUntilStarted()
        await client.reset()
        await gate.release()
        do {
            _ = try await pending.value
            XCTFail("A retired Studio read cannot publish native request history")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCredentialChangeRejectsInflightMonitorWithoutInvalidatingFreshWorker() async throws {
        let backend = UnslothUnderlyingStub(
            detection: .init(kind: .llamaCpp, baseURL: worker), samples: [nativeSlotSample()])
        let gate = UnslothSampleGate()
        let client = UnslothBackendClient(
            normal: backend, discovery: UnslothDiscoveryStub([server()]),
            studioMonitorTransport: { request in
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer first-token" {
                    await gate.hold()
                }
                return .ok(#"{"logging_enabled":true,"entries":[]}"#)
            })
        let firstConfiguration = BackendConfiguration(
            kind: .unsloth, baseURL: studio, studioMonitorToken: "first-token")
        let pending = Task { try await client.sample(firstConfiguration) }
        await gate.waitUntilStarted()
        let fresh = try await client.sample(
            .init(
                kind: .unsloth, baseURL: studio, studioMonitorToken: "second-token"))
        XCTAssertEqual(fresh.nativeRequests?.source, .studioMonitor)
        await gate.release()
        do {
            _ = try await pending.value
            XCTFail("History from the previous credentials cannot publish into the new scope")
        } catch { XCTAssertTrue(error is CancellationError) }
        let resets = await backend.resetCount
        XCTAssertEqual(resets, 0)
    }

    private func nativeSlotSample(at timestamp: Date = Date(timeIntervalSince1970: 100))
        -> BackendSample
    {
        .init(
            kind: .llamaCpp, timestamp: timestamp, model: "worker-model", currentTPS: 56,
            measurementDuration: 1,
            nativeRequests: .init(
                sourceEpoch: UUID(), source: .slotPolling,
                requests: [.init(id: "3:5893", model: "worker-model", outputTokens: 81)]),
            runningRequests: 1, outputTokens: 1000)
    }

    func testDetectAtVerifiedStudioReturnsStableUnslothIdentity() async throws {
        let backend = UnslothUnderlyingStub(detection: .init(kind: .llamaCpp, baseURL: worker))
        let client = UnslothBackendClient(
            normal: backend, discovery: UnslothDiscoveryStub([server()]))
        let result = try await client.detect(at: studio)
        XCTAssertEqual(result?.kind, .unsloth)
        XCTAssertEqual(result?.baseURL, studio)
    }

    func testLocalhostConfigurationMatchesVerifiedIPv4StudioWithoutDNSOrFrontendRequests()
        async throws
    {
        let backend = UnslothUnderlyingStub(
            detection: .init(kind: .llamaCpp, baseURL: worker),
            samples: [.init(kind: .llamaCpp, model: "local-model", currentTPS: 12)])
        let client = UnslothBackendClient(
            normal: backend, discovery: UnslothDiscoveryStub([server()]))
        let configuredURL = URL(string: "http://localhost:8888")!
        let detected = try await client.detect(at: configuredURL)
        XCTAssertEqual(detected?.kind, .unsloth)
        XCTAssertEqual(detected?.baseURL, studio)
        let sample = try await client.sample(.init(kind: .unsloth, baseURL: configuredURL))
        XCTAssertEqual(sample.kind, .unsloth)
        XCTAssertEqual(sample.model, "local-model")
        XCTAssertEqual(sample.currentTPS, 12)
        let detects = await backend.detectedURLs
        let configurations = await backend.configurations
        XCTAssertEqual(detects, [worker])
        XCTAssertEqual(configurations.map(\.baseURL), [worker])
    }

    func testExplicitModelIsForwardedWithoutChangingStableFrontendConfiguration() async throws {
        let backend = UnslothUnderlyingStub(detection: .init(kind: .llamaCpp, baseURL: worker))
        let client = UnslothBackendClient(
            normal: backend, discovery: UnslothDiscoveryStub([server()]))
        _ = try await client.sample(configuration(model: "selected/model"))
        let configs = await backend.configurations
        XCTAssertEqual(
            configs,
            [.init(kind: .llamaCpp, baseURL: worker, model: "selected/model", proxyPort: 11223)])
    }

    func testPortAndModelRestartReverifiesWorkerAndClearsUnderlyingCache() async throws {
        let backend = UnslothUnderlyingStub(
            detection: .init(kind: .llamaCpp, baseURL: worker),
            samples: [.init(kind: .llamaCpp, model: "first")])
        let discovery = UnslothDiscoveryStub([server()])
        let client = UnslothBackendClient(normal: backend, discovery: discovery)
        _ = try await client.sample(configuration())
        _ = try await client.sample(configuration())
        let nextWorker = URL(string: "http://127.0.0.1:54321")!
        await discovery.replace([server(workerURL: nextWorker, workerPID: 303)])
        await backend.replaceDetection(.init(kind: .llamaCpp, baseURL: nextWorker))
        await backend.replaceSamples([.init(kind: .llamaCpp, model: "second")])
        let updated = try await client.sample(configuration())
        XCTAssertEqual(updated.model, "second")
        let detects = await backend.detectedURLs
        let configs = await backend.configurations
        let resets = await backend.resetCount
        XCTAssertEqual(detects, [worker, nextWorker])
        XCTAssertEqual(configs.map(\.baseURL), [worker, worker, nextWorker])
        XCTAssertEqual(resets, 1)
    }

    func testSamePortPIDReuseClearsPreviouslyCachedModelAlias() async throws {
        let metrics = "llamacpp:requests_processing 0\nllamacpp:predicted_tokens_seconds 10"
        let transport = UnslothTransportStub([
            "/metrics": [.ok(metrics), .ok(metrics), .ok(metrics), .ok(metrics)],
            "/props": [.ok(#"{"model_alias":"first"}"#), .ok(#"{"model_alias":"second"}"#)],
        ])
        let discovery = UnslothDiscoveryStub([server()])
        let client = UnslothBackendClient(
            normal: HTTPBackendClient(transport: { try await transport.respond($0) }),
            discovery: discovery)
        let first = try await client.sample(configuration())
        XCTAssertEqual(first.model, "first")
        await discovery.replace([server(workerBirth: 999)])
        let second = try await client.sample(configuration())
        XCTAssertEqual(second.model, "second")
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/props" }.count, 2)
    }

    func testMissingMetricsDoesNotPretendTheWorkerIsReady() async throws {
        let backend = UnslothUnderlyingStub(
            detection: .init(
                kind: .llamaCpp, baseURL: worker, isReady: false, supportsLiveMetrics: false))
        let client = UnslothBackendClient(
            normal: backend, discovery: UnslothDiscoveryStub([server()]))
        let detected = await client.discoverLocalBackends()
        XCTAssertFalse(detected.first?.supportsLiveMetrics ?? true)
        await assertConfigurationError(client, containing: "metrics")
        let configs = await backend.configurations
        XCTAssertTrue(configs.isEmpty)
    }

    func testMissingOrUnrelatedWorkerIdentityCannotBecomeUnsloth() async throws {
        for detection in [nil, DetectedBackend(kind: .ollama, baseURL: worker)] {
            let backend = UnslothUnderlyingStub(detection: detection)
            let client = UnslothBackendClient(
                normal: backend, discovery: UnslothDiscoveryStub([server()]))
            let results = await client.discoverLocalBackends()
            XCTAssertFalse(results.first?.isReady ?? true)
            await assertConfigurationError(client, containing: "llama.cpp")
            let configs = await backend.configurations
            XCTAssertTrue(configs.isEmpty)
        }
    }

    func testAmbiguousWorkersProduceActionableSingleStudioEntry() async throws {
        let discovery = UnslothDiscoveryStub([
            server(), server(workerURL: URL(string: "http://127.0.0.1:54321")!, workerPID: 303),
        ])
        let backend = UnslothUnderlyingStub()
        let client = UnslothBackendClient(normal: backend, discovery: discovery)
        let results = await client.discoverLocalBackends()
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results.first?.isReady ?? true)
        await assertConfigurationError(client, containing: "multiple")
        let detects = await backend.detectedURLs
        XCTAssertTrue(detects.isEmpty)
    }

    func testStudioMissingAndUntrustedEndpointsFailBeforeWorkerRequests() async throws {
        let backend = UnslothUnderlyingStub()
        let discovery = UnslothDiscoveryStub([])
        let client = UnslothBackendClient(normal: backend, discovery: discovery)
        await assertConfigurationError(client, containing: "running")
        for address in [
            "http://server.example:8888", "http://127.0.0.2:8888", "http://127.0.0.1:8888/prefix",
            "http://user:secret@127.0.0.1:8888", "http://127.0.0.1:8888?token=secret",
            "http://127.0.0.1:8888#fragment", "file:///tmp/unsloth",
        ] {
            do {
                _ = try await client.sample(.init(kind: .unsloth, baseURL: URL(string: address)!))
                XCTFail("Unverified endpoints must be rejected: \(address)")
            } catch { XCTAssertTrue(error is BackendClientError) }
        }
        let detects = await backend.detectedURLs
        let configs = await backend.configurations
        XCTAssertTrue(detects.isEmpty)
        XCTAssertTrue(configs.isEmpty)
    }

    func testRemoteDiscoveredWorkerIsRejectedEvenWithVerifiedStudio() async throws {
        let backend = UnslothUnderlyingStub()
        let discovery = UnslothDiscoveryStub([
            server(workerURL: URL(string: "http://remote.example:8080")!)
        ])
        let client = UnslothBackendClient(normal: backend, discovery: discovery)
        await assertConfigurationError(client, containing: "local")
        let detects = await backend.detectedURLs
        XCTAssertTrue(detects.isEmpty)
    }

    func testAuthenticationAndTransientSamplingErrorsRemainExplicitAndReverifyOnRecovery()
        async throws
    {
        let backend = UnslothUnderlyingStub(detection: .init(kind: .llamaCpp, baseURL: worker))
        let client = UnslothBackendClient(
            normal: backend, discovery: UnslothDiscoveryStub([server()]))
        await backend.failSample(.httpStatus(401))
        do {
            _ = try await client.sample(configuration())
            XCTFail("Expected authentication error")
        } catch {
            guard case .configurationRequired(let message) = error as? BackendClientError else {
                return XCTFail("Expected worker authentication guidance, got \(error)")
            }
            XCTAssertTrue(message.contains("HTTP 401"))
            XCTAssertTrue(message.contains("worker API key in Settings"))
            XCTAssertTrue(message.contains("restarts"))
        }
        await backend.failSample(nil)
        _ = try await client.sample(configuration())
        let detects = await backend.detectedURLs
        let resets = await backend.resetCount
        XCTAssertEqual(detects, [worker, worker])
        XCTAssertEqual(resets, 1)
    }

    func testWorkerReplacementDuringARequestRejectsStaleModelAndMetrics() async throws {
        let gate = UnslothSampleGate()
        let backend = UnslothUnderlyingStub(
            detection: .init(kind: .llamaCpp, baseURL: worker), gate: gate)
        let discovery = UnslothDiscoveryStub([server()])
        let client = UnslothBackendClient(normal: backend, discovery: discovery)
        let task = Task { try await client.sample(configuration()) }
        await gate.waitUntilStarted()
        await discovery.replace([server(workerBirth: 999)])
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("A replaced worker must not publish its old sample")
        } catch {
            guard case .configurationRequired(let message) = error as? BackendClientError else {
                return XCTFail("Expected process-change guidance, got \(error)")
            }
            XCTAssertTrue(message.contains("changed"))
        }
    }

    func testResetAndCancellationRejectInflightResults() async throws {
        for reset in [true, false] {
            let gate = UnslothSampleGate()
            let backend = UnslothUnderlyingStub(
                detection: .init(kind: .llamaCpp, baseURL: worker), gate: gate)
            let discovery = UnslothDiscoveryStub([server()])
            let client: any BackendClientProtocol = UnslothBackendClient(
                normal: backend, discovery: discovery)
            let task = Task { try await client.sample(configuration()) }
            await gate.waitUntilStarted()
            if reset { await client.reset() } else { task.cancel() }
            await gate.release()
            do {
                _ = try await task.value
                XCTFail("Reset/cancelled sessions cannot publish late metrics")
            } catch { XCTAssertTrue(error is CancellationError) }
            if reset {
                let resets = await discovery.resetCount
                XCTAssertEqual(resets, 1)
            }
        }
    }

    private func configuration(model: String? = nil) -> BackendConfiguration {
        .init(kind: .unsloth, baseURL: studio, model: model, proxyPort: 11223)
    }

    private func server(
        workerURL: URL? = URL(string: "http://127.0.0.1:54234")!,
        workerPID: Int32? = 202, workerBirth: UInt64 = 200
    ) -> UnslothServer {
        .init(
            studioURL: studio, workerURL: workerURL,
            studioIdentity: .init(pid: 101, startTimeMicroseconds: 100),
            workerIdentity: workerPID.map { .init(pid: $0, startTimeMicroseconds: workerBirth) })
    }

    private func assertConfigurationError(
        _ client: UnslothBackendClient, containing fragment: String
    ) async {
        do {
            _ = try await client.sample(configuration())
            XCTFail("Expected configuration error containing \(fragment)")
        } catch {
            guard case .configurationRequired(let message) = error as? BackendClientError else {
                return XCTFail("Expected configuration guidance, got \(error)")
            }
            XCTAssertTrue(message.localizedCaseInsensitiveContains(fragment), message)
        }
    }
}

private actor UnslothDiscoveryStub: UnslothDiscovering {
    private var values: [UnslothServer]
    private(set) var calls = 0
    private(set) var resetCount = 0
    init(_ values: [UnslothServer]) { self.values = values }
    func servers() async -> [UnslothServer] {
        calls += 1
        return values
    }
    func reset() async { resetCount += 1 }
    func replace(_ values: [UnslothServer]) { self.values = values }
}

private actor UnslothUnderlyingStub: BackendClientProtocol {
    private var detection: DetectedBackend?
    private var samples: [BackendSample]
    private var sampleError: BackendClientError?
    private let gate: UnslothSampleGate?
    private(set) var detectedURLs: [URL] = []
    private(set) var configurations: [BackendConfiguration] = []
    private(set) var resetCount = 0
    init(
        detection: DetectedBackend? = nil, samples: [BackendSample] = [.init(kind: .llamaCpp)],
        gate: UnslothSampleGate? = nil
    ) {
        self.detection = detection
        self.samples = samples
        self.gate = gate
    }
    func detect(at baseURL: URL) async throws -> DetectedBackend? {
        detectedURLs.append(baseURL)
        return detection
    }
    func sample(_ configuration: BackendConfiguration) async throws -> BackendSample {
        configurations.append(configuration)
        if let gate { await gate.hold() }
        if let sampleError { throw sampleError }
        return samples.count > 1 ? samples.removeFirst() : samples[0]
    }
    func reset() async { resetCount += 1 }
    func replaceDetection(_ detection: DetectedBackend?) { self.detection = detection }
    func replaceSamples(_ samples: [BackendSample]) { self.samples = samples }
    func failSample(_ error: BackendClientError?) { sampleError = error }
}

private actor UnslothTransportStub {
    private var responses: [String: [BackendHTTPResponse]]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [String: [BackendHTTPResponse]]) { self.responses = responses }
    func respond(_ request: URLRequest) throws -> BackendHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        guard var queue = responses[path], !queue.isEmpty else {
            return .init(statusCode: 404, data: Data())
        }
        let response = queue.removeFirst()
        responses[path] = queue
        return response
    }
}

private actor UnslothSampleGate {
    private var started = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        started = true
        for observer in observers {
            observer.resume()
        }
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

private final class UnslothSlotTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100

    func now() -> TimeInterval { lock.withLock { time } }
    func date() -> Date { Date(timeIntervalSince1970: now()) }
    func advance(_ interval: TimeInterval) { lock.withLock { time += interval } }
}

extension BackendHTTPResponse {
    fileprivate static func ok(_ text: String) -> Self {
        .init(statusCode: 200, data: Data(text.utf8))
    }
}
