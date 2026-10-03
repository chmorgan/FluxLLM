import AppKit
import MetalKit
import SwiftUI

/// Publication inputs only. The native host owns effect deadlines and advances
/// shader time without publishing animation frames through SwiftUI.
struct MetalFullChartDecorationInput: Equatable {
    let lanes: [RequestLane]
    let segments: [RequestRailGeometry.Segment]
    let presentation: RequestRailPresentation
    let now: Date
    let duration: TimeInterval
    let rail: CGRect
    let colors: [UUID: SIMD4<Float>]
    let enabled: Bool
}

/// Shares the reference receipt and random scheduling semantics, but has no
/// observed properties, display timer, drawing geometry, or GPU resources.
struct MetalFullChartAnimationScheduler {
    private(set) var prepared: [RequestRailLifecycleEffects.Prepared] = []
    private(set) var twinkles: [RequestRailTwinkle] = []
    private(set) var schedule = RequestRailAnimationSchedule(
        at: .distantPast, visibleUntil: [], nextTwinkleAt: nil)
    private(set) var retainedTwinkleSchedule = RequestRailAnimationSchedule(
        at: .distantPast, visibleUntil: [], nextTwinkleAt: nil)
    private(set) var work: RequestRailLifecycleEffects.WorkKey?
    private(set) var nextTwinkleAt: Date?
    private var input: MetalFullChartDecorationInput?
    private var sequence: UInt64 = 0

    mutating func update(
        _ input: MetalFullChartDecorationInput, visible: Bool, at timestamp: Date,
        deterministic: Bool
    ) {
        self.input = input
        let eligibility = RequestRailAnimationEligibility(
            segments: input.segments, events: input.presentation.events,
            now: input.now, duration: input.duration)
        let nextWork = RequestRailLifecycleEffects.WorkKey(
            events: input.presentation.events.map(RequestRailLifecycleEffects.Key.init),
            eligibility: eligibility, duration: input.duration,
            enabled: input.enabled && visible)
        if work != nextWork {
            work = nextWork
            guard nextWork.enabled else {
                resetEffects(at: timestamp)
                return
            }
            prepared = RequestRailLifecycleEffects.prepare(
                input.presentation.events, lanes: input.lanes,
                assignments: input.presentation.assignments, now: input.now,
                timestamp: timestamp, previous: prepared)
            twinkles.removeAll {
                $0.endsAt <= timestamp || !eligibility.liveIDs.contains($0.requestID)
            }
            sequence = PerformanceAnimationRandomness.initialTwinkleSequence(
                at: timestamp, deterministic: deterministic)
            nextTwinkleAt = eligibility.liveIDs.isEmpty ? nil : timestamp
        }
        advance(at: timestamp)
    }

