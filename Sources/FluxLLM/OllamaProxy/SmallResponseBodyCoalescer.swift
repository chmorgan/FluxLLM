import NIO

/// Combines the encoder's prefix, payload and suffix for one small body write.
/// The existing HTTP encoder still owns all protocol decisions. A scope never
/// spans caller returns or flushes, so each incoming body is forwarded immediately.
final class SmallResponseBodyCoalescer: ChannelOutboundHandler {
    typealias OutboundIn = IOData
    typealias OutboundOut = IOData

    static let maximumBodyBytes = 4_096
    private static let framingAllowance = 32

    private var context: ChannelHandlerContext?
    private var scoped = false
    private var remainingBytes: Int?
    private var capacityLimit = 0
    private var firstBuffer: ByteBuffer?
    private var combinedBuffer: ByteBuffer?
    private let nioDiagnostics: PerformanceNIODiagnostics?

    init(nioDiagnostics: PerformanceNIODiagnostics? = nil) {
        self.nioDiagnostics = nioDiagnostics
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        drain(context: context)
        self.context = nil
    }

    /// Called only around the ordinary same-event-loop, unpromised body path.
    /// Unsupported and nested writes retain their ordinary pipeline behavior.
    func withBodyWrite(byteCount: Int, _ write: () -> Void) {
        // Inclusive subset of forwarding: this includes the encoder and
        // immediate downstream write/flush, not just this handler's copying.
        let cpuScope = nioDiagnostics?.begin(.coalescer, bytes: byteCount, bodies: 1)
        defer { nioDiagnostics?.end(cpuScope) }
        guard let context, context.eventLoop.inEventLoop else {
            write()
            return
        }
        guard !scoped, byteCount > 0, byteCount <= Self.maximumBodyBytes else {
            if scoped { drain(context: context) }
            write()
            return
        }

        scoped = true
        capacityLimit = byteCount + Self.framingAllowance
        remainingBytes = capacityLimit
        defer {
            drain(context: context)
            scoped = false
        }
        write()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard let remainingBytes else {
            context.write(data, promise: promise)
            return
        }
        let value = unwrapOutboundIn(data)
        guard promise == nil, case .byteBuffer(var buffer) = value,
            buffer.readableBytes <= remainingBytes
        else {
            drain(context: context)
            context.write(data, promise: promise)
            return
        }
        self.remainingBytes = remainingBytes - buffer.readableBytes
        if combinedBuffer != nil {
            combinedBuffer!.writeBuffer(&buffer)
        } else if var firstBuffer {
            var combined = context.channel.allocator.buffer(capacity: capacityLimit)
            combined.writeBuffer(&firstBuffer)
            combined.writeBuffer(&buffer)
            self.firstBuffer = nil
            combinedBuffer = combined
        } else {
            // A nonchunked body needs no copy or new allocation.
            firstBuffer = buffer
        }
    }

    func flush(context: ChannelHandlerContext) {
        drain(context: context)
        context.flush()
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        drain(context: context)
        context.close(mode: mode, promise: promise)
    }

    private func drain(context: ChannelHandlerContext) {
        remainingBytes = nil
        capacityLimit = 0
        let buffer = combinedBuffer ?? firstBuffer
        combinedBuffer = nil
        firstBuffer = nil
        guard let buffer else { return }
        context.write(wrapOutboundOut(.byteBuffer(buffer)), promise: nil)
    }
}
