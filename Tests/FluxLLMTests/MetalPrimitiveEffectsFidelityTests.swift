import AppKit
import Dispatch
import Metal
import SwiftUI
import XCTest

@testable import FluxLLM

/// The original Canvas operations are the visual oracle. Resource comparisons
/// can still run when this strict, separately reported native gate fails.
@MainActor
final class MetalPrimitiveEffectsFidelityTests: XCTestCase {
    private typealias Renderer = MetalPrimitiveEffectsRenderer
    private typealias Element = MetalFullChartEffectsRenderer.Element
    private let size = CGSize(width: 192, height: 112)
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let colors: [SIMD4<Float>] = [SIMD4(0.05, 0.87, 1, 1), SIMD4(1, 0.08, 0.56, 0.55)]

    func testLifecycleEffectsAgainstIndependentCanvasOptIn() throws {
        let gate = try nativeGate()
        var results: [[String: Any]] = []
        var deviceName: String?
        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                try gate.summary(
                    status: "unavailable", cases: [], device: nil, error: "Metal device unavailable"
                )
                throw XCTSkip("Metal unavailable; primitive effects fidelity was not evaluated")
            }
            deviceName = device.name
            let renderer = try Renderer(device: device)
            for scale in [CGFloat(1), 2] {
                let result = try calibrate(renderer, scale: scale, gate: gate)
                results.append(result)
                guard (result["expected_nonzero_alpha_pixels"] as? Int ?? 0) > 0 else {
                    try gate.summary(
                        status: "unavailable", cases: results, device: deviceName,
                        error:
                            "Independent Canvas calibration produced no pixels; native fidelity unavailable"
                    )
                    throw XCTSkip(
                        "Canvas calibration produced no pixels; no effect verdict is available")
                }
                guard result["fixture_verified"] as? Bool == true,
                    result["within_gate"] as? Bool == true
                else {
                    try gate.summary(
                        status: "calibration_failed", cases: results, device: deviceName,
                        error:
                            "Independent row, channel, coverage or premultiplied-alpha calibration failed"
                    )
                    throw Failure.failed(
                        "Primitive native readback calibration failed; \(gate.directory.path)")
                }
            }

