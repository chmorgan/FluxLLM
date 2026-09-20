import Darwin
import Foundation

/// Resolves a local endpoint to its actual listening process and verified inference workers.
/// It never attributes a machine-wide GPU value to an LLM backend.
public actor LocalBackendProcessResolver: BackendProcessResolving {
    private struct Cache {
        let key: String
        let sampledAt: TimeInterval
        let selection: GPUProcessSelection
    }

    private let inspector: any LocalBackendProcessInspecting
    private let clock: @Sendable () -> TimeInterval
    private var cache: Cache?
    private var revision = 0
    private let cacheDuration: TimeInterval = 3

    public init() {
        inspector = DarwinBackendProcessInspector()
        clock = { ProcessInfo.processInfo.systemUptime }
    }

    init(
        inspector: any LocalBackendProcessInspecting,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.inspector = inspector
        self.clock = clock
    }

    public func reset() async {
        cache = nil
        revision &+= 1
    }

    public func resolve(_ configuration: BackendConfiguration) async -> GPUProcessSelection {
        guard let endpoint = LocalBackendEndpoint(configuration.baseURL) else {
            return unavailable("GPU activity is available only for a backend running on this Mac.")
        }
        let key = "\(configuration.kind.rawValue)|\(configuration.baseURL.absoluteString)"
        let now = clock()
        if let cached = cache, cached.key == key,
            now >= cached.sampledAt, now - cached.sampledAt < cacheDuration,
            identitiesAreCurrent(cached.selection.processes)
        {
            return cached.selection
        }

        let requestedRevision = revision
        let snapshot = await Self.takeSnapshot(using: inspector, endpoint: endpoint)
        guard !Task.isCancelled, requestedRevision == revision else {
            return unavailable("GPU process discovery was cancelled.")
        }
        let selection = select(configuration.kind, snapshot: snapshot)
        cache = Cache(key: key, sampledAt: now, selection: selection)
        return selection
    }

    private func identitiesAreCurrent(_ processes: Set<GPUProcessIdentity>) -> Bool {
        for process in processes {
            if inspector.identity(of: process.pid) != process { return false }
        }
        return true
    }

    private nonisolated static func takeSnapshot(
        using inspector: any LocalBackendProcessInspecting, endpoint: LocalBackendEndpoint
    ) async -> LocalBackendProcessSnapshot {
        let task = Task.detached(priority: .utility) { [inspector, endpoint] in
            inspector.snapshot(for: endpoint)
        }
        return await task.value
    }

    private func select(_ kind: BackendKind, snapshot: LocalBackendProcessSnapshot)
        -> GPUProcessSelection
    {
        let listeners = snapshot.listeners.compactMap { snapshot.processes[$0] }
        guard !listeners.isEmpty, listeners.count == snapshot.listeners.count else {
            return unavailable("The local backend's listening process could not be identified.")
        }

        // A shared inherited listening socket is safe only when its owners belong to one
        // verified backend process tree. Separate servers or a reverse proxy are ambiguous.
        let verifiedListeners = listeners.compactMap { listener in
            verifiedServerAncestor(of: listener, kind: kind, snapshot: snapshot)
        }
        let uniqueServers = Dictionary(
            verifiedListeners.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first }
        )
        guard !verifiedListeners.isEmpty else {
            return unavailable(
                "The local endpoint is not owned by a recognized \(kind.title) process.")
        }
        let roots = uniqueServers.values.filter { candidate in
            !uniqueServers.values.contains { other in
                other.identity != candidate.identity
                    && descends(candidate, from: other, snapshot: snapshot)
            }
        }
        guard roots.count == 1, let root = roots.first,
            listeners.allSatisfy({
                $0.identity == root.identity
                    || (descends($0, from: root, snapshot: snapshot)
                        && isWorker($0, kind: kind, root: root))
            })
        else {
            return unavailable("Multiple local listeners prevent reliable backend GPU attribution.")
        }

        var selected: Set<GPUProcessIdentity> = [root.identity]
        for process in snapshot.processes.values where process.identity != root.identity {
            guard descends(process, from: root, snapshot: snapshot),
                isWorker(process, kind: kind, root: root)
            else { continue }
            selected.insert(process.identity)
        }
        // A process can exit or a PID can be reused while its sockets and arguments are read.
        // In that case do not return a partial, potentially unrelated attribution tree.
        guard identitiesAreCurrent(selected) else {
            return unavailable("The backend's processes changed; GPU discovery will retry.")
        }
        return GPUProcessSelection(processes: selected)
    }

    private func descends(
        _ process: LocalBackendProcess, from root: LocalBackendProcess,
        snapshot: LocalBackendProcessSnapshot
    ) -> Bool {
        var child = process
        var visited: Set<Int32> = [child.identity.pid]
        for _ in 0..<32 {
            guard let parent = snapshot.processes[child.parentPID],
                visited.insert(parent.identity.pid).inserted,
                parent.identity.startTimeMicroseconds <= child.identity.startTimeMicroseconds,
                inspector.identity(of: parent.identity.pid) == parent.identity
            else { return false }
            if parent.identity == root.identity { return true }
            child = parent
        }
        return false
    }

    private func verifiedServerAncestor(
        of listener: LocalBackendProcess, kind: BackendKind,
        snapshot: LocalBackendProcessSnapshot
    ) -> LocalBackendProcess? {
        var process = listener
        var visited: Set<Int32> = []
        for _ in 0..<32 {
            guard visited.insert(process.identity.pid).inserted,
                inspector.identity(of: process.identity.pid) == process.identity
            else { return nil }
            if isServer(process, kind: kind) { return process }
            guard let parent = snapshot.processes[process.parentPID],
                parent.identity.startTimeMicroseconds <= process.identity.startTimeMicroseconds
            else { return nil }
            process = parent
        }
        return nil
    }

    private func isServer(_ process: LocalBackendProcess, kind: BackendKind) -> Bool {
        let name = process.executableName
        switch kind {
        case .ollama:
            guard name == "ollama", let arguments = inspector.arguments(of: process.identity) else {
                return false
            }
            return arguments.dropFirst().first == "serve"
        case .llamaCpp:
            return name == "llama-server" || name == "llama-server-metal"
        case .rapidMLX:
            guard isPython(process), let arguments = inspector.arguments(of: process.identity)
            else { return false }
            return Self.invokesPythonModule(arguments, prefixes: ["vllm_mlx", "rapid_mlx"])
                || Self.invokesScript(
                    arguments, names: ["rapid-mlx", "rmlx", "vllm-mlx"], command: "serve")
        case .vllm:
            guard isPython(process) || name == "vllm",
                let arguments = inspector.arguments(of: process.identity)
            else { return false }
            return (name == "vllm" && arguments.dropFirst().first == "serve")
                || (isPython(process)
                    && (Self.invokesPythonModule(arguments, prefixes: ["vllm"])
                        || Self.invokesScript(arguments, names: ["vllm"], command: "serve")))
        }
    }

    private func isWorker(
        _ process: LocalBackendProcess, kind: BackendKind, root: LocalBackendProcess
    ) -> Bool {
        let name = process.executableName
        let arguments = inspector.arguments(of: process.identity) ?? []
        switch kind {
        case .ollama:
            // Current Ollama embeds `runner`; older releases use an ollama_llama_server
            // executable. The listener ancestry rules above exclude unrelated runners.
            return (name == "ollama" && arguments.dropFirst().first == "runner")
                || name == "ollama_llama_server" || name == "ollama-runner"
                || name == "llama-server"
        case .llamaCpp:
            return name == "llama-server" || name == "llama-server-metal"
        case .rapidMLX, .vllm:
            guard isPython(process), process.executablePath == root.executablePath else {
                return false
            }
            let modules = kind == .rapidMLX ? ["vllm_mlx", "rapid_mlx"] : ["vllm"]
            return Self.invokesPythonModule(arguments, prefixes: modules)
                || Self.isMultiprocessingWorker(arguments)
                || (kind == .vllm && Self.hasVLLMWorkerTitle(arguments))
        }
    }

    private func isPython(_ process: LocalBackendProcess) -> Bool {
        let name = process.executableName.lowercased()
        guard name.hasPrefix("python") else { return false }
        let suffix = name.dropFirst("python".count)
        return suffix.isEmpty || suffix.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func invokesPythonModule(_ arguments: [String], prefixes: [String]) -> Bool {
        guard let index = pythonOption("-m", in: arguments), index + 1 < arguments.count else {
            return false
        }
        let module = arguments[index + 1]
        return prefixes.contains { module == $0 || module.hasPrefix($0 + ".") }
    }

    private static func invokesScript(
        _ arguments: [String], names: [String], command: String? = nil
    ) -> Bool {
        guard arguments.count > 1 else { return false }
        let script = URL(fileURLWithPath: arguments[1]).lastPathComponent
        guard names.contains(script) else { return false }
        return command == nil || (arguments.count > 2 && arguments[2] == command)
    }

    private static func isMultiprocessingWorker(_ arguments: [String]) -> Bool {
        // Python's spawn/forkserver workers retain the verified listener as an ancestor
        // and use the identical Python binary. Generic `python some_script.py` children
        // are intentionally excluded, as is multiprocessing's resource tracker.
        guard let index = pythonOption("-c", in: arguments), index + 1 < arguments.count else {
            return false
        }
        let code = arguments[index + 1]
        return code.hasPrefix("from multiprocessing.spawn import spawn_main;")
            || code.hasPrefix("from multiprocessing.forkserver import main;")
    }

    private static func pythonOption(_ option: String, in arguments: [String]) -> Int? {
        // Only interpreter options before -c/-m/the script are meaningful. This
        // prevents `python unrelated.py --model vllm -m vllm` from matching.
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == option { return index }
            if argument == "-c" || argument == "-m" || argument == "--" || !argument.hasPrefix("-")
            {
                return nil
            }
            if argument == "-W" || argument == "-X" { index += 1 }
            index += 1
        }
        return nil
    }

    private static func hasVLLMWorkerTitle(_ arguments: [String]) -> Bool {
        // vLLM replaces argv with titles such as VLLM::EngineCore_DP0. The prefix
        // is configurable, so only use the role after verifying ancestry and binary.
        guard let title = arguments.first,
            let separator = title.range(of: "::", options: .backwards)
        else { return false }
        let role = String(title[separator.upperBound...])
        return role.range(
            of: "^(EngineCore|Worker|APIServer)(_[A-Za-z]+[0-9]+)*$", options: .regularExpression)
            != nil
    }

    private func unavailable(_ reason: String) -> GPUProcessSelection {
        GPUProcessSelection(processes: [], unavailableReason: reason)
    }
}

