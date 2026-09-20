import Darwin
import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class LocalBackendProcessResolverTests: XCTestCase {
    func testOllamaSelectsActualListenerAndVerifiedRunnersOnly() async {
        let processes = [
            process(10, parent: 1, path: "/Applications/Ollama.app/Contents/Resources/ollama"),
            process(11, parent: 10, path: "/Applications/Ollama.app/Contents/Resources/ollama"),
            process(
                12, parent: 10, path: "/Applications/Ollama.app/Contents/Resources/llama-server"),
            process(13, parent: 10, path: "/usr/bin/python3"),
            process(14, parent: 10, path: "/Applications/Ollama.app/Contents/Resources/ollama"),
            process(20, parent: 1, path: "/opt/homebrew/bin/ollama"),
            process(21, parent: 20, path: "/opt/homebrew/bin/ollama"),
        ]
        let inspector = ProcessInspectorStub(
            processes, listeners: [10],
            arguments: [
                10: ["ollama", "serve"], 11: ["ollama", "runner", "--ollama-engine"],
                12: ["llama-server", "--model", "test.gguf"],
                13: ["python3", "unrelated.py"], 14: ["ollama", "list"],
                20: ["ollama", "serve"], 21: ["ollama", "runner"],
            ])
        let result = await LocalBackendProcessResolver(inspector: inspector).resolve(
            config(.ollama))
        XCTAssertEqual(result.processes, Set(processes.prefix(3).map(\.identity)))
        XCTAssertNil(result.unavailableReason)
    }

    func testRemoteOrAliasedHostsNeverInspectLocalProcesses() async {
        let inspector = ProcessInspectorStub([], listeners: [])
        let resolver = LocalBackendProcessResolver(inspector: inspector)
        for host in [
            "192.168.1.10", "example.com", "my-mac.local", "127.0.0.2", "localhost.example.com",
        ] {
            let result = await resolver.resolve(config(.ollama, url: "http://\(host):11434"))
            XCTAssertTrue(result.processes.isEmpty)
            XCTAssertTrue(result.unavailableReason?.contains("this Mac") == true)
        }
        XCTAssertEqual(inspector.snapshotCount, 0)
    }

    func testEndpointRecognizesOnlyLiteralLoopbackAndValidPorts() {
        XCTAssertEqual(LocalBackendEndpoint(URL(string: "http://localhost")!)?.port, 80)
        XCTAssertEqual(LocalBackendEndpoint(URL(string: "https://127.0.0.1")!)?.port, 443)
        XCTAssertEqual(LocalBackendEndpoint(URL(string: "http://[::1]:8080")!)?.host, .ipv6)
        XCTAssertNil(LocalBackendEndpoint(URL(string: "ftp://127.0.0.1:8080")!))
        XCTAssertNil(LocalBackendEndpoint(URL(string: "http://127.0.0.1:0")!))
    }

    func testIPv6OnlyWildcardDoesNotMatchIPv4Endpoint() {
        var socket = in_sockinfo()
        socket.insi_vflag = UInt8(INI_IPV6)
        let inspector = DarwinBackendProcessInspector()
        XCTAssertFalse(
            inspector.matches(
                socket, endpoint: LocalBackendEndpoint(URL(string: "http://127.0.0.1:8000")!)!))
        XCTAssertTrue(
            inspector.matches(
                socket, endpoint: LocalBackendEndpoint(URL(string: "http://[::1]:8000")!)!))
        XCTAssertTrue(
            inspector.matches(
                socket, endpoint: LocalBackendEndpoint(URL(string: "http://localhost:8000")!)!))
        socket.insi_vflag = UInt8(INI_IPV4 | INI_IPV6)
        XCTAssertTrue(
            inspector.matches(
                socket, endpoint: LocalBackendEndpoint(URL(string: "http://127.0.0.1:8000")!)!))
    }

    func testUnrecognizedReverseProxyAndWrongSelectedBackendAreUnavailable() async {
        let server = process(10, parent: 1, path: "/opt/homebrew/bin/ollama")
        let tunnel = process(20, parent: 1, path: "/usr/bin/ssh")
        let inspector = ProcessInspectorStub(
            [server, tunnel], listeners: [20],
            arguments: [
                10: ["ollama", "serve"], 20: ["ssh", "-L", "11434:localhost:11434"],
            ])
        let resolver = LocalBackendProcessResolver(inspector: inspector)
        let tunnelResult = await resolver.resolve(config(.ollama))
        XCTAssertTrue(tunnelResult.processes.isEmpty)
        inspector.replace([server], listeners: [10])
        let wrongKind = await resolver.resolve(config(.vllm))
        XCTAssertTrue(wrongKind.processes.isEmpty)
        XCTAssertTrue(wrongKind.unavailableReason?.contains("vLLM") == true)
    }

    func testVLLMMatchesVerifiedPythonAndItsSpawnedOrRetitledWorkers() async {
        let python = "/opt/homebrew/opt/python/bin/python3.12"
        let processes = [
            process(10, parent: 1, path: python),
            process(11, parent: 10, path: python),
            process(12, parent: 11, path: python),
            process(13, parent: 10, path: python),
            process(14, parent: 10, path: python),
            process(15, parent: 10, path: "/another/env/bin/python3.12"),
            process(16, parent: 1, path: python),
        ]
        let inspector = ProcessInspectorStub(
            processes, listeners: [10],
            arguments: [
                10: ["python3.12", "-m", "vllm.entrypoints.openai.api_server", "--model", "test"],
                11: [
                    "python3.12", "-c",
                    "from multiprocessing.spawn import spawn_main; spawn_main()",
                    "--multiprocessing-fork",
                ],
                12: ["CUSTOM::EngineCore_DP0"],
                13: ["python3.12", "unrelated.py"],
                14: [
                    "python3.12", "-c",
                    "from multiprocessing.resource_tracker import main; main(5)",
                ],
                15: ["VLLM::Worker_TP0"],
                16: ["VLLM::Worker_TP1"],
            ])
        let result = await LocalBackendProcessResolver(inspector: inspector).resolve(config(.vllm))
        XCTAssertEqual(result.processes, Set(processes.prefix(3).map(\.identity)))
    }

    func testVLLMSpawnedAPIServerListenerCanResolveItsVerifiedParent() async {
        let python = "/env/bin/python3"
        let parent = process(10, parent: 1, path: python)
        let listener = process(11, parent: 10, path: python)
        let worker = process(12, parent: 10, path: python)
        let inspector = ProcessInspectorStub(
            [parent, listener, worker], listeners: [11],
            arguments: [
                10: ["python3", "/env/bin/vllm", "serve", "test"],
                11: ["VLLM::APIServer"], 12: ["VLLM::EngineCore"],
            ])
        let result = await LocalBackendProcessResolver(inspector: inspector).resolve(config(.vllm))
        XCTAssertEqual(result.processes, [parent.identity, listener.identity, worker.identity])
    }

    func testRapidSupportsCurrentAndLegacyModuleAndCLIForms() async {
        let server = process(10, parent: 1, path: "/env/bin/python3")
        for arguments in [
            ["python3", "-m", "rapid_mlx.cli", "serve", "test"],
            ["python3", "-m", "vllm_mlx.server", "--model", "test"],
            ["python3", "/env/bin/rapid-mlx", "serve", "test"],
            ["python3", "/env/bin/rmlx", "serve", "test"],
            ["python3", "/env/bin/vllm-mlx", "serve", "test"],
        ] {
            let inspector = ProcessInspectorStub(
                [server], listeners: [10], arguments: [10: arguments])
            let result = await LocalBackendProcessResolver(inspector: inspector).resolve(
                config(.rapidMLX))
            XCTAssertEqual(result.processes, [server.identity], "\(arguments)")
        }
    }

    func testArgumentsContainingBackendNamesDoNotEstablishIdentity() async {
        let server = process(10, parent: 1, path: "/env/bin/python3")
        for arguments in [
            ["python3", "unrelated.py", "--model", "vllm"],
            ["python3", "unrelated.py", "-m", "vllm"],
            ["python3", "-c", "print('vllm')", "-m", "vllm"],
            ["python3", "-m", "vllm_unrelated.server"],
            ["python3", "-m", "other_vllm"],
        ] {
            let inspector = ProcessInspectorStub(
                [server], listeners: [10], arguments: [10: arguments])
            let result = await LocalBackendProcessResolver(inspector: inspector).resolve(
                config(.vllm))
            XCTAssertTrue(result.processes.isEmpty, "\(arguments)")
        }
    }

    func testLlamaRouterIncludesOnlyItsServerWorkers() async {
        let parent = process(10, parent: 1, path: "/opt/homebrew/bin/llama-server")
        let worker = process(11, parent: 10, path: parent.executablePath)
        let unrelated = process(12, parent: 1, path: parent.executablePath)
        let helper = process(13, parent: 10, path: "/usr/bin/curl")
        let inspector = ProcessInspectorStub([parent, worker, unrelated, helper], listeners: [10])
        let result = await LocalBackendProcessResolver(inspector: inspector).resolve(
            config(.llamaCpp))
        XCTAssertEqual(result.processes, [parent.identity, worker.identity])
    }

    func testMultipleIndependentListenersAreAmbiguousButInheritedSocketIsAllowed() async {
        let parent = process(10, parent: 1, path: "/usr/local/bin/llama-server")
        let other = process(20, parent: 1, path: parent.executablePath)
        let inspector = ProcessInspectorStub([parent, other], listeners: [10, 20])
        let resolver = LocalBackendProcessResolver(inspector: inspector)
        let ambiguous = await resolver.resolve(config(.llamaCpp))
        XCTAssertTrue(ambiguous.processes.isEmpty)
        let child = process(20, parent: 10, path: parent.executablePath)
        inspector.replace([parent, child], listeners: [10, 20])
        await resolver.reset()
        let shared = await resolver.resolve(config(.llamaCpp))
        XCTAssertEqual(shared.processes, [parent.identity, child.identity])
    }

    func testYoungerReusedParentAndAncestryCycleAreRejected() async {
        let parent = process(10, parent: 1, path: "/usr/local/bin/llama-server", birth: 100)
        let olderChild = process(11, parent: 10, path: parent.executablePath, birth: 50)
        let cycleA = process(20, parent: 21, path: parent.executablePath, birth: 200)
        let cycleB = process(21, parent: 20, path: parent.executablePath, birth: 200)
        let inspector = ProcessInspectorStub([parent, olderChild, cycleA, cycleB], listeners: [10])
        let result = await LocalBackendProcessResolver(inspector: inspector).resolve(
            config(.llamaCpp))
        XCTAssertEqual(result.processes, [parent.identity])
    }

    func testCacheExpiresAndResetForcesDiscovery() async {
        let server = process(10, parent: 1, path: "/usr/local/bin/llama-server")
        let inspector = ProcessInspectorStub([server], listeners: [10])
        let clock = ResolverClock()
        let resolver = LocalBackendProcessResolver(inspector: inspector, clock: { clock.now })
        _ = await resolver.resolve(config(.llamaCpp))
        clock.advance(2)
        _ = await resolver.resolve(config(.llamaCpp))
        XCTAssertEqual(inspector.snapshotCount, 1)
        clock.advance(1)
        _ = await resolver.resolve(config(.llamaCpp))
        XCTAssertEqual(inspector.snapshotCount, 2)
        await resolver.reset()
        _ = await resolver.resolve(config(.llamaCpp))
        XCTAssertEqual(inspector.snapshotCount, 3)
    }

    func testCachedPIDIsRevalidatedAndReusedPIDNeverInheritsIdentity() async {
        let server = process(10, parent: 1, path: "/usr/local/bin/llama-server", birth: 100)
        let inspector = ProcessInspectorStub([server], listeners: [10])
        let resolver = LocalBackendProcessResolver(inspector: inspector)
        let initial = await resolver.resolve(config(.llamaCpp))
        XCTAssertEqual(initial.processes, [server.identity])
        let newIdentity = GPUProcessIdentity(pid: 10, startTimeMicroseconds: 200)
        inspector.setIdentity(newIdentity)
        let changed = await resolver.resolve(config(.llamaCpp))
        XCTAssertTrue(changed.processes.isEmpty)
        XCTAssertEqual(inspector.snapshotCount, 2)
        let restarted = process(10, parent: 1, path: server.executablePath, birth: 200)
        inspector.replace([restarted], listeners: [10])
        await resolver.reset()
        let fresh = await resolver.resolve(config(.llamaCpp))
        XCTAssertEqual(fresh.processes, [newIdentity])
    }

    func testMissingListenerAndInaccessibleArgumentsRemainUnavailable() async {
        let server = process(10, parent: 1, path: "/env/bin/python3")
        let inspector = ProcessInspectorStub([server], listeners: [])
        let resolver = LocalBackendProcessResolver(inspector: inspector)
        let missing = await resolver.resolve(config(.rapidMLX))
        XCTAssertTrue(missing.processes.isEmpty)
        inspector.replace([server], listeners: [10])
        await resolver.reset()
        let unreadable = await resolver.resolve(config(.rapidMLX))
        XCTAssertTrue(unreadable.processes.isEmpty)
    }

    func testKernelArgumentDecoderExcludesEnvironmentAndHandlesEmptyArguments() {
        let arguments = ["python3", "", "-m", "rapid_mlx.cli"]
        var count = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &count) { Array($0) }
        bytes += Array("/env/bin/python3".utf8) + [0, 0, 0]
        for argument in arguments { bytes += Array(argument.utf8) + [0] }
        bytes += Array("PRIVATE_API_KEY=not-an-argument".utf8) + [0]
        XCTAssertEqual(DarwinBackendProcessInspector.decodeArguments(bytes), arguments)
        XCTAssertNil(DarwinBackendProcessInspector.decodeArguments([1, 0, 0, 0, 65]))
        XCTAssertNil(DarwinBackendProcessInspector.decodeArguments([255, 255, 255, 255, 0]))
    }

    private func config(_ kind: BackendKind, url: String = "http://127.0.0.1:11434")
        -> BackendConfiguration
    {
        BackendConfiguration(kind: kind, baseURL: URL(string: url)!)
    }

    private func process(_ pid: Int32, parent: Int32, path: String, birth: UInt64? = nil)
        -> LocalBackendProcess
    {
        LocalBackendProcess(
            identity: GPUProcessIdentity(
                pid: pid, startTimeMicroseconds: birth ?? UInt64(pid) * 1_000),
            parentPID: parent, executablePath: path)
    }
}

