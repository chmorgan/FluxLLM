import Foundation
import IOKit

/// Reads this Mac's whole-device GPU utilization, including work from other apps.
/// Multiple devices contribute equally: summed utilization divided by summed
/// available percentage (100 per unique GPU). This is an average of normalized
/// utilization, without weighting devices by their computing power.
public actor SystemGPUMonitor: BackendGPUMonitoring {
    typealias RegistryReader = @Sendable () throws -> SystemGPURegistrySnapshot
    typealias SampleClock = @Sendable () -> Date

    private let reader: RegistryReader
    private let clock: SampleClock

    public init() {
        reader = IOKitSystemGPURegistry.read
        clock = { Date() }
    }

    init(reader: @escaping RegistryReader, clock: @escaping SampleClock = { Date() }) {
        self.reader = reader
        self.clock = clock
    }

    public func reset() async {}

    public func sample(_ configuration: BackendConfiguration?) async -> GPUActivitySample {
        // Backend selection deliberately does not affect this Mac's GPU reading.
        // In particular, this never attributes local GPU use to a remote server.
        let timestamp = clock()
        let source = "macOS system GPU utilization"
        func unavailable(_ reason: String) -> GPUActivitySample {
            GPUActivitySample(
                timestamp: timestamp, source: source, unavailableReason: reason, scope: .system)
        }

        let snapshot: SystemGPURegistrySnapshot
        do {
            snapshot = try reader()
        } catch {
            return unavailable("macOS system GPU counters could not be read.")
        }
        guard !snapshot.devices.isEmpty else {
            return unavailable("This Mac does not expose system GPU utilization counters.")
        }

        var devices: [UInt64: Double] = [:]
        for device in snapshot.devices {
            guard let utilization = device.utilizationPercent,
                utilization.isFinite, (0...100).contains(utilization)
            else {
                // A partial reading must not silently become the complete
                // system value or change the number of available GPUs.
                return unavailable("This Mac has no complete system GPU utilization reading.")
            }
            if let previous = devices[device.registryID], previous != utilization {
                return unavailable("macOS returned inconsistent system GPU utilization counters.")
            }
            // Registry aliases must not inflate the device count.
            devices[device.registryID] = utilization
        }
        guard !devices.isEmpty else {
            return unavailable("This Mac does not expose system GPU utilization counters.")
        }
        let utilization = devices.values.reduce(0, +) / Double(devices.count)
        let deviceSource =
            devices.count > 1 ? "\(source) (average across \(devices.count) GPUs)" : source
        return GPUActivitySample(
            timestamp: timestamp, activityPercent: utilization, source: deviceSource, scope: .system
        )
    }
}

struct SystemGPURegistryDevice: Sendable, Equatable {
    let registryID: UInt64
    let utilizationPercent: Double?
}

struct SystemGPURegistrySnapshot: Sendable {
    let devices: [SystemGPURegistryDevice]
}

enum SystemGPURegistryReadError: Error {
    case enumerationFailed
    case propertiesUnavailable
}

enum IOKitSystemGPURegistry {
    // IOKit is public and needs no privileged helper, but PerformanceStatistics
    // and Device Utilization % are driver-specific fields, not a stable API.
    // Missing or changed fields therefore mean unavailable, never measured zero.
    static func read() throws -> SystemGPURegistrySnapshot {
        guard let matching = IOServiceMatching("IOAccelerator") else {
            throw SystemGPURegistryReadError.enumerationFailed
        }
        var accelerators: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &accelerators)
        guard result == KERN_SUCCESS, accelerators != 0 else {
            if accelerators != 0 { IOObjectRelease(accelerators) }
            throw SystemGPURegistryReadError.enumerationFailed
        }
        defer { IOObjectRelease(accelerators) }

        var devices: [SystemGPURegistryDevice] = []
        var seenRegistryIDs: Set<UInt64> = []
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(accelerator, &registryID) == KERN_SUCCESS else {
                throw SystemGPURegistryReadError.enumerationFailed
            }
            guard seenRegistryIDs.insert(registryID).inserted else { continue }
            var properties: Unmanaged<CFMutableDictionary>?
            let propertyResult = IORegistryEntryCreateCFProperties(
                accelerator, &properties, kCFAllocatorDefault, 0)
            guard propertyResult == KERN_SUCCESS, let properties else {
                if let properties { _ = properties.takeRetainedValue() }
                throw SystemGPURegistryReadError.propertiesUnavailable
            }
            let dictionary = properties.takeRetainedValue() as NSDictionary
            devices.append(
                SystemGPURegistryDevice(
                    registryID: registryID,
                    utilizationPercent: utilizationPercent(properties: dictionary)))
        }
        guard IOIteratorIsValid(accelerators) != 0 else {
            throw SystemGPURegistryReadError.enumerationFailed
        }
        return SystemGPURegistrySnapshot(devices: devices)
    }

    static func utilizationPercent(properties: NSDictionary) -> Double? {
        guard let statistics = properties["PerformanceStatistics"] as? NSDictionary,
            let number = statistics["Device Utilization %"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let utilization = number.doubleValue
        guard utilization.isFinite, (0...100).contains(utilization) else { return nil }
        return utilization
    }
}