struct LocalBackendEndpoint: Equatable, Sendable {
    enum Host: Equatable, Sendable { case ipv4, ipv6, localhost }
    let host: Host
    let port: UInt16

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let hostname = url.host?.lowercased()
        else { return nil }
        switch hostname {
        case "localhost": host = .localhost
        case "127.0.0.1": host = .ipv4
        case "::1", "[::1]": host = .ipv6
        default: return nil
        }
        let rawPort = url.port ?? (scheme == "https" ? 443 : 80)
        guard let port = UInt16(exactly: rawPort), port > 0 else { return nil }
        self.port = port
    }
}

struct LocalBackendProcess: Sendable, Equatable {
    let identity: GPUProcessIdentity
    let parentPID: Int32
    let executablePath: String
    var executableName: String { URL(fileURLWithPath: executablePath).lastPathComponent }
}

struct LocalBackendProcessSnapshot: Sendable {
    let processes: [Int32: LocalBackendProcess]
    let listeners: Set<Int32>
}

protocol LocalBackendProcessInspecting: Sendable {
    func snapshot(for endpoint: LocalBackendEndpoint) -> LocalBackendProcessSnapshot
    func identity(of pid: Int32) -> GPUProcessIdentity?
    func arguments(of identity: GPUProcessIdentity) -> [String]?
}

