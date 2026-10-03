import Foundation

/// Resolve the held scales before projecting a publication. This reference is
/// view-owned but deliberately not observable: repeated body, hover, and drawing
/// reads reuse one immutable result without scheduling another SwiftUI update.
@MainActor
final class LuminousChartScaleCache {
    struct Key: Equatable {
        let publicationID: UUID
        let now: Date
        let duration: TimeInterval
        let isLive: Bool
        let tokenPeak: Double
        let toolPeak: Double

        init(
            publicationID: UUID, now: Date, duration: TimeInterval, isLive: Bool,
            tokenPeak: Double?, toolPeak: Double?
        ) {
            self.publicationID = publicationID
            self.now = now
            self.duration = duration
            self.isLive = isLive
            // ChartScaleState treats unavailable, nonfinite and nonpositive
            // peaks identically. Canonical keys also make NaN reads reusable.
            self.tokenPeak = Self.validPeak(tokenPeak)
            self.toolPeak = Self.validPeak(toolPeak)
        }

        private static func validPeak(_ peak: Double?) -> Double {
            guard let peak, peak.isFinite, peak > 0 else { return 0 }
            return peak
        }
    }

    struct Scales: Equatable {
        let tokenUpperBound: Double
        let toolUpperBound: Double
    }

    private var key: Key?
    private var token = ChartScaleState()
    private var tool = ChartScaleState()
    private var retained = Scales(tokenUpperBound: 1, toolUpperBound: 1)

    func resolve(_ key: Key) -> Scales {
        if self.key == key {
            PerformanceGraphicsDiagnostics.shared.recordAtomicChartScaleCacheHit()
            return retained
        }
        // A selected historical window fits its own data immediately. Live
        // windows keep the existing immediate growth and eight-second shrink.
        if !key.isLive {
            token = ChartScaleState()
            tool = ChartScaleState()
        }
        token.update(peak: key.tokenPeak, now: key.now)
        tool.update(peak: key.toolPeak, now: key.now)
        self.key = key
        let resolved = Scales(tokenUpperBound: token.upperBound, toolUpperBound: tool.upperBound)
        PerformanceGraphicsDiagnostics.shared.recordAtomicChartScaleResolution(
            changed: resolved != retained)
        retained = resolved
        return retained
    }
}
