import Foundation
import NIO
import NIOHTTP1
import XCTest

@testable import FluxLLM

final class StreamBodyWriteTests: XCTestCase {
    func testBodyOptimizationPreservesEncodedBytesAndImmediateFlushes() throws {
        for optimized in [false, true] {
            let harness = try StreamWriteHarness(optimized: optimized)
            defer { harness.finish() }
            try harness.sendHead()
            _ = try harness.readWire()
            let first = "{\"response\":\"café 🌊\",\"done\":false}\n"
            let second = "{\"response\":\"second\",\"done\":false}\n"
            for text in [first, second] {
                let previousFlushes = harness.probe.flushes
                try harness.sendBody(text)
                XCTAssertEqual(harness.probe.flushes, previousFlushes + 1)
                XCTAssertEqual(
                    try harness.readWire(),
                    "\(String(text.utf8.count, radix: 16))\r\n\(text)\r\n")
                XCTAssertTrue(harness.downstream.isActive)
            }
            XCTAssertEqual(harness.probe.promisedParts, [true, !optimized, !optimized])
            XCTAssertEqual(harness.events.snapshots.first?.outputTokens, 1)
            harness.loop.advanceTime(by: .milliseconds(50))
            XCTAssertEqual(harness.events.snapshots.last?.outputTokens, 2)
        }
    }

    func testHEADAndCONNECTKeepBodyFailurePromises() throws {
        for method in [HTTPMethod.HEAD, .CONNECT] {
            let harness = try StreamWriteHarness(optimized: true, method: method)
            defer { harness.finish() }
            try harness.sendHead()
            harness.probe.bodyFailure = .promiseOnly
            try harness.sendBody("{\"response\":\"rejected\"}\n")
            XCTAssertEqual(harness.probe.promisedParts, [true, true])
            XCTAssertEqual(harness.events.kinds, ["began", "cancelled"])
            XCTAssertFalse(harness.upstream.isActive)
            XCTAssertFalse(harness.downstream.isActive)
        }
    }

    func testUninstalledLifecycleCannotEnableUnpromisedWrites() throws {
        let harness = try StreamWriteHarness(optimized: true, installLifecycle: false)
        defer { harness.finish() }
        try harness.sendHead()
        try harness.sendBody("{\"response\":\"one\"}\n")
        XCTAssertEqual(harness.probe.promisedParts, [true, true])
    }

    func testSynchronousSocketFailureCancelsBeforeFailedTerminalBodyIsTapped() throws {
        let harness = try StreamWriteHarness(optimized: true)
        defer { harness.finish() }
        try harness.sendHead()
        harness.probe.bodyFailure = .synchronousClose
        try harness.sendBody(StreamWriteHarness.terminal)
        XCTAssertEqual(harness.probe.promisedParts, [true, false])
        XCTAssertEqual(harness.events.kinds, ["began", "cancelled"])
        XCTAssertTrue(harness.events.snapshots.isEmpty)
        XCTAssertFalse(harness.upstream.isActive)
        XCTAssertFalse(harness.downstream.isActive)
    }

    func testAsynchronousSocketFailureFlushesAcceptedAccountingAndCancelsExactlyOnce() throws {
        let harness = try StreamWriteHarness(optimized: true)
        defer { harness.finish() }
        try harness.sendHead()
        try harness.sendBody("{\"response\":\"one\"}\n")
        harness.probe.bodyFailure = .asynchronousClose
        try harness.sendBody("{\"response\":\"two\"}\n")
        XCTAssertEqual(harness.events.kinds, ["began", "live:1"])
        XCTAssertTrue(harness.upstream.isActive)
        harness.loop.advanceTime(by: .milliseconds(1))
        XCTAssertEqual(harness.events.kinds, ["began", "live:1", "live:2", "cancelled"])
        XCTAssertFalse(harness.upstream.isActive)
        XCTAssertFalse(harness.downstream.isActive)
        harness.loop.advanceTime(by: .seconds(1))
        harness.relay.cancel()
        harness.relay.fail("late transport failure")
        XCTAssertEqual(harness.events.kinds, ["began", "live:1", "live:2", "cancelled"])
    }

    func testOutputClosureWhileChannelIsActiveCancelsAndClosesBothSides() throws {
        let harness = try StreamWriteHarness(optimized: true)
        defer { harness.finish() }
        try harness.sendHead()
        try harness.sendBody("{\"response\":\"one\"}\n")
        XCTAssertTrue(harness.downstream.isActive)
        harness.downstream.pipeline.fireUserInboundEventTriggered(ChannelEvent.outputClosed)
        XCTAssertEqual(harness.events.kinds, ["began", "live:1", "cancelled"])
        XCTAssertFalse(harness.upstream.isActive)
        XCTAssertFalse(harness.downstream.isActive)
    }

    func testHeadFailureRemainsObserved() throws {
        let harness = try StreamWriteHarness(optimized: true)
        defer { harness.finish() }
        harness.probe.rejectHead = true
        try harness.sendHead()
        XCTAssertEqual(harness.probe.promisedParts, [true])
        XCTAssertEqual(harness.events.kinds, ["began", "cancelled"])
        XCTAssertFalse(harness.upstream.isActive)
        XCTAssertFalse(harness.downstream.isActive)
    }

