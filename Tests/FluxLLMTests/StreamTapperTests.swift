import Foundation
import NIO
import XCTest

@testable import FluxLLM

@MainActor
final class StreamTapperTests: XCTestCase {
    func testScopedNIOCPUUsesRealRegisteredLoopAndPreservesLiveForwarding() async throws {
        let gate = MockResponseGate()
        let fixture = MockOllamaResponse.generation(chat: true, gate: gate)
        try await withProxy(response: fixture, nioCPUAccountingEnabled: true) { context in
            let beforeValue = try await context.proxy.performanceNIOSnapshot()
            let before = try XCTUnwrap(beforeValue)
            let probe = StreamingProbe()
            let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            session.dataTask(with: context.request(path: "/api/chat")).resume()
            try await waitForCondition("Instrumented bytes must arrive before completion") {
                probe.data == Data(fixture.firstBytes)
            }
            XCTAssertFalse(probe.isComplete)
            await gate.release()
            try await waitForCondition("Instrumented stream must finish with exact accounting") {
                probe.isComplete && context.store.activeGeneration?.state == .completed
            }
            XCTAssertNil(probe.error)
            XCTAssertEqual(probe.data, fixture.body)
            XCTAssertEqual(context.store.outputTokens, 12)
            let afterValue = try await context.proxy.performanceNIOSnapshot()
            let after = try XCTUnwrap(afterValue)
            let threadID = try await context.proxy.performanceEventLoopThreadID()
            XCTAssertEqual(after.threadID, threadID)
            XCTAssertNil(after.error)
            XCTAssertGreaterThan(after.sequence, before.sequence)
            let metrics = after.counters
            XCTAssertGreaterThan(
                metrics[PerformanceNIODiagnostics.Metric.upstreamRead.index].calls, 0)
            XCTAssertGreaterThan(
                metrics[PerformanceNIODiagnostics.Metric.upstreamReadComplete.index].calls, 0)
            XCTAssertEqual(
                metrics[PerformanceNIODiagnostics.Metric.forwarding.index].bytes,
                UInt64(fixture.body.count))
            XCTAssertEqual(
                metrics[PerformanceNIODiagnostics.Metric.framing.index].bytes,
                UInt64(fixture.body.count))
            XCTAssertEqual(metrics[PerformanceNIODiagnostics.Metric.forwarding.index].ends, 1)
            XCTAssertEqual(metrics[PerformanceNIODiagnostics.Metric.framing.index].ends, 1)
        }
    }

    func testOnlyNativeGenerationPathsAreTracked() {
        let body = ByteBuffer(string: "{\"stream\":true}")
        XCTAssertTrue(StreamTapper.isGenerationRequest(path: "/api/generate", body: body))
        XCTAssertTrue(StreamTapper.isGenerationRequest(path: "/api/chat?x=1", body: body))
        XCTAssertFalse(StreamTapper.isGenerationRequest(path: "/api/tags", body: body))
        XCTAssertFalse(StreamTapper.isGenerationRequest(path: "/api/anything", body: body))
        XCTAssertFalse(StreamTapper.isGenerationRequest(path: "/v1/chat/completions", body: body))
    }

    func testGenerateForwardsLiveContentBeforeCompletion() async throws {
        try await verifyLiveForwarding(chat: false)
    }

    func testChatForwardsLiveContentBeforeCompletion() async throws {
        try await verifyLiveForwarding(chat: true)
    }

    func testBatchedTelemetryForwardsGenerateAndChatBytesBeforeCompletion() async throws {
        try await withBatchedTelemetry {
            try await verifyLiveForwarding(chat: false)
            try await verifyLiveForwarding(chat: true)
        }
    }

    func testBatchedTelemetryPreservesMalformedBytesToolsAndAuthoritativeCorrection() async throws {
        try await withBatchedTelemetry {
            try await verifySharedRecordPreservesTextToolsMalformedBytesAndFinalCorrection()
        }
    }

    func testBatchedTelemetryPreservesClientCancellationAndShutdownUsage() async throws {
        try await withBatchedTelemetry {
            try await verifyClientCancellation()
            try await verifyStoppingProxyDuringRequest()
        }
    }

    func testBatchedTelemetryPreservesAbortedUpstreamFailureAndAcceptedUsage() async throws {
        try await withBatchedTelemetry {
            try await verifyUpstreamAbort()
        }
    }