    mutating func advance(at timestamp: Date) {
        guard let input, let work, work.enabled else {
            resetEffects(at: timestamp)
            return
        }
        prepared.removeAll { $0.visibleUntil <= timestamp }
        twinkles.removeAll { $0.endsAt <= timestamp }
        let liveIDs = work.eligibility.liveIDs
        if let due = nextTwinkleAt, due <= timestamp, !liveIDs.isEmpty {
            var random = RequestRailRandom(seed: sequence)
            let index = min(liveIDs.count - 1, Int(random.unit() * Double(liveIDs.count)))
            let id = liveIDs[index]
            var requestRandom = RequestRailRandom(seed: Self.seed(id) ^ sequence)
            let start = max(
                input.segments.first(where: { $0.lane.id == id })?.lane.startedAt ?? timestamp,
                timestamp.addingTimeInterval(-input.duration))
            let fraction = 0.08 + requestRandom.unit() * 0.84
            let twinkle = RequestRailTwinkle(
                requestID: id, startedAt: timestamp,
                duration: 0.43 + requestRandom.unit() * 0.16,
                location: start.addingTimeInterval(timestamp.timeIntervalSince(start) * fraction),
                size: 2 + requestRandom.unit() * 1.3,
                angle: requestRandom.unit() * 0.7, star: requestRandom.unit() > 0.45)
            twinkles = Array((twinkles + [twinkle]).suffix(2))
            nextTwinkleAt = timestamp.addingTimeInterval(
                RequestRailAnimationSchedule.twinkleInterval)
            sequence &+= 1
        }
        let visible = prepared.filter { work.eligibility.effectIDs.contains($0.key.eventID) }
        schedule = RequestRailAnimationSchedule(
            at: timestamp,
            visibleUntil: visible.map(\.visibleUntil) + twinkles.map(\.endsAt),
            nextTwinkleAt: nextTwinkleAt, retainedUntil: prepared.map(\.visibleUntil))
        // Retained glints need spawn/expiry wakes, but no app animation clock.
        // Include the lifecycle deadline separately: a longer-lived glint must
        // not keep Metal running after the last lifecycle pixels disappear.
        retainedTwinkleSchedule = RequestRailAnimationSchedule(
            at: timestamp, visibleUntil: visible.map(\.visibleUntil),
            nextTwinkleAt: schedule.nextUpdate, retainedUntil: prepared.map(\.visibleUntil))
    }

    func metalSchedule(retainingTwinkles: Bool, hasCursor: Bool = false)
        -> RequestRailAnimationSchedule
    {
        // The cursor is rendered after all decorations in the same Metal
        // drawable. During inspection, shader glints preserve that ordering.
        retainingTwinkles && !hasCursor ? retainedTwinkleSchedule : schedule
    }

    func usesShaderTwinkles(retainingTwinkles: Bool, hasCursor: Bool = false) -> Bool {
        !retainingTwinkles || hasCursor || retainedTwinkleSchedule.isAnimating
    }

    mutating func stop(at timestamp: Date) {
        work = nil
        input = nil
        resetEffects(at: timestamp)
    }

    private mutating func resetEffects(at timestamp: Date) {
        prepared = []
        twinkles = []
        nextTwinkleAt = nil
        schedule = RequestRailAnimationSchedule(at: timestamp, visibleUntil: [], nextTwinkleAt: nil)
        retainedTwinkleSchedule = schedule
    }

    private static func seed(_ id: UUID) -> UInt64 {
        id.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }
}

struct MetalFullChartSurface: NSViewRepresentable {
    let scene: MetalFullChartScene
    let revision: AnyHashable
    var cursor: MetalFullChartScene? = nil
    var cursorRevision: AnyHashable? = nil
    let decorations: MetalFullChartDecorationInput
    var cacheStaticAndRetainTwinkles = false
    var onFailure: (@MainActor () -> Void)? = nil
    @Environment(\.displayScale) private var displayScale

    func makeNSView(context: Context) -> MetalFullChartView {
        let view = MetalFullChartView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MetalFullChartView, context: Context) {
        view.update(
            scene: scene, revision: revision, cursor: cursor,
            cursorRevision: cursorRevision, decorations: decorations,
            scale: displayScale, cacheStaticAndRetainTwinkles: cacheStaticAndRetainTwinkles,
            onFailure: onFailure)
    }

    static func dismantleNSView(_ view: MetalFullChartView, coordinator: ()) { view.stop() }
}