    func testTerminalWriteKeepsPromiseAndDrainsBeforeCloseIncludingDeferredFailure() throws {
        for fail in [false, true] {
            let harness = try StreamWriteHarness(optimized: true)
            defer { harness.finish() }
            try harness.sendHead()
            try harness.sendBody(StreamWriteHarness.terminal)
            _ = try harness.readWire()
            harness.probe.holdEnd = true
            try harness.upstream.writeInbound(HTTPClientResponsePart.end(nil))
            XCTAssertEqual(harness.probe.promisedParts, [true, false, true])
            XCTAssertTrue(harness.upstream.isActive)
            XCTAssertTrue(harness.downstream.isActive)
            XCTAssertEqual(harness.events.kinds, ["began", "finished:7"])
            harness.probe.releaseEnd(failing: fail)
            XCTAssertFalse(harness.upstream.isActive)
            XCTAssertFalse(harness.downstream.isActive)
            XCTAssertEqual(
                harness.events.kinds, ["began", "finished:7"],
                "Existing terminal accounting is independent of later delivery failure")
            XCTAssertEqual(try harness.readWire(), fail ? "" : "0\r\n\r\n")
        }
    }
}

private final class StreamWriteHarness {
    static let terminal =
        "{\"done\":true,\"eval_count\":7,\"prompt_eval_count\":3,\"eval_duration\":1000000000}\n"
    let loop: EmbeddedEventLoop
    let upstream: EmbeddedChannel
    let downstream: EmbeddedChannel
    let probe = StreamWriteProbe()
    let events: StreamWriteEvents
    let relay: GenerationRelay

    init(optimized: Bool, method: HTTPMethod = .POST, installLifecycle: Bool = true) throws {
        let loop = EmbeddedEventLoop()
        self.loop = loop
        let events = StreamWriteEvents()
        self.events = events
        upstream = EmbeddedChannel(loop: loop)
        downstream = EmbeddedChannel(loop: loop)
        relay = GenerationRelay(request: GenerationRequest(), sink: { events.append($0) })
        try downstream.pipeline.syncOperations.addHandlers(HTTPResponseEncoder(), probe)
        let lifecycle = optimized ? StreamBodyWriteLifecycle(upstream: upstream, relay: relay) : nil
        if let lifecycle, installLifecycle {
            try downstream.pipeline.syncOperations.addHandler(lifecycle)
        }
        try upstream.pipeline.syncOperations.addHandler(
            StreamTapper(
                serverChannel: downstream, relay: relay, isGeneration: true,
                requestMethod: method, bodyWriteLifecycle: lifecycle))
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
        upstream.connect(to: address, promise: nil)
        downstream.connect(to: address, promise: nil)
    }

    func sendHead() throws {
        try upstream.writeInbound(
            HTTPClientResponsePart.head(
                HTTPResponseHead(
                    version: .http1_1, status: .ok,
                    headers: [
                        "content-type": "application/x-ndjson",
                        "transfer-encoding": "chunked",
                    ])))
    }

    func sendBody(_ text: String) throws {
        try upstream.writeInbound(HTTPClientResponsePart.body(ByteBuffer(string: text)))
    }

    func readWire() throws -> String {
        var bytes: [UInt8] = []
        while let part = try downstream.readOutbound(as: IOData.self) {
            switch part {
            case .byteBuffer(let buffer): bytes.append(contentsOf: buffer.readableBytesView)
            case .fileRegion: XCTFail("Unexpected file region")
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func finish() {
        probe.releaseEnd(failing: true)
        upstream.close(promise: nil)
        downstream.close(promise: nil)
        loop.run()
        _ = try? upstream.finish(acceptAlreadyClosed: true)
        _ = try? downstream.finish(acceptAlreadyClosed: true)
    }
}

/// The failure paths model socket closure (synchronous or deferred), plus a
/// promise-only encoder rejection. No wall-clock sleeps or live socket races.
private final class StreamWriteProbe: ChannelOutboundHandler {
    typealias OutboundIn = HTTPServerResponsePart
    enum BodyFailure { case synchronousClose, asynchronousClose, promiseOnly }
    var bodyFailure: BodyFailure?
    var rejectHead = false
    var holdEnd = false
    var promisedParts: [Bool] = []
    var flushes = 0
    private var heldEnd: (ChannelHandlerContext, NIOAny, EventLoopPromise<Void>?)?

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        promisedParts.append(promise != nil)
        switch unwrapOutboundIn(data) {
        case .head where rejectHead:
            promise?.fail(StreamWriteFailure())
            return
        case .body:
            if let failure = bodyFailure {
                bodyFailure = nil
                switch failure {
                case .promiseOnly:
                    promise?.fail(StreamWriteFailure())
                case .synchronousClose:
                    promise?.fail(StreamWriteFailure())
                    context.close(promise: nil)
                case .asynchronousClose:
                    let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
                    context.eventLoop.scheduleTask(in: .milliseconds(1)) {
                        promise?.fail(StreamWriteFailure())
                        bound.value.close(promise: nil)
                    }
                }
                return
            }
        case .end where holdEnd:
            heldEnd = (context, data, promise)
            return
        default: break
        }
        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        flushes += 1
        context.flush()
    }

    func releaseEnd(failing: Bool) {
        guard let (context, data, promise) = heldEnd else { return }
        heldEnd = nil
        if failing {
            promise?.fail(StreamWriteFailure())
        } else {
            context.writeAndFlush(data, promise: promise)
        }
    }
}

private struct StreamWriteFailure: Error {}

private final class StreamWriteEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [GenerationEvent] = []
    func append(_ event: GenerationEvent) {
        lock.lock()
        defer { lock.unlock() }
        values.append(event)
    }
    var events: [GenerationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
    var snapshots: [GenerationSnapshot] {
        events.compactMap { if case .updated(_, let value) = $0 { value } else { nil } }
    }
    var kinds: [String] {
        events.map {
            switch $0 {
            case .began: "began"
            case .updated(_, let snapshot):
                "\(snapshot.finished ? "finished" : "live"):\(snapshot.outputTokens)"
            case .cancelled: "cancelled"
            case .failed: "failed"
            case .toolActivity: "tools"
            }
        }
    }
}
