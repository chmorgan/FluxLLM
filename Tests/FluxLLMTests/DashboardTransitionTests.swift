import AppKit
import SwiftUI
import XCTest

@testable import FluxLLM

/// Keep the production popover host alive while telemetry changes. Recreating a
/// host for each state misses preferred-content-size jumps during generation.
@MainActor
final class DashboardTransitionTests: XCTestCase {
    func testCompactRequestKeepsMetricPositionsAcrossPrefillStreamingAndCompletion() throws {
        try assertOllamaTransitionsStayFixed(windowSize: nil)
    }

    func testNarrowDashboardKeepsMetricPositionsAcrossRequestTransitions() throws {
        try assertOllamaTransitionsStayFixed(
            windowSize: DashboardSizingPolicy.minimumContentSize(forWidth: 360))
    }

    func testDashboardReflowsAtAllowedWidthsAndRestoresItsWideLayout() throws {
        let clock = DashboardTransitionClock()
        let store = MetricsStore(clock: { clock.now })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyBackendSample(
            BackendSample(kind: .ollama, timestamp: clock.now, model: "Qwen3-8B"), epoch: epoch)
        applyGPU(67, to: store, at: clock.now, epoch: epoch)
        store.sample(at: clock.now)
        let host = DashboardTransitionHost(
            store: store, windowSize: DashboardView.preferredWindowSize)
        defer { host.close() }
        let initial = try host.measure()

        for size in [
            DashboardSizingPolicy.minimumContentSize(forWidth: 519),
            DashboardSizingPolicy.minimumContentSize(forWidth: 520),
            DashboardSizingPolicy.minimumContentSize(forWidth: 360),
            DashboardSizingPolicy.minimumContentSize(forWidth: 320),
            DashboardSizingPolicy.minimumContentSize(forWidth: 740),
            DashboardView.preferredWindowSize,
        ] {
            host.resize(to: size)
            let measurement = try host.measure()
            try assertCardGeometry(measurement, isCompact: false)
            let history = try XCTUnwrap(measurement.frames["history-controls"])
            XCTAssertGreaterThanOrEqual(history.minX, -0.5)
            XCTAssertLessThanOrEqual(history.maxX, size.width + 0.5)
            let card = try XCTUnwrap(measurement.frames["activity-card"])
            XCTAssertLessThanOrEqual(history.maxY, card.minY + 0.5)
        }
        let restored = try host.measure()
        try assertFramesEqual(
            initial, restored, identifiers: frameIdentifiers(isCompact: false, isOllama: true))
    }

    func testDashboardChartsKeepTheirBoundsWhenModelAndRequestStatisticsArrive() throws {
        for size in [
            DashboardSizingPolicy.minimumContentSize(forWidth: 640),
            DashboardSizingPolicy.minimumContentSize(forWidth: 740),
            NSSize(width: 740, height: 632), DashboardView.preferredWindowSize,
            NSSize(width: 740, height: 1100),
        ] {
            try assertOllamaTransitionsStayFixed(windowSize: size)
        }
    }

