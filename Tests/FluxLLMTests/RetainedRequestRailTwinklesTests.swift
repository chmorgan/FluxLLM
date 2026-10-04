import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class RetainedRequestRailTwinklesTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnimationUsesOriginalAgeAndSeparateOpacityWithoutRestartingForGeometryUpdates() throws
    {
        let descriptor = descriptor(centerX: 45)
        let group = RetainedTwinkleLayerGroup(descriptor: descriptor, surfaceHeight: 60, scale: 2)
        let parent = CALayer()
        parent.addSublayer(group.clip)
        XCTAssertEqual(
            group.installAnimations(
                for: descriptor.twinkle,
                at: origin.addingTimeInterval(0.2), mediaTime: 100), 4)
        XCTAssertEqual(group.ellipse.opacity, 0)
        XCTAssertEqual(group.mark.opacity, 0)
        XCTAssertEqual(group.clip.opacity, 1, "Parent opacity must not alter source-over overlap")
        let opacity = try animation("opacity", on: group.mark)
        XCTAssertEqual(opacity.beginTime, 99.8, accuracy: 0.000001)
        XCTAssertEqual(opacity.duration, descriptor.twinkle.duration)
        XCTAssertTrue(opacity.isRemovedOnCompletion)
        let ellipseScale = try animation("transform.scale.x", on: group.ellipse)
        let markScale = try animation("transform.scale", on: group.mark)
        for progress in [0.0, 0.1, 0.25, 0.5, 0.8, 1.0] {
            let expected = pow(sin(.pi * progress), 2)
            XCTAssertEqual(value(opacity, at: progress), expected, accuracy: 0.0007)
            XCTAssertEqual(
                value(ellipseScale, at: progress), 0.7 + 0.3 * expected, accuracy: 0.0003)
            XCTAssertEqual(value(markScale, at: progress), 0.7 + 0.3 * expected, accuracy: 0.0003)
        }
        let originalPath = group.mark.path
        let shifted = RetainedTwinkleDescriptor(
            twinkle: descriptor.twinkle,
            placement: .init(
                center: CGPoint(x: 50, y: 23.5), bar: CGRect(x: 15, y: 20, width: 80, height: 7),
                cornerRadius: 3.5), color: descriptor.color)
        group.update(descriptor: shifted, surfaceHeight: 70, scale: 1)
        XCTAssertEqual(group.clip.frame, CGRect(x: 15, y: 43, width: 80, height: 7))
        XCTAssertTrue(group.mark.path === originalPath, "Moving the bar does not rebuild the star")
        XCTAssertEqual(try animation("opacity", on: group.mark).beginTime, opacity.beginTime)
        XCTAssertEqual(
            group.installAnimations(
                for: descriptor.twinkle,
                at: origin.addingTimeInterval(0.3), mediaTime: 101), 0)
        XCTAssertEqual(group.animationInstallations, 4)
        group.stop()
        XCTAssertNil(group.clip.superlayer)
        XCTAssertTrue(group.ellipse.animationKeys()?.isEmpty ?? true)
        XCTAssertTrue(group.mark.animationKeys()?.isEmpty ?? true)
    }

    func testLayerGeometryAndSourceOverMatchCanvasAtSampledAnimationPhases() throws {
        let size = CGSize(width: 100, height: 60)
        for scale in [CGFloat(1), 2] {
            for star in [false, true] {
                for x in [CGFloat(10), 45, 90] {
                    let descriptor = descriptor(centerX: x, star: star)
                    for progress in [0.2, 0.5, 0.8] {
                        let group = RetainedTwinkleLayerGroup(
                            descriptor: descriptor, surfaceHeight: size.height, scale: scale)
                        let parent = CALayer()
                        parent.bounds = CGRect(origin: .zero, size: size)
                        parent.addSublayer(group.clip)
                        group.installAnimations(for: descriptor.twinkle, at: origin, mediaTime: 100)
                        let opacity = value(try animation("opacity", on: group.mark), at: progress)
                        let sizeFactor = value(
                            try animation("transform.scale", on: group.mark), at: progress)
                        // Render model layers at sampled animation values. This
                        // validates geometry/compositing, not live GPU execution.
                        group.ellipse.removeAllAnimations()
                        group.mark.removeAllAnimations()
                        group.ellipse.opacity = Float(opacity)
                        group.mark.opacity = Float(opacity)
                        group.ellipse.transform = CATransform3DMakeScale(sizeFactor, 1, 1)
                        group.mark.transform = CATransform3DMakeScale(sizeFactor, sizeFactor, 1)
                        let actual = try bitmap(size: size, scale: scale)
                        parent.render(in: actual)
                        let expected = try bitmap(size: size, scale: scale)
                        let lane = RequestLane(
                            id: descriptor.twinkle.requestID,
                            startedAt: origin.addingTimeInterval(-100))
                        let segment = RequestRailGeometry.Segment(
                            lane: lane, rect: descriptor.placement.bar,
                            isLive: true, track: 0)
                        let renderer = ImageRenderer(
                            content: Canvas { context, _ in
                                descriptor.twinkle.draw(
                                    segment: segment, now: self.origin, duration: 100,
                                    rail: CGRect(x: 0, y: 20, width: 100, height: 7),
                                    timestamp: self.origin.addingTimeInterval(
                                        descriptor.twinkle.duration * progress),
                                    color: Color(.sRGB, red: 0.1, green: 0.6, blue: 0.9),
                                    in: &context)
                            })
                        renderer.proposedSize = ProposedViewSize(size)
                        renderer.scale = scale
                        renderer.render(rasterizationScale: scale) { _, draw in draw(expected) }
                        assertPixels(
                            actual, match: expected,
                            label: "scale-\(scale)-star-\(star)-x-\(x)-p-\(progress)")
                        group.stop()
                    }
                }
            }
        }
    }

    func testHostClipsShapesToThePlotDuringResize() throws {
        let host = RetainedRequestRailTwinkleView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        let original = descriptor(centerX: 45)
        let outside = RetainedTwinkleDescriptor(
            twinkle: original.twinkle,
            placement: .init(
                center: CGPoint(x: 102, y: 23.5),
                bar: CGRect(x: 90, y: 20, width: 20, height: 7), cornerRadius: 3.5),
            color: original.color)
        let group = RetainedTwinkleLayerGroup(descriptor: outside, surfaceHeight: 60, scale: 1)
        group.ellipse.opacity = 1
        group.mark.opacity = 1
        let layer = try XCTUnwrap(host.layer)
        XCTAssertTrue(layer.masksToBounds)
        layer.addSublayer(group.clip)
        let pixels = try bitmap(size: CGSize(width: 120, height: 60), scale: 1)
        layer.render(in: pixels)
        let data = pixels.data!.assumingMemoryBound(to: UInt8.self)
        var visibleAlpha = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let alpha = Int(data[y * pixels.bytesPerRow + x * 4 + 3])
                if x >= 100 { XCTAssertEqual(alpha, 0) } else { visibleAlpha += alpha }
            }
        }
        XCTAssertGreaterThan(visibleAlpha, 0)
        group.stop()
        host.stop()
    }

    func testFinishedOrFutureInstancesInstallNoAnimationsAndSeparateInstancesHaveDistinctLayers() {
        let first = descriptor(centerX: 45)
        let group = RetainedTwinkleLayerGroup(descriptor: first, surfaceHeight: 60, scale: 1)
        XCTAssertEqual(
            group.installAnimations(for: first.twinkle, at: first.twinkle.endsAt, mediaTime: 100), 0
        )
        XCTAssertEqual(
            group.installAnimations(
                for: first.twinkle, at: origin.addingTimeInterval(-1), mediaTime: 100), 0)
        XCTAssertNil(group.mark.animationKeys())
        XCTAssertEqual(group.mark.opacity, 0)
        let overlapping = RequestRailTwinkle(
            requestID: first.twinkle.requestID, startedAt: origin.addingTimeInterval(0.1),
            duration: 0.5, location: first.twinkle.location, size: 2.5, angle: 0.3, star: true)
        let second = RetainedTwinkleLayerGroup(
            descriptor: .init(
                twinkle: overlapping, placement: first.placement, color: first.color),
            surfaceHeight: 60, scale: 1)
        XCTAssertNotEqual(group.id, second.id)
        XCTAssertFalse(group.clip === second.clip)
        group.stop()
        second.stop()
    }

    func testDetachedAndStoppedHostsCannotClaimInstalledAnimations() throws {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        try diagnostics.enable(mode: .normal)
        defer { XCTAssertNoThrow(try diagnostics.disable()) }
        let view = RetainedRequestRailTwinkleView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        view.update(descriptors: [descriptor(centerX: 45)], scale: 2)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.window)
        var counters = try XCTUnwrap(
            diagnostics.snapshot()["retained_twinkles"] as? [String: UInt64])
        XCTAssertEqual(counters["hosts_created"], 0)
        XCTAssertEqual(counters["animation_starts"], 0)
        XCTAssertTrue(view.layer?.sublayers?.isEmpty ?? true)
        view.stop()
        view.update(descriptors: [descriptor(centerX: 50)], scale: 1)
        counters = try XCTUnwrap(diagnostics.snapshot()["retained_twinkles"] as? [String: UInt64])
        XCTAssertEqual(counters["live_hosts"], 0)
        XCTAssertEqual(counters["animation_starts"], 0)
        XCTAssertTrue(view.layer?.sublayers?.isEmpty ?? true)
    }

    func testNormalHostAnimatesAndReleasesHiddenLayersWithDiagnosticsDisabled() throws {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        XCTAssertFalse(diagnostics.isEnabled)
        XCTAssertEqual(diagnostics.mode, .normal)
        let initial = diagnostics.snapshot() as NSDictionary
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 100, height: 60)
        let window = RetainedTwinkleVisibilityWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: frame)
        window.contentView = container
        let host = RetainedRequestRailTwinkleView(frame: frame)
        defer {
            host.stop()
            host.removeFromSuperview()
            window.close()
        }
        // A long remaining lifetime avoids timer sleeps or expiry races. The
        // simulated visibility exercises host lifecycle, not displayed frames.
        let startedAt = Date().addingTimeInterval(-5)
        let descriptors = [CGFloat(25), 45, 65].map { x in
            let original = descriptor(centerX: x)
            return RetainedTwinkleDescriptor(
                twinkle: RequestRailTwinkle(
                    requestID: original.twinkle.requestID, startedAt: startedAt, duration: 60,
                    location: original.twinkle.location, size: original.twinkle.size,
                    angle: original.twinkle.angle, star: original.twinkle.star),
                placement: original.placement, color: original.color)
        }
        container.addSubview(host)
        host.update(descriptors: descriptors, scale: 2)
        let layer = try XCTUnwrap(host.layer)
        let clips = try XCTUnwrap(layer.sublayers)
        XCTAssertEqual(
            clips.count, 2, "The real host must enforce the two-instance bound without counters")
        for clip in clips {
            XCTAssertEqual(clip.sublayers?.count, 2)
            XCTAssertEqual(clip.sublayers?.reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }, 4)
        }
        let mark = try XCTUnwrap(clips.first?.sublayers?.last as? CAShapeLayer)
        let path = mark.path
        let firstStart = try animation("opacity", on: mark).beginTime
        let moved = descriptors.map {
            RetainedTwinkleDescriptor(
                twinkle: $0.twinkle,
                placement: .init(
                    center: CGPoint(x: $0.placement.center.x + 1, y: $0.placement.center.y),
                    bar: $0.placement.bar, cornerRadius: $0.placement.cornerRadius),
                color: $0.color)
        }
        host.update(descriptors: moved, scale: 1)
        XCTAssertTrue(layer.sublayers?.first === clips.first)
        XCTAssertTrue(mark.path === path)
        XCTAssertEqual(try animation("opacity", on: mark).beginTime, firstStart)

        window.simulatedOccluded = true
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertTrue(layer.sublayers?.isEmpty ?? true)
        for clip in clips {
            XCTAssertNil(clip.superlayer)
            for shape in clip.sublayers ?? [] {
                XCTAssertTrue(shape.animationKeys()?.isEmpty ?? true)
            }
        }
        window.simulatedOccluded = false
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(layer.sublayers?.count, 2)
        let resumedMark = try XCTUnwrap(layer.sublayers?.first?.sublayers?.last as? CAShapeLayer)
        XCTAssertFalse(resumedMark === mark)
        XCTAssertEqual(
            try animation("opacity", on: resumedMark).beginTime, firstStart, accuracy: 0.05,
            "Reappearance resumes the original age rather than restarting the glint")

        host.isHidden = true
        host.viewDidHide()
        host.update(descriptors: descriptors, scale: 2)
        XCTAssertTrue(layer.sublayers?.isEmpty ?? true)
        host.isHidden = false
        host.viewDidUnhide()
        XCTAssertEqual(layer.sublayers?.count, 2)
        host.removeFromSuperview()
        XCTAssertNil(host.window)
        XCTAssertTrue(layer.sublayers?.isEmpty ?? true)
        container.addSubview(host)
        XCTAssertEqual(layer.sublayers?.count, 2)
        host.stop()
        host.update(descriptors: descriptors, scale: 2)
        NotificationCenter.default.post(name: NSWindow.didExposeNotification, object: window)
        XCTAssertTrue(layer.sublayers?.isEmpty ?? true)
        XCTAssertEqual(
            diagnostics.snapshot() as NSDictionary, initial,
            "Animation lifetime must not depend on optional diagnostic registrations")
    }

    private func descriptor(centerX: CGFloat, star: Bool = true) -> RetainedTwinkleDescriptor {
        let twinkle = RequestRailTwinkle(
            requestID: UUID(), startedAt: origin, duration: 0.5,
            location: origin.addingTimeInterval(Double(centerX) - 100), size: 3, angle: 0.47,
            star: star)
        return RetainedTwinkleDescriptor(
            twinkle: twinkle,
            placement: .init(
                center: CGPoint(x: centerX, y: 23.5),
                bar: CGRect(x: 10, y: 20, width: 80, height: 7), cornerRadius: 3.5),
            color: CGColor(srgbRed: 0.1, green: 0.6, blue: 0.9, alpha: 1))
    }

    private func animation(_ key: String, on layer: CALayer) throws -> CAKeyframeAnimation {
        try XCTUnwrap(layer.animation(forKey: key) as? CAKeyframeAnimation)
    }

    private func value(_ animation: CAKeyframeAnimation, at progress: Double) -> Double {
        let values = animation.values as! [NSNumber]
        let offset = min(Double(values.count - 1), max(0, progress * Double(values.count - 1)))
        let left = Int(floor(offset))
        let right = min(values.count - 1, left + 1)
        let fraction = offset - Double(left)
        return values[left].doubleValue * (1 - fraction) + values[right].doubleValue * fraction
    }

    private func bitmap(size: CGSize, scale: CGFloat) throws -> CGContext {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        return context
    }

    private func assertPixels(
        _ actual: CGContext, match expected: CGContext, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        func bytes(_ context: CGContext) -> [UInt8] {
            Array(
                UnsafeBufferPointer(
                    start: context.data!.assumingMemoryBound(to: UInt8.self),
                    count: context.bytesPerRow * context.height))
        }
        let lhs = bytes(actual)
        let rhs = bytes(expected)
        var differences: [Int] = []
        var actualAlpha = 0
        var expectedAlpha = 0
        for pixel in 0..<(lhs.count / 4) {
            let offset = pixel * 4
            actualAlpha += Int(lhs[offset + 3])
            expectedAlpha += Int(rhs[offset + 3])
            if lhs[offset + 3] > 0 || rhs[offset + 3] > 0 {
                for component in 0..<4 {
                    differences.append(
                        abs(Int(lhs[offset + component]) - Int(rhs[offset + component])))
                }
            }
        }
        XCTAssertGreaterThan(actualAlpha, 0, file: file, line: line)
        XCTAssertGreaterThan(expectedAlpha, 0, file: file, line: line)
        // CA and Canvas may antialias edges differently. Compare just the
        // occupied pixels, not a large transparent canvas that dilutes errors.
        let meanError = Double(differences.reduce(0, +)) / Double(max(1, differences.count))
        if meanError > 8 {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                "fluxllm-retained-fidelity")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, context) in [("actual", actual), ("expected", expected)] {
                if let image = context.makeImage(),
                    let png = NSBitmapImageRep(cgImage: image).representation(
                        using: .png, properties: [:])
                {
                    try? png.write(to: folder.appendingPathComponent("\(label)-\(name).png"))
                }
            }
            print(
                "Retained fidelity \(label): mean=\(meanError), alpha=\(actualAlpha)/\(expectedAlpha), files=\(folder.path)"
            )
        }
        XCTAssertLessThanOrEqual(meanError, 8, label, file: file, line: line)
        XCTAssertLessThanOrEqual(
            Double(abs(actualAlpha - expectedAlpha)) / Double(max(1, expectedAlpha)),
            0.08, file: file, line: line)
    }
}

/// No test orders a real window front. Only the visibility queried by the
/// production host is simulated; its native layer and notification hooks run.
@MainActor
private final class RetainedTwinkleVisibilityWindow: NSWindow {
    var simulatedOccluded = false
    override var isVisible: Bool { true }
    override var isMiniaturized: Bool { false }
    override var occlusionState: NSWindow.OcclusionState { simulatedOccluded ? [] : [.visible] }
}
