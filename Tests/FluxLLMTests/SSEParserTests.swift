import XCTest

@testable import FluxLLM

final class SSEParserTests: XCTestCase {
    func testExtractsMultipleNativeRecordsAndSkipsBlankLines() {
        var parser = SSEParser()
        let first = #"{"model":"llama3","response":"Hello","done":false}"#
        let second = #"{"response":" world","done":false}"#
        let final = #"{"done":true,"eval_count":2}"#

        XCTAssertEqual(parser.feed("\n\(first)\n\n\(second)\n\(final)\n"), [first, second, final])
        XCTAssertTrue(parser.finish().isEmpty)
    }

    func testPreservesUTF8AcrossEveryPossibleByteSplit() {
        let first = #"{"message":{"content":"café 🦙 東京"},"done":false}"#
        let final = #"{"done":true,"eval_count":3}"#
        let bytes = Array("\(first)\n\(final)\n".utf8)

        for split in 0...bytes.count {
            var parser = SSEParser()
            var records = parser.feed(Array(bytes[..<split]))
            records += parser.feed(Array(bytes[split...]))
            records += parser.finish()

            XCTAssertEqual(records, [first, final], "Failed at byte split \(split)")
        }
    }

    func testPreservesUTF8WhenEveryReadContainsOnlyOneByte() {
        var parser = SSEParser()
        let payload = #"{"response":"👩🏽‍💻 naïve 中文","done":false}"#
        var records: [String] = []

        for byte in "\(payload)\n".utf8 {
            records += parser.feed([byte])
        }

        XCTAssertEqual(records, [payload])
        XCTAssertTrue(parser.finish().isEmpty)
    }

    func testBuffersIncompleteStringRecordUntilNewlineArrives() {
        var parser = SSEParser()

        XCTAssertTrue(parser.feed(#"{"response":"Hel"#).isEmpty)
        XCTAssertTrue(parser.feed(#"lo","done":false}"#).isEmpty)
        XCTAssertEqual(parser.feed("\n"), [#"{"response":"Hello","done":false}"#])
    }

    func testAcceptsCRLFAndSSEDataPrefix() {
        var parser = SSEParser()
        let first = #"{"response":"Hello","done":false}"#
        let final = #"{"done":true,"eval_count":1}"#

        XCTAssertEqual(parser.feed("data: \(first)\r"), [])
        XCTAssertEqual(parser.feed("\n\r\ndata:\(final)\r\n\r\n"), [first, final])
        XCTAssertTrue(parser.finish().isEmpty)
    }

    func testFinishEmitsUnterminatedUTF8RecordOnlyOnce() {
        var parser = SSEParser()
        let payload = #"{"response":"fin 🦙","done":true,"eval_count":2}"#

        XCTAssertTrue(parser.feed(Array(payload.utf8)).isEmpty)
        XCTAssertEqual(parser.finish(), [payload])
        XCTAssertTrue(parser.finish().isEmpty)
    }

    func testFinishDoesNotEmitWhitespaceAsARecord() {
        var parser = SSEParser()

        XCTAssertTrue(parser.feed(" \t\r").isEmpty)
        XCTAssertTrue(parser.finish().isEmpty)
        XCTAssertTrue(parser.finish().isEmpty)
    }
}
