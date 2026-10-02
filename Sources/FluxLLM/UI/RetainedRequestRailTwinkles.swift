import AppKit
import QuartzCore
import SwiftUI

/// Receives the same bounded twinkle instances as the Canvas control. Only
/// spawn/expiry and chart publication updates cross SwiftUI; Core Animation
/// interpolates the two small shapes between those updates.
struct RetainedRequestRailTwinkles: NSViewRepresentable {
    let twinkles: [RequestRailTwinkle]
    let segments: [RequestRailGeometry.Segment]
    let now: Date
    let duration: TimeInterval
    let rail: CGRect
    let color: (RequestLane) -> Color
    @Environment(\.displayScale) private var displayScale

    func makeNSView(context: Context) -> RetainedRequestRailTwinkleView {
        let view = RetainedRequestRailTwinkleView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RetainedRequestRailTwinkleView, context: Context) {
        let descriptors = twinkles.suffix(2).compactMap { twinkle -> RetainedTwinkleDescriptor? in
            guard
                let segment = segments.first(where: { $0.lane.id == twinkle.requestID && $0.isLive }
                ),
                let placement = twinkle.placement(
                    segment: segment, now: now, duration: duration, rail: rail)
            else { return nil }
            return RetainedTwinkleDescriptor(
                twinkle: twinkle, placement: placement,
                color: NSColor(color(segment.lane)).cgColor)
        }
        view.update(descriptors: descriptors, scale: displayScale)
    }

    static func dismantleNSView(_ view: RetainedRequestRailTwinkleView, coordinator: ()) {
        view.stop()
    }
}

struct RetainedTwinkleDescriptor {
    let twinkle: RequestRailTwinkle
    let placement: RequestRailTwinkle.Placement
    let color: CGColor
}

/// A single instance owns just a rounded clip and two fixed vector shapes.
/// Separate shape opacities preserve the original source-over overlap; fading
/// a precomposited parent would change the colored halo under the white mark.
@MainActor
final class RetainedTwinkleLayerGroup {
    static let keyframeIntervals = 64
    let id: RequestRailTwinkle.ID
    let clip = CALayer()
    let ellipse = CAShapeLayer()
    let mark = CAShapeLayer()
    private(set) var animationInstallations: UInt64 = 0
    private struct Shape: Equatable {
        let size: Double
        let angle: Double
        let star: Bool
        let height: CGFloat
    }
    private var shape: Shape?

    init(descriptor: RetainedTwinkleDescriptor, surfaceHeight: CGFloat, scale: CGFloat) {
        id = descriptor.twinkle.id
        clip.masksToBounds = true
        clip.cornerCurve = .circular
        ellipse.fillRule = .nonZero
        mark.fillRule = .nonZero
        mark.fillColor = CGColor(gray: 1, alpha: 1)
        // Finished animations return to invisible model values even before the
        // scheduler next removes their instances. No completion callback loop.
        ellipse.opacity = 0
        mark.opacity = 0
        clip.addSublayer(ellipse)
        clip.addSublayer(mark)
        update(descriptor: descriptor, surfaceHeight: surfaceHeight, scale: scale)
    }

    func update(descriptor: RetainedTwinkleDescriptor, surfaceHeight: CGFloat, scale: CGFloat) {
        let twinkle = descriptor.twinkle
        let placement = descriptor.placement
        let bar = placement.bar
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // The AppKit host uses Quartz's bottom-left origin; the shared model
        // uses the original chart's top-left coordinates.
        let frame = CGRect(
            x: bar.minX, y: surfaceHeight - bar.maxY,
            width: bar.width, height: bar.height)
        if clip.frame != frame { clip.frame = frame }
        if clip.cornerRadius != placement.cornerRadius {
            clip.cornerRadius = placement.cornerRadius
        }
        let point = CGPoint(x: placement.center.x - bar.minX, y: bar.maxY - placement.center.y)
        if ellipse.position != point { ellipse.position = point }
        if mark.position != point { mark.position = point }
        for layer in [clip, ellipse, mark] where layer.contentsScale != scale {
            layer.contentsScale = scale
        }
        let nextShape = Shape(
            size: twinkle.size, angle: twinkle.angle, star: twinkle.star, height: bar.height)
        if shape != nextShape {
            let halfWidth = CGFloat(twinkle.size) * 2.1
            ellipse.bounds = CGRect(
                x: -halfWidth, y: -bar.height / 2,
                width: halfWidth * 2, height: bar.height)
            ellipse.path = CGPath(ellipseIn: ellipse.bounds, transform: nil)
            let radius = CGFloat(twinkle.size)
            mark.bounds = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
            var flip = CGAffineTransform(scaleX: 1, y: -1)
            mark.path = twinkle.markPath(at: .zero).cgPath.copy(using: &flip)
            shape = nextShape
        }
        let color = descriptor.color.copy(alpha: descriptor.color.alpha * 0.32)
        if let color, ellipse.fillColor.map({ !CFEqual($0, color) }) ?? true {
            ellipse.fillColor = color
        }
    }

