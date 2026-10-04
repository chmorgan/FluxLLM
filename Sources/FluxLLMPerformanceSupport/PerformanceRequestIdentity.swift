import CoreFoundation
import Foundation

/// An explicitly enabled performance session may assign reproducible request
/// identities from the fixture index. Invalid evidence never reuses an identity.
final class PerformanceRequestIdentity: @unchecked Sendable {
    static let maximumRecordedRequests = 4_096

    private let lock = NSLock()
    private var requests: [Int: UUID] = [:]
    private var invalidRequests = 0

    func requestID(for body: Data) -> UUID {
        let index = Self.fixtureIndex(in: body)
        lock.lock()
        defer { lock.unlock() }
        if let index, requests[index] == nil, requests.count < Self.maximumRecordedRequests {
            let id = PerformanceHistoryFixture.fixedID(namespace: 7, index: index)
            requests[index] = id
            return id
        }
        invalidRequests += 1
        // Use the same UUID uniqueness assumption as ordinary requests instead
        // of retaining unbounded fallback evidence. Version-4 UUIDs cannot equal
        // the fixture's namespace-7 identities, whose version bits are zero.
        return UUID()
    }

    func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let ordered: [[String: Any]] = requests.keys.sorted().map { index in
            ["index": index, "id": requests[index]!.uuidString]
        }
        return [
            "policy": "fixture-index-v1",
            "invalid_requests": invalidRequests,
            "requests": ordered,
        ]
    }

    private static func fixtureIndex(in body: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: body),
            let object = json as? [String: Any], let value = object["perf_index"] as? NSNumber,
            CFGetTypeID(value) != CFBooleanGetTypeID()
        else { return nil }
        // Do not silently coerce strings, Boolean NSNumber values, or floating
        // point JSON numbers into request indices.
        switch String(cString: value.objCType) {
        case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q": break
        default: return nil
        }
        guard let index = Int(exactly: value.doubleValue), (0...32_000_032).contains(index)
        else { return nil }
        return index
    }
}
