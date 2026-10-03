import AppKit
import MetalKit
import SwiftUI

/// Diagnostic GPU destination. SwiftUI publishes source descriptors; MetalKit
/// advances only the time uniform while a real arrival is visible.
struct MetalArrivalBurstSurface: NSViewRepresentable {
    struct Burst: Equatable {
        let id: RequestRailLifecycleEffects.Key
        let startDate: Date
        let profile: RequestRailEffectProfile
        let origin: CGPoint
        let color: SIMD4<Float>
    }

    struct Twinkle: Equatable {
        let twinkle: RequestRailTwinkle
        let placement: RequestRailTwinkle.Placement
        let color: SIMD4<Float>
    }

    enum Element: Equatable {
        case burst(Burst)
        case twinkle(Twinkle)

        func isActiveArrival(at date: Date) -> Bool {
            guard case .burst(let burst) = self, !burst.profile.completion else { return false }
            let age = date.timeIntervalSince(burst.startDate)
            return age.isFinite && age >= 0 && age < burst.profile.burstDuration
        }

        @MainActor
        func rendererElement(relativeTo anchor: Date) -> MetalArrivalBurstRenderer.Element {
            switch self {
            case .burst(let burst):
                return .burst(
                    .init(
                        id: burst.id, startTime: burst.startDate.timeIntervalSince(anchor),
                        profile: burst.profile, origin: burst.origin, color: burst.color))
            case .twinkle(let twinkle):
                return .twinkle(
                    .init(
                        twinkle: twinkle.twinkle, placement: twinkle.placement,
                        startTime: twinkle.twinkle.startedAt.timeIntervalSince(anchor),
                        color: twinkle.color))
            }
        }
    }

    let elements: [Element]
    let drawingBounds: CGRect
    @Environment(\.displayScale) private var displayScale

    func makeNSView(context: Context) -> MetalArrivalBurstView {
        let view = MetalArrivalBurstView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MetalArrivalBurstView, context: Context) {
        view.update(elements: elements, drawingBounds: drawingBounds, scale: displayScale)
    }

    static func dismantleNSView(_ view: MetalArrivalBurstView, coordinator: ()) {
        view.stop()
    }
}

/// Pure lifecycle bookkeeping, also exercised without opening a native window.
/// A clear acknowledges only the content preceding it, never a newer arrival.
struct MetalArrivalSurfaceLifecycle {
    enum Phase: Equatable { case hidden, idle, active, stopped }
    private(set) var phase: Phase = .hidden
    private(set) var generation: UInt64 = 0
    private var submittedRevision: UInt64 = 0
    private var clearedRevision: UInt64 = 0
    private var clearingRevision: UInt64?

    var needsClear: Bool {
        phase == .idle && submittedRevision > clearedRevision && clearingRevision == nil
    }

    mutating func update(visible: Bool, activeArrival: Bool) {
        guard phase != .stopped else { return }
        if !visible {
            if phase != .hidden { generation &+= 1 }
            phase = .hidden
            submittedRevision = 0
            clearedRevision = 0
            clearingRevision = nil
        } else {
            if phase == .hidden { generation &+= 1 }
            phase = activeArrival ? .active : .idle
        }
    }

    mutating func submittedArrival() {
        guard phase == .active else { return }
        submittedRevision &+= 1
    }

    mutating func beginClear() -> UInt64? {
        guard needsClear else { return nil }
        clearingRevision = submittedRevision
        return submittedRevision
    }

    mutating func completedClear(_ revision: UInt64, generation: UInt64, success: Bool) {
        guard self.generation == generation, clearingRevision == revision else { return }
        clearingRevision = nil
        if success { clearedRevision = max(clearedRevision, revision) }
    }

    mutating func stop() {
        update(visible: false, activeArrival: false)
        generation &+= 1
        phase = .stopped
    }
}

/// Reservations never wait for the GPU. Command completion releases its own
/// ticket even after its view or renderer has been destroyed.
final class MetalArrivalFrameLimiter: @unchecked Sendable {
    static let capacity = 2
    private let lock = NSLock()
    private var nextTicket: UInt64 = 0
    private var tickets: Set<UInt64> = []

    var inFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return tickets.count
    }

    func begin() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard tickets.count < Self.capacity else { return nil }
        nextTicket &+= 1
        tickets.insert(nextTicket)
        return nextTicket
    }

    @discardableResult
    func finish(_ ticket: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tickets.remove(ticket) != nil
    }
}

enum MetalArrivalSurfaceGeometry {
    // Two bounded drawables; no depth or multisample attachments are requested.
    static let maximumDrawableBytes = 32 * 1_024 * 1_024

