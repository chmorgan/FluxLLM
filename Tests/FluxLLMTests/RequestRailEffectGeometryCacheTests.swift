import CoreGraphics
import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class RequestRailEffectGeometryCacheTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let rect = CGRect(x: 13.375, y: 22.125, width: 173.75, height: 7)

    func testCachedLightningMatchesUnchangedFrameAtEveryCrackleBoundaryAndPhase() throws {
        let cache = RequestRailEffectGeometryCache(recordsDiagnostics: false)
        let key = key(1)
        cache.retain([key], duration: 60)
        let rectangles = [
            CGRect(x: 0, y: 0, width: 0.1, height: 7),
            CGRect(x: -3.375, y: 1.125, width: 2, height: 7),
            CGRect(x: 13.375, y: 22.125, width: 7, height: 7),
            CGRect(x: -50.625, y: 81.875, width: 159.75, height: 7),
            CGRect(x: 0.125, y: -9.375, width: 850.25, height: 11.5),
            CGRect(x: -100, y: -40, width: 10_000, height: 7),
        ]
        var directions: Set<Double> = []
        for seed in UInt64(0)..<6 {
            for duration in [0.0, 8, 80] {
                let profile = RequestRailEffectProfile(
                    seed: seed, requestDuration: duration, completion: true)
                directions.insert(profile.direction)
                var ages = [
                    -1, 0, profile.surgeDelay, profile.surgeDelay.nextDown,
                    profile.surgeDelay.nextUp,
                    profile.surgeDelay + 0.05,
                    profile.surgeDelay + profile.surgeDuration,
                    profile.surgeDelay + profile.surgeDuration + 0.15,
                    (profile.surgeDelay + profile.surgeDuration + 0.15).nextDown,
                    (profile.surgeDelay + profile.surgeDuration + 0.15).nextUp,
                    profile.visibleDuration, profile.visibleDuration + 1,
                ]
                for crackle in profile.crackles where crackle.at <= profile.surgeDuration {
                    let age = profile.surgeDelay + crackle.at
                    ages += [age.nextDown, age, age.nextUp, age + 0.018]
                }
                ages += (0...24).map {
                    profile.surgeDelay + Double($0) / 24 * (profile.surgeDuration + 0.15)
                }
                for rect in rectangles {
                    let geometry = try XCTUnwrap(
                        cache.geometry(key: key, profile: profile, rect: rect))
                    for age in ages {
                        assertBitExact(
                            geometry.lightningFrame(profile: profile, age: age),
                            profile.lightningFrame(age: age, rect: rect),
                            "seed=\(seed), duration=\(duration), rect=\(rect), age=\(age)")
                    }
                }
            }
        }
        XCTAssertEqual(directions, [-1, 1])
    }

    func testParticlePositionsSparkEndpointsAndStarTransformsAreExact() throws {
        let cache = RequestRailEffectGeometryCache(recordsDiagnostics: false)
        let key = key(2, completion: false)
        cache.retain([key], duration: 60)
        let points = [
            CGPoint.zero, CGPoint(x: -18.375, y: 55.625), CGPoint(x: 9_837.25, y: -4.125),
        ]
        var families: Set<String> = []
        for seed in UInt64(0)..<24 {
            let profile = RequestRailEffectProfile(
                seed: seed, requestDuration: 5, completion: false)
            families.insert(String(describing: profile.family))
            let geometry = try XCTUnwrap(cache.geometry(key: key, profile: profile, rect: rect))
            XCTAssertEqual(geometry.particleDirections.count, profile.particles.count)
            XCTAssertEqual(geometry.starRotation, CGAffineTransform(rotationAngle: profile.angle))
            for (index, particle) in profile.particles.enumerated() {
                let direction = geometry.particleDirections[index]
                // The original renderer computes cos/sin together in one
                // CGPoint expression. Release pairs these through sincos;
                // a standalone libm sin can differ by one ULP. Compare the
                // actual original vector, without weakening bit equality.
                assertPointBits(
                    CGPoint(x: direction.cosine, y: direction.sine),
                    originalParticleDirection(particle.angle))
                for p in [0.0, 0.025, 0.25, 0.7, 0.94, 1] {
                    let q = RequestRailEffectProfile.clamp((p - particle.delay) / particle.life)
                    let travel = 1 - pow(1 - q, 2)
                    for scale in [0.5, 1, 1.12] {
                        let size = profile.size * scale
                        let distance = (4 + particle.distance * travel) * size
                        let length = particle.length * (1 - 0.5 * q)
                        for point in points {
                            let position = CGPoint(
                                x: point.x + direction.cosine * distance,
                                y: point.y + direction.sine * distance)
                            let reference = CGPoint(
                                x: point.x + cos(particle.angle) * distance,
                                y: point.y + sin(particle.angle) * distance)
                            assertPointBits(position, reference)
                            assertPointBits(
                                CGPoint(
                                    x: position.x + direction.cosine * length,
                                    y: position.y + direction.sine * length),
                                CGPoint(
                                    x: reference.x + cos(particle.angle) * length,
                                    y: reference.y + sin(particle.angle) * length))
                            let translation = CGAffineTransform(translationX: point.x, y: point.y)
                            XCTAssertEqual(
                                geometry.starRotation.concatenating(translation),
                                CGAffineTransform(rotationAngle: profile.angle).concatenating(
                                    translation))
                        }
                    }
                }
            }
        }
        XCTAssertEqual(families, ["fireflies", "sparks", "arcs"])
    }

    func testRepeatedFramesReuseOneEntryAndRectangleReplacementDoesNotAccumulate() throws {
        let cache = RequestRailEffectGeometryCache(recordsDiagnostics: false)
        let key = key(3)
        let profile = profile()
        cache.retain([key], duration: 60)
        let first = try XCTUnwrap(cache.geometry(key: key, profile: profile, rect: rect))
        for _ in 0..<100 {
            XCTAssertTrue(
                try XCTUnwrap(cache.geometry(key: key, profile: profile, rect: rect)) === first)
        }
        XCTAssertEqual(
            cache.statistics, .init(builds: 1, hits: 100, currentEntries: 1, peakEntries: 1))
        for replacement in [
            rect.offsetBy(dx: 0.125, dy: 0), rect.offsetBy(dx: 0, dy: 0.125),
            CGRect(x: rect.minX, y: rect.minY, width: rect.width.nextUp, height: rect.height),
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height.nextUp),
        ] {
            let next = try XCTUnwrap(cache.geometry(key: key, profile: profile, rect: replacement))
            XCTAssertFalse(next === first)
            XCTAssertEqual(cache.statistics.currentEntries, 1)
            XCTAssertEqual(cache.statistics.peakEntries, 1)
            XCTAssertEqual(next.rect, replacement)
        }
        XCTAssertEqual(cache.statistics.builds, 5)
    }

    func testProfileSeedAndDurationInvalidateEvenWhenCappedVisibleParametersAreEqual() throws {
        let cache = RequestRailEffectGeometryCache(recordsDiagnostics: false)
        let key = key(4)
        cache.retain([key], duration: 60)
        let capped = profile(duration: 1_000)
        let alsoCapped = profile(duration: 2_000)
        XCTAssertEqual(capped, alsoCapped, "Normal visible profile equality remains unchanged")
        XCTAssertNotEqual(capped.geometryIdentity, alsoCapped.geometryIdentity)
        let first = try XCTUnwrap(cache.geometry(key: key, profile: capped, rect: rect))
        let next = try XCTUnwrap(cache.geometry(key: key, profile: alsoCapped, rect: rect))
        XCTAssertFalse(first === next)
        XCTAssertFalse(
            try XCTUnwrap(cache.geometry(key: key, profile: profile(seed: 9), rect: rect)) === next)
        XCTAssertEqual(cache.statistics.builds, 3)
        XCTAssertEqual(cache.statistics.currentEntries, 1)
    }

    func testInvalidDurationsShareOriginalNormalizationAndArrivalHasNoLightning() throws {
        let cache = RequestRailEffectGeometryCache(recordsDiagnostics: false)
        let key = key(5, completion: false)
        cache.retain([key], duration: 60)
        let zero = profile(duration: 0, completion: false)
        let first = try XCTUnwrap(cache.geometry(key: key, profile: zero, rect: rect))
        for duration in [Double.nan, .infinity, -.infinity, -5, -0.0] {
            let candidate = profile(duration: duration, completion: false)
            XCTAssertEqual(candidate, zero)
            XCTAssertEqual(candidate.geometryIdentity, zero.geometryIdentity)
            let geometry = try XCTUnwrap(cache.geometry(key: key, profile: candidate, rect: rect))
            XCTAssertTrue(geometry === first)
            for age in [-1.0, 0, 0.1, 1, 10] {
                XCTAssertNil(geometry.lightningFrame(profile: candidate, age: age))
                XCTAssertNil(candidate.lightningFrame(age: age, rect: rect))
            }
        }
        XCTAssertEqual(cache.statistics.builds, 1)
        XCTAssertEqual(cache.statistics.hits, 5)
    }

    func testBoundedEntriesEvictOldestReceiptWithoutChangingTheFrame() throws {
        let cache = RequestRailEffectGeometryCache(recordsDiagnostics: false)
        let keys = (0..<40).map { key($0 + 10) }
        cache.retain(Set(keys), duration: 60)
        let profile = profile()
        for key in keys {
            _ = try XCTUnwrap(cache.geometry(key: key, profile: profile, rect: rect))
        }
        XCTAssertEqual(RequestRailEffectGeometryCache.maximumEntries, 24)
        XCTAssertEqual(
            cache.statistics, .init(builds: 40, hits: 0, currentEntries: 24, peakEntries: 24))
        let newest = try XCTUnwrap(cache.geometry(key: keys[39], profile: profile, rect: rect))
        let evicted = try XCTUnwrap(cache.geometry(key: keys[0], profile: profile, rect: rect))
        XCTAssertFalse(newest === evicted)
        XCTAssertEqual(cache.statistics.builds, 41)
        XCTAssertEqual(cache.statistics.hits, 1)
        XCTAssertEqual(cache.statistics.currentEntries, 24)
        assertBitExact(
            evicted.lightningFrame(profile: profile, age: 0.6),
            profile.lightningFrame(age: 0.6, rect: rect))
    }

    func testExpirationPruningAndDurationChangeReleaseObsoleteEntries() throws {
        let cache = RequestRailEffectGeometryCache(recordsDiagnostics: false)
        let firstKey = key(6)
        let secondKey = key(7)
        cache.retain([firstKey, secondKey], duration: 60)
        let profile = profile()
        let first = try XCTUnwrap(cache.geometry(key: firstKey, profile: profile, rect: rect))
        _ = try XCTUnwrap(cache.geometry(key: secondKey, profile: profile, rect: rect))
        cache.retain([firstKey], duration: 60)
        XCTAssertEqual(cache.statistics.currentEntries, 1)
        XCTAssertNil(
            cache.geometry(key: secondKey, profile: profile, rect: rect),
            "Expired captured draw cannot recreate its entry")
        XCTAssertTrue(
            try XCTUnwrap(cache.geometry(key: firstKey, profile: profile, rect: rect)) === first)
        cache.retain([firstKey], duration: 300)
        XCTAssertEqual(cache.statistics.currentEntries, 0)
        XCTAssertFalse(
            try XCTUnwrap(cache.geometry(key: firstKey, profile: profile, rect: rect)) === first)
        cache.retain([], duration: 300)
        XCTAssertEqual(cache.statistics.currentEntries, 0)
        XCTAssertNil(cache.geometry(key: firstKey, profile: profile, rect: rect))
    }

    func testHiddenClosedAndInitiallyInactiveCachesRejectLateDrawCallbacks() throws {
        let cache = RequestRailEffectGeometryCache(recordsDiagnostics: false)
        let key = key(8)
        let profile = profile()
        XCTAssertNil(cache.geometry(key: key, profile: profile, rect: rect))
        XCTAssertEqual(cache.statistics.builds, 0)
        cache.retain([key], duration: 60)
        weak var retained: RequestRailEffectGeometryCache.Geometry? = try XCTUnwrap(
            cache.geometry(key: key, profile: profile, rect: rect))
        XCTAssertNotNil(retained)
        cache.removeAll()
        XCTAssertNil(retained, "The owner drops geometry storage on hide/close")
        XCTAssertNil(
            cache.geometry(key: key, profile: profile, rect: rect),
            "A late captured closure cannot recreate storage")
        XCTAssertEqual(cache.statistics.currentEntries, 0)
        XCTAssertEqual(cache.statistics.builds, 1)
        cache.retain([key], duration: 60)
        XCTAssertNotNil(
            cache.geometry(key: key, profile: profile, rect: rect), "Reopening permits a fresh draw"
        )
        XCTAssertEqual(cache.statistics.builds, 2)
    }

    func testDegenerateAndNonfiniteRectanglesKeepOriginalFrameEligibility() throws {
        let cache = RequestRailEffectGeometryCache(recordsDiagnostics: false)
        let key = key(9)
        let profile = profile()
        cache.retain([key], duration: 60)
        for rect in [
            CGRect.zero, CGRect(x: 5, y: 7, width: 0, height: 7),
            CGRect(x: 5, y: 7, width: 10, height: 0),
            CGRect(x: 5, y: 7, width: -10, height: 7),
            CGRect(x: CGFloat.infinity, y: 7, width: 10, height: 7),
            CGRect(x: 5, y: 7, width: CGFloat.infinity, height: 7),
        ] {
            let geometry = try XCTUnwrap(cache.geometry(key: key, profile: profile, rect: rect))
            for age in [0.0, 0.1, 0.5, 1, 3] {
                assertBitExact(
                    geometry.lightningFrame(profile: profile, age: age),
                    profile.lightningFrame(age: age, rect: rect))
            }
        }
    }

    private func key(_ index: Int, completion: Bool = true) -> RequestRailLifecycleEffects.Key {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index))!
        return RequestRailLifecycleEffects.Key(
            RequestRailEvent(
                requestID: id, kind: completion ? .completion : .arrival,
                startedAt: origin, seed: UInt64(index)))
    }

    private func profile(seed: UInt64 = 3, duration: TimeInterval = 8, completion: Bool = true)
        -> RequestRailEffectProfile
    {
        RequestRailEffectProfile(seed: seed, requestDuration: duration, completion: completion)
    }

    private func assertBitExact(
        _ actual: RequestRailEffectProfile.LightningFrame?,
        _ expected: RequestRailEffectProfile.LightningFrame?, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, message, file: file, line: line)
        guard let actual, let expected else { return }
        XCTAssertEqual(
            actual.brightness.bitPattern, expected.brightness.bitPattern, message, file: file,
            line: line)
        XCTAssertEqual(
            actual.recharge.bitPattern, expected.recharge.bitPattern, message, file: file,
            line: line)
        assertPointBits(actual.head, expected.head, file: file, line: line)
        for (a, b) in zip(actual.points, expected.points) {
            assertPointBits(a, b, file: file, line: line)
        }
        for (a, b) in zip(actual.forks, expected.forks) {
            XCTAssertEqual(
                a.energy.bitPattern, b.energy.bitPattern, message, file: file, line: line)
            for (a, b) in zip(a.points, b.points) { assertPointBits(a, b, file: file, line: line) }
        }
    }

    private func assertPointBits(
        _ actual: CGPoint, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            Double(actual.x).bitPattern, Double(expected.x).bitPattern, file: file, line: line)
        XCTAssertEqual(
            Double(actual.y).bitPattern, Double(expected.y).bitPattern, file: file, line: line)
    }

    @inline(never)
    private func originalParticleDirection(_ angle: Double) -> CGPoint {
        CGPoint(x: cos(angle), y: sin(angle))
    }
}
