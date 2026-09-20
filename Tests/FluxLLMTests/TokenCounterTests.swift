import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class TokenCounterTests: XCTestCase {
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
