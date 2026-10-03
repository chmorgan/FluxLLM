import AppKit
import Foundation
import simd

/// Immutable publication geometry for the full-chart Metal surface. Animation
/// descriptors live separately: submitting an animation frame never rebuilds
/// these paths, colors, labels, or buffers.
final class MetalFullChartScene {
    struct Stop: Equatable {
        let location: CGFloat
        let color: SIMD4<Float>
    }

    enum Paint: Equatable {
        case solid(SIMD4<Float>)
        case linear(start: CGPoint, end: CGPoint, stops: [Stop])
    }

    enum Shape: Equatable {
        case polygon([CGPoint])
        case polyline([CGPoint])
        case ellipse(CGRect)
        case roundedRect(CGRect, radius: CGFloat)
    }

    struct Stroke: Equatable {
        enum Cap: Equatable { case butt, round }
        let width: CGFloat
        let dash: [CGFloat]
        let blurRadius: CGFloat
        let cap: Cap

        init(width: CGFloat, dash: [CGFloat] = [], blurRadius: CGFloat = 0, cap: Cap = .round) {
            self.width = width
            self.dash = dash
            self.blurRadius = blurRadius
            self.cap = cap
        }
    }

    struct RoundedClip: Equatable {
        let rect: CGRect
        let radius: CGFloat
    }

    struct Primitive: Equatable {
        let shape: Shape
        let paint: Paint
        let stroke: Stroke?
        let clip: RoundedClip?

        init(shape: Shape, paint: Paint, stroke: Stroke? = nil, clip: RoundedClip? = nil) {
            self.shape = shape
            self.paint = paint
            self.stroke = stroke
            self.clip = clip
        }
    }

    /// Text remains an ordinary accessible-platform text primitive rather than
    /// becoming a raster texture. These are the three labels formerly inside
    /// the static Canvas; axes and inspection already belong to SwiftUI.
    struct Label: Equatable {
        enum Role: Equatable { case requestHeading, emptyRequests, overflow }
        let role: Role
        let text: String
        let position: CGPoint
        let color: SIMD4<Float>
        let fontSize: CGFloat
        let leadingAligned: Bool
    }

    struct Style: Equatable {
        let generatedColor: SIMD4<Float>
        let deviceColor: SIMD4<Float>
        let backgroundColor: SIMD4<Float>
        let primaryColor: SIMD4<Float>
        let secondaryColor: SIMD4<Float>
        let compact: Bool
        let hasEffects: Bool
        let increasedContrast: Bool
        let isDark: Bool

        var seriesStrokeWidth: CGFloat { increasedContrast ? 2.8 : (compact ? 2.2 : 2.7) }
        var toolStrokeWidth: CGFloat { increasedContrast ? 2.2 : 1.6 }
    }

    let size: CGSize
    let primitives: [Primitive]
    let labels: [Label]

    init(size: CGSize, primitives: [Primitive], labels: [Label] = []) {
        self.size = size
        self.primitives = primitives
        self.labels = labels
    }

