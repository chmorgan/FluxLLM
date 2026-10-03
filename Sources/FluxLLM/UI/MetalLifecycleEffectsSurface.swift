import AppKit
import MetalKit
import SwiftUI

/// A transparent, cropped effect surface. Publications replace immutable
/// episode descriptors; the native frame clock changes only a time uniform.
struct MetalLifecycleEffectsSurface: NSViewRepresentable {
    struct Effect: Equatable {
        let id: RequestRailLifecycleEffects.Key
        let startDate: Date
        let expiresAt: Date
        let profile: RequestRailEffectProfile
        let rect: CGRect
        let cornerRadius: CGFloat
        let color: SIMD4<Float>

        var visibleUntil: Date {
            min(expiresAt, startDate.addingTimeInterval(profile.visibleDuration))
        }
    }

    struct Twinkle: Equatable {
        let twinkle: RequestRailTwinkle
        let placement: RequestRailTwinkle.Placement
        let color: SIMD4<Float>
    }

    enum Element: Equatable {
        case effect(Effect)
        case twinkle(Twinkle)

        var startsAt: Date {
            switch self {
            case .effect(let effect): effect.startDate
            case .twinkle(let twinkle): twinkle.twinkle.startedAt
            }
        }

        var visibleUntil: Date {
            switch self {
            case .effect(let effect): effect.visibleUntil
            case .twinkle(let twinkle): twinkle.twinkle.endsAt
            }
        }

        func isActiveLifecycle(at date: Date) -> Bool {
            guard case .effect = self else { return false }
            return date >= startsAt && date < visibleUntil
        }

        @MainActor
        func rendererElement(relativeTo anchor: Date) -> MetalPrimitiveEffectsRenderer.Element {
            switch self {
            case .effect(let effect):
                .effect(
                    .init(
                        id: effect.id, startTime: effect.startDate.timeIntervalSince(anchor),
                        profile: effect.profile, rect: effect.rect,
                        cornerRadius: effect.cornerRadius,
                        color: effect.color))
            case .twinkle(let twinkle):
                .twinkle(
                    .init(
                        twinkle: twinkle.twinkle, placement: twinkle.placement,
                        startTime: twinkle.twinkle.startedAt.timeIntervalSince(anchor),
                        color: twinkle.color))
            }
        }
    }

    let elements: [Element]
    let drawingBounds: CGRect
    var isValid = true
    let onFailure: @MainActor () -> Void
    @Environment(\.displayScale) private var displayScale

    func makeNSView(context: Context) -> MetalLifecycleEffectsView {
        let view = MetalLifecycleEffectsView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MetalLifecycleEffectsView, context: Context) {
        view.update(
            elements: elements, drawingBounds: drawingBounds, scale: displayScale,
            isValid: isValid, onFailure: onFailure)
    }

    static func dismantleNSView(_ view: MetalLifecycleEffectsView, coordinator: ()) { view.stop() }
}

/// The Canvas draws segment -> lifecycle effects -> glints. Keep that exact
/// order when overlapping requests share this surface, including completions.
enum MetalLifecycleEffectsInput {
    @MainActor
    static func elements(
        segments: [RequestRailGeometry.Segment], prepared: [RequestRailLifecycleEffects.Prepared],
        eligibleIDs: [RequestRailEvent.ID], twinkles: [RequestRailTwinkle],
        now: Date, duration: TimeInterval, rail: CGRect,
        color: (RequestLane) -> SIMD4<Float>?
    ) -> [MetalLifecycleEffectsSurface.Element]? {
        // Ordinary glints are owned by retained layers between lifecycle
        // episodes. They must not upload a Metal descriptor or acquire frames.
        guard prepared.contains(where: { eligibleIDs.contains($0.key.eventID) }) else { return [] }
        var result: [MetalLifecycleEffectsSurface.Element] = []
        for segment in segments {
            guard let color = color(segment.lane) else { return nil }
            for effect in prepared where effect.key.requestID == segment.lane.id {
                guard eligibleIDs.contains(effect.key.eventID),
                    effect.profile.completion
                        || segment.lane.startedAt >= now.addingTimeInterval(-duration)
                else { continue }
                result.append(
                    .effect(
                        .init(
                            id: effect.key, startDate: effect.startedAt,
                            expiresAt: effect.expiresAt, profile: effect.profile,
                            rect: segment.rect,
                            cornerRadius: segment.cornerRadius, color: color)))
            }
            if segment.isLive {
                for twinkle in twinkles where twinkle.requestID == segment.lane.id {
                    if let placement = twinkle.placement(
                        segment: segment, now: now, duration: duration, rail: rail)
                    {
                        result.append(
                            .twinkle(.init(twinkle: twinkle, placement: placement, color: color)))
                    }
                }
            }
        }
        return result.contains(where: {
            if case .effect = $0 { return true }
            return false
        }) ? result : []
    }

