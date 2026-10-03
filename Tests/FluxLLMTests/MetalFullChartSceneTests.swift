import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class MetalFullChartSceneTests: XCTestCase {
    private typealias Geometry = LuminousChartGeometryCache
    private typealias Scene = MetalFullChartScene
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let requestID = UUID()
    private let secondID = UUID()
    private let generated = SIMD4<Float>(0.2, 0.8, 0.4, 1)
    private let device = SIMD4<Float>(0.3, 0.4, 0.9, 1)
    private let firstTool = SIMD4<Float>(0.9, 0.2, 0.1, 1)
    private let secondTool = SIMD4<Float>(0.9, 0.8, 0.1, 1)

    func testDisablingDrawingPathsPreservesProjectionCurvesMarkersAndInspection() throws {
        for compact in [false, true] {
            for duration in [60.0, 75.25, 300] {
                for size in [CGSize(width: 640, height: 320), CGSize(width: 401.5, height: 247.25)]
                {
                    let key = key(compact: compact, duration: duration, size: size)
                    let source = frame(key: key, buildPaths: true)
                    let metal = frame(key: key, buildPaths: false)
                    XCTAssertFalse(metal.buildDrawingPaths)
                    XCTAssertEqual(metal.layout.main, source.layout.main)
                    XCTAssertEqual(metal.layout.lanes, source.layout.lanes)
                    XCTAssertEqual(metal.layout.tools, source.layout.tools)
                    XCTAssertEqual(metal.generatedEndpoint, source.generatedEndpoint)
                    XCTAssertEqual(metal.deviceEndpoint, source.deviceEndpoint)
                    XCTAssertTrue(source.generated.contains { !$0.trace.isEmpty })
                    assertSameGeometry(metal.generated, source.generated)
                    assertSameGeometry(metal.device, source.device)
                    for id in [requestID, secondID] {
                        let expected = try XCTUnwrap(source.requestTools[id])
                        let actual = try XCTUnwrap(metal.requestTools[id])
                        assertSameGeometry(actual.segments, expected.segments)
                        XCTAssertEqual(actual.resultPoints, expected.resultPoints)
                        XCTAssertFalse(expected.resultDiamonds.isEmpty)
                        XCTAssertTrue(actual.resultDiamonds.isEmpty)
                    }
                }
            }
        }
    }

    func testDrawingPathStrategyInvalidatesFrameWithoutChangingPublication() {
        let cache = Geometry()
        let key = key()
        let source = frame(cache: cache, key: key, buildPaths: true)
        XCTAssertTrue(frame(cache: cache, key: key, buildPaths: true) === source)
        let metal = frame(cache: cache, key: key, buildPaths: false)
        XCTAssertFalse(metal === source)
        XCTAssertEqual(metal.key, source.key)
        XCTAssertTrue(frame(cache: cache, key: key, buildPaths: false) === metal)
        let restored = frame(cache: cache, key: key, buildPaths: true)
        XCTAssertFalse(restored === metal)
        XCTAssertFalse(restored === source)
        XCTAssertTrue(restored.generated.contains { !$0.trace.isEmpty })
    }

    func testScenePreservesSeriesToolsAndRailCompositionOrder() throws {
        let frame = frame(buildPaths: false)
        let scene = makeScene(frame: frame)
        let primitives = scene.primitives
        XCTAssertEqual(scene.size, frame.key.size)
        XCTAssertTrue(primitives.prefix(4).allSatisfy { $0.stroke?.width == 0.6 })
        XCTAssertTrue(primitives.prefix(4).allSatisfy { $0.stroke?.cap == .butt })
        let deviceFill = try XCTUnwrap(primitives.firstIndex { isFill($0, color: device) })
        let generatedFill = try XCTUnwrap(primitives.firstIndex { isFill($0, color: generated) })
        let firstToolIndex = try XCTUnwrap(primitives.firstIndex { $0.stroke?.dash == [4, 3] })
        let firstBar = try XCTUnwrap(
            primitives.firstIndex {
                if case .roundedRect = $0.shape { return true }
                return false
            })
        XCTAssertEqual(deviceFill, 4)
        XCTAssertLessThan(deviceFill, generatedFill)
        XCTAssertLessThan(generatedFill, firstToolIndex)
        XCTAssertLessThan(firstToolIndex, firstBar)
        for index in [deviceFill, generatedFill] {
            XCTAssertEqual(primitives[index + 1].stroke?.width, 7)
            XCTAssertEqual(primitives[index + 1].stroke?.blurRadius, 3)
            XCTAssertEqual(primitives[index + 2].stroke?.width, 2.7)
        }
        let toolStrokes = primitives.filter { $0.stroke?.dash == [4, 3] }
        let toolColors = toolStrokes.compactMap { primitive -> SIMD4<Float>? in
            if case .solid(let color) = primitive.paint { return color }
            return nil
        }
        XCTAssertEqual(
            toolColors,
            Array(repeating: firstTool, count: frame.requestTools[requestID]!.segments.count)
                + Array(repeating: secondTool, count: frame.requestTools[secondID]!.segments.count))
        XCTAssertTrue(toolStrokes.allSatisfy { $0.stroke?.width == 1.6 })
        XCTAssertTrue(toolStrokes.allSatisfy { $0.stroke?.cap == .round })
        let firstDiamond = try XCTUnwrap(
            primitives.firstIndex {
                guard case .polygon(let vertices) = $0.shape else { return false }
                return vertices.count == 4 && $0.paint == .solid(firstTool)
            })
        let secondToolIndex = try XCTUnwrap(
            primitives.firstIndex {
                $0.stroke?.dash == [4, 3] && $0.paint == .solid(secondTool)
            })
        XCTAssertLessThan(firstDiamond, secondToolIndex)
        let liveHead = try XCTUnwrap(primitives[(firstBar + 1)...].first { $0.clip != nil })
        XCTAssertEqual(liveHead.clip?.rect, railSegments(frame).first?.rect)
        XCTAssertEqual(liveHead.clip?.radius, railSegments(frame).first?.cornerRadius)
    }

    func testContrastPreservesVisibleTracesBarsAndMarkersWithoutTranslucentEffects() throws {
        let frame = frame(buildPaths: false)
        let scene = makeScene(frame: frame, style: style(increasedContrast: true))
        XCTAssertTrue(
            scene.primitives.allSatisfy {
                if case .solid = $0.paint { return true }
                return false
            })
        XCTAssertFalse(scene.primitives.contains { ($0.stroke?.blurRadius ?? 0) > 0 })
        XCTAssertTrue(scene.primitives.contains { $0.stroke?.width == 2.8 })
        XCTAssertTrue(
            scene.primitives.contains { $0.stroke?.width == 2.2 && $0.stroke?.dash == [4, 3] })
        let bars = scene.primitives.filter {
            if case .roundedRect = $0.shape { return true }
            return false
        }
        XCTAssertEqual(bars.count, lanes.count)
        XCTAssertEqual(bars.map(\.paint), [.solid(firstTool), .solid(secondTool)])
        XCTAssertTrue(scene.primitives.contains { $0.stroke?.width == 1.7 })
        XCTAssertFalse(
            scene.primitives.contains {
                if case .ellipse(let rect) = $0.shape { return rect.width == 12 }
                return false
            })
        guard case .solid(let grid) = try XCTUnwrap(scene.primitives.first).paint else {
            return XCTFail("Grid must retain a solid stroke")
        }
        XCTAssertEqual(grid.w, 0.3, accuracy: 0.000001)
    }

    func testCursorMovesIndependentlyWithoutRebuildingStaticScene() throws {
        let cache = MetalFullChartSceneCache()
        let frame = frame(buildPaths: false)
        let style = style()
        let staticScene = cachedScene(cache, frame: frame, style: style)
        let empty = cache.cursor(frame: frame, x: nil, style: style)
        XCTAssertTrue(empty.primitives.isEmpty)
        let x = frame.generated.last!.points.last!.x
        let cursor = cache.cursor(frame: frame, x: x, style: style)
        XCTAssertTrue(cache.cursor(frame: frame, x: x, style: style) === cursor)
        XCTAssertTrue(cachedScene(cache, frame: frame, style: style) === staticScene)
        let moved = cache.cursor(frame: frame, x: x - 1, style: style)
        XCTAssertFalse(moved === cursor)
        XCTAssertTrue(cachedScene(cache, frame: frame, style: style) === staticScene)
        guard case .polyline(let line) = try XCTUnwrap(cursor.primitives.first).shape else {
            return XCTFail("Cursor must start with its vertical guide")
        }
        XCTAssertEqual(
            line,
            [
                CGPoint(x: x, y: frame.layout.main.minY),
                CGPoint(x: x, y: frame.layout.tools.maxY),
            ])
        XCTAssertEqual(cursor.primitives.first?.stroke?.cap, .butt)
        let expectedY = try XCTUnwrap(frame.generated.last?.inspectedY(atX: x))
        XCTAssertTrue(
            cursor.primitives.contains {
                if case .ellipse(let rect) = $0.shape {
                    return rect.midX == x && rect.midY == expectedY && rect.width == 5
                }
                return false
            })
        let changedStyle = self.style(increasedContrast: true)
        XCTAssertFalse(cachedScene(cache, frame: frame, style: changedStyle) === staticScene)
    }

    func testCachesRetainOnlyTheirLatestPublicationAndReleaseTheirFrames() {
        var cache: MetalFullChartSceneCache? = MetalFullChartSceneCache()
        var initial: Geometry.Frame? = frame(buildPaths: false)
        weak var firstFrame = initial
        weak var firstScene = cachedScene(cache!, frame: initial!, style: style())
        weak var firstCursor = cache!.cursor(frame: initial!, x: 100, style: style())
        initial = nil
        XCTAssertNotNil(firstFrame, "Scene identities must keep their originating object alive")
        let replacement = frame(buildPaths: false)
        weak var replacementScene = cachedScene(cache!, frame: replacement, style: style())
        XCTAssertNil(firstScene)
        XCTAssertNotNil(firstFrame, "The independent cursor still owns its older frame")
        weak var replacementCursor = cache!.cursor(frame: replacement, x: nil, style: style())
        XCTAssertNil(firstCursor)
        XCTAssertNil(firstFrame)
        XCTAssertNotNil(replacementScene)
        XCTAssertNotNil(replacementCursor)
        cache = nil
        XCTAssertNil(replacementScene)
        XCTAssertNil(replacementCursor)
    }

    func testFlattenedCurvesStayWithinToleranceAndKeepVerticalSteps() {
        let vertices: [CGPoint] = [
            .init(x: 0, y: 100), .init(x: 8, y: 4), .init(x: 20, y: 65),
            .init(x: 20, y: 90), .init(x: 21, y: 20), .init(x: 110, y: 20),
            .init(x: 113, y: 120), .init(x: 400, y: 4),
        ]
        let segment = Geometry.Segment(
            points: vertices, smoothed: true, baseline: 150,
            buildDrawingPaths: false)
        let flattened = Scene.flattened(segment)
        XCTAssertEqual(flattened.first, vertices.first)
        XCTAssertEqual(flattened.last, vertices.last)
        for vertex in vertices { XCTAssertTrue(flattened.contains(vertex)) }
        XCTAssertTrue(zip(flattened, flattened.dropFirst()).allSatisfy { $0.x <= $1.x })
        for span in segment.spans {
            for step in 0...100 {
                let fraction = CGFloat(step) / 100
                let point = CGPoint(
                    x: span.start.x + (span.end.x - span.start.x) * fraction,
                    y: span.value(at: fraction))
                let error =
                    zip(flattened, flattened.dropFirst()).map {
                        distance(point, to: $0, $1)
                    }.min() ?? .infinity
                XCTAssertLessThanOrEqual(error, 0.080001)
            }
        }
    }

    func testFormerCanvasTextAndCompactVisibilityArePreserved() {
        let frame = frame(buildPaths: false)
        let empty = Scene.make(
            frame: frame, lanes: [], laneColors: [:], segments: [],
            overflow: [], style: style())
        XCTAssertEqual(empty.labels.map(\.text), ["Requests", "No recent requests"])
        let overflows = [
            RequestRailGeometry.OverflowSegment(
                rect: CGRect(x: 29, y: 220, width: 100, height: 7), count: 12),
            RequestRailGeometry.OverflowSegment(
                rect: CGRect(x: 140, y: 220, width: 23, height: 7), count: 3),
        ]
        let crowded = Scene.make(
            frame: frame, lanes: [], laneColors: [:], segments: [],
            overflow: overflows, style: style())
        XCTAssertEqual(crowded.labels.map(\.text), ["Requests", "+12"])
        XCTAssertEqual(crowded.labels.last?.position, CGPoint(x: 79, y: 223.5))
        let compact = makeScene(
            frame: self.frame(key: key(compact: true), buildPaths: false),
            style: style(compact: true))
        XCTAssertTrue(compact.labels.isEmpty)
        XCTAssertFalse(
            compact.primitives.contains {
                if case .roundedRect = $0.shape { return true }
                return false
            })
        XCTAssertTrue(compact.primitives.contains { $0.stroke?.width == 2.2 })
    }

    private func assertSameGeometry(_ actual: [Geometry.Segment], _ expected: [Geometry.Segment]) {
        XCTAssertEqual(actual.map(\.points), expected.map(\.points))
        XCTAssertEqual(actual.map(\.spans), expected.map(\.spans))
        XCTAssertEqual(actual.map(\.tracePointCount), expected.map(\.tracePointCount))
        XCTAssertTrue(actual.allSatisfy { $0.trace.isEmpty && $0.area == nil })
        for (actual, expected) in zip(actual, expected) {
            let left = (expected.points.first?.x ?? 0) - 1
            let right = (expected.points.last?.x ?? 0) + 1
            for x in stride(from: left, through: right, by: 0.5) {
                XCTAssertEqual(actual.inspectedY(atX: x), expected.inspectedY(atX: x))
            }
        }
    }

    private func isFill(_ primitive: Scene.Primitive, color: SIMD4<Float>) -> Bool {
        guard case .polygon = primitive.shape,
            case .linear(_, _, let stops) = primitive.paint, let first = stops.first
        else { return false }
        return first.color.x == color.x && first.color.y == color.y && first.color.z == color.z
    }

    private func distance(_ point: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t =
            lengthSquared == 0
            ? 0
            : min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
    }

    private func makeScene(frame: Geometry.Frame, style: Scene.Style? = nil) -> Scene {
        Scene.make(
            frame: frame, lanes: lanes, laneColors: colors, segments: railSegments(frame),
            overflow: [], style: style ?? self.style())
    }

    private func cachedScene(
        _ cache: MetalFullChartSceneCache, frame: Geometry.Frame,
        style: Scene.Style
    ) -> Scene {
        cache.scene(
            frame: frame, lanes: lanes, laneColors: colors, segments: railSegments(frame),
            overflow: [], style: style)
    }

    private var lanes: [RequestLane] {
        [
            RequestLane(id: requestID, startedAt: date(73)),
            RequestLane(id: secondID, startedAt: date(90), endedAt: date(115)),
        ]
    }

    private var colors: [UUID: SIMD4<Float>] { [requestID: firstTool, secondID: secondTool] }

    private func railSegments(_ frame: Geometry.Frame) -> [RequestRailGeometry.Segment] {
        RequestRailGeometry.layout(
            lanes: lanes,
            assignments: [
                requestID: .init(track: 0, colorIndex: 0), secondID: .init(track: 1, colorIndex: 1),
            ], now: frame.key.now, duration: frame.key.duration, rect: frame.layout.lanes)
    }

    private func style(compact: Bool = false, increasedContrast: Bool = false) -> Scene.Style {
        .init(
            generatedColor: generated, deviceColor: device,
            backgroundColor: SIMD4(0.1, 0.1, 0.1, 1), primaryColor: SIMD4(1, 1, 1, 1),
            secondaryColor: SIMD4(0.7, 0.7, 0.7, 1), compact: compact,
            hasEffects: !increasedContrast, increasedContrast: increasedContrast, isDark: true)
    }

    private func key(
        compact: Bool = false, duration: TimeInterval = 60,
        size: CGSize = CGSize(width: 640, height: 320)
    ) -> Geometry.Key {
        .init(
            publicationID: UUID(), now: date(120), duration: duration, size: size,
            compact: compact, hasTools: true, tokenUpperBound: 200, toolUpperBound: 60)
    }

    private func frame(
        cache: Geometry = Geometry(), key: Geometry.Key? = nil,
        buildPaths: Bool
    ) -> Geometry.Frame {
        let key = key ?? self.key()
        let history = ChartDisplayHistory(
            samples: observations, now: key.now, duration: key.duration)
        let tools: [UUID: ToolActivityHistory] = Dictionary(
            uniqueKeysWithValues: [requestID, secondID].map { id in
                (
                    id,
                    ToolActivityHistory(
                        events: [
                            .init(kind: .call, timestamp: date(73), requestID: id),
                            .init(kind: .call, timestamp: date(119.5), requestID: id),
                            .init(kind: .resultSubmission, timestamp: date(119.75), requestID: id),
                        ], observations: observations, now: key.now, duration: key.duration)
                )
            })
        return cache.frame(
            for: key, throughput: history, gpu: history, requestTools: tools,
            buildDrawingPaths: buildPaths)
    }

    private var observations: [TimeSeriesPoint] {
        [
            (0.0, 0.0, true), (40, 250, true), (45, 20, true), (72, 0, true),
            (73, 45, true), (74, 10, false), (90, 80, true), (119, 40, true), (120, 100, true),
        ]
        .map { TimeSeriesPoint(timestamp: date($0.0), value: $0.1, isAvailable: $0.2) }
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
}
