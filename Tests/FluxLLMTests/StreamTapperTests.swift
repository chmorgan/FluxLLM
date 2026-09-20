import Foundation
import NIO
import XCTest

@testable import FluxLLM

@MainActor
final class StreamTapperTests: XCTestCase {
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
            XCTAssertEqual(context.store.currentTPS, 0)
            XCTAssertNil(context.store.lastMeasuredTPS)
        }
    }

    func testClientCancellationMarksGenerationCancelled() async throws {
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
            XCTAssertEqual(context.store.currentTPS, 0)
            XCTAssertNil(context.store.lastMeasuredTPS)
            XCTAssertTrue(context.proxy.isRunning)
            await gate.release()
        }
    }

    func testStoppingProxyDuringRequestClosesClientAndCancelsGeneration() async throws {
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
            XCTAssertEqual(context.store.currentTPS, 0)
            XCTAssertEqual(context.store.proxyState, .stopped)
            await gate.release()
        }
    }
}
