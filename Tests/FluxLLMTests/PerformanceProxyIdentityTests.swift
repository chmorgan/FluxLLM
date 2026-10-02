import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class PerformanceProxyIdentityTests: XCTestCase {
    func testProductionProxyKeepsRandomIdentitiesDespiteFixtureFields() async throws {
        try await withProxy { context in
            let body = #"{"model":"fixture-model","stream":false,"perf_index":480000}"#
            let expected = PerformanceHistoryFixture.fixedID(namespace: 7, index: 480000)
            _ = try await URLSession.shared.data(for: context.request(body: body))
            try await waitForCondition("First production request did not finish") {
                context.store.activeGeneration?.state == .completed
            }
            let first = try XCTUnwrap(context.store.activeGeneration?.id)
            _ = try await URLSession.shared.data(for: context.request(body: body))
            try await waitForCondition("Second production request reused the first identity") {
                context.store.activeGeneration?.state == .completed
                    && context.store.activeGeneration?.id != first
            }
            let second = try XCTUnwrap(context.store.activeGeneration?.id)
            XCTAssertNotEqual(first, expected)
            XCTAssertNotEqual(second, expected)
            XCTAssertNotEqual(first, second)
        }
    }

    func testInjectedIdentityOnlyAppliesToGenerationsAndPreservesForwardedBytes() async throws {
        let response = MockOllamaResponse.nonStreaming()
        let mock = MockOllamaServer(response: response)
        let store = MetricsStore()
        let identity = PerformanceRequestIdentity()
        try await mock.start()
        let proxy = ProxyManager(
            listenPort: 0, ollamaHost: "127.0.0.1", ollamaPort: mock.port, metricsStore: store,
            requestIDFactory: { identity.requestID(for: $0) })
        do {
            try await proxy.start()
            let context = ProxyTestContext(
                mock: mock, proxy: proxy, store: store, port: try XCTUnwrap(proxy.boundPort))
            var probe = context.request(path: "/api/tags")
            probe.httpMethod = "GET"
            probe.httpBody = nil
            _ = try await URLSession.shared.data(for: probe)
            XCTAssertEqual(identity.snapshot()["invalid_requests"] as? Int, 0)
            XCTAssertEqual((identity.snapshot()["requests"] as? [[String: Any]])?.count, 0)
            XCTAssertNil(store.activeGeneration)

            let body =
                #"{"model":"fixture-model","stream":false,"perf_index":480000,"prompt":"Hello 🌊"}"#
            let expected = PerformanceHistoryFixture.fixedID(namespace: 7, index: 480000)
            let (bytes, result) = try await URLSession.shared.data(for: context.request(body: body))
            XCTAssertEqual((result as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(bytes, response.body)
            try await waitForCondition("Injected identity did not reach telemetry") {
                store.activeGeneration?.state == .completed
                    && store.activeGeneration?.id == expected
            }
            _ = try await URLSession.shared.data(for: context.request(body: body))
            try await waitForCondition("Duplicate fixture index merged request accounting") {
                store.activeGeneration?.state == .completed
                    && store.activeGeneration?.id != expected
            }
            XCTAssertEqual(identity.snapshot()["invalid_requests"] as? Int, 1)
            XCTAssertEqual((identity.snapshot()["requests"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual(mock.requests.count, 3)
            for forwarded in mock.requests.dropFirst() {
                XCTAssertEqual(forwarded.uri, "/api/generate")
                XCTAssertEqual(forwarded.body, Data(body.utf8))
            }
        } catch {
            await proxy.stop()
            await mock.stop()
            throw error
        }
        await proxy.stop()
        await mock.stop()
    }
}
