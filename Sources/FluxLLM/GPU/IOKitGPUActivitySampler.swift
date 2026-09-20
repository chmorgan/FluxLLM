import Foundation
import IOKit

/// Reads process-owned GPU time; it never substitutes device-wide GPU utilization.
/// The registry's driver-specific keys are undocumented and may not be available.
public actor IOKitGPUActivitySampler: GPUActivitySampling {
    typealias RegistryReader = @Sendable () throws -> GPURegistrySnapshot
    typealias SampleClock = @Sendable () -> GPUActivityInstant

    private struct ClientIdentity: Hashable {
        let process: GPUProcessIdentity
        let registryID: UInt64
    }

    private struct Baseline {
        let instant: GPUActivityInstant
        let clients: [ClientIdentity: GPURegistryClient]
    }

    private let reader: RegistryReader
    private let clock: SampleClock
    private let maximumInterval: TimeInterval
    private var baseline: Baseline?

    public init() {
        reader = IOKitGPURegistry.read
        let continuousClock = ContinuousClock()
        let origin = continuousClock.now
        clock = {
            let duration = origin.duration(to: continuousClock.now).components
            return GPUActivityInstant(
                uptime: Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                date: Date())
        }
        maximumInterval = 5
    }

    init(
        reader: @escaping RegistryReader,
        clock: @escaping SampleClock,
        maximumInterval: TimeInterval = 5
    ) {
        self.reader = reader
        self.clock = clock
        self.maximumInterval = maximumInterval
    }

    public func reset() async {
        baseline = nil
    }

    public func sample(processes: Set<GPUProcessIdentity>) async -> GPUActivitySample {
        let instant = clock()
        let processIDs = processes.map(\.pid).sorted()
        func unavailable(_ reason: String) -> GPUActivitySample {
            GPUActivitySample(
                timestamp: instant.date, processIDs: processIDs, unavailableReason: reason)
        }

        guard !processes.isEmpty else {
            baseline = nil
            return unavailable("No local backend process has been identified.")
        }
        // A PID cannot identify two live processes. Refuse ambiguous input rather
        // than matching a registry owner to an arbitrary birth time.
        guard Set(processIDs).count == processIDs.count else {
            baseline = nil
            return unavailable("The backend process identity changed; waiting for a new reading.")
        }
        let owners = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let snapshot: GPURegistrySnapshot
        do {
            snapshot = try reader()
        } catch {
            baseline = nil
            return unavailable("macOS GPU counters could not be read.")
        }
        guard snapshot.acceleratorCount > 0 else {
            baseline = nil
            return unavailable("This Mac does not expose process GPU counters.")
        }
        guard snapshot.unreadableProcessIDs.isDisjoint(with: owners.keys) else {
            baseline = nil
            return unavailable("Some backend GPU counters could not be read.")
        }

        var clients: [ClientIdentity: GPURegistryClient] = [:]
        var duplicateIDs: Set<ClientIdentity> = []
        for client in snapshot.clients {
            guard let process = owners[client.processID], !client.queues.isEmpty else { continue }
            let identity = ClientIdentity(process: process, registryID: client.registryID)
            if clients[identity] != nil { duplicateIDs.insert(identity) }
            clients[identity] = client
        }
        // The same registry entry must not be counted twice if the service tree
        // exposes it through multiple accelerator paths.
        for identity in duplicateIDs { clients.removeValue(forKey: identity) }
        guard !clients.isEmpty else {
            baseline = nil
            return unavailable("The selected backend has no readable GPU activity counters.")
        }
        let measuredProcessIDs = Set(clients.keys.map(\.process.pid)).sorted()

        let previous = baseline
        baseline = Baseline(instant: instant, clients: clients)
        guard let previous else {
            return unavailable("Waiting for the next GPU activity sample.")
        }
        let elapsed = instant.uptime - previous.instant.uptime
        let wallElapsed = instant.date.timeIntervalSince(previous.instant.date)
        // ContinuousClock includes sleep. Also reject wall-clock corrections so
        // chart timestamps and this interval's elapsed time remain consistent.
        guard elapsed.isFinite, elapsed > 0, elapsed <= maximumInterval,
            wallElapsed.isFinite, wallElapsed > 0, wallElapsed <= maximumInterval,
            abs(wallElapsed - elapsed) < 1
        else {
            return unavailable("GPU sampling resumed; waiting for a new reading.")
        }
        guard clients.keys.count == previous.clients.keys.count,
            Set(clients.keys) == Set(previous.clients.keys), duplicateIDs.isEmpty
        else {
            return unavailable("GPU workers changed; waiting for a new reading.")
        }

        var gpuNanoseconds = 0.0
        var stableClients = 0
        for (identity, client) in clients {
            guard let old = previous.clients[identity],
                let delta = client.nanoseconds(since: old)
            else {
                return unavailable("GPU workers changed; waiting for a new reading.")
            }
            gpuNanoseconds += delta
            stableClients += 1
        }
        guard stableClients > 0 else {
            return unavailable("GPU workers changed; waiting for a new reading.")
        }
        let activity = gpuNanoseconds / (elapsed * 1_000_000_000) * 100
        guard activity.isFinite, activity >= 0 else {
            return unavailable("macOS returned an invalid GPU activity counter.")
        }
        // Parallel queues can legitimately exceed 100%. This is accumulated
        // execution time / wall time, not a measurement of GPU core occupancy.
        return GPUActivitySample(
            timestamp: instant.date, activityPercent: activity, processIDs: measuredProcessIDs)
    }
}