    static func nextBoundary(
        elements: [MetalLifecycleEffectsSurface.Element], after date: Date
    ) -> Date? {
        elements.flatMap { [$0.startsAt, $0.visibleUntil] }.filter { $0 > date }.min()
    }
}

/// A diagnostic host cannot disappear before its last GPU submission. Successful
/// frame completions do not enqueue work on the main actor or retain the view.
final class MetalLifecycleFrameLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0
    private var closing = false
    private var destroyed = false
    private var retry: (@Sendable () -> Void)?
    let id: UInt64?
    private let onDestroyed: @Sendable () -> Void

    init(id: UInt64?, onDestroyed: @escaping @Sendable () -> Void) {
        self.id = id
        self.onDestroyed = onDestroyed
    }

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closing, outstanding < MetalArrivalFrameLimiter.capacity else { return false }
        outstanding += 1
        return true
    }

    func finish() {
        lock.lock()
        guard outstanding > 0 else {
            lock.unlock()
            return
        }
        outstanding -= 1
        let destroy = closing && outstanding == 0 && !destroyed
        if destroy { destroyed = true }
        let resume = outstanding == 0 && !closing ? retry : nil
        if outstanding == 0 { retry = nil }
        lock.unlock()
        if destroy { onDestroyed() }
        resume?()
    }

    func close() {
        lock.lock()
        closing = true
        retry = nil
        let destroy = outstanding == 0 && !destroyed
        if destroy { destroyed = true }
        lock.unlock()
        if destroy { onDestroyed() }
    }

    func retryWhenDrained(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let immediately = !closing && outstanding == 0
        if !closing && !immediately { retry = action }
        lock.unlock()
        if immediately { action() }
    }
}

@MainActor
final class MetalLifecycleEffectsView: NSView, MTKViewDelegate {
    private var elements: [MetalLifecycleEffectsSurface.Element] = []
    private var drawingBounds = CGRect.zero
    private var requestedScale: CGFloat = 1
    private var anchor = Date()
    private var needsUpload = true
    private var renderer: MetalPrimitiveEffectsRenderer?
    private var commandQueue: (any MTLCommandQueue)?
    private var metalView: MTKView?
    private var lifecycle = MetalArrivalSurfaceLifecycle()
    private var lifetime: MetalLifecycleFrameLifetime?
    private var boundaryTask: Task<Void, Never>?
    private var onFailure: (@MainActor () -> Void)?
    private var closing = false
    private var failed = false

    var lifecyclePhase: MetalArrivalSurfaceLifecycle.Phase { lifecycle.phase }
    var hasNativeResources: Bool { renderer != nil || metalView != nil || commandQueue != nil }
    var timeAnchor: Date { anchor }
    var hasBoundaryTask: Bool { boundaryTask != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        canDrawSubviewsIntoLayer = false
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }

    func update(
        elements: [MetalLifecycleEffectsSurface.Element], drawingBounds: CGRect,
        scale: CGFloat, isValid: Bool = true, at timestamp: Date = Date(),
        onFailure: @escaping @MainActor () -> Void = {}
    ) {
        guard lifecycle.phase != .stopped else { return }
        self.onFailure = onFailure
        guard isValid,
            elements.count <= MetalPrimitiveEffectsRenderer.maximumEffects
                + MetalPrimitiveEffectsRenderer.maximumTwinkles,
            MetalArrivalSurfaceGeometry.valid(drawingBounds), scale.isFinite, scale > 0,
            timestamp.timeIntervalSinceReferenceDate.isFinite
        else {
            fail()
            return
        }
        if self.elements != elements {
            anchor = timestamp
            needsUpload = true
        }
        self.elements = elements
        self.drawingBounds = drawingBounds
        requestedScale = scale
        reconcile(at: timestamp)
        scheduleBoundary(at: timestamp)
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
        if lifecycle.phase != .stopped, let window {
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
        scheduleBoundary(at: Date())
    }

    @objc private func windowChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification { closing = true }
        reconcile()
        scheduleBoundary(at: Date())
    }

    private var isNativelyVisible: Bool {
        guard lifecycle.phase != .stopped, !closing, !isHiddenOrHasHiddenAncestor,
            let window, window.isVisible, !window.isMiniaturized,
            window.occlusionState.contains(.visible), MetalArrivalSurfaceGeometry.valid(bounds),
            MetalArrivalSurfaceGeometry.valid(drawingBounds)
        else { return false }
        return true
    }

