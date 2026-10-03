import Foundation
import NIO
import NIOHTTP1
import XCTest

@testable import FluxLLM

final class StreamBodyCoalescerTests: XCTestCase {
    func testEligibleBodyBecomesOneWireWriteWithExactUnicodeAndBinaryBytes() throws {
        let harness = try CoalescerHarness()
        defer { harness.finish() }
        try harness.head()
        for bytes in [Array("café 🌊\n".utf8), Array(UInt8.min...UInt8.max)] {
            var body = ByteBuffer(bytes: [0xAA, 0xBB] + bytes + [0xCC])
            body.moveReaderIndex(forwardBy: 2)
            body.moveWriterIndex(to: body.writerIndex - 1)
            let writes = harness.probe.parts.count
            let flushes = harness.probe.flushes
            harness.body(body)
            XCTAssertEqual(harness.probe.parts.count - writes, 1)
            XCTAssertEqual(harness.probe.flushes - flushes, 1)
            XCTAssertEqual(try harness.readWire(), framed(bytes))
            XCTAssertEqual(
                Array(body.readableBytesView), bytes,
                "Coalescing must not change the caller's buffer indices or storage")
        }
    }

    func testSmallBodyBoundAndLargerBodyFallbackPreserveEveryByte() throws {
        let harness = try CoalescerHarness()
        defer { harness.finish() }
        try harness.head()
        for count in [
            1, SmallResponseBodyCoalescer.maximumBodyBytes,
            SmallResponseBodyCoalescer.maximumBodyBytes + 1,
        ] {
            let bytes = [UInt8](repeating: 0xA5, count: count)
            let writes = harness.probe.parts.count
            harness.body(ByteBuffer(bytes: bytes))
            XCTAssertEqual(
                harness.probe.parts.count - writes,
                count <= SmallResponseBodyCoalescer.maximumBodyBytes ? 1 : 3)
            XCTAssertEqual(try harness.readWire(), framed(bytes))
        }
    }

    func testPromisedBodyRetainsEncoderPromisesAndImmediateFlush() throws {
        let harness = try CoalescerHarness()
        defer { harness.finish() }
        try harness.head()
        let completed = expectation(description: "Body write promise completed")
        let promise = harness.loop.makePromise(of: Void.self)
        promise.futureResult.whenSuccess { completed.fulfill() }
        let writes = harness.probe.parts.count
        let flushes = harness.probe.flushes
        harness.body(ByteBuffer(string: "promised"), promise: promise)
        XCTAssertEqual(harness.probe.parts.count - writes, 3)
        XCTAssertTrue(harness.probe.parts.suffix(3).allSatisfy(\.promised))
        XCTAssertEqual(harness.probe.flushes - flushes, 1)
        XCTAssertEqual(try harness.readWire(), framed(Array("promised".utf8)))
        wait(for: [completed], timeout: 0.1)
    }

    func testEmptyBodyRetainsEncoderBehaviorAndDoesNotDelayTheNextBody() throws {
        let harness = try CoalescerHarness()
        defer { harness.finish() }
        try harness.head()
        let writes = harness.probe.parts.count
        let flushes = harness.probe.flushes
        harness.body(ByteBuffer())
        XCTAssertEqual(
            harness.probe.parts.count, writes + 1,
            "The encoder preserves an empty IOData write without chunk framing")
        XCTAssertEqual(harness.probe.flushes, flushes + 1)
        XCTAssertEqual(try harness.readWire(), [])
        harness.body(ByteBuffer(string: "next"))
        XCTAssertEqual(harness.probe.parts.count, writes + 2)
        XCTAssertEqual(try harness.readWire(), framed(Array("next".utf8)))
    }

    func testNoBytesAreHeldAcrossBodiesTrailersOrSubsequentResponses() throws {
        let harness = try CoalescerHarness()
        defer { harness.finish() }
        for index in 0..<2 {
            try harness.head()
            for body in ["first-\(index)", "second-\(index)"] {
                let writes = harness.probe.parts.count
                harness.body(ByteBuffer(string: body))
                XCTAssertEqual(harness.probe.parts.count - writes, 1)
                XCTAssertEqual(try harness.readWire(), framed(Array(body.utf8)))
            }
            let ended = expectation(description: "Response end remains promised")
            let promise = harness.loop.makePromise(of: Void.self)
            promise.futureResult.whenSuccess { ended.fulfill() }
            harness.channel.writeAndFlush(
                HTTPServerResponsePart.end(["x-check": "\(index)"]), promise: promise)
            XCTAssertEqual(try harness.readWire(), Array("0\r\nx-check: \(index)\r\n\r\n".utf8))
            wait(for: [ended], timeout: 0.1)
            let writes = harness.probe.parts.count
            harness.channel.flush()
            XCTAssertEqual(harness.probe.parts.count, writes)
            XCTAssertEqual(try harness.readWire(), [])
        }
    }

