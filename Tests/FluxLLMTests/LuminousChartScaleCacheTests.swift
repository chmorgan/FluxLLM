import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class LuminousChartScaleCacheTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let publication = UUID()

    func testLiveScalesMatchExistingGrowthAndEightSecondShrink() {
        let cache = LuminousChartScaleCache()
        var token = ChartScaleState()
        var tool = ChartScaleState()
        let steps: [(Double, Double, Double)] = [
            (0, 80, 40), (1, 10, 2), (8, 10, 2), (9, 10, 2),
            (10, 190, 100), (11, 0, 0), (18.999, 0, 0), (19, 0, 0),
        ]
        for (time, tokenPeak, toolPeak) in steps {
            token.update(peak: tokenPeak, now: date(time))
            tool.update(peak: toolPeak, now: date(time))
            let actual = cache.resolve(key(time: time, token: tokenPeak, tool: toolPeak))
            XCTAssertEqual(actual.tokenUpperBound, token.upperBound)
            XCTAssertEqual(actual.toolUpperBound, tool.upperBound)
        }
    }

    func testBurstCancelsPendingShrinkAndRepeatedReadsDoNotAdvanceTheClock() {
        let cache = LuminousChartScaleCache()
        XCTAssertEqual(cache.resolve(key(token: 80)).tokenUpperBound, 100)
        let pending = key(time: 1, token: 10)
        for _ in 0..<100 {
            XCTAssertEqual(cache.resolve(pending).tokenUpperBound, 100)
        }
        XCTAssertEqual(cache.resolve(key(time: 7, token: 80)).tokenUpperBound, 100)
        XCTAssertEqual(cache.resolve(key(time: 9, token: 10)).tokenUpperBound, 100)
        XCTAssertEqual(cache.resolve(key(time: 16, token: 10)).tokenUpperBound, 100)
        XCTAssertEqual(cache.resolve(key(time: 17, token: 10)).tokenUpperBound, 20)
    }

    func testHistoricalNavigationFitsEachWindowAndReturningLiveRetainsTheNewRange() {
        let cache = LuminousChartScaleCache()
        XCTAssertEqual(cache.resolve(key(token: 800)).tokenUpperBound, 1_000)
        let historical = key(time: -50, live: false, token: 10, tool: 2)
        let fit = cache.resolve(historical)
        XCTAssertEqual(fit, .init(tokenUpperBound: 20, toolUpperBound: 5))
        XCTAssertEqual(cache.resolve(historical), fit)
        XCTAssertEqual(
            cache.resolve(key(time: -40, duration: 300, live: false, token: 80, tool: 40)),
            .init(tokenUpperBound: 100, toolUpperBound: 50))
        XCTAssertEqual(cache.resolve(key(time: 1, token: 10)).tokenUpperBound, 100)
        XCTAssertEqual(cache.resolve(key(time: 9, token: 10)).tokenUpperBound, 20)
    }

    func testDurationChangePreservesLiveHysteresisAndFitsHistoricalData() {
        let cache = LuminousChartScaleCache()
        _ = cache.resolve(key(token: 80))
        _ = cache.resolve(key(time: 1, token: 10))
        XCTAssertEqual(cache.resolve(key(time: 5, duration: 300, token: 10)).tokenUpperBound, 100)
        XCTAssertEqual(cache.resolve(key(time: 9, duration: 300, token: 10)).tokenUpperBound, 20)
        XCTAssertEqual(
            cache.resolve(key(time: 9, duration: 60, live: false, token: 1)).tokenUpperBound, 2)
    }

    func testPublicationAndPeakChangesResolveBeforeTheFirstFrame() {
        let scales = LuminousChartScaleCache()
        let geometry = LuminousChartGeometryCache()
        _ = scales.resolve(key(token: 80, tool: 2))
        let next = key(publication: UUID(), time: 1, token: 190, tool: 40)
        let first = frame(geometry, key: next, scales: scales.resolve(next))
        XCTAssertEqual(first.key.tokenUpperBound, 500)
        XCTAssertEqual(first.key.toolUpperBound, 50)
        for _ in 0..<20 {
            XCTAssertTrue(frame(geometry, key: next, scales: scales.resolve(next)) === first)
        }
        // Defensive peak fields also invalidate legacy callers that reuse an
        // ID, even though dashboard publications promise immutable histories.
        let changed = key(publication: next.publicationID, time: 1, token: 800, tool: 100)
        let replacement = frame(geometry, key: changed, scales: scales.resolve(changed))
        XCTAssertFalse(replacement === first)
        XCTAssertEqual(replacement.key.tokenUpperBound, 1_000)
        XCTAssertEqual(replacement.key.toolUpperBound, 200)
    }

    func testAtomicScaleEliminatesTheStaleThenCorrectedGeometryFrame() {
        let baselineGeometry = LuminousChartGeometryCache()
        var old = ChartScaleState()
        old.update(peak: 80, now: origin)
        let publication = key(publication: UUID(), time: 1, token: 190)
        let stale = frame(
            baselineGeometry, key: publication,
            scales: .init(tokenUpperBound: old.upperBound, toolUpperBound: 1))
        old.update(peak: 190, now: publication.now)
        let corrected = frame(
            baselineGeometry, key: publication,
            scales: .init(tokenUpperBound: old.upperBound, toolUpperBound: 1))
        XCTAssertFalse(stale === corrected)

        let atomicGeometry = LuminousChartGeometryCache()
        let cache = LuminousChartScaleCache()
        _ = cache.resolve(key(token: 80))
        let atomic = frame(atomicGeometry, key: publication, scales: cache.resolve(publication))
        XCTAssertEqual(atomic.key, corrected.key)
        XCTAssertEqual(atomic.generated.map(\.points), corrected.generated.map(\.points))
        XCTAssertEqual(atomic.generated.map(\.trace), corrected.generated.map(\.trace))
        XCTAssertEqual(atomic.device.map(\.points), corrected.device.map(\.points))
        XCTAssertTrue(
            frame(atomicGeometry, key: publication, scales: cache.resolve(publication)) === atomic)
    }

    func testMissingAndInvalidPeaksShareTheExistingMinimumRange() {
        let cache = LuminousChartScaleCache()
        let unavailable = key(token: nil, tool: nil)
        let minimum = cache.resolve(unavailable)
        XCTAssertEqual(minimum, .init(tokenUpperBound: 1, toolUpperBound: 1))
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0] {
            let equivalent = key(token: invalid, tool: invalid)
            XCTAssertEqual(equivalent, unavailable)
            XCTAssertEqual(cache.resolve(equivalent), minimum)
        }
    }

    func testScaleCacheReleasesWithItsViewOwner() {
        var cache: LuminousChartScaleCache? = LuminousChartScaleCache()
        weak var retained = cache
        _ = cache?.resolve(key(token: 80))
        XCTAssertNotNil(retained)
        cache = nil
        XCTAssertNil(retained)
    }

    private func date(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }

    private func key(
        publication: UUID? = nil, time: Double = 0, duration: TimeInterval = 60,
        live: Bool = true, token: Double? = 0, tool: Double? = 0
    ) -> LuminousChartScaleCache.Key {
        .init(
            publicationID: publication ?? self.publication, now: date(time), duration: duration,
            isLive: live, tokenPeak: token, toolPeak: tool)
    }

    private func frame(
        _ cache: LuminousChartGeometryCache, key: LuminousChartScaleCache.Key,
        scales: LuminousChartScaleCache.Scales
    ) -> LuminousChartGeometryCache.Frame {
        let tokens = history(peak: key.tokenPeak, now: key.now, duration: key.duration)
        let gpu = history(peak: 70, now: key.now, duration: key.duration)
        return cache.frame(
            for: .init(
                publicationID: key.publicationID, now: key.now, duration: key.duration,
                size: CGSize(width: 640, height: 320), compact: false, hasTools: key.toolPeak > 0,
                tokenUpperBound: scales.tokenUpperBound, toolUpperBound: scales.toolUpperBound),
            throughput: tokens, gpu: gpu, requestTools: [:])
    }

    private func history(peak: Double, now: Date, duration: TimeInterval) -> ChartDisplayHistory {
        ChartDisplayHistory(
            samples: [
                .init(timestamp: now.addingTimeInterval(-1), value: peak / 2, isAvailable: true),
                .init(timestamp: now, value: peak, isAvailable: true),
            ], now: now, duration: duration)
    }
}
