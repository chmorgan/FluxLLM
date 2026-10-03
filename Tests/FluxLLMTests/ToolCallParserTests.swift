import Foundation
import NIO
import XCTest

@testable import FluxLLM

final class ToolCallParserTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testDecodedRecordsPreserveIdentityAndMalformedShapeHandling() {
        var strings = ToolCallParser()
        var decoded = ToolCallParser()
        var foundation = ToolCallParser()
        let payloads = [
            #"{"message":{"content":"Hello","tool_calls":[{"function":{"index":0,"name":"search","arguments":"{"}}]}}"#,
            #"{"message":{"tool_calls":[null,3,{"id":"new","function":{"name":"read","arguments":{}}}]}}"#,
            #"{"message":{"tool_calls":"invalid"}}"#,
            #"{"message":{"tool_calls":[{"id":"call-a","function":{"index":0,"name":"search","arguments":{}}}]}}"#,
            #"{"message":{"tool_calls":[{"id":"call-b","function":{"index":0,"name":"search","arguments":{}}}]}}"#,
            #"{"message":{"tool_calls":[{"function":{"name":"anonymous","arguments":{}}},{"function":{"index":true,"name":"invalid","arguments":"{"}}]}}"#,
        ]
        var observedNames: [String?] = []
        for (index, payload) in payloads.enumerated() {
            let timestamp = origin.addingTimeInterval(Double(index))
            let expected = strings.ingest(payload, at: timestamp)
            let object =
                (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
            let actual = object.map { decoded.ingest($0, at: timestamp) } ?? []
            let borrowed =
                DecodedGenerationRecord(data: Data(payload.utf8))
                .map { foundation.ingest($0, at: timestamp) } ?? []
            XCTAssertEqual(actual.map(\.kind), expected.map(\.kind), payload)
            XCTAssertEqual(actual.map(\.name), expected.map(\.name), payload)
            XCTAssertEqual(actual.map(\.callID), expected.map(\.callID), payload)
            XCTAssertEqual(actual.map(\.timestamp), expected.map(\.timestamp), payload)
            XCTAssertEqual(borrowed.map(\.kind), actual.map(\.kind), payload)
            XCTAssertEqual(borrowed.map(\.name), actual.map(\.name), payload)
            XCTAssertEqual(borrowed.map(\.callID), actual.map(\.callID), payload)
            XCTAssertEqual(borrowed.map(\.timestamp), actual.map(\.timestamp), payload)
            observedNames.append(contentsOf: actual.map(\.name))
        }
        XCTAssertEqual(observedNames, ["search", "search", "anonymous"])
    }

    func testBorrowedMalformedCallArrayCannotConsumeAnIdentity() throws {
        var parser = ToolCallParser()
        let malformed = try XCTUnwrap(
            DecodedGenerationRecord(
                data: Data(
                    #"{"message":{"tool_calls":[{"id":"a","function":{"name":"read_🌊","arguments":{}}},null]}}"#
                        .utf8)))
        XCTAssertTrue(parser.ingest(malformed, at: origin).isEmpty)

        let valid = try XCTUnwrap(
            DecodedGenerationRecord(
                data: Data(
                    #"{"message":{"tool_calls":[{"id":"a","function":{"name":"read_🌊","arguments":{}}}]}}"#
                        .utf8)))
        let events = parser.ingest(valid, at: origin.addingTimeInterval(1))
        XCTAssertEqual(events.map(\.name), ["read_🌊"])
        XCTAssertEqual(events.map(\.callID), ["a"])
        XCTAssertTrue(parser.ingest(valid, at: origin.addingTimeInterval(2)).isEmpty)
    }