/// Public libproc socket/process interfaces avoid spawning helpers or requiring root.
struct DarwinBackendProcessInspector: LocalBackendProcessInspecting {
    func snapshot(for endpoint: LocalBackendEndpoint) -> LocalBackendProcessSnapshot {
        let requested = Int(proc_listallpids(nil, 0))
        guard requested > 0 else {
            return LocalBackendProcessSnapshot(processes: [:], listeners: [])
        }
        var pids = [Int32](repeating: 0, count: min(requested + 128, 32_768))
        let count = pids.withUnsafeMutableBytes {
            Int(proc_listallpids($0.baseAddress, Int32($0.count)))
        }
        var processes: [Int32: LocalBackendProcess] = [:]
        var listeners: Set<Int32> = []
        for pid in pids.prefix(max(0, min(count, pids.count))) where pid > 0 {
            guard let info = bsdInfo(pid), let identity = identity(pid, info: info),
                let path = executablePath(pid)
            else { continue }
            processes[pid] = LocalBackendProcess(
                identity: identity, parentPID: Int32(bitPattern: info.pbi_ppid),
                executablePath: path)
            if listens(pid, at: endpoint) { listeners.insert(pid) }
        }
        return LocalBackendProcessSnapshot(processes: processes, listeners: listeners)
    }

