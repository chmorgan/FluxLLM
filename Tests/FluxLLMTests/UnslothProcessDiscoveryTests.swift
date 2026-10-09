import Darwin
import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class UnslothProcessDiscoveryTests: XCTestCase {
    private let installation = "/Users/example/.unsloth"

    func testManagedStudioAndOnlyItsWorkerUseNativeListeningPorts() async {
        let studio = studioProcess()
        let worker = workerProcess()
        let unrelated = process(40, parent: 1, path: "/opt/homebrew/bin/llama-server")
        let python = process(41, parent: 1, path: "/usr/bin/python3")
        let inspector = UnslothInspectorStub(
            [studio, worker, unrelated, python], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)], 20: [listener(54234)], 40: [listener(8080)]])
        let discovery = UnslothProcessDiscovery(inspector: inspector)

        let result = await discovery.servers()

        XCTAssertEqual(result, [server(studio: studio, worker: worker)])
        XCTAssertEqual(inspector.listenerPIDs, [10, 20])
        XCTAssertEqual(inspector.inventoryCount, 1)
    }

    func testUnloadedStudioRetainsItsStableURL() async {
        let studio = studioProcess()
        let inspector = UnslothInspectorStub(
            [studio], arguments: [10: studioArguments()], listeners: [10: [listener(8888)]])
        let discovery = UnslothProcessDiscovery(inspector: inspector)

        let result = await discovery.servers()

        XCTAssertEqual(result, [server(studio: studio, worker: nil)])
    }

    func testOnlyVerifiedWorkerKeyFileArgumentIsAttachedToDiscovery() async {
        let file = installation + "/studio/auth/llama_api_key_0123456789abcdef"
        let reference = UnslothWorkerKeyFile(
            fileURL: URL(fileURLWithPath: file),
            authDirectoryURL: URL(fileURLWithPath: installation + "/studio/auth"))
        for flags in [["--api-key-file", file], ["--api-key-file=" + file]] {
            let inspector = UnslothInspectorStub(
                [studioProcess(), workerProcess()],
                arguments: [10: studioArguments(), 20: workerArguments() + flags],
                listeners: [10: [listener(8888)], 20: [listener(54234)]])
            let result = await UnslothProcessDiscovery(inspector: inspector).servers()
            XCTAssertEqual(result.first?.workerKeySource, .file(reference))
            XCTAssertEqual(inspector.argumentPIDs, [10, 20])
        }
    }

    func testUnreadableOrEmptyWorkerArgumentsAreNotAssumedKeyless() async {
        for unreadable in [true, false] {
            let inspector = loadedInspector()
            if unreadable {
                inspector.removeArguments(pid: 20)
            } else {
                inspector.replace(
                    [studioProcess(), workerProcess()],
                    arguments: [10: studioArguments(), 20: []],
                    listeners: [10: [listener(8888)], 20: [listener(54234)]])
            }
            let result = await UnslothProcessDiscovery(inspector: inspector).servers()
            XCTAssertEqual(result.first?.workerIdentity, workerProcess().identity)
            XCTAssertEqual(result.first?.workerKeySource, .unavailable)
        }
        let result = await UnslothProcessDiscovery(inspector: loadedInspector()).servers()
        XCTAssertEqual(result.first?.workerKeySource, UnslothWorkerKeySource.none)
    }

    func testUnsafeDuplicateOrUnsupportedKeyArgumentsAreUnavailable() async {
        let file = installation + "/studio/auth/llama_api_key_0123456789abcdef"
        let invalidFlags = [
            ["--api-key-file"], ["--api-key-file="], ["--api-key-file", "--metrics"],
            ["--api-key-file", file, "--api-key-file=" + file],
            ["--api-key-file", "relative/llama_api_key_0123456789abcdef"],
            ["--api-key-file", "/Users/other/.unsloth/studio/auth/llama_api_key_0123456789abcdef"],
            ["--api-key-file", installation + "/studio/auth/auth.db"],
            ["--api-key-file", installation + "/studio/auth/llama_api_key_0123456789ABCDEf"],
            [
                "--api-key-file",
                installation + "/studio/auth/sub/../llama_api_key_0123456789abcdef",
            ],
            ["--api-key-file", installation + "/studio/auth/./llama_api_key_0123456789abcdef"],
            ["--api-key-file", installation + "/studio/auth//llama_api_key_0123456789abcdef"],
            ["--api-key-file", file + "/"],
            ["--api-key", "synthetic-inline-key"], ["--api-key=synthetic-inline-key"],
        ]
        for flags in invalidFlags {
            let inspector = UnslothInspectorStub(
                [studioProcess(), workerProcess()],
                arguments: [10: studioArguments(), 20: workerArguments() + flags],
                listeners: [10: [listener(8888)], 20: [listener(54234)]])
            let result = await UnslothProcessDiscovery(inspector: inspector).servers()
            XCTAssertEqual(result.first?.workerKeySource, .unavailable, "Rejected flags: \(flags)")
        }
    }

    func testUnrelatedWorkersCannotContributeKeyFileMetadata() async {
        let unrelated = workerProcess(pid: 21, parent: 1)
        let foreign = process(
            22, parent: 10, path: "/Users/other/.unsloth/llama.cpp/build/bin/llama-server")
        let file = installation + "/studio/auth/llama_api_key_0123456789abcdef"
        let inspector = UnslothInspectorStub(
            [studioProcess(), workerProcess(), unrelated, foreign],
            arguments: [
                10: studioArguments(), 21: [unrelated.executablePath, "--api-key-file", file],
                22: [foreign.executablePath, "--api-key-file", file],
            ],
            listeners: [
                10: [listener(8888)], 20: [listener(54234)],
                21: [listener(54235)], 22: [listener(54236)],
            ])
        let result = await UnslothProcessDiscovery(inspector: inspector).servers()
        XCTAssertEqual(result.first?.workerKeySource, UnslothWorkerKeySource.none)
        XCTAssertEqual(inspector.argumentPIDs, [10, 20])
    }

    func testWorkerKeyMetadataFollowsBirthChangesWithoutReusingCachedArguments() async {
        let firstFile = installation + "/studio/auth/llama_api_key_0123456789abcdef"
        let secondFile = installation + "/studio/auth/llama_api_key_fedcba9876543210"
        let inspector = UnslothInspectorStub(
            [studioProcess(), workerProcess()],
            arguments: [
                10: studioArguments(), 20: workerArguments() + ["--api-key-file", firstFile],
            ],
            listeners: [10: [listener(8888)], 20: [listener(54234)]])
        let discovery = UnslothProcessDiscovery(inspector: inspector)
        let first = await discovery.servers()
        _ = await discovery.servers()
        XCTAssertEqual(inspector.argumentPIDs, [10, 20])
        let replacement = workerProcess(birth: 99_000)
        inspector.replace(
            [studioProcess(), replacement],
            arguments: [
                10: studioArguments(), 20: workerArguments() + ["--api-key-file", secondFile],
            ],
            listeners: [10: [listener(8888)], 20: [listener(54321)]])
        let refreshed = await discovery.servers()
        XCTAssertNotEqual(refreshed.first?.workerKeySource, first.first?.workerKeySource)
        XCTAssertEqual(refreshed.first?.workerIdentity, replacement.identity)
        guard case .file(let reference) = refreshed.first?.workerKeySource else {
            return XCTFail("Expected the replacement worker's key file")
        }
        XCTAssertEqual(reference.fileURL.path, secondFile)
    }

    func testWorkerDisappearingDuringArgumentReadDoesNotPublishItsKeyReference() async {
        let inspector = loadedInspector()
        inspector.removeIdentityAfterArguments(pid: 20)
        let result = await UnslothProcessDiscovery(inspector: inspector).servers()
        XCTAssertEqual(result, [server(studio: studioProcess(), worker: nil)])
    }

    func testPositiveCacheChecksIdentitiesWithoutInventoriesOrSocketRescans() async {
        let inspector = loadedInspector()
        let clock = UnslothDiscoveryClock()
        let discovery = UnslothProcessDiscovery(inspector: inspector, clock: { clock.now })
        let first = await discovery.servers()
        let identitiesAfterFirst = inspector.identityCount
        clock.advance(4.9)
        let second = await discovery.servers()

        XCTAssertEqual(first, second)
        XCTAssertEqual(inspector.inventoryCount, 1)
        XCTAssertEqual(inspector.listenerPIDs, [10, 20])
        XCTAssertGreaterThan(inspector.identityCount, identitiesAfterFirst)
        clock.advance(0.1)
        _ = await discovery.servers()
        XCTAssertEqual(inspector.inventoryCount, 2)
    }

    func testConcurrentColdCallsShareOneNativeInventory() async {
        let inspector = loadedInspector()
        let started = expectation(description: "cold inspection began")
        inspector.blockInventory(started: { started.fulfill() })
        let discovery = UnslothProcessDiscovery(inspector: inspector)
        let callers = (0..<6).map { _ in Task { await discovery.servers() } }
        await fulfillment(of: [started], timeout: 2)
        await waitForCallers(6, discovery: discovery)
        inspector.releaseInventory()
        for caller in callers {
            let result = await caller.value
            XCTAssertEqual(result, [server(studio: studioProcess(), worker: workerProcess())])
        }
        XCTAssertEqual(inspector.inventoryCount, 1)
        XCTAssertEqual(inspector.listenerPIDs, [10, 20])
    }

    func testConcurrentCachedCallsShareOneIdentityValidation() async {
        let inspector = loadedInspector()
        let discovery = UnslothProcessDiscovery(inspector: inspector)
        _ = await discovery.servers()
        let initialIdentityCount = inspector.identityCount
        let started = expectation(description: "cache identity validation began")
        inspector.blockIdentity(started: { started.fulfill() })
        let callers = (0..<6).map { _ in Task { await discovery.servers() } }
        await fulfillment(of: [started], timeout: 2)
        await waitForCallers(6, discovery: discovery)
        inspector.releaseIdentity()
        for caller in callers {
            let result = await caller.value
            XCTAssertEqual(result, [server(studio: studioProcess(), worker: workerProcess())])
        }
        XCTAssertEqual(inspector.identityCount - initialIdentityCount, 2)
        XCTAssertEqual(inspector.inventoryCount, 1)
    }

    func testCancelledCallerCannotDiscardSharedColdInspection() async {
        let inspector = loadedInspector()
        let started = expectation(description: "shared cold inspection began")
        inspector.blockInventory(started: { started.fulfill() })
        let discovery = UnslothProcessDiscovery(inspector: inspector)
        let cancelled = Task { await discovery.servers() }
        await fulfillment(of: [started], timeout: 2)
        let retained = Task { await discovery.servers() }
        await waitForCallers(2, discovery: discovery)
        cancelled.cancel()
        inspector.releaseInventory()
        let cancelledResult = await cancelled.value
        let retainedResult = await retained.value
        XCTAssertTrue(cancelledResult.isEmpty)
        XCTAssertEqual(retainedResult, [server(studio: studioProcess(), worker: workerProcess())])
        _ = await discovery.servers()
        XCTAssertEqual(inspector.inventoryCount, 1)
    }

    func testNegativeCacheAndUnloadedStudioRefreshWithinFiveSeconds() async {
        let inspector = UnslothInspectorStub([])
        let clock = UnslothDiscoveryClock()
        let discovery = UnslothProcessDiscovery(inspector: inspector, clock: { clock.now })
        let initial = await discovery.servers()
        XCTAssertTrue(initial.isEmpty)
        inspector.replace(
            [studioProcess()], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)]])
        clock.advance(4)
        let cachedEmpty = await discovery.servers()
        XCTAssertTrue(cachedEmpty.isEmpty)
        XCTAssertEqual(inspector.inventoryCount, 1)
        clock.advance(1)
        let unloaded = await discovery.servers()
        XCTAssertEqual(unloaded, [server(studio: studioProcess(), worker: nil)])

        inspector.replace(
            [studioProcess(), workerProcess()], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)], 20: [listener(54234)]])
        clock.advance(5)
        let loaded = await discovery.servers()
        XCTAssertEqual(loaded, [server(studio: studioProcess(), worker: workerProcess())])
        XCTAssertEqual(inspector.inventoryCount, 3)
    }

    func testWorkerDisappearanceInvalidatesImmediatelyAndReloadFollowsNewPort() async {
        let inspector = loadedInspector()
        let clock = UnslothDiscoveryClock()
        let discovery = UnslothProcessDiscovery(inspector: inspector, clock: { clock.now })
        let original = await discovery.servers()
        inspector.replace(
            [studioProcess()], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)]])
        let unloaded = await discovery.servers()
        XCTAssertEqual(unloaded, [server(studio: studioProcess(), worker: nil)])
        XCTAssertEqual(inspector.inventoryCount, 2)

        let replacement = workerProcess(pid: 21, birth: 50_000)
        inspector.replace(
            [studioProcess(), replacement], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)], 21: [listener(54321)]])
        clock.advance(5)
        let reloaded = await discovery.servers()
        XCTAssertEqual(reloaded.first?.studioURL, original.first?.studioURL)
        XCTAssertEqual(reloaded.first?.workerURL, URL(string: "http://127.0.0.1:54321"))
        XCTAssertEqual(reloaded.first?.workerIdentity, replacement.identity)
    }

    func testReusedWorkerPIDCannotInheritCachedBinding() async {
        let inspector = loadedInspector()
        let discovery = UnslothProcessDiscovery(inspector: inspector)
        _ = await discovery.servers()
        let replacement = workerProcess(birth: 99_000)
        inspector.replace(
            [studioProcess(), replacement], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)], 20: [listener(54321)]])

        let result = await discovery.servers()

        XCTAssertEqual(result.first?.workerIdentity, replacement.identity)
        XCTAssertEqual(result.first?.workerURL, URL(string: "http://127.0.0.1:54321"))
        XCTAssertEqual(inspector.inventoryCount, 2)
    }

    func testUnrelatedPythonStandaloneLlamaAndOtherInstallationAreExcluded() async {
        let studio = studioProcess()
        let foreignWorker = process(
            20, parent: 10, path: "/Users/other/.unsloth/llama.cpp/build/bin/llama-server")
        let standalone = workerProcess(pid: 21, parent: 1)
        for arguments in [
            ["/usr/bin/python3", "unrelated.py", "--model", "unsloth"],
            [installation + "/studio/unsloth_studio/bin/python", "unrelated.py", "studio"],
            [
                installation + "/studio/unsloth_studio/bin/python",
                installation + "/studio/unsloth_studio/bin/unsloth", "train",
            ],
        ] {
            let inspector = UnslothInspectorStub(
                [studio, foreignWorker, standalone], arguments: [10: arguments],
                listeners: [10: [listener(8888)], 20: [listener(54234)], 21: [listener(54235)]])
            let result = await UnslothProcessDiscovery(inspector: inspector).servers()
            XCTAssertTrue(result.isEmpty)
            XCTAssertTrue(inspector.listenerPIDs.isEmpty)
        }
        let inspector = UnslothInspectorStub(
            [studio, foreignWorker, standalone], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)], 20: [listener(54234)], 21: [listener(54235)]])
        let result = await UnslothProcessDiscovery(inspector: inspector).servers()
        XCTAssertEqual(result, [server(studio: studio, worker: nil)])
        XCTAssertEqual(inspector.listenerPIDs, [10])
    }

    func testAmbiguousWorkersStayExplicitAndDoNotSelectFirstProcess() async {
        let studio = studioProcess()
        let first = workerProcess()
        let second = workerProcess(pid: 21)
        let inspector = UnslothInspectorStub(
            [second, studio, first], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)], 20: [listener(54234)], 21: [listener(54321)]])

        let result = await UnslothProcessDiscovery(inspector: inspector).servers()

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.compactMap(\.workerIdentity)), [first.identity, second.identity])
        XCTAssertEqual(Set(result.map(\.studioURL)), [URL(string: "http://127.0.0.1:8888")!])
    }

    func testAmbiguousStudioListenerDoesNotGuessEndpoint() async {
        let inspector = UnslothInspectorStub(
            [studioProcess(), workerProcess()], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888), listener(9999)], 20: [listener(54234)]])
        let result = await UnslothProcessDiscovery(inspector: inspector).servers()
        XCTAssertTrue(result.isEmpty)
    }

    func testIPv6LoopbackProducesLiteralIPv6URLs() async {
        let inspector = UnslothInspectorStub(
            [studioProcess(), workerProcess()], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888, host: .ipv6)], 20: [listener(54234, host: .ipv6)]])
        let result = await UnslothProcessDiscovery(inspector: inspector).servers()
        XCTAssertEqual(result.first?.studioURL, URL(string: "http://[::1]:8888"))
        XCTAssertEqual(result.first?.workerURL, URL(string: "http://[::1]:54234"))
    }

    func testDualStackListenersOnSamePortRemainOneBinding() async {
        let inspector = UnslothInspectorStub(
            [studioProcess(), workerProcess()], arguments: [10: studioArguments()],
            listeners: [
                10: [listener(8888, host: .ipv6), listener(8888)],
                20: [listener(54234, host: .ipv6), listener(54234)],
            ])
        let result = await UnslothProcessDiscovery(inspector: inspector).servers()
        XCTAssertEqual(result, [server(studio: studioProcess(), worker: workerProcess())])
    }

    func testExcessiveListenerSetCannotCreateUnboundedCachedBindings() async {
        let inspector = UnslothInspectorStub(
            [studioProcess(), workerProcess()], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)], 20: (10_000..<10_129).map { listener(UInt16($0)) }])
        let discovery = UnslothProcessDiscovery(inspector: inspector)
        let first = await discovery.servers()
        let second = await discovery.servers()
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(inspector.inventoryCount, 1)
    }

    func testNativeSocketExtractionRejectsWildcardsRemoteAddressesAndZeroPorts() {
        let inspector = DarwinBackendProcessInspector()
        var socket = in_sockinfo()
        socket.insi_vflag = UInt8(INI_IPV4)
        socket.insi_lport = Int32(UInt16(8888).bigEndian)
        XCTAssertTrue(inspector.literalLoopbackEndpoints(socket).isEmpty)
        socket.insi_laddr.ina_46.i46a_addr4.s_addr = UInt32(0x7F00_0001).bigEndian
        XCTAssertEqual(inspector.literalLoopbackEndpoints(socket), [listener(8888)])
        socket.insi_laddr.ina_46.i46a_addr4.s_addr = UInt32(0x7F00_0002).bigEndian
        XCTAssertTrue(inspector.literalLoopbackEndpoints(socket).isEmpty)

        socket.insi_vflag = UInt8(INI_IPV6)
        socket.insi_laddr.ina_6 = in6_addr()
        XCTAssertTrue(inspector.literalLoopbackEndpoints(socket).isEmpty)
        withUnsafeMutableBytes(of: &socket.insi_laddr.ina_6) { $0[15] = 1 }
        XCTAssertEqual(inspector.literalLoopbackEndpoints(socket), [listener(8888, host: .ipv6)])
        socket.insi_lport = 0
        XCTAssertTrue(inspector.literalLoopbackEndpoints(socket).isEmpty)
    }

    func testDisappearingProcessDuringInspectionIsNotPublished() async {
        let inspector = loadedInspector()
        inspector.removeIdentityAfterListeners(pid: 20)
        let result = await UnslothProcessDiscovery(inspector: inspector).servers()
        XCTAssertEqual(result, [server(studio: studioProcess(), worker: nil)])
    }

    func testIntermediateAncestorBirthIsVerifiedAndCached() async {
        let studio = studioProcess()
        let helper = process(15, parent: 10, path: "/usr/bin/true")
        let worker = workerProcess(parent: 15)
        let inspector = UnslothInspectorStub(
            [studio, helper, worker], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)], 20: [listener(54234)]])
        let discovery = UnslothProcessDiscovery(inspector: inspector)
        let initial = await discovery.servers()
        XCTAssertEqual(initial, [server(studio: studio, worker: worker)])
        inspector.replace(
            [studio, process(15, parent: 10, path: helper.executablePath, birth: 99_000), worker],
            arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)], 20: [listener(54234)]])
        let result = await discovery.servers()
        XCTAssertEqual(result, [server(studio: studio, worker: nil)])
        XCTAssertEqual(inspector.inventoryCount, 2)
    }

    func testResetClearsPositiveAndNegativeCaches() async {
        let inspector = loadedInspector()
        let discovery = UnslothProcessDiscovery(inspector: inspector)
        _ = await discovery.servers()
        await discovery.reset()
        _ = await discovery.servers()
        XCTAssertEqual(inspector.inventoryCount, 2)
        inspector.replace([])
        _ = await discovery.servers()
        await discovery.reset()
        _ = await discovery.servers()
        XCTAssertEqual(inspector.inventoryCount, 4)
    }

    func testCancelledInspectionCannotPopulateCache() async {
        let inspector = loadedInspector()
        let started = expectation(description: "inspection began")
        inspector.blockInventory(started: { started.fulfill() })
        let discovery = UnslothProcessDiscovery(inspector: inspector)
        let task = Task { await discovery.servers() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        inspector.releaseInventory()
        let result = await task.value
        XCTAssertTrue(result.isEmpty)
        _ = await discovery.servers()
        XCTAssertEqual(inspector.inventoryCount, 2)
    }

    func testResetDuringInspectionCannotRestoreStaleCache() async {
        let inspector = loadedInspector()
        let started = expectation(description: "inspection began")
        inspector.blockInventory(started: { started.fulfill() })
        let discovery = UnslothProcessDiscovery(inspector: inspector)
        let task = Task { await discovery.servers() }
        await fulfillment(of: [started], timeout: 2)
        await discovery.reset()
        inspector.releaseInventory()
        let result = await task.value
        XCTAssertTrue(result.isEmpty)
        _ = await discovery.servers()
        XCTAssertEqual(inspector.inventoryCount, 2)
    }

    func testOldFlightCompletionCannotClearNewFlightAfterReset() async {
        let inspector = loadedInspector()
        let firstStarted = expectation(description: "old inspection began")
        let firstGate = inspector.blockInventory(started: { firstStarted.fulfill() })
        let discovery = UnslothProcessDiscovery(inspector: inspector)
        let old = Task { await discovery.servers() }
        await fulfillment(of: [firstStarted], timeout: 2)
        await discovery.reset()
        let secondStarted = expectation(description: "new inspection began")
        let secondGate = inspector.blockInventory(started: { secondStarted.fulfill() })
        let current = Task { await discovery.servers() }
        await fulfillment(of: [secondStarted], timeout: 2)

        firstGate.signal()
        let oldResult = await old.value
        XCTAssertTrue(oldResult.isEmpty)
        let follower = Task { await discovery.servers() }
        await waitForCallers(2, discovery: discovery)
        secondGate.signal()
        let currentResult = await current.value
        let followerResult = await follower.value
        XCTAssertEqual(currentResult, followerResult)
        XCTAssertEqual(inspector.inventoryCount, 2)
    }

    private func waitForCallers(_ count: Int, discovery: UnslothProcessDiscovery) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while await discovery.inFlightCallCount != count,
            ProcessInfo.processInfo.systemUptime < deadline
        {
            await Task.yield()
        }
        let actual = await discovery.inFlightCallCount
        XCTAssertEqual(actual, count, "All concurrent callers must join the same inspection")
    }

    private func studioProcess() -> LocalBackendProcess {
        process(10, parent: 1, path: "/Users/example/.local/share/uv/python/cpython/bin/python3.13")
    }

    private func studioArguments() -> [String] {
        [
            installation + "/studio/unsloth_studio/bin/python",
            installation + "/studio/unsloth_studio/bin/unsloth", "studio",
        ]
    }

    private func workerProcess(pid: Int32 = 20, parent: Int32 = 10, birth: UInt64? = nil)
        -> LocalBackendProcess
    {
        process(
            pid, parent: parent, path: installation + "/llama.cpp/build/bin/llama-server",
            birth: birth)
    }

    private func workerArguments() -> [String] {
        [installation + "/llama.cpp/build/bin/llama-server", "--metrics"]
    }

    private func process(_ pid: Int32, parent: Int32, path: String, birth: UInt64? = nil)
        -> LocalBackendProcess
    {
        LocalBackendProcess(
            identity: GPUProcessIdentity(
                pid: pid, startTimeMicroseconds: birth ?? UInt64(pid) * 1_000),
            parentPID: parent, executablePath: path)
    }

    private func listener(_ port: UInt16, host: LocalBackendTCPListener.Host = .ipv4)
        -> LocalBackendTCPListener
    {
        LocalBackendTCPListener(host: host, port: port)
    }

    private func server(studio: LocalBackendProcess, worker: LocalBackendProcess?) -> UnslothServer
    {
        UnslothServer(
            studioURL: URL(string: "http://127.0.0.1:8888")!,
            workerURL: worker == nil ? nil : URL(string: "http://127.0.0.1:54234")!,
            studioIdentity: studio.identity, workerIdentity: worker?.identity)
    }

    private func loadedInspector() -> UnslothInspectorStub {
        UnslothInspectorStub(
            [studioProcess(), workerProcess()], arguments: [10: studioArguments()],
            listeners: [10: [listener(8888)], 20: [listener(54234)]])
    }
}