    static func make(
        frame: LuminousChartGeometryCache.Frame, lanes: [RequestLane],
        laneColors: [UUID: SIMD4<Float>], segments: [RequestRailGeometry.Segment],
        overflow: [RequestRailGeometry.OverflowSegment], style: Style
    ) -> MetalFullChartScene {
        var primitives: [Primitive] = []
        var labels: [Label] = []
        let layout = frame.layout
        let grid = opacity(style.primaryColor, style.increasedContrast ? 0.3 : 0.10)
        for fraction in [0.0, 0.5, 1.0] {
            let y = layout.main.minY + fraction * layout.main.height
            primitives.append(
                .init(
                    shape: .polyline([
                        CGPoint(x: layout.main.minX, y: y),
                        CGPoint(x: layout.main.maxX, y: y),
                    ]),
                    paint: .solid(grid), stroke: .init(width: 0.6, cap: .butt)))
        }
        if frame.key.hasTools {
            primitives.append(
                .init(
                    shape: .polyline([
                        CGPoint(x: layout.tools.minX, y: layout.tools.maxY),
                        CGPoint(x: layout.tools.maxX, y: layout.tools.maxY),
                    ]),
                    paint: .solid(grid), stroke: .init(width: 0.6, cap: .butt)))
        }
        // Preserve source composition order, including each segment's glow
        // before its primary stroke and the duplicate single-point endpoint.
        appendSeries(
            frame.device, color: style.deviceColor, fillOpacity: 0.14,
            rect: layout.main, style: style, to: &primitives)
        appendSeries(
            frame.generated, color: style.generatedColor, fillOpacity: 0.25,
            rect: layout.main, style: style, to: &primitives)
        appendEndpoint(
            frame.generatedEndpoint, color: style.generatedColor,
            style: style, to: &primitives)
        appendEndpoint(
            frame.deviceEndpoint, color: style.deviceColor,
            style: style, to: &primitives)
        let tools = frame.requestTools
        for lane in lanes {
            guard let track = tools[lane.id], let color = laneColors[lane.id] else { continue }
            for segment in track.segments {
                primitives.append(
                    .init(
                        shape: .polyline(segment.points), paint: .solid(color),
                        stroke: .init(width: style.toolStrokeWidth, dash: [4, 3])))
            }
            for point in track.resultPoints {
                primitives.append(
                    .init(
                        shape: .polygon([
                            CGPoint(x: point.x, y: point.y - 3),
                            CGPoint(x: point.x + 3, y: point.y),
                            CGPoint(x: point.x, y: point.y + 3),
                            CGPoint(x: point.x - 3, y: point.y),
                        ]), paint: .solid(color)))
            }
        }
        if !style.compact {
            if layout.lanes.height > 0 {
                labels.append(
                    .init(
                        role: .requestHeading, text: "Requests",
                        position: CGPoint(x: layout.lanes.minX, y: layout.lanes.minY - 6),
                        color: style.secondaryColor, fontSize: 9, leadingAligned: true))
            }
            if segments.isEmpty && overflow.isEmpty {
                labels.append(
                    .init(
                        role: .emptyRequests, text: "No recent requests",
                        position: CGPoint(
                            x: layout.lanes.minX,
                            y: layout.lanes.minY + RequestRailGeometry.trackPitch / 2),
                        color: style.secondaryColor, fontSize: 10, leadingAligned: true))
            }
            for segment in segments {
                guard let color = laneColors[segment.lane.id] else { continue }
                let bar = segment.rect
                let paint: Paint =
                    style.hasEffects
                    ? .linear(
                        start: CGPoint(x: bar.minX, y: bar.midY),
                        end: CGPoint(x: bar.maxX, y: bar.midY),
                        stops: [
                            .init(location: 0, color: opacity(color, 0.42)),
                            .init(location: 0.5, color: opacity(color, segment.isLive ? 1 : 0.83)),
                            .init(location: 1, color: opacity(color, segment.isLive ? 1 : 0.88)),
                        ]) : .solid(color)
                primitives.append(
                    .init(
                        shape: .roundedRect(bar, radius: segment.cornerRadius), paint: paint))
                if segment.isLive {
                    let point = CGPoint(x: bar.maxX - segment.cornerRadius, y: bar.midY)
                    let clip = RoundedClip(rect: bar, radius: segment.cornerRadius)
                    primitives.append(
                        .init(
                            shape: .ellipse(circle(point, radius: 3.5)),
                            paint: .solid(color), clip: clip))
                    primitives.append(
                        .init(
                            shape: .ellipse(circle(point, radius: 1.2)),
                            paint: .solid(SIMD4(1, 1, 1, 1)), clip: clip))
                }
            }
            for segment in overflow {
                primitives.append(
                    .init(
                        shape: .roundedRect(segment.rect, radius: min(3.5, segment.rect.width / 2)),
                        paint: .solid(
                            opacity(style.secondaryColor, style.increasedContrast ? 0.8 : 0.3))))
                let label = "+\(segment.count)"
                if segment.rect.width >= 24, overflowLabelWidth(label) + 4 <= segment.rect.width {
                    labels.append(
                        .init(
                            role: .overflow, text: label,
                            position: CGPoint(x: segment.rect.midX, y: segment.rect.midY),
                            color: style.primaryColor, fontSize: 11, leadingAligned: false))
                }
            }
        }
        return MetalFullChartScene(size: frame.key.size, primitives: primitives, labels: labels)
    }

