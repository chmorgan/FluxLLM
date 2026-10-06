import Foundation

/// A locally verified Studio endpoint and, when loaded, its managed GGUF worker.
/// PID birth identities prevent a restarted process from inheriting an old binding.
public struct UnslothServer: Equatable, Sendable {
    public let studioURL: URL
    public let workerURL: URL?
    public let studioIdentity: GPUProcessIdentity
    public let workerIdentity: GPUProcessIdentity?

    public init(
        studioURL: URL, workerURL: URL?, studioIdentity: GPUProcessIdentity,
        workerIdentity: GPUProcessIdentity?
    ) {
        self.studioURL = studioURL
        self.workerURL = workerURL
        self.studioIdentity = studioIdentity
        self.workerIdentity = workerIdentity
    }
}

public protocol UnslothDiscovering: Sendable {
    func servers() async -> [UnslothServer]
    func reset() async
}

extension UnslothDiscovering {
    public func reset() async {}
}

/// Passive discovery of the managed Unsloth Studio installation on this Mac.
/// Expensive inventory and socket reads run at most every five seconds, except when
/// a cached process disappears or its PID is reused. Only verified candidates have
/// their sockets inspected; this never runs ps/lsof or connects to inferred ports.
public actor UnslothProcessDiscovery: UnslothDiscovering {
    private struct Snapshot: Sendable {
        let servers: [UnslothServer]
        let identities: Set<GPUProcessIdentity>
    }

    private struct Cache: Sendable {
        let sampledAt: TimeInterval
        let snapshot: Snapshot
    }

    private struct Flight {
        let token: UInt64
        let revision: UInt64
        let sampledAt: TimeInterval
        let task: Task<(Snapshot, Bool), Never>
        var callers: Int
    }

    private let inspector: any UnslothProcessInspecting
    private let clock: @Sendable () -> TimeInterval
    private var cache: Cache?
    private var revision: UInt64 = 0
    private var nextFlightToken: UInt64 = 0
    private var inFlight: Flight?
    private let cacheDuration: TimeInterval = 5

    /// Read-only internal state makes concurrent-call tests deterministic without
    /// adding work, callbacks, or counters to native process inspections.
    var inFlightCallCount: Int { inFlight?.callers ?? 0 }

    public init() {
        inspector = DarwinBackendProcessInspector()
        clock = { ProcessInfo.processInfo.systemUptime }
    }

    init(
        inspector: any UnslothProcessInspecting,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.inspector = inspector
        self.clock = clock
    }

    public func reset() async {
        cache = nil
        revision &+= 1
        inFlight?.task.cancel()
        inFlight = nil
    }

    public func servers() async -> [UnslothServer] {
        guard !Task.isCancelled else { return [] }
        let now = clock()
        let flight: Flight
        if var existing = inFlight, existing.revision == revision {
            existing.callers += 1
            inFlight = existing
            flight = existing
        } else {
            let validCache: Cache?
            if let cache, now >= cache.sampledAt, now - cache.sampledAt < cacheDuration {
                validCache = cache
            } else {
                validCache = nil
            }
            let inspector = self.inspector
            // Capture only value state and the inspector. The actor retains this
            // task, so capturing self here would create an unnecessary retain cycle.
            let task = Task.detached(priority: .utility) { [inspector, validCache] in
                if let validCache,
                    validCache.snapshot.identities.allSatisfy({
                        inspector.identity(of: $0.pid) == $0
                    })
                {
                    return (validCache.snapshot, false)
                }
                return (Self.inspect(using: inspector), true)
            }
            nextFlightToken &+= 1
            flight = Flight(
                token: nextFlightToken, revision: revision, sampledAt: now,
                task: task, callers: 1)
            inFlight = flight
        }

        let (snapshot, refreshed) = await flight.task.value
        guard flight.revision == revision else { return [] }
        let cancelled = Task.isCancelled
        // Only the current flight may publish or clear state. In particular, a
        // task invalidated by reset cannot erase a newer discovery already running.
        if var current = inFlight, current.token == flight.token {
            current.callers -= 1
            if !cancelled {
                if refreshed { cache = Cache(sampledAt: flight.sampledAt, snapshot: snapshot) }
                inFlight = nil
            } else if current.callers == 0 {
                inFlight = nil
            } else {
                inFlight = current
            }
        }
        guard !cancelled else { return [] }
        return snapshot.servers
    }

    private nonisolated static func inspect(using inspector: any UnslothProcessInspecting)
        -> Snapshot
    {
        let processes = inspector.inventory()
        let candidates = processes.values.sorted { $0.identity.pid < $1.identity.pid }
        var studios: [(process: LocalBackendProcess, installation: String)] = []
        for process in candidates where isPython(process.executableName) {
            guard inspector.identity(of: process.identity.pid) == process.identity,
                let arguments = inspector.arguments(of: process.identity),
                let installation = managedStudioInstallation(arguments)
            else { continue }
            studios.append((process, installation))
            // Treat an implausibly large set as unresolvable rather than allocating
            // unbounded endpoint/cached-identity state or picking an arbitrary one.
            guard studios.count <= 16 else { return Snapshot(servers: [], identities: []) }
        }

        var servers: [UnslothServer] = []
        var identities: Set<GPUProcessIdentity> = []
        for (studio, installation) in studios {
            let studioEndpoints = inspector.listeningEndpoints(of: studio.identity)
            // Dual-stack listeners on the same port have one stable endpoint. Distinct
            // ports are ambiguous: neither argv nor a conventional port proves which
            // listener belongs to Studio's HTTP service.
            guard Set(studioEndpoints.map(\.port)).count == 1,
                let studioEndpoint = ordered(studioEndpoints).first,
                inspector.identity(of: studio.identity.pid) == studio.identity
            else { continue }
            let workerPath = installation + "/llama.cpp/build/bin/llama-server"
            let workers = candidates.filter { $0.executablePath == workerPath }
            guard workers.count <= 64 else { continue }
            var bindings:
                [(
                    worker: LocalBackendProcess, endpoint: LocalBackendTCPListener,
                    lineage: Set<GPUProcessIdentity>
                )] = []
            for worker in workers {
                guard
                    let lineage = lineage(
                        of: worker, to: studio, processes: processes, inspector: inspector)
                else { continue }
                let endpoints = ordered(inspector.listeningEndpoints(of: worker.identity))
                guard lineage.allSatisfy({ inspector.identity(of: $0.pid) == $0 }) else { continue }
                for endpoint in endpoints {
                    // A pair of literal v4/v6 listeners at the same port is a single
                    // service. Multiple distinct ports stay explicit for the adapter
                    // to reject instead of silently selecting one.
                    if bindings.contains(where: {
                        $0.worker.identity == worker.identity && $0.endpoint.port == endpoint.port
                    }) {
                        continue
                    }
                    bindings.append((worker, endpoint, lineage))
                    guard bindings.count <= 128 else {
                        return Snapshot(servers: [], identities: [])
                    }
                }
            }
            guard inspector.identity(of: studio.identity.pid) == studio.identity else { continue }
            if bindings.isEmpty {
                servers.append(
                    UnslothServer(
                        studioURL: studioEndpoint.url, workerURL: nil,
                        studioIdentity: studio.identity, workerIdentity: nil))
                identities.insert(studio.identity)
            } else {
                for binding in bindings {
                    servers.append(
                        UnslothServer(
                            studioURL: studioEndpoint.url, workerURL: binding.endpoint.url,
                            studioIdentity: studio.identity, workerIdentity: binding.worker.identity
                        ))
                    identities.formUnion(binding.lineage)
                }
            }
            guard servers.count <= 128 else { return Snapshot(servers: [], identities: []) }
        }
        return Snapshot(servers: servers, identities: identities)
    }

    private nonisolated static func ordered(_ endpoints: [LocalBackendTCPListener])
        -> [LocalBackendTCPListener]
    {
        Set(endpoints.filter { $0.port > 0 }).sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.host == .ipv4 && $1.host == .ipv6
        }
    }

    private nonisolated static func managedStudioInstallation(_ arguments: [String]) -> String? {
        guard arguments.count >= 3, arguments[2] == "studio" else { return nil }
        let launchPath = arguments[0]
        let suffix = "/.unsloth/studio/unsloth_studio/bin/"
        guard launchPath.hasPrefix("/"),
            URL(fileURLWithPath: launchPath).standardizedFileURL.path == launchPath,
            let marker = launchPath.range(of: suffix, options: .backwards),
            isPython(String(launchPath[marker.upperBound...])),
            arguments[1] == String(launchPath[..<marker.upperBound]) + "unsloth"
        else { return nil }
        return String(launchPath[..<marker.lowerBound]) + "/.unsloth"
    }

    private nonisolated static func isPython(_ name: String) -> Bool {
        guard name.hasPrefix("python") else { return false }
        let suffix = name.dropFirst("python".count)
        return suffix.isEmpty || suffix.allSatisfy { $0.isNumber || $0 == "." }
    }

    private nonisolated static func lineage(
        of worker: LocalBackendProcess, to studio: LocalBackendProcess,
        processes: [Int32: LocalBackendProcess], inspector: any UnslothProcessInspecting
    ) -> Set<GPUProcessIdentity>? {
        var child = worker
        var identities: Set<GPUProcessIdentity> = []
        var visited: Set<Int32> = []
        for _ in 0..<32 {
            guard visited.insert(child.identity.pid).inserted,
                inspector.identity(of: child.identity.pid) == child.identity
            else { return nil }
            identities.insert(child.identity)
            if child.identity == studio.identity { return identities }
            guard let parent = processes[child.parentPID],
                parent.identity.startTimeMicroseconds <= child.identity.startTimeMicroseconds
            else { return nil }
            child = parent
        }
        return nil
    }
}

/// Socket candidates have literal loopback addresses only, never wildcard binds.
struct LocalBackendTCPListener: Hashable, Sendable {
    enum Host: Hashable, Sendable { case ipv4, ipv6 }
    let host: Host
    let port: UInt16
    var url: URL {
        let hostname = host == .ipv4 ? "127.0.0.1" : "[::1]"
        return URL(string: "http://\(hostname):\(port)")!
    }
}

protocol UnslothProcessInspecting: Sendable {
    func inventory() -> [Int32: LocalBackendProcess]
    func identity(of pid: Int32) -> GPUProcessIdentity?
    func arguments(of identity: GPUProcessIdentity) -> [String]?
    func listeningEndpoints(of identity: GPUProcessIdentity) -> [LocalBackendTCPListener]
}