private final class UnslothInspectorStub: UnslothProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Int32: LocalBackendProcess] = [:]
    private var argumentsByPID: [Int32: [String]] = [:]
    private var listenersByPID: [Int32: [LocalBackendTCPListener]] = [:]
    private var liveIdentities: [Int32: GPUProcessIdentity] = [:]
    private var inventories = 0
    private var identities = 0
    private var listeners: [Int32] = []
    private var argumentsRead: [Int32] = []
    private var removeAfterListeners: Int32?
    private var removeAfterArguments: Int32?
    private var blocked: (started: @Sendable () -> Void, gate: DispatchSemaphore)?
    private var inventoryGate: DispatchSemaphore?
    private var blockedIdentity: (@Sendable () -> Void)?
    private let identityGate = DispatchSemaphore(value: 0)

    init(
        _ processes: [LocalBackendProcess], arguments: [Int32: [String]] = [:],
        listeners: [Int32: [LocalBackendTCPListener]] = [:]
    ) {
        replace(processes, arguments: arguments, listeners: listeners)
    }

    var inventoryCount: Int { lock.withLock { inventories } }
    var identityCount: Int { lock.withLock { identities } }
    var listenerPIDs: [Int32] { lock.withLock { listeners } }
    var argumentPIDs: [Int32] { lock.withLock { argumentsRead } }

    func inventory() -> [Int32: LocalBackendProcess] {
        let (value, started) = lock.withLock {
            inventories += 1
            let started = blocked
            blocked = nil
            return (processes, started)
        }
        if let started {
            started.started()
            started.gate.wait()
        }
        return value
    }

    func identity(of pid: Int32) -> GPUProcessIdentity? {
        let (identity, started) = lock.withLock {
            identities += 1
            let started = blockedIdentity
            blockedIdentity = nil
            return (liveIdentities[pid], started)
        }
        if let started {
            started()
            identityGate.wait()
        }
        return identity
    }

    func arguments(of identity: GPUProcessIdentity) -> [String]? {
        lock.withLock {
            argumentsRead.append(identity.pid)
            let result = argumentsByPID[identity.pid]
            if removeAfterArguments == identity.pid {
                liveIdentities.removeValue(forKey: identity.pid)
                removeAfterArguments = nil
            }
            return result
        }
    }

    func listeningEndpoints(of identity: GPUProcessIdentity) -> [LocalBackendTCPListener] {
        lock.withLock {
            listeners.append(identity.pid)
            let result = listenersByPID[identity.pid] ?? []
            if removeAfterListeners == identity.pid {
                liveIdentities.removeValue(forKey: identity.pid)
                removeAfterListeners = nil
            }
            return result
        }
    }

    func replace(
        _ processes: [LocalBackendProcess], arguments: [Int32: [String]] = [:],
        listeners: [Int32: [LocalBackendTCPListener]] = [:]
    ) {
        lock.withLock {
            self.processes = Dictionary(
                uniqueKeysWithValues: processes.map { ($0.identity.pid, $0) })
            // Existing loaded fixtures explicitly model a worker without authentication.
            // A missing argv read is injected separately and must stay unavailable.
            argumentsByPID = Dictionary(
                uniqueKeysWithValues: processes.filter { $0.executableName == "llama-server" }
                    .map { ($0.identity.pid, [$0.executablePath, "--metrics"]) }
            )
            .merging(arguments) { _, supplied in supplied }
            listenersByPID = listeners
            liveIdentities = Dictionary(
                uniqueKeysWithValues: processes.map { ($0.identity.pid, $0.identity) })
        }
    }

    func removeIdentityAfterListeners(pid: Int32) { lock.withLock { removeAfterListeners = pid } }
    func removeIdentityAfterArguments(pid: Int32) { lock.withLock { removeAfterArguments = pid } }
    func removeArguments(pid: Int32) {
        _ = lock.withLock { argumentsByPID.removeValue(forKey: pid) }
    }
    @discardableResult
    func blockInventory(started: @escaping @Sendable () -> Void) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock {
            blocked = (started, gate)
            inventoryGate = gate
        }
        return gate
    }
    func releaseInventory() { lock.withLock { inventoryGate }?.signal() }
    func blockIdentity(started: @escaping @Sendable () -> Void) {
        lock.withLock { blockedIdentity = started }
    }
    func releaseIdentity() { identityGate.signal() }
}

private final class UnslothDiscoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