    func testUnpromisedBodiesKeepLiveDeliveryAndAuthoritativeCompletion() async throws {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        let previousMode = diagnostics.mode
        try diagnostics.enable(mode: .runtimeStreamWrites)
        defer { try? diagnostics.enable(mode: previousMode) }
        PerformancePresentationCounters.shared.enable()
        try await verifyLiveForwarding(chat: true)
        XCTAssertGreaterThan(
            PerformancePresentationCounters.shared.snapshot()[
                "streamed_bodies_without_promises", default: 0], 0)
    }

    func testSharedRecordPreservesTextToolsMalformedBytesAndFinalCorrection() async throws {
        try await verifySharedRecordPreservesTextToolsMalformedBytesAndFinalCorrection()
    }

    private func verifySharedRecordPreservesTextToolsMalformedBytesAndFinalCorrection() async throws
    {
        let gate = MockResponseGate()
        let call =
            #"{"id":"call-1","function":{"name":"read_file","arguments":{}}}"#
        let first =
            #"{"message":{"content":"Hello 🌊","thinking":"Reasoning","tool_calls":[\#(call)]},"done":false}"#
            + "\n" + #"{"message":"# + "\n"
            + "[]\n"
            + #"{"message":{"content":null,"tool_calls":"invalid"},"done":false}"# + "\n"
        let firstBytes =
            Array(first.utf8)
            + Array(#"{"response":""#.utf8) + [UInt8(0xFF)] + Array("\"}\n".utf8)
        let final =
            #"{"message":{"content":"Done","tool_calls":[\#(call),{"id":"call-2","function":{"name":"search","arguments":{}}}]},"done":true,"eval_count":1,"prompt_eval_count":3,"eval_duration":500000000}"#
            + "\n"
        let fixture = MockOllamaResponse(
            contentType: "application/x-ndjson", firstBytes: firstBytes,
            remainingBytes: Array(final.utf8), gate: gate, streaming: true)
        try await withProxy(response: fixture) { context in
            let probe = StreamingProbe()
            let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            session.dataTask(with: context.request(path: "/api/chat")).resume()
            try await waitForCondition("Text and tools must be observed before completion") {
                probe.data == Data(firstBytes) && context.store.outputTokens == 2
                    && context.store.toolActivityEvents.count == 1
            }
            XCTAssertFalse(probe.isComplete)
            XCTAssertTrue(context.store.outputIsEstimated)
            XCTAssertEqual(context.store.toolActivityEvents.map(\.callID), ["call-1"])

            await gate.release()
            try await waitForCondition("Final usage and the terminal record's new call must arrive")
            {
                probe.isComplete && context.store.activeGeneration?.state == .completed
            }
            XCTAssertNil(probe.error)
            XCTAssertEqual(probe.data, fixture.body, "Malformed telemetry must still pass through")
            XCTAssertEqual(
                context.store.outputTokens, 1, "Final usage can correct an estimate down")
            XCTAssertEqual(context.store.promptTokens, 3)
            XCTAssertEqual(context.store.lastMeasuredTPS, 2)
            XCTAssertFalse(context.store.outputIsEstimated)
            XCTAssertEqual(context.store.toolActivityEvents.map(\.callID), ["call-1", "call-2"])
            XCTAssertEqual(context.store.toolActivityEvents.map(\.name), ["read_file", "search"])
        }
    }

    func testChatToolCallsArriveBeforeCompletionWithoutCountingAsText() async throws {
        let gate = MockResponseGate()
        let call =
            #"{"function":{"index":0,"name":"read_file","arguments":{"path":"source.swift"}}}"#
        let first = #"{"message":{"tool_calls":[\#(call)]},"done":false}"# + "\n"
        let final =
            #"{"message":{"tool_calls":[\#(call)]},"done":true,"eval_count":0}"# + "\n"
        let fixture = MockOllamaResponse(
            contentType: "application/x-ndjson", firstBytes: Array(first.utf8),
            remainingBytes: Array(final.utf8), gate: gate, streaming: true)
        try await withProxy(response: fixture) { context in
            let probe = StreamingProbe()
            let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            session.dataTask(
                with: context.request(
                    path: "/api/chat",
                    body: #"{"model":"fixture-model","messages":[],"stream":true}"#)
            ).resume()
            try await waitForCondition("Live tool call was not recorded before completion") {
                context.store.toolActivityEvents.count == 1
                    && probe.data == Data(first.utf8)
            }
            XCTAssertFalse(probe.isComplete)
            XCTAssertEqual(context.store.activeGeneration?.state, .running)
            XCTAssertEqual(context.store.requestLanes.first?.model, "fixture-model")
            XCTAssertEqual(context.store.outputTokens, 0)
            XCTAssertEqual(context.store.toolActivityEvents.first?.kind, .call)
            XCTAssertEqual(context.store.toolActivityEvents.first?.name, "read_file")

            await gate.release()
            try await waitForCondition("Tool-only stream did not complete") {
                probe.isComplete && context.store.activeGeneration?.state == .completed
            }
            XCTAssertNil(probe.error)
            XCTAssertEqual(probe.data, fixture.body)
            XCTAssertEqual(context.store.requestLanes.first?.model, "fixture-model")
            XCTAssertEqual(context.store.toolActivityEvents.count, 1, "Repeated index is one call")
        }
    }

    func testFragmentedToolCallAtUnterminatedFinalLineIsRetained() async throws {
        let gate = MockResponseGate()
        let body =
            #"{"message":{"tool_calls":[{"id":"call-1","function":{"name":"read_🌊","arguments":{}}}]},"done":true,"eval_count":0}"#
        let bytes = Array(body.utf8)
        let split = try XCTUnwrap(bytes.firstIndex(of: 0xF0)) + 2
        let fixture = MockOllamaResponse(
            contentType: "application/x-ndjson", firstBytes: Array(bytes[..<split]),
            remainingBytes: Array(bytes[split...]), gate: gate, streaming: true)
        try await withProxy(response: fixture) { context in
            let probe = StreamingProbe()
            let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            session.dataTask(with: context.request(path: "/api/chat")).resume()
            try await waitForCondition("Partial tool response was not forwarded immediately") {
                probe.data == Data(fixture.firstBytes)
            }
            XCTAssertTrue(context.store.toolActivityEvents.isEmpty)
            await gate.release()
            try await waitForCondition("Final tool call was dropped at EOF") {
                probe.isComplete && context.store.activeGeneration?.state == .completed
            }
            XCTAssertNil(probe.error)
            XCTAssertEqual(probe.data, Data(bytes))
            XCTAssertEqual(context.store.toolActivityEvents.map(\.name), ["read_🌊"])
            XCTAssertEqual(context.store.toolActivityEvents.first?.callID, "call-1")
        }
    }

    func testNonStreamingToolResponseAndLatestResultsPreserveRequestAndResponseBytes() async throws
    {
        let responseBody =
            #"{"message":{"tool_calls":[{"id":"next-1","function":{"name":"search","arguments":{}}},{"id":"next-2","function":{"name":"search","arguments":{}}}]},"done":true,"eval_count":0}"#
        let requestBody = """
            {"model":"fixture-model","stream":false,"messages":[
              {"role":"tool","tool_name":"old_result","content":"old content"},
              {"role":"assistant","tool_calls":[{"id":"a","function":{"name":"read_file","arguments":{}}}]},
              {"role":"tool","tool_name":"read_file","tool_call_id":"a","content":"private file content"},
              {"role":"tool","name":"search","tool_call_id":"b","content":"private search result"}
            ]}
            """
        let fixture = MockOllamaResponse(firstBytes: Array(responseBody.utf8))
        try await withProxy(response: fixture) { context in
            let (data, response) = try await URLSession.shared.data(
                for: context.request(path: "/api/chat?fixture=1", body: requestBody))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, fixture.body)
            try await waitForCondition("Nonstreaming tool events were not retained") {
                context.store.activeGeneration?.state == .completed
            }
            XCTAssertEqual(context.store.requestLanes.first?.model, "fixture-model")
            XCTAssertEqual(context.mock.requests.first?.body, Data(requestBody.utf8))
            let events = context.store.toolActivityEvents
            XCTAssertEqual(
                events.map(\.kind), [.resultSubmission, .resultSubmission, .call, .call])
            XCTAssertEqual(events.map(\.name), ["read_file", "search", "search", "search"])
            XCTAssertEqual(events.map(\.callID), ["a", "b", "next-1", "next-2"])
            XCTAssertTrue(events.prefix(2).allSatisfy { $0.timestamp <= events[2].timestamp })
        }
    }

    private func verifyLiveForwarding(chat: Bool) async throws {
        let gate = MockResponseGate()
        let fixture = MockOllamaResponse.generation(chat: chat, gate: gate)
        try await withProxy(response: fixture) { context in
            let probe = StreamingProbe()
            let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let body =
                chat
                ? "{\"model\":\"fixture-model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"stream\":true}"
                : nil
            let task = session.dataTask(
                with: context.request(
                    path: chat ? "/api/chat" : "/api/generate", body: body))
            task.resume()
            try await waitForCondition("Client did not receive the first upstream NDJSON line") {
                probe.data == Data(fixture.firstBytes)
            }
            XCTAssertFalse(probe.isComplete, "Fixture has not released terminal bytes")
            try await waitForCondition("Live content did not update metrics before done:true") {
                context.store.outputTokens > 0
                    && context.store.activeGeneration?.state == .running
            }
            XCTAssertTrue(context.store.outputIsEstimated)
            XCTAssertNil(context.store.promptTokens)
            XCTAssertNil(context.store.lastMeasuredTPS)
            XCTAssertEqual(context.store.currentModel, "fixture-model")
            XCTAssertEqual(context.store.requestLanes.first?.model, "fixture-model")

            await gate.release()
            try await waitForCondition("Stream did not finish after releasing terminal bytes") {
                probe.isComplete && context.store.activeGeneration?.state == .completed
            }
            XCTAssertNil(probe.error)
            XCTAssertEqual(probe.data, fixture.body, "Proxy must preserve all response bytes")
            XCTAssertEqual(context.store.outputTokens, 12)
            XCTAssertEqual(context.store.promptTokens, 4)
            XCTAssertFalse(context.store.outputIsEstimated)
            XCTAssertEqual(context.store.currentTPS, 0)
            XCTAssertEqual(context.store.lastMeasuredTPS ?? -1, 20, accuracy: 0.001)
        }
    }

    func testUTF8SplitAcrossUpstreamWritesPreservesResponseAndMetrics() async throws {
        let gate = MockResponseGate()
        var fixture = MockOllamaResponse.generation(gate: gate)
        let bytes = Array(fixture.body)
        let unicodeStart = try XCTUnwrap(bytes.firstIndex(of: 0xF0))
        let split = unicodeStart + 2
        fixture.firstBytes = Array(bytes[..<split])
        fixture.remainingBytes = Array(bytes[split...])
        try await withProxy(response: fixture) { context in
            let probe = StreamingProbe()
            let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            session.dataTask(with: context.request()).resume()
            try await waitForCondition("Partial UTF-8 response bytes were buffered by proxy") {
                probe.data == Data(fixture.firstBytes)
            }
            XCTAssertFalse(probe.isComplete)
            await gate.release()
            try await waitForCondition("Fragmented response did not complete") {
                probe.isComplete && context.store.activeGeneration?.state == .completed
            }
            XCTAssertNil(probe.error)
            XCTAssertEqual(probe.data, Data(bytes))
            XCTAssertEqual(context.store.outputTokens, 12)
            XCTAssertEqual(context.store.currentModel, "fixture-model")
        }
    }

    func testStreamErrorBodyPassesThroughAndDoesNotBecomeSuccess() async throws {
        let fixture = MockOllamaResponse(
            contentType: "application/x-ndjson",
            firstBytes: Array("{\"error\":\"runner stopped\"}\n".utf8), streaming: true)
        try await withProxy(response: fixture) { context in
            let (data, response) = try await URLSession.shared.data(for: context.request())
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, fixture.body)
            try await waitForCondition("Stream error was not reflected in metrics") {
                context.store.activeGeneration?.state == .errored
            }
            XCTAssertTrue(context.store.generationError?.contains("runner stopped") == true)
            XCTAssertNil(context.store.lastMeasuredTPS)
            XCTAssertEqual(context.store.currentTPS, 0)
        }
    }