    func testNativeDictionaryShapesRetainStrictStringKeys() {
        var parser = ToolCallParser()
        let invalidArguments: [Int: String] = [1: "not a JSON key"]
        let anonymous: [String: Any] = [
            "function": ["name": "invalid", "arguments": invalidArguments] as [String: Any]
        ]
        XCTAssertTrue(
            parser.ingest(
                [
                    "message": ["tool_calls": [anonymous]]
                ], at: origin
            ).isEmpty)

        let mixed: [Any] = [
            ["id": "a", "function": ["name": "read", "arguments": [String: Any]()]]
                as [String: Any],
            [1: "not a JSON key"],
        ]
        XCTAssertTrue(
            parser.ingest(
                [
                    "message": ["tool_calls": mixed]
                ], at: origin
            ).isEmpty)
        let valid: [String: Any] = [
            "message": [
                "tool_calls": [
                    ["id": "a", "function": ["name": "read", "arguments": [String: Any]()]]
                        as [String: Any]
                ]
            ]
        ]
        XCTAssertEqual(parser.ingest(valid, at: origin).map(\.callID), ["a"])
    }

    func testEscapedDuplicateToolKeysPreserveSelectionAndMalformedArrayAtomicity() throws {
        let call =
            #"{"i\u0064":"a","id":"b","funct\u0069on":{"na\u006de":"read_🌊","name":"other","argu\u006dents":{}}}"#
        let prefix = #"{"mess\u0061ge":{"tool\u005fcalls":["#
        let valid = prefix + call + "]}}"
        let malformed = prefix + call + ",null]}}"
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        let calls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let selectedCall = try XCTUnwrap(calls.first)
        let function = try XCTUnwrap(selectedCall["function"] as? [String: Any])
        let expectedName = try XCTUnwrap(function["name"] as? String)
        let expectedID = try XCTUnwrap(selectedCall["id"] as? String)
        var strings = ToolCallParser()
        var native = ToolCallParser()
        var borrowed = ToolCallParser()

        for (index, payload) in [malformed, valid, valid].enumerated() {
            let timestamp = origin.addingTimeInterval(Double(index))
            let dictionary = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            let record = try XCTUnwrap(DecodedGenerationRecord(data: Data(payload.utf8)))
            let results = [
                strings.ingest(payload, at: timestamp),
                native.ingest(dictionary, at: timestamp),
                borrowed.ingest(record, at: timestamp),
            ]
            for events in results {
                if index == 1 {
                    XCTAssertEqual(events.map(\.kind), [.call])
                    XCTAssertEqual(events.map(\.name), [expectedName])
                    XCTAssertEqual(events.map(\.callID), [expectedID])
                    XCTAssertEqual(events.map(\.timestamp), [timestamp])
                } else {
                    XCTAssertTrue(events.isEmpty, payload)
                }
            }
        }
    }

    func testEmitsEachIdentifiedCallOnceWithNameAndObservationTime() {
        var parser = ToolCallParser()
        let payload =
            #"{"message":{"tool_calls":[{"id":"call-a","function":{"name":"read_file","arguments":{"path":"a.swift"}}},{"id":"call-b","function":{"name":"read_file","arguments":{"path":"b.swift"}}}]}}"#

        let events = parser.ingest(payload, at: origin)

        XCTAssertEqual(events.map(\.kind), [.call, .call])
        XCTAssertEqual(events.map(\.name), ["read_file", "read_file"])
        XCTAssertEqual(events.map(\.callID), ["call-a", "call-b"])
        XCTAssertEqual(events.map(\.timestamp), [origin, origin])
        XCTAssertEqual(Set(events.map(\.id)).count, 2)
        XCTAssertTrue(parser.ingest(payload, at: origin.addingTimeInterval(1)).isEmpty)
    }

    func testIdentifiedCallWaitsForNameButDoesNotWaitForCompletedArguments() {
        var parser = ToolCallParser()
        XCTAssertTrue(
            parser.ingest(
                #"{"message":{"tool_calls":[{"id":"call-a","function":{"name":"","arguments":"{"}}]}}"#,
                at: origin
            ).isEmpty)

        let timestamp = origin.addingTimeInterval(1)
        let events = parser.ingest(
            #"{"message":{"tool_calls":[{"id":"call-a","function":{"name":"read_file","arguments":"{\"path\":"}}]}}"#,
            at: timestamp)

        XCTAssertEqual(events.map(\.name), ["read_file"])
        XCTAssertEqual(events.map(\.timestamp), [timestamp])
        XCTAssertTrue(
            parser.ingest(
                #"{"message":{"tool_calls":[{"id":"call-a","function":{"name":"read_file","arguments":{"path":"a.swift"}}}]}}"#,
                at: timestamp.addingTimeInterval(1)
            ).isEmpty)
    }

