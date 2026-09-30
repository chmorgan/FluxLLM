import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class DiagnosticLoggerTests: XCTestCase {
    func testDisabledLoggerDoesNotCreateOutputOrScheduleWrites() async throws {
        let output = DiagnosticTestOutput()
        let logger = DiagnosticLogger(configuration: .init()) { _ in
            output.noteFactoryCall()
            return output
        }
        for _ in 0..<1_000 { logger.record(.sample, count: 1) }
        try await logger.setEnabled(false)
        XCTAssertFalse(logger.isEnabled)
        XCTAssertEqual(logger.droppedCount, 0)
        XCTAssertEqual(output.snapshot.factoryCalls, 0)
        XCTAssertEqual(output.snapshot.openCalls, 0)
        XCTAssertTrue(output.snapshot.writes.isEmpty)
        XCTAssertEqual(output.snapshot.closeCalls, 0)
        XCTAssertFalse(DiagnosticLogger().isEnabled)
    }

    func testQueueAndWriteBatchesStayBoundedWhenWriterIsBlocked() async throws {
        let entered = expectation(description: "Writer entered")
        let output = DiagnosticTestOutput(blockWrites: true, entered: entered)
        defer { output.releaseWrites() }
        let configuration = DiagnosticLogger.Configuration(
            queueBytes: 512, batchBytes: 128, fileBytes: 512, fileCount: 2)
        let logger = DiagnosticLogger(configuration: configuration) { _ in output }
        try await logger.setEnabled(true, directory: temporaryDirectory())
        logger.record(.sample, count: 0)
        await fulfillment(of: [entered], timeout: 2)
        for index in 1...1_000 { logger.record(.sample, count: index) }
        XCTAssertGreaterThan(logger.droppedCount, 0)
        output.releaseWrites()
        try await logger.setEnabled(false)

        let writes = output.snapshot.writes
        XCTAssertTrue(writes.allSatisfy { $0.count <= configuration.batchBytes })
        XCTAssertLessThanOrEqual(writes.reduce(0) { $0 + $1.count }, configuration.queueBytes)
        XCTAssertEqual(try records(writes).count + logger.droppedCount, 1_001)
        XCTAssertEqual(output.snapshot.closeCalls, 1)
    }

    func testDisableStopsAcceptanceBeforeAcknowledgingWriterClose() async throws {
        let entered = expectation(description: "Writer entered")
        let output = DiagnosticTestOutput(blockWrites: true, entered: entered)
        defer { output.releaseWrites() }
        let logger = DiagnosticLogger(configuration: .init()) { _ in output }
        try await logger.setEnabled(true, directory: temporaryDirectory())
        logger.record(.requestStarted, count: 1)
        await fulfillment(of: [entered], timeout: 2)
        let disable = Task { @MainActor in try await logger.setEnabled(false) }
        await Task.yield()
        XCTAssertFalse(logger.isEnabled)
        XCTAssertTrue(logger.isUpdating)
        XCTAssertEqual(output.snapshot.closeCalls, 0)
        logger.record(.requestFinished, count: 2)
        output.releaseWrites()
        try await disable.value
        XCTAssertFalse(logger.isUpdating)
        XCTAssertEqual(output.snapshot.closeCalls, 1)
        XCTAssertEqual(try records(output.snapshot.writes).count, 1)
        logger.record(.sample, count: 3)
        XCTAssertEqual(try records(output.snapshot.writes).count, 1)
    }

    func testWriterFailureClosesOutputAndCountsUnwrittenRecords() async throws {
        let entered = expectation(description: "Writer entered")
        let output = DiagnosticTestOutput(blockWrites: true, failWrites: true, entered: entered)
        defer { output.releaseWrites() }
        let logger = DiagnosticLogger(configuration: .init()) { _ in output }
        try await logger.setEnabled(true, directory: temporaryDirectory())
        logger.record(.sample, count: 1)
        await fulfillment(of: [entered], timeout: 2)
        logger.record(.sample, count: 2)
        output.releaseWrites()
        do {
            try await logger.setEnabled(false)
            XCTFail("A failed writer must report the failure at its disable barrier")
        } catch {}
        XCTAssertFalse(logger.isEnabled)
        XCTAssertEqual(logger.droppedCount, 2)
        XCTAssertNotNil(logger.errorMessage)
        XCTAssertEqual(output.snapshot.closeCalls, 1)
        XCTAssertTrue(output.snapshot.writes.isEmpty)
        try await logger.setEnabled(false)
    }

    func testDisableWaitsForCloseBarrierAndSurfacesItsFailure() async throws {
        let entered = expectation(description: "Close barrier entered")
        let output = DiagnosticTestOutput(
            blockClose: true, failClose: true, closeEntered: entered)
        defer { output.releaseClose() }
        let logger = DiagnosticLogger(configuration: .init()) { _ in output }
        try await logger.setEnabled(true, directory: temporaryDirectory())
        logger.record(.sample, count: 1)
        let disable = Task { @MainActor in try await logger.setEnabled(false) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(logger.isEnabled)
        XCTAssertTrue(logger.isUpdating, "Disable must await buffered-output completion")
        XCTAssertEqual(try records(output.snapshot.writes).count, 1)
        logger.record(.sample, count: 2)
        output.releaseClose()
        do {
            try await disable.value
            XCTFail("The disable caller must receive a close-barrier failure")
        } catch {}
        XCTAssertFalse(logger.isUpdating)
        XCTAssertNotNil(logger.errorMessage)
        XCTAssertEqual(output.snapshot.closeCalls, 1)
        XCTAssertEqual(try records(output.snapshot.writes).count, 1)
        try await logger.setEnabled(false)
    }

    func testOpenFailureLeavesLoggingDisabledAndClosesOutput() async throws {
        let output = DiagnosticTestOutput(failOpen: true)
        let logger = DiagnosticLogger(configuration: .init()) { _ in output }
        do {
            try await logger.setEnabled(true, directory: temporaryDirectory())
            XCTFail("Opening the failing output should throw")
        } catch {}
        logger.record(.sample)
        XCTAssertFalse(logger.isEnabled)
        XCTAssertFalse(logger.isUpdating)
        XCTAssertNotNil(logger.errorMessage)
        XCTAssertEqual(output.snapshot.openCalls, 1)
        XCTAssertEqual(output.snapshot.closeCalls, 1)
        XCTAssertTrue(output.snapshot.writes.isEmpty)
    }

    func testRotationLimitsFilesAndPreservesCompleteMetadataRecords() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = DiagnosticLogger.Configuration(
            queueBytes: 32_768, batchBytes: 256, fileBytes: 512, fileCount: 3)
        let logger = DiagnosticLogger(configuration: configuration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try await logger.setEnabled(true, directory: directory)
        for index in 0..<100 {
            logger.record(.performance, backend: .ollama, durationMilliseconds: 0.5, count: index)
        }
        try await logger.setEnabled(false)
        XCTAssertEqual(logger.droppedCount, 0)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(
            Set(urls.map(\.lastPathComponent)),
            [
                "diagnostics.jsonl", "diagnostics.1.jsonl", "diagnostics.2.jsonl",
            ])
        for url in urls {
            let data = try Data(contentsOf: url)
            XCTAssertLessThanOrEqual(data.count, configuration.fileBytes)
            for record in try records([data]) {
                XCTAssertEqual(
                    Set(record.keys),
                    [
                        "timestamp", "event", "backend", "durationMilliseconds", "count",
                    ])
                XCTAssertEqual(record["event"] as? String, "performance")
                XCTAssertEqual(record["backend"] as? String, "ollama")
            }
        }
        let latest = try Data(contentsOf: directory.appendingPathComponent("diagnostics.jsonl"))
        XCTAssertEqual(try records([latest]).last?["count"] as? Int, 99)
        let freshSession = DiagnosticLogger()
        XCTAssertFalse(freshSession.isEnabled)
    }

    func testStoreLogsOnlyEnabledEventsAndSafeScalarMetadata() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let store = MetricsStore(clock: { origin })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        let disabledRequest = GenerationRequest(model: "private-disabled-model", startedAt: origin)
        store.apply(.began(disabledRequest), epoch: epoch)
        store.apply(.cancelled(requestID: disabledRequest.id), epoch: epoch)
        store.sample(at: origin)
        XCTAssertFalse(store.diagnosticLogger.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        try await store.diagnosticLogger.setEnabled(true, directory: directory)
        let request = GenerationRequest(model: "private-model-name", startedAt: origin)
        store.apply(.began(request), epoch: epoch)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    model: "private-model-name", outputTokens: 7, promptTokens: 13,
                    liveTPS: 3.5, timestamp: origin)), epoch: epoch)
        store.apply(
            .toolActivity(
                requestID: request.id,
                events: [
                    ToolActivityEvent(
                        kind: .call, name: "private-tool-name", callID: "private-call-id",
                        timestamp: origin),
                    ToolActivityEvent(
                        kind: .resultSubmission, name: "private-tool-name",
                        callID: "private-call-id", timestamp: origin),
                ]), epoch: epoch)
        store.sample(at: origin.addingTimeInterval(0.5))
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(outputTokens: 11, finished: true, timestamp: origin)),
            epoch: epoch)
        let failed = GenerationRequest(model: "private-failed-model", startedAt: origin)
        store.apply(.began(failed), epoch: epoch)
        store.apply(
            .updated(
                requestID: failed.id,
                snapshot: GenerationSnapshot(error: "private-stream-error", timestamp: origin)),
            epoch: epoch)
        store.apply(.failed(requestID: failed.id, message: "private-failure-message"), epoch: epoch)
        // An event from a retired monitoring session must not appear in diagnostics.
        store.apply(.began(GenerationRequest(model: "private-stale-model")), epoch: UUID())
        try await store.diagnosticLogger.setEnabled(false)

        let file = directory.appendingPathComponent("diagnostics.jsonl")
        let data = try Data(contentsOf: file)
        let logged = try records([data])
        XCTAssertEqual(
            logged.compactMap { $0["event"] as? String },
            [
                "requestStarted", "requestUpdated", "toolCall", "toolResult", "sample",
                "requestFinished", "requestStarted", "requestFailed", "requestFailed",
            ])
        let allowedKeys: Set<String> = ["timestamp", "event", "requestID", "backend", "count"]
        for record in logged {
            XCTAssertTrue(Set(record.keys).isSubset(of: allowedKeys))
            XCTAssertEqual(record["backend"] as? String, "ollama")
            XCTAssertNotNil(record["timestamp"] as? Double)
        }
        XCTAssertEqual(logged[1]["count"] as? Int, 7)
        XCTAssertEqual(logged[4]["count"] as? Int, 1)
        XCTAssertEqual(logged[5]["count"] as? Int, 11)
        XCTAssertEqual(logged[0]["requestID"] as? String, request.id.uuidString)
        XCTAssertEqual(logged[7]["requestID"] as? String, failed.id.uuidString)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-"))

        store.apply(.began(GenerationRequest(model: "private-after-disable", startedAt: origin)))
        store.sample(at: origin.addingTimeInterval(1))
        try await store.diagnosticLogger.setEnabled(false)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(store.diagnosticLogger.droppedCount, 0)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "FluxLLM-diagnostics-\(UUID().uuidString)", isDirectory: true)
    }

    private func records(_ writes: [Data]) throws -> [[String: Any]] {
        try writes.flatMap { data in
            try data.split(separator: 0x0A).map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
            }
        }
    }
}