    func testUpstreamAbortEndsClientAndMarksGenerationErrored() async throws {
        try await verifyUpstreamAbort()
    }

    private func verifyUpstreamAbort() async throws {
        let gate = MockResponseGate()
        var fixture = MockOllamaResponse.generation(gate: gate)
        fixture.remainingBytes = []
        fixture.truncate = true
        try await withProxy(response: fixture) { context in
            let probe = StreamingProbe()
            let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            session.dataTask(with: context.request()).resume()
            try await waitForCondition("Abort fixture did not deliver prefix") {
                !probe.data.isEmpty
            }
            await gate.release()
            try await waitForCondition("Aborted stream left an open client or running generation") {
                probe.isComplete && context.store.activeGeneration?.state == .errored
            }
            XCTAssertEqual(probe.data, Data(fixture.firstBytes))
            XCTAssertNotNil(context.store.generationError)
            XCTAssertEqual(
                context.store.outputTokens, 1, "Aborting must flush accepted prefix accounting")
            XCTAssertEqual(context.store.currentTPS, 0)
            XCTAssertNil(context.store.lastMeasuredTPS)
        }
    }

    func testClientCancellationMarksGenerationCancelled() async throws {
        try await verifyClientCancellation()
    }

    func testUnpromisedBodiesCancelWhenClientDisconnects() async throws {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        let previousMode = diagnostics.mode
        try diagnostics.enable(mode: .runtimeStreamWrites)
        defer { try? diagnostics.enable(mode: previousMode) }
        try await verifyClientCancellation()
    }

