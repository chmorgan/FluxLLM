import AppKit
import SwiftUI

/// Stable request bars and their short-lived decoration layer. The display clock
/// is deliberately local: a lightning frame never prepares chart histories.
struct RequestRailLayer: View {
    let lanes: [RequestLane]
    let presentation: RequestRailPresentation
    let now: Date
    let duration: TimeInterval
    let rect: CGRect
    let isLive: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var windowVisible = false
    @State private var prepared: [PreparedEffect] = []
    @State private var twinkles: [Twinkle] = []
    @State private var animating = false

    private var effectsEnabled: Bool {
        isLive && !reduceMotion && !reduceTransparency && contrast != .increased && windowVisible
    }

    var body: some View {
        let segments = RequestRailGeometry.layout(
            lanes: lanes, assignments: presentation.assignments, now: now,
            duration: duration, rect: rect)
        let overflow = RequestRailGeometry.overflow(
            lanes: lanes, assignments: presentation.assignments, now: now,
            duration: duration, rect: rect)
        let liveIDs = segments.filter(\.isLive).map { $0.lane.id }
        let work = WorkKey(
            events: presentation.events.map(EffectKey.init), liveIDs: liveIDs,
            duration: duration, enabled: effectsEnabled)

        ZStack {
            Canvas { context, _ in
                drawBars(segments, overflow: overflow, in: &context)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { clock in
                Canvas { context, _ in
                    if effectsEnabled {
                        drawDecorations(segments, at: clock.date, in: &context)
                    }
                }
            }
        }
        .background(RequestRailWindowVisibility(isVisible: $windowVisible))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: work) {
            await runDecorations(work: work)
        }
        .onDisappear { animating = false }
    }

    /// Profiles are cached by receipt identity, so a new telemetry snapshot or a
    /// resized chart cannot change an existing bolt's forks or burst family.
    @MainActor
    private func runDecorations(work: WorkKey) async {
        guard work.enabled else {
            animating = false
            twinkles = []
            return
        }
        let cached = Dictionary(uniqueKeysWithValues: prepared.map { ($0.key, $0) })
        prepared = presentation.events.compactMap { event in
            guard event.expiresAt > Date(),
                let lane = lanes.first(where: { $0.id == event.requestID }),
                let assignment = presentation.assignments[lane.id],
                (0..<RequestRailState.individualTrackCount).contains(assignment.track)
            else { return nil }
            let key = EffectKey(event)
            if let existing = cached[key] { return existing }
            return PreparedEffect(
                key: key, startedAt: event.startedAt, expiresAt: event.expiresAt,
                profile: RequestRailEffectProfile(
                    seed: event.seed,
                    requestDuration: (lane.endedAt ?? now).timeIntervalSince(lane.startedAt),
                    completion: event.kind == .completion))
        }
        twinkles.removeAll { $0.endsAt <= Date() || !work.liveIDs.contains($0.requestID) }
        animating = !work.liveIDs.isEmpty || !prepared.isEmpty
        var sequence = UInt64(max(0, Date().timeIntervalSinceReferenceDate * 1_000))

        while !Task.isCancelled {
            let timestamp = Date()
            let hasTail = prepared.contains { $0.expiresAt > timestamp }
            guard !work.liveIDs.isEmpty || hasTail else {
                animating = false
                twinkles = []
                return
            }
            twinkles.removeAll { $0.endsAt <= timestamp }
            if !work.liveIDs.isEmpty {
                // A single scheduler keeps the entire chart to at most two
                // simultaneous glints, even during a dense request burst.
                var random = RequestRailRandom(seed: sequence)
                let index = min(
                    work.liveIDs.count - 1, Int(random.unit() * Double(work.liveIDs.count)))
                let id = work.liveIDs[index]
                var requestRandom = RequestRailRandom(seed: Self.seed(id) ^ sequence)
                let start = max(
                    lanes.first(where: { $0.id == id })?.startedAt ?? timestamp,
                    timestamp.addingTimeInterval(-duration))
                let fraction = 0.08 + requestRandom.unit() * 0.84
                let twinkle = Twinkle(
                    requestID: id, startedAt: timestamp,
                    duration: 0.43 + requestRandom.unit() * 0.16,
                    location: start.addingTimeInterval(
                        timestamp.timeIntervalSince(start) * fraction),
                    size: 2 + requestRandom.unit() * 1.3,
                    angle: requestRandom.unit() * 0.7,
                    star: requestRandom.unit() > 0.45)
                twinkles = Array((twinkles + [twinkle]).suffix(2))
                sequence &+= 1
            }
            do {
                try await Task.sleep(for: .milliseconds(505))
            } catch { return }
        }
    }