/// An old host remains diagnostically alive until its final GPU submission has
/// completed. Completion never waits, touches SwiftUI, or retains the NSView.
private final class MetalFullChartFrameLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0
    private var closing = false
    private var destroyed = false
    private var retry: (@Sendable () -> Void)?
    let id: UInt64?

    @MainActor
    init() { id = PerformanceGraphicsDiagnostics.shared.metalFullChartHostCreated() }

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closing, outstanding < 2 else { return false }
        outstanding += 1
        return true
    }

    func finish() {
        lock.lock()
        outstanding -= 1
        let destroy = closing && outstanding == 0 && !destroyed
        if destroy { destroyed = true }
        let resume = outstanding == 0 && !closing ? retry : nil
        if outstanding == 0 { retry = nil }
        lock.unlock()
        if destroy { notifyDestroyed() }
        resume?()
    }

    func close() {
        lock.lock()
        closing = true
        retry = nil
        let destroy = outstanding == 0 && !destroyed
        if destroy { destroyed = true }
        lock.unlock()
        if destroy { notifyDestroyed() }
    }

    func retryWhenDrained(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let immediately = !closing && outstanding == 0
        if !closing && !immediately { retry = action }
        lock.unlock()
        if immediately { action() }
    }

    private func notifyDestroyed() {
        let id = id
        // One lifecycle notification per destroyed native surface, not one
        // MainActor task per successful animation frame.
        Task { @MainActor in PerformanceGraphicsDiagnostics.shared.metalFullChartHostDestroyed(id) }
    }
}

@MainActor
final class MetalFullChartView: NSView, MTKViewDelegate {
    private var scene: MetalFullChartScene?
    private var cursor: MetalFullChartScene?
    private var revision: AnyHashable?
    private var cursorRevision: AnyHashable?
    private var input: MetalFullChartDecorationInput?
    private var requestedScale: CGFloat = 1
    private var onFailure: (@MainActor () -> Void)?
    private var renderer: MetalFullChartRenderer?
    private var cursorRenderer: MetalFullChartRenderer?
    private var effectsRenderer: MetalFullChartEffectsRenderer?
    private var staticCache: MetalChartStaticCache?
    private var staticCacheRevision: UInt64 = 0
    private var drawingScale: CGFloat?
    private var retainedTwinkleView: RetainedRequestRailTwinkleView?
    private var cacheStaticAndRetainTwinkles = false
    private var queue: (any MTLCommandQueue)?
    private var metalView: MTKView?
    private var lifetime: MetalFullChartFrameLifetime?
    private var scheduler = MetalFullChartAnimationScheduler()
    private var wake: DispatchWorkItem?
    private var wakeGeneration: UInt64 = 0
    private var anchor = Date()
    private var uploadedEffects: [MetalFullChartEffectsRenderer.Element] = []
    private var needsStaticUpload = true
    private var needsCursorUpload = true
    private var needsRedraw = true
    private var closing = false
    private var stopped = false
    private var failed = false

    var hasNativeResources: Bool {
        metalView != nil || renderer != nil || effectsRenderer != nil
            || staticCache != nil || retainedTwinkleView != nil
    }
    private var hasCursor: Bool { cursor.map { !$0.primitives.isEmpty } ?? false }
    private var metalSchedule: RequestRailAnimationSchedule {
        scheduler.metalSchedule(
            retainingTwinkles: cacheStaticAndRetainTwinkles, hasCursor: hasCursor)
    }
    var isAnimating: Bool { metalSchedule.isAnimating }
    var hasScheduledWake: Bool { wake != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        canDrawSubviewsIntoLayer = false
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }

    func update(
        scene: MetalFullChartScene, revision: AnyHashable,
        cursor: MetalFullChartScene?, cursorRevision: AnyHashable?,
        decorations: MetalFullChartDecorationInput, scale: CGFloat,
        cacheStaticAndRetainTwinkles: Bool = false,
        onFailure: (@MainActor () -> Void)? = nil
    ) {
        guard !stopped else { return }
        self.onFailure = onFailure
        guard scene.size.width.isFinite, scene.size.height.isFinite,
            scene.size.width >= 0, scene.size.height >= 0, scale.isFinite, scale > 0,
            cursor == nil || cursor?.size == scene.size
        else {
            fail()
            return
        }
        if self.cacheStaticAndRetainTwinkles != cacheStaticAndRetainTwinkles {
            releaseResources()
            self.cacheStaticAndRetainTwinkles = cacheStaticAndRetainTwinkles
        }
        if self.revision != revision || self.scene == nil
            || (cacheStaticAndRetainTwinkles
                && (self.scene !== scene || self.scene?.size != scene.size))
        {
            self.scene = scene
            self.revision = revision
            staticCacheRevision &+= 1
            needsStaticUpload = true
            needsRedraw = true
        }
        if self.cursorRevision != cursorRevision || (self.cursor == nil) != (cursor == nil) {
            self.cursor = cursor
            self.cursorRevision = cursorRevision
            needsCursorUpload = true
            needsRedraw = true
        }
        input = decorations
        requestedScale = scale
        reconcile()
    }

