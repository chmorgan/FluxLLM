import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class ProxyServerTests: XCTestCase {
    func testDefaultLocalhostUpstreamCanReachIPv4Fixture() async throws {
        let response = MockOllamaResponse.nonStreaming()
        let mock = MockOllamaServer(response: response)
        try await mock.start()
        let proxy = ProxyManager(listenPort: 0, ollamaHost: "localhost", ollamaPort: mock.port)
        do {
            try await proxy.start()
            let port = try XCTUnwrap(proxy.boundPort)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/generate")!)
            request.httpMethod = "POST"
            request.httpBody = Data(
                "{\"model\":\"fixture-model\",\"prompt\":\"Hello\",\"stream\":false}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 5
            let (data, result) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((result as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, response.body)
            XCTAssertEqual(mock.requests.count, 1)
        } catch {
            await proxy.stop()
            await mock.stop()
            throw error
        }
        await proxy.stop()
        await mock.stop()
    }

    func testRejectsNonLoopbackListenerWithoutOpeningSocket() async {
        let store = MetricsStore()
        let proxy = ProxyManager(listenHost: "0.0.0.0", listenPort: 0, metricsStore: store)
        do {
            try await proxy.start()
            XCTFail("POC must not expose its proxy on all interfaces")
        } catch {
            XCTAssertEqual(store.proxyState, .failed)
            XCTAssertNotNil(proxy.lastError)
            XCTAssertNil(proxy.boundPort)
        }
        await proxy.stop()
    }

    func testForwardsRequestIdentityAndExactNonStreamingResponse() async throws {
        let fixture = MockOllamaResponse.nonStreaming()
        try await withProxy(response: fixture) { context in
            let body = "{\"model\":\"fixture-model\",\"prompt\":\"Hello 🌊\",\"stream\":false}"
            var request = context.request(path: "/api/generate?keep=1", body: body)
            request.setValue("request-identity", forHTTPHeaderField: "X-Request-ID")
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(http.value(forHTTPHeaderField: "X-Fixture"), "FluxLLM POC")
            XCTAssertEqual(data, fixture.body)
            let captured = try XCTUnwrap(context.mock.requests.first)
            XCTAssertEqual(captured.method, "POST")
            XCTAssertEqual(captured.uri, "/api/generate?keep=1")
            XCTAssertEqual(captured.headers["x-request-id"], "request-identity")
            XCTAssertEqual(captured.headers["content-type"], "application/json")
            XCTAssertEqual(captured.body, body.data(using: .utf8))
            try await waitForCondition("Nonstreaming result was not completed") {
                context.store.activeGeneration?.state == .completed
            }
            XCTAssertEqual(context.store.outputTokens, 12)
            XCTAssertEqual(context.store.promptTokens, 4)
            XCTAssertFalse(context.store.outputIsEstimated)
            XCTAssertEqual(context.store.lastMeasuredTPS ?? -1, 20, accuracy: 0.001)
            XCTAssertEqual(context.store.currentTPS, 0)
        }
    }

    func testNonGenerationRequestPassesThroughWithoutChangingMetrics() async throws {
        let fixture = MockOllamaResponse(firstBytes: Array("{\"models\":[]}".utf8))
        try await withProxy(response: fixture) { context in
            var request = context.request(path: "/api/tags")
            request.httpMethod = "GET"
            request.httpBody = nil
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, fixture.body)
            XCTAssertEqual(context.mock.requests.first?.method, "GET")
            XCTAssertNil(context.store.activeGeneration)
            XCTAssertEqual(context.store.outputTokens, 0)
        }
    }

    func testNativeChatNonStreamingResponsePublishesFinalUsage() async throws {
        let fixture = MockOllamaResponse.nonStreaming(chat: true)
        try await withProxy(response: fixture) { context in
            let body =
                "{\"model\":\"fixture-model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"stream\":false}"
            let (data, response) = try await URLSession.shared.data(
                for:
                    context.request(path: "/api/chat", body: body))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, fixture.body)
            try await waitForCondition("Nonstreaming chat did not publish final usage") {
                context.store.activeGeneration?.state == .completed
            }
            XCTAssertEqual(context.store.outputTokens, 12)
            XCTAssertEqual(context.store.promptTokens, 4)
            XCTAssertEqual(context.store.lastMeasuredTPS ?? -1, 20, accuracy: 0.001)
        }
    }

    func testUpstreamHTTPErrorPreservesStatusAndBodyAndMarksGenerationFailed() async throws {
        let fixture = MockOllamaResponse.httpError()
        try await withProxy(response: fixture) { context in
            let (data, response) = try await URLSession.shared.data(for: context.request())
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
            XCTAssertEqual(data, fixture.body)
            try await waitForCondition("Upstream HTTP error was not reflected in metrics") {
                context.store.activeGeneration?.state == .errored
            }
            XCTAssertNotNil(context.store.generationError)
            XCTAssertEqual(context.store.currentTPS, 0)
            XCTAssertNil(context.store.lastMeasuredTPS)
            XCTAssertTrue(context.proxy.isRunning, "A request error must not stop the listener")
        }
    }

    func testUnavailableUpstreamReturnsBadGatewayAndErrorState() async throws {
        let reservation = MockOllamaServer()
        try await reservation.start()
        let unavailablePort = reservation.port
        await reservation.stop()
        let store = MetricsStore()
        let proxy = ProxyManager(
            listenPort: 0, ollamaHost: "127.0.0.1", ollamaPort: unavailablePort,
            metricsStore: store)
        do {
            try await proxy.start()
            let port = try XCTUnwrap(proxy.boundPort)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/generate")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{\"model\":\"fixture-model\"}".utf8)
            request.timeoutInterval = 5
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
            try await waitForCondition("Unavailable upstream did not mark request errored") {
                store.activeGeneration?.state == .errored
            }
            XCTAssertNotNil(store.generationError)
            XCTAssertEqual(store.currentTPS, 0)
        } catch {
            await proxy.stop()
            throw error
        }
        await proxy.stop()
    }

    func testPortConflictCanRetryAndStopReleasesActualSocket() async throws {
        let occupant = MockOllamaServer()
        try await occupant.start()
        let port = occupant.port
        let store = MetricsStore()
        let proxy = ProxyManager(listenPort: port, metricsStore: store)
        do {
            do {
                try await proxy.start()
                XCTFail("Binding an occupied loopback port should fail")
            } catch {
                XCTAssertFalse(proxy.isRunning)
                XCTAssertFalse(proxy.isStarting)
                XCTAssertNotNil(proxy.lastError)
                XCTAssertEqual(store.proxyState, .failed)
            }
            await occupant.stop()
            try await proxy.start()
            XCTAssertTrue(proxy.isRunning)
            XCTAssertEqual(proxy.boundPort, port)
            XCTAssertNil(proxy.lastError)
            XCTAssertEqual(store.proxyState, .listening)
            await proxy.stop()
            await proxy.stop()
            XCTAssertFalse(proxy.isRunning)
            XCTAssertNil(proxy.boundPort)
            XCTAssertEqual(store.proxyState, .stopped)
            let replacement = MockOllamaServer(port: port)
            try await replacement.start()
            await replacement.stop()
        } catch {
            await proxy.stop()
            await occupant.stop()
            throw error
        }
    }

    func testSequentialRequestsGetDistinctSessionsAndDoNotAccumulateCounts() async throws {
        try await withProxy { context in
            _ = try await URLSession.shared.data(for: context.request())
            try await waitForCondition("First request did not finish") {
                context.store.activeGeneration?.state == .completed
            }
            let firstID = try XCTUnwrap(context.store.activeGeneration?.id)
            _ = try await URLSession.shared.data(for: context.request())
            try await waitForCondition("Second request did not get a completed session") {
                context.store.activeGeneration?.id != firstID
                    && context.store.activeGeneration?.state == .completed
            }
            XCTAssertEqual(context.store.outputTokens, 12)
            XCTAssertEqual(context.store.promptTokens, 4)
            XCTAssertEqual(context.store.lastMeasuredTPS ?? -1, 20, accuracy: 0.001)
            XCTAssertEqual(context.mock.requests.count, 2)
        }
    }

    func testRestartUsesNewUpstreamConfiguration() async throws {
        let response = MockOllamaResponse(firstBytes: Array("{\"models\":[\"new-upstream\"]}".utf8))
        let replacementUpstream = MockOllamaServer(response: response)
        try await replacementUpstream.start()
        do {
            try await withProxy { context in
                try await context.proxy.restart(
                    listenPort: 0, ollamaHost: "127.0.0.1", ollamaPort: replacementUpstream.port)
                let port = try XCTUnwrap(context.proxy.boundPort)
                let url = URL(string: "http://127.0.0.1:\(port)/api/tags")!
                let (data, result) = try await URLSession.shared.data(from: url)
                XCTAssertEqual((result as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertEqual(data, response.body)
                XCTAssertEqual(replacementUpstream.requests.count, 1)
                XCTAssertTrue(context.mock.requests.isEmpty)
                XCTAssertTrue(context.proxy.isRunning)
                XCTAssertNil(context.proxy.lastError)
            }
        } catch {
            await replacementUpstream.stop()
            throw error
        }
        await replacementUpstream.stop()
    }
}
