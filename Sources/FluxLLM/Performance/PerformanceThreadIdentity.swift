import Darwin

/// Explicit identities for the opt-in external CPU observer. Capturing an ID
/// does not start a timer or add work to the request/streaming path.
enum PerformanceThreadIdentity {
    static func current() throws -> UInt64 {
        var identifier: UInt64 = 0
        guard pthread_threadid_np(nil, &identifier) == 0, identifier > 0 else {
            throw PerformanceSessionError.invalid("Cannot identify the performance thread")
        }
        return identifier
    }
}