    func testFunctionIndexZeroIsAnIdentityAndRepeatedIndicesAreSuppressed() {
        var parser = ToolCallParser()
        let payload =
            #"{"message":{"tool_calls":[{"function":{"index":0,"name":"search","arguments":"{"}},{"function":{"index":1,"name":"search","arguments":"{"}}]}}"#

        let events = parser.ingest(payload, at: origin)

        XCTAssertEqual(events.map(\.name), ["search", "search"])
        XCTAssertTrue(parser.ingest(payload, at: origin.addingTimeInterval(1)).isEmpty)
    }

    func testCallIDTakesPrecedenceOverFunctionIndex() {
        var parser = ToolCallParser()
        let events = parser.ingest(
            #"{"message":{"tool_calls":[{"id":"call-a","function":{"index":0,"name":"search","arguments":{}}},{"id":"call-b","function":{"index":0,"name":"search","arguments":{}}}]}}"#,
            at: origin)

        XCTAssertEqual(events.map(\.callID), ["call-a", "call-b"])
        XCTAssertTrue(
            parser.ingest(
                #"{"message":{"tool_calls":[{"id":"call-a","function":{"index":9,"name":"search","arguments":{}}}]}}"#,
                at: origin.addingTimeInterval(1)
            ).isEmpty)
    }

    func testEmptyCallIDFallsBackToFunctionIndex() {
        var parser = ToolCallParser()
        let payload =
            #"{"message":{"tool_calls":[{"id":"","function":{"index":0,"name":"search","arguments":"{"}}]}}"#

        XCTAssertEqual(parser.ingest(payload, at: origin).count, 1)
        XCTAssertTrue(parser.ingest(payload, at: origin).isEmpty)
    }