    func identity(of pid: Int32) -> GPUProcessIdentity? {
        guard let info = bsdInfo(pid) else { return nil }
        return identity(pid, info: info)
    }

    func arguments(of identity: GPUProcessIdentity) -> [String]? {
        guard self.identity(of: identity.pid) == identity else { return nil }
        // KERN_PROCARGS2 starts with argc, the executable path, padding, and exactly
        // argc NUL-terminated arguments. Never decode or retain the environment tail.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, identity.pid]
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        var size = bytes.count
        let result = mib.withUnsafeMutableBufferPointer { names in
            bytes.withUnsafeMutableBytes { buffer in
                sysctl(names.baseAddress, u_int(names.count), buffer.baseAddress, &size, nil, 0)
            }
        }
        guard result == 0, size > MemoryLayout<Int32>.size,
            self.identity(of: identity.pid) == identity
        else { return nil }
        return Self.decodeArguments(Array(bytes.prefix(size)))
    }

    static func decodeArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 65_536 else { return nil }
        var cursor = 4
        guard let executableEnd = bytes[cursor...].firstIndex(of: 0) else { return nil }
        cursor = executableEnd
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0),
                let value = String(bytes: bytes[cursor..<end], encoding: .utf8)
            else { return nil }
            arguments.append(value)
            cursor = end + 1
        }
        return arguments
    }

    private func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return info
    }

    private func identity(_ pid: Int32, info: proc_bsdinfo) -> GPUProcessIdentity? {
        guard info.pbi_pid == UInt32(bitPattern: pid), info.pbi_start_tvsec > 0,
            info.pbi_start_tvsec <= UInt64.max / 1_000_000,
            info.pbi_start_tvusec < 1_000_000
        else { return nil }
        return GPUProcessIdentity(
            pid: pid,
            startTimeMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

    private func executablePath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is an expression macro not imported into Swift.
        // sys/proc_info.h defines it as 4 * MAXPATHLEN.
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = bytes.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0, let end = bytes.firstIndex(of: 0), end > 0 else { return nil }
        return String(bytes: bytes[..<end], encoding: .utf8)
    }

    private func listens(_ pid: Int32, at endpoint: LocalBackendEndpoint) -> Bool {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        let size = MemoryLayout<proc_fdinfo>.size
        let capacity = min(Int(needed) / size + 16, 16_384)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let count = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return false }
        for descriptor in descriptors.prefix(min(Int(count) / size, capacity))
        where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            let socketSize = MemoryLayout<socket_fdinfo>.size
            guard
                proc_pidfdinfo(
                    pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, Int32(socketSize))
                    == socketSize,
                socket.psi.soi_kind == SOCKINFO_TCP
            else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN,
                UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
                    == endpoint.port,
                matches(tcp.tcpsi_ini, endpoint: endpoint)
            else { continue }
            return true
        }
        return false
    }

    func matches(_ socket: in_sockinfo, endpoint: LocalBackendEndpoint) -> Bool {
        if socket.insi_vflag & UInt8(INI_IPV4) != 0, endpoint.host != .ipv6 {
            let address = socket.insi_laddr.ina_46.i46a_addr4.s_addr
            if address == 0 || UInt32(bigEndian: address) == 0x7F00_0001 { return true }
        }
        if socket.insi_vflag & UInt8(INI_IPV6) != 0, endpoint.host != .ipv4 {
            var address = socket.insi_laddr.ina_6
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            let wildcard = bytes.allSatisfy { $0 == 0 }
            let loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes.last == 1
            if wildcard || (endpoint.host != .ipv4 && loopback) { return true }
        }
        return false
    }
}