private final class ProcessInspectorStub: LocalBackendProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Int32: LocalBackendProcess]
    private var listeners: Set<Int32>
    private var liveIdentities: [Int32: GPUProcessIdentity]
    private let argumentValues: [Int32: [String]]
    private var count = 0

    init(
        _ processes: [LocalBackendProcess], listeners: Set<Int32>,
        arguments: [Int32: [String]] = [:]
    ) {
        self.processes = Dictionary(uniqueKeysWithValues: processes.map { ($0.identity.pid, $0) })
        liveIdentities = Dictionary(
            uniqueKeysWithValues: processes.map { ($0.identity.pid, $0.identity) })
        self.listeners = listeners
        argumentValues = arguments
    }

    var snapshotCount: Int { lock.withLock { count } }

    func snapshot(for endpoint: LocalBackendEndpoint) -> LocalBackendProcessSnapshot {
        lock.withLock {
            count += 1
            return LocalBackendProcessSnapshot(processes: processes, listeners: listeners)
        }
    }

    func identity(of pid: Int32) -> GPUProcessIdentity? { lock.withLock { liveIdentities[pid] } }
    func arguments(of identity: GPUProcessIdentity) -> [String]? { argumentValues[identity.pid] }
    func setIdentity(_ identity: GPUProcessIdentity) {
        lock.withLock { liveIdentities[identity.pid] = identity }
    }

    func replace(_ processes: [LocalBackendProcess], listeners: Set<Int32>) {
        lock.withLock {
            self.processes = Dictionary(
                uniqueKeysWithValues: processes.map { ($0.identity.pid, $0) })
            liveIdentities = Dictionary(
                uniqueKeysWithValues: processes.map { ($0.identity.pid, $0.identity) })
            self.listeners = listeners
        }
    }
}

private final class ResolverClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
