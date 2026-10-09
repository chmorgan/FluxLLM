import Darwin
import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class UnslothWorkerKeyReaderTests: XCTestCase {
    func testPrivateManagedWorkerFileUsesBoundedReadsAndBothProcessBirthChecks() async throws {
        let fixture = try UnslothKeyFileFixture(contents: Data("  fixture-worker-key\n".utf8))
        defer { fixture.remove() }
        let identities = UnslothKeyReaderIdentities()
        let reads = UnslothKeyReadCounter()
        let reader = UnslothWorkerKeyReader(
            identity: { identities.identity($0) },
            readBytes: { descriptor, buffer, count in
                reads.record()
                return Darwin.read(descriptor, buffer, min(3, count))
            })

        let key = try await reader.key(for: fixture.server)

        XCTAssertEqual(key, "fixture-worker-key")
        XCTAssertEqual(identities.calls, [10, 20, 10, 20])
        XCTAssertGreaterThan(reads.count, 2)
    }

    func testConfirmedKeylessWorkerReturnsNilWithoutInspectingProcesses() async throws {
        let identities = UnslothKeyReaderIdentities()
        let reader = UnslothWorkerKeyReader(identity: { identities.identity($0) })
        let key = try await reader.key(for: makeServer(source: .none))
        XCTAssertNil(key)
        XCTAssertTrue(identities.calls.isEmpty)
        await assertUnavailable(makeServer(source: .unavailable), reader: reader)
        XCTAssertTrue(identities.calls.isEmpty)
    }

    func testUnsafeAndUnrelatedFileReferencesFailBeforeReadingContents() async throws {
        let fixture = try UnslothKeyFileFixture()
        defer { fixture.remove() }
        let reads = UnslothKeyReadCounter()
        let reader = UnslothWorkerKeyReader(
            identity: { UnslothKeyReaderIdentities.expected($0) },
            readBytes: { descriptor, buffer, count in
                reads.record()
                return Darwin.read(descriptor, buffer, count)
            })
        let auth = fixture.authDirectoryURL
        let references = [
            UnslothWorkerKeyFile(
                fileURL: URL(string: "https://remote.example/key")!, authDirectoryURL: auth),
            UnslothWorkerKeyFile(
                fileURL: auth.appendingPathComponent("auth.db"), authDirectoryURL: auth),
            UnslothWorkerKeyFile(
                fileURL: auth.appendingPathComponent("llama_api_key_0123456789ABCDEf"),
                authDirectoryURL: auth),
            UnslothWorkerKeyFile(fileURL: fixture.fileURL, authDirectoryURL: fixture.root),
            UnslothWorkerKeyFile(
                fileURL: fixture.root.appendingPathComponent(fixture.fileURL.lastPathComponent),
                authDirectoryURL: auth),
            UnslothWorkerKeyFile(
                fileURL: URL(string: fixture.fileURL.absoluteString + "?token=fixture")!,
                authDirectoryURL: auth),
            UnslothWorkerKeyFile(
                fileURL: URL(
                    fileURLWithPath: auth.path + "/sub/../" + fixture.fileURL.lastPathComponent),
                authDirectoryURL: auth),
            UnslothWorkerKeyFile(
                fileURL: URL(
                    fileURLWithPath: auth.path + "/./" + fixture.fileURL.lastPathComponent),
                authDirectoryURL: auth),
            UnslothWorkerKeyFile(
                fileURL: URL(fileURLWithPath: auth.path + "//" + fixture.fileURL.lastPathComponent),
                authDirectoryURL: auth),
        ]
        for reference in references {
            await assertUnavailable(makeServer(source: .file(reference)), reader: reader)
        }
        XCTAssertEqual(reads.count, 0)
    }

    func testFinalSymlinkCannotReadAnUnrelatedPrivateFile() async throws {
        let fixture = try UnslothKeyFileFixture()
        defer { fixture.remove() }
        let other = fixture.root.appendingPathComponent("unrelated-private-file")
        try Data("unrelated-synthetic-secret".utf8).write(to: other)
        try FileManager.default.removeItem(at: fixture.fileURL)
        try FileManager.default.createSymbolicLink(at: fixture.fileURL, withDestinationURL: other)
        await assertUnavailable(fixture.server, forbidden: ["unrelated-synthetic-secret"])
    }

    func testSymlinksInAnyManagedParentDirectoryAreRejected() async throws {
        for depth in 0..<3 {
            let fixture = try UnslothKeyFileFixture()
            defer { fixture.remove() }
            var original = fixture.authDirectoryURL
            for _ in 0..<depth { original.deleteLastPathComponent() }
            let moved = fixture.root.appendingPathComponent("moved-directory")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
            await assertUnavailable(fixture.server)
        }
    }

    func testFileMustBePrivateNonExecutableReadableAndOwnedByCurrentUser() async throws {
        let fixture = try UnslothKeyFileFixture()
        defer { fixture.remove() }
        for permissions in [mode_t(0o644), 0o640, 0o700, 0o601, 0o200] {
            XCTAssertEqual(fixture.fileURL.path.withCString { Darwin.chmod($0, permissions) }, 0)
            await assertUnavailable(fixture.server)
        }
        XCTAssertEqual(fixture.fileURL.path.withCString { Darwin.chmod($0, 0o600) }, 0)
        let wrongOwner: uid_t = geteuid() == 0 ? 1 : 0
        await assertUnavailable(
            fixture.server,
            reader: UnslothWorkerKeyReader(
                identity: { UnslothKeyReaderIdentities.expected($0) }, ownerUID: wrongOwner))
        XCTAssertEqual(fixture.authDirectoryURL.path.withCString { Darwin.chmod($0, 0o755) }, 0)
        await assertUnavailable(fixture.server)
    }

    func testHardLinkDirectoryAndFIFOAreRejectedWithoutBlocking() async throws {
        for kind in 0..<3 {
            let fixture = try UnslothKeyFileFixture()
            defer { fixture.remove() }
            switch kind {
            case 0:
                try FileManager.default.linkItem(
                    at: fixture.fileURL, to: fixture.root.appendingPathComponent("other-link"))
            case 1:
                try FileManager.default.removeItem(at: fixture.fileURL)
                try FileManager.default.createDirectory(
                    at: fixture.fileURL, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            default:
                try FileManager.default.removeItem(at: fixture.fileURL)
                XCTAssertEqual(fixture.fileURL.path.withCString { Darwin.mkfifo($0, 0o600) }, 0)
            }
            await assertUnavailable(fixture.server)
        }
    }

    func testEmptyOversizedInvalidEncodingAndInvalidHeaderFilesGiveSafeErrors() async throws {
        let invalid = [
            Data(), Data("fixture key".utf8), Data("fixture\r\nInjected: header".utf8),
            Data("fixture\u{0}key".utf8), Data("café".utf8), Data([0xFF, 0xFE]),
            Data(repeating: 0x61, count: 16_385),
        ]
        for contents in invalid {
            let fixture = try UnslothKeyFileFixture(contents: contents)
            defer { fixture.remove() }
            await assertUnavailable(fixture.server, forbidden: [fixture.fileURL.path, "Injected"])
        }
        let maximum = try UnslothKeyFileFixture(contents: Data(repeating: 0x61, count: 16_384))
        defer { maximum.remove() }
        let key = try await defaultReader().key(for: maximum.server)
        XCTAssertEqual(key?.utf8.count, 16_384)
    }

    func testWorkerOrStudioBirthMismatchPreventsOpeningKeyFile() async throws {
        let fixture = try UnslothKeyFileFixture()
        defer { fixture.remove() }
        let reads = UnslothKeyReadCounter()
        for changedPID in [Int32(10), 20] {
            let reader = UnslothWorkerKeyReader(
                identity: { pid in
                    pid == changedPID
                        ? GPUProcessIdentity(pid: pid, startTimeMicroseconds: 99_000)
                        : UnslothKeyReaderIdentities.expected(pid)
                },
                readBytes: { descriptor, buffer, count in
                    reads.record()
                    return Darwin.read(descriptor, buffer, count)
                })
            await assertUnavailable(fixture.server, reader: reader)
        }
        XCTAssertEqual(reads.count, 0)
    }

    func testWorkerDisappearanceDuringReadCannotPublishCredential() async throws {
        let fixture = try UnslothKeyFileFixture()
        defer { fixture.remove() }
        let identities = UnslothKeyReaderIdentities()
        let reader = UnslothWorkerKeyReader(
            identity: { identities.identity($0) },
            readBytes: { descriptor, buffer, count in
                let received = Darwin.read(descriptor, buffer, count)
                identities.remove(20)
                return received
            })
        await assertUnavailable(fixture.server, reader: reader)
    }

    func testInPlaceRewriteAndAtomicReplacementDuringReadAreRejected() async throws {
        for atomic in [true, false] {
            let fixture = try UnslothKeyFileFixture()
            defer { fixture.remove() }
            let file = fixture.fileURL
            let reader = UnslothWorkerKeyReader(
                identity: { UnslothKeyReaderIdentities.expected($0) },
                readBytes: { descriptor, buffer, count in
                    let received = Darwin.read(descriptor, buffer, count)
                    try? Data("replacement-worker-key-with-different-size".utf8).write(
                        to: file, options: atomic ? .atomic : [])
                    return received
                })
            await assertUnavailable(fixture.server, reader: reader)
        }
    }

    func testParentReplacedBySymlinkDuringReadCannotPublishOldCredential() async throws {
        let fixture = try UnslothKeyFileFixture()
        defer { fixture.remove() }
        let auth = fixture.authDirectoryURL
        let moved = fixture.root.appendingPathComponent("moved-auth")
        let reader = UnslothWorkerKeyReader(
            identity: { UnslothKeyReaderIdentities.expected($0) },
            readBytes: { descriptor, buffer, count in
                let received = Darwin.read(descriptor, buffer, count)
                if !FileManager.default.fileExists(atPath: moved.path) {
                    try? FileManager.default.moveItem(at: auth, to: moved)
                    try? FileManager.default.createSymbolicLink(at: auth, withDestinationURL: moved)
                }
                return received
            })
        await assertUnavailable(fixture.server, reader: reader)
    }

    func testEachReadUsesCurrentFileContentsWithoutCachingSecret() async throws {
        let fixture = try UnslothKeyFileFixture()
        defer { fixture.remove() }
        let reader = defaultReader()
        let first = try await reader.key(for: fixture.server)
        try Data("rotated-fixture-worker-key".utf8).write(to: fixture.fileURL)
        let second = try await reader.key(for: fixture.server)
        XCTAssertEqual(first, "fixture-worker-key")
        XCTAssertEqual(second, "rotated-fixture-worker-key")
    }

    func testCancellationDuringReadRemainsCancellation() async throws {
        let fixture = try UnslothKeyFileFixture()
        defer { fixture.remove() }
        let reader = UnslothWorkerKeyReader(
            identity: { UnslothKeyReaderIdentities.expected($0) },
            readBytes: { descriptor, buffer, count in
                let received = Darwin.read(descriptor, buffer, count)
                withUnsafeCurrentTask { $0?.cancel() }
                return received
            })
        let pending = Task { try await reader.key(for: fixture.server) }
        do {
            _ = try await pending.value
            XCTFail("A cancelled read cannot publish a worker key")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func defaultReader() -> UnslothWorkerKeyReader {
        UnslothWorkerKeyReader(identity: { UnslothKeyReaderIdentities.expected($0) })
    }

    private func makeServer(source: UnslothWorkerKeySource) -> UnslothServer {
        UnslothServer(
            studioURL: URL(string: "http://127.0.0.1:8888")!,
            workerURL: URL(string: "http://127.0.0.1:54234")!,
            studioIdentity: UnslothKeyReaderIdentities.expected(10)!,
            workerIdentity: UnslothKeyReaderIdentities.expected(20)!, workerKeySource: source)
    }

    private func assertUnavailable(
        _ server: UnslothServer, reader: UnslothWorkerKeyReader? = nil,
        forbidden: [String] = []
    ) async {
        do {
            _ = try await (reader ?? defaultReader()).key(for: server)
            XCTFail("An unsafe or unavailable file must not return a key")
        } catch {
            guard case .configurationRequired(let message) = error as? BackendClientError else {
                return XCTFail("Expected safe configuration guidance")
            }
            XCTAssertTrue(message.contains("could not safely read"))
            XCTAssertFalse(message.contains("fixture-worker-key"))
            for value in forbidden { XCTAssertFalse(message.contains(value)) }
        }
    }
}

private struct UnslothKeyFileFixture: Sendable {
    let root: URL
    let authDirectoryURL: URL
    let fileURL: URL

    init(contents: Data = Data("fixture-worker-key".utf8)) throws {
        root = URL(fileURLWithPath: "/private/tmp/fluxllm-worker-key-\(UUID().uuidString)")
        authDirectoryURL = root.appendingPathComponent(".unsloth/studio/auth", isDirectory: true)
        fileURL = authDirectoryURL.appendingPathComponent("llama_api_key_0123456789abcdef")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.createDirectory(
                at: authDirectoryURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try contents.write(to: fileURL)
            guard fileURL.path.withCString({ Darwin.chmod($0, 0o600) }) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    var server: UnslothServer {
        UnslothServer(
            studioURL: URL(string: "http://127.0.0.1:8888")!,
            workerURL: URL(string: "http://127.0.0.1:54234")!,
            studioIdentity: UnslothKeyReaderIdentities.expected(10)!,
            workerIdentity: UnslothKeyReaderIdentities.expected(20)!,
            workerKeySource: .file(
                UnslothWorkerKeyFile(fileURL: fileURL, authDirectoryURL: authDirectoryURL)))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class UnslothKeyReaderIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32: GPUProcessIdentity] = [
        10: UnslothKeyReaderIdentities.expected(10)!,
        20: UnslothKeyReaderIdentities.expected(20)!,
    ]
    private var recorded: [Int32] = []

    static func expected(_ pid: Int32) -> GPUProcessIdentity? {
        guard pid == 10 || pid == 20 else { return nil }
        return GPUProcessIdentity(pid: pid, startTimeMicroseconds: UInt64(pid) * 1_000)
    }

    var calls: [Int32] { lock.withLock { recorded } }
    func identity(_ pid: Int32) -> GPUProcessIdentity? {
        lock.withLock {
            recorded.append(pid)
            return values[pid]
        }
    }
    func remove(_ pid: Int32) { _ = lock.withLock { values.removeValue(forKey: pid) } }
}

private final class UnslothKeyReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = 0
    var count: Int { lock.withLock { recorded } }
    func record() { lock.withLock { recorded += 1 } }
}
