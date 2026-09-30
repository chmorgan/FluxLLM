import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class BackendTransportTests: XCTestCase {
    func testSequentialRequestsReuseSessionAndRetainEphemeralPolicy() async throws {
        let fixture = BackendURLProtocolFixture(paths: ["/first", "/second"])
        let transport = fixture.makeTransport()
        XCTAssertEqual(fixture.sessionCount, 0, "An unused client should not create a session")
        for (path, status, body) in [
            ("/first", 200, "first body"), ("/second", 202, "second body"),
        ] {
            let request = fixture.request(path)
            let pending = Task { try await transport.send(request) }
            defer { pending.cancel() }
            await fulfillment(of: [fixture.started(path)], timeout: 2)
            try fixture.respond(path, status: status, chunks: [Data(body.utf8)])
            let response = try await value(of: pending)
            XCTAssertEqual(response.statusCode, status)
            XCTAssertEqual(response.data, Data(body.utf8))
        }
        XCTAssertEqual(fixture.sessionCount, 1)
        let configuration = try XCTUnwrap(fixture.configuration)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 1.5)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 3)
    }

    func testCancellationAndLateCompletionDoNotAffectAnotherRequest() async throws {
        let fixture = BackendURLProtocolFixture(paths: ["/cancel", "/keep", "/next"])
        let transport = fixture.makeTransport()
        let cancelled = Task { try await transport.send(fixture.request("/cancel")) }
        let kept = Task { try await transport.send(fixture.request("/keep")) }
        defer {
            cancelled.cancel()
            kept.cancel()
        }
        await fulfillment(of: [fixture.started("/cancel"), fixture.started("/keep")], timeout: 2)
        try await fixture.captureActiveTasks()

        cancelled.cancel()
        await assertCancellation(cancelled)
        try fixture.replayCompletion("/cancel")
        try fixture.respond("/keep", status: 201, chunks: [Data("still running".utf8)])
        let response = try await value(of: kept)
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(response.data, Data("still running".utf8))
        try fixture.replayCompletion("/keep")

        let next = Task { try await transport.send(fixture.request("/next")) }
        defer { next.cancel() }
        await fulfillment(of: [fixture.started("/next")], timeout: 2)
        try fixture.respond("/next", chunks: [Data("reused".utf8)])
        let nextResponse = try await value(of: next)
        XCTAssertEqual(nextResponse.data, Data("reused".utf8))
        XCTAssertEqual(fixture.sessionCount, 1)
    }

    func testCancellationBeforeTaskInstallationStillCompletesAndReusesSession() async throws {
        let entered = expectation(description: "Session creation entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let fixture = BackendURLProtocolFixture(paths: ["/cancel", "/next"])
        let transport = fixture.makeTransport {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        let request = fixture.request("/cancel")
        let cancelled = Task.detached { try await transport.send(request) }
        defer { cancelled.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        cancelled.cancel()
        release.signal()
        await assertCancellation(cancelled)
        XCTAssertEqual(fixture.startedPaths, [], "A cancelled request must not start loading")

        let next = Task { try await transport.send(fixture.request("/next")) }
        defer { next.cancel() }
        await fulfillment(of: [fixture.started("/next")], timeout: 2)
        try fixture.respond("/next", chunks: [Data("after cancellation".utf8)])
        let nextResponse = try await value(of: next)
        XCTAssertEqual(nextResponse.data, Data("after cancellation".utf8))
        XCTAssertEqual(fixture.sessionCount, 1)
    }

    func testDeclaredAndStreamingResponseLimitsRemainPerRequest() async throws {
        let fixture = BackendURLProtocolFixture(paths: ["/declared", "/streamed", "/exact"])
        let transport = fixture.makeTransport()
        let declared = Task { try await transport.send(fixture.request("/declared")) }
        let streamed = Task { try await transport.send(fixture.request("/streamed")) }
        let exact = Task { try await transport.send(fixture.request("/exact")) }
        defer {
            declared.cancel()
            streamed.cancel()
            exact.cancel()
        }
        await fulfillment(
            of: [
                fixture.started("/declared"), fixture.started("/streamed"),
                fixture.started("/exact"),
            ],
            timeout: 2)
        // This response intentionally has no body or completion. Supply its MIME
        // type so header delivery does not depend on sniffing body bytes.
        try fixture.respond(
            "/declared",
            headers: [
                "Content-Type": "application/octet-stream",
                "Content-Length": String(HTTPBackendClient.maximumResponseBytes + 1),
            ],
            chunks: [], finish: false)
        let full = Data(repeating: 120, count: HTTPBackendClient.maximumResponseBytes)
        // No Content-Length: the incremental body cap must stop this response.
        try fixture.respond("/streamed", chunks: [full, Data([121])])
        try fixture.respond("/exact", chunks: [full])
        for (path, pending) in [("/declared", declared), ("/streamed", streamed)] {
            do {
                _ = try await value(of: pending)
                XCTFail("Expected the response size limit")
            } catch {
                XCTAssertEqual(
                    error as? BackendClientError, .responseTooLarge,
                    "Unexpected \(path) failure: \(error as NSError)")
            }
        }
        let accepted = try await value(of: exact)
        XCTAssertEqual(accepted.data, full)
        XCTAssertEqual(accepted.statusCode, 200)
        XCTAssertEqual(fixture.sessionCount, 1)
    }

    func testResetDoesNotCloseTransportOrCancelAnUnrelatedRequest() async throws {
        let fixture = BackendURLProtocolFixture(paths: ["/api/version", "/api/ps"])
        let transport = fixture.makeTransport()
        let client = HTTPBackendClient(transport: { try await transport.send($0) })
        let configuration = BackendConfiguration(kind: .ollama, baseURL: fixture.baseURL)
        let pending = Task { try await client.sample(configuration) }
        defer { pending.cancel() }
        await fulfillment(of: [fixture.started("/api/version")], timeout: 2)
        await client.reset()
        try fixture.respond("/api/version", chunks: [Data(#"{"version":"fixture"}"#.utf8)])
        await fulfillment(of: [fixture.started("/api/ps")], timeout: 2)
        try fixture.respond("/api/ps", chunks: [Data(#"{"models":[{"name":"model-a"}]}"#.utf8)])
        let sample = try await value(of: pending)
        XCTAssertEqual(sample.model, "model-a")
        XCTAssertEqual(fixture.sessionCount, 1)
    }

    private func assertCancellation(_ task: Task<BackendHTTPResponse, Error>) async {
        do {
            _ = try await value(of: task)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
    }

    private func value<Value: Sendable>(of task: Task<Value, Error>) async throws -> Value {
        let completion = BackendTransportCompletion<Value>()
        let observer = Task { completion.finish(await task.result) }
        await fulfillment(of: [completion.finished], timeout: 3)
        guard let result = completion.result else {
            task.cancel()
            observer.cancel()
            throw BackendTransportTestError.completionTimedOut
        }
        return try result.get()
    }
}

private enum BackendTransportTestError: Error {
    case completionTimedOut
}

private final class BackendTransportCompletion<Value: Sendable>: @unchecked Sendable {
    let finished = XCTestExpectation(description: "Transport completed")
    private let lock = NSLock()
    private var outcome: Result<Value, Error>?

    var result: Result<Value, Error>? { lock.withLock { outcome } }

    func finish(_ result: Result<Value, Error>) {
        lock.withLock { outcome = result }
        finished.fulfill()
    }
}

/// Exercises URLSession's real task/delegate dispatch without network timing.
private final class BackendURLProtocolFixture: @unchecked Sendable {
    private let lock = NSLock()
    let baseURL = URL(string: "http://\(UUID().uuidString.lowercased()).test")!
    private let expectations: [String: XCTestExpectation]
    private var protocols: [String: ControlledBackendURLProtocol] = [:]
    private var retainedTasks: [String: URLSessionTask] = [:]
    private var createdSessions = 0
    private var savedConfiguration: URLSessionConfiguration?
    private weak var session: URLSession?
    private weak var delegate: (any URLSessionDataDelegate)?

    init(paths: [String]) {
        expectations = Dictionary(
            uniqueKeysWithValues: paths.map {
                ($0, XCTestExpectation(description: "Started \($0)"))
            })
        ControlledBackendURLProtocol.register(host: baseURL.host!) { [weak self] request in
            self?.record(request)
        }
    }

    deinit { ControlledBackendURLProtocol.remove(host: baseURL.host!) }

    var sessionCount: Int { lock.withLock { createdSessions } }
    var configuration: URLSessionConfiguration? { lock.withLock { savedConfiguration } }
    var startedPaths: [String] { lock.withLock { protocols.keys.sorted() } }

    func request(_ path: String) -> URLRequest {
        URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
    }

    func started(_ path: String) -> XCTestExpectation { expectations[path]! }

    func makeTransport(beforeCreation: (@Sendable () -> Void)? = nil) -> BoundedBackendTransport {
        BoundedBackendTransport { [self] configuration, delegate in
            beforeCreation?()
            configuration.protocolClasses = [ControlledBackendURLProtocol.self]
            let session = URLSession(
                configuration: configuration, delegate: delegate, delegateQueue: nil)
            lock.withLock {
                createdSessions += 1
                savedConfiguration = configuration
                self.session = session
                self.delegate = delegate as? any URLSessionDataDelegate
            }
            return session
        }
    }

    func respond(
        _ path: String, status: Int = 200, headers: [String: String] = [:],
        chunks: [Data], finish: Bool = true
    ) throws {
        let request = try XCTUnwrap(lock.withLock { protocols[path] })
        request.respond(status: status, headers: headers, chunks: chunks, finish: finish)
    }

    func replayCompletion(_ path: String) throws {
        let state = lock.withLock { (self.session, self.delegate, retainedTasks[path]) }
        let session = try XCTUnwrap(state.0)
        let delegate = try XCTUnwrap(state.1)
        let task = try XCTUnwrap(state.2)
        delegate.urlSession?(session, task: task, didCompleteWithError: nil)
        delegate.urlSession?(session, task: task, didCompleteWithError: URLError(.cancelled))
    }

    func captureActiveTasks() async throws {
        let session = try XCTUnwrap(lock.withLock { self.session })
        let tasks = await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
        lock.withLock {
            for task in tasks {
                if let path = task.originalRequest?.url?.path { retainedTasks[path] = task }
            }
        }
    }

    private func record(_ request: ControlledBackendURLProtocol) {
        let path = request.request.url!.path
        lock.withLock { protocols[path] = request }
        expectations[path]?.fulfill()
    }
}

private final class ControlledBackendURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handlers = BackendProtocolHandlers()
    private let lock = NSLock()
    private var stopped = false

    static func register(
        host: String, handler: @escaping @Sendable (ControlledBackendURLProtocol) -> Void
    ) {
        handlers.set(handler, for: host)
    }

    static func remove(host: String) { handlers.set(nil, for: host) }

    override class func canInit(with request: URLRequest) -> Bool {
        handlers.get(request.url?.host ?? "") != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() { Self.handlers.get(request.url?.host ?? "")?(self) }
    override func stopLoading() { lock.withLock { stopped = true } }

    func respond(status: Int, headers: [String: String], chunks: [Data], finish: Bool) {
        guard !lock.withLock({ stopped }),
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: headers)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks where !lock.withLock({ stopped }) {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if finish, !lock.withLock({ stopped }) { client?.urlProtocolDidFinishLoading(self) }
    }
}

private final class BackendProtocolHandlers: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable (ControlledBackendURLProtocol) -> Void] = [:]

    func set(_ handler: (@Sendable (ControlledBackendURLProtocol) -> Void)?, for host: String) {
        lock.withLock { handlers[host] = handler }
    }

    func get(_ host: String) -> (@Sendable (ControlledBackendURLProtocol) -> Void)? {
        lock.withLock { handlers[host] }
    }
}
