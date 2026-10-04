import Foundation

/// The small reproducibility hook used by the production animation scheduler.
/// Synthetic request identities and history construction live in support only.
package enum PerformanceAnimationRandomness {
    package static func policy(deterministic: Bool) -> String {
        deterministic
            ? "fixture-index-and-fixed-twinkle-seed-v1"
            : "fixture-index-and-wall-clock-twinkles"
    }

    package static func initialTwinkleSequence(at timestamp: Date, deterministic: Bool) -> UInt64 {
        if deterministic { return 0x4658_4C4C_4D }
        return UInt64(max(0, timestamp.timeIntervalSinceReferenceDate * 1_000))
    }
}