    func testScopeWithoutFlushDrainsBeforeReturningAndLaterFlushDoesNotDuplicate() throws {
        let harness = try CoalescerHarness()
        defer { harness.finish() }
        try harness.head()
        let writes = harness.probe.parts.count
        let flushes = harness.probe.flushes
        harness.coalescer.withBodyWrite(byteCount: 3) {
            harness.channel.write(
                HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "one"))),
                promise: nil)
        }
        XCTAssertEqual(
            harness.probe.parts.count, writes + 1,
            "Temporary encoded bytes must leave the coalescer before the caller returns")
        XCTAssertEqual(harness.probe.flushes, flushes)
        harness.channel.flush()
        XCTAssertEqual(harness.probe.parts.count, writes + 1)
        XCTAssertEqual(try harness.readWire(), framed(Array("one".utf8)))
    }

    func testUnexpectedEncodedSizeFallsBackInOrderWithoutExceedingTheScope() throws {
        let harness = try CoalescerHarness()
        defer { harness.finish() }
        try harness.head()
        let bytes = [UInt8](repeating: 0xFE, count: 128)
        let writes = harness.probe.parts.count
        harness.coalescer.withBodyWrite(byteCount: 1) {
            harness.channel.writeAndFlush(
                HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: bytes))), promise: nil)
        }
        XCTAssertEqual(harness.probe.parts.count - writes, 3)
        XCTAssertEqual(try harness.readWire(), framed(bytes))
        let afterFallback = harness.probe.parts.count
        harness.body(ByteBuffer(string: "next"))
        XCTAssertEqual(harness.probe.parts.count - afterFallback, 1)
        XCTAssertEqual(try harness.readWire(), framed(Array("next".utf8)))
    }

    func testNestedScopeFlushesEarlierBytesBeforePassingThroughInnerWrite() throws {
        let harness = try CoalescerHarness()
        defer { harness.finish() }
        try harness.head()
        let writes = harness.probe.parts.count
        harness.coalescer.withBodyWrite(byteCount: 3) {
            harness.channel.write(
                HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "one"))),
                promise: nil)
            harness.coalescer.withBodyWrite(byteCount: 3) {
                harness.channel.writeAndFlush(
                    HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "two"))),
                    promise: nil)
            }
        }
        XCTAssertEqual(
            harness.probe.parts.count - writes, 4,
            "Nested writes fall back after draining the earlier body")
        XCTAssertEqual(
            try harness.readWire(), framed(Array("one".utf8)) + framed(Array("two".utf8)))
        let afterNested = harness.probe.parts.count
        harness.body(ByteBuffer(string: "three"))
        XCTAssertEqual(harness.probe.parts.count - afterNested, 1)
        XCTAssertEqual(try harness.readWire(), framed(Array("three".utf8)))
    }

    func testNonchunkedBodyStaysOneExactWrite() throws {
        for version in [HTTPVersion.http1_0, .http1_1] {
            let harness = try CoalescerHarness()
            defer { harness.finish() }
            try harness.head(chunked: false, version: version)
            let bytes = Array("raw café 🌊".utf8)
            let writes = harness.probe.parts.count
            harness.body(ByteBuffer(bytes: bytes))
            XCTAssertEqual(harness.probe.parts.count - writes, 1)
            XCTAssertEqual(try harness.readWire(), bytes)
        }
    }

    func testFirstFlushEndsCollectionEvenBeforeTheScopeReturns() throws {
        let harness = try CoalescerHarness()
        defer { harness.finish() }
        try harness.head()
        let writes = harness.probe.parts.count
        let flushes = harness.probe.flushes
        harness.coalescer.withBodyWrite(byteCount: 6) {
            for body in ["one", "two"] {
                harness.channel.writeAndFlush(
                    HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: body))), promise: nil
                )
            }
        }
        XCTAssertEqual(harness.probe.parts.count - writes, 4)
        XCTAssertEqual(harness.probe.flushes - flushes, 2)
        XCTAssertEqual(
            try harness.readWire(), framed(Array("one".utf8)) + framed(Array("two".utf8)))
    }

    func testClosingDuringScopeDrainsStagedBytesBeforeClosingWithoutLaterDuplication() throws {
        let harness = try CoalescerHarness()
        defer { harness.finish() }
        try harness.head()
        let writes = harness.probe.parts.count
        harness.coalescer.withBodyWrite(byteCount: 3) {
            harness.channel.write(
                HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "one"))),
                promise: nil)
            XCTAssertEqual(harness.probe.parts.count, writes)
            harness.channel.close(promise: nil)
            XCTAssertEqual(harness.probe.parts.count, writes + 1)
        }
        XCTAssertFalse(harness.channel.isActive)
        XCTAssertEqual(harness.probe.parts.count, writes + 1)
    }

    func testFileRegionFallsBackWithoutCopyingOrCombiningItsFraming() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3, 4]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try NIOFileHandle(path: file.path)
        defer { try? handle.close() }
        let harness = try CoalescerHarness()
        defer { harness.finish() }
        try harness.head()
        let writes = harness.probe.parts.count
        let region = FileRegion(fileHandle: handle, readerIndex: 0, endIndex: 4)
        harness.coalescer.withBodyWrite(byteCount: 4) {
            harness.channel.writeAndFlush(
                HTTPServerResponsePart.body(.fileRegion(region)), promise: nil)
        }
        XCTAssertEqual(harness.probe.parts.count - writes, 3)
        guard
            case .byteBuffer(let prefix) = try XCTUnwrap(
                try harness.channel.readOutbound(as: IOData.self)),
            case .fileRegion(let forwarded) = try XCTUnwrap(
                try harness.channel.readOutbound(as: IOData.self)),
            case .byteBuffer(let suffix) = try XCTUnwrap(
                try harness.channel.readOutbound(as: IOData.self))
        else {
            return XCTFail("The original chunk prefix, file region and suffix must remain separate")
        }
        XCTAssertEqual(Array(prefix.readableBytesView), Array("4\r\n".utf8))
        XCTAssertTrue(forwarded.fileHandle === handle)
        XCTAssertEqual(forwarded.readerIndex, 0)
        XCTAssertEqual(forwarded.endIndex, 4)
        XCTAssertEqual(Array(suffix.readableBytesView), [13, 10])
        XCTAssertNil(try harness.channel.readOutbound(as: IOData.self))
    }

    func testFinishedChannelReleasesItsCoalescerAfterACompletedBodyScope() throws {
        var harness: CoalescerHarness? = try CoalescerHarness()
        weak var coalescer = harness?.coalescer
        try harness?.head()
        harness?.body(ByteBuffer(string: "completed"))
        _ = try harness?.readWire()
        XCTAssertNotNil(coalescer)
        harness?.finish()
        harness = nil
        XCTAssertNil(coalescer, "A completed scope must not retain a channel or handler cycle")
    }

    private func framed(_ bytes: [UInt8]) -> [UInt8] {
        Array("\(String(bytes.count, radix: 16))\r\n".utf8) + bytes + [13, 10]
    }
}