    private func verifyClientCancellation() async throws {
        let gate = MockResponseGate()
        let fixture = MockOllamaResponse.generation(gate: gate)
        try await withProxy(response: fixture) { context in
            let probe = StreamingProbe()
            let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let task = session.dataTask(with: context.request())
            task.resume()
            try await waitForCondition("Cancellation fixture did not start") {
                !probe.data.isEmpty && context.store.activeGeneration?.state == .running
            }
            task.cancel()
            try await waitForCondition("Client cancellation left the generation running") {
                context.store.activeGeneration?.state == .cancelled
            }
            XCTAssertEqual(
                context.store.outputTokens, 1, "Cancelling must flush accepted prefix accounting")
            XCTAssertEqual(context.store.requestLanes.first?.outputTokens, 1)
            XCTAssertEqual(context.store.currentTPS, 0)
            XCTAssertNil(context.store.lastMeasuredTPS)
            XCTAssertTrue(context.proxy.isRunning)
            await gate.release()
        }
    }

    func testStoppingProxyDuringRequestClosesClientAndCancelsGeneration() async throws {
        try await verifyStoppingProxyDuringRequest()
    }

    private func verifyStoppingProxyDuringRequest() async throws {
        let gate = MockResponseGate()
        try await withProxy(response: .generation(gate: gate)) { context in
            let probe = StreamingProbe()
            let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            session.dataTask(with: context.request()).resume()
            try await waitForCondition("Shutdown fixture did not start") {
                !probe.data.isEmpty && context.store.activeGeneration?.state == .running
            }
            await context.proxy.stop()
            try await waitForCondition("Shutdown did not close the client and cancel its request") {
                probe.isComplete && context.store.activeGeneration?.state == .cancelled
            }
            XCTAssertFalse(context.proxy.isRunning)
            XCTAssertNil(context.proxy.boundPort)
            XCTAssertEqual(context.store.activeGeneration?.state, .cancelled)
            XCTAssertEqual(
                context.store.outputTokens, 1, "Shutdown must flush accepted prefix accounting")
            XCTAssertEqual(context.store.requestLanes.first?.outputTokens, 1)
            XCTAssertEqual(context.store.currentTPS, 0)
            XCTAssertEqual(context.store.proxyState, .stopped)
            await gate.release()
        }
    }

    private func withBatchedTelemetry(_ operation: () async throws -> Void) async throws {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        let previousMode = diagnostics.mode
        let wasEnabled = diagnostics.isEnabled
        try diagnostics.enable(mode: .runtimeTelemetryBatch)
        defer {
            if wasEnabled {
                try? diagnostics.enable(mode: previousMode)
            } else {
                try? diagnostics.disable()
            }
        }
        try await operation()
        let counters = try XCTUnwrap(
            diagnostics.snapshot()["batched_telemetry"] as? [String: UInt64])
        XCTAssertGreaterThan(counters["compact_states_enqueued", default: 0], 0)
        XCTAssertGreaterThan(counters["snapshots_materialized", default: 0], 0)
        XCTAssertGreaterThan(counters["batches_applied", default: 0], 0)
        XCTAssertEqual(counters["projection_refreshes"], counters["batches_applied"])
        XCTAssertLessThanOrEqual(
            counters["snapshots_materialized", default: 0],
            counters["compact_states_enqueued", default: 0])
    }
}
