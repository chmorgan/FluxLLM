import Foundation
import XCTest

@testable import FluxLLM

/// Exercises the real bounded URLSession transport and coordinator against
/// independent HTTP servers. Generation goes directly to the fixture, never a proxy.
@MainActor
final class NativeBackendIntegrationTests: XCTestCase {
    func testVLLMDirectStreamDrivesNativeMonitoringWithoutProxy() async throws {
        try await exerciseNativeBackend(.vllm, fixtureName: "vllm")
    }

    func testRapidMLXDirectStreamDrivesNativeMonitoringWithoutProxy() async throws {
        try await exerciseNativeBackend(.rapidMLX, fixtureName: "rapid-mlx")
    }

    func testLlamaCppDirectStreamDrivesNativeMonitoringWithoutProxy() async throws {
        try await exerciseNativeBackend(.llamaCpp, fixtureName: "llama.cpp")
    }

    private func exerciseNativeBackend(_ kind: BackendKind, fixtureName: String) async throws {
        let fixture = try await NativePythonFixture(backend: fixtureName)
        defer { fixture.stop() }
        let suite = "com.cmorgan.FluxLLM.native-integration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.backendSelection = try XCTUnwrap(BackendSelection(rawValue: kind.rawValue))
        settings.backendEndpoints[kind] = fixture.baseURL.absoluteString
        let store = MetricsStore()
        var proxyCreations = 0
        let coordinator = MonitoringCoordinator(
            settings: settings, store: store,
            gpuMonitor: UnavailableBackendGPUMonitor(),
            proxyFactory: { _, _ in
                proxyCreations += 1
                XCTFail("Native monitoring must not construct an Ollama proxy")
                return UnexpectedNativeProxy()
            },
            pollInterval: .milliseconds(40), discoveryInterval: .seconds(60))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            await coordinator.start()
            XCTAssertEqual(coordinator.selectedConfiguration?.kind, kind)
            XCTAssertEqual(store.connectionState, .ready)
            XCTAssertFalse(store.isBackendActive)
            XCTAssertTrue(
                store.detectedBackends.contains {
                    $0.kind == kind && $0.baseURL == fixture.baseURL
                })

            var request = URLRequest(
                url: fixture.baseURL.appendingPathComponent("v1/chat/completions"))
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "Fixture/\(fixtureName)-synthetic",
                "messages": [["role": "user", "content": "direct fixture generation"]],
                "stream": true,
            ])
            let generation = Task { try await session.data(for: request) }
            defer { generation.cancel() }
            try await eventually {
                store.isBackendActive && store.rateIsAvailable && store.currentTPS > 0
            }
            XCTAssertEqual(store.runningRequests, 1)
            XCTAssertEqual(store.currentModel, "Fixture/\(fixtureName)-synthetic")
            XCTAssertEqual(
                store.throughputBasis,
                kind == .vllm ? .serverAggregate : .serverReportedAverage)
            XCTAssertNil(
                store.inferenceGPUPercent, "Synthetic tokens must not invent GPU measurements")
            if kind == .vllm {
                XCTAssertGreaterThan(
                    store.backendOutputTokens ?? 0, 0,
                    "vLLM counters must advance before generation completes")
            }
            let (body, response) = try await generation.value
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let stream = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(stream.contains("data: [DONE]"))
            let usage = try stream.split(separator: "\n").compactMap { line -> [String: Int]? in
                guard line.hasPrefix("data: {"),
                    let data = String(line.dropFirst(6)).data(using: .utf8),
                    let record = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return record["usage"] as? [String: Int]
            }.last
            XCTAssertEqual(usage?["completion_tokens"], 80)
            try await eventually {
                !store.isBackendActive && store.runningRequests == 0
                    && store.backendOutputTokens == 80 && store.currentTPS == 0
            }
            XCTAssertEqual(store.connectionState, .ready)
            XCTAssertEqual(store.currentTPS, 0)
            XCTAssertEqual(proxyCreations, 0)
            await coordinator.stop()
            XCTAssertNil(coordinator.selectedConfiguration)
        } catch {
            await coordinator.stop()
            throw error
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Real HTTP telemetry did not reach the expected state")
                throw NativeFixtureError.timeout
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class UnexpectedNativeProxy: MonitoringProxy {
    func start() async throws { XCTFail("Native monitoring must not start a proxy") }
    func stop() async {}
}

private enum NativeFixtureError: Error {
    case timeout
    case startup(String)
}

@MainActor
private final class NativePythonFixture {
    let baseURL: URL
    private let process: Process
    private let outputURL: URL
    private let outputHandle: FileHandle

    init(backend: String) async throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/mock_metrics_backend.py")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluxllm-native-fixture-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw NativeFixtureError.startup("Cannot create fixture output file")
        }
        let handle = try FileHandle(forWritingTo: outputURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", script.path, "--backend", backend, "--port", "0",
            "--pace", "0.05", "--chunks", "40", "--quiet",
        ]
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var address: URL?
            while address == nil {
                let output = try String(contentsOf: outputURL, encoding: .utf8)
                if let match = output.range(
                    of: "http://127\\.0\\.0\\.1:[0-9]+", options: .regularExpression)
                {
                    address = URL(string: String(output[match]))
                } else {
                    guard process.isRunning, ContinuousClock.now < deadline else {
                        throw NativeFixtureError.startup(output)
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            baseURL = try XCTUnwrap(address)
            self.process = process
            self.outputURL = outputURL
            outputHandle = handle
        } catch {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? handle.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? outputHandle.close()
        try? FileManager.default.removeItem(at: outputURL)
    }
}