            let arrivals = try seeds(completion: false)
            let exploding = try seeds(completion: true, explodes: true)
            let settling = try seeds(completion: true, explodes: false)
            for scale in [CGFloat(1), 2] {
                for (family, seed) in arrivals {
                    let effect = effect(seed: seed, completion: false)
                    for progress in [0.025, 0.25, 0.7, 0.94] {
                        results.append(
                            try compare(
                                [.effect(effect)], elapsed: effect.profile.burstDuration * progress,
                                renderer: renderer, scale: scale,
                                label: "arrival-\(family)-seed\(seed)-p\(progress)-s\(Int(scale))",
                                gate: gate))
                    }
                }
                for (explodes, fixtures) in [(true, exploding), (false, settling)] {
                    for (family, seed) in fixtures {
                        let effect = effect(seed: seed, completion: true, color: colors[1])
                        let profile = effect.profile
                        var times = [
                            0.06, profile.surgeDelay + profile.surgeDuration * 0.5,
                            profile.surgeDelay + profile.surgeDuration + 0.06,
                        ]
                        if explodes {
                            times.append(
                                profile.surgeDelay + profile.surgeDuration + profile.burstDuration
                                    * 0.45)
                        }
                        for (index, elapsed) in times.enumerated() {
                            results.append(
                                try compare(
                                    [.effect(effect)], elapsed: elapsed, renderer: renderer,
                                    scale: scale,
                                    label:
                                        "completion-\(family)-seed\(seed)-explode\(explodes)-t\(index)-s\(Int(scale))",
                                    gate: gate))
                        }
                    }
                }
                let first = effect(
                    seed: arrivals[0].1, completion: false,
                    rect: CGRect(x: 89.25, y: 45.375, width: 24.5, height: 7))
                let second = effect(
                    seed: exploding[1].1, completion: true, index: 1, startTime: 0.035,
                    rect: CGRect(x: 68.75, y: 47.125, width: 31.5, height: 7), color: colors[1])
                for star in [false, true] {
                    let glint = twinkle(star: star, atLeftEdge: !star)
                    results.append(
                        try compare(
                            [.twinkle(glint)], elapsed: 0.17, renderer: renderer,
                            scale: scale, label: "clipped-glint-star\(star)-s\(Int(scale))",
                            gate: gate))
                    for (order, elements) in [
                        [Element.effect(first), .twinkle(glint), .effect(second)],
                        [.effect(second), .twinkle(glint), .effect(first)],
                    ].enumerated() {
                        results.append(
                            try compare(
                                elements, elapsed: 0.17, renderer: renderer, scale: scale,
                                label: "ordered-overlap\(order)-star\(star)-s\(Int(scale))",
                                gate: gate))
                    }
                }
                // The cropped overlay receives chart coordinates and a fractional
                // origin. The reference translates the original Canvas, independently.
                results.append(
                    try compare(
                        [
                            .effect(first), .twinkle(twinkle(star: true, atLeftEdge: false)),
                            .effect(second),
                        ],
                        elapsed: 0.17, renderer: renderer, scale: scale,
                        label: "cropped-fractional-origin-s\(Int(scale))", gate: gate,
                        pointSize: CGSize(width: 64, height: 24),
                        drawingOrigin: CGPoint(x: 76.25, y: 41.375)))
                // Reaches the original 240-knot cap, with clipping at both image
                // edges, testing GPU masks rather than only short channels.
                let wideBase = effect(
                    seed: exploding[2].1, completion: true, index: 2,
                    rect: CGRect(x: 0, y: 70.375, width: 1600.5, height: 7))
                let wideElapsed =
                    wideBase.profile.surgeDelay + wideBase.profile.surgeDuration * 0.25
                let wideFrame = try XCTUnwrap(
                    Self.lightningFrame(wideBase.profile, age: wideElapsed, rect: wideBase.rect))
                let wide = effect(
                    seed: exploding[2].1, completion: true, index: 2,
                    rect: CGRect(x: 96.25 - wideFrame.head.x, y: 70.375, width: 1600.5, height: 7))
                results.append(
                    try compare(
                        [.effect(wide)], elapsed: wideElapsed,
                        renderer: renderer, scale: scale,
                        label: "wide-clipped-channel-s\(Int(scale))", gate: gate))

                for (family, seed) in arrivals {
                    let effect = effect(seed: seed, completion: false)
                    for (boundary, elapsed) in [
                        ("start", 0.0), ("end", effect.profile.burstDuration),
                    ] {
                        results.append(
                            try compare(
                                [.effect(effect)], elapsed: elapsed, renderer: renderer,
                                scale: scale,
                                label: "blank-arrival-\(family)-\(boundary)-s\(Int(scale))",
                                gate: gate, content: .blank))
                    }
                }
                for (family, seed) in exploding {
                    let effect = effect(seed: seed, completion: true)
                    for (boundary, elapsed) in [
                        ("start", 0.0), ("end", effect.profile.visibleDuration),
                    ] {
                        results.append(
                            try compare(
                                [.effect(effect)], elapsed: elapsed, renderer: renderer,
                                scale: scale,
                                label: "blank-completion-\(family)-\(boundary)-s\(Int(scale))",
                                gate: gate, content: .blank))
                    }
                }
                for star in [false, true] {
                    let glint = twinkle(star: star, atLeftEdge: !star)
                    for (boundary, elapsed) in [
                        ("start", glint.startTime),
                        ("end", glint.startTime + glint.twinkle.duration),
                    ] {
                        results.append(
                            try compare(
                                [.twinkle(glint)], elapsed: elapsed, renderer: renderer,
                                scale: scale,
                                label: "blank-glint-star\(star)-\(boundary)-s\(Int(scale))",
                                gate: gate, content: .blank))
                    }
                }
            }
            let failed = results.filter { ($0["within_gate"] as? Bool) != true }.count
            let unavailable = results.contains {
                ($0["requires_visible_content"] as? Bool) == true
                    && ($0["expected_nonzero_alpha_pixels"] as? Int ?? 0) == 0
            }
            let status = unavailable ? "unavailable" : failed == 0 ? "passed" : "failed"
            try gate.summary(
                status: status, cases: results, device: deviceName,
                error: unavailable
                    ? "A visible original Canvas fixture produced no pixels; no valid fidelity verdict"
                    : nil)
            if unavailable {
                throw XCTSkip(
                    "Original Canvas produced no pixels in a visible fixture; evidence saved")
            }
            XCTAssertEqual(
                failed, 0,
                "Primitive strict lifecycle pixel gate failed; evidence: \(gate.directory.path)")
        } catch {
            try gate.failureIfAbsent(error, cases: results, device: deviceName)
            throw error
        }
    }

    /// Canvas replay with cached invariants must be pixel-identical to the
    /// independent pre-optimization oracle. This has a separate output gate
    /// and never relaxes the existing two-byte Metal comparison.
    func testCachedRailGeometryAgainstIndependentCanvasOptIn() throws {
        let gate = try railGeometryGate()
        var results: [[String: Any]] = []
        do {
            for scale in [CGFloat(1), 2] {
                let result = try calibrateCanvas(scale: scale, gate: gate)
                results.append(result)
                guard (result["expected_nonzero_alpha_pixels"] as? Int ?? 0) > 0 else {
                    try gate.summary(
                        status: "unavailable", cases: results, device: nil,
                        error: "Independent Canvas calibration produced no pixels")
                    throw XCTSkip(
                        "Canvas calibration produced no pixels; cached rail fidelity unavailable")
                }
                guard result["fixture_verified"] as? Bool == true,
                    result["within_gate"] as? Bool == true
                else {
                    throw Failure.failed(
                        "Cached Canvas readback calibration failed; \(gate.directory.path)")
                }
            }
            let arrivals = try seeds(completion: false)
            let exploding = try seeds(completion: true, explodes: true)
            let settling = try seeds(completion: true, explodes: false)
            for scale in [CGFloat(1), 2] {
                for (family, seed) in arrivals {
                    let effect = effect(seed: seed, completion: false)
                    for progress in [0.025, 0.25, 0.7, 0.94] {
                        results.append(
                            try compareCachedCanvas(
                                [.effect(effect)], elapsed: effect.profile.burstDuration * progress,
                                scale: scale,
                                label: "arrival-\(family)-seed\(seed)-p\(progress)-s\(Int(scale))",
                                gate: gate))
                    }
                }
                for (explodes, fixtures) in [(true, exploding), (false, settling)] {
                    for (family, seed) in fixtures {
                        let effect = effect(seed: seed, completion: true, color: colors[1])
                        let profile = effect.profile
                        var times = [
                            0.06, profile.surgeDelay + profile.surgeDuration * 0.5,
                            profile.surgeDelay + profile.surgeDuration + 0.06,
                        ]
                        if explodes {
                            times.append(
                                profile.surgeDelay + profile.surgeDuration + profile.burstDuration
                                    * 0.45)
                        }
                        for (index, elapsed) in times.enumerated() {
                            results.append(
                                try compareCachedCanvas(
                                    [.effect(effect)], elapsed: elapsed, scale: scale,
                                    label:
                                        "completion-\(family)-seed\(seed)-explode\(explodes)-t\(index)-s\(Int(scale))",
                                    gate: gate))
                        }
                    }
                }
                let first = effect(
                    seed: arrivals[0].1, completion: false,
                    rect: CGRect(x: 89.25, y: 45.375, width: 24.5, height: 7))
                let second = effect(
                    seed: exploding[1].1, completion: true, index: 1, startTime: 0.035,
                    rect: CGRect(x: 68.75, y: 47.125, width: 31.5, height: 7), color: colors[1])
                for star in [false, true] {
                    let glint = twinkle(star: star, atLeftEdge: !star)
                    results.append(
                        try compareCachedCanvas(
                            [.twinkle(glint)], elapsed: 0.17, scale: scale,
                            label: "clipped-glint-star\(star)-s\(Int(scale))", gate: gate))
                    for (order, elements) in [
                        [Element.effect(first), .twinkle(glint), .effect(second)],
                        [.effect(second), .twinkle(glint), .effect(first)],
                    ].enumerated() {
                        results.append(
                            try compareCachedCanvas(
                                elements, elapsed: 0.17, scale: scale,
                                label: "ordered-overlap\(order)-star\(star)-s\(Int(scale))",
                                gate: gate))
                    }
                }
                // Both Canvas replays receive chart coordinates and a fractional
                // crop origin; each translates the drawing independently.
                results.append(
                    try compareCachedCanvas(
                        [
                            .effect(first), .twinkle(twinkle(star: true, atLeftEdge: false)),
                            .effect(second),
                        ],
                        elapsed: 0.17, scale: scale,
                        label: "cropped-fractional-origin-s\(Int(scale))", gate: gate,
                        pointSize: CGSize(width: 64, height: 24),
                        drawingOrigin: CGPoint(x: 76.25, y: 41.375)))
                // Reaches the original 240-knot cap, with clipping at both image
                // edges, covering cached long-perimeter knots and forks.
                let wideBase = effect(
                    seed: exploding[2].1, completion: true, index: 2,
                    rect: CGRect(x: 0, y: 70.375, width: 1600.5, height: 7))
                let wideElapsed =
                    wideBase.profile.surgeDelay + wideBase.profile.surgeDuration * 0.25
                let wideFrame = try XCTUnwrap(
                    Self.lightningFrame(wideBase.profile, age: wideElapsed, rect: wideBase.rect))
                let wide = effect(
                    seed: exploding[2].1, completion: true, index: 2,
                    rect: CGRect(x: 96.25 - wideFrame.head.x, y: 70.375, width: 1600.5, height: 7))
                results.append(
                    try compareCachedCanvas(
                        [.effect(wide)], elapsed: wideElapsed,
                        scale: scale, label: "wide-clipped-channel-s\(Int(scale))", gate: gate))

                for (family, seed) in arrivals {
                    let effect = effect(seed: seed, completion: false)
                    for (boundary, elapsed) in [
                        ("start", 0.0), ("end", effect.profile.burstDuration),
                    ] {
                        results.append(
                            try compareCachedCanvas(
                                [.effect(effect)], elapsed: elapsed, scale: scale,
                                label: "blank-arrival-\(family)-\(boundary)-s\(Int(scale))",
                                gate: gate, content: .blank))
                    }
                }
                for (family, seed) in exploding {
                    let effect = effect(seed: seed, completion: true)
                    for (boundary, elapsed) in [
                        ("start", 0.0), ("end", effect.profile.visibleDuration),
                    ] {
                        results.append(
                            try compareCachedCanvas(
                                [.effect(effect)], elapsed: elapsed, scale: scale,
                                label: "blank-completion-\(family)-\(boundary)-s\(Int(scale))",
                                gate: gate, content: .blank))
                    }
                }
                for star in [false, true] {
                    let glint = twinkle(star: star, atLeftEdge: !star)
                    for (boundary, elapsed) in [
                        ("start", glint.startTime),
                        ("end", glint.startTime + glint.twinkle.duration),
                    ] {
                        results.append(
                            try compareCachedCanvas(
                                [.twinkle(glint)], elapsed: elapsed, scale: scale,
                                label: "blank-glint-star\(star)-\(boundary)-s\(Int(scale))",
                                gate: gate, content: .blank))
                    }
                }
            }
            let failed = results.filter { ($0["within_gate"] as? Bool) != true }.count
            let unavailable = results.contains {
                ($0["requires_visible_content"] as? Bool) == true
                    && ($0["expected_nonzero_alpha_pixels"] as? Int ?? 0) == 0
            }
            try gate.summary(
                status: unavailable ? "unavailable" : failed == 0 ? "passed" : "failed",
                cases: results, device: nil,
                error: unavailable
                    ? "A visible original Canvas fixture produced no pixels; no fidelity verdict"
                    : nil)
            if unavailable {
                throw XCTSkip(
                    "Original Canvas produced no pixels in a visible fixture; evidence saved")
            }
            XCTAssertEqual(
                failed, 0,
                "Cached normal Canvas exact pixel gate failed; evidence: \(gate.directory.path)")
        } catch {
            try gate.failureIfAbsent(error, cases: results, device: nil)
            throw error
        }
    }

    private func effect(
        seed: UInt64, completion: Bool, index: Int = 0, startTime: TimeInterval = 0,
        rect: CGRect = CGRect(x: 49.25, y: 43.375, width: 101.5, height: 7),
        color: SIMD4<Float>? = nil
    ) -> MetalFullChartEffectsRenderer.Effect {
        let event = RequestRailEvent(
            requestID: UUID(
                uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
            kind: completion ? .completion : .arrival, startedAt: origin, seed: seed)
        return .init(
            id: .init(event), startTime: startTime,
            profile: .init(seed: seed, requestDuration: 30, completion: completion), rect: rect,
            cornerRadius: min(rect.width, rect.height) / 2, color: color ?? colors[0])
    }

    private func twinkle(star: Bool, atLeftEdge: Bool) -> MetalFullChartEffectsRenderer.Twinkle {
        let bar = CGRect(x: 87.25, y: 45.375, width: 16.5, height: 7)
        return .init(
            twinkle: .init(
                requestID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                startedAt: origin,
                duration: 0.4, location: origin, size: 3.1, angle: 0.37, star: star),
            placement: .init(
                center: CGPoint(x: atLeftEdge ? bar.minX + 0.25 : bar.maxX - 0.25, y: bar.midY),
                bar: bar, cornerRadius: 3.5), startTime: 0.015, color: colors[1])
    }

    private func seeds(completion: Bool, explodes: Bool? = nil) throws -> [(String, UInt64)] {
        var selected: [String: UInt64] = [:]
        for seed in UInt64(0)..<10_000 {
            let profile = RequestRailEffectProfile(
                seed: seed, requestDuration: 30, completion: completion)
            guard explodes == nil || profile.explodes == explodes else { continue }
            let name = familyName(profile.family)
            if selected[name] == nil { selected[name] = seed }
            if selected.count == 3 { break }
        }
        guard selected.count == 3 else {
            throw Failure.failed("Could not cover every deterministic particle family")
        }
        return ["fireflies", "sparks", "arcs"].map { ($0, selected[$0]!) }
    }

    private func familyName(_ family: RequestRailEffectProfile.Family) -> String {
        switch family {
        case .fireflies: "fireflies"
        case .sparks: "sparks"
        case .arcs: "arcs"
        }
    }

    private enum Content: Equatable { case visible, blank }

    private func compare(
        _ elements: [Element], elapsed: TimeInterval, renderer: Renderer, scale: CGFloat,
        label: String, gate: Gate, pointSize: CGSize? = nil, drawingOrigin: CGPoint = .zero,
        content: Content = .visible
    ) throws -> [String: Any] {
        let pointSize = pointSize ?? size
        try renderer.update(elements: elements)
        let before = renderer.statistics
        let actual = try render(renderer, scale: scale, size: pointSize) {
            try renderer.encode(
                into: $0, target: $1, elapsedTime: elapsed, pointSize: pointSize,
                origin: drawingOrigin, clear: true)
        }
        let after = renderer.statistics
        let expected = try canvas(scale: scale, size: pointSize) { context in
            context.translateBy(x: -drawingOrigin.x, y: -drawingOrigin.y)
            Self.drawReference(elements, elapsed: elapsed, in: &context)
        }
        var result = try comparison(
            actual, expected: expected, label: label, gate: gate,
            requiresVisible: content == .visible)
        result["scale"] = Double(scale)
        result["elapsed_seconds"] = elapsed
        result["point_size"] = [Double(pointSize.width), Double(pointSize.height)]
        result["drawing_origin"] = [Double(drawingOrigin.x), Double(drawingOrigin.y)]
        result["element_order"] = elements.map { element -> [String: Any] in
            switch element {
            case .effect(let effect):
                [
                    "kind": effect.profile.completion ? "completion" : "arrival",
                    "seed": String(effect.id.seed),
                    "family": familyName(effect.profile.family),
                    "explodes": effect.profile.explodes,
                    "start_time": effect.startTime, "burst_duration": effect.profile.burstDuration,
                    "visible_duration": effect.profile.visibleDuration,
                    "rect": [
                        Double(effect.rect.minX), Double(effect.rect.minY),
                        Double(effect.rect.width), Double(effect.rect.height),
                    ],
                    "srgb_rgba": [effect.color.x, effect.color.y, effect.color.z, effect.color.w]
                        .map(Double.init),
                ]
            case .twinkle(let glint):
                [
                    "kind": "glint", "star": glint.twinkle.star, "start_time": glint.startTime,
                    "duration": glint.twinkle.duration,
                    "srgb_rgba": [glint.color.x, glint.color.y, glint.color.z, glint.color.w].map(
                        Double.init),
                ]
            }
        }
        result["unchanged_descriptor_uploads_during_frame"] =
            before.descriptorUploads == after.descriptorUploads
        result["encoded_frame_delta"] = after.encodedFrames - before.encodedFrames
        result["in_flight_after_completion"] = after.inFlightFrames
        result["retained_descriptor_bytes"] = after.retainedDescriptorBytes
        result["retained_frame_bytes"] = after.retainedFrameBytes
        XCTAssertEqual(
            before.descriptorUploads, after.descriptorUploads,
            "Frames must reuse immutable effect descriptors")
        XCTAssertEqual(after.inFlightFrames, 0, "GPU completion must release frame leases")
        try gate.write(result, name: "\(label)-metrics.json")
        return result
    }

    // MARK: Original Canvas drawing and timing, independent of candidate geometry

    private func compareCachedCanvas(
        _ elements: [Element], elapsed: TimeInterval, scale: CGFloat,
        label: String, gate: Gate, pointSize: CGSize? = nil, drawingOrigin: CGPoint = .zero,
        content: Content = .visible
    ) throws -> [String: Any] {
        let pointSize = pointSize ?? size
        let cache = RequestRailEffectGeometryCache(recordsDiagnostics: false)
        let effects = elements.compactMap { element -> MetalFullChartEffectsRenderer.Effect? in
            guard case .effect(let effect) = element else { return nil }
            return effect
        }
        cache.retain(Set(effects.map(\.id)), duration: 60)
        var geometries: [RequestRailLifecycleEffects.Key: RequestRailEffectGeometryCache.Geometry] =
            [:]
        for effect in effects {
            let first = try XCTUnwrap(
                cache.geometry(key: effect.id, profile: effect.profile, rect: effect.rect))
            let reused = try XCTUnwrap(
                cache.geometry(key: effect.id, profile: effect.profile, rect: effect.rect))
            XCTAssertTrue(first === reused, "Candidate fixture must exercise cached geometry reuse")
            geometries[effect.id] = reused
        }
        let candidateGeometry = geometries
        let actual = try canvas(scale: scale, size: pointSize) { context in
            context.translateBy(x: -drawingOrigin.x, y: -drawingOrigin.y)
            Self.drawReference(
                elements, elapsed: elapsed, cachedGeometry: candidateGeometry, in: &context)
        }
        let expected = try canvas(scale: scale, size: pointSize) { context in
            context.translateBy(x: -drawingOrigin.x, y: -drawingOrigin.y)
            Self.drawReference(elements, elapsed: elapsed, in: &context)
        }
        cache.removeAll()
        XCTAssertEqual(cache.statistics.currentEntries, 0)
        var result = try comparison(
            actual, expected: expected, label: label, gate: gate,
            requiresVisible: content == .visible)
        result["candidate_renderer"] = "normal Canvas with cached invariant rail geometry"
        result["reference_renderer"] =
            "independent original Canvas with original perimeter and timing formulas"
        result["scale"] = Double(scale)
        result["elapsed_seconds"] = elapsed
        result["point_size"] = [Double(pointSize.width), Double(pointSize.height)]
        result["drawing_origin"] = [Double(drawingOrigin.x), Double(drawingOrigin.y)]
        result["cache_builds"] = cache.statistics.builds
        result["cache_hits"] = cache.statistics.hits
        result["cache_entries_after_clear"] = cache.statistics.currentEntries
        result["cache_peak_entries"] = cache.statistics.peakEntries
        result["element_order"] = elements.map { element -> [String: Any] in
            switch element {
            case .effect(let effect):
                [
                    "kind": effect.profile.completion ? "completion" : "arrival",
                    "seed": String(effect.id.seed),
                    "family": familyName(effect.profile.family),
                    "explodes": effect.profile.explodes,
                    "start_time": effect.startTime, "burst_duration": effect.profile.burstDuration,
                    "visible_duration": effect.profile.visibleDuration,
                    "rect": [
                        Double(effect.rect.minX), Double(effect.rect.minY),
                        Double(effect.rect.width), Double(effect.rect.height),
                    ],
                    "srgb_rgba": [effect.color.x, effect.color.y, effect.color.z, effect.color.w]
                        .map(Double.init),
                ]
            case .twinkle(let glint):
                [
                    "kind": "glint", "star": glint.twinkle.star, "start_time": glint.startTime,
                    "duration": glint.twinkle.duration,
                    "srgb_rgba": [glint.color.x, glint.color.y, glint.color.z, glint.color.w].map(
                        Double.init),
                ]
            }
        }
        try gate.write(result, name: "\(label)-metrics.json")
        return result
    }

    private static func color(_ rgba: SIMD4<Float>) -> Color {
        Color(
            .sRGB, red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z),
            opacity: Double(rgba.w))
    }

    private static func drawReference(
        _ elements: [Element], elapsed: TimeInterval,
        cachedGeometry: [RequestRailLifecycleEffects.Key: RequestRailEffectGeometryCache.Geometry] =
            [:],
        in context: inout GraphicsContext
    ) {
        for element in elements {
            switch element {
            case .effect(let effect):
                let age = elapsed - effect.startTime
                let profile = effect.profile
                let rect = effect.rect
                guard age >= 0 else { continue }
                let tint = color(effect.color)
                let geometry = cachedGeometry[effect.id]
                if profile.completion {
                    let tip = CGPoint(x: rect.maxX, y: rect.midY)
                    drawBurst(
                        profile, age: age, duration: 0.24, scale: 0.5, at: tip, color: tint,
                        geometry: geometry, in: &context)
                    drawLightning(
                        profile, age: age, rect: rect, color: tint, geometry: geometry, in: &context
                    )
                    if profile.explodes {
                        drawBurst(
                            profile, age: age - profile.surgeDelay - profile.surgeDuration,
                            duration: profile.burstDuration, scale: 1.12, at: tip, color: tint,
                            geometry: geometry, in: &context)
                    }
                } else {
                    drawBurst(
                        profile, age: age, duration: profile.burstDuration, scale: 1,
                        at: CGPoint(x: rect.minX + effect.cornerRadius, y: rect.midY), color: tint,
                        geometry: geometry, in: &context)
                }
            case .twinkle(let glint):
                drawTwinkle(glint, age: elapsed - glint.startTime, in: &context)
            }
        }
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func smooth(_ value: Double) -> Double {
        let p = clamp(value)
        return p * p * (3 - 2 * p)
    }
    private static func envelope(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return 0 }
        let fade = clamp((p - 0.1) / 0.9)
        return min(1, p / 0.04) * (1 - fade) * (1 - fade) * (1 + 2 * fade)
    }

    private static func drawBurst(
        _ profile: RequestRailEffectProfile, age: TimeInterval, duration: TimeInterval,
        scale: Double, at point: CGPoint, color: Color,
        geometry: RequestRailEffectGeometryCache.Geometry? = nil, in context: inout GraphicsContext
    ) {
        let p = age / duration
        guard p > 0, p < 1 else { return }
        let strength = envelope(p)
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
            for (index, particle) in profile.particles.enumerated() {
                let q = clamp((p - particle.delay) / particle.life)
                let brightness = envelope(q) * 0.92
                guard brightness > 0 else { continue }
                let travel = 1 - pow(1 - q, 2)
                let distance = (4 + particle.distance * travel) * size
                let direction = geometry?.particleDirections[index]
                let position = CGPoint(
                    x: point.x + (direction?.cosine ?? cos(particle.angle)) * distance,
                    y: point.y + (direction?.sine ?? sin(particle.angle)) * distance)
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
                            x: position.x + (direction?.cosine ?? cos(particle.angle)) * length,
                            y: position.y + (direction?.sine ?? sin(particle.angle)) * length))
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
            : star(
                at: point, size: (4.5 + 3.5 * strength) * size, angle: profile.angle,
                rotation: geometry?.starRotation)
        context.fill(core, with: .color(.white.opacity(strength)))
    }

    private static func drawTwinkle(
        _ fixture: MetalFullChartEffectsRenderer.Twinkle, age: TimeInterval,
        in context: inout GraphicsContext
    ) {
        let twinkle = fixture.twinkle
        let placement = fixture.placement
        guard twinkle.duration.isFinite, twinkle.duration > 0, twinkle.size.isFinite,
            twinkle.size > 0, twinkle.angle.isFinite
        else { return }
        let p = age / twinkle.duration
        guard p > 0, p < 1 else { return }
        let strength = pow(sin(.pi * p), 2)
        let size = CGFloat(twinkle.size) * CGFloat(0.7 + 0.3 * strength)
        var clipped = context
        clipped.clip(
            to: Path(
                roundedRect: placement.bar, cornerRadius: placement.cornerRadius, style: .circular))
        clipped.fill(
            Path(
                ellipseIn: CGRect(
                    x: placement.center.x - size * 2.1, y: placement.bar.minY,
                    width: size * 4.2, height: placement.bar.height)),
            with: .color(color(fixture.color).opacity(strength * 0.32)))
        let mark =
            twinkle.star
            ? star(at: placement.center, size: size, angle: twinkle.angle)
            : circle(at: placement.center, radius: size * 0.56)
        clipped.fill(mark, with: .color(.white.opacity(strength)))
    }

    private static func drawLightning(
        _ profile: RequestRailEffectProfile, age: TimeInterval,
        rect: CGRect, color: Color,
        geometry: RequestRailEffectGeometryCache.Geometry? = nil,
        in context: inout GraphicsContext
    ) {
        let frame: RequestRailEffectProfile.LightningFrame?
        if let geometry {
            frame = geometry.lightningFrame(profile: profile, age: age)
        } else {
            frame = lightningFrame(profile, age: age, rect: rect)
        }
        guard let frame else { return }
        var clipped = context
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

    /// Uses only immutable profile data. This repeats the pre-optimization CPU
    /// timing and perimeter formula, and never reads GPU frame buffers/helpers.
    private static func lightningFrame(
        _ profile: RequestRailEffectProfile, age originalAge: TimeInterval,
        rect: CGRect
    ) -> RequestRailEffectProfile.LightningFrame? {
        let age = originalAge - profile.surgeDelay
        guard profile.completion, age > 0, age < profile.surgeDuration + 0.15,
            rect.width > 0, rect.height > 0
        else { return nil }
        let p = clamp(age / profile.surgeDuration)
        let progress = p + profile.bend * sin(2 * .pi * p)
        let settle = smooth((age - profile.surgeDuration) / 0.15)
        let strength = min(1, age / 0.05) * (1 - settle)
        let route = ReferencePerimeter(rect: rect)
        let distance = Double(route.length) * progress
        let tail = min(96, Double(route.length) * (0.31 + profile.trail), distance) * (1 - settle)
        let count = max(8, min(240, Int(ceil(route.length / 6.5))))
        let sampleTime = min(age, profile.surgeDuration)
        let index = profile.crackles.lastIndex { $0.at <= sampleTime } ?? 0
        let current = profile.crackles[index]
        let previous = profile.crackles[max(0, index - 1)]
        let blend = smooth((sampleTime - current.at) / 0.018)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * blend }
        let recharge = profile.flashAt.map { exp(-pow((p - $0) / 0.036, 2)) }.max() ?? 0
        let brightness = strength * (0.7 + 0.3 * mix(previous.brightness, current.brightness))
        let total = profile.channel.prefix(count).reduce(0) { $0 + $1.weight }
        func offsetPoint(_ position: Double, _ offset: Double) -> CGPoint {
            let d = profile.direction * position
            let point = route.point(at: d)
            let before = route.point(at: d - 0.12)
            let after = route.point(at: d + 0.12)
            let dx = after.x - before.x
            let dy = after.y - before.y
            let length = max(0.0001, hypot(dx, dy))
            return CGPoint(x: point.x + dy / length * offset, y: point.y - dx / length * offset)
        }
        var points = [offsetPoint(distance - tail, 0)]
        var forks: [RequestRailEffectProfile.Fork] = []
        var sum = 0.0
        for index in 0..<count {
            let item = profile.channel[index]
            sum += item.weight
            let position = Double(route.length) * sum / total
            guard position > distance - tail, position < distance else { continue }
            let offset =
                (item.offset * 0.3 + mix(previous.offsets[index], current.offsets[index]) * 0.7)
                * (1 - settle)
            let knot = offsetPoint(position, offset)
            points.append(knot)
            let charge = mix(previous.forks[index], current.forks[index])
            let energy = clamp((charge - 0.46) / 0.54)
            guard energy > 0, distance - position >= 2 else { continue }
            let reach = min(item.reach, Double(route.length) * 0.16, distance - position)
            forks.append(
                .init(
                    points: [
                        knot,
                        offsetPoint(position + reach * 0.3, -item.depth * 0.42 + item.kink * 0.5),
                        offsetPoint(position + reach * 0.63, -item.depth * 0.76 - item.kink * 0.3),
                        offsetPoint(position + reach, -item.depth),
                    ], energy: energy))
        }
        let head = route.point(at: profile.direction * distance)
        points.append(head)
        return .init(
            points: points, forks: forks, head: head, brightness: brightness, recharge: recharge)
    }

    private struct ReferencePerimeter {
        let length: CGFloat
        private let start: CGPoint
        private let pieces: [Piece]
        private enum Shape {
            case line(CGPoint, CGPoint)
            case arc(CGPoint, CGFloat, CGFloat)
        }
        private struct Piece {
            let offset, length: CGFloat
            let shape: Shape
        }
        init(rect: CGRect) {
            let radius = min(rect.width, rect.height) / 2
            let start = CGPoint(x: rect.maxX, y: rect.midY)
            self.start = start
            var cursor = start
            var total: CGFloat = 0
            var result: [Piece] = []
            func line(_ end: CGPoint) {
                let length = hypot(end.x - cursor.x, end.y - cursor.y)
                if length > 0 {
                    result.append(.init(offset: total, length: length, shape: .line(cursor, end)))
                }
                total += length
                cursor = end
            }
            func arc(_ center: CGPoint, _ angle: CGFloat) {
                let length = .pi * radius / 2
                if length > 0 {
                    result.append(
                        .init(offset: total, length: length, shape: .arc(center, angle, radius)))
                }
                total += length
                cursor = CGPoint(
                    x: center.x + radius * cos(angle + .pi / 2),
                    y: center.y + radius * sin(angle + .pi / 2))
            }
            line(CGPoint(x: rect.maxX, y: rect.maxY - radius))
            arc(CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), 0)
            line(CGPoint(x: rect.minX + radius, y: rect.maxY))
            arc(CGPoint(x: rect.minX + radius, y: rect.maxY - radius), .pi / 2)
            line(CGPoint(x: rect.minX, y: rect.minY + radius))
            arc(CGPoint(x: rect.minX + radius, y: rect.minY + radius), .pi)
            line(CGPoint(x: rect.maxX - radius, y: rect.minY))
            arc(CGPoint(x: rect.maxX - radius, y: rect.minY + radius), .pi * 1.5)
            line(start)
            length = total
            pieces = result
        }
        func point(at input: CGFloat) -> CGPoint {
            guard length > 0, input.isFinite else { return start }
            let distance = (input.truncatingRemainder(dividingBy: length) + length)
                .truncatingRemainder(dividingBy: length)
            guard
                let piece = pieces.first(where: { distance < $0.offset + $0.length }) ?? pieces.last
            else { return start }
            let p = min(1, max(0, (distance - piece.offset) / piece.length))
            switch piece.shape {
            case .line(let a, let b):
                return CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
            case .arc(let center, let angle, let radius):
                let angle = angle + p * .pi / 2
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
        }
    }

    private static func drawGlow(
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
    private static func circle(at point: CGPoint, radius: CGFloat) -> Path {
        Path(
            ellipseIn: CGRect(
                x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }
    private static func star(
        at point: CGPoint, size: CGFloat, angle: Double,
        rotation: CGAffineTransform? = nil
    ) -> Path {
        let inset = size * 0.24
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -size))
        path.addQuadCurve(to: CGPoint(x: size, y: 0), control: CGPoint(x: inset, y: -inset))
        path.addQuadCurve(to: CGPoint(x: 0, y: size), control: CGPoint(x: inset, y: inset))
        path.addQuadCurve(to: CGPoint(x: -size, y: 0), control: CGPoint(x: -inset, y: inset))
        path.addQuadCurve(to: CGPoint(x: 0, y: -size), control: CGPoint(x: -inset, y: -inset))
        path.closeSubpath()
        return path.applying(
            (rotation ?? CGAffineTransform(rotationAngle: angle)).concatenating(
                CGAffineTransform(translationX: point.x, y: point.y)))
    }
    private static func polyline(_ points: [CGPoint]) -> Path {
        var path = Path()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    // MARK: Independent native row, channel and alpha calibration

    private func calibrateCanvas(scale: CGFloat, gate: Gate) throws -> [String: Any] {
        func renderFixture() throws -> CGContext {
            try canvas(scale: scale, size: size) { context in
                context.fill(
                    Path(CGRect(x: 7, y: 11, width: 9, height: 13)),
                    with: .color(Color(.sRGB, red: 1, green: 0, blue: 0)))
                context.fill(
                    Path(CGRect(x: 75, y: 61, width: 11, height: 9)),
                    with: .color(Color(.sRGB, red: 0, green: 0, blue: 1)))
                context.fill(
                    Path(CGRect(x: 39, y: 27, width: 15, height: 11)),
                    with: .color(Color(.sRGB, red: 0.1, green: 0.7, blue: 0.3, opacity: 0.5)))
            }
        }
        let actual = try renderFixture()
        let expected = try renderFixture()
        let label = "canvas-calibration-s\(Int(scale))"
        var result = try comparison(
            actual, expected: expected, label: label, gate: gate, requiresVisible: true)
        var verified = true
        var samples: [[String: Any]] = []
        for (producer, bitmap) in [("cached-canvas", actual), ("original-canvas", expected)] {
            for (point, expectedRGBA) in [
                (CGPoint(x: 11, y: 17), [255, 0, 0, 255]),
                (CGPoint(x: 80, y: 65), [0, 0, 255, 255]),
                (CGPoint(x: 45, y: 32), [13, 89, 38, 128]),
                (CGPoint(x: 11, y: 70), [0, 0, 0, 0]),
                (CGPoint(x: 80, y: 22), [0, 0, 0, 0]),
            ] {
                let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
                let offset = Int(point.y * scale) * bitmap.bytesPerRow + Int(point.x * scale) * 4
                let rgba = (0..<4).map { Int(bytes[offset + $0]) }
                verified = verified && zip(rgba, expectedRGBA).allSatisfy { abs($0 - $1) <= 1 }
                samples.append([
                    "producer": producer, "xy": [Double(point.x), Double(point.y)],
                    "expected_rgba": expectedRGBA, "actual_rgba": rgba,
                ])
            }
        }
        let coverage = Int(381 * scale * scale)
        verified =
            verified && (result["actual_nonzero_alpha_pixels"] as? Int == coverage)
            && (result["expected_nonzero_alpha_pixels"] as? Int == coverage)
        result["fixture_samples"] = samples
        result["fixture_verified"] = verified
        result["scale"] = Double(scale)
        try gate.write(result, name: "\(label)-metrics.json")
        return result
    }

    private struct CalibrationVertex {
        let point: SIMD2<Float>
        let color: SIMD4<Float>
    }
    private func calibrate(_ renderer: Renderer, scale: CGFloat, gate: Gate) throws -> [String: Any]
    {
        let library = try renderer.device.makeLibrary(
            source: """
                #include <metal_stdlib>
                using namespace metal;
                struct Input { float2 point; float4 color; };
                struct Output { float4 position [[position]]; float4 color; };
                vertex Output calibrationVertex(uint id [[vertex_id]], constant Input *v [[buffer(0)]],
                                                constant float2 &size [[buffer(1)]]) {
                    return { float4(v[id].point.x / size.x * 2 - 1, 1 - v[id].point.y / size.y * 2, 0, 1), v[id].color };
                }
                fragment float4 calibrationFragment(Output in [[stage_in]]) { return in.color; }
                """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "calibrationVertex"))
        descriptor.fragmentFunction = try XCTUnwrap(
            library.makeFunction(name: "calibrationFragment"))
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try renderer.device.makeRenderPipelineState(descriptor: descriptor)
        let rectangles: [(CGRect, SIMD4<Float>)] = [
            (CGRect(x: 7, y: 11, width: 9, height: 13), SIMD4(1, 0, 0, 1)),
            (CGRect(x: 75, y: 61, width: 11, height: 9), SIMD4(0, 0, 1, 1)),
            (CGRect(x: 39, y: 27, width: 15, height: 11), SIMD4(0.05, 0.35, 0.15, 0.5)),
        ]
        var vertices: [CalibrationVertex] = []
        for (rect, color) in rectangles {
            for point in [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
            ] {
                vertices.append(.init(point: SIMD2(Float(point.x), Float(point.y)), color: color))
            }
        }
        let actual = try render(renderer, scale: scale, size: size) { command, texture in
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            vertices.withUnsafeBytes {
                encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
            }
            var pointSize = SIMD2(Float(size.width), Float(size.height))
            encoder.setVertexBytes(&pointSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()
        }
        let expected = try canvas(scale: scale, size: size) { context in
            context.fill(
                Path(CGRect(x: 7, y: 11, width: 9, height: 13)),
                with: .color(Color(.sRGB, red: 1, green: 0, blue: 0)))
            context.fill(
                Path(CGRect(x: 75, y: 61, width: 11, height: 9)),
                with: .color(Color(.sRGB, red: 0, green: 0, blue: 1)))
            context.fill(
                Path(CGRect(x: 39, y: 27, width: 15, height: 11)),
                with: .color(Color(.sRGB, red: 0.1, green: 0.7, blue: 0.3, opacity: 0.5)))
        }
        let label = "calibration-s\(Int(scale))"
        var result = try comparison(
            actual, expected: expected, label: label, gate: gate, requiresVisible: true)
        var verified = true
        var samples: [[String: Any]] = []
        for (producer, bitmap) in [("metal", actual), ("canvas", expected)] {
            for (point, expectedRGBA) in [
                (CGPoint(x: 11, y: 17), [255, 0, 0, 255]),
                (CGPoint(x: 80, y: 65), [0, 0, 255, 255]),
                (CGPoint(x: 45, y: 32), [13, 89, 38, 128]),
                (CGPoint(x: 11, y: 70), [0, 0, 0, 0]),
                (CGPoint(x: 80, y: 22), [0, 0, 0, 0]),
            ] {
                let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
                let offset = Int(point.y * scale) * bitmap.bytesPerRow + Int(point.x * scale) * 4
                let rgba = (0..<4).map { Int(bytes[offset + $0]) }
                verified = verified && zip(rgba, expectedRGBA).allSatisfy { abs($0 - $1) <= 1 }
                samples.append([
                    "producer": producer, "xy": [Double(point.x), Double(point.y)],
                    "expected_rgba": expectedRGBA, "actual_rgba": rgba,
                ])
            }
        }
        let coverage = Int(381 * scale * scale)
        verified =
            verified && (result["actual_nonzero_alpha_pixels"] as? Int == coverage)
            && (result["expected_nonzero_alpha_pixels"] as? Int == coverage)
        result["fixture_samples"] = samples
        result["fixture_verified"] = verified
        try gate.write(result, name: "\(label)-metrics.json")
        return result
    }

    // MARK: Bounded native execution and calibrated direct readback

    private final class Resources: @unchecked Sendable {
        let renderer: Renderer
        let texture: any MTLTexture
        let buffer: any MTLBuffer
        init(_ renderer: Renderer, _ texture: any MTLTexture, _ buffer: any MTLBuffer) {
            self.renderer = renderer
            self.texture = texture
            self.buffer = buffer
        }
    }
    private func render(
        _ renderer: Renderer, scale: CGFloat, size: CGSize,
        encode: (any MTLCommandBuffer, any MTLTexture) throws -> Void
    ) throws -> CGContext {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(size.width * scale),
            height: Int(size.height * scale), mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let rowBytes = (texture.width * 4 + 255) / 256 * 256
        let buffer = try XCTUnwrap(
            renderer.device.makeBuffer(
                length: rowBytes * texture.height, options: .storageModeShared))
        let queue = try XCTUnwrap(renderer.device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        defer { if command.status == .notEnqueued { command.commit() } }
        try encode(command, texture)
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        let complete = DispatchSemaphore(value: 0)
        let resources = Resources(renderer, texture, buffer)
        command.addCompletedHandler { _ in withExtendedLifetime(resources) { complete.signal() } }
        command.commit()
        guard complete.wait(timeout: .now() + 5) == .success else {
            throw Failure.failed("GPU completion timeout after five seconds")
        }
        guard command.status == .completed, command.error == nil else {
            throw Failure.failed("GPU command failed: \(String(describing: command.error))")
        }
        let result = try bitmap(width: texture.width, height: texture.height)
        let target = try XCTUnwrap(result.data).assumingMemoryBound(to: UInt8.self)
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        for y in 0..<texture.height {
            for x in 0..<texture.width {
                let from = y * rowBytes + x * 4
                let to = y * result.bytesPerRow + x * 4
                target[to] = source[from + 2]
                target[to + 1] = source[from + 1]
                target[to + 2] = source[from]
                target[to + 3] = source[from + 3]
            }
        }
        return result
    }
    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
    }
    private func canvas(
        scale: CGFloat, size: CGSize, drawing: @escaping (inout GraphicsContext) -> Void
    ) throws -> CGContext {
        let context = try bitmap(width: Int(size.width * scale), height: Int(size.height * scale))
        context.clear(
            CGRect(
                origin: .zero,
                size: CGSize(width: CGFloat(context.width), height: CGFloat(context.height))))
        context.scaleBy(x: scale, y: scale)
        let renderer = ImageRenderer(content: Canvas { context, _ in drawing(&context) })
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        renderer.render(rasterizationScale: scale) { _, draw in draw(context) }
        return context
    }
    private func comparison(
        _ actual: CGContext, expected: CGContext, label: String, gate: Gate,
        requiresVisible: Bool
    ) throws -> [String: Any] {
        guard actual.width == expected.width, actual.height == expected.height else {
            throw Failure.failed("Mismatched fidelity dimensions")
        }
        let a = try XCTUnwrap(actual.data).assumingMemoryBound(to: UInt8.self)
        let b = try XCTUnwrap(expected.data).assumingMemoryBound(to: UInt8.self)
        let differenceImage = try bitmap(width: actual.width, height: actual.height)
        let difference = try XCTUnwrap(differenceImage.data).assumingMemoryBound(to: UInt8.self)
        var maximum = [Int](repeating: 0, count: 4)
        var sums = [UInt64](repeating: 0, count: 4)
        var squared = [Double](repeating: 0, count: 4)
        var differing = 0
        var aboveGate = 0
        var actualVisible = 0
        var expectedVisible = 0
        var firstDifference: [Int]?
        for y in 0..<actual.height {
            for x in 0..<actual.width {
                let ai = y * actual.bytesPerRow + x * 4
                let bi = y * expected.bytesPerRow + x * 4
                let di = y * differenceImage.bytesPerRow + x * 4
                if a[ai + 3] > 0 { actualVisible += 1 }
                if b[bi + 3] > 0 { expectedVisible += 1 }
                var different = false
                var outsideGate = false
                for channel in 0..<4 {
                    let delta = abs(Int(a[ai + channel]) - Int(b[bi + channel]))
                    maximum[channel] = max(maximum[channel], delta)
                    sums[channel] += UInt64(delta)
                    squared[channel] += Double(delta * delta)
                    different = different || delta > 0
                    outsideGate = outsideGate || delta > gate.maximumAllowedChannelDifference
                    difference[di + channel] = UInt8(delta)
                }
                difference[di + 3] = 255
                if different {
                    differing += 1
                    if firstDifference == nil { firstDifference = [x, y] }
                }
                if outsideGate { aboveGate += 1 }
            }
        }
        let pixels = Double(actual.width * actual.height)
        let contentVerified =
            requiresVisible
            ? actualVisible > 0 && expectedVisible > 0 : actualVisible == 0 && expectedVisible == 0
        let result: [String: Any] = [
            "label": label, "width": actual.width, "height": actual.height,
            "maximum_rgba_difference": maximum, "absolute_rgba_difference_sums": sums,
            "rms_rgba_difference": squared.map { sqrt($0 / pixels) },
            "differing_pixels": differing, "pixels_above_gate": aboveGate,
            "first_difference_xy": firstDifference as Any? ?? NSNull(),
            "actual_nonzero_alpha_pixels": actualVisible,
            "expected_nonzero_alpha_pixels": expectedVisible,
            "requires_visible_content": requiresVisible, "content_verified": contentVerified,
            "maximum_allowed_channel_difference": gate.maximumAllowedChannelDifference,
            "within_gate": contentVerified
                && maximum.allSatisfy { $0 <= gate.maximumAllowedChannelDifference },
            "format": "sRGB encoded premultiplied RGBA8",
            "row_order": "upper-left row first, direct calibrated mapping",
        ]
        try gate.save(actual, name: "\(label)-\(gate.candidateImageLabel).png")
        try gate.save(expected, name: "\(label)-\(gate.referenceImageLabel).png")
        try gate.save(differenceImage, name: "\(label)-absolute-difference.png")
        return result
    }

    // MARK: Explicit output gate; native results never enter Git

    private enum Failure: Error { case failed(String) }
    private struct Gate {
        let directory: URL
        let maximumAllowedChannelDifference: Int
        let candidateImageLabel: String
        let referenceImageLabel: String
        let scope: String

        init(
            directory: URL, maximumAllowedChannelDifference: Int = 2,
            candidateImageLabel: String = "metal", referenceImageLabel: String = "canvas",
            scope: String =
                "Native Metal particle/lightning/glint primitives against independent original Canvas; includes cropped origins, ordered overlap and exact blank endpoints; excludes static chart, text and live CPU/GPU resource acceptance"
        ) {
            self.directory = directory
            self.maximumAllowedChannelDifference = maximumAllowedChannelDifference
            self.candidateImageLabel = candidateImageLabel
            self.referenceImageLabel = referenceImageLabel
            self.scope = scope
        }
        func write(_ value: [String: Any], name: String) throws {
            try JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys]
            )
            .write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
        }
        func summary(status: String, cases: [[String: Any]], device: String?, error: String?) throws
        {
            try write(
                [
                    "schema_version": 1, "status": status, "cases": cases,
                    "device": device as Any? ?? NSNull(), "error": error as Any? ?? NSNull(),
                    "maximum_allowed_channel_difference": maximumAllowedChannelDifference,
                    "scope": scope,
                ],
                name: "result.json")
        }
        func failureIfAbsent(_ error: any Error, cases: [[String: Any]], device: String?) throws {
            if !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("result.json").path)
            {
                try summary(
                    status: "failed", cases: cases, device: device, error: String(describing: error)
                )
            }
        }
        func save(_ context: CGContext, name: String) throws {
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
        }
    }
    private func nativeGate() throws -> Gate {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLUXLLM_RUN_METAL_PRIMITIVE_FIDELITY"] == "1" else {
            throw XCTSkip(
                "Set FLUXLLM_RUN_METAL_PRIMITIVE_FIDELITY=1 and FLUXLLM_METAL_PRIMITIVE_FIDELITY_OUTPUT for the native pixel gate"
            )
        }
        guard let path = environment["FLUXLLM_METAL_PRIMITIVE_FIDELITY_OUTPUT"], !path.isEmpty
        else {
            throw Failure.failed("Explicit FLUXLLM_METAL_PRIMITIVE_FIDELITY_OUTPUT is required")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ignored = repository.appendingPathComponent(".performance-results", isDirectory: true)
            .resolvingSymlinksInPath()
        let requested =
            (path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : repository.appendingPathComponent(path, isDirectory: true)).standardizedFileURL
            .resolvingSymlinksInPath()
        guard requested.path == ignored.path || requested.path.hasPrefix(ignored.path + "/") else {
            throw Failure.failed(
                "Native pixel results must be under the ignored .performance-results directory")
        }
        let directory = requested.appendingPathComponent(
            "primitive-effects-fidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("FLUXLLM_METAL_PRIMITIVE_FIDELITY_OUTPUT=\(directory.path)")
        return Gate(directory: directory)
    }

    private func railGeometryGate() throws -> Gate {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLUXLLM_RUN_RAIL_GEOMETRY_FIDELITY"] == "1" else {
            throw XCTSkip(
                "Set FLUXLLM_RUN_RAIL_GEOMETRY_FIDELITY=1 and FLUXLLM_RAIL_GEOMETRY_FIDELITY_OUTPUT for the cached normal Canvas pixel gate"
            )
        }
        guard let path = environment["FLUXLLM_RAIL_GEOMETRY_FIDELITY_OUTPUT"], !path.isEmpty else {
            throw Failure.failed("Explicit FLUXLLM_RAIL_GEOMETRY_FIDELITY_OUTPUT is required")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ignored = repository.appendingPathComponent(".performance-results", isDirectory: true)
            .resolvingSymlinksInPath()
        let requested =
            (path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : repository.appendingPathComponent(path, isDirectory: true)).standardizedFileURL
            .resolvingSymlinksInPath()
        guard requested.path == ignored.path || requested.path.hasPrefix(ignored.path + "/") else {
            throw Failure.failed(
                "Cached Canvas pixel results must be under ignored .performance-results")
        }
        let directory = requested.appendingPathComponent(
            "rail-geometry-fidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("FLUXLLM_RAIL_GEOMETRY_FIDELITY_OUTPUT=\(directory.path)")
        return Gate(
            directory: directory, maximumAllowedChannelDifference: 0,
            candidateImageLabel: "cached-canvas", referenceImageLabel: "original-canvas",
            scope:
                "Normal Canvas with cached invariant rail effect geometry against independent original Canvas; exact pixel equality at 1x and 2x, cropped fractional origins, ordered overlap, wide clipped channel and blank endpoints; excludes static chart, text and live CPU/GPU resource acceptance"
        )
    }
}