    func testIndexOnlyCallAdoptsLaterExplicitIDWithoutEmittingAgain() {
        var parser = ToolCallParser()
        let first = parser.ingest(
            #"{"message":{"tool_calls":[{"function":{"index":0,"name":"search","arguments":"{"}}]}}"#,
            at: origin)
        let identified =
            #"{"message":{"tool_calls":[{"id":"call-a","function":{"index":0,"name":"search","arguments":{}}}]}}"#

        XCTAssertEqual(first.count, 1)
        XCTAssertNil(first.first?.callID)
        XCTAssertTrue(parser.ingest(identified, at: origin.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(parser.ingest(identified, at: origin.addingTimeInterval(2)).isEmpty)
        XCTAssertTrue(
            parser.ingest(
                #"{"message":{"tool_calls":[{"id":"call-a","function":{"name":"search","arguments":{}}}]}}"#,
                at: origin.addingTimeInterval(3)
            ).isEmpty)
    }

    func testExplicitIDAndIndexSuppressLaterIndexOnlyContinuation() {
        var parser = ToolCallParser()
        let first = parser.ingest(
            #"{"message":{"tool_calls":[{"id":"call-a","function":{"index":0,"name":"search","arguments":"{"}}]}}"#,
            at: origin)

        XCTAssertEqual(first.map(\.callID), ["call-a"])
        XCTAssertTrue(
            parser.ingest(
                #"{"message":{"tool_calls":[{"function":{"index":0,"name":"search","arguments":{}}}]}}"#,
                at: origin.addingTimeInterval(1)
            ).isEmpty)
    }

    func testAdoptedIndexDoesNotCollapseAnotherExplicitIDAtTheSameIndex() {
        var parser = ToolCallParser()
        XCTAssertEqual(
            parser.ingest(
                #"{"message":{"tool_calls":[{"function":{"index":0,"name":"search","arguments":{}}}]}}"#,
                at: origin
            ).count, 1)
        let events = parser.ingest(
            #"{"message":{"tool_calls":[{"id":"call-a","function":{"index":0,"name":"search","arguments":{}}},{"id":"call-b","function":{"index":0,"name":"search","arguments":{}}}]}}"#,
            at: origin.addingTimeInterval(1))

        XCTAssertEqual(events.map(\.callID), ["call-b"])
    }

    func testKnownIDCanGainAnIndexBeforeIndexOnlyContinuation() {
        var parser = ToolCallParser()
        XCTAssertEqual(
            parser.ingest(
                #"{"message":{"tool_calls":[{"id":"call-a","function":{"name":"search","arguments":{}}}]}}"#,
                at: origin
            ).count, 1)
        XCTAssertTrue(
            parser.ingest(
                #"{"message":{"tool_calls":[{"id":"call-a","function":{"index":0,"name":"search","arguments":{}}}]}}"#,
                at: origin.addingTimeInterval(1)
            ).isEmpty)
        XCTAssertTrue(
            parser.ingest(
                #"{"message":{"tool_calls":[{"function":{"index":0,"name":"search","arguments":{}}}]}}"#,
                at: origin.addingTimeInterval(2)
            ).isEmpty)
    }

    func testInvalidFunctionIndicesCannotIdentifyIncompleteCalls() {
        var parser = ToolCallParser()
        let events = parser.ingest(
            #"{"message":{"tool_calls":[{"function":{"index":true,"name":"search","arguments":"{"}},{"function":{"index":-1,"name":"search","arguments":"{"}},{"function":{"index":0.5,"name":"search","arguments":"{"}},{"function":{"index":"0","name":"search","arguments":"{"}}]}}"#,
            at: origin)

        XCTAssertTrue(events.isEmpty)
    }

    func testIdenticalAnonymousCompleteRecordsRemainDistinctCalls() {
        var parser = ToolCallParser()
        let payload =
            #"{"message":{"tool_calls":[{"function":{"name":"read_file","arguments":{"path":"a.swift"}}},{"function":{"name":"read_file","arguments":{"path":"a.swift"}}}]}}"#

        let first = parser.ingest(payload, at: origin)
        let next = parser.ingest(payload, at: origin.addingTimeInterval(1))

        XCTAssertEqual(first.map(\.name), ["read_file", "read_file"])
        XCTAssertEqual(next.map(\.name), ["read_file", "read_file"])
        XCTAssertTrue(first.allSatisfy { $0.callID == nil })
        XCTAssertEqual(Set((first + next).map(\.id)).count, 4)
    }

    func testAnonymousCallsRequireNameAndDictionaryArguments() {
        var parser = ToolCallParser()
        let events = parser.ingest(
            #"{"message":{"tool_calls":[{"function":{"name":"","arguments":{}}},{"function":{"arguments":{}}},{"function":{"name":"search"}},{"function":{"name":"search","arguments":"{}"}},{"function":{"name":"search","arguments":[]}},{"function":{"name":"search","arguments":{}}}]}}"#,
            at: origin)

        XCTAssertEqual(events.map(\.name), ["search"])
    }

    func testMalformedAndNonNativeResponseShapesDoNotEmitCalls() {
        var parser = ToolCallParser()
        for payload in [
            "not JSON",
            "[]",
            #"{"message":{"tool_calls":"invalid"}}"#,
            #"{"message":{"tool_calls":[null,3,{}, {"function":null}]}}"#,
            #"{"tool_calls":[{"id":"a","function":{"name":"search","arguments":{}}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"id":"a","function":{"name":"search","arguments":"{}"}}]}}]}"#,
        ] {
            XCTAssertTrue(parser.ingest(payload, at: origin).isEmpty, payload)
        }
    }

    func testNewResponseParserAllowsPreviouslySeenIDAgain() {
        let payload =
            #"{"message":{"tool_calls":[{"id":"call-a","function":{"name":"search","arguments":{}}}]}}"#
        var firstRequest = ToolCallParser()
        var nextRequest = ToolCallParser()

        XCTAssertEqual(firstRequest.ingest(payload, at: origin).count, 1)
        XCTAssertTrue(firstRequest.ingest(payload, at: origin).isEmpty)
        XCTAssertEqual(nextRequest.ingest(payload, at: origin.addingTimeInterval(1)).count, 1)
    }

    func testResultSubmissionsIncludeOnlyLatestTrailingToolBatch() {
        let body = ByteBuffer(
            string:
                #"{"messages":[{"role":"assistant","tool_calls":[{"id":"old","function":{"name":"search","arguments":{}}}]},{"role":"tool","tool_name":"search","tool_call_id":"old","content":"old result"},{"role":"assistant","content":"Next step"},{"role":"tool","tool_name":"read_file","tool_call_id":"call-a","content":"file contents"},{"role":"tool","name":"search","tool_call_id":"call-b","content":"search results"}]}"#
        )

        let events = ToolCallParser.resultSubmissions(
            path: "/api/chat?trace=1", body: body, at: origin)

        XCTAssertEqual(events.map(\.kind), [.resultSubmission, .resultSubmission])
        XCTAssertEqual(events.map(\.name), ["read_file", "search"])
        XCTAssertEqual(events.map(\.callID), ["call-a", "call-b"])
        XCTAssertEqual(events.map(\.timestamp), [origin, origin])
        XCTAssertEqual(Set(events.map(\.id)).count, 2)
    }

    func testRequestHistoryAndAssistantCallsDoNotBecomeNewToolEvents() {
        for payload in [
            #"{"messages":[{"role":"tool","tool_name":"search","content":"old result"},{"role":"user","content":"Try again"}]}"#,
            #"{"messages":[{"role":"tool","tool_name":"search","content":"old result"},{"role":"assistant","content":"Done"}]}"#,
            #"{"messages":[{"role":"assistant","tool_calls":[{"id":"a","function":{"name":"search","arguments":{}}}]}]}"#,
        ] {
            XCTAssertTrue(
                ToolCallParser.resultSubmissions(
                    path: "/api/chat", body: ByteBuffer(string: payload), at: origin
                ).isEmpty,
                payload)
        }
    }

    func testToolResultsWithoutOptionalNamesOrIdentifiersStillEmit() {
        let events = ToolCallParser.resultSubmissions(
            path: "/api/chat",
            body: ByteBuffer(string: #"{"messages":[{"role":"tool","content":"result"}]}"#),
            at: origin)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .resultSubmission)
        XCTAssertNil(events.first?.name)
        XCTAssertNil(events.first?.callID)
    }

    func testResultExtractionPreservesRequestBodyAndReadableIndices() {
        var body = ByteBuffer(string: "prefix")
        body.writeString(#"{"messages":[{"role":"tool","tool_name":"read_file","content":"秘密"}]}"#)
        body.moveReaderIndex(forwardBy: "prefix".utf8.count)
        let original = body
        let readerIndex = body.readerIndex
        let writerIndex = body.writerIndex

        let events = ToolCallParser.resultSubmissions(path: "/api/chat", body: body, at: origin)

        XCTAssertEqual(events.map(\.name), ["read_file"])
        XCTAssertEqual(body, original)
        XCTAssertEqual(body.readerIndex, readerIndex)
        XCTAssertEqual(body.writerIndex, writerIndex)
    }

    func testResultExtractionIgnoresOtherPathsAndMalformedRequests() {
        let body = ByteBuffer(string: #"{"messages":[{"role":"tool","content":"result"}]}"#)
        for path in ["/api/generate", "/api/tags", "/v1/chat/completions", "/api/chat/extra"] {
            XCTAssertTrue(
                ToolCallParser.resultSubmissions(path: path, body: body, at: origin).isEmpty,
                path)
        }
        for payload in ["not JSON", "[]", "{}", #"{"messages":{}}"#, #"{"messages":[]}"#] {
            XCTAssertTrue(
                ToolCallParser.resultSubmissions(
                    path: "/api/chat", body: ByteBuffer(string: payload), at: origin
                ).isEmpty,
                payload)
        }
    }
}