    func testDashboardShrinksPlotToItsAllowedMinimumAndPreservesVisibleContent() throws {
        for kind in [BackendKind.ollama, .vllm] {
            let clock = DashboardTransitionClock()
            let store = MetricsStore(clock: { clock.now })
            let epoch = UUID()
            store.beginBackendSession(kind: kind, epoch: epoch)
            store.applyBackendSample(
                BackendSample(kind: kind, timestamp: clock.now, model: "Qwen3-8B"), epoch: epoch)
            if kind == .ollama {
                let request = GenerationRequest(
                    model: "Qwen3-8B", startedAt: clock.now.addingTimeInterval(-4))
                store.apply(.began(request), epoch: epoch)
            }
            applyGPU(67, to: store, at: clock.now, epoch: epoch)
            store.sample(at: clock.now)
            let preferred = DashboardView.preferredWindowSize
            let minimum = DashboardSizingPolicy.minimumContentSize(forWidth: preferred.width)
            let host = DashboardTransitionHost(store: store, windowSize: preferred)
            defer { host.close() }
            let standard = try host.measure()
            var previousPlot = try XCTUnwrap(standard.frames["main-activity-plot"])

            for height in [(preferred.height + minimum.height) / 2, minimum.height] {
                host.resize(to: NSSize(width: preferred.width, height: height))
                let compressed = try host.measure()
                try assertCardGeometry(compressed, isCompact: false)
                let plot = try XCTUnwrap(compressed.frames["main-activity-plot"])
                XCTAssertLessThan(plot.height, previousPlot.height)
                previousPlot = plot
            }

            host.resize(to: DashboardSizingPolicy.minimumContentSize(forWidth: 320))
            let narrow = try host.measure()
            try assertCardGeometry(narrow, isCompact: false)
            let history = try XCTUnwrap(narrow.frames["history-controls"])
            let card = try XCTUnwrap(narrow.frames["activity-card"])
            XCTAssertLessThanOrEqual(history.maxY, card.minY + 0.5)

            host.resize(to: preferred)
            let restored = try host.measure()
            try assertFramesEqual(
                standard, restored,
                identifiers: frameIdentifiers(isCompact: false, isOllama: kind == .ollama))
        }
    }

    func testBackendSwitchesFitWithinTheSameMinimumWindow() throws {
        for width: CGFloat in [320, 360, 519, 520, 740] {
            let clock = DashboardTransitionClock()
            let store = MetricsStore(clock: { clock.now })
            let size = DashboardSizingPolicy.minimumContentSize(forWidth: width)
            let host = DashboardTransitionHost(store: store, windowSize: size)
            defer { host.close() }

            for kind in [BackendKind.vllm, .ollama, .rapidMLX, .ollama] {
                let epoch = UUID()
                store.beginBackendSession(kind: kind, epoch: epoch)
                store.applyBackendSample(
                    BackendSample(kind: kind, timestamp: clock.now, model: "Qwen3-8B"),
                    epoch: epoch)
                applyGPU(67, to: store, at: clock.now, epoch: epoch)
                store.sample(at: clock.now)
                let measurement = try host.measure()
                XCTAssertEqual(measurement.size.width, size.width, accuracy: 0.5)
                XCTAssertEqual(measurement.size.height, size.height, accuracy: 0.5)
                XCTAssertEqual(measurement.hasTools, store.chartPresentation.supportsToolActivity)
                try assertCardGeometry(measurement, isCompact: false)
            }
        }
    }

