import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class LlamaSlotThroughputTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8000/prefix")!

    func testGrowingLiveCountsOverrideZeroGaugeWithoutPublishingCumulativeWarmup() async throws {
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": [metrics(), metrics()],
            "/prefix/props": [props()],
            "/prefix/slots": [slots([(3, 5893, 81)]), slots([(3, 5893, 137)])],
        ])
        let clock = LlamaSlotTestClock()
        let client = makeClient(fixture, clock: clock)
        let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)

        let warmup = try await client.sample(configuration)
        XCTAssertNil(warmup.currentTPS)
        XCTAssertEqual(warmup.basis, .serverAggregate)
        XCTAssertEqual(warmup.throughputState, .warmingUp)
        XCTAssertNil(warmup.measurementDuration)
        XCTAssertEqual(warmup.model, "local-model")
        let baselineRequests = try XCTUnwrap(warmup.nativeRequests)
        XCTAssertEqual(baselineRequests.source, .slotPolling)
        XCTAssertTrue(baselineRequests.isComplete)
        XCTAssertEqual(baselineRequests.requests.map(\.id), ["3:5893"])
        XCTAssertEqual(baselineRequests.requests.first?.outputTokens, 81)
        XCTAssertEqual(baselineRequests.requests.first?.model, "local-model")
        XCTAssertNil(baselineRequests.requests.first?.liveTPS)
        XCTAssertNil(baselineRequests.requests.first?.startedAt)
        clock.advance(1)
        let live = try await client.sample(configuration)
        XCTAssertEqual(live.currentTPS, 56)
        XCTAssertEqual(live.basis, .serverAggregate)
        XCTAssertEqual(live.throughputState, .measured)
        XCTAssertEqual(live.measurementDuration, 1)
        XCTAssertEqual(live.runningRequests, 1)
        XCTAssertEqual(live.queuedRequests, 2)
        XCTAssertEqual(live.outputTokens, 1000, "Slots do not replace server usage totals")
        XCTAssertEqual(live.promptTokens, 2000)
        XCTAssertEqual(live.nativeRequests?.sourceEpoch, baselineRequests.sourceEpoch)
        XCTAssertEqual(live.nativeRequests?.requests.first?.outputTokens, 137)
        XCTAssertEqual(live.nativeRequests?.requests.first?.liveTPS, 56)
        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/prefix/props" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.path == "/prefix/slots" }.count, 2)
    }

    func testConcurrentRequestsAggregateAndTurnoverNeverAddsNewCumulativeCounts() throws {
        var throughput = LlamaSlotThroughput()
        XCTAssertNil(try rate(&throughput, [(0, 10, 100), (1, 20, 200)], at: 100))
        XCTAssertEqual(try rate(&throughput, [(0, 10, 140), (1, 20, 260)], at: 101), 100)
        XCTAssertEqual(
            try rate(&throughput, [(0, 10, 160), (1, 21, 100_000), (2, 30, 50_000)], at: 102),
            20, "Unchanged requests remain measurable when new requests join")
        XCTAssertEqual(
            try rate(&throughput, [(1, 21, 100_060), (2, 30, 50_020)], at: 103), 80,
            "A disappearing request contributes no fabricated completion count")
        XCTAssertNil(try rate(&throughput, [(0, 40, 99_999)], at: 104))
        XCTAssertEqual(try rate(&throughput, [(0, 40, 100_009)], at: 105), 10)
        XCTAssertNil(
            try rate(&throughput, [(3, 40, 100_019)], at: 106),
            "The same task ID in a different slot is a different request")
    }

    func testPromptProcessingZeroCountsRemainZeroUntilGenerationBegins() throws {
        var throughput = LlamaSlotThroughput()
        XCTAssertNil(try rate(&throughput, [(0, 1, 0)], at: 100))
        XCTAssertEqual(try rate(&throughput, [(0, 1, 0)], at: 101), 0)
        XCTAssertEqual(try rate(&throughput, [(0, 1, 56)], at: 102), 56)
    }

    func testCounterResetDoesNotSuppressUnchangedConcurrentRequest() throws {
        var throughput = LlamaSlotThroughput()
        _ = try throughput.sample(
            slots([(0, 1, 100), (1, 2, 200)]).data, at: 100, processStart: nil)
        let partial = try throughput.sample(
            slots([(0, 1, 10), (1, 2, 225)]).data, at: 101, processStart: nil)
        XCTAssertEqual(partial.activeRequests, 2)
        XCTAssertEqual(partial.currentTPS, 25)
        XCTAssertEqual(partial.state, .measured)
        XCTAssertEqual(partial.measurementDuration, 1)
        XCTAssertNil(partial.requests.first { $0.id == "0:1" }?.liveTPS)
        XCTAssertEqual(partial.requests.first { $0.id == "1:2" }?.liveTPS, 25)
        let recovered = try throughput.sample(
            slots([(0, 1, 15), (1, 2, 230)]).data, at: 102, processStart: nil)
        XCTAssertEqual(recovered.currentTPS, 10)
        XCTAssertEqual(recovered.state, .measured)
    }

    func testMeasurementStatesAndDurationsDistinguishWarmupFromInvalidTiming() throws {
        var throughput = LlamaSlotThroughput()
        let baseline = try throughput.sample(
            slots([(0, 1, 100)]).data, at: 100, processStart: nil)
        XCTAssertEqual(baseline.activeRequests, 1)
        XCTAssertNil(baseline.currentTPS)
        XCTAssertEqual(baseline.state, .warmingUp)
        XCTAssertNil(baseline.measurementDuration)
        let measured = try throughput.sample(
            slots([(0, 1, 150)]).data, at: 102, processStart: nil)
        XCTAssertEqual(measured.currentTPS, 25)
        XCTAssertEqual(measured.state, .measured)
        XCTAssertEqual(measured.measurementDuration, 2)
        let stale = try throughput.sample(
            slots([(0, 1, 500)]).data, at: 108, processStart: nil)
        XCTAssertNil(stale.currentTPS)
        XCTAssertEqual(stale.state, .warmingUp)
        XCTAssertNil(stale.measurementDuration)
        for time in [108.0, 107.0, .infinity, .nan] {
            let invalid = try throughput.sample(
                slots([(0, 1, 600)]).data, at: time, processStart: nil)
            XCTAssertNil(invalid.currentTPS)
            XCTAssertEqual(invalid.state, .unavailable)
            XCTAssertNil(invalid.measurementDuration)
        }
        let recovered = try throughput.sample(
            slots([(0, 1, 10_000)]).data, at: 109, processStart: nil)
        XCTAssertNil(recovered.currentTPS)
        XCTAssertEqual(recovered.state, .warmingUp)
        let fresh = try throughput.sample(
            slots([(0, 1, 10_010)]).data, at: 109.5, processStart: nil)
        XCTAssertEqual(fresh.currentTPS, 20)
        XCTAssertEqual(fresh.state, .measured)
        XCTAssertEqual(fresh.measurementDuration, 0.5)
        let reset = try throughput.sample(
            slots([(0, 1, 0)]).data, at: 110.5, processStart: nil)
        XCTAssertNil(reset.currentTPS)
        XCTAssertEqual(reset.state, .warmingUp)
        let replaced = try throughput.sample(
            slots([(0, 2, 50_000)]).data, at: 111.5, processStart: nil)
        XCTAssertNil(replaced.currentTPS)
        XCTAssertEqual(replaced.state, .warmingUp)
        let restarted = try throughput.sample(
            slots([(0, 2, 60_000)]).data, at: 112.5, processStart: 123)
        XCTAssertNil(restarted.currentTPS)
        XCTAssertEqual(restarted.state, .warmingUp)
    }

    func testSuccessfulIdleSlotsReplaceEarlierActiveMetricsAndClearHistory() async throws {
        let idleSnapshots: [BackendHTTPResponse] = [
            .json("[]"),
            .json(#"[{"id":0,"is_processing":false,"id_task":-1}]"#),
        ]
        for idleSnapshot in idleSnapshots {
            let fixture = LlamaSlotTransportStub([
                "/prefix/metrics": Array(repeating: metrics(gauge: 25), count: 3),
                "/prefix/props": [props()],
                "/prefix/slots": [
                    slots([(0, 1, 100)]), idleSnapshot, slots([(0, 2, 10_000)]),
                ],
            ])
            let clock = LlamaSlotTestClock()
            let client = makeClient(fixture, clock: clock)
            let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)
            _ = try await client.sample(configuration)
            clock.advance(1)
            let idle = try await client.sample(configuration)
            XCTAssertEqual(idle.runningRequests, 0, "The newer slots snapshot establishes idle")
            XCTAssertEqual(idle.currentTPS, 0)
            XCTAssertEqual(idle.basis, .serverAggregate)
            XCTAssertEqual(idle.throughputState, .measured)
            XCTAssertNil(idle.measurementDuration)
            XCTAssertEqual(idle.nativeRequests?.requests.count, 0)
            XCTAssertEqual(idle.nativeRequests?.source, .slotPolling)
            XCTAssertEqual(idle.outputTokens, 1000)
            clock.advance(1)
            let next = try await client.sample(configuration)
            XCTAssertEqual(next.runningRequests, 1)
            XCTAssertNil(next.currentTPS)
            XCTAssertEqual(next.throughputState, .warmingUp)
            let requests = await fixture.requests
            XCTAssertEqual(requests.filter { $0.url?.path == "/prefix/slots" }.count, 3)
        }
    }

    func testNewerSlotsSnapshotUpdatesConcurrentActivityAndIntervalDuration() async throws {
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": [metrics(), metrics()],
            "/prefix/props": [props()],
            "/prefix/slots": [
                slots([(0, 1, 100), (1, 2, 200)]), slots([(0, 1, 110), (1, 2, 220)]),
            ],
        ])
        let clock = LlamaSlotTestClock()
        let client = makeClient(fixture, clock: clock)
        let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)
        let baseline = try await client.sample(configuration)
        XCTAssertEqual(baseline.runningRequests, 2)
        XCTAssertEqual(baseline.throughputState, .warmingUp)
        clock.advance(0.5)
        let measured = try await client.sample(configuration)
        XCTAssertEqual(measured.runningRequests, 2)
        XCTAssertEqual(measured.currentTPS, 60)
        XCTAssertEqual(measured.throughputState, .measured)
        XCTAssertEqual(measured.measurementDuration, 0.5)
    }

    func testInvalidMonotonicTimingRemainsUnavailableDespiteHealthySlots() async throws {
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": [metrics(gauge: 25), metrics(gauge: 25)],
            "/prefix/props": [props()],
            "/prefix/slots": [slots([(0, 1, 100)]), slots([(0, 1, 200)])],
        ])
        let client = makeClient(fixture)
        let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)
        _ = try await client.sample(configuration)
        let invalid = try await client.sample(configuration)
        XCTAssertNil(invalid.currentTPS)
        XCTAssertEqual(invalid.throughputState, .unavailable)
        XCTAssertNil(invalid.measurementDuration)
        XCTAssertEqual(invalid.basis, .serverAggregate)
        XCTAssertEqual(invalid.runningRequests, 1)
    }

    func testIdlePollingSkipsSlotsAndNextRequestWarmsUp() async throws {
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": [
                metrics(gauge: 25), metrics(running: 0, gauge: 25),
                metrics(gauge: 25), metrics(gauge: 25),
            ],
            "/prefix/props": [props()],
            "/prefix/slots": [
                slots([(0, 1, 100)]), slots([(0, 2, 10_000)]), slots([(0, 2, 10_050)]),
            ],
        ])
        let clock = LlamaSlotTestClock()
        let client = makeClient(fixture, clock: clock)
        let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)
        _ = try await client.sample(configuration)
        clock.advance(1)
        let idle = try await client.sample(configuration)
        XCTAssertEqual(idle.runningRequests, 0)
        XCTAssertEqual(idle.currentTPS, 25, "The existing idle gauge remains a reported average")
        XCTAssertEqual(idle.basis, .serverReportedAverage)
        XCTAssertEqual(idle.nativeRequests?.requests.count, 0)
        XCTAssertTrue(idle.nativeRequests?.isComplete == true)
        clock.advance(1)
        let next = try await client.sample(configuration)
        XCTAssertNil(next.currentTPS)
        XCTAssertEqual(next.basis, .serverAggregate)
        XCTAssertEqual(next.throughputState, .warmingUp)
        XCTAssertNil(next.measurementDuration)
        clock.advance(1)
        let live = try await client.sample(configuration)
        XCTAssertEqual(live.currentTPS, 50)
        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/prefix/slots" }.count, 3)
        XCTAssertEqual(requests.filter { $0.url?.path == "/prefix/props" }.count, 1)
    }

    func testSlotCapabilityMustBeExplicitBooleanAndCachesEvenWithoutModelAlias() async throws {
        for capability in [nil, "false", "1", "0", "\"true\"", "null"] as [String?] {
            let fixture = LlamaSlotTransportStub([
                "/prefix/metrics": [metrics(gauge: 25), metrics(gauge: 25)],
                "/prefix/props": [props(capability: capability, model: nil)],
            ])
            let client = makeClient(fixture)
            let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)
            for _ in 0..<2 {
                let sample = try await client.sample(configuration)
                XCTAssertEqual(sample.currentTPS, 25, "Capability: \(capability ?? "missing")")
                XCTAssertEqual(sample.basis, .serverReportedAverage)
                XCTAssertEqual(sample.throughputState, .measured)
                XCTAssertNil(sample.measurementDuration)
                XCTAssertNil(sample.nativeRequests)
            }
            let requests = await fixture.requests
            XCTAssertEqual(requests.filter { $0.url?.path == "/prefix/props" }.count, 1)
            XCTAssertFalse(requests.contains { $0.url?.path == "/prefix/slots" })
        }
    }

    func testUnknownActivityDoesNotPollSlots() async throws {
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": [.json("llamacpp:predicted_tokens_seconds 25")],
            "/prefix/props": [props()],
        ])
        let sample = try await makeClient(fixture).sample(.init(kind: .llamaCpp, baseURL: base))
        XCTAssertNil(sample.runningRequests)
        XCTAssertNil(sample.currentTPS)
        XCTAssertEqual(sample.throughputState, .unavailable)
        XCTAssertNil(sample.measurementDuration)
        XCTAssertNil(sample.nativeRequests)
        let requests = await fixture.requests
        XCTAssertFalse(requests.contains { $0.url?.path == "/prefix/slots" })
    }

    func testOptionalSlotFailuresFallBackAndNeverBridgeAnOutage() async throws {
        let failures: [BackendHTTPResponse] = [
            .init(statusCode: 503, data: Data()),
            .json("not JSON"),
            .json(
                #"[{"id":0,"is_processing":true,"id_task":1,"next_token":[{"n_decoded":true}]}]"#),
            .init(
                statusCode: 200,
                data: Data(repeating: 32, count: HTTPBackendClient.maximumResponseBytes + 1)),
        ]
        for failure in failures {
            let fixture = LlamaSlotTransportStub([
                "/prefix/metrics": Array(repeating: metrics(gauge: 25), count: 4),
                "/prefix/props": [props()],
                "/prefix/slots": [
                    slots([(0, 1, 100)]), failure,
                    slots([(0, 1, 10_000)]), slots([(0, 1, 10_040)]),
                ],
            ])
            let clock = LlamaSlotTestClock()
            let client = makeClient(fixture, clock: clock)
            let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)
            _ = try await client.sample(configuration)
            clock.advance(1)
            let fallback = try await client.sample(configuration)
            XCTAssertEqual(fallback.currentTPS, 25)
            XCTAssertEqual(fallback.basis, .serverReportedAverage)
            XCTAssertEqual(fallback.throughputState, .measured)
            XCTAssertNil(fallback.measurementDuration)
            XCTAssertNil(fallback.nativeRequests)
            clock.advance(1)
            let warmup = try await client.sample(configuration)
            XCTAssertNil(warmup.currentTPS)
            XCTAssertEqual(warmup.basis, .serverAggregate)
            XCTAssertEqual(warmup.throughputState, .warmingUp)
            XCTAssertNil(warmup.measurementDuration)
            clock.advance(1)
            let recovered = try await client.sample(configuration)
            XCTAssertEqual(recovered.currentTPS, 40)
        }
    }

    func testMalformedSlotsWithoutReportedGaugeRemainUnavailableThenWarmUp() async throws {
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": [
                .json("llamacpp:requests_processing 1"), metrics(), metrics(),
            ],
            "/prefix/props": [props()],
            "/prefix/slots": [
                .json("not JSON"), slots([(0, 1, 10_000)]), slots([(0, 1, 10_040)]),
            ],
        ])
        let clock = LlamaSlotTestClock()
        let client = makeClient(fixture, clock: clock)
        let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)
        let unavailable = try await client.sample(configuration)
        XCTAssertNil(unavailable.currentTPS)
        XCTAssertEqual(unavailable.throughputState, .unavailable)
        XCTAssertNil(unavailable.measurementDuration)
        clock.advance(1)
        let warmup = try await client.sample(configuration)
        XCTAssertNil(warmup.currentTPS)
        XCTAssertEqual(warmup.throughputState, .warmingUp)
        XCTAssertNil(warmup.measurementDuration)
        clock.advance(1)
        let recovered = try await client.sample(configuration)
        XCTAssertEqual(recovered.currentTPS, 40)
        XCTAssertEqual(recovered.throughputState, .measured)
        XCTAssertEqual(recovered.measurementDuration, 1)
    }

    func testSlotRequestSourceEpochSurvivesIdleAndRotatesOnProcessRestartAndReset() async throws {
        let metricBodies = [(1, 10), (0, 10), (1, 10), (1, 20), (1, 20)].map { running, start in
            BackendHTTPResponse.json(
                "llamacpp:requests_processing \(running)\nprocess_start_time_seconds \(start)")
        }
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": metricBodies,
            "/prefix/props": [props(), props()],
            "/prefix/slots": [100, 10_000, 20_000, 30_000].map { slots([(0, 1, $0)]) },
        ])
        let clock = LlamaSlotTestClock()
        let client = makeClient(fixture, clock: clock)
        let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)
        let first = try await client.sample(configuration)
        let source = try XCTUnwrap(first.nativeRequests?.sourceEpoch)
        for _ in 0..<2 {
            clock.advance(1)
            let sample = try await client.sample(configuration)
            XCTAssertEqual(sample.nativeRequests?.sourceEpoch, source)
        }
        clock.advance(1)
        let restarted = try await client.sample(configuration)
        XCTAssertNotEqual(restarted.nativeRequests?.sourceEpoch, source)
        XCTAssertEqual(restarted.nativeRequests?.requests.first?.id, "0:1")
        XCTAssertNil(restarted.nativeRequests?.requests.first?.liveTPS)
        await client.reset()
        clock.advance(1)
        let reset = try await client.sample(configuration)
        XCTAssertNotEqual(reset.nativeRequests?.sourceEpoch, restarted.nativeRequests?.sourceEpoch)
    }

    func testFailedMetricsPollClearsSlotBaseline() async throws {
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": [
                metrics(), .init(statusCode: 503, data: Data()), metrics(), metrics(),
            ],
            "/prefix/props": [props(), props()],
            "/prefix/slots": [
                slots([(0, 1, 100)]), slots([(0, 1, 10_000)]), slots([(0, 1, 10_030)]),
            ],
        ])
        let clock = LlamaSlotTestClock()
        let client = makeClient(fixture, clock: clock)
        let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)
        _ = try await client.sample(configuration)
        do {
            _ = try await client.sample(configuration)
            XCTFail("Expected a metrics outage")
        } catch { XCTAssertEqual(error as? BackendClientError, .httpStatus(503)) }
        clock.advance(1)
        let warmup = try await client.sample(configuration)
        XCTAssertNil(warmup.currentTPS)
        XCTAssertEqual(warmup.throughputState, .warmingUp)
        XCTAssertNil(warmup.measurementDuration)
        clock.advance(1)
        let recovered = try await client.sample(configuration)
        XCTAssertEqual(recovered.currentTPS, 30)
    }

    func testCounterResetsStaleAndNonpositiveIntervalsCreateFreshBaselines() throws {
        var throughput = LlamaSlotThroughput()
        XCTAssertNil(try rate(&throughput, [(0, 1, 100)], at: 100))
        XCTAssertNil(try rate(&throughput, [(0, 1, 10)], at: 101))
        XCTAssertEqual(try rate(&throughput, [(0, 1, 30)], at: 102), 20)
        XCTAssertNil(try rate(&throughput, [(0, 1, 90)], at: 108))
        XCTAssertEqual(try rate(&throughput, [(0, 1, 120)], at: 109), 30)
        XCTAssertNil(try rate(&throughput, [(0, 1, 150)], at: 109))
        XCTAssertEqual(try rate(&throughput, [(0, 1, 160)], at: 110), 10)
        XCTAssertNil(try rate(&throughput, [(0, 1, 180)], at: 109))
        XCTAssertEqual(try rate(&throughput, [(0, 1, 190)], at: 110), 10)
        XCTAssertNil(try rate(&throughput, [(0, 1, 200)], at: .infinity))
        XCTAssertNil(try rate(&throughput, [(0, 1, 10_000)], at: 111))
        XCTAssertEqual(try rate(&throughput, [(0, 1, 10_050)], at: 116), 10)
    }

    func testProcessRestartAndEmptyOrIdleSlotSnapshotsDropHistory() throws {
        var throughput = LlamaSlotThroughput()
        XCTAssertNil(try rate(&throughput, [(0, 1, 100)], at: 100, processStart: 1))
        XCTAssertNil(try rate(&throughput, [(0, 1, 1000)], at: 101, processStart: 2))
        XCTAssertEqual(try rate(&throughput, [(0, 1, 1010)], at: 102, processStart: 2), 10)
        XCTAssertEqual(try rate(&throughput, [], at: 103, processStart: 2), 0)
        XCTAssertNil(try rate(&throughput, [(0, 1, 10_000)], at: 104, processStart: 2))
        let idle = Data(
            #"""
            [{"id":0,"is_processing":false,"id_task":-1,
            "next_token":[{"n_decoded":"retained"}]}]
            """#.utf8)
        let idleMeasurement = try throughput.sample(idle, at: 105, processStart: 2)
        XCTAssertEqual(idleMeasurement.activeRequests, 0)
        XCTAssertEqual(idleMeasurement.currentTPS, 0)
        XCTAssertEqual(idleMeasurement.state, .measured)
        XCTAssertNil(idleMeasurement.measurementDuration)
        XCTAssertNil(try rate(&throughput, [(0, 1, 20_000)], at: 106, processStart: 2))
    }

    func testInvalidActiveSlotFieldsRejectSnapshotAndDropHistory() throws {
        var malformed: [String] = [
            "{}", "[null]", "[{}]",
            #"[{"is_processing":true,"id_task":1,"next_token":[{"n_decoded":10}]}]"#,
            #"[{"id":0,"id_task":1,"next_token":[{"n_decoded":10}]}]"#,
            #"[{"id":0,"is_processing":1,"id_task":1,"next_token":[{"n_decoded":10}]}]"#,
            #"[{"id":0,"is_processing":true,"next_token":[{"n_decoded":10}]}]"#,
            #"[{"id":0,"is_processing":true,"id_task":1}]"#,
            #"[{"id":0,"is_processing":true,"id_task":1,"next_token":[]}]"#,
            #"[{"id":0,"is_processing":true,"id_task":1,"next_token":[{}]}]"#,
            #"[{"id":0,"is_processing":true,"id_task":1,"next_token":{"n_decoded":10}}]"#,
            #"[{"id":0,"is_processing":true,"id_task":1,"next_token":[{"n_decoded":10},{"n_decoded":20}]}]"#,
            #"[{"id":0,"is_processing":false},{"id":0,"is_processing":false}]"#,
        ]
        for value in ["true", "-1", "1.5", "\"10\"", "null", "1e400", "9223372036854775808"] {
            malformed.append(
                "[{\"id\":\(value),\"is_processing\":true,\"id_task\":1,"
                    + "\"next_token\":[{\"n_decoded\":10}]}]")
            malformed.append(
                "[{\"id\":0,\"is_processing\":true,\"id_task\":\(value),"
                    + "\"next_token\":[{\"n_decoded\":10}]}]")
            malformed.append(
                "[{\"id\":0,\"is_processing\":true,\"id_task\":1,"
                    + "\"next_token\":[{\"n_decoded\":\(value)}]}]")
        }
        for body in malformed {
            var throughput = LlamaSlotThroughput()
            _ = try rate(&throughput, [(0, 1, 100)], at: 100)
            XCTAssertThrowsError(
                try throughput.sample(Data(body.utf8), at: 101, processStart: nil), body)
            XCTAssertNil(try rate(&throughput, [(0, 1, 10_000)], at: 102), body)
            XCTAssertEqual(try rate(&throughput, [(0, 1, 10_010)], at: 103), 10, body)
        }
    }

    func testLargeNumericRequestIdentitiesRemainDistinctWithoutDoubleRounding() throws {
        var throughput = LlamaSlotThroughput()
        let firstTask = Int.max - 1
        XCTAssertNil(try rate(&throughput, [(Int.max, firstTask, 100)], at: 100))
        XCTAssertNil(try rate(&throughput, [(Int.max, Int.max, 10_000)], at: 101))
        XCTAssertEqual(try rate(&throughput, [(Int.max, Int.max, 10_010)], at: 102), 10)
    }

    func testRouterSlotsGetUsesConfiguredModelAndNeverAutoloads() async throws {
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": [metrics(), metrics()],
            "/prefix/props": [props()],
            "/prefix/slots": [slots([(0, 1, 0)]), slots([(0, 1, 10)])],
        ])
        let clock = LlamaSlotTestClock()
        let client = makeClient(fixture, clock: clock)
        let model = "org/model:Q4 & custom"
        let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base, model: model)
        _ = try await client.sample(configuration)
        clock.advance(1)
        let sample = try await client.sample(configuration)
        XCTAssertEqual(sample.currentTPS, 10)
        XCTAssertEqual(sample.model, model)
        let requests = await fixture.requests
        XCTAssertEqual(
            requests.map { $0.url?.path },
            [
                "/prefix/metrics", "/prefix/props", "/prefix/slots", "/prefix/metrics",
                "/prefix/slots",
            ])
        for request in requests {
            let url = try XCTUnwrap(request.url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first { $0.name == "autoload" }?.value, "false")
            XCTAssertEqual(items?.first { $0.name == "model" }?.value, model)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.timeoutInterval, 1.5)
            if url.path == "/prefix/slots" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            }
        }
    }

    func testExplicitResetRejectsInFlightSnapshotWithoutClearingNewSessionHistory() async throws {
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": [metrics(), metrics(), metrics()],
            "/prefix/props": [props(), props()],
            "/prefix/slots": [
                slots([(0, 1, 100)]), slots([(0, 1, 10_000)]), slots([(0, 1, 10_056)]),
            ],
        ])
        let gate = LlamaSlotResponseGate()
        await fixture.suspendNextSlots(with: gate)
        let clock = LlamaSlotTestClock()
        let client: any BackendClientProtocol = makeClient(fixture, clock: clock)
        let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)
        let pending = Task { try await client.sample(configuration) }
        await gate.waitUntilPaused()
        await client.reset()
        let warmup = try await client.sample(configuration)
        XCTAssertNil(warmup.currentTPS)
        XCTAssertEqual(warmup.throughputState, .warmingUp)
        XCTAssertNil(warmup.measurementDuration)
        await gate.release()
        do {
            _ = try await pending.value
            XCTFail("The snapshot belongs to the client session before reset")
        } catch { XCTAssertTrue(error is CancellationError) }
        clock.advance(1)
        let fresh = try await client.sample(configuration)
        XCTAssertEqual(fresh.currentTPS, 56)
        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/prefix/props" }.count, 2)
    }

    func testCancellationDuringSlotPollIsNotConvertedToGaugeFallback() async throws {
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": [metrics(gauge: 25)],
            "/prefix/props": [props()],
            "/prefix/slots": [slots([(0, 1, 100)])],
        ])
        let gate = LlamaSlotResponseGate()
        await fixture.suspendNextSlots(with: gate)
        let client = makeClient(fixture)
        let configuration = BackendConfiguration(kind: .llamaCpp, baseURL: base)
        let pending = Task { try await client.sample(configuration) }
        await gate.waitUntilPaused()
        pending.cancel()
        await gate.release()
        do {
            _ = try await pending.value
            XCTFail("Cancellation must leave the sampling task")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTransportCancellationIsRethrownEvenWhenTaskWasNotCancelled() async throws {
        let fixture = LlamaSlotTransportStub([
            "/prefix/metrics": [metrics(gauge: 25)],
            "/prefix/props": [props()],
        ])
        await fixture.cancelNextSlots()
        do {
            _ = try await makeClient(fixture).sample(.init(kind: .llamaCpp, baseURL: base))
            XCTFail("A transport cancellation must not become the reported gauge")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func makeClient(
        _ fixture: LlamaSlotTransportStub, clock: LlamaSlotTestClock = LlamaSlotTestClock()
    ) -> HTTPBackendClient {
        HTTPBackendClient(
            transport: { try await fixture.respond($0) }, monotonicTime: { clock.now() })
    }

    private func metrics(running: Int = 1, gauge: Double = 0) -> BackendHTTPResponse {
        .json(
            """
            llamacpp:requests_processing \(running)
            llamacpp:requests_deferred 2
            llamacpp:predicted_tokens_seconds \(gauge)
            llamacpp:tokens_predicted_total 1000
            llamacpp:prompt_tokens_total 2000
            """)
    }

    private func props(capability: String? = "true", model: String? = "local-model")
        -> BackendHTTPResponse
    {
        var fields = [
            "\"default_generation_settings\":{}", "\"total_slots\":4", "\"endpoint_metrics\":true",
        ]
        if let capability { fields.append("\"endpoint_slots\":\(capability)") }
        if let model { fields.append("\"model_alias\":\"\(model)\"") }
        return .json("{" + fields.joined(separator: ",") + "}")
    }

    private func slots(_ values: [(Int, Int, Int)]) -> BackendHTTPResponse {
        let entries = values.map { slot, task, count in
            "{\"id\":\(slot),\"is_processing\":true,\"id_task\":\(task),"
                + "\"next_token\":[{\"n_decoded\":\(count)}],\"params\":{\"temperature\":0.8}}"
        }
        return .json("[" + entries.joined(separator: ",") + "]")
    }

    private func rate(
        _ throughput: inout LlamaSlotThroughput, _ values: [(Int, Int, Int)],
        at time: TimeInterval, processStart: Double? = nil
    ) throws -> Double? {
        try throughput.sample(slots(values).data, at: time, processStart: processStart).currentTPS
    }
}

private actor LlamaSlotTransportStub {
    var requests: [URLRequest] = []
    private var responses: [String: [BackendHTTPResponse]]
    private var slotGate: LlamaSlotResponseGate?
    private var shouldCancelSlots = false

    init(_ responses: [String: [BackendHTTPResponse]]) { self.responses = responses }

    func suspendNextSlots(with gate: LlamaSlotResponseGate) { slotGate = gate }
    func cancelNextSlots() { shouldCancelSlots = true }

    func respond(_ request: URLRequest) async throws -> BackendHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        if path == "/prefix/slots", shouldCancelSlots {
            shouldCancelSlots = false
            throw CancellationError()
        }
        guard var queue = responses[path], !queue.isEmpty else {
            return BackendHTTPResponse(statusCode: 404, data: Data())
        }
        let response = queue.removeFirst()
        responses[path] = queue
        if path == "/prefix/slots", let gate = slotGate {
            slotGate = nil
            await gate.pause()
        }
        return response
    }
}

private actor LlamaSlotResponseGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class LlamaSlotTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ amount: TimeInterval) { lock.withLock { time += amount } }
}

extension BackendHTTPResponse {
    fileprivate static func json(_ text: String) -> BackendHTTPResponse {
        BackendHTTPResponse(statusCode: 200, data: Data(text.utf8))
    }
}