struct GPUActivityInstant: Sendable {
    let uptime: TimeInterval
    let date: Date
}

struct GPURegistrySnapshot: Sendable {
    let acceleratorCount: Int
    let clients: [GPURegistryClient]
    var unreadableProcessIDs: Set<Int32> = []
}

struct GPURegistryQueue: Sendable, Equatable {
    let api: String
    let accumulatedNanoseconds: UInt64
    let lastSubmittedTime: UInt64
}

struct GPURegistryClient: Sendable {
    let registryID: UInt64
    let processID: Int32
    let queues: [GPURegistryQueue]

    func nanoseconds(since old: GPURegistryClient) -> Double? {
        // AppUsage supplies no persistent queue identifier. Changing topology,
        // order, or a counter reset invalidates this client's interval. A
        // same-count replacement with larger counters cannot be detected using
        // these undocumented fields; do not claim hardware-capacity accuracy.
        guard queues.count == old.queues.count else { return nil }
        var total = 0.0
        for (current, previous) in zip(queues, old.queues) {
            guard current.api == previous.api,
                current.accumulatedNanoseconds >= previous.accumulatedNanoseconds,
                current.lastSubmittedTime >= previous.lastSubmittedTime
            else { return nil }
            total += Double(current.accumulatedNanoseconds - previous.accumulatedNanoseconds)
        }
        return total
    }
}

enum GPURegistryReadError: Error {
    case enumerationFailed
}

enum IOKitGPURegistry {
    // Driver field names cross-checked against this independently implemented
    // reader: https://github.com/longbridge/gpui-kit/blob/7a9ac172e804ce89aebac644a02f09813dc9e793/crates/fps/src/gpu/macos.rs
    // IOKit provides the transport; AppUsage and its time-unit convention are
    // driver details, so absence or an unexpected type means unavailable.
    static func read() throws -> GPURegistrySnapshot {
        guard let matching = IOServiceMatching("IOAccelerator") else {
            throw GPURegistryReadError.enumerationFailed
        }
        var accelerators: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, matching, &accelerators)
                == KERN_SUCCESS, accelerators != 0
        else { throw GPURegistryReadError.enumerationFailed }
        defer { IOObjectRelease(accelerators) }

        var acceleratorCount = 0
        var clients: [GPURegistryClient] = []
        var unreadableProcessIDs: Set<Int32> = []
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            acceleratorCount += 1
            var children: io_iterator_t = 0
            guard
                IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children)
                    == KERN_SUCCESS, children != 0
            else { throw GPURegistryReadError.enumerationFailed }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                // The verified AppUsage source is Apple's AGX device client.
                // Accelerator siblings can have the same creator PID without
                // exposing GPU execution counters; they are not failed reads.
                guard IOObjectConformsTo(child, "AGXDeviceUserClient") != 0 else { continue }
                var identifier: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(child, &identifier) == KERN_SUCCESS else {
                    throw GPURegistryReadError.enumerationFailed
                }
                var properties: Unmanaged<CFMutableDictionary>?
                guard
                    IORegistryEntryCreateCFProperties(child, &properties, kCFAllocatorDefault, 0)
                        == KERN_SUCCESS, let properties
                else { throw GPURegistryReadError.enumerationFailed }
                let dictionary = properties.takeRetainedValue() as NSDictionary
                if let client = parse(registryID: identifier, properties: dictionary) {
                    clients.append(client)
                } else if let owner = ownerPID(properties: dictionary) {
                    // An explicitly empty array means no GPU queues; a CPU-only
                    // server can coexist with a measurable inference worker.
                    if let queues = dictionary["AppUsage"] as? [Any], queues.isEmpty { continue }
                    unreadableProcessIDs.insert(owner)
                }
            }
            guard IOIteratorIsValid(children) != 0 else {
                throw GPURegistryReadError.enumerationFailed
            }
        }
        guard IOIteratorIsValid(accelerators) != 0 else {
            throw GPURegistryReadError.enumerationFailed
        }
        return GPURegistrySnapshot(
            acceleratorCount: acceleratorCount, clients: clients,
            unreadableProcessIDs: unreadableProcessIDs)
    }

    static func parse(registryID: UInt64, properties: NSDictionary) -> GPURegistryClient? {
        guard let processID = ownerPID(properties: properties),
            let rawQueues = properties["AppUsage"] as? [Any], !rawQueues.isEmpty
        else { return nil }

        var queues: [GPURegistryQueue] = []
        for rawQueue in rawQueues {
            guard let queue = rawQueue as? [String: Any],
                let api = queue["API"] as? String, !api.isEmpty,
                let time = unsignedInteger(queue["accumulatedGPUTime"]),
                let lastSubmitted = unsignedInteger(queue["lastSubmittedTime"])
            else { return nil }
            queues.append(
                GPURegistryQueue(
                    api: api, accumulatedNanoseconds: time, lastSubmittedTime: lastSubmitted))
        }
        return GPURegistryClient(registryID: registryID, processID: processID, queues: queues)
    }

    private static func ownerPID(properties: NSDictionary) -> Int32? {
        guard let creator = properties["IOUserClientCreator"] as? String,
            creator.hasPrefix("pid "), let comma = creator.firstIndex(of: ","),
            let processID = Int32(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma]),
            processID > 0
        else { return nil }
        return processID
    }

    private static func unsignedInteger(_ raw: Any?) -> UInt64? {
        guard let number = raw as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            !["f", "d"].contains(String(cString: number.objCType))
        else { return nil }
        return UInt64(number.stringValue)
    }
}
