import AppKit
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class DashboardRetainedUsageTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private typealias Coordinator = DashboardRetainedUsageCoordinator

    func testNativePixelsAndGeometryMatchNormalAcrossWidthsAndUsageStates() throws {
        for size in [CGSize(width: 740, height: 700), CGSize(width: 360, height: 950)] {
            let normal = try capture(mode: .normal, size: size)
            let retained = try capture(mode: .runtimeRetainedUsage, size: size)
            XCTAssertEqual(
                retained.map(\.frames), normal.map(\.frames), "Native geometry changed at \(size)")
            try assertPixelParity(
                retained, normal, label: "light-\(Int(size.width))x\(Int(size.height))")
        }
    }

    func testNativeDarkColorSchemeRefreshMatchesNormalPixels() throws {
        for size in [CGSize(width: 740, height: 700), CGSize(width: 360, height: 950)] {
            let normal = try capture(mode: .normal, size: size, scheme: .dark)
            let retained = try capture(mode: .runtimeRetainedUsage, size: size, scheme: .dark)
            XCTAssertEqual(retained.map(\.frames), normal.map(\.frames))
            try assertPixelParity(
                retained, normal, label: "dark-\(Int(size.width))x\(Int(size.height))")
        }
    }

    func testOutputOnlyCoalescedUpdateDoesNotRebuildDetailsOrOuterLayout() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeRetainedUsage)
        let store = makeStore()
        publish(usage(output: 24), store: store)
        let host = RetainedUsageTestHost(store: store, size: CGSize(width: 740, height: 700))
        defer {
            host.close()
            drain()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        try host.settle()
        let idleBefore = try work(host.state)
        let idleCanvases = PerformanceGraphicsDiagnostics.shared.snapshot()["native_canvas_draws"]
        let idleNativeBefore = Dictionary(
            uniqueKeysWithValues: host.retainedHosts().map {
                ($0.field.rawValue, $0.nativeDiagnostics)
            })
        try host.settle(forceLayout: false)
        let before = try work(host.state)
        print(
            "Retained no-update control: workBefore=\(idleBefore); workAfter=\(before); nativeBefore=\(idleNativeBefore); nativeAfter=\(Dictionary(uniqueKeysWithValues: host.retainedHosts().map { ($0.field.rawValue, $0.nativeDiagnostics) }))"
        )
        let idleCanvasAfter = PerformanceGraphicsDiagnostics.shared.snapshot()[
            "native_canvas_draws"]
        print(
            "Retained no-update canvas draws: before=\(String(describing: idleCanvases)); after=\(String(describing: idleCanvasAfter))"
        )
        let frames = host.state.scalarPerformanceFrames
        let hosts = host.retainedHosts()
        XCTAssertEqual(hosts.count, 5)
        let intrinsic = Dictionary(
            uniqueKeysWithValues: hosts.map { ($0.field, $0.intrinsicContentSize) })
        let nativeBefore = Dictionary(
            uniqueKeysWithValues: hosts.map { ($0.field.rawValue, $0.nativeDiagnostics) })
        let applies = counter("value_applies")
        let skips = counter("value_apply_skips")
        publish(usage(output: 25), store: store)
        try host.settle(forceLayout: false)
        XCTAssertEqual(
            try work(host.state), before,
            "Usage observation and intrinsic text sizing must not dirty the enclosing details/grid layout; nativeBefore=\(nativeBefore); nativeAfter=\(Dictionary(uniqueKeysWithValues: hosts.map { ($0.field.rawValue, $0.nativeDiagnostics) })); geometry=\(host.nativeGeometry())"
        )
        XCTAssertEqual(host.state.scalarPerformanceFrames, frames)
        XCTAssertEqual(counter("value_applies"), applies + 1)
        XCTAssertEqual(counter("value_apply_skips"), skips + 4)
        XCTAssertEqual(hosts.first(where: { $0.field == .output })?.appliedDisplay?.value, "25")
        for view in hosts {
            XCTAssertEqual(view.intrinsicContentSize, intrinsic[view.field])
            if view.field != .badge {
                let density = DashboardHeightPolicy(viewportHeight: 700, viewportWidth: 740)
                XCTAssertEqual(view.intrinsicContentSize.height, density.value(21, 18))
            }
        }
        let owner = try retainedOwner(host.state)
        XCTAssertEqual((owner["values"] as? [String: Any])?["output_tokens"] as? Int, 25)
        XCTAssertEqual(
            try dashboardWitness(host.state)["values"] as? NSDictionary,
            owner["values"] as? NSDictionary)
    }

    func testNativeFieldsAndCompactResponseAdvanceWithAuthoritativeAccounting() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeRetainedUsage)
        let store = makeStore()
        let full = RetainedUsageTestHost(store: store, size: CGSize(width: 740, height: 700))
        let compact = RetainedUsageTestHost(
            store: store, size: CGSize(width: 360, height: 550), compact: true)
        defer {
            full.close()
            compact.close()
            drain()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        try full.settle()
        try compact.settle()
        let request = GenerationRequest(
            model: "Live native", startedAt: origin.addingTimeInterval(0.1))
        store.apply(.began(request))
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 17, liveTPS: 34, timestamp: origin.addingTimeInterval(0.6))))
        store.sample(at: origin.addingTimeInterval(0.7))
        try full.settle()
        try compact.settle()
        let fields = try XCTUnwrap(
            try retainedOwner(full.state)["fields"] as? [String: [String: String]])
        XCTAssertEqual(fields["output"]?["value"], "~17")
        XCTAssertEqual(fields["input"]?["value"], "—")
        XCTAssertEqual(fields["badge"]?["value"], "1 active")
        XCTAssertEqual(
            store.usageSummary(in: DateInterval(start: origin, duration: 60)).outputTokens, 17)
        XCTAssertEqual(
            try presented(compact.state)["compact_details"]?["response"] as? String, "~17")
        XCTAssertEqual(try presented(full.state)["header"]?["status"] as? String, "Active")
        XCTAssertEqual(compact.retainedHosts().count, 0)
        XCTAssertNil(full.state.heldUsage)
        XCTAssertNil(full.state.frozenScalars)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 21, promptTokens: 6, isEstimated: false, finished: true,
                    timestamp: origin.addingTimeInterval(0.8))))
        try full.settle()
        try compact.settle()
        let finished = try XCTUnwrap(
            try retainedOwner(full.state)["fields"] as? [String: [String: String]])
        XCTAssertEqual(finished["output"]?["value"], "21")
        XCTAssertEqual(finished["input"]?["value"], "6")
        XCTAssertEqual(finished["badge"]?["value"], "")
        XCTAssertEqual(
            try presented(compact.state)["compact_details"]?["response"] as? String, "21")
        XCTAssertEqual(counter("hosts_created") - counter("hosts_destroyed"), 5)
        XCTAssertEqual(counter("current_owners"), 1)
    }

    func testSameBackendVisibleEpochRebindsAndHiddenCallbacksCannotResurrect() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .runtimeRetainedUsage)
        let store = makeStore()
        let state = DashboardPresentationState()
        let host = RetainedUsageTestHost(
            store: store, size: CGSize(width: 740, height: 700), state: state)
        defer {
            host.close()
            drain()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        try host.settle()
        let old = state.retainedUsageCoordinator(store: store)
        let oldFrames = state.scalarPerformanceFrames
        let oldEpoch = store.monitoringEpoch
        let oldGeneration = state.scalarFrameGeneration
        publish(usage(output: 99), store: store)
        let nextEpoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: nextEpoch)
        store.updateConnection(.ready)
        try host.settle()
        XCTAssertTrue(old.isStopped)
        XCTAssertEqual(
            state.scalarPerformanceFrames, oldFrames,
            "A visible boundary must resolve fresh, identical anchors even when geometry is unchanged"
        )
        state.recordScalarPerformanceFrames(oldFrames, generation: oldGeneration, epoch: oldEpoch)
        XCTAssertEqual(
            state.scalarPerformanceFrames, oldFrames,
            "A late old-boundary callback must not replace the newly admitted receipt")
        XCTAssertEqual(try retainedOwner(state)["epoch"] as? String, nextEpoch.uuidString)
        publish(usage(output: 71), store: store)
        try host.settle(forceLayout: false)
        XCTAssertEqual(
            host.retainedHosts().first(where: { $0.field == .output })?.appliedDisplay?.value, "71")
        XCTAssertEqual(
            (try retainedOwner(state)["values"] as? [String: Any])?["output_tokens"] as? Int, 71)
        publish(usage(output: 72), store: store)
        host.close()
        drain()
        XCTAssertEqual(counter("current_owners"), 0)
        XCTAssertEqual(counter("hosts_created"), counter("hosts_destroyed"))
        let closed = namespace() as NSDictionary
        publish(usage(output: 73), store: store)
        drain()
        XCTAssertEqual(
            namespace() as NSDictionary, closed,
            "A queued observer or detached native host must not revive a closed owner")
        let reopened = RetainedUsageTestHost(
            store: store, size: CGSize(width: 740, height: 700), state: state)
        defer {
            reopened.close()
            drain()
        }
        try reopened.settle()
        XCTAssertEqual(
            reopened.retainedHosts().first(where: { $0.field == .output })?.appliedDisplay?.value,
            "73")
        XCTAssertEqual(counter("current_owners"), 1)
        XCTAssertEqual(counter("peak_owners"), 1)
    }

    func testProjectionPreservesUnknownHelpEstimatesPartialPrecedenceAndUnchangedFields() {
        let initial = usage(
            input: nil, unknown: 2, output: 1_234, estimated: true, tools: 3,
            requests: 4, active: 2, partial: true)
        let first = Coordinator.project(initial, previous: nil, displays: [:])
        XCTAssertEqual(first[.input]?.value, "—")
        XCTAssertEqual(
            first[.input]?.help,
            "Input usage is unavailable for 2 requests. A + marks the known subtotal.")
        XCTAssertEqual(first[.output]?.value, "~" + 1_234.formatted())
        XCTAssertEqual(first[.tools]?.value, "3")
        XCTAssertEqual(first[.requests]?.value, "4")
        XCTAssertEqual(first[.badge]?.value, "Partial history")
        XCTAssertEqual(Coordinator.project(initial, previous: initial, displays: first), first)
        let exact = usage(
            input: 6, unknown: 1, output: 1_235, estimated: false, tools: 3,
            requests: 4, active: 2)
        let second = Coordinator.project(exact, previous: initial, displays: first)
        XCTAssertEqual(second[.input]?.value, "6+")
        XCTAssertEqual(second[.output]?.value, 1_235.formatted())
        XCTAssertEqual(second[.badge]?.value, "2 active")
        XCTAssertEqual(second[.tools], first[.tools])
        XCTAssertEqual(second[.requests], first[.requests])
    }

    func testNativeCoordinatorRendersWithoutDiagnosticCountersOrNewTimer() throws {
        let diagnostics = PerformanceGraphicsDiagnostics.shared
        XCTAssertFalse(diagnostics.isEnabled)
        let before = diagnostics.snapshot() as NSDictionary
        let store = makeStore()
        let state = DashboardPresentationState()
        state.setActive(true, store: store)
        let coordinator = state.retainedUsageCoordinator(store: store)
        let hosts = Coordinator.Field.allCases.map {
            DashboardRetainedUsageHost(field: $0, density: .condensed, colorScheme: .light)
        }
        defer {
            state.setActive(false, store: store)
            for host in hosts {
                host.disconnect()
            }
        }
        for host in hosts {
            host.connect(to: coordinator)
        }
        publish(usage(output: 42), store: store)
        drain()
        XCTAssertEqual(hosts.first(where: { $0.field == .output })?.appliedDisplay?.value, "42")
        XCTAssertEqual(coordinator.appliedUsage?.outputTokens, 42)
        XCTAssertEqual(
            hosts.filter { $0.field != .badge }.map(\.intrinsicContentSize.height),
            [18, 18, 18, 18])
        XCTAssertEqual(diagnostics.snapshot() as NSDictionary, before)
    }

    func testReplacementBeforeOldDismantleKeepsNewNativeFieldRegistered() {
        let store = makeStore()
        let state = DashboardPresentationState()
        state.setActive(true, store: store)
        let coordinator = state.retainedUsageCoordinator(store: store)
        let old = DashboardRetainedUsageHost(field: .output, density: .roomy, colorScheme: .light)
        let replacement = DashboardRetainedUsageHost(
            field: .output, density: .roomy, colorScheme: .light)
        defer {
            state.setActive(false, store: store)
            old.disconnect()
            replacement.disconnect()
        }
        old.connect(to: coordinator)
        publish(usage(output: 11), store: store)
        drain()
        XCTAssertEqual(old.appliedDisplay?.value, "11")
        replacement.connect(to: coordinator)
        XCTAssertEqual(replacement.appliedDisplay?.value, "11")
        old.disconnect()
        XCTAssertFalse(coordinator.isStopped)
        publish(usage(output: 12), store: store)
        drain()
        XCTAssertEqual(replacement.appliedDisplay?.value, "12")
        XCTAssertEqual(old.appliedDisplay?.value, "11")
        replacement.disconnect()
        XCTAssertTrue(coordinator.isStopped)
    }

    func testNativeValuesPreserveSelectionFullStringAndMinimumScale() throws {
        let store = makeStore()
        let state = DashboardPresentationState()
        state.setActive(true, store: store)
        let coordinator = state.retainedUsageCoordinator(store: store)
        let host = DashboardRetainedUsageHost(field: .output, density: .roomy, colorScheme: .light)
        host.frame = CGRect(x: 0, y: 0, width: 32, height: 21)
        let window = NSWindow(
            contentRect: CGRect(x: -2000, y: -2000, width: 400, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 60))
        container.addSubview(host)
        window.contentView = container
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            window.endEditing(for: nil)
            pasteboard.releaseGlobally()
            state.setActive(false, store: store)
            host.disconnect()
            window.contentView = nil
            window.close()
        }
        host.connect(to: coordinator)
        publish(usage(output: Int.max), store: store)
        drain()
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(host.nativeValueField)
        XCTAssertTrue(field.isSelectable)
        XCTAssertFalse(field.isEditable)
        XCTAssertFalse(field.isBordered)
        XCTAssertFalse(field.drawsBackground)
        XCTAssertEqual(
            field.stringValue, Int.max.formatted(),
            "Selection and AX retain the full untruncated value")
        // Original Text preserves the fractional 0.7 minimum; the public
        // Font.scaled(by:) resolver quantizes it and is not the rendered fit.
        let physicalMinimum: CGFloat = 11.2
        XCTAssertEqual(try XCTUnwrap(field.font).pointSize, physicalMinimum, accuracy: 0.000_001)
        XCTAssertEqual(field.maximumNumberOfLines, 1)
        XCTAssertEqual(field.lineBreakMode, .byTruncatingTail)
        window.orderFront(nil)
        window.layoutIfNeeded()
        host.displayIfNeeded()
        field.selectText(nil)
        let editor = try XCTUnwrap(
            field.currentEditor() as? NSTextView,
            "The native selectable value must provide a real window-backed field editor")
        XCTAssertEqual(editor.string, Int.max.formatted())
        XCTAssertEqual(
            editor.selectedRange(),
            NSRange(location: 0, length: (Int.max.formatted() as NSString).length))
        XCTAssertEqual(editor.textContainer?.lineFragmentPadding, 0)
        XCTAssertEqual(editor.textContainerInset, .zero)
        XCTAssertEqual(try XCTUnwrap(editor.font).pointSize, physicalMinimum, accuracy: 0.000_001)
        let writableType = try XCTUnwrap(
            editor.writablePasteboardTypes.first(where: {
                $0 == .string || $0.rawValue == "NSStringPboardType"
            }))
        let declaredTypes = pasteboard.declareTypes([writableType], owner: nil)
        XCTAssertTrue(
            editor.writeSelection(to: pasteboard, type: writableType),
            "Real editor copy failed: declared=\(declaredTypes), boardTypes=\(String(describing: pasteboard.types)), writable=\(editor.writablePasteboardTypes), selected=\(editor.selectedRange())"
        )
        XCTAssertEqual(
            pasteboard.string(forType: writableType), Int.max.formatted(),
            "Copy must preserve the full string while the visible cell is truncated")
        window.endEditing(for: nil)
        host.frame.size.width = 400
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(field.font).pointSize, 16, accuracy: 0.000_001)
        let digitWidths = ["1", "8"].map {
            ($0 as NSString).size(withAttributes: [.font: field.font!]).width
        }
        XCTAssertEqual(digitWidths[0], digitWidths[1], accuracy: 0.000_001)
    }

    func testOriginalAndRetainedTextAccessibilityParityWhenSwiftUIGraphIsAvailable() throws {
        // SwiftUI does not eagerly vend its AX graph in every XCTest process.
        // An independent ordinary SwiftUI cell is the availability control;
        // empty-to-empty must never be reported as accessibility parity.
        let store = makeStore()
        let state = DashboardPresentationState()
        state.setActive(true, store: store)
        let reference = NSHostingView(
            rootView:
                VStack(alignment: .leading, spacing: 5) {
                    Text("Input tokens").font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8).frame(height: 14)
                    Text("6+").font(.system(size: 16, weight: .medium, design: .rounded))
                        .monospacedDigit().textSelection(.enabled)
                        .lineLimit(1).minimumScaleFactor(0.7).frame(height: 21)
                }.frame(maxWidth: .infinity, alignment: .leading)
                .help("Input usage is unavailable for 1 requests. A + marks the known subtotal."))
        let coordinator = state.retainedUsageCoordinator(store: store)
        let retained = NSHostingView(
            rootView: RetainedInputAccessibilityCell(coordinator: coordinator))
        let window = NSWindow(
            contentRect: CGRect(x: -2000, y: -2000, width: 200, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        reference.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        retained.frame = CGRect(x: 0, y: 50, width: 200, height: 40)
        container.addSubview(reference)
        container.addSubview(retained)
        window.contentView = container
        defer {
            state.setActive(false, store: store)
            window.close()
        }
        publish(usage(input: 6, unknown: 1), store: store)
        drain()
        window.layoutIfNeeded()
        container.layoutSubtreeIfNeeded()
        let original = accessibilityStrings(reference)
        guard !original.isEmpty else {
            throw XCTSkip(
                "The independent ordinary SwiftUI reference exposes no token AX graph in this XCTest host; retained AX parity is unmeasured. Pixel, native-value, layout and accounting tests remain mandatory."
            )
        }
        XCTAssertTrue(original.contains(where: { $0.contains("Input tokens") }))
        XCTAssertTrue(original.contains(where: { $0.contains("6+") }))
        let candidate = accessibilityStrings(retained)
        XCTAssertTrue(candidate.contains(where: { $0.contains("Input tokens") }))
        XCTAssertTrue(candidate.contains(where: { $0.contains("6+") }))
        XCTAssertEqual(candidate, original)
    }

    private struct Capture {
        let frames: [String: CGRect]
        let pixels: Data
        let png: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let samples: Int
        let alphaIndex: Int?
        let nativeGeometry: String
    }
    private func capture(
        mode: PerformanceGraphicsDiagnostics.Mode, size: CGSize, scheme: ColorScheme = .light
    ) throws -> [Capture] {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: mode)
        let store = makeStore()
        let host = RetainedUsageTestHost(store: store, size: size)
        defer {
            host.close()
            drain()
            try? PerformanceGraphicsDiagnostics.shared.disable()
        }
        if scheme != .light {
            try host.settle()
            host.setColorScheme(scheme)
        }
        var result: [Capture] = []
        let fixtures: [(UsageScope, UsageSummary)] = [
            (.sinceLaunch, usage(input: 6, output: 24)),
            (
                .today,
                usage(
                    input: nil, unknown: 2, output: 235, estimated: true, tools: 2, requests: 2,
                    active: 2)
            ),
            (
                .selectedPeriod,
                usage(
                    input: 1_234, unknown: 1, output: 3_456, tools: 23, requests: 45, partial: true)
            ),
            (
                .sinceLaunch,
                usage(
                    input: Int.max, unknown: 1, output: Int.max, estimated: true,
                    tools: Int.max, requests: Int.max, partial: true)
            ),
        ]
        for (scope, usage) in fixtures {
            store.usageScope = scope
            publish(usage, store: store)
            try host.settle()
            let frames = host.state.scalarPerformanceFrames.filter { $0.key != "native-window" }
            let statistics = try XCTUnwrap(frames["statistics-row"])
            let image = try host.pixels(in: statistics)
            result.append(
                Capture(
                    frames: frames, pixels: image.data, png: image.png,
                    pixelWidth: image.width, pixelHeight: image.height, samples: image.samples,
                    alphaIndex: image.alphaIndex,
                    nativeGeometry: host.nativeGeometry()))
            if mode == .runtimeRetainedUsage {
                let owner = try retainedOwner(host.state)
                XCTAssertEqual(owner["scope"] as? String, scope.rawValue)
                XCTAssertEqual(
                    owner["values"] as? NSDictionary,
                    DashboardHeldUsage.values(for: usage) as NSDictionary)
            }
        }
        return result
    }
    private func assertPixelParity(_ actual: [Capture], _ expected: [Capture], label: String) throws
    {
        XCTAssertEqual(actual.count, expected.count)
        for (index, pair) in zip(actual, expected).enumerated() {
            let (candidate, reference) = pair
            XCTAssertEqual(candidate.pixelWidth, reference.pixelWidth)
            XCTAssertEqual(candidate.pixelHeight, reference.pixelHeight)
            XCTAssertEqual(candidate.samples, reference.samples)
            XCTAssertEqual(candidate.alphaIndex, reference.alphaIndex)
            XCTAssertEqual(candidate.pixels.count, reference.pixels.count)
            guard candidate.pixels != reference.pixels else { continue }
            // CoreGraphics and SwiftUI can quantize an identical glyph's RGB
            // coverage by one 8-bit step. Compare the SAME pixel coordinates;
            // dimensions/geometry/alpha remain exact, with no image shifts.
            if candidate.pixelWidth == reference.pixelWidth,
                candidate.pixelHeight == reference.pixelHeight,
                candidate.samples == reference.samples,
                candidate.alphaIndex == reference.alphaIndex,
                candidate.pixels.count == reference.pixels.count
            {
                let valid = candidate.pixels.indices.allSatisfy { offset in
                    let delta = abs(Int(candidate.pixels[offset]) - Int(reference.pixels[offset]))
                    return offset % candidate.samples == candidate.alphaIndex
                        ? delta == 0 : delta <= 1
                }
                if valid { continue }
            }
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(
                    ".performance-results/retained-usage-pixel-diffs", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let stem = "\(label)-phase\(index)-\(UUID().uuidString)"
            let expectedPath = directory.appendingPathComponent("\(stem)-normal.png")
            let actualPath = directory.appendingPathComponent("\(stem)-retained.png")
            try reference.png.write(to: expectedPath)
            try candidate.png.write(to: actualPath)
            var count = 0
            var minX = Int.max
            var minY = Int.max
            var maxX = -1
            var maxY = -1
            if candidate.pixels.count == reference.pixels.count,
                candidate.pixelWidth == reference.pixelWidth
            {
                for offset in 0..<candidate.pixels.count
                where candidate.pixels[offset] != reference.pixels[offset] {
                    let pixel = offset / candidate.samples
                    let x = pixel % candidate.pixelWidth
                    let y = pixel / candidate.pixelWidth
                    count += 1
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            XCTFail(
                "Usage pixels differ: \(label) phase\(index), dimensions=\(candidate.pixelWidth)x\(candidate.pixelHeight), changedBytes=\(count), bounds=(\(minX),\(minY))–(\(maxX),\(maxY)); normal=\(expectedPath.path); retained=\(actualPath.path); geometry=\(candidate.nativeGeometry)"
            )
        }
    }
    private func makeStore() -> MetricsStore {
        let store = MetricsStore(clock: { self.origin })
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        store.updateConnection(.ready)
        store.setChartPresentationDemand(true, consumer: .dashboard)
        store.setChartPresentationDemand(true, consumer: .popover)
        store.sample(at: origin)
        return store
    }
    private func usage(
        input: Int? = 6, unknown: Int = 0, output: Int = 0, estimated: Bool = false,
        tools: Int = 0, requests: Int = 0, active: Int = 0, partial: Bool = false
    ) -> UsageSummary {
        UsageSummary(
            inputTokens: input, unknownInputRequests: unknown, outputTokens: output,
            outputIsEstimated: estimated, toolCalls: tools, requests: requests,
            activeRequests: active, isPartial: partial)
    }
    private func publish(_ usage: UsageSummary, store: MetricsStore) {
        store.liveScalars.updateCoalesced(
            DashboardScalarPresentation(
                latestResponse: nil, usage: usage, usageScope: store.usageScope,
                selectedInterval: nil, historyPersistenceError: nil))
    }
    private func drain() {
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    private func namespace() -> [String: Any] {
        PerformanceGraphicsDiagnostics.shared.snapshot()["retained_usage"] as? [String: Any] ?? [:]
    }
    private func counter(_ key: String) -> UInt64 {
        (namespace()[key] as? NSNumber)?.uint64Value ?? .max
    }
    private func retainedOwner(_ state: DashboardPresentationState) throws -> [String: Any] {
        let owners = try XCTUnwrap(namespace()["owners"] as? [String: [String: Any]])
        return try XCTUnwrap(owners[state.scalarPerformanceOwnerID.uuidString])
    }
    private func presented(_ state: DashboardPresentationState) throws -> [String: [String: Any]] {
        let scalar = try XCTUnwrap(
            PerformanceGraphicsDiagnostics.shared.snapshot()["scalar_presentation"]
                as? [String: Any])
        let owners = try XCTUnwrap(scalar["presentation_owners"] as? [String: [String: Any]])
        return try XCTUnwrap(
            owners[state.scalarPerformanceOwnerID.uuidString]?["presented_values"]
                as? [String: [String: Any]])
    }
    private func dashboardWitness(_ state: DashboardPresentationState) throws -> [String: Any] {
        try XCTUnwrap(try presented(state)["dashboard_usage"])
    }
    private func work(_ state: DashboardPresentationState) throws -> [String: UInt64] {
        let scalar = try XCTUnwrap(
            PerformanceGraphicsDiagnostics.shared.snapshot()["scalar_presentation"]
                as? [String: Any])
        let owners = try XCTUnwrap(scalar["presentation_owners"] as? [String: [String: Any]])
        let bodies = try XCTUnwrap(
            owners[state.scalarPerformanceOwnerID.uuidString]?["leaf_body_updates"]
                as? [String: UInt64])
        return [
            "details": bodies["details"] ?? 0,
            "size": try XCTUnwrap(scalar["layout_size_calls"] as? UInt64),
            "place": try XCTUnwrap(scalar["layout_place_calls"] as? UInt64),
            "measure": try XCTUnwrap(scalar["layout_child_measurements"] as? UInt64),
        ]
    }
    private func accessibilityStrings(_ view: NSView) -> [String] {
        var seen: Set<ObjectIdentifier> = []
        var values: [String] = []
        func visit(_ object: Any, depth: Int) {
            guard depth < 24, seen.count < 512, let node = object as? NSObject,
                seen.insert(ObjectIdentifier(node)).inserted
            else { return }
            func read(_ name: String) -> Any? {
                let selector = NSSelectorFromString(name)
                guard node.responds(to: selector) else { return nil }
                return node.perform(selector)?.takeUnretainedValue()
            }
            let label = read("accessibilityLabel") as? String ?? ""
            let value = read("accessibilityValue")
            let text =
                (value as? String) ?? (value as? NSAttributedString)?.string
                ?? (value as? NSNumber)?.stringValue ?? ""
            let help = read("accessibilityHelp") as? String ?? ""
            if !label.isEmpty || !text.isEmpty || !help.isEmpty {
                values.append("\(label)|\(text)|\(help)")
            }
            for child in read("accessibilityChildren") as? [Any] ?? [] {
                visit(child, depth: depth + 1)
            }
            for child in read("accessibilityChildrenInNavigationOrder") as? [Any] ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(view, depth: 0)
        if let exposed = NSAccessibility.unignoredDescendant(of: view) { visit(exposed, depth: 0) }
        return values.sorted()
    }
}

private struct RetainedInputAccessibilityCell: View {
    let coordinator: DashboardRetainedUsageCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Input tokens").font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8).frame(height: 14)
            DashboardRetainedUsageField(
                coordinator: coordinator, field: .input,
                density: .roomy, colorScheme: .light)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(coordinator.inputHelp.text)
    }
}

@MainActor
private final class RetainedUsageTestHost {
    let state: DashboardPresentationState
    private let store: MetricsStore
    private let window: NSWindow
    private var hosting: NSHostingController<AnyView>?
    private let size: CGSize
    private let compact: Bool

    init(
        store: MetricsStore, size: CGSize, compact: Bool = false,
        state: DashboardPresentationState = DashboardPresentationState()
    ) {
        _ = NSApplication.shared
        self.store = store
        self.size = size
        self.state = state
        self.compact = compact
        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -2000, y: -2000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        state.setActive(true, store: store)
        state.bindScalarPerformanceWindow(window, role: compact ? "popover" : "dashboard")
        let host = NSHostingController(
            rootView: AnyView(
                DashboardView(isCompact: compact, presentation: state).environment(store)
                    .environment(\.colorScheme, .light)))
        host.sizingOptions = []
        let container = NSViewController()
        container.view = NSView(frame: CGRect(origin: .zero, size: size))
        container.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])
        window.contentViewController = container
        window.setContentSize(size)
        hosting = host
    }

    func settle(forceLayout: Bool = true) throws {
        let view = try XCTUnwrap(hosting?.view)
        for _ in 0..<10 {
            if forceLayout { view.needsLayout = true }
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(view.bounds.size, size)
        XCTAssertNotNil(
            state.scalarPerformanceFrames["statistics-row"],
            "Current anchors: \(state.scalarPerformanceFrames.keys.sorted()); generation=\(state.scalarFrameGeneration)"
        )
    }

    func retainedHosts() -> [DashboardRetainedUsageHost] {
        func descend(_ view: NSView) -> [DashboardRetainedUsageHost] {
            if let host = view as? DashboardRetainedUsageHost { return [host] }
            return view.subviews.flatMap(descend)
        }
        return hosting.map { descend($0.view) } ?? []
    }

    func setColorScheme(_ scheme: ColorScheme) {
        hosting?.rootView = AnyView(
            DashboardView(isCompact: compact, presentation: state)
                .environment(store).environment(\.colorScheme, scheme))
    }

    func nativeGeometry() -> String {
        guard let root = hosting?.view else { return "detached" }
        return retainedHosts().map { $0.nativeGeometry(relativeTo: root) }.sorted().joined(
            separator: "; ")
    }

    func pixels(in frame: CGRect) throws -> (
        data: Data, png: Data, width: Int, height: Int, samples: Int, alphaIndex: Int?
    ) {
        let view = try XCTUnwrap(hosting?.view)
        let region = frame.integral.intersection(view.bounds)
        XCTAssertFalse(region.isEmpty)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: region))
        view.cacheDisplay(in: region, to: bitmap)
        XCTAssertEqual(bitmap.bitsPerSample, 8)
        XCTAssertFalse(bitmap.isPlanar)
        XCTAssertEqual(bitmap.colorSpace.numberOfColorComponents, 3)
        XCTAssertEqual(bitmap.colorSpace.colorSpaceModel, .rgb)
        XCTAssertEqual(bitmap.samplesPerPixel, bitmap.hasAlpha ? 4 : 3)
        let alphaIndex: Int? =
            bitmap.hasAlpha
            ? (bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bitmap.samplesPerPixel - 1) : nil
        let pointer = try XCTUnwrap(bitmap.bitmapData)
        var result = Data()
        for row in 0..<bitmap.pixelsHigh {
            result.append(
                pointer.advanced(by: row * bitmap.bytesPerRow),
                count: bitmap.pixelsWide * bitmap.samplesPerPixel)
        }
        XCTAssertGreaterThan(Set(result).count, 4)
        return (
            result, try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            bitmap.pixelsWide, bitmap.pixelsHigh, bitmap.samplesPerPixel, alphaIndex
        )
    }

    func close() {
        state.setActive(false, store: store)
        window.contentViewController = nil
        hosting = nil
        window.close()
    }
}
