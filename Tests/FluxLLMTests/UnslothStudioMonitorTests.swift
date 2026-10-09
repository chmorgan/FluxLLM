import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class UnslothStudioMonitorTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8888")!

    func testAuthenticatedReadKeepsOnlyReducedRequestMetadataAndStatus() async throws {
        let fixture = StudioMonitorTransportStub([
            .studioJSON(
                #"""
                {"status":"generating","server_time":200,"logging_enabled":true,"entries":[
                  {"id":"a","status":"running","model":"model-a","started_at":100.5,
                   "completion_tokens":12,"prompt_tokens":7,"tok_per_sec":24,
                   "prompt_preview":{"unexpected":"shape"},"reply_preview":["ignored"],
                   "error":{"ignored":true},"kind":"ignored","progress":"ignored"},
                  {"id":"b","status":"completed","started_at":101,"finished_at":105,
                   "completion_tokens":30,"prompt_tokens":20},
                  {"id":"c","status":"cancelled","started_at":102,"finished_at":106},
                  {"id":"d","status":"error","started_at":103,"finished_at":107}
                ]}
                """#)
        ])
        let monitor = UnslothStudioMonitor(transport: { try await fixture.respond($0) })
        let epoch = UUID()
        let value = try await monitor.snapshot(
            at: base, token: "explicit-test-token", sourceEpoch: epoch)
        let snapshot = try XCTUnwrap(value)
        XCTAssertEqual(snapshot.sourceEpoch, epoch)
        XCTAssertEqual(snapshot.source, .studioMonitor)
        XCTAssertFalse(snapshot.isComplete, "The monitor's retained history can omit identities")
        XCTAssertEqual(snapshot.requests.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(
            snapshot.requests.map(\.status), [.running, .completed, .cancelled, .failed])
        XCTAssertEqual(snapshot.requests[0].startedAt, Date(timeIntervalSince1970: 100.5))
        XCTAssertNil(snapshot.requests[0].endedAt)
        XCTAssertEqual(snapshot.requests[0].model, "model-a")
        XCTAssertEqual(snapshot.requests[0].outputTokens, 12)
        XCTAssertEqual(snapshot.requests[0].promptTokens, 7)
        XCTAssertEqual(snapshot.requests[0].liveTPS, 24)
        XCTAssertEqual(snapshot.requests[1].endedAt, Date(timeIntervalSince1970: 105))
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8888/api/inference/monitor")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"), "Bearer explicit-test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 1.5)
    }

    func testDisabledLoggingIsUnavailableEvenWhenEntriesHaveUnrecognizedShapes() async throws {
        let fixture = StudioMonitorTransportStub([
            .studioJSON(#"{"logging_enabled":false,"entries":"ignored"}"#)
        ])
        let monitor = UnslothStudioMonitor(transport: { try await fixture.respond($0) })
        let snapshot = try await monitor.snapshot(
            at: base, token: "test-token", sourceEpoch: UUID())
        XCTAssertNil(snapshot)
    }

    func testMalformedAndUnsupportedMetadataRejectSnapshot() async throws {
        let entries = [
            #"{"id":"a","status":"unknown"}"#,
            #"{"id":"","status":"running"}"#,
            #"{"id":1,"status":"running"}"#,
            #"{"id":"a","status":"running","started_at":true}"#,
            #"{"id":"a","status":"running","started_at":-1}"#,
            #"{"id":"a","status":"completed","started_at":10,"finished_at":5}"#,
            #"{"id":"a","status":"running","prompt_tokens":true}"#,
            #"{"id":"a","status":"running","completion_tokens":1.5}"#,
            #"{"id":"a","status":"running","completion_tokens":-1}"#,
            #"{"id":"a","status":"running","tok_per_sec":-1}"#,
            #"{"id":"a","status":"running","tok_per_sec":true}"#,
        ]
        var bodies = entries.map { "{\"logging_enabled\":true,\"entries\":[\($0)]}" }
        bodies.append(#"{"logging_enabled":1,"entries":[]}"#)
        bodies.append(#"{"entries":[]}"#)
        bodies.append(
            #"{"logging_enabled":true,"entries":[{"id":"a","status":"running"},{"id":"a","status":"completed"}]}"#
        )
        for body in bodies {
            let fixture = StudioMonitorTransportStub([.studioJSON(body)])
            let monitor = UnslothStudioMonitor(transport: { try await fixture.respond($0) })
            do {
                _ = try await monitor.snapshot(at: base, token: "test-token", sourceEpoch: UUID())
                XCTFail("Expected invalid monitor metadata")
            } catch { XCTAssertFalse(error is CancellationError) }
        }
    }

    func testBoundedResponseAndRetainedHistoryLimits() async throws {
        let entries = (0...UnslothStudioMonitor.maximumEntries).map {
            "{\"id\":\"\($0)\",\"status\":\"running\"}"
        }.joined(separator: ",")
        let responses: [(BackendHTTPResponse, BackendClientError)] = [
            (
                .init(
                    statusCode: 200,
                    data: Data(repeating: 32, count: HTTPBackendClient.maximumResponseBytes + 1)),
                .responseTooLarge
            ),
            (.studioJSON("{\"logging_enabled\":true,\"entries\":[\(entries)]}"), .invalidResponse),
            (.init(statusCode: 401, data: Data()), .httpStatus(401)),
            (.init(statusCode: 404, data: Data()), .httpStatus(404)),
        ]
        for (response, expected) in responses {
            let fixture = StudioMonitorTransportStub([response])
            let monitor = UnslothStudioMonitor(transport: { try await fixture.respond($0) })
            do {
                _ = try await monitor.snapshot(at: base, token: "test-token", sourceEpoch: UUID())
                XCTFail("Expected bounded monitor failure")
            } catch { XCTAssertEqual(error as? BackendClientError, expected) }
        }
    }

    func testInvalidEndpointsAndHeaderTokensFailBeforeTransport() async throws {
        let fixture = StudioMonitorTransportStub([])
        let monitor = UnslothStudioMonitor(transport: { try await fixture.respond($0) })
        let endpoints = [
            "http://example.com:8888", "http://user:secret@localhost:8888",
            "http://localhost:8888?token=secret", "http://localhost:8888/api", "file:///tmp/server",
        ]
        for endpoint in endpoints {
            do {
                _ = try await monitor.snapshot(
                    at: URL(string: endpoint)!, token: "test-token", sourceEpoch: UUID())
                XCTFail("Expected invalid endpoint")
            } catch { XCTAssertEqual(error as? BackendClientError, .invalidEndpoint) }
        }
        for token in ["", "with space", "with\nnewline"] {
            do {
                _ = try await monitor.snapshot(at: base, token: token, sourceEpoch: UUID())
                XCTFail("Expected invalid token")
            } catch { XCTAssertEqual(error as? BackendClientError, .invalidResponse) }
        }
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testTransportCancellationRemainsCancellation() async throws {
        let monitor = UnslothStudioMonitor(transport: { _ in throw CancellationError() })
        do {
            _ = try await monitor.snapshot(at: base, token: "test-token", sourceEpoch: UUID())
            XCTFail("A passive read must preserve cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor StudioMonitorTransportStub {
    private var responses: [BackendHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [BackendHTTPResponse]) { self.responses = responses }
    func respond(_ request: URLRequest) throws -> BackendHTTPResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}

extension BackendHTTPResponse {
    fileprivate static func studioJSON(_ body: String) -> Self {
        .init(statusCode: 200, data: Data(body.utf8))
    }
}