private final class DiagnosticTestOutput: DiagnosticLogOutput, @unchecked Sendable {
    struct Snapshot {
        var factoryCalls = 0
        var openCalls = 0
        var closeCalls = 0
        var writes: [Data] = []
    }

    private let condition = NSCondition()
    private var state = Snapshot()
    private var blockWrites: Bool
    private var blockClose: Bool
    private let failWrites: Bool
    private let failOpen: Bool
    private let failClose: Bool
    private var entered: XCTestExpectation?
    private var closeEntered: XCTestExpectation?

    init(
        blockWrites: Bool = false, failWrites: Bool = false, failOpen: Bool = false,
        entered: XCTestExpectation? = nil, blockClose: Bool = false, failClose: Bool = false,
        closeEntered: XCTestExpectation? = nil
    ) {
        self.blockWrites = blockWrites
        self.blockClose = blockClose
        self.failWrites = failWrites
        self.failOpen = failOpen
        self.failClose = failClose
        self.entered = entered
        self.closeEntered = closeEntered
    }

    var snapshot: Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    func noteFactoryCall() {
        condition.lock()
        state.factoryCalls += 1
        condition.unlock()
    }

    func open(directory: URL) throws {
        condition.lock()
        defer { condition.unlock() }
        state.openCalls += 1
        if failOpen { throw TestError.outputFailure }
    }

    func write(_ data: Data) throws {
        condition.lock()
        defer { condition.unlock() }
        entered?.fulfill()
        entered = nil
        while blockWrites { condition.wait() }
        if failWrites { throw TestError.outputFailure }
        state.writes.append(data)
    }

    func close() throws {
        condition.lock()
        defer { condition.unlock() }
        state.closeCalls += 1
        closeEntered?.fulfill()
        closeEntered = nil
        while blockClose { condition.wait() }
        if failClose { throw TestError.outputFailure }
    }

    func releaseWrites() {
        condition.lock()
        blockWrites = false
        condition.broadcast()
        condition.unlock()
    }

    func releaseClose() {
        condition.lock()
        blockClose = false
        condition.broadcast()
        condition.unlock()
    }

    private enum TestError: Error { case outputFailure }
}