    private func refreshLifecycle(at date: Date) {
        lifecycle.update(
            visible: isNativelyVisible,
            activeArrival: elements.contains { $0.isActiveLifecycle(at: date) })
    }

    private func scheduleBoundary(at date: Date) {
        boundaryTask?.cancel()
        boundaryTask = nil
        guard !failed, isNativelyVisible,
            let boundary = MetalLifecycleEffectsInput.nextBoundary(elements: elements, after: date)
        else { return }
        boundaryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, boundary.timeIntervalSinceNow))) } catch
            { return }
            guard !Task.isCancelled, let self else { return }
            self.boundaryTask = nil
            self.reconcile()
            self.scheduleBoundary(at: Date())
        }
    }

    private func reconcile(at date: Date = Date()) {
        guard lifecycle.phase != .stopped else { return }
        let wasHidden = lifecycle.phase == .hidden
        refreshLifecycle(at: date)
        guard lifecycle.phase != .hidden else {
            releaseResources()
            return
        }
        guard !failed else { return }
        guard
            let size = MetalArrivalSurfaceGeometry.drawableSize(
                points: bounds.size, scale: window?.backingScaleFactor ?? requestedScale)
        else {
            fail()
            return
        }
        if renderer == nil {
            do {
                let renderer = try MetalPrimitiveEffectsRenderer()
                guard let queue = renderer.device.makeCommandQueue() else {
                    fail()
                    return
                }
                let view = MTKView(frame: bounds, device: renderer.device)
                view.isPaused = true
                view.enableSetNeedsDisplay = false
                view.preferredFramesPerSecond = 30
                view.autoResizeDrawable = false
                view.drawableSize = size
                view.colorPixelFormat = MetalPrimitiveEffectsRenderer.pixelFormat
                view.sampleCount = 1
                view.depthStencilPixelFormat = .invalid
                view.framebufferOnly = true
                view.clearColor = MTLClearColorMake(0, 0, 0, 0)
                view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
                view.layer?.isOpaque = false
                if let layer = view.layer as? CAMetalLayer {
                    layer.maximumDrawableCount = MetalArrivalFrameLimiter.capacity
                    layer.allowsNextDrawableTimeout = true
                    layer.backgroundColor = CGColor(gray: 0, alpha: 0)
                }
                let id = PerformanceGraphicsDiagnostics.shared.metalPrimitiveEffectsHostCreated()
                lifetime = MetalLifecycleFrameLifetime(id: id) {
                    Task { @MainActor in
                        PerformanceGraphicsDiagnostics.shared.metalPrimitiveEffectsHostDestroyed(id)
                    }
                }
                self.renderer = renderer
                commandQueue = queue
                metalView = view
                view.delegate = self
                addSubview(view)
                needsUpload = true
            } catch {
                fail()
                return
            }
        }
        guard let view = metalView, let renderer else { return }
        if view.frame != bounds { view.frame = bounds }
        if view.drawableSize != size { view.drawableSize = size }
        let visible = elements.filter { $0.visibleUntil > date }
        if elements != visible {
            elements = visible
            needsUpload = true
        }
        if needsUpload {
            do {
                let previous = renderer.statistics.descriptorUploads
                try renderer.update(
                    elements: elements.map { $0.rendererElement(relativeTo: anchor) })
                if renderer.statistics.descriptorUploads != previous {
                    PerformanceGraphicsDiagnostics.shared.metalPrimitiveEffectsDescriptorsUploaded(
                        lifetime?.id, bytes: retainedBufferBytes)
                }
                needsUpload = false
            } catch {
                fail()
                return
            }
        }
        if wasHidden { scheduleBoundary(at: date) }
        if view.isPaused != (lifecycle.phase != .active) {
            view.isPaused = lifecycle.phase != .active
        }
        if lifecycle.needsClear { view.draw() }
    }

    private var retainedBufferBytes: UInt64 {
        guard let stats = renderer?.statistics else { return 0 }
        return UInt64(stats.retainedDescriptorBytes + stats.retainedFrameBytes)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard view === metalView, !failed, lifecycle.phase != .stopped else { return }
        let now = Date()
        refreshLifecycle(at: now)
        guard lifecycle.phase != .hidden else {
            releaseResources()
            return
        }
        let active = lifecycle.phase == .active
        if view.isPaused != !active { view.isPaused = !active }
        guard active || lifecycle.needsClear, let renderer, let commandQueue, let lifetime else {
            return
        }
        guard lifetime.begin() else {
            if active {
                PerformanceGraphicsDiagnostics.shared.metalPrimitiveEffectsFrameSkipped(lifetime.id)
            } else {
                lifetime.retryWhenDrained { [weak self] in
                    Task { @MainActor in self?.reconcile() }
                }
            }
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let drawable = view.currentDrawable
        else {
            lifetime.finish()
            fail()
            return
        }
        var content: MetalPrimitiveEffectsRenderer.EncodedContent?
        var encodingFailed = false
        do {
            if active {
                if elements.contains(where: { $0.visibleUntil <= now }) {
                    let visible = elements.filter { $0.visibleUntil > now }
                    elements = visible
                    try renderer.update(
                        elements: visible.map { $0.rendererElement(relativeTo: anchor) })
                    PerformanceGraphicsDiagnostics.shared.metalPrimitiveEffectsDescriptorsUploaded(
                        lifetime.id, bytes: retainedBufferBytes)
                    scheduleBoundary(at: now)
                }
                content = try renderer.encode(
                    into: commandBuffer, target: drawable.texture,
                    elapsedTime: now.timeIntervalSince(anchor), pointSize: drawingBounds.size,
                    origin: drawingBounds.origin, clear: true)
            } else {
                let pass = MTLRenderPassDescriptor()
                let attachment = pass.colorAttachments[0]!
                attachment.texture = drawable.texture
                attachment.loadAction = .clear
                attachment.storeAction = .store
                attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                    throw MetalPrimitiveEffectsRenderer.RendererError.encoderUnavailable
                }
                encoder.endEncoding()
                renderer.removeAll()
                needsUpload = true
            }
            PerformanceGraphicsDiagnostics.shared.metalPrimitiveEffectsBuffersRetained(
                lifetime.id, bytes: retainedBufferBytes)
        } catch {
            // An encode may already hold GPU leases. Commit even a partial
            // command so ownership is released by its completion handler.
            encodingFailed = true
        }
        let generation = lifecycle.generation
        let clearRevision = active || encodingFailed ? nil : lifecycle.beginClear()
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let success = buffer.status == .completed && buffer.error == nil
            lifetime.finish()
            guard clearRevision != nil || !success else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.failed, self.lifetime === lifetime,
                    self.lifecycle.generation == generation,
                    self.lifecycle.phase != .stopped
                else {
                    if !success {
                        PerformanceGraphicsDiagnostics.shared.metalPrimitiveEffectsFailure()
                    }
                    return
                }
                guard success else {
                    self.fail()
                    return
                }
                if let clearRevision {
                    self.lifecycle.completedClear(
                        clearRevision, generation: generation, success: true)
                    PerformanceGraphicsDiagnostics.shared.metalPrimitiveEffectsBuffersRetained(
                        lifetime.id, bytes: self.retainedBufferBytes)
                }
                if self.lifecycle.needsClear { self.metalView?.draw() }
            }
        }
        if !encodingFailed {
            commandBuffer.present(drawable)
            if active { lifecycle.submittedArrival() }
            PerformanceGraphicsDiagnostics.shared.metalPrimitiveEffectsFrameSubmitted(
                lifetime.id, arrival: (content?.arrivalBursts ?? 0) > 0,
                completion: (content?.completionEffects ?? 0) > 0,
                twinkle: (content?.twinkles ?? 0) > 0, clear: !active)
        }
        commandBuffer.commit()
        if encodingFailed { fail() }
    }

    private func fail() {
        guard !failed else { return }
        failed = true
        lifecycle.update(visible: false, activeArrival: false)
        PerformanceGraphicsDiagnostics.shared.metalPrimitiveEffectsFailure(lifetime?.id)
        PerformanceGraphicsDiagnostics.shared.metalPrimitiveEffectsFallback()
        let callback = onFailure
        releaseResources()
        // Failure can occur during updateNSView. Publish fallback after that
        // update completes; the fallback remains sticky for this chart host.
        Task { @MainActor in callback?() }
    }

    private func releaseResources() {
        boundaryTask?.cancel()
        boundaryTask = nil
        if let view = metalView, !view.isPaused { view.isPaused = true }
        metalView?.delegate = nil
        metalView?.releaseDrawables()
        metalView?.device = nil
        metalView?.removeFromSuperview()
        metalView = nil
        renderer?.removeAll()
        renderer = nil
        commandQueue = nil
        lifetime?.close()
        lifetime = nil
        needsUpload = true
    }

    func stop() {
        lifecycle.stop()
        NotificationCenter.default.removeObserver(self)
        releaseResources()
        elements = []
        onFailure = nil
    }

    deinit {
        boundaryTask?.cancel()
        lifetime?.close()
        let view = metalView
        NotificationCenter.default.removeObserver(self)
        MainActor.assumeIsolated {
            if let view, !view.isPaused { view.isPaused = true }
            view?.delegate = nil
        }
    }
}