    func testDashboardActivityChartExpandsWhenTheExistingWindowGetsTaller() throws {
        let clock = DashboardTransitionClock()
        let store = MetricsStore(clock: { clock.now })
        let epoch = UUID()
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: clock.now, model: "Qwen3-8B", currentTPS: 42,
                runningRequests: 1, queuedRequests: 0, outputTokens: 2400, promptTokens: 320),
            epoch: epoch)
        applyGPU(67, to: store, at: clock.now, epoch: epoch)
        store.sample(at: clock.now)
        let preferred = DashboardView.preferredWindowSize
        let minimumSize = DashboardSizingPolicy.minimumContentSize(forWidth: preferred.width)
        let host = DashboardTransitionHost(store: store, windowSize: minimumSize)
        defer { host.close() }
        let minimum = try host.measure()
        try assertCardGeometry(minimum, isCompact: false)

        host.resize(to: preferred)
        let standard = try host.measure()
        try assertCardGeometry(standard, isCompact: false)
        let tallSize = NSSize(
            width: preferred.width,
            height: DashboardSizingPolicy.roomyHeight(forWidth: preferred.width) + 40)
        host.resize(to: tallSize)
        let tall = try host.measure()
        try assertCardGeometry(tall, isCompact: false)

        let minimumPlot = try XCTUnwrap(minimum.frames["main-activity-plot"])
        let standardPlot = try XCTUnwrap(standard.frames["main-activity-plot"])
        let tallPlot = try XCTUnwrap(tall.frames["main-activity-plot"])
        XCTAssertGreaterThan(standardPlot.height, minimumPlot.height)
        XCTAssertGreaterThan(tallPlot.height, standardPlot.height)
        XCTAssertLessThanOrEqual(
            tallPlot.height - standardPlot.height, tallSize.height - preferred.height + 1)

        // Only heights beyond the roomy threshold keep identical control sizes;
        // all additional height then belongs to the main plot.
        host.resize(to: NSSize(width: tallSize.width, height: tallSize.height + 200))
        let roomier = try host.measure()
        let roomierPlot = try XCTUnwrap(roomier.frames["main-activity-plot"])
        XCTAssertEqual(roomierPlot.height - tallPlot.height, 200, accuracy: 1)
        try assertFramesEqual(
            tall, roomier,
            identifiers: ["dashboard-header", "provider-model", "throughput-value", "gpu-value"])

        host.resize(to: preferred)
        let restored = try host.measure()
        assertSizeEqual(standard, restored)
        try assertFramesEqual(
            standard, restored, identifiers: frameIdentifiers(isCompact: false, isOllama: false))
    }

    private func assertOllamaTransitionsStayFixed(windowSize: NSSize?) throws {
        let clock = DashboardTransitionClock()
        let store = MetricsStore(clock: { clock.now })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyBackendSample(
            BackendSample(kind: .ollama, timestamp: clock.now), epoch: epoch)
        applyGPU(nil, to: store, at: clock.now, epoch: epoch)
        store.sample(at: clock.now)
        let host = DashboardTransitionHost(store: store, windowSize: windowSize)
        defer { host.close() }
        let identifiers = frameIdentifiers(isCompact: windowSize == nil)
        let idle = try host.measure()
        XCTAssertNil(store.currentModel)
        XCTAssertNil(store.activeGeneration)
        // Every metric slot exists before the first model or request arrives.
        try assertFramesEqual(idle, idle, identifiers: identifiers)

        clock.advance(0.25)
        store.applyBackendSample(
            BackendSample(kind: .ollama, timestamp: clock.now, model: "Qwen3-8B"),
            epoch: epoch)
        store.sample(at: clock.now)
        let modelLoaded = try host.measure()
        XCTAssertEqual(store.currentModel, "Qwen3-8B")
        assertSizeEqual(idle, modelLoaded)
        try assertFramesEqual(idle, modelLoaded, identifiers: identifiers)

        clock.advance(0.25)
        let request = GenerationRequest(startedAt: clock.now)
        store.apply(.began(request), epoch: epoch)
        store.sample(at: clock.now)
        let prefill = try host.measure()
        XCTAssertNil(store.currentModel)
        assertSizeEqual(idle, prefill)
        try assertFramesEqual(idle, prefill, identifiers: identifiers)

        clock.advance(0.25)
        store.apply(
            .toolActivity(
                requestID: request.id,
                events: [
                    ToolActivityEvent(kind: .call, name: "read_file", timestamp: clock.now)
                ]), epoch: epoch)
        store.sample(at: clock.now)
        let firstToolCall = try host.measure()
        XCTAssertEqual(store.toolActivityEvents.count, 1)
        assertSizeEqual(idle, firstToolCall)
        try assertFramesEqual(idle, firstToolCall, identifiers: identifiers)

        let readings: [(tokens: Int, rate: Double, gpu: Double?)] = [
            (1, 1, 0), (84, 1234.5, 73), (999, 9.7, nil), (10_024, 204.3, 100),
        ]
        for (index, reading) in readings.enumerated() {
            clock.advance(0.75)
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        model: index == 2
                            ? "mlx-community/Qwen3.8-27B-Instruct-Reasoning-Long-Context-8bit"
                            : "Qwen3-8B",
                        outputTokens: reading.tokens, liveTPS: reading.rate,
                        elapsed: clock.now.timeIntervalSince(request.startedAt),
                        timestamp: clock.now)),
                epoch: epoch)
            applyGPU(reading.gpu, to: store, at: clock.now, epoch: epoch)
            store.sample(at: clock.now)
            let streaming = try host.measure()
            assertSizeEqual(idle, streaming)
            try assertFramesEqual(idle, streaming, identifiers: identifiers)
        }

        clock.advance(0.5)
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 10_432, promptTokens: 120, isEstimated: false,
                    authoritativeTPS: 44.6, finished: true,
                    elapsed: clock.now.timeIntervalSince(request.startedAt), timestamp: clock.now)),
            epoch: epoch)
        applyGPU(0, to: store, at: clock.now, epoch: epoch)
        store.sample(at: clock.now)
        let completed = try host.measure()
        assertSizeEqual(idle, completed)
        try assertFramesEqual(idle, completed, identifiers: identifiers)
        XCTAssertEqual(store.outputTokens, 10_432)
        XCTAssertEqual(store.promptTokens, 120)
        XCTAssertEqual(store.lastMeasuredTPS, 44.6)
        XCTAssertEqual(store.activeGeneration?.state, .completed)

        clock.advance(0.5)
        store.apply(.began(GenerationRequest(startedAt: clock.now)), epoch: epoch)
        store.sample(at: clock.now)
        let nextRequest = try host.measure()
        XCTAssertNil(store.currentModel)
        XCTAssertNil(store.promptTokens)
        assertSizeEqual(idle, nextRequest)
        try assertFramesEqual(idle, nextRequest, identifiers: identifiers)
    }

    func testNativeCountersAndModelChangesKeepExistingMetricSlotsAndChartBounds() throws {
        let windowSizes: [NSSize?] = [nil, DashboardView.preferredWindowSize]
        for windowSize in windowSizes {
            let clock = DashboardTransitionClock()
            let store = MetricsStore(clock: { clock.now })
            let epoch = UUID()
            store.beginBackendSession(kind: .vllm, epoch: epoch)
            store.applyBackendSample(
                BackendSample(
                    kind: .vllm, timestamp: clock.now, currentTPS: 0,
                    runningRequests: 0, queuedRequests: 0), epoch: epoch)
            applyGPU(0, to: store, at: clock.now, epoch: epoch)
            store.sample(at: clock.now)
            let host = DashboardTransitionHost(store: store, windowSize: windowSize)
            defer { host.close() }
            let initial = try host.measure()
            let identifiers = frameIdentifiers(isCompact: windowSize == nil, isOllama: false)
            try assertFramesEqual(initial, initial, identifiers: identifiers)

            for state in [
                (model: "Qwen3-8B", rate: 28.5, requests: 1, output: 12, prompt: 160),
                (
                    model: "mlx-community/Qwen3.8-27B-Instruct-Reasoning-Long-Context-8bit",
                    rate: 1382.5, requests: 125, output: 123_456, prompt: 45_678
                ),
                (model: nil, rate: nil, requests: nil, output: nil, prompt: nil),
                (model: nil, rate: 0, requests: 0, output: nil, prompt: nil),
            ] as [(model: String?, rate: Double?, requests: Int?, output: Int?, prompt: Int?)] {
                clock.advance(0.5)
                store.applyBackendSample(
                    BackendSample(
                        kind: .vllm, timestamp: clock.now, model: state.model,
                        currentTPS: state.rate, runningRequests: state.requests,
                        queuedRequests: state.requests.map { $0 > 0 ? 1 : 0 },
                        outputTokens: state.output, promptTokens: state.prompt), epoch: epoch)
                store.sample(at: clock.now)
                let current = try host.measure()
                assertSizeEqual(initial, current)
                try assertFramesEqual(initial, current, identifiers: identifiers)
            }
        }
    }

    func testFreshStreamAndLateHealthFailuresDoNotResizeAnExistingPopover() throws {
        let clock = DashboardTransitionClock()
        let store = MetricsStore(clock: { clock.now })
        let epoch = UUID()
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        // The health sample deliberately becomes stale while output continues.
        store.applyBackendSample(
            BackendSample(kind: .ollama, timestamp: clock.now), epoch: epoch)
        let request = GenerationRequest(model: "Qwen3-8B", startedAt: clock.now)
        store.apply(.began(request), epoch: epoch)
        store.sample(at: clock.now)
        let host = DashboardTransitionHost(store: store)
        defer { host.close() }
        let initial = try host.measure()

        for index in 1...14 {
            clock.advance(0.5)
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        outputTokens: index * 14, liveTPS: index.isMultiple(of: 2) ? 24 : 37,
                        elapsed: clock.now.timeIntervalSince(request.startedAt),
                        timestamp: clock.now)),
                epoch: epoch)
            // Model a probe finishing after a newer successful stream chunk.
            store.updateConnection(
                index.isMultiple(of: 2) ? .unavailable : .connecting,
                message: "Delayed health probe", at: clock.now)
            XCTAssertEqual(store.connectionState, .ready)
            XCTAssertNil(BackendPresentation.configurationPrompt(store: store))
            store.sample(at: clock.now)
            XCTAssertEqual(store.connectionState, .ready)
            XCTAssertNil(BackendPresentation.configurationPrompt(store: store))
            let current = try host.measure()
            assertSizeEqual(initial, current)
            try assertFramesEqual(initial, current, identifiers: frameIdentifiers(isCompact: true))
        }
    }

    func testSlowPrefillAndRecoveryKeepExistingPopoverAndDashboardChartBounds() throws {
        let windowSizes: [NSSize?] = [
            nil, DashboardView.preferredWindowSize, NSSize(width: 740, height: 900),
        ]
        for windowSize in windowSizes {
            let clock = DashboardTransitionClock()
            let store = MetricsStore(clock: { clock.now })
            let epoch = UUID()
            store.beginBackendSession(kind: .ollama, epoch: epoch)
            store.applyBackendSample(
                BackendSample(kind: .ollama, timestamp: clock.now), epoch: epoch)
            applyGPU(0, to: store, at: clock.now, epoch: epoch)
            store.sample(at: clock.now)
            let host = DashboardTransitionHost(store: store, windowSize: windowSize)
            defer { host.close() }
            let initial = try host.measure()
            let identifiers = frameIdentifiers(isCompact: windowSize == nil)

            clock.advance(0.25)
            let request = GenerationRequest(startedAt: clock.now)
            store.apply(.began(request), epoch: epoch)
            store.sample(at: clock.now)
            let prefill = try host.measure()
            assertSizeEqual(initial, prefill)
            try assertFramesEqual(initial, prefill, identifiers: identifiers)

            // Model loading can outlast freshness before the first stream chunk.
            // Health freshness must not move the chart or hide the open request.
            clock.advance(6)
            store.sample(at: clock.now)
            XCTAssertEqual(store.connectionState, .unavailable)
            XCTAssertNotNil(BackendPresentation.configurationPrompt(store: store))
            XCTAssertEqual(BackendPresentation.statusTitle(store: store), "Active")
            XCTAssertEqual(BackendPresentation.rateLabel(store: store), "0.0")
            let stale = try host.measure()
            assertSizeEqual(initial, stale)
            try assertFramesEqual(initial, stale, identifiers: identifiers)

            clock.advance(0.5)
            store.updateConnection(
                .unavailable, message: "Health probe timed out during model loading", at: clock.now)
            store.sample(at: clock.now)
            XCTAssertEqual(store.connectionState, .unavailable)
            let failedHealth = try host.measure()
            assertSizeEqual(initial, failedHealth)
            try assertFramesEqual(initial, failedHealth, identifiers: identifiers)

            clock.advance(0.1)
            store.apply(
                .updated(
                    requestID: request.id,
                    snapshot: GenerationSnapshot(
                        model: "mlx-community/Qwen3.8-27B-Instruct-Reasoning-Long-Context-8bit",
                        outputTokens: 1, liveTPS: 10, elapsed: 0.1, timestamp: clock.now)),
                epoch: epoch)
            applyGPU(78, to: store, at: clock.now, epoch: epoch)
            store.sample(at: clock.now)
            XCTAssertEqual(store.connectionState, .ready)
            XCTAssertNil(BackendPresentation.configurationPrompt(store: store))
            let firstOutput = try host.measure()
            assertSizeEqual(initial, firstOutput)
            try assertFramesEqual(initial, firstOutput, identifiers: identifiers)
        }
    }

    private func frameIdentifiers(isCompact: Bool, isOllama: Bool = true) -> [String] {
        var identifiers = [
            "dashboard-header", "provider-model", "throughput-value", "gpu-value",
            "activity-chart", "activity-card", "statistics-row",
        ]
        if isCompact {
            identifiers.append("compact-activity")
            if isOllama { identifiers.append("total-response-tokens") }
        } else {
            identifiers += [
                "main-activity-plot", "request-rail-band", "dashboard-content", "dashboard-footer",
            ]
        }
        return identifiers
    }

    private func applyGPU(
        _ value: Double?, to store: MetricsStore, at date: Date, epoch: UUID
    ) {
        store.applyGPUSample(
            GPUActivitySample(
                timestamp: date, activityPercent: value,
                source: "macOS Device Utilization %",
                unavailableReason: value == nil ? "System GPU counters are unavailable." : nil,
                scope: .system), epoch: epoch)
    }

    private func assertSizeEqual(
        _ expected: DashboardTransitionMeasurement, _ actual: DashboardTransitionMeasurement,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            actual.size.width, expected.size.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(
            actual.size.height, expected.size.height, accuracy: 0.5,
            "Telemetry updates must not resize the dashboard", file: file, line: line)
    }

    private func assertFramesEqual(
        _ expected: DashboardTransitionMeasurement, _ actual: DashboardTransitionMeasurement,
        identifiers: [String], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try assertCardGeometry(
            actual, isCompact: actual.frames["compact-activity"] != nil, file: file, line: line)
        for identifier in identifiers {
            let before = try XCTUnwrap(
                expected.frames[identifier], identifier, file: file, line: line)
            let after = try XCTUnwrap(actual.frames[identifier], identifier, file: file, line: line)
            XCTAssertGreaterThan(before.height, 0, identifier, file: file, line: line)
            XCTAssertEqual(
                after.minX, before.minX, accuracy: 0.5,
                "\(identifier) shifted horizontally", file: file, line: line)
            if identifier != "gpu-value" {
                XCTAssertEqual(
                    after.width, before.width, accuracy: 0.5,
                    "\(identifier) changed width", file: file, line: line)
            }
            XCTAssertEqual(
                after.minY, before.minY, accuracy: 0.5,
                "\(identifier) shifted vertically", file: file, line: line)
            XCTAssertEqual(
                after.maxY, before.maxY, accuracy: 0.5,
                "\(identifier) bottom edge shifted", file: file, line: line)
            XCTAssertEqual(
                after.height, before.height, accuracy: 0.5,
                "\(identifier) changed height", file: file, line: line)
        }
    }

    private func assertCardGeometry(
        _ measurement: DashboardTransitionMeasurement, isCompact: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let card = try XCTUnwrap(measurement.frames["activity-card"], file: file, line: line)
        let plot = try XCTUnwrap(measurement.frames["activity-chart"], file: file, line: line)
        let throughputReading = try XCTUnwrap(
            measurement.frames["throughput-value"], file: file, line: line)
        let gpuReading = try XCTUnwrap(measurement.frames["gpu-value"], file: file, line: line)
        let viewport = CGRect(origin: .zero, size: measurement.size).insetBy(dx: -0.5, dy: -0.5)
        let cardBounds = card.insetBy(dx: -0.5, dy: -0.5)
        XCTAssertGreaterThanOrEqual(card.minX, viewport.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(card.maxX, viewport.maxX, file: file, line: line)
        XCTAssertTrue(
            cardBounds.contains(plot), "The shared plot must remain inside the activity card",
            file: file, line: line)
        for (name, reading) in [("Generated", throughputReading), ("GPU", gpuReading)] {
            XCTAssertTrue(
                cardBounds.contains(reading),
                "\(name) reading must remain inside the activity card",
                file: file, line: line)
            XCTAssertLessThanOrEqual(
                reading.maxY, plot.minY + 0.5,
                "\(name) reading must remain above the shared plot", file: file, line: line)
        }
        if !isCompact, measurement.size.width < 520 {
            XCTAssertLessThanOrEqual(
                throughputReading.maxY, gpuReading.minY + 0.5,
                "Narrow dashboard readings must stack without overlap", file: file, line: line)
        } else {
            XCTAssertEqual(
                throughputReading.minY, gpuReading.minY, accuracy: 0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(
                throughputReading.maxX, gpuReading.minX + 0.5,
                "Generated and GPU readings must remain side by side", file: file, line: line)
        }
        let header = try XCTUnwrap(measurement.frames["dashboard-header"], file: file, line: line)
        XCTAssertLessThanOrEqual(header.maxY, card.minY + 0.5, file: file, line: line)
        let statistics = try XCTUnwrap(measurement.frames["statistics-row"], file: file, line: line)
        XCTAssertGreaterThanOrEqual(statistics.minY, card.maxY - 0.5, file: file, line: line)
        if isCompact {
            XCTAssertEqual(measurement.size.width, 360, accuracy: 0.5, file: file, line: line)
            XCTAssertLessThanOrEqual(measurement.size.height, 490, file: file, line: line)
            XCTAssertTrue(viewport.contains(card), file: file, line: line)
            XCTAssertLessThanOrEqual(
                statistics.maxY, measurement.size.height + 0.5, file: file, line: line)
            XCTAssertGreaterThanOrEqual(plot.width, 280, file: file, line: line)
            XCTAssertEqual(
                plot.height, LuminousActivityChart.compactHeight(hasTools: measurement.hasTools),
                accuracy: 0.5, file: file, line: line)
        } else {
            let compression = DashboardHeightPolicy(
                viewportHeight: measurement.size.height, viewportWidth: measurement.size.width
            ).compression
            let content = try XCTUnwrap(
                measurement.frames["dashboard-content"], file: file, line: line)
            let footer = try XCTUnwrap(
                measurement.frames["dashboard-footer"], file: file, line: line)
            XCTAssertTrue(
                viewport.contains(content), "Dashboard content must fit without scrolling",
                file: file, line: line)
            XCTAssertTrue(
                viewport.contains(footer), "The footer must remain visible at every allowed size",
                file: file, line: line)
            XCTAssertTrue(viewport.contains(card), file: file, line: line)
            XCTAssertLessThanOrEqual(
                statistics.maxY, footer.minY + 0.5, file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                plot.height,
                LuminousActivityChart.minimumHeight(
                    hasTools: measurement.hasTools, compression: compression) - 0.5,
                file: file, line: line)
            let main = try XCTUnwrap(
                measurement.frames["main-activity-plot"], file: file, line: line)
            let rails = try XCTUnwrap(
                measurement.frames["request-rail-band"], file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                main.height, 87.5, "The throughput and GPU plot must remain readable",
                file: file, line: line)
            XCTAssertEqual(
                rails.height, 84, accuracy: 0.5,
                "Window compression must preserve request rail thickness and spacing",
                file: file, line: line)
            XCTAssertTrue(cardBounds.contains(main), file: file, line: line)
            XCTAssertTrue(cardBounds.contains(rails), file: file, line: line)
            XCTAssertLessThanOrEqual(main.maxY, rails.minY, file: file, line: line)
        }
    }
}

@MainActor
private final class DashboardTransitionClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

private struct DashboardTransitionMeasurement {
    let size: NSSize
    let frames: [String: CGRect]
    let hasTools: Bool
}

private struct DashboardTransitionFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

@MainActor
private final class DashboardTransitionFrameMeasurements {
    var frames: [String: CGRect] = [:]
}

@MainActor
private final class DashboardTransitionHost {
    private let hosting: NSHostingController<AnyView>
    private let window: NSWindow
    private let measurements: DashboardTransitionFrameMeasurements
    private let store: MetricsStore
    private var windowSize: NSSize?

    init(store: MetricsStore, windowSize: NSSize? = nil) {
        _ = NSApplication.shared
        self.windowSize = windowSize
        self.store = store
        let frameMeasurements = DashboardTransitionFrameMeasurements()
        measurements = frameMeasurements
        let surface: AnyView
        if windowSize != nil {
            surface = AnyView(
                DashboardView().environment(store).environment(\.colorScheme, .light))
        } else {
            surface = AnyView(
                MenuBarExtraView().environment(store).environment(\.colorScheme, .light)
                    .frame(width: DashboardView.compactWidth))
        }
        hosting = NSHostingController(
            rootView: AnyView(
                surface
                    .overlayPreferenceValue(DashboardFrameAnchors.self) { anchors in
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: DashboardTransitionFrames.self,
                                value: anchors.mapValues { geometry[$0] })
                        }
                    }
                    .onPreferenceChange(DashboardTransitionFrames.self) { frames in
                        Task { @MainActor in frameMeasurements.frames = frames }
                    }))
        hosting.sizingOptions = windowSize == nil ? [.preferredContentSize] : []
        window = NSWindow(
            contentRect: NSRect(
                origin: NSPoint(x: -2000, y: -2000),
                size: windowSize ?? NSSize(width: DashboardView.compactWidth, height: 480)),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        if let windowSize {
            // Pin the retained controller inside a real AppKit content view.
            // Offscreen NSHostingController window attachment alone can reset
            // the controller's view to zero despite its nonzero fitting size.
            let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
            let containerController = NSViewController()
            containerController.view = container
            containerController.addChild(hosting)
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            window.contentViewController = containerController
            window.setContentSize(windowSize)
            container.setFrameSize(windowSize)
        } else {
            window.contentViewController = hosting
        }
        // Never show or activate the window; all measurements stay in process.
    }

    private func containsScrollView(_ view: NSView) -> Bool {
        view is NSScrollView || view.subviews.contains { containsScrollView($0) }
    }

    func close() {
        window.close()
    }

    func resize(to size: NSSize) {
        precondition(
            windowSize != nil, "Only the dashboard window resizes independently of content")
        windowSize = size
    }

    func measure() throws -> DashboardTransitionMeasurement {
        for _ in 0..<5 {
            if let windowSize {
                window.setContentSize(windowSize)
                window.contentView?.setFrameSize(windowSize)
                window.updateConstraintsIfNeeded()
                window.layoutIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
            }
            hosting.view.needsLayout = true
            hosting.view.layoutSubtreeIfNeeded()
            window.setContentSize(windowSize ?? hosting.view.fittingSize)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        hosting.view.layoutSubtreeIfNeeded()
        if let windowSize {
            let content = try XCTUnwrap(window.contentView)
            XCTAssertEqual(content.bounds.size.width, windowSize.width, accuracy: 0.5)
            XCTAssertEqual(content.bounds.size.height, windowSize.height, accuracy: 0.5)
            let layoutDescription =
                "Content frame: \(content.frame); hosted frame: \(hosting.view.frame)"
            XCTAssertEqual(
                hosting.view.bounds.size.width, windowSize.width, accuracy: 0.5, layoutDescription)
            XCTAssertEqual(
                hosting.view.bounds.size.height, windowSize.height, accuracy: 0.5, layoutDescription
            )
            XCTAssertFalse(
                containsScrollView(hosting.view),
                "The dashboard must not create horizontal or vertical scroll containers")
            // A constrained controller with sizingOptions=[] follows its window
            // bounds; it intentionally supplies no intrinsic fitting size.
            return DashboardTransitionMeasurement(
                size: hosting.view.bounds.size, frames: measurements.frames,
                hasTools: store.chartPresentation.supportsToolActivity)
        }
        let fitting = hosting.view.fittingSize
        XCTAssertEqual(fitting.width, DashboardView.compactWidth, accuracy: 0.5)
        XCTAssertEqual(hosting.preferredContentSize.width, fitting.width, accuracy: 0.5)
        XCTAssertEqual(hosting.preferredContentSize.height, fitting.height, accuracy: 0.5)
        return DashboardTransitionMeasurement(
            size: fitting, frames: measurements.frames,
            hasTools: store.chartPresentation.supportsToolActivity)
    }
}