    /// Called once after attachment, never on ordinary position/color updates.
    /// Animation clocks are anchored to the original instance age.
    @discardableResult
    func installAnimations(for twinkle: RequestRailTwinkle, at now: Date, mediaTime: CFTimeInterval)
        -> UInt64
    {
        guard animationInstallations == 0, twinkle.duration.isFinite, twinkle.duration > 0 else {
            return 0
        }
        let age = now.timeIntervalSince(twinkle.startedAt)
        guard age.isFinite, age >= 0, age < twinkle.duration else { return 0 }
        let strength = (0...Self.keyframeIntervals).map { index -> NSNumber in
            let progress = Double(index) / Double(Self.keyframeIntervals)
            return NSNumber(value: pow(sin(.pi * progress), 2))
        }
        let scale = strength.map { NSNumber(value: 0.7 + 0.3 * $0.doubleValue) }
        let times = (0...Self.keyframeIntervals).map {
            NSNumber(value: Double($0) / Double(Self.keyframeIntervals))
        }
        func install(_ values: [NSNumber], key: String, on layer: CALayer) {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.keyTimes = times
            animation.calculationMode = .linear
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.duration = twinkle.duration
            animation.beginTime = layer.convertTime(mediaTime, from: nil) - age
            animation.isRemovedOnCompletion = true
            layer.add(animation, forKey: key)
        }
        install(strength, key: "opacity", on: ellipse)
        install(scale, key: "transform.scale.x", on: ellipse)
        install(strength, key: "opacity", on: mark)
        install(scale, key: "transform.scale", on: mark)
        animationInstallations = 4
        return 4
    }

    func stop() {
        ellipse.removeAllAnimations()
        mark.removeAllAnimations()
        clip.removeFromSuperlayer()
    }
}

@MainActor
final class RetainedRequestRailTwinkleView: NSView {
    private var descriptors: [RetainedTwinkleDescriptor] = []
    private var requestedScale: CGFloat = 1
    private var groups: [RequestRailTwinkle.ID: RetainedTwinkleLayerGroup] = [:]
    private var diagnosticID: UInt64?
    private var closing = false
    private var stopped = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        canDrawSubviewsIntoLayer = false
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func updateLayer() {}

    func update(descriptors: [RetainedTwinkleDescriptor], scale: CGFloat) {
        guard !stopped else { return }
        self.descriptors = Array(descriptors.suffix(2))
        requestedScale = scale.isFinite && scale > 0 ? scale : 1
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

    private func reconcile() {
        guard !stopped, !closing, !isHiddenOrHasHiddenAncestor,
            let window, window.isVisible, !window.isMiniaturized,
            window.occlusionState.contains(.visible), let layer,
            bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0
        else {
            releaseHost()
            return
        }
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        if diagnosticID == nil { diagnosticID = diagnostics.retainedTwinkleHostCreated() }
        let now = Date()
        let mediaTime = CACurrentMediaTime()
        let scale =
            window.backingScaleFactor.isFinite && window.backingScaleFactor > 0
            ? window.backingScaleFactor : requestedScale
        let eligible = descriptors.filter {
            $0.twinkle.startedAt <= now && $0.twinkle.endsAt > now
        }
        let identities = Set(eligible.map { $0.twinkle.id })
        for id in Array(groups.keys) where !identities.contains(id) {
            groups.removeValue(forKey: id)?.stop()
        }
        var started: UInt64 = 0
        for descriptor in eligible {
            let id = descriptor.twinkle.id
            if let group = groups[id] {
                group.update(descriptor: descriptor, surfaceHeight: bounds.height, scale: scale)
            } else {
                let group = RetainedTwinkleLayerGroup(
                    descriptor: descriptor,
                    surfaceHeight: bounds.height, scale: scale)
                layer.addSublayer(group.clip)
                let installed = group.installAnimations(
                    for: descriptor.twinkle, at: now, mediaTime: mediaTime)
                guard installed > 0 else {
                    group.stop()
                    continue
                }
                groups[id] = group
                started += installed
            }
        }
        diagnostics.retainedTwinkleHostUpdated(
            diagnosticID,
            instances: Set(groups.keys.map(AnyHashable.init)), animationsStarted: started)
    }

    private func releaseHost() {
        for group in groups.values { group.stop() }
        groups.removeAll(keepingCapacity: false)
        PerformanceGraphicsDiagnostics.shared.retainedTwinkleHostDestroyed(diagnosticID)
        diagnosticID = nil
    }

    func stop() {
        stopped = true
        NotificationCenter.default.removeObserver(self)
        releaseHost()
        descriptors = []
    }

    deinit {
        let id = diagnosticID
        let retainedGroups = Array(groups.values)
        MainActor.assumeIsolated {
            for group in retainedGroups { group.stop() }
            PerformanceGraphicsDiagnostics.shared.retainedTwinkleHostDestroyed(id)
        }
        NotificationCenter.default.removeObserver(self)
    }
}
