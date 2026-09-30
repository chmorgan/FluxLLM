import Darwin
import Foundation

/// The kernel's cumulative GPU execution counter for this process. A successful
/// zero is preserved, but a performance gate must first validate that this OS/
/// GPU actually advances the field during independently timed GPU work.
public struct NativeProcessGPUCounterSnapshot: Sendable {
    public let rawTimeNanoseconds: UInt64
    public let sampledAtMonotonicSeconds: Double

    public init(rawTimeNanoseconds: UInt64, sampledAtMonotonicSeconds: Double) {
        self.rawTimeNanoseconds = rawTimeNanoseconds
        self.sampledAtMonotonicSeconds = sampledAtMonotonicSeconds
    }
}

public enum NativeProcessGPUCounter {
    /// Read-only task_info on mach_task_self_; no task port acquisition, process
    /// discovery, IOKit enumeration, file access, or privileged helper is used.
    public static func read() -> NativeProcessGPUCounterSnapshot? {
        var info = task_power_info_v2_data_t()
        let words = MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(words)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: words) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        var timestamp = timespec()
        guard result == KERN_SUCCESS, count == mach_msg_type_number_t(words),
            clock_gettime(CLOCK_MONOTONIC, &timestamp) == 0
        else { return nil }
        return NativeProcessGPUCounterSnapshot(
            rawTimeNanoseconds: info.gpu_energy.task_gpu_utilisation,
            sampledAtMonotonicSeconds: Double(timestamp.tv_sec) + Double(timestamp.tv_nsec)
                / 1_000_000_000)
    }
}