    private static func seed(_ id: UUID) -> UInt64 {
        id.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }

    private func color(for lane: RequestLane) -> Color {
        RequestLanePalette.color(
            at: presentation.assignments[lane.id]?.colorIndex ?? 0, scheme: colorScheme)
    }

    private func drawBars(
        _ segments: [RequestRailGeometry.Segment],
        overflow: [RequestRailGeometry.OverflowSegment], in context: inout GraphicsContext
    ) {
        if segments.isEmpty && overflow.isEmpty {
            context.draw(
                Text("No recent requests")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary),
                at: CGPoint(x: rect.minX, y: rect.minY + RequestRailGeometry.trackPitch / 2),
                anchor: .leading)
        }
        for segment in segments {
            let bar = segment.rect
            let shape = Path(roundedRect: bar, cornerRadius: segment.cornerRadius, style: .circular)
            let color = color(for: segment.lane)
            if contrast == .increased || reduceTransparency {
                context.fill(shape, with: .color(color))
            } else {
                context.fill(
                    shape,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: color.opacity(0.42), location: 0),
                            .init(color: color.opacity(segment.isLive ? 1 : 0.83), location: 0.5),
                            .init(color: color.opacity(segment.isLive ? 1 : 0.88), location: 1),
                        ]),
                        startPoint: CGPoint(x: bar.minX, y: bar.midY),
                        endPoint: CGPoint(x: bar.maxX, y: bar.midY)))
            }
            if segment.isLive {
                var head = context
                head.clip(to: shape)
                let point = CGPoint(x: bar.maxX - segment.cornerRadius, y: bar.midY)
                head.fill(circle(at: point, radius: 3.5), with: .color(color))
                head.fill(circle(at: point, radius: 1.2), with: .color(.white))
            }
        }
        for segment in overflow {
            context.fill(
                Path(
                    roundedRect: segment.rect, cornerRadius: min(3.5, segment.rect.width / 2),
                    style: .circular),
                with: .color(.secondary.opacity(contrast == .increased ? 0.8 : 0.3)))
            if segment.rect.width >= 24 {
                let label = Text("+\(segment.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                let resolved = context.resolve(label)
                let size = resolved.measure(
                    in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
                if size.width + 4 <= segment.rect.width {
                    context.draw(resolved, at: CGPoint(x: segment.rect.midX, y: segment.rect.midY))
                }
            }
        }
    }

    private func drawDecorations(
        _ segments: [RequestRailGeometry.Segment], at timestamp: Date,
        in context: inout GraphicsContext
    ) {
        for segment in segments {
            let color = color(for: segment.lane)
            for effect in prepared where effect.key.requestID == segment.lane.id {
                let age = timestamp.timeIntervalSince(effect.startedAt)
                guard age >= 0, timestamp < effect.expiresAt else { continue }
                let bar = segment.rect
                let profile = effect.profile
                if profile.completion {
                    let tip = CGPoint(x: bar.maxX, y: bar.midY)
                    drawBurst(
                        profile, age: age, duration: 0.24, scale: 0.5,
                        at: tip, color: color, in: &context)
                    drawLightning(profile, age: age, rect: bar, color: color, in: &context)
                    if profile.explodes {
                        drawBurst(
                            profile, age: age - profile.surgeDelay - profile.surgeDuration,
                            duration: profile.burstDuration, scale: 1.12,
                            at: tip, color: color, in: &context)
                    }
                } else if segment.lane.startedAt >= now.addingTimeInterval(-duration) {
                    drawBurst(
                        profile, age: age, duration: profile.burstDuration, scale: 1,
                        at: CGPoint(x: bar.minX + segment.cornerRadius, y: bar.midY),
                        color: color, in: &context)
                }
            }
            if segment.isLive {
                for twinkle in twinkles where twinkle.requestID == segment.lane.id {
                    drawTwinkle(
                        twinkle, segment: segment, at: timestamp, color: color, in: &context)
                }
            }
        }
    }

    private func drawTwinkle(
        _ twinkle: Twinkle, segment: RequestRailGeometry.Segment, at timestamp: Date,
        color: Color, in context: inout GraphicsContext
    ) {
        let p = timestamp.timeIntervalSince(twinkle.startedAt) / twinkle.duration
        guard p > 0, p < 1 else { return }
        let strength = pow(sin(.pi * p), 2)
        let size = CGFloat(twinkle.size * (0.7 + 0.3 * strength))
        let bar = segment.rect
        let x =
            rect.minX + twinkle.location.timeIntervalSince(now.addingTimeInterval(-duration))
            / duration * rect.width
        guard x >= bar.minX, x <= bar.maxX else { return }
        let point = CGPoint(x: x, y: bar.midY)
        var clipped = context
        clipped.clip(
            to: Path(roundedRect: bar, cornerRadius: segment.cornerRadius, style: .circular))
        clipped.fill(
            Path(
                ellipseIn: CGRect(
                    x: point.x - size * 2.1, y: bar.minY, width: size * 4.2, height: bar.height)),
            with: .color(color.opacity(strength * 0.32)))
        let mark =
            twinkle.star
            ? star(at: point, size: size, angle: twinkle.angle)
            : circle(at: point, radius: size * 0.56)
        clipped.fill(mark, with: .color(.white.opacity(strength)))
    }

    private func drawBurst(
        _ profile: RequestRailEffectProfile, age: TimeInterval, duration: TimeInterval,
        scale: Double, at point: CGPoint, color: Color, in context: inout GraphicsContext
    ) {
        let p = age / duration
        guard p > 0, p < 1 else { return }
        let strength = RequestRailEffectProfile.envelope(p)
        let expansion = 1 - pow(1 - p, 3)
        let size = profile.size * scale
        let halo: Double = profile.family == .fireflies ? 20 : profile.family == .arcs ? 18 : 14
        var glow = context
        glow.translateBy(x: point.x, y: point.y)
        glow.rotate(by: .radians(profile.angle))
        glow.scaleBy(x: 1, y: 0.76)
        drawGlow(
            at: .zero, radius: (9 + halo * expansion) * size, strength: strength * 0.92,
            color: color, in: &glow)

        if profile.family == .arcs {
            for index in 0..<3 {
                let radius = (7 + 12 * expansion + Double(index) * 1.6) * size
                let angle = profile.angle + Double(index) * 2.2
                var arc = Path()
                arc.addArc(
                    center: point, radius: radius, startAngle: .radians(angle),
                    endAngle: .radians(angle + 0.4 + profile.particles[index].stretch * 0.48),
                    clockwise: false)
                context.stroke(
                    arc, with: .color(color.opacity(strength)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        } else {
            for particle in profile.particles {
                let q = RequestRailEffectProfile.clamp((p - particle.delay) / particle.life)
                let brightness = RequestRailEffectProfile.envelope(q) * 0.92
                guard brightness > 0 else { continue }
                let travel = 1 - pow(1 - q, 2)
                let distance = (4 + particle.distance * travel) * size
                let position = CGPoint(
                    x: point.x + cos(particle.angle) * distance,
                    y: point.y + sin(particle.angle) * distance)
                if profile.family == .fireflies {
                    drawGlow(
                        at: position, radius: particle.size * 3, strength: brightness * 0.8,
                        color: color, in: &context)
                    context.fill(
                        circle(at: position, radius: particle.size * (1 - 0.4 * q)),
                        with: .color(.white.opacity(brightness)))
                } else {
                    let length = particle.length * (1 - 0.5 * q)
                    var spark = Path()
                    spark.move(to: position)
                    spark.addLine(
                        to: CGPoint(
                            x: position.x + cos(particle.angle) * length,
                            y: position.y + sin(particle.angle) * length))
                    context.stroke(
                        spark, with: .color(.white.opacity(brightness)),
                        style: StrokeStyle(lineWidth: particle.size * 0.75, lineCap: .round))
                }
            }
        }
        drawGlow(at: point, radius: 8 * size, strength: strength, color: color, in: &context)
        let core =
            profile.family == .fireflies
            ? circle(at: point, radius: (2 + 1.3 * strength) * size)
            : star(at: point, size: (4.5 + 3.5 * strength) * size, angle: profile.angle)
        context.fill(core, with: .color(.white.opacity(strength)))
    }

    private func drawLightning(
        _ profile: RequestRailEffectProfile, age: TimeInterval, rect: CGRect,
        color: Color, in context: inout GraphicsContext
    ) {
        guard let frame = profile.lightningFrame(age: age, rect: rect) else { return }
        var clipped = context
        // Keep crackles local to the bar, leaving the neighboring rail body clear.
        clipped.clip(
            to: Path(
                CGRect(x: rect.minX - 7, y: rect.midY - 6.5, width: rect.width + 14, height: 13)))
        for fork in frame.forks {
            let path = polyline(fork.points)
            clipped.stroke(
                path, with: .color(color.opacity(frame.brightness * fork.energy * 0.65)),
                style: StrokeStyle(lineWidth: 2.2, lineJoin: .miter))
            clipped.stroke(
                path, with: .color(.white.opacity(frame.brightness * fork.energy * 0.86)),
                style: StrokeStyle(lineWidth: 0.65, lineJoin: .miter))
        }
        let channel = polyline(frame.points)
        clipped.stroke(
            channel, with: .color(color.opacity(frame.brightness * (0.22 + frame.recharge * 0.16))),
            style: StrokeStyle(lineWidth: 5.5 + frame.recharge * 1.5, lineJoin: .round))
        clipped.stroke(
            channel, with: .color(color.opacity(frame.brightness * 0.9)),
            style: StrokeStyle(lineWidth: 2.8, lineJoin: .miter, miterLimit: 2))
        clipped.stroke(
            channel, with: .color(.white.opacity(frame.brightness)),
            style: StrokeStyle(
                lineWidth: 1.15 + frame.recharge * 0.4, lineJoin: .miter, miterLimit: 2))
        clipped.fill(
            circle(at: frame.head, radius: 0.7), with: .color(.white.opacity(frame.brightness)))
    }

    private func drawGlow(
        at point: CGPoint, radius: CGFloat, strength: Double, color: Color,
        in context: inout GraphicsContext
    ) {
        context.fill(
            circle(at: point, radius: radius),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(strength), location: 0),
                    .init(color: .white.opacity(strength), location: 0.18),
                    .init(color: color.opacity(strength * 0.95), location: 0.4),
                    .init(color: color.opacity(0), location: 1),
                ]), center: point, startRadius: 0, endRadius: radius))
    }

    private func circle(at point: CGPoint, radius: CGFloat) -> Path {
        Path(
            ellipseIn: CGRect(
                x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    private func star(at point: CGPoint, size: CGFloat, angle: Double) -> Path {
        let inset = size * 0.24
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -size))
        path.addQuadCurve(to: CGPoint(x: size, y: 0), control: CGPoint(x: inset, y: -inset))
        path.addQuadCurve(to: CGPoint(x: 0, y: size), control: CGPoint(x: inset, y: inset))
        path.addQuadCurve(to: CGPoint(x: -size, y: 0), control: CGPoint(x: -inset, y: inset))
        path.addQuadCurve(to: CGPoint(x: 0, y: -size), control: CGPoint(x: -inset, y: -inset))
        path.closeSubpath()
        return path.applying(
            CGAffineTransform(rotationAngle: angle).concatenating(
                CGAffineTransform(translationX: point.x, y: point.y)))
    }

    private func polyline(_ points: [CGPoint]) -> Path {
        var path = Path()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    private struct EffectKey: Hashable {
        let requestID: UUID
        let completion: Bool
        let startedAt: Date
        let seed: UInt64

        init(_ event: RequestRailEvent) {
            requestID = event.requestID
            completion = event.kind == .completion
            startedAt = event.startedAt
            seed = event.seed
        }
    }

    private struct WorkKey: Hashable {
        let events: [EffectKey]
        let liveIDs: [UUID]
        let duration: TimeInterval
        let enabled: Bool
    }

    private struct PreparedEffect {
        let key: EffectKey
        let startedAt: Date
        let expiresAt: Date
        let profile: RequestRailEffectProfile
    }

    private struct Twinkle {
        let requestID: UUID
        let startedAt: Date
        let duration: TimeInterval
        let location: Date
        let size: Double
        let angle: Double
        let star: Bool
        var endsAt: Date { startedAt.addingTimeInterval(duration) }
    }
}

/// Dashboard windows are hosted by AppKit rather than a SwiftUI scene. Observe
/// the actual hosting window so a visible, non-key dashboard keeps animating,
/// while a hidden, minimized, fully occluded, detached, or closed one pauses.
private struct RequestRailWindowVisibility: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.visibilityChanged = { isVisible = $0 }
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.visibilityChanged = { isVisible = $0 }
        view.scheduleVisibilityUpdate()
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.stopObserving()
    }

    final class VisibilityView: NSView {
        var visibilityChanged: ((Bool) -> Void)?
        private var generation = 0
        private var lastDelivered: Bool?
        private var closing = false
        private var stopped = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            closing = false
            if !stopped, let window {
                let names: [Notification.Name] = [
                    NSWindow.didChangeOcclusionStateNotification,
                    NSWindow.didMiniaturizeNotification,
                    NSWindow.didDeminiaturizeNotification,
                    NSWindow.didMoveNotification,
                    NSWindow.didResizeNotification,
                    NSWindow.didChangeScreenNotification,
                    NSWindow.didExposeNotification,
                    NSWindow.willCloseNotification,
                ]
                for name in names {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(windowChanged(_:)), name: name, object: window)
                }
            }
            scheduleVisibilityUpdate()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleVisibilityUpdate()
        }

        override func viewDidHide() {
            super.viewDidHide()
            scheduleVisibilityUpdate()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            scheduleVisibilityUpdate()
        }

        @objc private func windowChanged(_ notification: Notification) {
            if notification.name == NSWindow.willCloseNotification {
                // willClose arrives while isVisible can still be true. Keep the
                // observers: MenuBarController reopens this same retained window.
                closing = true
            } else if notification.name == NSWindow.didExposeNotification
                || notification.name == NSWindow.didChangeOcclusionStateNotification
            {
                if let window, window.isVisible, window.occlusionState.contains(.visible) {
                    closing = false
                }
            }
            scheduleVisibilityUpdate()
        }

        func scheduleVisibilityUpdate() {
            generation &+= 1
            let scheduledGeneration = generation
            // AppKit can call these hooks during a SwiftUI update. Deliver only
            // the newest value on the next main-loop turn, never synchronously.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.generation == scheduledGeneration else {
                    return
                }
                let visible: Bool
                if let window = self.window {
                    visible =
                        !self.closing && !self.isHiddenOrHasHiddenAncestor
                        && window.isVisible && !window.isMiniaturized
                        && window.occlusionState.contains(.visible)
                } else {
                    visible = false
                }
                guard visible != self.lastDelivered else { return }
                self.lastDelivered = visible
                self.visibilityChanged?(visible)
            }
        }

        func stopObserving() {
            stopped = true
            generation &+= 1
            NotificationCenter.default.removeObserver(self)
            visibilityChanged = nil
        }
    }
}

