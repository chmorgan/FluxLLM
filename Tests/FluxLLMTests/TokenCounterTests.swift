import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class TokenCounterTests: XCTestCase {
    func testRecordTimestampsPreserveLiveRateWhenSnapshotPublicationIsDelayed() {
        let clock = TokenCounterTestClock()
        let firstRecordAt = clock.now()
        let secondRecordAt = firstRecordAt.addingTimeInterval(2)
        clock.advance(by: 30)
        var state = TokenState(clock: { clock.now() })

        state.ingest(["response": "first", "done": false], at: firstRecordAt)
        state.ingest(["response": "second", "done": false], at: secondRecordAt)

        let recorded = state.snapshot(at: secondRecordAt)
        XCTAssertEqual(recorded.timestamp, secondRecordAt)
        XCTAssertEqual(recorded.outputTokens, 2)
        XCTAssertEqual(recorded.elapsed, 2, accuracy: 0.000_001)
        XCTAssertEqual(recorded.liveTPS, 1, accuracy: 0.000_001)
        XCTAssertFalse(recorded.finished)
        XCTAssertFalse(state.isTerminal)
        XCTAssertTrue(state.hasOutput)

        let current = state.snapshot()
        XCTAssertEqual(current.timestamp, clock.now())
        XCTAssertEqual(current.elapsed, 30, accuracy: 0.000_001)
        XCTAssertEqual(current.liveTPS, 2.0 / 30.0, accuracy: 0.000_001)
        XCTAssertEqual(current.outputTokens, recorded.outputTokens)
        XCTAssertEqual(state.snapshot(at: secondRecordAt).timestamp, secondRecordAt)
    }

    func testTerminalRecordTimeOverridesEarlierAndLaterSnapshotTimes() {
        let terminalRecords: [[String: Any]] = [
            ["done": true, "eval_count": 3, "eval_duration": 1_000_000_000.0],
            ["error": "runner stopped"],
        ]
        for terminalRecord in terminalRecords {
            let clock = TokenCounterTestClock()
            let firstRecordAt = clock.now()
            let terminalRecordAt = firstRecordAt.addingTimeInterval(4)
            clock.advance(by: 40)
            var state = TokenState(clock: { clock.now() })
            state.ingest(["response": "partial", "done": false], at: firstRecordAt)
            state.ingest(terminalRecord, at: terminalRecordAt)

            let terminal = state.snapshot()
            XCTAssertTrue(state.isTerminal)
            XCTAssertTrue(terminal.finished)
            XCTAssertEqual(terminal.error, terminalRecord["error"] as? String)
            XCTAssertEqual(terminal.timestamp, terminalRecordAt)
            XCTAssertEqual(terminal.elapsed, 4, accuracy: 0.000_001)
            XCTAssertEqual(terminal.liveTPS, 0.25, accuracy: 0.000_001)
            for offset in [-10.0, 100.0] {
                assertEqualSnapshots(
                    state.snapshot(at: firstRecordAt.addingTimeInterval(offset)), terminal,
                    payload: "terminal snapshot at offset \(offset)")
            }

            clock.advance(by: 20)
            state.ingest(
                ["response": "late", "done": true, "eval_count": 999], at: clock.now())
            assertEqualSnapshots(state.finish(), terminal, payload: "late terminal input")
            XCTAssertTrue(state.isTerminal)
        }
    }

    func testPrematureEOFTimeOverridesExplicitSnapshotTimes() {
        let clock = TokenCounterTestClock()
        let firstRecordAt = clock.now()
        var state = TokenState(clock: { clock.now() })
        state.ingest(["response": "partial", "done": false], at: firstRecordAt)
        clock.advance(by: 4)
        let terminal = state.finish()

        XCTAssertTrue(state.isTerminal)
        XCTAssertTrue(terminal.finished)
        XCTAssertNotNil(terminal.error)
        XCTAssertEqual(terminal.timestamp, clock.now())
        XCTAssertEqual(terminal.elapsed, 4, accuracy: 0.000_001)
        for offset in [-10.0, 100.0] {
            assertEqualSnapshots(
                state.snapshot(at: firstRecordAt.addingTimeInterval(offset)), terminal,
                payload: "EOF snapshot at offset \(offset)")
        }
        clock.advance(by: 20)
        assertEqualSnapshots(state.finish(), terminal, payload: "repeated EOF")
    }

    func testDecodedDeltaFieldsCountOnlyNonemptyStringsIncludingWhitespace() {
        let clock = TokenCounterTestClock()
        var state = TokenState(clock: { clock.now() })
        XCTAssertFalse(state.hasOutput)
        XCTAssertFalse(state.isTerminal)

        state.ingest([
            "response": "", "thinking": "", "message": ["content": "", "thinking": ""],
        ])
        state.ingest([
            "response": 7, "thinking": NSNull(),
            "message": ["content": false, "thinking": ["nested": "ignored"]] as [String: Any],
        ])
        XCTAssertEqual(state.snapshot().outputTokens, 0)
        XCTAssertFalse(state.hasOutput)

        state.ingest([
            "response": "answer", "thinking": "reasoning",
            "message": ["content": "nested answer", "thinking": "nested reasoning"],
        ])
        XCTAssertEqual(state.snapshot().outputTokens, 4)
        XCTAssertTrue(state.hasOutput)

        state.ingest([
            "response": " ", "thinking": "\t", "message": ["content": "\n", "thinking": " \t\n"],
        ])
        XCTAssertEqual(state.snapshot().outputTokens, 8)
        XCTAssertTrue(state.hasOutput)
    }

    func testHasOutputMatchesAuthoritativeCountIncludingZero() {
        for authoritativeCount in [0, 7] {
            let clock = TokenCounterTestClock()
            var state = TokenState(clock: { clock.now() })
            XCTAssertEqual(state.hasOutput, state.snapshot().outputTokens > 0)

            state.ingest(["response": "estimated fragment", "done": false])
            XCTAssertTrue(state.hasOutput)
            XCTAssertEqual(state.hasOutput, state.snapshot().outputTokens > 0)

            state.ingest([
                "done": true, "eval_count": authoritativeCount,
                "eval_duration": 1_000_000_000.0,
            ])
            let terminal = state.snapshot()
            XCTAssertEqual(terminal.outputTokens, authoritativeCount)
            XCTAssertFalse(terminal.isEstimated)
            XCTAssertNil(terminal.error)
            XCTAssertEqual(state.hasOutput, authoritativeCount > 0)
            XCTAssertEqual(state.hasOutput, terminal.outputTokens > 0)
            XCTAssertTrue(state.isTerminal)
        }
    }

    func testTokenStateConformsToSendable() {
        func requireSendable<Value: Sendable>(_ value: Value) {}
        requireSendable(TokenState())
    }

    func testNativeDictionaryAdapterPreservesScalarCastSemantics() {
        let timestamp = Date(timeIntervalSince1970: 100)
        var integerFlag = TokenState()
        integerFlag.ingest(
            [
                "response": "partial", "done": 1, "prompt_eval_count": 3.0,
                "eval_count": 2, "eval_duration": 1_000_000_000.0,
            ], at: timestamp)
        XCTAssertFalse(integerFlag.isTerminal, "A native Swift Int is not a Bool")
        XCTAssertNil(integerFlag.snapshot(at: timestamp).promptTokens)
        XCTAssertEqual(integerFlag.snapshot(at: timestamp).outputTokens, 1)

        var integerDuration = TokenState()
        integerDuration.ingest(
            [
                "done": true, "eval_count": 3, "eval_duration": 1_000_000_000,
            ], at: timestamp)
        let invalid = integerDuration.snapshot()
        XCTAssertTrue(invalid.finished)
        XCTAssertEqual(invalid.outputTokens, 3)
        XCTAssertNil(invalid.authoritativeTPS, "A native Swift Int is not a Double")
        XCTAssertNotNil(invalid.error)

        var numberDuration = TokenState()
        numberDuration.ingest(
            [
                "done": true, "eval_count": 3, "eval_duration": NSNumber(value: 1_000_000_000),
            ], at: timestamp)
        XCTAssertEqual(numberDuration.snapshot().authoritativeTPS, 3)
        XCTAssertNil(numberDuration.snapshot().error)

        var booleanCount = TokenState()
        booleanCount.ingest(["response": "partial"], at: timestamp)
        booleanCount.ingest(
            [
                "done": true, "eval_count": true, "prompt_eval_count": false,
                "eval_duration": 1_000_000_000.0,
            ], at: timestamp.addingTimeInterval(1))
        let missingCount = booleanCount.snapshot()
        XCTAssertEqual(missingCount.outputTokens, 1)
        XCTAssertTrue(missingCount.isEstimated, "A native Swift Bool is not an Int")
        XCTAssertNil(missingCount.promptTokens)
        XCTAssertNotNil(missingCount.error)
    }

    func testDecodedRecordsPreserveStringIngestionSemantics() throws {
        let sequences = [
            [
                #"{"model":"qwen3","message":{"content":"","thinking":""},"done":false}"#,
                #"{"response":"top-level","thinking":"reasoning","message":{"content":"café ✓","thinking":"nested reasoning"},"done":false}"#,
                #"{"message":{"content":"partial""#,
                "[]",
                #"{"response":7,"thinking":null,"message":{"content":false,"thinking":{}},"done":"invalid"}"#,
                #"{"model":"resolved","done":true,"eval_count":2,"prompt_eval_count":8,"eval_duration":500000000}"#,
                #"{"response":"late","done":true,"eval_count":999,"eval_duration":1000000000}"#,
            ],
            [
                #"{"response":"partial","done":false}"#,
                #"{"error":"runner stopped"}"#,
                #"{"done":true,"eval_count":999,"eval_duration":1000000000}"#,
            ],
            [
                #"{"response":"delta","prompt_eval_count":true}"#,
                #"{"done":1,"eval_count":2.0,"eval_duration":1000000000}"#,
            ],
            [#"{"done":true,"eval_count":true,"eval_duration":true}"#],
        ]
        for payloads in sequences {
            let clock = TokenCounterTestClock()
            var strings = TokenState(clock: { clock.now() })
            var decoded = TokenState(clock: { clock.now() })
            var foundation = TokenState(clock: { clock.now() })
            for payload in payloads {
                clock.advance(by: 2)
                strings.ingest(payload)
                if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                    as? [String: Any]
                {
                    decoded.ingest(object)
                }
                if let record = DecodedGenerationRecord(data: Data(payload.utf8)) {
                    foundation.ingest(record)
                }
                assertEqualSnapshots(decoded.snapshot(), strings.snapshot(), payload: payload)
                assertEqualSnapshots(foundation.snapshot(), decoded.snapshot(), payload: payload)
            }
            assertEqualSnapshots(decoded.finish(), strings.finish(), payload: "EOF")
            assertEqualSnapshots(foundation.finish(), decoded.finish(), payload: "Foundation EOF")
        }
    }

    func testBorrowedRecordRejectsMalformedAndNonObjectJSON() {
        for bytes in [
            Array("not JSON".utf8), Array("[]".utf8), Array("null".utf8),
            Array(#"{"message":"#.utf8), [UInt8(0xFF)],
        ] {
            XCTAssertNil(DecodedGenerationRecord(data: Data(bytes)))
        }
    }

    func testEscapedAndDuplicateProtocolKeysPreserveFoundationAccounting() throws {
        let clock = TokenCounterTestClock()
        var strings = TokenState(clock: { clock.now() })
        var native = TokenState(clock: { clock.now() })
        var borrowed = TokenState(clock: { clock.now() })
        let payloads = [
            #"{"mo\u0064el":"qwen-🌊","model":"duplicate-model","res\u0070onse":"answer","thinking":"reasoning","mess\u0061ge":{"con\u0074ent":"nested","thinking":"thought"},"done":false}"#,
            #"{"do\u006ee":true,"eval\u005fcount":6,"eval_count":7,"prompt\u005feval_count":true,"eval\u005fduration":1000000000}"#,
        ]
        var expectedModel: String?
        var expectedCount: Int?
        for (index, payload) in payloads.enumerated() {
            clock.advance(by: 2)
            // Read the existing Foundation result with ordinary String keys:
            // duplicate-key selection must remain Foundation's decision.
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            strings.ingest(payload)
            native.ingest(object)
            borrowed.ingest(try XCTUnwrap(DecodedGenerationRecord(data: Data(payload.utf8))))
            assertEqualSnapshots(borrowed.snapshot(), native.snapshot(), payload: payload)
            assertEqualSnapshots(strings.snapshot(), native.snapshot(), payload: payload)
            if index == 0 {
                expectedModel = try XCTUnwrap(object["model"] as? String)
                XCTAssertEqual(borrowed.snapshot().outputTokens, 4)
                XCTAssertEqual(borrowed.snapshot().model, expectedModel)
            } else {
                expectedCount = try XCTUnwrap(object["eval_count"] as? Int)
            }
        }
        let result = borrowed.finish()
        let count = try XCTUnwrap(expectedCount)
        XCTAssertEqual(result.model, expectedModel)
        XCTAssertEqual(result.outputTokens, count)
        XCTAssertEqual(result.promptTokens, 1, "JSON booleans retain NSNumber-to-Int bridging")
        XCTAssertEqual(result.authoritativeTPS, Double(count))
        XCTAssertTrue(result.finished)
        XCTAssertFalse(result.isEstimated)
        XCTAssertNil(result.error)
    }

    func testGenerateContentOnlyDeltasProduceAnEstimatedWallClockRate() async {
        let clock = TokenCounterTestClock()
        let counter = TokenCounter(clock: { clock.now() })

        await counter.ingestStream(#"{"model":"llama3","response":"Hello","done":false}"#)
        clock.advance(by: 2)
        await counter.ingestStream(#"{"model":"llama3","response":" world","done":false}"#)
        let live = await counter.live()

        XCTAssertEqual(live.model, "llama3")
        XCTAssertEqual(live.outputTokens, 2)
        XCTAssertNil(live.promptTokens)
        XCTAssertTrue(live.isEstimated)
        XCTAssertFalse(live.finished)
        XCTAssertNil(live.error)
        XCTAssertNil(live.authoritativeTPS)
        XCTAssertEqual(live.elapsed, 2, accuracy: 0.000_001)
        XCTAssertEqual(live.liveTPS, 1, accuracy: 0.000_001)
        XCTAssertEqual(live.timestamp, clock.now())
    }

    func testChatCountsContentAndThinkingButIgnoresEmptyDeltas() async {
        let clock = TokenCounterTestClock()
        let counter = TokenCounter(clock: { clock.now() })

        await counter.ingestStream(
            #"{"model":"qwen3","message":{"role":"assistant","content":"","thinking":""},"done":false}"#
        )
        let empty = await counter.live()
        XCTAssertEqual(empty.outputTokens, 0)
        XCTAssertNil(empty.promptTokens)

        // Time spent before generated text arrives must not dilute generation TPS.
        clock.advance(by: 10)
        await counter.ingestStream(
            #"{"model":"qwen3","message":{"role":"assistant","thinking":"Let me think"},"done":false}"#
        )
        clock.advance(by: 2)
        await counter.ingestStream(
            #"{"model":"qwen3","message":{"role":"assistant","content":"The answer"},"done":false}"#
        )
        await counter.ingestStream(
            #"{"message":{"content":"","thinking":""},"done":false}"#)
        let live = await counter.live()

        XCTAssertEqual(live.outputTokens, 2)
        XCTAssertTrue(live.isEstimated)
        XCTAssertEqual(live.liveTPS, 1, accuracy: 0.000_001)
        XCTAssertNil(live.authoritativeTPS)
    }

    func testGenerateCountsBothNonemptyResponseAndThinkingFields() async {
        let counter = TokenCounter()

        await counter.ingestStream(
            #"{"response":"Answer","thinking":"Reasoning","done":false}"#)
        await counter.ingestStream(#"{"response":"","thinking":"","done":false}"#)
        let live = await counter.live()

        XCTAssertEqual(live.outputTokens, 2)
        XCTAssertTrue(live.isEstimated)
    }

    func testTerminalStatisticsReplaceEstimateEvenWhenFinalCountIsLower() async {
        let clock = TokenCounterTestClock()
        let counter = TokenCounter(clock: { clock.now() })
        for delta in ["a", "b", "c"] {
            await counter.ingestStream("{\"response\":\"\(delta)\",\"done\":false}")
        }
        clock.advance(by: 4)
        let estimated = await counter.live()
        XCTAssertEqual(estimated.outputTokens, 3)
        XCTAssertEqual(estimated.liveTPS, 0.75, accuracy: 0.000_001)

        await counter.ingestStream(
            #"{"model":"llama3","response":"","done":true,"eval_count":2,"prompt_eval_count":8,"eval_duration":500000000}"#
        )
        let result = await counter.finish()

        XCTAssertEqual(result.outputTokens, 2)
        XCTAssertEqual(result.promptTokens, 8)
        XCTAssertEqual(result.model, "llama3")
        XCTAssertFalse(result.isEstimated)
        XCTAssertTrue(result.finished)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.authoritativeTPS ?? -1, 4, accuracy: 0.000_001)
        XCTAssertEqual(result.elapsed, 4, accuracy: 0.000_001)
    }

    func testPromptUsageRemainsUnknownUntilReported() async {
        let counter = TokenCounter()
        let initial = await counter.live()
        XCTAssertNil(initial.promptTokens)

        await counter.ingestStream(#"{"response":"Hi","done":false}"#)
        let live = await counter.live()
        XCTAssertNil(live.promptTokens)

        await counter.ingestStream(
            #"{"done":true,"eval_count":1,"prompt_eval_count":0,"eval_duration":1000000000}"#)
        let result = await counter.finish()
        XCTAssertEqual(result.promptTokens, 0)
    }

    func testNonStreamingParsesAuthoritativeFinalBody() async {
        let counter = TokenCounter()

        await counter.ingestNonStreaming(
            #"{"model":"llama3","response":"A complete answer","done":true,"eval_count":42,"prompt_eval_count":8,"eval_duration":1000000000}"#
        )
        let result = await counter.finish()

        XCTAssertEqual(result.outputTokens, 42)
        XCTAssertEqual(result.promptTokens, 8)
        XCTAssertEqual(result.model, "llama3")
        XCTAssertFalse(result.isEstimated)
        XCTAssertTrue(result.finished)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.authoritativeTPS ?? -1, 42, accuracy: 0.000_001)
    }

    func testNonStreamingChatParsesAuthoritativeFinalBody() async {
        let counter = TokenCounter()

        await counter.ingestNonStreaming(
            #"{"model":"qwen3","message":{"role":"assistant","content":"A complete answer"},"done":true,"eval_count":10,"prompt_eval_count":4,"eval_duration":250000000}"#
        )
        let result = await counter.finish()

        XCTAssertEqual(result.outputTokens, 10)
        XCTAssertEqual(result.promptTokens, 4)
        XCTAssertFalse(result.isEstimated)
        XCTAssertTrue(result.finished)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.authoritativeTPS ?? -1, 40, accuracy: 0.000_001)
    }

    func testZeroAuthoritativeCountReplacesEstimate() async {
        let counter = TokenCounter()
        await counter.ingestStream(#"{"response":"estimated fragment","done":false}"#)
        await counter.ingestStream(
            #"{"done":true,"eval_count":0,"eval_duration":1000000000}"#)
        let result = await counter.finish()

        XCTAssertEqual(result.outputTokens, 0)
        XCTAssertFalse(result.isEstimated)
        XCTAssertEqual(result.authoritativeTPS, 0)
        XCTAssertTrue(result.liveTPS.isFinite)
    }

    func testMissingOrInvalidEvaluationDurationDoesNotProduceAnAuthoritativeRate() async {
        for body in [
            #"{"done":true,"eval_count":3}"#,
            #"{"done":true,"eval_count":3,"eval_duration":0}"#,
            #"{"done":true,"eval_count":3,"eval_duration":-100}"#,
        ] {
            let counter = TokenCounter()
            await counter.ingestStream(body)
            let result = await counter.finish()

            XCTAssertTrue(result.finished)
            XCTAssertNil(result.authoritativeTPS, body)
            XCTAssertTrue(result.liveTPS.isFinite, body)
            XCTAssertTrue(result.elapsed.isFinite, body)
        }
    }

    func testCompletionWithoutTokenCountRetainsEstimateAndHasNoAuthoritativeRate() async {
        let counter = TokenCounter()
        await counter.ingestStream(#"{"response":"Hello","done":false}"#)
        await counter.ingestStream(#"{"done":true,"eval_duration":1000000000}"#)
        let result = await counter.finish()

        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.outputTokens, 1)
        XCTAssertTrue(result.isEstimated)
        XCTAssertNil(result.authoritativeTPS)
        XCTAssertTrue(result.liveTPS.isFinite)
    }

    func testMalformedChunkDoesNotPreventSubsequentValidStatistics() async {
        let counter = TokenCounter()
        await counter.ingestStream("this is not json")
        await counter.ingestStream(#"{"response":"Hello","done":false}"#)
        let live = await counter.live()
        XCTAssertEqual(live.outputTokens, 1)
        XCTAssertFalse(live.finished)

        await counter.ingestStream(
            #"{"done":true,"eval_count":7,"eval_duration":1000000000}"#)
        let result = await counter.finish()
        XCTAssertEqual(result.outputTokens, 7)
        XCTAssertNil(result.error)
    }

    func testPrematureEOFIsTerminalErrorAndRetainsPartialEstimate() async {
        let counter = TokenCounter()
        await counter.ingestStream(#"{"response":"partial","done":false}"#)
        let result = await counter.finish()

        XCTAssertTrue(result.finished)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.outputTokens, 1)
        XCTAssertTrue(result.isEstimated)
        XCTAssertNil(result.authoritativeTPS)
    }

    func testMalformedOnlyAndEmptyResponsesCannotCompleteSuccessfully() async {
        for body in ["", "not JSON", #"{"response":"unterminated"#] {
            let counter = TokenCounter()
            await counter.ingestStream(body)
            let result = await counter.finish()

            XCTAssertTrue(result.finished)
            XCTAssertNotNil(result.error, body)
            XCTAssertEqual(result.outputTokens, 0)
            XCTAssertNil(result.authoritativeTPS)
        }
    }

    func testNonStreamingBodyWithoutCompletionFlagCannotCompleteSuccessfully() async {
        let counter = TokenCounter()
        await counter.ingestNonStreaming(
            #"{"response":"partial","done":false,"eval_count":7,"eval_duration":1000000000}"#)
        let result = await counter.finish()

        XCTAssertTrue(result.finished)
        XCTAssertNotNil(result.error)
        XCTAssertNil(result.authoritativeTPS)
    }

    func testOllamaErrorImmediatelyTerminatesAndIgnoresLaterSuccess() async {
        let counter = TokenCounter()
        await counter.ingestStream(#"{"response":"partial","done":false}"#)
        await counter.ingestStream(#"{"error":"model unavailable"}"#)
        let failed = await counter.live()

        XCTAssertTrue(failed.finished)
        XCTAssertEqual(failed.error, "model unavailable")
        XCTAssertEqual(failed.outputTokens, 1)

        await counter.ingestStream(
            #"{"done":true,"eval_count":99,"eval_duration":1000000000}"#)
        let result = await counter.finish()
        XCTAssertEqual(result.error, failed.error)
        XCTAssertEqual(result.outputTokens, failed.outputTokens)
        XCTAssertNil(result.authoritativeTPS)
    }

    func testFinishIsIdempotentAndLateChunksCannotChangeTerminalSnapshot() async {
        let clock = TokenCounterTestClock()
        let counter = TokenCounter(clock: { clock.now() })
        await counter.ingestStream(#"{"model":"llama3","response":"Hello","done":false}"#)
        clock.advance(by: 2)
        await counter.ingestStream(
            #"{"done":true,"eval_count":3,"prompt_eval_count":8,"eval_duration":1000000000}"#)
        let first = await counter.finish()

        clock.advance(by: 20)
        await counter.ingestStream(#"{"response":"late fragment","done":false}"#)
        await counter.ingestNonStreaming(
            #"{"model":"late-model","done":true,"eval_count":999,"prompt_eval_count":999,"eval_duration":1000000000}"#
        )
        let second = await counter.finish()

        XCTAssertTrue(first.finished)
        XCTAssertTrue(second.finished)
        XCTAssertEqual(second.model, first.model)
        XCTAssertEqual(second.outputTokens, first.outputTokens)
        XCTAssertEqual(second.promptTokens, first.promptTokens)
        XCTAssertEqual(second.isEstimated, first.isEstimated)
        XCTAssertEqual(second.liveTPS, first.liveTPS)
        XCTAssertEqual(second.authoritativeTPS, first.authoritativeTPS)
        XCTAssertEqual(second.elapsed, first.elapsed)
        XCTAssertEqual(second.timestamp, first.timestamp)
        XCTAssertEqual(second.error, first.error)
    }

    private func assertEqualSnapshots(
        _ actual: GenerationSnapshot, _ expected: GenerationSnapshot, payload: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.model, expected.model, payload, file: file, line: line)
        XCTAssertEqual(actual.outputTokens, expected.outputTokens, payload, file: file, line: line)
        XCTAssertEqual(actual.promptTokens, expected.promptTokens, payload, file: file, line: line)
        XCTAssertEqual(actual.isEstimated, expected.isEstimated, payload, file: file, line: line)
        XCTAssertEqual(actual.liveTPS, expected.liveTPS, payload, file: file, line: line)
        XCTAssertEqual(
            actual.authoritativeTPS, expected.authoritativeTPS, payload, file: file, line: line)
        XCTAssertEqual(actual.finished, expected.finished, payload, file: file, line: line)
        XCTAssertEqual(actual.elapsed, expected.elapsed, payload, file: file, line: line)
        XCTAssertEqual(actual.error, expected.error, payload, file: file, line: line)
        XCTAssertEqual(actual.timestamp, expected.timestamp, payload, file: file, line: line)
    }
}

/// Synchronous clock injection avoids sleeps and is safe to capture in a
/// Sendable closure while the counter runs on its actor.
private final class TokenCounterTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 100)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }
}
