import Foundation
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

    func testByteFramingScansLargeUnfinishedRecordOnlyOnceUnderOneByteFragmentation() {
        var parser = SSEParser()
        let payload =
            #"{"response":""# + String(repeating: "x", count: 64 * 1024)
            + #"","done":false}"#
        let bytes = Array(payload.utf8)
        var prematureRecords: [Data] = []

        // Count deterministic delimiter work instead of relying on machine-specific timing.
        // Rescanning the unfinished prefix for every read would require quadratic work.
        for byte in bytes {
            prematureRecords += parser.feedBytes(CollectionOfOne(byte))
        }

        XCTAssertTrue(prematureRecords.isEmpty)
        XCTAssertEqual(parser.scannedByteCount, bytes.count)
        XCTAssertEqual(parser.feedBytes(CollectionOfOne(UInt8(0x0A))), [Data(bytes)])
        XCTAssertEqual(parser.scannedByteCount, bytes.count + 1)
        XCTAssertTrue(parser.finishBytes().isEmpty)
        XCTAssertEqual(parser.scannedByteCount, bytes.count + 1)
    }

    func testByteFramingConsumesManyRecordsAndPartialTailsWithLinearScanWork() {
        var parser = SSEParser()
        let payloads = (0..<1024).map { index in
            #"{"response":"record "# + String(index) + #" café 🦙","done":false}"#
        }
        let wire = Array((payloads.joined(separator: "\n") + "\n").utf8)
        let chunkSizes = [1, 7, 113, 3, 64]
        var records: [Data] = []
        var offset = 0
        var chunkIndex = 0

        while offset < wire.count {
            let end = min(offset + chunkSizes[chunkIndex % chunkSizes.count], wire.count)
            // Nonzero ArraySlice indices also exercise the generic collection API.
            records += parser.feedBytes(wire[offset..<end])
            XCTAssertEqual(parser.scannedByteCount, end)
            offset = end
            chunkIndex += 1
        }

        XCTAssertEqual(records, payloads.map { Data($0.utf8) })
        XCTAssertTrue(parser.finishBytes().isEmpty)
        XCTAssertEqual(parser.scannedByteCount, wire.count)

        let next = #"{"done":true}"#
        XCTAssertTrue(parser.feedBytes(Data(next.utf8)).isEmpty)
        XCTAssertEqual(parser.finishBytes(), [Data(next.utf8)])
        XCTAssertTrue(parser.finishBytes().isEmpty)
        XCTAssertEqual(parser.scannedByteCount, wire.count + next.utf8.count)
    }

    func testByteFramingPreservesUTF8AcrossEveryPossibleByteSplit() {
        let payload = #"{"message":{"content":"👩🏽‍💻 naïve 中文"},"done":false}"#
        let bytes = Array("data: \(payload)\r\n".utf8)

        for split in 0...bytes.count {
            var parser = SSEParser()
            var records = parser.feedBytes(bytes[..<split])
            records += parser.feedBytes(bytes[split...])
            records += parser.finishBytes()

            XCTAssertEqual(records, [Data(payload.utf8)], "Failed at byte split \(split)")
            XCTAssertEqual(parser.scannedByteCount, bytes.count)
        }
    }

    func testByteFramingPreservesCRLFDataPrefixAndUnicodeWhitespaceBehavior() {
        let first = #"{"response":" café 🦙 ","done":false}"#
        let second = #"{"done":true}"#
        let wire =
            "\u{2003}\u{00A0}data:\u{2009}\(first)\u{3000}\r\n"
            + "\r\n: heartbeat\r\nevent: token\r\ndata: [DONE]\r\n"
            + " \tdata:\(second)\t\r\n\u{2003}\u{00A0}\r\n"
        var byteParser = SSEParser()
        var stringParser = SSEParser()

        XCTAssertEqual(
            byteParser.feedBytes(Data(wire.utf8)), [Data(first.utf8), Data(second.utf8)])
        XCTAssertEqual(stringParser.feed(wire), [first, second])
        XCTAssertTrue(byteParser.finishBytes().isEmpty)
        XCTAssertTrue(stringParser.finish().isEmpty)
    }

    func testByteFramingFinishTrimsUnicodeWhitespaceAndEmitsOnlyOnce() {
        var parser = SSEParser()
        let payload = #"{"response":"fin 🦙","done":true}"#
        let wire = "\u{2003}data:\u{00A0}\(payload)\u{3000}"

        XCTAssertTrue(parser.feedBytes(Data(wire.utf8)).isEmpty)
        XCTAssertEqual(parser.finishBytes(), [Data(payload.utf8)])
        XCTAssertTrue(parser.finishBytes().isEmpty)
        XCTAssertTrue(parser.feedBytes(Data(" \t\u{2003}\u{00A0}\r".utf8)).isEmpty)
        XCTAssertTrue(parser.finishBytes().isEmpty)
    }

    func testByteFramingDropsInvalidUTF8RecordsAndRecoversAtNextLine() {
        let prefix = Array(#"{"response":""#.utf8)
        let suffix = Array(#"","done":false}"#.utf8)
        let valid = #"{"response":"recovered 🦙","done":true}"#
        let malformedRecords: [[UInt8]] = [
            prefix + [0xFF] + suffix,
            prefix + [0xC0, 0xAF] + suffix,  // Overlong UTF-8 encoding.
            prefix + [0xED, 0xA0, 0x80] + suffix,  // UTF-16 surrogate encoded as UTF-8.
            prefix + [0xF0, 0x9F] + suffix,  // Interrupted four-byte scalar.
            Array(valid.utf8) + [0xC2],  // Invalid trailing byte must not be trimmed away.
            Array("data: ".utf8) + prefix + [0xFF] + suffix,
        ]

        for (index, malformed) in malformedRecords.enumerated() {
            var byteParser = SSEParser()
            var stringParser = SSEParser()
            let wire = malformed + [0x0A] + Array(valid.utf8) + [0x0A]

            XCTAssertEqual(
                byteParser.feedBytes(wire), [Data(valid.utf8)], "Malformed case \(index)")
            XCTAssertEqual(stringParser.feed(wire), [valid], "Malformed case \(index)")
            XCTAssertTrue(byteParser.finishBytes().isEmpty)
            XCTAssertTrue(stringParser.finish().isEmpty)
        }
    }

    func testByteFramingFinishDropsIncompleteUTF8AndClearsThePendingRecord() {
        var parser = SSEParser()
        let incomplete = Array(#"{"response":""#.utf8) + [0xF0, 0x9F, 0xA6]
        let next = #"{"done":true}"#

        XCTAssertTrue(parser.feedBytes(incomplete).isEmpty)
        XCTAssertTrue(parser.finishBytes().isEmpty)
        XCTAssertTrue(parser.finishBytes().isEmpty)
        XCTAssertEqual(parser.feedBytes(Data("\(next)\n".utf8)), [Data(next.utf8)])
        XCTAssertEqual(parser.scannedByteCount, incomplete.count + next.utf8.count + 1)
    }
}
