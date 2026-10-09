import Darwin
import Foundation

public protocol UnslothWorkerKeyReading: Sendable {
    func key(for server: UnslothServer) async throws -> String?
}

/// Reads only the key file named by a verified managed worker. Credentials stay in memory.
public struct UnslothWorkerKeyReader: UnslothWorkerKeyReading {
    private let identity: @Sendable (Int32) -> GPUProcessIdentity?
    private let ownerUID: uid_t
    private let readBytes: @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int
    private static let maximumKeyBytes = 16_384

    public init() {
        let inspector = DarwinBackendProcessInspector()
        identity = { inspector.identity(of: $0) }
        ownerUID = geteuid()
        readBytes = { Darwin.read($0, $1, $2) }
    }

    init(
        identity: @escaping @Sendable (Int32) -> GPUProcessIdentity?,
        ownerUID: uid_t = geteuid(),
        readBytes: @escaping @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int = {
            Darwin.read($0, $1, $2)
        }
    ) {
        self.identity = identity
        self.ownerUID = ownerUID
        self.readBytes = readBytes
    }

    public func key(for server: UnslothServer) async throws -> String? {
        try Task.checkCancellation()
        switch server.workerKeySource {
        case .none:
            return nil
        case .unavailable:
            throw Self.unavailable()
        case .file(let reference):
            guard let worker = server.workerIdentity, server.workerURL != nil,
                worker != server.studioIdentity,
                identity(server.studioIdentity.pid) == server.studioIdentity,
                identity(worker.pid) == worker
            else { throw Self.unavailable() }
            let key = try read(reference)
            try Task.checkCancellation()
            guard identity(server.studioIdentity.pid) == server.studioIdentity,
                identity(worker.pid) == worker
            else { throw Self.unavailable() }
            return key
        }
    }

    private func read(_ reference: UnslothWorkerKeyFile) throws -> String {
        guard reference.hasManagedPath else { throw Self.unavailable() }
        let directory = try openAuthDirectory(reference.authDirectoryURL)
        defer { Darwin.close(directory) }
        var directoryBefore = stat()
        guard Darwin.fstat(directory, &directoryBefore) == 0 else { throw Self.unavailable() }

        // NONBLOCK keeps a substituted FIFO from blocking before fstat rejects its type.
        let descriptor = reference.fileURL.lastPathComponent.withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw Self.unavailable() }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0, safeFile(before) else {
            throw Self.unavailable()
        }
        var bytes = [UInt8](repeating: 0, count: Self.maximumKeyBytes + 1)
        var count = 0
        while count < bytes.count {
            try Task.checkCancellation()
            let received = bytes.withUnsafeMutableBytes { buffer in
                readBytes(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw Self.unavailable()
            }
            guard received <= bytes.count - count else { throw Self.unavailable() }
            if received == 0 { break }
            count += received
        }
        // Rewalk the directories so a replacement or newly inserted parent symlink
        // during the read cannot inherit the pinned directory's earlier validation.
        let currentDirectory = try openAuthDirectory(reference.authDirectoryURL)
        defer { Darwin.close(currentDirectory) }
        var directoryAfter = stat()
        var after = stat()
        var currentPath = stat()
        guard count > 0, count <= Self.maximumKeyBytes, off_t(count) == before.st_size,
            Darwin.fstat(currentDirectory, &directoryAfter) == 0,
            directoryBefore.st_dev == directoryAfter.st_dev,
            directoryBefore.st_ino == directoryAfter.st_ino,
            Darwin.fstat(descriptor, &after) == 0, safeFile(after),
            Self.sameFile(before, after),
            // The descriptor can remain valid after a file is replaced. Require the
            // original name still to identify that same private file before publishing.
            reference.fileURL.lastPathComponent.withCString({
                Darwin.fstatat(currentDirectory, $0, &currentPath, AT_SYMLINK_NOFOLLOW)
            }) == 0, safeFile(currentPath), Self.sameFile(after, currentPath),
            let text = String(bytes: bytes.prefix(count), encoding: .utf8)
        else { throw Self.unavailable() }
        do {
            guard let key = try AppSettings.normalizedUnslothWorkerAPIKey(text) else {
                throw Self.unavailable()
            }
            return key
        } catch {
            // Neither low-level paths, contents, nor a rejected header value enter errors.
            throw Self.unavailable()
        }
    }

    private func openAuthDirectory(_ url: URL) throws -> Int32 {
        // Pin each directory and reject links in every component, including the auth root.
        // A later rename cannot redirect the file lookup away from the opened directory.
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw Self.unavailable() }
        var retained = false
        defer { if !retained { Darwin.close(directory) } }
        for component in url.pathComponents.dropFirst() {
            try Task.checkCancellation()
            let next = component.withCString {
                Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else { throw Self.unavailable() }
            Darwin.close(directory)
            directory = next
        }
        var directoryInfo = stat()
        guard Darwin.fstat(directory, &directoryInfo) == 0,
            (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
            directoryInfo.st_uid == ownerUID,
            directoryInfo.st_mode & 0o077 == 0,
            directoryInfo.st_mode & mode_t(S_IXUSR) != 0
        else { throw Self.unavailable() }
        retained = true
        return directory
    }

    private func safeFile(_ information: stat) -> Bool {
        (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && information.st_uid == ownerUID
            && information.st_nlink == 1
            && information.st_mode & 0o177 == 0
            && information.st_mode & mode_t(S_IRUSR) != 0
            && information.st_size > 0 && information.st_size <= off_t(Self.maximumKeyBytes)
    }

    private static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
            && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    private static func unavailable() -> BackendClientError {
        .configurationRequired(
            "FluxLLM could not safely read the current local Unsloth worker API key. Reload the model in Studio or enter the worker key manually in Settings. The Studio access token is separate."
        )
    }
}
