import Foundation

/// Reassembles complete NDJSON records before UTF-8 decoding. The scan cursor
/// visits each incoming byte once, including a long record split across reads.
struct SSEParser {
    private var bytes: [UInt8] = []
    private var recordStart = 0
    private var scanPosition = 0
    private(set) var scannedByteCount = 0

    mutating func feed(_ chunk: String) -> [String] {
        feedBytes(chunk.utf8).map { String(decoding: $0, as: UTF8.self) }
    }

    mutating func feed(_ chunk: [UInt8]) -> [String] {
        feedBytes(chunk).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The proxy passes ByteBuffer.readableBytesView directly. Complete records
    /// become JSON input Data without an intermediate array or UTF-8 String.
    mutating func feedBytes<Bytes: Collection>(_ chunk: Bytes) -> [Data]
    where Bytes.Element == UInt8 {
        bytes.append(contentsOf: chunk)
        var results: [Data] = []
        while scanPosition < bytes.count {
            let index = scanPosition
            scanPosition += 1
            scannedByteCount += 1
            if bytes[index] == 0x0A {
                if let payload = Self.payload(bytes[recordStart..<index]) {
                    results.append(payload)
                }
                recordStart = scanPosition
            }
        }
        compactConsumedBytes()
        return results
    }

    mutating func finish() -> [String] {
        finishBytes().map { String(decoding: $0, as: UTF8.self) }
    }

    mutating func finishBytes() -> [Data] {
        defer {
            bytes.removeAll(keepingCapacity: true)
            recordStart = 0
            scanPosition = 0
        }
        return Self.payload(bytes[recordStart...]).map { [$0] } ?? []
    }

    private mutating func compactConsumedBytes() {
        if recordStart == bytes.count {
            bytes.removeAll(keepingCapacity: true)
            recordStart = 0
            scanPosition = 0
        } else if recordStart >= 4_096, recordStart >= bytes.count / 2 {
            // Copy a remaining tail only after consuming at least as many
            // bytes, so repeated small records cannot repeatedly shift it.
            bytes.removeFirst(recordStart)
            scanPosition -= recordStart
            recordStart = 0
        }
    }

    private static func payload(_ source: ArraySlice<UInt8>) -> Data? {
        var bytes = trimmingASCIIWhitespace(source)
        guard !bytes.isEmpty else { return nil }
        // Unicode boundary whitespace is uncommon for NDJSON, but the legacy
        // framing accepted Foundation's full whitespace set. Keep that path.
        if bytes.first! >= 0x80 || bytes.last! >= 0x80 {
            return unicodePayload(source)
        }
        if bytes.starts(with: [0x64, 0x61, 0x74, 0x61, 0x3A]) {  // data:
            bytes = trimmingASCIIWhitespace(bytes.dropFirst(5))
            guard !bytes.isEmpty else { return nil }
            if bytes.first! >= 0x80 || bytes.last! >= 0x80 {
                return unicodePayload(source)
            }
        }
        // SSE compatibility is tolerated framing, not another API backend.
        if bytes.first == 0x7B, bytes.count > 1, bytes[bytes.startIndex + 1] >= 0x80 {
            // String.first treated a combining mark after "{" as part of its
            // first grapheme. Keep that uncommon malformed-record behavior.
            return unicodePayload(source)
        }
        guard bytes.first == 0x7B, isValidUTF8(bytes) else { return nil }
        return Data(bytes)
    }

    private static func trimmingASCIIWhitespace(_ source: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var start = source.startIndex
        var end = source.endIndex
        while start < end, isASCIIWhitespace(source[start]) { start += 1 }
        while end > start, isASCIIWhitespace(source[end - 1]) { end -= 1 }
        return source[start..<end]
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

    private static func unicodePayload(_ bytes: ArraySlice<UInt8>) -> Data? {
        guard var line = String(bytes: bytes, encoding: .utf8) else { return nil }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("data:") {
            line = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard line.first == "{" else { return nil }
        return Data(line.utf8)
    }

    /// Validate without allocating a String that JSONSerialization would
    /// immediately decode again. Reject overlong encodings and surrogates too.
    static func isValidUTF8<Bytes: RandomAccessCollection>(_ bytes: Bytes) -> Bool
    where Bytes.Element == UInt8, Bytes.Index == Int {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let first = bytes[index]
            if first < 0x80 {
                index += 1
                continue
            }
            let length: Int
            let secondRange: ClosedRange<UInt8>
            switch first {
            case 0xC2...0xDF:
                length = 2
                secondRange = 0x80...0xBF
            case 0xE0:
                length = 3
                secondRange = 0xA0...0xBF
            case 0xE1...0xEC, 0xEE...0xEF:
                length = 3
                secondRange = 0x80...0xBF
            case 0xED:
                length = 3
                secondRange = 0x80...0x9F
            case 0xF0:
                length = 4
                secondRange = 0x90...0xBF
            case 0xF1...0xF3:
                length = 4
                secondRange = 0x80...0xBF
            case 0xF4:
                length = 4
                secondRange = 0x80...0x8F
            default:
                return false
            }
            guard bytes.endIndex - index >= length,
                secondRange.contains(bytes[index + 1])
            else { return false }
            if length > 2 {
                for offset in 2..<length where !(0x80...0xBF).contains(bytes[index + offset]) {
                    return false
                }
            }
            index += length
        }
        return true
    }
}
