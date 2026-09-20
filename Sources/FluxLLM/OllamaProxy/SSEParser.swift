import Foundation

/// Reassembles complete NDJSON lines before UTF-8 decoding. Network reads can
/// split both a JSON object and an individual multibyte character.
struct SSEParser {
    private var bytes: [UInt8] = []

    mutating func feed(_ chunk: String) -> [String] { feed(Array(chunk.utf8)) }

    mutating func feed(_ chunk: [UInt8]) -> [String] {
        bytes.append(contentsOf: chunk)
        var results: [String] = []
        var lineStart = 0
        for index in bytes.indices where bytes[index] == 0x0A {
            if let payload = Self.payload(bytes[lineStart..<index]) {
                results.append(payload)
            }
            lineStart = index + 1
        }
        if lineStart > 0 { bytes.removeFirst(lineStart) }
        return results
    }

    mutating func finish() -> [String] {
        defer { bytes.removeAll(keepingCapacity: true) }
        return Self.payload(bytes[...]).map { [$0] } ?? []
    }

    private static func payload(_ bytes: ArraySlice<UInt8>) -> String? {
        guard var line = String(bytes: bytes, encoding: .utf8) else { return nil }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("data:") {
            line = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // SSE compatibility is just tolerated framing, not another API backend.
        guard line.first == "{" else { return nil }
        return line
    }
}
