import Foundation
import XCTest

@testable import FluxLLM
@testable import FluxLLMPerformanceSupport

final class PerformanceRequestIdentityTests: XCTestCase {
    func testIndependentSessionsMapIndicesIdenticallyRegardlessOfArrivalOrder() throws {
        let first = PerformanceRequestIdentity()
        let second = PerformanceRequestIdentity()
        let indices = [480_000, 0, 32_000_032, 480_001]
        var expected: [Int: UUID] = [:]
        for index in indices { expected[index] = first.requestID(for: body(index)) }
        for index in indices.reversed() {
            XCTAssertEqual(second.requestID(for: body(index)), expected[index])
        }
        for helper in [first, second] {
            let snapshot = helper.snapshot()
            XCTAssertEqual(snapshot["policy"] as? String, "fixture-index-v1")
            XCTAssertEqual(snapshot["invalid_requests"] as? Int, 0)
            let requests = try XCTUnwrap(snapshot["requests"] as? [[String: Any]])
            XCTAssertEqual(requests.compactMap { $0["index"] as? Int }, indices.sorted())
            XCTAssertEqual(
                requests.compactMap { $0["id"] as? String },
                indices.sorted().map { expected[$0]!.uuidString })
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: snapshot))
        }
    }

    @MainActor
    func testLiveNamespaceMatchesFixtureEncodingAndDoesNotReuseHistoryIdentities() {
        let helper = PerformanceRequestIdentity()
        for index in [0, 1, 480_000, 32_000_032] {
            let id = helper.requestID(for: body(index))
            XCTAssertEqual(id, PerformanceHistoryFixture.fixedID(namespace: 7, index: index))
            for namespace in UInt16(1)...6 {
                XCTAssertNotEqual(
                    id, PerformanceHistoryFixture.fixedID(namespace: namespace, index: index))
            }
        }
    }

    func testMalformedAndDuplicateRequestsAreInvalidAndReceiveIndependentFallbackIDs() throws {
        let helper = PerformanceRequestIdentity()
        let valid = helper.requestID(for: body(17))
        let invalidBodies = [
            "{\"perf_index\":true}", "{\"perf_index\":false}",
            "{\"perf_index\":1.5}", "{\"perf_index\":\"17\"}",
            "{\"perf_index\":-1}", "{\"perf_index\":32000033}",
            "{\"perf_index\":18446744073709551615}", "{\"perf_index\":null}",
            "{\"perf_index\":[]}", "{\"perf_index\":{}}", "{}", "[]", "null", "invalid JSON",
            "{\"perf_index\":17}",
        ]
        let fallback = invalidBodies.map { helper.requestID(for: Data($0.utf8)) }
        XCTAssertEqual(Set(fallback).count, fallback.count)
        XCTAssertFalse(fallback.contains(valid))
        let snapshot = helper.snapshot()
        XCTAssertEqual(snapshot["invalid_requests"] as? Int, invalidBodies.count)
        let requests = try XCTUnwrap(snapshot["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?["index"] as? Int, 17)
        XCTAssertEqual(requests.first?["id"] as? String, valid.uuidString)
    }

    func testIdentityEvidenceIsBoundedAndOverflowInvalidatesTheMeasurement() throws {
        let helper = PerformanceRequestIdentity()
        let limit = PerformanceRequestIdentity.maximumRecordedRequests
        var accepted = Set<UUID>()
        for index in 0..<limit { accepted.insert(helper.requestID(for: body(index))) }
        XCTAssertEqual(accepted.count, limit)
        let firstOverflow = helper.requestID(for: body(limit))
        let repeatedOverflow = helper.requestID(for: body(limit))
        let duplicate = helper.requestID(for: body(0))
        XCTAssertEqual(Set([firstOverflow, repeatedOverflow, duplicate]).count, 3)
        XCTAssertTrue(accepted.isDisjoint(with: [firstOverflow, repeatedOverflow, duplicate]))
        let snapshot = helper.snapshot()
        XCTAssertEqual(snapshot["invalid_requests"] as? Int, 3)
        let requests = try XCTUnwrap(snapshot["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, limit)
        XCTAssertEqual(requests.last?["index"] as? Int, limit - 1)
    }

    func testConcurrentDuplicateClaimsAllocateEachFixtureIdentityOnlyOnce() throws {
        let helper = PerformanceRequestIdentity()
        let results = ConcurrentIdentityResults()
        let bodies = (0..<64).map(body)
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            results.append(helper.requestID(for: bodies[index % bodies.count]))
        }
        let ids = results.snapshot()
        XCTAssertEqual(ids.count, 256)
        XCTAssertEqual(Set(ids).count, 256)
        let snapshot = helper.snapshot()
        XCTAssertEqual(snapshot["invalid_requests"] as? Int, 192)
        let requests = try XCTUnwrap(snapshot["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.compactMap { $0["index"] as? Int }, Array(0..<64))
        for request in requests {
            let id = try XCTUnwrap((request["id"] as? String).flatMap(UUID.init(uuidString:)))
            XCTAssertEqual(ids.filter { $0 == id }.count, 1)
        }
    }

    func testDeterministicAnimationSeedIsIndependentOfWallClockAndNormalSeedIsUnchanged() {
        XCTAssertEqual(
            PerformanceAnimationRandomness.policy(deterministic: true),
            "fixture-index-and-fixed-twinkle-seed-v1")
        XCTAssertEqual(
            PerformanceAnimationRandomness.policy(deterministic: false),
            "fixture-index-and-wall-clock-twinkles")
        let first = Date(timeIntervalSinceReferenceDate: 123)
        let second = Date(timeIntervalSinceReferenceDate: 456)
        XCTAssertEqual(
            PerformanceAnimationRandomness.initialTwinkleSequence(at: first, deterministic: true),
            PerformanceAnimationRandomness.initialTwinkleSequence(at: second, deterministic: true))
        XCTAssertEqual(
            PerformanceAnimationRandomness.initialTwinkleSequence(at: first, deterministic: true),
            0x4658_4C4C_4D)
        XCTAssertEqual(
            PerformanceAnimationRandomness.initialTwinkleSequence(at: first, deterministic: false),
            123_000)
        XCTAssertEqual(
            PerformanceAnimationRandomness.initialTwinkleSequence(at: second, deterministic: false),
            456_000)
        XCTAssertEqual(
            PerformanceAnimationRandomness.initialTwinkleSequence(
                at: Date(timeIntervalSinceReferenceDate: -1), deterministic: false), 0)
    }

    private func body(_ index: Int) -> Data {
        Data("{\"perf_index\":\(index)}".utf8)
    }
}

private final class ConcurrentIdentityResults: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []

    func append(_ id: UUID) {
        lock.lock()
        ids.append(id)
        lock.unlock()
    }

    func snapshot() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}