private final class CoalescerHarness {
    let loop = EmbeddedEventLoop()
    let coalescer = SmallResponseBodyCoalescer()
    let probe = EncodedWriteProbe()
    let channel: EmbeddedChannel

    init() throws {
        channel = EmbeddedChannel(loop: loop)
        try channel.pipeline.syncOperations.addHandlers(probe, coalescer, HTTPResponseEncoder())
        channel.connect(to: try SocketAddress(ipAddress: "127.0.0.1", port: 1), promise: nil)
    }

    func head(chunked: Bool = true, version: HTTPVersion = .http1_1) throws {
        channel.writeAndFlush(
            HTTPServerResponsePart.head(
                HTTPResponseHead(
                    version: version, status: .ok,
                    headers: chunked ? ["transfer-encoding": "chunked"] : ["content-length": "1024"]
                )),
            promise: nil)
        let bytes = try readWire()
        XCTAssertTrue(
            String(decoding: bytes, as: UTF8.self).hasPrefix(
                "HTTP/\(version.major).\(version.minor) 200 OK\r\n"))
    }

    func body(_ buffer: ByteBuffer, promise: EventLoopPromise<Void>? = nil) {
        coalescer.withBodyWrite(byteCount: buffer.readableBytes) {
            channel.writeAndFlush(
                HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: promise)
        }
    }

    func readWire() throws -> [UInt8] {
        var bytes: [UInt8] = []
        while let part = try channel.readOutbound(as: IOData.self) {
            switch part {
            case .byteBuffer(let buffer): bytes.append(contentsOf: buffer.readableBytesView)
            case .fileRegion: XCTFail("Unexpected file region")
            }
        }
        return bytes
    }

    func finish() {
        channel.close(promise: nil)
        loop.run()
        _ = try? channel.finish(acceptAlreadyClosed: true)
    }
}

private final class EncodedWriteProbe: ChannelOutboundHandler {
    typealias OutboundIn = IOData
    struct Part { let promised: Bool }
    var parts: [Part] = []
    var flushes = 0

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        parts.append(Part(promised: promise != nil))
        context.write(data, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        flushes += 1
        context.flush()
    }
}
