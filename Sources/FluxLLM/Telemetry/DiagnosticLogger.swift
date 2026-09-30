import Foundation
import Observation

/// Explicitly enabled, session-only diagnostics. Records contain metadata, never request content.
@MainActor
@Observable
public final class DiagnosticLogger {
    public enum Event: String, Codable, Sendable {
        case monitoringStarted, monitoringStopped, sample
        case requestStarted, requestUpdated, requestFinished, requestFailed
        case toolCall, toolResult, connectionChanged, performance
    }

    public private(set) var isEnabled = false
    public private(set) var isUpdating = false
    public private(set) var errorMessage: String?
    public private(set) var droppedCount = 0

    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let outputFactory:
        @Sendable (Configuration) -> any DiagnosticLogOutput
    @ObservationIgnored private var writer: DiagnosticLogWriter?
    @ObservationIgnored private var encoder: JSONEncoder?
    @ObservationIgnored private var transitionWaiters: [CheckedContinuation<Void, Never>] = []

    public convenience init() {
        self.init(configuration: Configuration())
    }

    convenience init(configuration: Configuration) {
        self.init(configuration: configuration) { DiagnosticFileOutput(configuration: $0) }
    }

    init(
        configuration: Configuration,
        outputFactory: @escaping @Sendable (Configuration) -> any DiagnosticLogOutput
    ) {
        self.configuration = configuration
        self.outputFactory = outputFactory
    }

    /// Disabling stops acceptance immediately and acknowledges only after the writer has closed.
    public func setEnabled(_ enabled: Bool, directory: URL? = nil) async throws {
        while isUpdating {
            await withCheckedContinuation { transitionWaiters.append($0) }
        }
        guard enabled != isEnabled || (!enabled && writer != nil) else { return }
        isUpdating = true
        defer {
            isUpdating = false
            let waiting = transitionWaiters
            transitionWaiters.removeAll()
            for continuation in waiting { continuation.resume() }
        }
        errorMessage = nil

        if !enabled {
            isEnabled = false
            encoder = nil
            guard let closing = writer else { return }
            closing.stopAccepting()
            do {
                try await closing.finish()
                droppedCount = closing.droppedCount
                writer = nil
            } catch {
                droppedCount = closing.droppedCount
                writer = nil
                errorMessage = "Diagnostic logging stopped after a file error."
                throw error
            }
            return
        }

        // A failed writer is already closed, but finish its serial queue before replacing it.
        if let previous = writer {
            previous.stopAccepting()
            _ = try? await previous.finish()
            writer = nil
        }
        let next = DiagnosticLogWriter(
            configuration: configuration, output: outputFactory(configuration))
        writer = next
        next.onFailure = { [weak self, weak next] in
            // One notification per writer failure, never one Task per recorded event.
            Task { @MainActor [weak self, weak next] in
                guard let self, let next, self.writer === next else { return }
                self.isEnabled = false
                self.encoder = nil
                self.droppedCount = next.droppedCount
                self.errorMessage = "Diagnostic logging stopped after a file error."
            }
        }
        do {
            let destination =
                directory
                ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/FluxLLM", isDirectory: true)
            try await next.open(directory: destination)
            encoder = JSONEncoder()
            droppedCount = 0
            isEnabled = true
        } catch {
            writer = nil
            errorMessage = "Diagnostic logging could not open its log file."
            throw error
        }
    }

    /// The disabled path returns before reading a clock, encoding, scheduling, or touching disk.
    public func record(
        _ event: Event, requestID: UUID? = nil, backend: BackendKind? = nil,
        durationMilliseconds: Double? = nil, count: Int? = nil
    ) {
        guard isEnabled, let writer, let encoder else { return }
        let record = Record(
            timestamp: Date().timeIntervalSince1970, event: event, requestID: requestID,
            backend: backend?.rawValue,
            durationMilliseconds: durationMilliseconds.flatMap { $0.isFinite ? $0 : nil },
            count: count)
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        droppedCount = writer.enqueue(data)
    }

    struct Configuration: Sendable {
        var queueBytes = 128 * 1_024
        var batchBytes = 16 * 1_024
        var fileBytes = 1_024 * 1_024
        var fileCount = 3

        var maximumRecordBytes: Int { min(queueBytes, batchBytes, fileBytes) }
    }

    private struct Record: Encodable {
        let timestamp: Double
        let event: Event
        let requestID: UUID?
        let backend: String?
        let durationMilliseconds: Double?
        let count: Int?
    }

    enum LoggerError: LocalizedError {
        case fileUnavailable

        var errorDescription: String? {
            switch self {
            case .fileUnavailable: "The diagnostic log file is unavailable."
            }
        }
    }
}

/// Implementations are accessed exclusively on the writer's serial queue.
protocol DiagnosticLogOutput: AnyObject, Sendable {
    func open(directory: URL) throws
    func write(_ data: Data) throws
    func close() throws
}