    override func layout() {
        super.layout()
        reconcile()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reconcile()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reconcile()
    }
    override func viewDidHide() {
        super.viewDidHide()
        reconcile()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        reconcile()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        closing = false
        if !stopped, let window {
            for name in [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification, NSWindow.didExposeNotification,
                NSWindow.didChangeScreenNotification, NSWindow.willCloseNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowChanged(_:)),
                    name: name, object: window)
            }
        }
        reconcile()
    }

    @objc private func windowChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification { closing = true }
        reconcile()
    }

    private var isNativelyVisible: Bool {
        guard !stopped, !closing, !isHiddenOrHasHiddenAncestor,
            let window, window.isVisible, !window.isMiniaturized,
            window.occlusionState.contains(.visible), MetalArrivalSurfaceGeometry.valid(bounds)
        else { return false }
        return true
    }

    private func reconcile(at timestamp: Date = Date()) {
        guard !stopped, !failed, let input, let scene else { return }
        guard isNativelyVisible, scene.size.width > 0, scene.size.height > 0 else {
            scheduler.stop(at: timestamp)
            cancelWake()
            releaseResources()
            return
        }
        guard !input.enabled || input.segments.allSatisfy({ input.colors[$0.lane.id] != nil })
        else {
            fail()
            return
        }
        scheduler.update(
            input, visible: true, at: timestamp,
            deterministic: PerformanceGraphicsDiagnostics.shared.isEnabled)
        let scale = window?.backingScaleFactor ?? requestedScale
        guard let size = MetalArrivalSurfaceGeometry.drawableSize(points: bounds.size, scale: scale)
        else {
            fail()
            return
        }
        do {
            if renderer == nil {
                guard let device = MTLCreateSystemDefaultDevice(),
                    let queue = device.makeCommandQueue()
                else {
                    fail()
                    return
                }
                let renderer = try MetalFullChartRenderer(device: device)
                let effects = try MetalFullChartEffectsRenderer(device: device)
                let cursor = try MetalFullChartRenderer(device: device)
                let view = MTKView(frame: bounds, device: device)
                view.isPaused = true
                view.enableSetNeedsDisplay = false
                view.preferredFramesPerSecond = 30
                view.autoResizeDrawable = false
                view.drawableSize = size
                view.colorPixelFormat = .bgra8Unorm
                view.sampleCount = 1
                view.depthStencilPixelFormat = .invalid
                view.framebufferOnly = true
                view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
                view.layer?.isOpaque = false
                if let layer = view.layer as? CAMetalLayer {
                    layer.maximumDrawableCount = 2
                    layer.allowsNextDrawableTimeout = true
                    layer.backgroundColor = CGColor(gray: 0, alpha: 0)
                }
                self.renderer = renderer
                if cacheStaticAndRetainTwinkles {
                    staticCache = try MetalChartStaticCache(device: device)
                }
                cursorRenderer = cursor
                effectsRenderer = effects
                self.queue = queue
                metalView = view
                lifetime = MetalFullChartFrameLifetime()
                view.delegate = self
                addSubview(view)
                needsStaticUpload = true
                needsCursorUpload = true
                needsRedraw = true
            }
            guard let view = metalView, let renderer, let cursorRenderer, let effectsRenderer else {
                return
            }
            if view.frame != bounds {
                view.frame = bounds
                needsRedraw = true
            }
            if view.drawableSize != size || drawingScale != scale {
                if view.drawableSize != size { view.drawableSize = size }
                drawingScale = scale
                staticCacheRevision &+= 1
                needsRedraw = true
                // One backing-scale change can also resize the drawable; it
                // invalidates the cached image once, independently of scene
                // publications and the history-preparation counter.
                if cacheStaticAndRetainTwinkles {
                    PerformanceGraphicsDiagnostics.shared.metalFullChartSurfaceInvalidated(
                        lifetime?.id)
                }
            }
            var uploaded = false
            if needsStaticUpload {
                try renderer.update(scene: scene)
                needsStaticUpload = false
                uploaded = true
            }
            if needsCursorUpload {
                if let cursor {
                    try cursorRenderer.update(scene: cursor)
                } else {
                    cursorRenderer.removeAll()
                }
                needsCursorUpload = false
                uploaded = true
            }
            // A fixed anchor is safe across an effect episode. Rebase when the
            // native surface starts, and before a stale idle anchor is reused.
            if uploadedEffects.isEmpty || abs(timestamp.timeIntervalSince(anchor)) > 60 {
                anchor = timestamp
            }
            let elements = effectElements(relativeTo: anchor)
            if elements != uploadedEffects {
                try effectsRenderer.update(elements: elements)
                uploadedEffects = elements
                needsRedraw = true
                uploaded = true
            }
            if uploaded {
                PerformanceGraphicsDiagnostics.shared.metalFullChartGeometryUploaded(
                    lifetime?.id,
                    bytes: UInt64(
                        renderer.statistics.retainedBytes + cursorRenderer.statistics.retainedBytes
                            + effectsRenderer.statistics.retainedDescriptorBytes
                            + effectsRenderer.statistics.retainedFrameBytes))
            }
            reconcileRetainedTwinkles(scale: scale)
            scheduleWake()
            let paused = !metalSchedule.isAnimating
            let wasPaused = view.isPaused
            if view.isPaused != paused { view.isPaused = paused }
            // An already active MTKView picks up changed descriptors on its next
            // scheduled frame. Do not add an extra frame for every publication
            // or glint spawn between its 30 Hz deadlines.
            if needsRedraw && (paused || wasPaused) { view.draw() }
        } catch { fail() }
    }

    private func effectElements(relativeTo anchor: Date) -> [MetalFullChartEffectsRenderer.Element]
    {
        guard let input, input.enabled else { return [] }
        var elements: [MetalFullChartEffectsRenderer.Element] = []
        for segment in input.segments {
            guard let color = input.colors[segment.lane.id] else { continue }
            for effect in scheduler.prepared where effect.key.requestID == segment.lane.id {
                guard
                    effect.profile.completion
                        || segment.lane.startedAt >= input.now.addingTimeInterval(-input.duration)
                else { continue }
                elements.append(
                    .effect(
                        .init(
                            id: effect.key, startTime: effect.startedAt.timeIntervalSince(anchor),
                            profile: effect.profile, rect: segment.rect,
                            cornerRadius: segment.cornerRadius,
                            color: color)))
            }
            if segment.isLive
                && scheduler.usesShaderTwinkles(
                    retainingTwinkles: cacheStaticAndRetainTwinkles, hasCursor: hasCursor
                )
            {
                for twinkle in scheduler.twinkles where twinkle.requestID == segment.lane.id {
                    guard
                        let placement = twinkle.placement(
                            segment: segment, now: input.now, duration: input.duration,
                            rail: input.rail)
                    else { continue }
                    elements.append(
                        .twinkle(
                            .init(
                                twinkle: twinkle, placement: placement,
                                startTime: twinkle.startedAt.timeIntervalSince(anchor), color: color
                            )))
                }
            }
        }
        return elements
    }

    private func reconcileRetainedTwinkles(scale: CGFloat) {
        guard cacheStaticAndRetainTwinkles, let input else { return }
        guard
            input.enabled
                && (!(scheduler.work?.eligibility.liveIDs.isEmpty ?? true)
                    || !scheduler.prepared.isEmpty || !scheduler.twinkles.isEmpty)
        else {
            retainedTwinkleView?.stop()
            retainedTwinkleView?.removeFromSuperview()
            retainedTwinkleView = nil
            return
        }
        let view: RetainedRequestRailTwinkleView
        if let existing = retainedTwinkleView {
            view = existing
        } else {
            view = RetainedRequestRailTwinkleView(frame: bounds)
            retainedTwinkleView = view
            addSubview(view)
        }
        if view.frame != bounds { view.frame = bounds }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let descriptors = scheduler.twinkles.suffix(2).compactMap {
            twinkle -> RetainedTwinkleDescriptor? in
            guard
                let segment = input.segments.first(where: {
                    $0.lane.id == twinkle.requestID && $0.isLive
                }),
                let placement = twinkle.placement(
                    segment: segment, now: input.now, duration: input.duration, rail: input.rail),
                let rgba = input.colors[segment.lane.id],
                let color = CGColor(
                    colorSpace: colorSpace,
                    components: [
                        CGFloat(rgba.x), CGFloat(rgba.y), CGFloat(rgba.z), CGFloat(rgba.w),
                    ])
            else { return nil }
            return RetainedTwinkleDescriptor(twinkle: twinkle, placement: placement, color: color)
        }
        // Keep the same retained instances and clocks while Metal temporarily
        // draws glints in per-request lifecycle order. The native layer host
        // suppresses opacity, then resumes at the original age without replay.
        view.update(
            descriptors: descriptors, scale: scale,
            isPresented: !scheduler.usesShaderTwinkles(
                retainingTwinkles: true, hasCursor: hasCursor))
    }

    private func cancelWake() {
        wakeGeneration &+= 1
        wake?.cancel()
        wake = nil
    }

    private func scheduleWake() {
        cancelWake()
        guard let deadline = metalSchedule.nextUpdate else { return }
        let generation = wakeGeneration
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wakeGeneration == generation else { return }
                self.wake = nil
                self.reconcile()
            }
        }
        wake = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: item)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsRedraw = true }

    func draw(in view: MTKView) {
        guard view === metalView, !failed, !stopped else { return }
        guard isNativelyVisible else {
            scheduler.stop(at: Date())
            cancelWake()
            releaseResources()
            return
        }
        guard
            let scene, let renderer, let cursorRenderer, let effectsRenderer,
            let queue, let lifetime
        else { return }
        guard lifetime.begin() else {
            PerformanceGraphicsDiagnostics.shared.metalFullChartFrameSkipped(lifetime.id)
            if view.isPaused {
                // The quality counter disqualifies a dropped animation frame.
                // A single completion-triggered retry still replaces the final
                // animated drawable with its static chart without an idle loop.
                lifetime.retryWhenDrained { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.lifetime === lifetime, !self.failed, !self.stopped
                        else { return }
                        self.metalView?.draw()
                    }
                }
            }
            return
        }
        guard let buffer = queue.makeCommandBuffer(), let drawable = view.currentDrawable else {
            lifetime.finish()
            fail()
            return
        }
        let timestamp = Date()
        do {
            if !view.isPaused {
                PerformanceGraphicsDiagnostics.shared.metalFullChartEffectClockTick(lifetime.id)
            }
            if let staticCache {
                let rasterized = try staticCache.encode(
                    into: buffer, target: drawable.texture, renderer: renderer,
                    scene: scene, revision: staticCacheRevision)
                PerformanceGraphicsDiagnostics.shared.metalFullChartStaticCacheUsed(
                    lifetime.id, rasterized: rasterized,
                    bytes: UInt64(staticCache.statistics.retainedBytes))
            } else {
                try renderer.encode(
                    into: buffer, target: drawable.texture, pointSize: scene.size, clear: true)
            }
            let content = try effectsRenderer.encode(
                into: buffer, target: drawable.texture,
                elapsedTime: timestamp.timeIntervalSince(anchor),
                pointSize: scene.size, origin: .zero, clear: false)
            if let cursor, !cursor.primitives.isEmpty {
                try cursorRenderer.encode(
                    into: buffer, target: drawable.texture, pointSize: scene.size, clear: false)
            }
            if content.frameStorageChanged {
                PerformanceGraphicsDiagnostics.shared.metalFullChartBuffersRetained(
                    lifetime.id,
                    bytes: UInt64(
                        renderer.statistics.retainedBytes + cursorRenderer.statistics.retainedBytes
                            + effectsRenderer.statistics.retainedDescriptorBytes
                            + effectsRenderer.statistics.retainedFrameBytes))
            }
            buffer.addCompletedHandler { [weak self] buffer in
                lifetime.finish()
                if buffer.status != .completed || buffer.error != nil {
                    // Only failure crosses back to AppKit; successful frames do
                    // not enqueue a MainActor task or trigger a SwiftUI update.
                    Task { @MainActor [weak self] in
                        // The native view may have closed while this command
                        // ran. Failure evidence outlives its registered host.
                        PerformanceGraphicsDiagnostics.shared.metalFullChartFailure()
                        self?.fail(record: false)
                    }
                }
            }
            buffer.present(drawable)
            buffer.commit()
            needsRedraw = false
            PerformanceGraphicsDiagnostics.shared.metalFullChartFrameSubmitted(
                lifetime.id, staticChart: !scene.primitives.isEmpty,
                arrival: content.arrivalBursts > 0, completion: content.completionEffects > 0,
                twinkle: content.twinkles > 0)
        } catch {
            // An encoder may already have registered a resource lease. Commit
            // the unpresented buffer so its completion can release that lease.
            buffer.addCompletedHandler { _ in lifetime.finish() }
            buffer.commit()
            fail()
        }
    }

    private func fail(record: Bool = true) {
        guard !failed, !stopped else { return }
        if record { PerformanceGraphicsDiagnostics.shared.metalFullChartFailure(lifetime?.id) }
        failed = true
        scheduler.stop(at: Date())
        cancelWake()
        releaseResources()
        if let onFailure {
            // Setup may fail inside NSViewRepresentable.updateNSView. Defer the
            // one fallback publication until that SwiftUI update has finished.
            Task { @MainActor in onFailure() }
        }
    }

    private func releaseResources() {
        retainedTwinkleView?.stop()
        retainedTwinkleView?.removeFromSuperview()
        retainedTwinkleView = nil
        metalView?.isPaused = true
        metalView?.delegate = nil
        metalView?.releaseDrawables()
        metalView?.device = nil
        metalView?.removeFromSuperview()
        metalView = nil
        renderer?.removeAll()
        cursorRenderer?.removeAll()
        effectsRenderer?.removeAll()
        staticCache?.removeAll()
        // In-flight command buffers can still hold old cache textures. The
        // diagnostic host remains alive until those frame leases drain.
        PerformanceGraphicsDiagnostics.shared.metalFullChartTexturesRetained(
            lifetime?.id, bytes: UInt64(staticCache?.statistics.retainedBytes ?? 0))
        staticCache = nil
        drawingScale = nil
        renderer = nil
        cursorRenderer = nil
        effectsRenderer = nil
        queue = nil
        lifetime?.close()
        lifetime = nil
        uploadedEffects = []
        needsStaticUpload = true
        needsCursorUpload = true
        needsRedraw = true
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        scheduler.stop(at: Date())
        cancelWake()
        NotificationCenter.default.removeObserver(self)
        releaseResources()
        scene = nil
        cursor = nil
        input = nil
        onFailure = nil
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        wake?.cancel()
        metalView?.isPaused = true
        metalView?.delegate = nil
        retainedTwinkleView?.stop()
        staticCache?.removeAll()
        lifetime?.close()
    }
}