    /// Hover uses a separate retained buffer. Moving the cursor cannot rebuild
    /// chart history geometry or re-upload the static chart's vertices.
    static func cursor(
        frame: LuminousChartGeometryCache.Frame, x: CGFloat?, style: Style
    ) -> MetalFullChartScene {
        guard let x, x.isFinite else {
            return MetalFullChartScene(size: frame.key.size, primitives: [])
        }
        let layout = frame.layout
        let bottom =
            frame.key.hasTools
            ? layout.tools.maxY
            : (style.compact ? layout.main.maxY : layout.lanes.maxY)
        var primitives: [Primitive] = [
            .init(
                shape: .polyline([CGPoint(x: x, y: layout.main.minY), CGPoint(x: x, y: bottom)]),
                paint: .solid(opacity(style.secondaryColor, 0.55)),
                stroke: .init(width: 0.8, cap: .butt))
        ]
        for (segments, color) in [
            (frame.generated, style.generatedColor),
            (frame.device, style.deviceColor),
        ] {
            if let y = segments.reversed().lazy.compactMap({ $0.inspectedY(atX: x) }).first {
                appendEndpoint(CGPoint(x: x, y: y), color: color, style: style, to: &primitives)
            }
        }
        return MetalFullChartScene(size: frame.key.size, primitives: primitives)
    }

    private static func appendSeries(
        _ segments: [LuminousChartGeometryCache.Segment], color: SIMD4<Float>,
        fillOpacity: Float, rect: CGRect, style: Style, to result: inout [Primitive]
    ) {
        for segment in segments {
            guard let first = segment.points.first else { continue }
            let points = flattened(segment)
            if style.hasEffects, segment.points.count > 1,
                let start = points.first, let end = points.last
            {
                result.append(
                    .init(
                        shape: .polygon(
                            points + [
                                CGPoint(x: end.x, y: rect.maxY),
                                CGPoint(x: start.x, y: rect.maxY),
                            ]),
                        paint: .linear(
                            start: CGPoint(x: 0, y: rect.minY),
                            end: CGPoint(x: 0, y: rect.maxY),
                            stops: [
                                .init(location: 0, color: opacity(color, fillOpacity)),
                                .init(location: 1, color: opacity(color, 0.01)),
                            ])))
                result.append(
                    .init(
                        shape: .polyline(points),
                        paint: .solid(opacity(color, style.isDark ? 0.35 : 0.24)),
                        stroke: .init(width: 7, blurRadius: style.compact ? 2.5 : 3)))
            }
            result.append(
                .init(
                    shape: .polyline(points), paint: .solid(color),
                    stroke: .init(width: style.seriesStrokeWidth)))
            if segment.points.count == 1 {
                appendEndpoint(first, color: color, style: style, to: &result)
            }
        }
    }

    private static func appendEndpoint(
        _ point: CGPoint?, color: SIMD4<Float>, style: Style, to result: inout [Primitive]
    ) {
        guard let point else { return }
        if style.hasEffects {
            result.append(
                .init(
                    shape: .ellipse(circle(point, radius: 6)),
                    paint: .solid(opacity(color, 0.13))))
        }
        let marker = circle(point, radius: 2.5)
        result.append(.init(shape: .ellipse(marker), paint: .solid(style.backgroundColor)))
        result.append(
            .init(shape: .ellipse(marker), paint: .solid(color), stroke: .init(width: 1.7)))
    }

    /// Subdivide the retained monotone cubic, not its original data samples.
    /// Bounding both control points' distance from the chord bounds the curve's
    /// geometric error; a depth cap also bounds malformed geometry work.
    static func flattened(_ segment: LuminousChartGeometryCache.Segment) -> [CGPoint] {
        guard !segment.spans.isEmpty else { return segment.points }
        var points = [segment.spans[0].start]
        for span in segment.spans {
            if span.isVertical {
                points.append(span.end)
            } else {
                flatten(span.start, span.control1, span.control2, span.end, depth: 0, into: &points)
            }
        }
        return points
    }