    static func drawableSize(points: CGSize, scale: CGFloat) -> CGSize? {
        guard points.width.isFinite, points.height.isFinite,
            points.width > 0, points.height > 0, scale.isFinite, scale > 0
        else { return nil }
        let width = ceil(points.width * scale)
        let height = ceil(points.height * scale)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
            width <= 16_384, height <= 16_384,
            width <= CGFloat(maximumDrawableBytes / 4) / height
        else { return nil }
        return CGSize(width: width, height: height)
    }

    static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }
}

/// The host releases the MTKView and its CAMetalLayer when hidden. Calling
/// releaseDrawables alone would not establish swap-chain ownership release.
@MainActor
final class MetalArrivalBurstView: NSView, MTKViewDelegate {
    private var elements: [MetalArrivalBurstSurface.Element] = []
    private var drawingBounds = CGRect.zero
    private var requestedScale: CGFloat = 1
    private var anchor = Date()
    private var needsUpload = true
    private var renderer: MetalArrivalBurstRenderer?
    private var metalView: MTKView?
    private var lifecycle = MetalArrivalSurfaceLifecycle()
    private let limiter = MetalArrivalFrameLimiter()
    private var closing = false
    private var failed = false
    private var hasAcquiredDrawable = false

    var lifecyclePhase: MetalArrivalSurfaceLifecycle.Phase { lifecycle.phase }
    var hasNativeResources: Bool { renderer != nil || metalView != nil }
    var timeAnchor: Date { anchor }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        canDrawSubviewsIntoLayer = false
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }

    func update(
        elements: [MetalArrivalBurstSurface.Element], drawingBounds: CGRect, scale: CGFloat,
        at timestamp: Date = Date()
    ) {
        guard lifecycle.phase != .stopped else { return }
        guard
            elements.count <= MetalArrivalBurstRenderer.maximumBursts
                + MetalArrivalBurstRenderer.maximumTwinkles,
            MetalArrivalSurfaceGeometry.valid(drawingBounds), scale.isFinite, scale > 0,
            timestamp.timeIntervalSinceReferenceDate.isFinite
        else {
            fail()
            return
        }
        if self.elements != elements {
            // Rebase each changed publication, not the host's lifetime. Even a
            // window left idle for days gets submillisecond burst time values.
            anchor = timestamp
            needsUpload = true
        }
        self.elements = elements
        self.drawingBounds = drawingBounds
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

    @objc private func windowChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification {
            closing = true
        } else if notification.name == NSWindow.didExposeNotification
            || notification.name == NSWindow.didChangeOcclusionStateNotification
        {
            if let window, window.isVisible, window.occlusionState.contains(.visible) {
                closing = false
            }
        }
        reconcile()
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
            activeArrival: elements.contains { $0.isActiveArrival(at: date) })
    }

    private func reconcile() {
        guard lifecycle.phase != .stopped else { return }
        refreshLifecycle(at: Date())
        guard lifecycle.phase != .hidden else {
            releaseResources()
            failed = false
            return
        }
        guard !failed else { return }
        let scale = window?.backingScaleFactor ?? requestedScale
        guard let size = MetalArrivalSurfaceGeometry.drawableSize(points: bounds.size, scale: scale)
        else {
            fail()
            return
        }
        if renderer == nil {
            let diagnostics = PerformanceArrivalDiagnostics.shared
            let measurement = diagnostics.begin(.metalSurfaceSetup)
            defer { diagnostics.end(measurement) }
            do {
                // Pipeline compilation occurs on visible idle, before an arrival
                // needs frames. No draw loop runs until a real arrival is active.
                let renderer = try MetalArrivalBurstRenderer()
                let view = MTKView(frame: bounds, device: renderer.device)
                view.isPaused = true
                view.enableSetNeedsDisplay = false
                view.preferredFramesPerSecond = 30
                view.autoResizeDrawable = false
                view.drawableSize = size
                view.colorPixelFormat = MetalArrivalBurstRenderer.pixelFormat
                view.sampleCount = 1
                view.depthStencilPixelFormat = .invalid
                view.framebufferOnly = true
                view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
                view.layer?.isOpaque = false
                if let layer = view.layer as? CAMetalLayer {
                    layer.maximumDrawableCount = MetalArrivalFrameLimiter.capacity
                    layer.allowsNextDrawableTimeout = true
                    layer.backgroundColor = CGColor(gray: 0, alpha: 0)
                }
                self.renderer = renderer
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
        if needsUpload {
            do {
                try renderer.update(
                    elements: elements.map { $0.rendererElement(relativeTo: anchor) })
                needsUpload = false
            } catch {
                fail()
                return
            }
        }
        let paused = lifecycle.phase != .active
        if view.isPaused != paused { view.isPaused = paused }
        if lifecycle.needsClear { view.draw() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let diagnostics = PerformanceArrivalDiagnostics.shared
        let callback = diagnostics.begin(.metalFrameCallback)
        defer { diagnostics.end(callback) }
        guard view === metalView, !failed, lifecycle.phase != .stopped else { return }
        let now = Date()
        refreshLifecycle(at: now)
        guard lifecycle.phase != .hidden else {
            releaseResources()
            return
        }
        let active = lifecycle.phase == .active
        let paused = !active
        if view.isPaused != paused { view.isPaused = paused }
        guard active || lifecycle.needsClear, let renderer else { return }
        guard let ticket = limiter.begin() else {
            // A final clear can wait for completion without keeping a timer
            // alive. Missing an active frame invalidates performance evidence.
            if active { PerformancePresentationCounters.shared.record(.metalArrivalFailures) }
            return
        }
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            limiter.finish(ticket)
            fail()
            return
        }
        let acquisition = diagnostics.begin(
            hasAcquiredDrawable ? .metalLaterDrawable : .metalFirstDrawable)
        let acquired = view.currentDrawable
        diagnostics.end(acquisition)
        guard let drawable = acquired else {
            limiter.finish(ticket)
            fail()
            return
        }
        hasAcquiredDrawable = true
        do {
            let measurement = diagnostics.begin(active ? .metalFrameEncode : .metalClear)
            defer { diagnostics.end(measurement) }
            if active {
                try renderer.encode(
                    into: commandBuffer, target: drawable.texture,
                    elapsedTime: now.timeIntervalSince(anchor), pointSize: drawingBounds.size,
                    origin: drawingBounds.origin)
            } else {
                let pass = MTLRenderPassDescriptor()
                let attachment = pass.colorAttachments[0]!
                attachment.texture = drawable.texture
                attachment.loadAction = .clear
                attachment.storeAction = .store
                attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                    throw MetalArrivalBurstRenderer.RendererError.encoderUnavailable
                }
                encoder.endEncoding()
            }
        } catch {
            limiter.finish(ticket)
            fail()
            return
        }
        let generation = lifecycle.generation
        let clearRevision = active ? nil : lifecycle.beginClear()
        let limiter = limiter
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let completion = diagnostics.begin(.metalCompletionCallback)
            defer { diagnostics.end(completion) }
            limiter.finish(ticket)
            let success = buffer.status == .completed && buffer.error == nil
            if !success { PerformancePresentationCounters.shared.record(.metalArrivalFailures) }
            Task { @MainActor [weak self] in
                let measurement = diagnostics.begin(.metalCompletionMainActor)
                defer { diagnostics.end(measurement) }
                guard let self, self.lifecycle.generation == generation,
                    self.lifecycle.phase != .stopped
                else { return }
                if let clearRevision {
                    self.lifecycle.completedClear(
                        clearRevision, generation: generation, success: success)
                }
                guard success else {
                    self.failed = true
                    self.releaseResources()
                    return
                }
                if self.lifecycle.needsClear { self.metalView?.draw() }
            }
        }
        let submission = diagnostics.begin(.metalFrameSubmit)
        commandBuffer.present(drawable)
        if active { lifecycle.submittedArrival() }
        commandBuffer.commit()
        diagnostics.end(submission)
        if active {
            PerformancePresentationCounters.shared.record(.metalArrivalFrames)
            PerformancePresentationCounters.shared.record(.metalArrivalSubmissions)
        }
    }

    private func fail() {
        PerformancePresentationCounters.shared.record(.metalArrivalFailures)
        failed = true
        releaseResources()
    }

    private func releaseResources() {
        if let view = metalView, !view.isPaused { view.isPaused = true }
        metalView?.delegate = nil
        metalView?.releaseDrawables()
        metalView?.device = nil
        metalView?.removeFromSuperview()
        metalView = nil
        renderer?.removeAll()
        renderer = nil
        needsUpload = true
        hasAcquiredDrawable = false
    }

    func stop() {
        lifecycle.stop()
        NotificationCenter.default.removeObserver(self)
        releaseResources()
        elements = []
    }

    deinit {
        let view = metalView
        NotificationCenter.default.removeObserver(self)
        // MTKView owns its timer. Break delegate/loop ownership before the
        // AppKit subtree disappears; outstanding GPU leases release separately.
        MainActor.assumeIsolated {
            if let view, !view.isPaused { view.isPaused = true }
            view?.delegate = nil
        }
    }
}
