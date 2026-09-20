import CoreFoundation
import Foundation
import NIO

/// Reads protocol activity without keeping arguments or tool result contents.
/// Identity is scoped to one response; anonymous complete calls remain distinct.
struct ToolCallParser {
    private var emittedIDs: Set<String> = []
    private var emittedIndices: Set<Int> = []
    private var indexOwners: [Int: Set<String>] = [:]

    mutating func ingest(_ payload: String, at timestamp: Date) -> [ToolActivityEvent] {
        guard let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? [String: Any],
            let calls = message["tool_calls"] as? [[String: Any]]
        else { return [] }

        return calls.compactMap { call in
            guard let function = call["function"] as? [String: Any],
                let name = Self.nonempty(function["name"])
            else { return nil }

            let callID = Self.nonempty(call["id"])
            let index = Self.index(function["index"])
            if callID != nil || index != nil {
                guard shouldEmit(callID: callID, index: index) else { return nil }
            } else {
                // Native anonymous calls have complete structured arguments.
                // Incomplete fragments have no reliable identity for merging.
                guard function["arguments"] is [String: Any] else { return nil }
            }
            return ToolActivityEvent(kind: .call, name: name, callID: callID, timestamp: timestamp)
        }
    }

    private mutating func shouldEmit(callID: String?, index: Int?) -> Bool {
        if let callID {
            let wasEmitted = !emittedIDs.insert(callID).inserted
            var adoptsIndexOnlyCall = false
            if let index {
                // A later ID can identify an earlier index-only record. Once
                // an explicit owner exists, another ID denotes a distinct call
                // even if the server reuses a default index such as zero.
                adoptsIndexOnlyCall =
                    emittedIndices.contains(index) && indexOwners[index, default: []].isEmpty
                indexOwners[index, default: []].insert(callID)
            }
            return !wasEmitted && !adoptsIndexOnlyCall
        }
        guard let index else { return false }
        // Missing IDs can be matched only when the index has one known owner.
        if indexOwners[index]?.count == 1 { return false }
        return emittedIndices.insert(index).inserted
    }

    /// Only a trailing tool-result batch is newly submitted. Earlier messages
    /// are replayed conversation context, not new tool activity.
    static func resultSubmissions(
        path: String, body: ByteBuffer, at timestamp: Date
    ) -> [ToolActivityEvent] {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard pathOnly == "/api/chat",
            let object = try? JSONSerialization.jsonObject(with: Data(body.readableBytesView))
                as? [String: Any],
            let messages = object["messages"] as? [[String: Any]]
        else { return [] }

        return messages.reversed().prefix { $0["role"] as? String == "tool" }.reversed().map {
            ToolActivityEvent(
                kind: .resultSubmission,
                name: nonempty($0["tool_name"]) ?? nonempty($0["name"]),
                callID: nonempty($0["tool_call_id"]), timestamp: timestamp)
        }
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func index(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let index = Int(exactly: number.doubleValue), index >= 0
        else { return nil }
        return index
    }
}
