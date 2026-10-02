import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class CompactToolPathTests: XCTestCase {
    private typealias Cache = LuminousChartGeometryCache
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let requestID = UUID()

    func testEmptySingletonAndTwoPointTracesKeepEveryCommand() {
        let fixtures: [[CGPoint]] = [
            [], [.init(x: 3, y: 4)], [.init(x: 3, y: 4), .init(x: 9, y: 4)],
        ]
        for points in fixtures {
            let segment = segment(points)
            XCTAssertEqual(segment.points, points)
            XCTAssertEqual(commands(segment.trace), commands(referencePath(points)))
            XCTAssertEqual(segment.tracePointCount, points.count)
            XCTAssertNil(segment.area)
            XCTAssertTrue(segment.spans.isEmpty)
        }
    }

    func testHorizontalInteriorsDisappearButEndpointsAndVerticalTransitionsRemain() {
        let points: [CGPoint] = [
            .init(x: 1, y: 8), .init(x: 2, y: 8), .init(x: 3, y: 8), .init(x: 4, y: 8),
            .init(x: 4, y: 3), .init(x: 5, y: 3), .init(x: 6, y: 3),
            .init(x: 6, y: 8), .init(x: 7, y: 8), .init(x: 8, y: 8),
        ]
        let expected = [points[0], points[3], points[4], points[6], points[7], points[9]]
        let candidate = segment(points)
        XCTAssertEqual(
            candidate.points, points, "Inspection retains all original sample coordinates")
        XCTAssertEqual(commands(candidate.trace), commands(referencePath(expected)))
        XCTAssertEqual(candidate.tracePointCount, expected.count)
        XCTAssertLessThan(commands(candidate.trace).count, commands(referencePath(points)).count)
        XCTAssertNil(candidate.area)
        XCTAssertTrue(candidate.spans.isEmpty)

        let defaultStrategy = Cache.Segment(points: points, smoothed: false, baseline: 100)
        XCTAssertEqual(commands(defaultStrategy.trace), commands(referencePath(points)))
        XCTAssertEqual(defaultStrategy.tracePointCount, points.count)
    }

    func testDuplicateReverseVerticalDiagonalAndAlmostHorizontalTriplesArePreserved() {
        let fixtures: [[CGPoint]] = [
            [.init(x: 0, y: 5), .init(x: 1, y: 5), .init(x: 1, y: 5)],
            [.init(x: 1, y: 5), .init(x: 1, y: 5), .init(x: 2, y: 5)],
            [.init(x: 2, y: 5), .init(x: 1, y: 5), .init(x: 0, y: 5)],
            [.init(x: 0, y: 5), .init(x: 2, y: 5), .init(x: 1, y: 5)],
            [.init(x: 1, y: 5), .init(x: 1, y: 6), .init(x: 1, y: 7)],
            [.init(x: 0, y: 0), .init(x: 1, y: 1), .init(x: 2, y: 2)],
            [.init(x: 0, y: 1), .init(x: 1, y: CGFloat(1).nextUp), .init(x: 2, y: 1)],
        ]
        for points in fixtures {
            let candidate = segment(points)
            XCTAssertEqual(candidate.points, points)
            XCTAssertEqual(commands(candidate.trace), commands(referencePath(points)))
            XCTAssertEqual(candidate.tracePointCount, points.count)
        }
    }

    func testCompactionUsesOriginalNeighborsAndKeepsDuplicateAndReversedBoundaries() {
        let duplicate: [CGPoint] = [
            .init(x: 0, y: 5), .init(x: 1, y: 5), .init(x: 1, y: 5),
            .init(x: 2, y: 5), .init(x: 3, y: 5),
        ]
        let reverse: [CGPoint] = [
            .init(x: 0, y: 5), .init(x: 2, y: 5), .init(x: 1, y: 5),
            .init(x: 3, y: 5), .init(x: 4, y: 5),
        ]
        for points in [duplicate, reverse] {
            let expected = [points[0], points[1], points[2], points[4]]
            let candidate = segment(points)
            XCTAssertEqual(candidate.points, points)
            XCTAssertEqual(commands(candidate.trace), commands(referencePath(expected)))
            XCTAssertEqual(candidate.tracePointCount, expected.count)
        }
    }

    func testAnyNonfiniteCoordinatePreventsRemovingTheMiddleOfItsOriginalTriple() {
        let finite: [CGPoint] = [.init(x: 0, y: 5), .init(x: 1, y: 5), .init(x: 2, y: 5)]
        for value in [CGFloat.nan, .infinity, -.infinity] {
            for index in finite.indices {
                for coordinate in 0..<2 {
                    var points = finite
                    if coordinate == 0 { points[index].x = value } else { points[index].y = value }
                    let candidate = segment(points)
                    XCTAssertEqual(candidate.tracePointCount, points.count)
                    XCTAssertEqual(candidate.points.count, points.count)
                    for (actual, expected) in zip(candidate.points, points) {
                        assertSameCoordinate(actual.x, expected.x)
                        assertSameCoordinate(actual.y, expected.y)
                    }
                    // Core Graphics may reject nonfinite commands. Compare with
                    // its own unmodified Path construction, not an assumed encoding.
                    assertSameCommands(commands(candidate.trace), commands(referencePath(points)))
                }
            }
        }
        let infinitePlateau = (0..<3).map { CGPoint(x: CGFloat($0), y: CGFloat.infinity) }
        XCTAssertEqual(segment(infinitePlateau).tracePointCount, infinitePlateau.count)
    }

    func testSeparateSegmentsKeepTheirOwnEndpointsAndMoveCommands() {
        let originals: [[CGPoint]] = [
            [.init(x: 1, y: 4), .init(x: 2, y: 4), .init(x: 3, y: 4)],
            [.init(x: 8, y: 4), .init(x: 9, y: 4), .init(x: 10, y: 4)],
        ]
        let actual = originals.map { segment($0) }
        XCTAssertEqual(actual.count, 2)
        for (candidate, original) in zip(actual, originals) {
            XCTAssertEqual(candidate.points, original)
            XCTAssertEqual(commands(candidate.trace), [.move(original[0]), .line(original[2])])
            XCTAssertEqual(candidate.tracePointCount, 2)
        }
    }

    func testSmoothedTraceAreaSpansAndInspectionAreUnchanged() {
        let points: [CGPoint] = [
            .init(x: 0, y: 8), .init(x: 1, y: 8), .init(x: 2, y: 8),
            .init(x: 2, y: 3), .init(x: 4, y: 6), .init(x: 6, y: 6),
        ]
        let baseline = Cache.Segment(points: points, smoothed: true, baseline: 20)
        let candidate = Cache.Segment(
            points: points, smoothed: true, baseline: 20, compactToolPaths: true)
        XCTAssertEqual(candidate.points, points)
        XCTAssertEqual(candidate.spans, baseline.spans)
        XCTAssertEqual(commands(candidate.trace), commands(baseline.trace))
        XCTAssertEqual(candidate.area, baseline.area)
        XCTAssertNotNil(candidate.area)
        XCTAssertEqual(candidate.tracePointCount, commands(candidate.trace).count)
        for x in stride(from: CGFloat(-1), through: 7, by: 0.25) {
            XCTAssertEqual(candidate.inspectedY(atX: x), baseline.inspectedY(atX: x))
        }
    }

    func testStrategyIsPartOfFrameIdentityAndLeavesOtherGeometryAndMarkersUnchanged() throws {
        let history = history()
        let tools = [requestID: toolHistory()]
        for direct in [false, true] {
            for compactLayout in [false, true] {
                for size in [CGSize(width: 640, height: 320), CGSize(width: 401.5, height: 247.25)]
                {
                    let cache = Cache()
                    let key = key(size: size, compact: compactLayout)
                    func frame(_ compact: Bool = false) -> Cache.Frame {
                        cache.frame(
                            for: key, throughput: history, gpu: history, requestTools: tools,
                            directToolPlot: direct, compactToolPaths: compact)
                    }
                    let baseline = frame()
                    XCTAssertFalse(baseline.compactToolPaths)
                    XCTAssertTrue(frame() === baseline)
                    let candidate = frame(true)
                    XCTAssertTrue(candidate.compactToolPaths)
                    XCTAssertEqual(candidate.directToolPlot, direct)
                    XCTAssertFalse(candidate === baseline)
                    XCTAssertTrue(frame(true) === candidate)
                    XCTAssertEqual(candidate.key, baseline.key)
                    XCTAssertEqual(
                        candidate.generated.map(\.trace), baseline.generated.map(\.trace))
                    XCTAssertEqual(candidate.generated.map(\.area), baseline.generated.map(\.area))
                    XCTAssertEqual(candidate.device.map(\.trace), baseline.device.map(\.trace))
                    XCTAssertEqual(candidate.device.map(\.area), baseline.device.map(\.area))
                    XCTAssertEqual(candidate.generatedEndpoint, baseline.generatedEndpoint)
                    XCTAssertEqual(candidate.deviceEndpoint, baseline.deviceEndpoint)
                    let actual = try XCTUnwrap(candidate.requestTools[requestID])
                    let expected = try XCTUnwrap(baseline.requestTools[requestID])
                    XCTAssertEqual(actual.segments.map(\.points), expected.segments.map(\.points))
                    XCTAssertEqual(actual.resultPoints, expected.resultPoints)
                    XCTAssertFalse(actual.resultPoints.isEmpty)
                    XCTAssertEqual(actual.resultDiamonds, expected.resultDiamonds)
                    XCTAssertLessThan(
                        commandCount(actual.segments), commandCount(expected.segments))
                    for (compacted, original) in zip(actual.segments, expected.segments) {
                        XCTAssertEqual(compacted.points.first, original.points.first)
                        XCTAssertEqual(compacted.points.last, original.points.last)
                        XCTAssertEqual(compacted.spans, original.spans)
                        XCTAssertEqual(compacted.area, original.area)
                    }
                    let restored = frame()
                    XCTAssertFalse(restored.compactToolPaths)
                    XCTAssertFalse(restored === candidate)
                    XCTAssertTrue(frame() === restored)
                }
            }
        }
    }

    func testPointCountersCountActualToolPathCommandsAndDoNotCountCacheHitsOrOtherSeries() {
        let counters = PerformancePresentationCounters.shared
        counters.enable()
        let cache = Cache()
        let key = key()
        let history = history()
        let tools = [requestID: toolHistory(), UUID(): toolHistory()]
        var expectedInputs: UInt64 = 0
        var expectedOutputs: UInt64 = 0
        for strategy in [(false, false), (false, true), (true, true), (true, false)] {
            func frame() -> Cache.Frame {
                cache.frame(
                    for: key, throughput: history, gpu: history, requestTools: tools,
                    directToolPlot: strategy.0, compactToolPaths: strategy.1)
            }
            let built = frame()
            let segments = built.requestTools.values.flatMap(\.segments)
            let inputs = UInt64(segments.reduce(0) { $0 + $1.points.count })
            // Inspect the Path itself so this does not merely repeat the
            // implementation's tracePointCount bookkeeping.
            let outputs = UInt64(commandCount(segments))
            XCTAssertGreaterThan(inputs, 0)
            if strategy.1 {
                XCTAssertLessThan(outputs, inputs)
            } else {
                XCTAssertEqual(outputs, inputs)
            }
            expectedInputs += inputs
            expectedOutputs += outputs
            XCTAssertEqual(counters.snapshot()["tool_path_input_points"], expectedInputs)
            XCTAssertEqual(counters.snapshot()["tool_path_output_points"], expectedOutputs)
            for _ in 0..<5 { XCTAssertTrue(frame() === built) }
            XCTAssertEqual(counters.snapshot()["tool_path_input_points"], expectedInputs)
            XCTAssertEqual(counters.snapshot()["tool_path_output_points"], expectedOutputs)
        }
        let withoutTools = Cache().frame(
            for: key, throughput: history, gpu: history, requestTools: [:], compactToolPaths: true)
        XCTAssertFalse(withoutTools.generated.isEmpty)
        XCTAssertFalse(withoutTools.device.isEmpty)
        XCTAssertEqual(counters.snapshot()["tool_path_input_points"], expectedInputs)
        XCTAssertEqual(counters.snapshot()["tool_path_output_points"], expectedOutputs)
    }

    func testCanvasPixelsExactlyMatchOriginalPathsAcrossScalesWidthsOffsetsDashesAndGaps() throws {
        let fixtures: [(String, [[CGPoint]])] = [
            ("long plateau", [(8...116).map { CGPoint(x: CGFloat($0), y: 23) }]),
            (
                "sharp transitions",
                [
                    [
                        .init(x: 8, y: 42), .init(x: 18, y: 42), .init(x: 29, y: 42),
                        .init(x: 29, y: 12), .init(x: 43, y: 12), .init(x: 57, y: 12),
                        .init(x: 57, y: 35), .init(x: 74, y: 35), .init(x: 89, y: 35),
                        .init(x: 89, y: 18), .init(x: 103, y: 18), .init(x: 116, y: 18),
                    ]
                ]
            ),
            (
                "separate gaps",
                [
                    [.init(x: 8, y: 23), .init(x: 17, y: 23), .init(x: 31, y: 23)],
                    [.init(x: 48, y: 23), .init(x: 57, y: 23), .init(x: 71, y: 23)],
                    [.init(x: 88, y: 23), .init(x: 101, y: 23), .init(x: 116, y: 23)],
                ]
            ),
        ]
        let dashes: [[CGFloat]] = [[], [4, 3]]
        for scale in [CGFloat(1), 2] {
            for width in [CGFloat(1.6), 2.2] {
                for offset in [CGPoint.zero, CGPoint(x: 0.25, y: 0.375), CGPoint(x: 0.5, y: 0.5)] {
                    for dash in dashes {
                        for (name, originals) in fixtures {
                            let shifted = originals.map { points in
                                points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
                            }
                            let expected = try render(
                                shifted.map { referencePath($0) }, scale: scale, width: width,
                                dash: dash)
                            let candidates = shifted.map { segment($0) }
                            XCTAssertLessThan(
                                commandCount(candidates), shifted.reduce(0) { $0 + $1.count })
                            let actual = try render(
                                candidates.map(\.trace), scale: scale, width: width, dash: dash)
                            let label =
                                "\(name), scale=\(scale), width=\(width), offset=\(offset), dash=\(dash)"
                            XCTAssertTrue(
                                expected.enumerated().contains {
                                    $0.offset % 4 == 3 && $0.element > 0
                                }, label)
                            XCTAssertEqual(actual.count, expected.count, label)
                            var differences = 0
                            var maximumDifference = 0
                            var firstDifference: Int?
                            for (index, pair) in zip(actual, expected).enumerated()
                            where pair.0 != pair.1 {
                                differences += 1
                                maximumDifference = max(
                                    maximumDifference, abs(Int(pair.0) - Int(pair.1)))
                                if firstDifference == nil { firstDifference = index }
                            }
                            XCTAssertEqual(
                                differences, 0,
                                "\(label): max channel difference \(maximumDifference), first byte \(String(describing: firstDifference))"
                            )
                        }
                    }
                }
            }
        }
    }

    func testProjectedToolPathsMatchPixelsWithNonbinaryWindowCoordinates() throws {
        let size = CGSize(width: 401.5, height: 247.25)
        let key = Cache.Key(
            publicationID: UUID(), now: date(60.123), duration: 61.337, size: size,
            compact: false, hasTools: true, tokenUpperBound: 100, toolUpperBound: 60)
        let cache = Cache()
        let history = history()
        let tools = [requestID: toolHistory()]
        let original = cache.frame(for: key, throughput: history, gpu: history, requestTools: tools)
        let compacted = cache.frame(
            for: key, throughput: history, gpu: history, requestTools: tools, compactToolPaths: true
        )
        let expected = try XCTUnwrap(original.requestTools[requestID]).segments
        let actual = try XCTUnwrap(compacted.requestTools[requestID]).segments
        XCTAssertEqual(actual.map(\.points), expected.map(\.points))
        XCTAssertLessThan(commandCount(actual), commandCount(expected))
        for scale in [CGFloat(1), 2] {
            for width in [CGFloat(1.6), 2.2] {
                let reference = try render(
                    expected.map(\.trace), scale: scale, width: width, dash: [4, 3], size: size)
                let candidate = try render(
                    actual.map(\.trace), scale: scale, width: width, dash: [4, 3], size: size)
                XCTAssertTrue(
                    reference.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 })
                XCTAssertTrue(
                    candidate == reference,
                    "Projected tool pixels differ at scale \(scale), width \(width)")
            }
        }
    }

    private enum Command: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)
        case close

        var points: [CGPoint] {
            switch self {
            case .move(let point), .line(let point): [point]
            case .quad(let point, let control): [point, control]
            case .curve(let point, let control1, let control2): [point, control1, control2]
            case .close: []
            }
        }

        var kind: Int {
            switch self {
            case .move: 0
            case .line: 1
            case .quad: 2
            case .curve: 3
            case .close: 4
            }
        }
    }

    private func commands(_ path: Path) -> [Command] {
        var commands: [Command] = []
        // SwiftUI.Path exposes callback traversal rather than Sequence iteration.
        // swift-format-ignore: ReplaceForEachWithForLoop
        path.forEach { element in
            switch element {
            case .move(let point): commands.append(.move(point))
            case .line(let point): commands.append(.line(point))
            case .quadCurve(let point, let control): commands.append(.quad(point, control))
            case .curve(let point, let control1, let control2):
                commands.append(.curve(point, control1, control2))
            case .closeSubpath: commands.append(.close)
            }
        }
        return commands
    }

    private func commandCount(_ segments: [Cache.Segment]) -> Int {
        segments.reduce(0) { $0 + commands($1.trace).count }
    }

    private func segment(_ points: [CGPoint]) -> Cache.Segment {
        Cache.Segment(points: points, smoothed: false, baseline: 100, compactToolPaths: true)
    }

    /// Independent oracle: the original drawing sequence, with every supplied
    /// vertex added directly and no production Segment or compaction helper.
    private func referencePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    private func assertSameCoordinate(
        _ actual: CGFloat, _ expected: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) {
        if expected.isNaN {
            XCTAssertTrue(actual.isNaN, file: file, line: line)
        } else {
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
    }

    private func assertSameCommands(
        _ actual: [Command], _ expected: [Command], file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (lhs, rhs) in zip(actual, expected) {
            XCTAssertEqual(lhs.kind, rhs.kind, file: file, line: line)
            XCTAssertEqual(lhs.points.count, rhs.points.count, file: file, line: line)
            for (a, b) in zip(lhs.points, rhs.points) {
                assertSameCoordinate(a.x, b.x, file: file, line: line)
                assertSameCoordinate(a.y, b.y, file: file, line: line)
            }
        }
    }

    private func render(
        _ paths: [Path], scale: CGFloat, width: CGFloat, dash: [CGFloat],
        size: CGSize = CGSize(width: 128, height: 56)
    ) throws -> [UInt8] {
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        var environment = EnvironmentValues()
        environment.colorScheme = .dark
        environment.displayScale = scale
        let renderer = ImageRenderer(
            content: Canvas { context, _ in
                for path in paths {
                    context.stroke(
                        path,
                        with: .color(
                            Color(.sRGB, red: 0.13, green: 0.86, blue: 0.97, opacity: 0.75)),
                        style: StrokeStyle(
                            lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
                }
            }.environment(\.self, environment))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        renderer.render(rasterizationScale: scale) { _, draw in draw(context) }
        let data = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return Array(UnsafeBufferPointer(start: data, count: context.bytesPerRow * context.height))
    }

    private func key(size: CGSize = CGSize(width: 640, height: 320), compact: Bool = false)
        -> Cache.Key
    {
        Cache.Key(
            publicationID: UUID(), now: date(60), duration: 60, size: size, compact: compact,
            hasTools: true, tokenUpperBound: 100, toolUpperBound: 60)
    }

    private func history() -> ChartDisplayHistory {
        ChartDisplayHistory(samples: observations, now: date(60), duration: 60)
    }

    private func toolHistory() -> ToolActivityHistory {
        ToolActivityHistory(
            events: [
                ToolActivityEvent(kind: .call, timestamp: date(3), requestID: requestID),
                ToolActivityEvent(kind: .call, timestamp: date(39), requestID: requestID),
                ToolActivityEvent(
                    kind: .resultSubmission, timestamp: date(39.5), requestID: requestID),
            ], observations: observations, now: date(60), duration: 60)
    }

    private var observations: [TimeSeriesPoint] {
        (0...120).map {
            TimeSeriesPoint(
                timestamp: date(Double($0) / 2), value: Double($0 % 17), isAvailable: $0 != 44)
        }
    }

    private func date(_ offset: TimeInterval) -> Date { origin.addingTimeInterval(offset) }
}