/// The lock protects admission and queue bounds; all file operations use one serial queue.
private final class DiagnosticLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.cmorgan.FluxLLM.diagnostics", qos: .utility)
    private let lock = NSLock()
    private let configuration: DiagnosticLogger.Configuration
    private let output: any DiagnosticLogOutput
    private var pending: [Data] = []
    private var queuedBytes = 0
    private var dropped = 0
    private var accepting = false
    private var scheduled = false
    private var failure: Error?
    // Serial-queue state; never accessed by producers.
    private var closed = true
    var onFailure: (@Sendable () -> Void)?

    init(configuration: DiagnosticLogger.Configuration, output: any DiagnosticLogOutput) {
        precondition(configuration.maximumRecordBytes > 0 && configuration.fileCount > 0)
        self.configuration = configuration
        self.output = output
    }

    var droppedCount: Int { lock.withLock { dropped } }

    func open(directory: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.output.open(directory: directory)
                    self.closed = false
                    self.lock.withLock { self.accepting = true }
                    continuation.resume()
                } catch {
                    try? self.output.close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func enqueue(_ data: Data) -> Int {
        lock.lock()
        guard accepting else {
            let result = dropped
            lock.unlock()
            return result
        }
        guard data.count <= configuration.maximumRecordBytes,
            queuedBytes <= configuration.queueBytes - data.count
        else {
            dropped += 1
            let result = dropped
            lock.unlock()
            return result
        }
        pending.append(data)
        queuedBytes += data.count
        let shouldSchedule = !scheduled
        scheduled = true
        let result = dropped
        lock.unlock()
        if shouldSchedule { queue.async { self.drain() } }
        return result
    }

    func stopAccepting() { lock.withLock { accepting = false } }

    func finish() async throws {
        stopAccepting()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.drain()
                do {
                    if !self.closed {
                        self.closed = true
                        try self.output.close()
                    }
                    if let error = self.lock.withLock({ self.failure }) { throw error }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func drain() {
        while true {
            let batch: (data: Data, count: Int)? = lock.withLock {
                guard !pending.isEmpty else {
                    scheduled = false
                    return nil
                }
                var data = Data()
                var count = 0
                for record in pending {
                    guard
                        data.count + record.count
                            <= min(configuration.batchBytes, configuration.fileBytes)
                    else { break }
                    data.append(record)
                    count += 1
                }
                pending.removeFirst(count)
                // In-flight bytes remain charged to the bound until the write completes.
                return (data, count)
            }
            guard let batch else { return }
            do {
                try output.write(batch.data)
                lock.withLock { queuedBytes -= batch.data.count }
            } catch {
                lock.withLock {
                    accepting = false
                    failure = error
                    dropped += batch.count + pending.count
                    pending.removeAll(keepingCapacity: false)
                    queuedBytes = 0
                    scheduled = false
                }
                if !closed {
                    closed = true
                    try? output.close()
                }
                onFailure?()
                return
            }
        }
    }
}

private final class DiagnosticFileOutput: DiagnosticLogOutput, @unchecked Sendable {
    private let configuration: DiagnosticLogger.Configuration
    private var directory: URL?
    private var handle: FileHandle?
    private var size = 0

    init(configuration: DiagnosticLogger.Configuration) { self.configuration = configuration }

    func open(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try openCurrent()
        if size > configuration.fileBytes { try rotate() }
    }

    func write(_ data: Data) throws {
        if size + data.count > configuration.fileBytes { try rotate() }
        guard let handle else { throw DiagnosticLogger.LoggerError.fileUnavailable }
        try handle.write(contentsOf: data)
        size += data.count
    }

    func close() throws {
        let closing = handle
        handle = nil
        try closing?.close()
    }

    private func path(_ index: Int) throws -> URL {
        guard let directory else { throw DiagnosticLogger.LoggerError.fileUnavailable }
        return directory.appendingPathComponent(
            index == 0 ? "diagnostics.jsonl" : "diagnostics.\(index).jsonl")
    }

    private func openCurrent() throws {
        let url = try path(0)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw DiagnosticLogger.LoggerError.fileUnavailable
            }
        }
        handle = try FileHandle(forWritingTo: url)
        size = Int(try handle!.seekToEnd())
    }

    private func rotate() throws {
        try close()
        let files = FileManager.default
        let oldest = try path(configuration.fileCount - 1)
        if files.fileExists(atPath: oldest.path) { try files.removeItem(at: oldest) }
        if configuration.fileCount > 1 {
            for index in stride(from: configuration.fileCount - 2, through: 0, by: -1) {
                let source = try path(index)
                if files.fileExists(atPath: source.path) {
                    try files.moveItem(at: source, to: path(index + 1))
                }
            }
        }
        try openCurrent()
    }
}
