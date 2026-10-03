import Foundation
import XCTest

@testable import FluxLLM

final class PerformanceNIODiagnosticsTests: XCTestCase {
    func testNestedScopesRetainInclusiveParentsAndDisjointLeafCounters() throws {
        let clock = NIOTestClock()
        let diagnostics = try makeDiagnostics(clock)
        let read = diagnostics.begin(.upstreamRead, bytes: 123)
        let forward = diagnostics.begin(.forwarding, bytes: 99, bodies: 1)
        let coalescer = diagnostics.begin(.coalescer, bytes: 99, bodies: 1)
        diagnostics.end(coalescer)
        diagnostics.end(forward)
        let decode = diagnostics.begin(.jsonDecode, bytes: 98)
        diagnostics.end(decode, records: 1)
        diagnostics.end(read)
        let snapshot = diagnostics.snapshot()
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(
            snapshot.counters[PerformanceNIODiagnostics.Metric.upstreamRead.index].cpuNS, 700)
        XCTAssertEqual(
            snapshot.counters[PerformanceNIODiagnostics.Metric.forwarding.index].cpuNS, 300)
        XCTAssertEqual(
            snapshot.counters[PerformanceNIODiagnostics.Metric.coalescer.index].cpuNS, 100)
        XCTAssertEqual(
            snapshot.counters[PerformanceNIODiagnostics.Metric.jsonDecode.index].cpuNS, 100)
        XCTAssertEqual(
            snapshot.counters[PerformanceNIODiagnostics.Metric.jsonDecode.index].records, 1)
        XCTAssertEqual(
            snapshot.counters[PerformanceNIODiagnostics.Metric.forwarding.index].bodies, 1)
        XCTAssertEqual(
            snapshot.counters[PerformanceNIODiagnostics.Metric.forwarding.index].bytes, 99)
        XCTAssertEqual(
            snapshot.counters[PerformanceNIODiagnostics.Metric.relayScheduled.index].calls, 0,
            "Calibration must not enter runtime totals")
    }

    func testCompletedSnapshotsAreImmutableAndMonotonic() throws {
        let diagnostics = try makeDiagnostics(NIOTestClock())
        let first = diagnostics.snapshot()
        let timer = diagnostics.begin(.relayScheduled)
        diagnostics.end(timer)
        let second = diagnostics.snapshot()
        XCTAssertNil(second.error)
        XCTAssertEqual(second.sequence, first.sequence + 1)
        XCTAssertGreaterThan(second.threadCPUBeforeNS, first.threadCPUAfterNS)
        XCTAssertGreaterThan(second.clockReads, first.clockReads)
        XCTAssertEqual(
            first.counters[PerformanceNIODiagnostics.Metric.relayScheduled.index].calls, 0)
        XCTAssertEqual(
            second.counters[PerformanceNIODiagnostics.Metric.relayScheduled.index].calls, 1)
        XCTAssertTrue(first.calibration.available)
        XCTAssertGreaterThan(first.calibration.pairCPUNS, 0)
        XCTAssertGreaterThan(first.calibration.emptyScopeMeasuredNS, 0)
    }

    func testLeafScopesCannotOverlapOrEscapeUpstreamCallbacks() throws {
        for overlap in [false, true] {
            let diagnostics = try makeDiagnostics(NIOTestClock())
            if overlap {
                _ = diagnostics.begin(.upstreamRead)
                _ = diagnostics.begin(.jsonDecode)
            }
            XCTAssertNil(diagnostics.begin(.framing))
            XCTAssertNotNil(diagnostics.snapshot().error)
            XCTAssertNil(diagnostics.begin(.relayScheduled), "Diagnostic failure must be sticky")
        }
    }

    func testReadCompleteCanContainDisjointParserStages() throws {
        let diagnostics = try makeDiagnostics(NIOTestClock())
        let parent = diagnostics.begin(.upstreamReadComplete)
        let leaf = diagnostics.begin(.framing, ends: 1)
        diagnostics.end(leaf, records: 1)
        diagnostics.end(parent)
        let snapshot = diagnostics.snapshot()
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.counters[PerformanceNIODiagnostics.Metric.framing.index].ends, 1)
    }

    func testUnbalancedNestedEndAndSnapshotInsideScopeAreRejected() throws {
        let diagnostics = try makeDiagnostics(NIOTestClock())
        let parent = diagnostics.begin(.upstreamRead)
        _ = diagnostics.begin(.forwarding)
        diagnostics.end(parent)
        XCTAssertNotNil(diagnostics.snapshot().error)
        let other = try makeDiagnostics(NIOTestClock())
        _ = other.begin(.upstreamRead)
        XCTAssertTrue(try XCTUnwrap(other.snapshot().error).contains("active scope"))
    }

    func testClockFailureRegressionAndThreadMismatchRemainUnavailable() throws {
        for failure in 0..<3 {
            let clock = NIOTestClock()
            let diagnostics = try makeDiagnostics(clock)
            let scope = diagnostics.begin(.relayScheduled)
            if failure == 0 { clock.failure = true }
            if failure == 1 { clock.now = 0 }
            if failure == 2 { clock.correctThread = false }
            diagnostics.end(scope)
            clock.failure = false
            clock.correctThread = true
            clock.now = 1_000_000
            XCTAssertNotNil(diagnostics.snapshot().error)
            XCTAssertNil(diagnostics.begin(.relayScheduled))
        }
    }

    func testCounterOverflowFailsWithoutWrapping() throws {
        let diagnostics = try makeDiagnostics(NIOTestClock())
        let parent = diagnostics.begin(.upstreamRead)
        for _ in 0..<2 {
            let child = diagnostics.begin(.framing, bytes: Int.max)
            diagnostics.end(child)
        }
        XCTAssertNil(diagnostics.begin(.framing, bytes: Int.max))
        diagnostics.end(parent)
        let snapshot = diagnostics.snapshot()
        XCTAssertTrue(try XCTUnwrap(snapshot.error).contains("overflow"))
        XCTAssertEqual(
            snapshot.counters[PerformanceNIODiagnostics.Metric.framing.index].bytes,
            UInt64(Int.max) * 2)
    }

    private func makeDiagnostics(_ clock: NIOTestClock) throws -> PerformanceNIODiagnostics {
        try PerformanceNIODiagnostics(
            threadID: 123, readCPU: { clock.read() },
            readMach: { clock.now }, matchesThread: { clock.correctThread },
            calibrationIterations: 1)
    }
}

private final class NIOTestClock {
    var now: UInt64 = 1_000
    var failure = false
    var correctThread = true
    func read() -> UInt64? {
        if failure { return nil }
        now += 100
        return now
    }
}
