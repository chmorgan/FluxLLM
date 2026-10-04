import CoreGraphics
import Foundation

/// An immutable receipt profile and an exact bar rectangle determine the
/// expensive, age-independent part of an effect. This cache belongs to the
/// decoration view and never publishes an observation change of its own.
@MainActor
final class RequestRailEffectGeometryCache {
    static let maximumEntries = 24

    struct Statistics: Equatable {
        var builds = 0
        var hits = 0
        var currentEntries = 0
        var peakEntries = 0
    }

    struct ParticleDirection: Equatable {
        let cosine: Double
        let sine: Double
    }

    struct OffsetBasis {
        let point: CGPoint
        // Keep the original subtraction and division order. Using a signed
        // normal followed by addition would change some floating-point bits.
        let dyOverLength: Double
        let dxOverLength: Double

        func offsetPoint(_ offset: Double) -> CGPoint {
            CGPoint(
                x: point.x + dyOverLength * offset,
                y: point.y - dxOverLength * offset)
        }
    }

    struct Knot {
        let position: Double
        let basis: OffsetBasis
        let fullReach: Double
        let fullForkPoints: [CGPoint]
    }

    final class Geometry {
        let identity: RequestRailEffectProfile.GeometryIdentity
        let rect: CGRect
        let particleDirections: [ParticleDirection]
        let starRotation: CGAffineTransform
        let route: RequestRailPerimeter
        let knots: [Knot]

        fileprivate init(profile: RequestRailEffectProfile, rect: CGRect) {
            identity = profile.geometryIdentity
            self.rect = rect
            particleDirections = profile.particles.map {
                ParticleDirection(cosine: cos($0.angle), sine: sin($0.angle))
            }
            starRotation = CGAffineTransform(rotationAngle: profile.angle)
            let route = RequestRailPerimeter(rect: profile.completion ? rect : .zero)
            self.route = route
            guard profile.completion, rect.width > 0, rect.height > 0 else {
                knots = []
                return
            }
            let count = max(8, min(240, Int(ceil(route.length / 6.5))))
            let total = profile.channel.prefix(count).reduce(0) { $0 + $1.weight }
            var sum = 0.0
            var result: [Knot] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                let item = profile.channel[index]
                sum += item.weight
                let position = Double(route.length) * sum / total
                let fullReach = min(item.reach, Double(route.length) * 0.16)
                func offsetPoint(_ position: Double, _ offset: Double) -> CGPoint {
                    Self.basis(route: route, direction: profile.direction, position: position)
                        .offsetPoint(offset)
                }
                result.append(
                    Knot(
                        position: position,
                        basis: Self.basis(
                            route: route, direction: profile.direction, position: position),
                        fullReach: fullReach,
                        fullForkPoints: [
                            offsetPoint(
                                position + fullReach * 0.3, -item.depth * 0.42 + item.kink * 0.5),
                            offsetPoint(
                                position + fullReach * 0.63, -item.depth * 0.76 - item.kink * 0.3),
                            offsetPoint(position + fullReach, -item.depth),
                        ]))
            }
            knots = result
        }

        private static func basis(
            route: RequestRailPerimeter, direction: Double, position: Double
        ) -> OffsetBasis {
            let d = direction * position
            let point = route.point(at: d)
            let before = route.point(at: d - 0.12)
            let after = route.point(at: d + 0.12)
            let dx = after.x - before.x
            let dy = after.y - before.y
            let length = max(0.0001, hypot(dx, dy))
            return OffsetBasis(point: point, dyOverLength: dy / length, dxOverLength: dx / length)
        }

        /// The original frame calculation with only invariant geometry reads
        /// replaced. Crackle interpolation, clipping, energies and lifetimes
        /// remain age-dependent and preserve the original arithmetic order.
        func lightningFrame(
            profile: RequestRailEffectProfile, age: TimeInterval
        ) -> RequestRailEffectProfile.LightningFrame? {
            let age = age - profile.surgeDelay
            guard profile.completion, age > 0, age < profile.surgeDuration + 0.15,
                rect.width > 0, rect.height > 0
            else { return nil }
            let p = RequestRailEffectProfile.clamp(age / profile.surgeDuration)
            let progress = p + profile.bend * sin(2 * .pi * p)
            let settle = RequestRailEffectProfile.smooth((age - profile.surgeDuration) / 0.15)
            let strength = min(1, age / 0.05) * (1 - settle)
            let distance = Double(route.length) * progress
            let tail =
                min(96, Double(route.length) * (0.31 + profile.trail), distance) * (1 - settle)
            let sampleTime = min(age, profile.surgeDuration)
            let index = profile.crackles.lastIndex { $0.at <= sampleTime } ?? 0
            let current = profile.crackles[index]
            let previous = profile.crackles[max(0, index - 1)]
            let blend = RequestRailEffectProfile.smooth((sampleTime - current.at) / 0.018)
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * blend }
            let recharge = profile.flashAt.map { exp(-pow((p - $0) / 0.036, 2)) }.max() ?? 0
            let brightness = strength * (0.7 + 0.3 * mix(previous.brightness, current.brightness))