    private static func flatten(
        _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint,
        depth: Int, into result: inout [CGPoint]
    ) {
        let dx = d.x - a.x
        let dy = d.y - a.y
        let length = hypot(dx, dy)
        let error =
            length > 0
            ? max(
                abs(dx * (b.y - a.y) - dy * (b.x - a.x)),
                abs(dx * (c.y - a.y) - dy * (c.x - a.x))) / length
            : max(hypot(b.x - a.x, b.y - a.y), hypot(c.x - a.x, c.y - a.y))
        guard depth < 12, error > 0.08 else {
            result.append(d)
            return
        }
        let ab = midpoint(a, b)
        let bc = midpoint(b, c)
        let cd = midpoint(c, d)
        let abc = midpoint(ab, bc)
        let bcd = midpoint(bc, cd)
        let middle = midpoint(abc, bcd)
        flatten(a, ab, abc, middle, depth: depth + 1, into: &result)
        flatten(middle, bcd, cd, d, depth: depth + 1, into: &result)
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private static func circle(_ point: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func opacity(_ color: SIMD4<Float>, _ opacity: Float) -> SIMD4<Float> {
        SIMD4(color.x, color.y, color.z, color.w * opacity)
    }

    private static func overflowLabelWidth(_ text: String) -> CGFloat {
        let base = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let font =
            base.fontDescriptor.withDesign(.rounded).flatMap {
                NSFont(descriptor: $0, size: 11)
            } ?? base
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// One cache per chart. Keys only inspect small presentation values; immutable
/// frame identity avoids hashing or comparing history samples on hover.
final class MetalFullChartSceneCache {
    private struct Key: Equatable {
        let frame: ObjectIdentifier
        let lanes: [RequestLane]
        let colors: [UUID: SIMD4<Float>]
        let segments: [RequestRailGeometry.Segment]
        let overflow: [RequestRailGeometry.OverflowSegment]
        let style: MetalFullChartScene.Style
    }
    private var retained: (Key, MetalFullChartScene)?
    private var retainedCursor:
        (ObjectIdentifier, CGFloat?, MetalFullChartScene.Style, MetalFullChartScene)?
    // An ObjectIdentifier is only unique while its object is alive. Retain the
    // corresponding immutable frame until replacing each cache entry so a new
    // allocation at the same address cannot masquerade as that publication.
    private var retainedFrame: LuminousChartGeometryCache.Frame?
    private var retainedCursorFrame: LuminousChartGeometryCache.Frame?

    func scene(
        frame: LuminousChartGeometryCache.Frame, lanes: [RequestLane],
        laneColors: [UUID: SIMD4<Float>], segments: [RequestRailGeometry.Segment],
        overflow: [RequestRailGeometry.OverflowSegment], style: MetalFullChartScene.Style
    ) -> MetalFullChartScene {
        let key = Key(
            frame: ObjectIdentifier(frame), lanes: lanes, colors: laneColors,
            segments: segments, overflow: overflow, style: style)
        if let retained, retained.0 == key { return retained.1 }
        let scene = MetalFullChartScene.make(
            frame: frame, lanes: lanes, laneColors: laneColors,
            segments: segments, overflow: overflow, style: style)
        retainedFrame = frame
        retained = (key, scene)
        return scene
    }

    func cursor(
        frame: LuminousChartGeometryCache.Frame, x: CGFloat?, style: MetalFullChartScene.Style
    ) -> MetalFullChartScene {
        let identity = ObjectIdentifier(frame)
        if let retainedCursor, retainedCursor.0 == identity,
            retainedCursor.1 == x, retainedCursor.2 == style
        {
            return retainedCursor.3
        }
        let scene = MetalFullChartScene.cursor(frame: frame, x: x, style: style)
        retainedCursorFrame = frame
        retainedCursor = (identity, x, style, scene)
        return scene
    }
}