/// A deterministic random stream used only while preparing effect parameters.
/// Frames interpolate those parameters instead of generating new random points.
struct RequestRailRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }
}

/// Pure motion model shared by rendering and geometry/motion regressions.
struct RequestRailEffectProfile: Equatable {
    enum Family: Equatable { case fireflies, sparks, arcs }
    struct Particle: Equatable {
        let angle, distance, length, size, delay, life, stretch: Double
    }
    struct Channel: Equatable {
        let weight, offset, reach, depth, kink: Double
    }
    struct Crackle: Equatable {
        let at, brightness: Double
        let offsets, forks: [Double]
    }
    struct Fork: Equatable {
        let points: [CGPoint]
        let energy: Double
    }
    struct LightningFrame: Equatable {
        let points: [CGPoint]
        let forks: [Fork]
        let head: CGPoint
        let brightness, recharge: Double
    }

    let completion: Bool
    let family: Family
    let angle, size, burstDuration: Double
    let particles: [Particle]
    let surgeDelay = 0.08
    let surgeDuration, direction, bend, trail: Double
    let explodes: Bool
    let channel: [Channel]
    let crackles: [Crackle]
    let flashAt: [Double]

    init(seed: UInt64, requestDuration: TimeInterval, completion: Bool) {
        var random = RequestRailRandom(seed: seed)
        self.completion = completion
        let choice = random.unit()
        family = choice < 0.45 ? .fireflies : choice < 0.82 ? .sparks : .arcs
        angle = random.unit() * .pi * 2
        let duration = requestDuration.isFinite ? max(0, requestDuration) : 0
        surgeDuration = min(1.2, 0.64 + duration * 0.016) * (1 + random.unit() * 0.18)
        direction = random.unit() < 0.5 ? -1 : 1
        explodes = random.unit() < 0.65
        bend = (random.unit() - 0.5) * 0.08
        trail = 0.08 + random.unit() * 0.055
        burstDuration = (completion ? 0.8 : 0.6) * (0.9 + 0.2 * random.unit())
        size = 0.9 + 0.2 * random.unit()
        let particleCount = family == .fireflies ? 4 : 5
        var particles: [Particle] = []
        for index in 0..<particleCount {
            let particleAngle =
                family == .sparks
                ? angle + (Double(index) - 2) * 0.43 + (random.unit() - 0.5) * 0.3
                : angle + Double(index) * .pi / 2 + (random.unit() - 0.5) * 0.8
            particles.append(
                Particle(
                    angle: particleAngle, distance: 10 + random.unit() * 13,
                    length: 2 + random.unit() * 4, size: 0.9 + random.unit() * 1.3,
                    delay: random.unit() * 0.14, life: 0.65 + random.unit() * 0.2,
                    stretch: 0.7 + random.unit() * 0.7))
        }
        self.particles = particles
        guard completion else {
            channel = []
            crackles = []
            flashAt = []
            return
        }
        var electric = RequestRailRandom(seed: seed ^ 0xA076_1D64_78BD_642F)
        channel = (0..<256).map { _ in
            Channel(
                weight: 0.5 + electric.unit(), offset: (electric.unit() - 0.5) * 4.8,
                reach: 8 + electric.unit() * 14, depth: 2.6 + electric.unit() * 2.2,
                kink: (electric.unit() - 0.5) * 2)
        }
        flashAt = [0.19 + electric.unit() * 0.07, 0.61 + electric.unit() * 0.08]
        var states: [Crackle] = []
        var at = 0.0
        for _ in 0..<32 {
            states.append(
                Crackle(
                    at: at, brightness: 0.63 + electric.unit() * 0.37,
                    offsets: (0..<256).map { _ in (electric.unit() - 0.5) * 5 },
                    forks: (0..<256).map { _ in electric.unit() }))
            at += 0.045 + electric.unit() * 0.055
        }
        crackles = states
    }

    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    static func smooth(_ value: Double) -> Double {
        let p = clamp(value)
        return p * p * (3 - 2 * p)
    }
    static func envelope(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return 0 }
        let fade = clamp((p - 0.1) / 0.9)
        return min(1, p / 0.04) * (1 - fade) * (1 - fade) * (1 + 2 * fade)
    }

    func lightningFrame(age: TimeInterval, rect: CGRect) -> LightningFrame? {
        let age = age - surgeDelay
        guard completion, age > 0, age < surgeDuration + 0.15,
            rect.width > 0, rect.height > 0
        else { return nil }
        let p = Self.clamp(age / surgeDuration)
        let progress = p + bend * sin(2 * .pi * p)
        let settle = Self.smooth((age - surgeDuration) / 0.15)
        let strength = min(1, age / 0.05) * (1 - settle)
        let route = RequestRailPerimeter(rect: rect)
        let distance = Double(route.length) * progress
        let tail = min(96, Double(route.length) * (0.31 + trail), distance) * (1 - settle)
        let count = max(8, min(240, Int(ceil(route.length / 6.5))))
        let sampleTime = min(age, surgeDuration)
        let index = crackles.lastIndex { $0.at <= sampleTime } ?? 0
        let current = crackles[index]
        let previous = crackles[max(0, index - 1)]
        let blend = Self.smooth((sampleTime - current.at) / 0.018)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * blend }
        let recharge = flashAt.map { exp(-pow((p - $0) / 0.036, 2)) }.max() ?? 0
        let brightness = strength * (0.7 + 0.3 * mix(previous.brightness, current.brightness))
        let total = channel.prefix(count).reduce(0) { $0 + $1.weight }

        func offsetPoint(_ position: Double, _ offset: Double) -> CGPoint {
            let d = direction * position
            let point = route.point(at: d)
            let before = route.point(at: d - 0.12)
            let after = route.point(at: d + 0.12)
            let dx = after.x - before.x
            let dy = after.y - before.y
            let length = max(0.0001, hypot(dx, dy))
            return CGPoint(x: point.x + dy / length * offset, y: point.y - dx / length * offset)
        }
        var points = [offsetPoint(distance - tail, 0)]
        var forks: [Fork] = []
        var sum = 0.0
        for index in 0..<count {
            let item = channel[index]
            sum += item.weight
            let position = Double(route.length) * sum / total
            guard position > distance - tail, position < distance else { continue }
            let offset =
                (item.offset * 0.3 + mix(previous.offsets[index], current.offsets[index]) * 0.7)
                * (1 - settle)
            let knot = offsetPoint(position, offset)
            points.append(knot)
            let charge = mix(previous.forks[index], current.forks[index])
            let energy = Self.clamp((charge - 0.46) / 0.54)
            guard energy > 0, distance - position >= 2 else { continue }
            let reach = min(item.reach, Double(route.length) * 0.16, distance - position)
            forks.append(
                Fork(
                    points: [
                        knot,
                        offsetPoint(position + reach * 0.3, -item.depth * 0.42 + item.kink * 0.5),
                        offsetPoint(position + reach * 0.63, -item.depth * 0.76 - item.kink * 0.3),
                        offsetPoint(position + reach, -item.depth),
                    ], energy: energy))
        }
        let head = route.point(at: direction * distance)
        points.append(head)
        return LightningFrame(
            points: points, forks: forks, head: head, brightness: brightness, recharge: recharge)
    }
}