            func offsetPoint(_ position: Double, _ offset: Double) -> CGPoint {
                Self.basis(route: route, direction: profile.direction, position: position)
                    .offsetPoint(offset)
            }
            var points = [offsetPoint(distance - tail, 0)]
            var forks: [RequestRailEffectProfile.Fork] = []
            for index in knots.indices {
                let geometry = knots[index]
                let position = geometry.position
                guard position > distance - tail, position < distance else { continue }
                let item = profile.channel[index]
                let offset =
                    (item.offset * 0.3 + mix(previous.offsets[index], current.offsets[index]) * 0.7)
                    * (1 - settle)
                let knot = geometry.basis.offsetPoint(offset)
                points.append(knot)
                let charge = mix(previous.forks[index], current.forks[index])
                let energy = RequestRailEffectProfile.clamp((charge - 0.46) / 0.54)
                guard energy > 0, distance - position >= 2 else { continue }
                let reach = min(item.reach, Double(route.length) * 0.16, distance - position)
                let forkPoints: [CGPoint]
                if reach == geometry.fullReach {
                    forkPoints = [knot] + geometry.fullForkPoints
                } else {
                    forkPoints = [
                        knot,
                        offsetPoint(position + reach * 0.3, -item.depth * 0.42 + item.kink * 0.5),
                        offsetPoint(position + reach * 0.63, -item.depth * 0.76 - item.kink * 0.3),
                        offsetPoint(position + reach, -item.depth),
                    ]
                }
                forks.append(RequestRailEffectProfile.Fork(points: forkPoints, energy: energy))
            }
            let head = route.point(at: profile.direction * distance)
            points.append(head)
            return RequestRailEffectProfile.LightningFrame(
                points: points, forks: forks, head: head, brightness: brightness, recharge: recharge
            )
        }
    }

    private struct Entry {
        let key: RequestRailLifecycleEffects.Key
        let geometry: Geometry
    }

    private let recordsDiagnostics: Bool
    private let diagnosticsOwner = UUID()
    private var entries: [Entry] = []
    private var allowedKeys: Set<RequestRailLifecycleEffects.Key> = []
    private var isActive = false
    private var duration: TimeInterval?
    private(set) var statistics = Statistics()

    init(recordsDiagnostics: Bool = true) {
        self.recordsDiagnostics = recordsDiagnostics
    }

    func geometry(
        key: RequestRailLifecycleEffects.Key, profile: RequestRailEffectProfile, rect: CGRect
    ) -> Geometry? {
        // A Canvas can retain its old closure until the next presentation.
        // Clearing the view's cache must also prevent that callback from
        // recreating entries after a window hides or an effect expires.
        guard isActive, allowedKeys.contains(key) else { return nil }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let existing = entries.remove(at: index)
            if existing.geometry.identity == profile.geometryIdentity,
                existing.geometry.rect == rect
            {
                entries.append(existing)
                statistics.hits += 1
                if recordsDiagnostics {
                    PerformanceGraphicsDiagnostics.shared.recordRailGeometryCacheHit(
                        owner: diagnosticsOwner)
                }
                return existing.geometry
            }
        }
        let geometry = Geometry(profile: profile, rect: rect)
        if entries.count == Self.maximumEntries { entries.removeFirst() }
        entries.append(Entry(key: key, geometry: geometry))
        statistics.builds += 1
        statistics.currentEntries = entries.count
        statistics.peakEntries = max(statistics.peakEntries, entries.count)
        if recordsDiagnostics {
            PerformanceGraphicsDiagnostics.shared.recordRailGeometryCacheBuild(
                owner: diagnosticsOwner, entries: entries.count)
        }
        return geometry
    }

    /// A publication can change the selected duration or remove receipts. It
    /// never leaves obsolete rectangles or finished effect profiles retained.
    func retain(_ keys: Set<RequestRailLifecycleEffects.Key>, duration: TimeInterval) {
        isActive = true
        allowedKeys = keys
        if let previous = self.duration, previous != duration {
            entries.removeAll(keepingCapacity: false)
        }
        self.duration = duration
        entries.removeAll { !keys.contains($0.key) }
        updateCurrentEntries()
    }

    func removeAll() {
        isActive = false
        allowedKeys.removeAll(keepingCapacity: false)
        entries.removeAll(keepingCapacity: false)
        duration = nil
        updateCurrentEntries()
    }

    private func updateCurrentEntries() {
        statistics.currentEntries = entries.count
        if recordsDiagnostics {
            PerformanceGraphicsDiagnostics.shared.recordRailGeometryCacheEntries(
                owner: diagnosticsOwner, entries.count)
        }
    }
}
