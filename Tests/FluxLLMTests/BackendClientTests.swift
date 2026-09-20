import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class BackendClientTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8000/prefix")!

    func testVLLMCounterDeltasAggregateEnginesAndModelsUsingMonotonicTime() async throws {
        let stub = BackendTransportStub([
            "/prefix/metrics": [.ok(BackendFixtures.vllmFirst), .ok(BackendFixtures.vllmSecond)]
        ])
        let clock = BackendTestClock()
        let client = makeClient(stub, clock: clock)
        let config = BackendConfiguration(kind: .vllm, baseURL: base)
        let first = try await client.sample(config)
        XCTAssertNil(first.currentTPS)
        XCTAssertNil(first.model)
        XCTAssertEqual(first.runningRequests, 4)
        XCTAssertEqual(first.queuedRequests, 2)
        XCTAssertEqual(first.outputTokens, 600)
        XCTAssertEqual(first.promptTokens, 90)
        clock.advance(2)
        let second = try await client.sample(config)
        XCTAssertEqual(second.currentTPS, 40)
        XCTAssertEqual(second.basis, .serverAggregate)
        XCTAssertNil(second.inferenceGPUPercent)
        let requests = await stub.requests
        XCTAssertEqual(
            requests.map { $0.url?.path },
            [
                "/prefix/metrics", "/prefix/health", "/prefix/metrics", "/prefix/health",
            ])
        XCTAssertTrue(
            requests.allSatisfy {
                $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == nil
            })
        XCTAssertEqual(
            requests.first?.value(forHTTPHeaderField: "Accept"), "text/plain; version=0.0.4")
    }

    func testVLLMModelFilterDoesNotIncludeOtherModelsOrHistogramBuckets() async throws {
        let stub = BackendTransportStub([
            "/prefix/metrics": [.ok(BackendFixtures.vllmFirst), .ok(BackendFixtures.vllmSecond)]
        ])
        let clock = BackendTestClock()
        let client = makeClient(stub, clock: clock)
        let config = BackendConfiguration(kind: .vllm, baseURL: base, model: "model-a")
        let first = try await client.sample(config)
        XCTAssertEqual(first.outputTokens, 300)
        XCTAssertEqual(first.runningRequests, 3)
        clock.advance(2)
        let second = try await client.sample(config)
        XCTAssertEqual(second.currentTPS, 30)
        XCTAssertEqual(second.model, "model-a")
    }

    func testVLLMResetSeriesChangesAndStaleIntervalsCreateGaps() async throws {
        let bodies = [100, 10, 30, 90, 120].map { value in
            BackendHTTPResponse.ok(
                "vllm:generation_tokens_total{model_name=\"m\"} \(value)\nvllm:num_requests_running 1"
            )
        }
        let stub = BackendTransportStub(["/prefix/metrics": bodies])
        let clock = BackendTestClock()
        let client = makeClient(stub, clock: clock)
        let config = BackendConfiguration(kind: .vllm, baseURL: base)
        _ = try await client.sample(config)
        clock.advance(1)
        let reset = try await client.sample(config)
        XCTAssertNil(reset.currentTPS)
        clock.advance(1)
        let fresh = try await client.sample(config)
        XCTAssertEqual(fresh.currentTPS, 20)
        clock.advance(30)
        let stale = try await client.sample(config)
        XCTAssertNil(stale.currentTPS)
        clock.advance(1)
        let recovered = try await client.sample(config)
        XCTAssertEqual(recovered.currentTPS, 30)
    }

    func testVLLMEngineMembershipChangesDoNotFabricateThroughput() async throws {
        let stub = BackendTransportStub([
            "/prefix/metrics": [
                .ok("vllm:generation_tokens_total{engine=\"0\"} 100"),
                .ok(
                    "vllm:generation_tokens_total{engine=\"0\"} 110\nvllm:generation_tokens_total{engine=\"1\"} 9999"
                ),
            ]
        ])
        let clock = BackendTestClock()
        let client = makeClient(stub, clock: clock)
        let config = BackendConfiguration(kind: .vllm, baseURL: base)
        _ = try await client.sample(config)
        clock.advance(1)
        let changed = try await client.sample(config)
        XCTAssertNil(changed.currentTPS)
    }

    func testVLLMProcessRestartAndExplicitResetInvalidateCounterHistory() async throws {
        let stub = BackendTransportStub([
            "/prefix/metrics": [
                .ok("vllm:generation_tokens_total 100\nprocess_start_time_seconds 123"),
                .ok("vllm:generation_tokens_total 200\nprocess_start_time_seconds 456"),
                .ok("vllm:generation_tokens_total 220\nprocess_start_time_seconds 456"),
            ]
        ])
        let clock = BackendTestClock()
        // The coordinator stores the client behind this protocol. Exercise its
        // async requirement, not a concrete actor overload that can lose to the default.
        let client: any BackendClientProtocol = makeClient(stub, clock: clock)
        let config = BackendConfiguration(kind: .vllm, baseURL: base)
        _ = try await client.sample(config)
        clock.advance(1)
        let restarted = try await client.sample(config)
        XCTAssertNil(restarted.currentTPS)
        await client.reset()
        clock.advance(1)
        let selectedAgain = try await client.sample(config)
        XCTAssertNil(selectedAgain.currentTPS)
    }

    func testVLLMCompletedBetweenPollsKeepsMeasuredIntervalThroughput() async throws {
        let stub = BackendTransportStub([
            "/prefix/metrics": [
                .ok("vllm:generation_tokens_total 100\nvllm:num_requests_running 0"),
                .ok("vllm:generation_tokens_total 160\nvllm:num_requests_running 0"),
            ]
        ])
        let clock = BackendTestClock()
        let client = makeClient(stub, clock: clock)
        let config = BackendConfiguration(kind: .vllm, baseURL: base)
        _ = try await client.sample(config)
        clock.advance(2)
        let finished = try await client.sample(config)
        XCTAssertEqual(finished.currentTPS, 30)
        XCTAssertEqual(finished.runningRequests, 0)
    }

    func testVLLMExposedMetricsDoNotOverrideUnreadyHealth() async throws {
        let stub = BackendTransportStub([
            "/prefix/metrics": [.ok(BackendFixtures.vllmFirst)],
            "/prefix/health": [.init(statusCode: 503, data: Data())],
        ])
        let sample = try await makeClient(stub).sample(.init(kind: .vllm, baseURL: base))
        XCTAssertFalse(sample.isReady)
        XCTAssertNil(sample.currentTPS)
    }

    func testHTTPFailureClearsVLLMBaselineAndMissingMetricsStayUnknown() async throws {
        let stub = BackendTransportStub([
            "/prefix/metrics": [
                .ok("vllm:generation_tokens_total 100"), .init(statusCode: 503, data: Data()),
                .ok("vllm:generation_tokens_total 200"), .ok("vllm:num_requests_running 0"),
            ]
        ])
        let clock = BackendTestClock()
        let client = makeClient(stub, clock: clock)
        let config = BackendConfiguration(kind: .vllm, baseURL: base)
        _ = try await client.sample(config)
        do {
            _ = try await client.sample(config)
            XCTFail("Expected server error")
        } catch { XCTAssertEqual(error as? BackendClientError, .httpStatus(503)) }
        clock.advance(1)
        let recovered = try await client.sample(config)
        XCTAssertNil(recovered.currentTPS)
        let missing = try await client.sample(config)
        XCTAssertNil(missing.currentTPS)
        XCTAssertNil(missing.outputTokens)
        XCTAssertEqual(missing.runningRequests, 0)
    }

    func testRapidAverageKeepsActivitySeparateAndMemoryIsNotGPUUsage() async throws {
        let stub = BackendTransportStub([
            "/prefix/v1/status": [.ok(BackendFixtures.rapidActive), .ok(BackendFixtures.rapidIdle)]
        ])
        let client = makeClient(stub)
        let config = BackendConfiguration(kind: .rapidMLX, baseURL: base)
        let active = try await client.sample(config)
        XCTAssertEqual(active.currentTPS, 75.5)
        XCTAssertEqual(active.basis, .serverReportedAverage)
        XCTAssertEqual(active.runningRequests, 2)
        XCTAssertEqual(active.queuedRequests, 1)
        XCTAssertEqual(active.outputTokens, 150)
        XCTAssertNil(active.inferenceGPUPercent)
        let idle = try await client.sample(config)
        XCTAssertEqual(idle.currentTPS, 75.5)
        XCTAssertEqual(idle.runningRequests, 0)
    }

    func testRapidUnloadedDoesNotActivateTheModel() async throws {
        let stub = BackendTransportStub([
            "/prefix/v1/status": [.ok(#"{"status":"not_loaded","model":null,"requests":[]}"#)]
        ])
        let sample = try await makeClient(stub).sample(.init(kind: .rapidMLX, baseURL: base))
        XCTAssertFalse(sample.isReady)
        XCTAssertNil(sample.currentTPS)
        let paths = await stub.requests.map { $0.url?.path }
        XCTAssertEqual(paths, ["/prefix/v1/status"])
    }

    func testMissingRapidThroughputRemainsUnknown() async throws {
        let stub = BackendTransportStub([
            "/prefix/v1/status": [
                .ok(
                    #"{"status":"generating","model":"test","uptime_s":10,"num_running":1,"total_completion_tokens":20,"requests":[]}"#
                )
            ]
        ])
        let sample = try await makeClient(stub).sample(.init(kind: .rapidMLX, baseURL: base))
        XCTAssertTrue(sample.isReady)
        XCTAssertEqual(sample.runningRequests, 1)
        XCTAssertNil(sample.currentTPS)
    }

    func testLlamaUsesReportedAverageNotBatchedCounterDeltas() async throws {
        let stub = BackendTransportStub([
            "/prefix/metrics": [.ok(BackendFixtures.llamaActive)],
            "/prefix/props": [.ok(BackendFixtures.llamaProps)],
        ])
        let sample = try await makeClient(stub).sample(.init(kind: .llamaCpp, baseURL: base))
        XCTAssertEqual(sample.currentTPS, 25.5)
        XCTAssertEqual(sample.basis, .serverReportedAverage)
        XCTAssertEqual(sample.model, "local-model")
        XCTAssertEqual(sample.runningRequests, 2)
        XCTAssertEqual(sample.outputTokens, 1000)
    }

    func testLlamaWithMetricsDisabledOffersConfiguration() async throws {
        let stub = BackendTransportStub([
            "/prefix/props": [.ok(BackendFixtures.llamaProps), .ok(BackendFixtures.llamaProps)]
        ])
        let client = makeClient(stub)
        let detected = try await client.detect(at: base)
        XCTAssertEqual(detected?.kind, .llamaCpp)
        XCTAssertFalse(detected?.supportsLiveMetrics ?? true)
        do {
            _ = try await client.sample(.init(kind: .llamaCpp, baseURL: base))
            XCTFail("Expected configuration guidance")
        } catch {
            XCTAssertEqual(
                error as? BackendClientError,
                .configurationRequired(
                    "Start llama.cpp with --metrics to enable monitoring."))
        }
    }

    func testLlamaRouterModelQueriesAreEncodedAndNeverAutoload() async throws {
        let stub = BackendTransportStub([
            "/prefix/metrics": [.ok(BackendFixtures.llamaActive)],
            "/prefix/props": [.ok(BackendFixtures.llamaProps)],
        ])
        let model = "org/model:Q4 & custom"
        _ = try await makeClient(stub).sample(.init(kind: .llamaCpp, baseURL: base, model: model))
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first(where: { $0.name == "model" })?.value, model)
            XCTAssertEqual(items?.first(where: { $0.name == "autoload" })?.value, "false")
        }
    }

    func testUnconfiguredLlamaRouterIsDetectedWithoutLoadingAModel() async throws {
        let router = BackendHTTPResponse.ok(
            #"{"data":[{"id":"m","path":"/models/m.gguf","status":{"value":"unloaded"}}]}"#)
        let stub = BackendTransportStub(["/prefix/models": [router, router]])
        let client = makeClient(stub)
        let detected = try await client.detect(at: base)
        XCTAssertEqual(detected?.kind, .llamaCpp)
        XCTAssertFalse(detected?.isReady ?? true)
        do {
            _ = try await client.sample(.init(kind: .llamaCpp, baseURL: base))
            XCTFail("Expected router model configuration")
        } catch {
            XCTAssertEqual(
                error as? BackendClientError,
                .configurationRequired(
                    "Select a loaded llama.cpp router model in Settings."))
        }
        let requests = await stub.requests
        for request in requests
        where ["/prefix/metrics", "/prefix/props"].contains(request.url!.path) {
            XCTAssertEqual(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "autoload" })?.value, "false")
        }
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testDetectionRequiresNativeOllamaVersionAndModelShape() async throws {
        let stub = BackendTransportStub([
            "/prefix/api/version": [.ok(#"{"version":"0.12.0"}"#)],
            "/prefix/api/tags": [.ok(#"{"models":[]}"#)],
        ])
        let detected = try await makeClient(stub).detect(at: base)
        XCTAssertEqual(detected?.kind, .ollama)
        XCTAssertEqual(detected?.version, "0.12.0")
        XCTAssertFalse(detected?.supportsLiveMetrics ?? true)
        let unrelated = BackendTransportStub(["/prefix/api/version": [.ok(#"{"version":"1"}"#)]])
        let unknown = try await makeClient(unrelated).detect(at: base)
        XCTAssertNil(unknown)
    }

    func testRapidIdentityTakesPrecedenceOverCompatibleVLLMMetrics() async throws {
        let stub = BackendTransportStub([
            "/prefix/metrics": [
                .ok("rapid_mlx_build_info{version=\"0.13\"} 1\nvllm:generation_tokens_total 4")
            ],
            "/prefix/v1/status": [.ok(BackendFixtures.rapidIdle)],
        ])
        let detected = try await makeClient(stub).detect(at: base)
        XCTAssertEqual(detected?.kind, .rapidMLX)
        XCTAssertEqual(detected?.version, "0.13")
        XCTAssertTrue(detected?.isReady ?? false)
    }

    func testOllamaReadinessDoesNotInventActivityFromLoadedModels() async throws {
        let stub = BackendTransportStub([
            "/prefix/api/version": [.ok(#"{"version":"0.12.0"}"#)],
            "/prefix/api/ps": [.ok(#"{"models":[{"model":"qwen3:8b"}]}"#)],
        ])
        let sample = try await makeClient(stub).sample(.init(kind: .ollama, baseURL: base))
        XCTAssertTrue(sample.isReady)
        XCTAssertEqual(sample.model, "qwen3:8b")
        XCTAssertNil(sample.runningRequests)
        XCTAssertNil(sample.currentTPS)
    }

    func testCredentialsAndUnsupportedURLsAreRejectedBeforeTransport() async throws {
        let stub = BackendTransportStub([:])
        for address in [
            "http://user:secret@127.0.0.1:8000", "file:///tmp/metrics",
            "http://localhost:8000?token=secret",
        ] {
            do {
                _ = try await makeClient(stub).detect(at: URL(string: address)!)
                XCTFail("Expected invalid endpoint")
            } catch { XCTAssertEqual(error as? BackendClientError, .invalidEndpoint) }
        }
        let requests = await stub.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testResponseLimitAndHTTPAuthenticationErrorsAreExplicit() async throws {
        let stub = BackendTransportStub([
            "/prefix/metrics": [
                .init(
                    statusCode: 200,
                    data: Data(repeating: 32, count: HTTPBackendClient.maximumResponseBytes + 1)),
                .init(statusCode: 401, data: Data()),
            ]
        ])
        let client = makeClient(stub)
        let config = BackendConfiguration(kind: .vllm, baseURL: base)
        do {
            _ = try await client.sample(config)
            XCTFail("Expected size limit")
        } catch { XCTAssertEqual(error as? BackendClientError, .responseTooLarge) }
        do {
            _ = try await client.sample(config)
            XCTFail("Expected authentication error")
        } catch { XCTAssertEqual(error as? BackendClientError, .httpStatus(401)) }
    }

    private func makeClient(
        _ stub: BackendTransportStub, clock: BackendTestClock = BackendTestClock()
    ) -> HTTPBackendClient {
        HTTPBackendClient(transport: { try await stub.respond($0) }, monotonicTime: { clock.now() })
    }
}

private actor BackendTransportStub {
    var requests: [URLRequest] = []
    private var responses: [String: [BackendHTTPResponse]]

    init(_ responses: [String: [BackendHTTPResponse]]) { self.responses = responses }

    func respond(_ request: URLRequest) throws -> BackendHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        guard var queue = responses[path], !queue.isEmpty else {
            return BackendHTTPResponse(statusCode: 404, data: Data())
        }
        let response = queue.removeFirst()
        responses[path] = queue
        return response
    }
}

private final class BackendTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ amount: TimeInterval) { lock.withLock { time += amount } }
}

extension BackendHTTPResponse {
    fileprivate static func ok(_ text: String) -> BackendHTTPResponse {
        BackendHTTPResponse(statusCode: 200, data: Data(text.utf8))
    }
}
