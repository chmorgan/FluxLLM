import Foundation

/// Keeps only request identities and token counts from llama.cpp's read-only slot snapshots.
struct LlamaSlotThroughput {
    struct Measurement {
        let activeRequests: Int
        let currentTPS: Double?
        let state: ThroughputMeasurementState
        let measurementDuration: TimeInterval?
        let requests: [NativeRequestObservation]
    }

    private struct RequestID: Hashable {
        let slot: Int
        let task: Int
    }

    private struct Snapshot {
        let time: TimeInterval
        let counts: [RequestID: Int]
        let processStart: Double?
    }

    private var previous: Snapshot?

    mutating func sample(_ data: Data, at time: TimeInterval, processStart: Double?) throws
        -> Measurement
    {
        // A malformed response must not leave a baseline that bridges the failed poll.
        let old = previous
        previous = nil
        let slots = try JSONDecoder().decode([Slot].self, from: data)
        var slotIDs: Set<Int> = []
        var counts: [RequestID: Int] = [:]
        for slot in slots {
            guard slotIDs.insert(slot.id).inserted else {
                throw BackendClientError.invalidResponse
            }
            if let task = slot.task, let decoded = slot.decoded {
                counts[RequestID(slot: slot.id, task: task)] = decoded
            }
        }
        guard !counts.isEmpty else {
            return Measurement(
                activeRequests: 0, currentTPS: 0, state: .measured, measurementDuration: nil,
                requests: [])
        }
        let requests = Self.observations(counts)
        let unavailable = Measurement(
            activeRequests: counts.count, currentTPS: nil, state: .unavailable,
            measurementDuration: nil, requests: requests)
        guard time.isFinite else { return unavailable }
        previous = Snapshot(time: time, counts: counts, processStart: processStart)
        let warmup = Measurement(
            activeRequests: counts.count, currentTPS: nil, state: .warmingUp,
            measurementDuration: nil, requests: requests)
        guard let old, old.processStart == processStart else { return warmup }
        let interval = time - old.time
        guard interval.isFinite, interval > 0 else { return unavailable }
        guard interval <= 5 else { return warmup }

        var delta = 0.0
        var requestRates: [RequestID: Double] = [:]
        var hasComparableRequest = false
        for (request, count) in counts {
            // New or replaced requests start at their own baseline, even if their first
            // observed count is large. Remaining concurrent requests can still contribute.
            guard let oldCount = old.counts[request], count >= oldCount else { continue }
            hasComparableRequest = true
            delta += Double(count - oldCount)
            let requestRate = Double(count - oldCount) / interval
            if requestRate.isFinite { requestRates[request] = requestRate }
        }
        guard hasComparableRequest else { return warmup }
        let rate = delta / interval
        guard rate.isFinite else { return unavailable }
        return Measurement(
            activeRequests: counts.count, currentTPS: rate, state: .measured,
            measurementDuration: interval, requests: Self.observations(counts, rates: requestRates))
    }

    private static func observations(_ counts: [RequestID: Int], rates: [RequestID: Double] = [:])
        -> [NativeRequestObservation]
    {
        counts.sorted {
            $0.key.slot == $1.key.slot ? $0.key.task < $1.key.task : $0.key.slot < $1.key.slot
        }.map { request, count in
            NativeRequestObservation(
                id: "\(request.slot):\(request.task)", outputTokens: count, liveTPS: rates[request])
        }
    }

    private struct Slot: Decodable {
        let id: Int
        let task: Int?
        let decoded: Int?

        private enum CodingKeys: String, CodingKey {
            case id
            case processing = "is_processing"
            case task = "id_task"
            case nextToken = "next_token"
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(Int.self, forKey: .id)
            guard id >= 0 else { throw BackendClientError.invalidResponse }
            let processing = try fields.decode(Bool.self, forKey: .processing)
            guard processing else {
                // Idle slots can retain previous request metadata, including sentinel IDs.
                task = nil
                decoded = nil
                return
            }
            let task = try fields.decode(Int.self, forKey: .task)
            let tokens = try fields.decode([NextToken].self, forKey: .nextToken)
            guard task >= 0, tokens.count == 1, let decoded = tokens.first?.decoded,
                decoded >= 0
            else { throw BackendClientError.invalidResponse }
            self.task = task
            self.decoded = decoded
        }
    }

    private struct NextToken: Decodable {
        let decoded: Int

        private enum CodingKeys: String, CodingKey {
            case decoded = "n_decoded"
        }
    }
}
