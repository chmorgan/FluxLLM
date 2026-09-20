import Foundation
import XCTest

@testable import FluxLLM

@MainActor
struct ProxyTestContext {
    let mock: MockOllamaServer
    let proxy: ProxyManager
    let store: MetricsStore
    let port: Int

    func request(path: String = "/api/generate", body: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody =
            (body ?? "{\"model\":\"fixture-model\",\"prompt\":\"Hello\",\"stream\":true}")
            .data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        return request
    }
}

/// Always tears down sockets, even when a thrown request/assertion aborts a test.
@MainActor
func withProxy(
    response: MockOllamaResponse = .nonStreaming(),
    operation: (ProxyTestContext) async throws -> Void
) async throws {
    let mock = MockOllamaServer(response: response)
    let store = MetricsStore()
    try await mock.start()
    let proxy = ProxyManager(
        listenPort: 0, ollamaHost: "127.0.0.1", ollamaPort: mock.port, metricsStore: store)
    do {
        try await proxy.start()
        let port = try XCTUnwrap(proxy.boundPort)
        try await operation(ProxyTestContext(mock: mock, proxy: proxy, store: store, port: port))
    } catch {
        await proxy.stop()
        await mock.stop()
        throw error
    }
    await proxy.stop()
    await mock.stop()
}

/// The deadline guards a broken async pipeline; correctness uses explicit stream
/// gates or injected dates rather than depending on a specific scheduling delay.
@MainActor
func waitForCondition(
    _ message: String,
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail(message, file: file, line: line)
            throw ProxyTestTimeout()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct ProxyTestTimeout: Error {}

/// URLSession.data(for:) buffers the response. This delegate exposes incremental
/// bytes while the fixture deliberately withholds the final NDJSON record.
final class StreamingProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var received = Data()
    private var finished = false
    private var failure: Error?

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        received.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        lock.lock()
        defer { lock.unlock() }
        failure = error
        finished = true
    }
}
