import AppKit
import XCTest

@testable import FluxLLM

@MainActor
final class StatusItemPresentationTests: XCTestCase {
    func testCompactRateDistinguishesUnavailableAndAvailable() {
        XCTAssertEqual(
            StatusItemPresentation.compactTPS(tps: 50, active: false), "— t/s")
        XCTAssertEqual(
            StatusItemPresentation.compactTPS(tps: 50, active: true), "50 t/s")
    }

    func testCompactRateHandlesInvalidAndVeryLargeValues() {
        for rate in [Double.nan, .infinity, -.infinity, -20] {
            XCTAssertEqual(
                StatusItemPresentation.compactTPS(tps: rate, active: true),
                "— t/s")
        }
        XCTAssertEqual(
            StatusItemPresentation.compactTPS(tps: 1_500, active: true),
            "1500 t/s")
        XCTAssertEqual(
            StatusItemPresentation.compactTPS(tps: 1_000_000, active: true),
            "999999+ t/s")
        XCTAssertEqual(
            StatusItemPresentation.compactTPS(tps: .greatestFiniteMagnitude, active: true),
            "999999+ t/s")
    }

    func testNumberBudgetGrowsAtRoundedDigitBoundariesAndRetainsItsMaximum() {
        var budget = StatusItemWidthBudget()
        XCTAssertEqual(budget.numberCharacters, 3)
        for rate in [nil, Double.nan, .infinity, -.infinity, -1, 0, 50, 999.4] {
            budget.observe(publishedTPS: rate)
            XCTAssertEqual(budget.numberCharacters, 3)
        }
        budget.observe(publishedTPS: 999.6)
        XCTAssertEqual(StatusItemPresentation.compactTPS(tps: 999.6, active: true), "1000 t/s")
        XCTAssertEqual(budget.numberCharacters, 4)
        for rate in [nil, Double.nan, -1, 0, 50] {
            budget.observe(publishedTPS: rate)
            XCTAssertEqual(budget.numberCharacters, 4)
        }
        budget.observe(publishedTPS: 999_999)
        XCTAssertEqual(budget.numberCharacters, 6)
        budget.observe(publishedTPS: 999_999.6)
        XCTAssertEqual(budget.numberCharacters, 7)
        budget.observe(publishedTPS: .greatestFiniteMagnitude)
        XCTAssertEqual(budget.numberCharacters, 7)
        XCTAssertEqual(
            StatusItemWidthBudget().numberCharacters, 3, "A new app lifetime resets width")
    }

    func testBudgetIgnoresUnpublishedRatesAndSurvivesBackendAndRequestChanges() {
        let store = makeStore(currentTPS: 50, gpuPercent: 42)
        let now = store.sampleDate
        var budget = StatusItemWidthBudget()
        budget.observe(publishedTPS: store.displayTPS)
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: now.addingTimeInterval(0.5), currentTPS: 1_234,
                runningRequests: 1), epoch: store.monitoringEpoch)
        store.sample(at: now.addingTimeInterval(0.5))
        budget.observe(publishedTPS: store.displayTPS)
        XCTAssertEqual(store.currentTPS, 1_234)
        XCTAssertEqual(budget.numberCharacters, 3)
        store.sample(at: now.addingTimeInterval(1))
        budget.observe(publishedTPS: store.displayTPS)
        XCTAssertEqual(budget.numberCharacters, 4)

        store.beginBackendSession(kind: .ollama, epoch: UUID())
        budget.observe(publishedTPS: store.displayTPS)
        let request = GenerationRequest(model: "test", startedAt: now.addingTimeInterval(2))
        store.apply(.began(request))
        budget.observe(publishedTPS: store.displayTPS)
        store.apply(.cancelled(requestID: request.id))
        budget.observe(publishedTPS: store.displayTPS)
        XCTAssertEqual(budget.numberCharacters, 4)
    }

    func testMeasuredLayoutReservesThreeDigitsAndKeepsArtworkAndMeterSpacingCompact() {
        var previousWidth: CGFloat = 0
        for characters in 3...7 {
            let layout = StatusItemPresentation.layout(
                numberCharacters: characters, availableHeight: 22)
            let maximumLabel =
                characters == 7 ? "999999+" : String(repeating: "9", count: characters)
            let measuredNumber = maximumLabel.size(withAttributes: [.font: layout.numberFont])
            XCTAssertEqual(layout.markFrame, NSRect(x: 0, y: 0, width: 24, height: 18))
            XCTAssertEqual(layout.numberFrame.minX - layout.markFrame.maxX, 4)
            XCTAssertGreaterThanOrEqual(layout.numberFrame.width, measuredNumber.width)
            XCTAssertEqual(layout.unitOrigin.x, layout.numberFrame.maxX)
            XCTAssertEqual(layout.throughputFrame.width, 35)
            XCTAssertEqual(layout.gpuFrame.width, 35)
            XCTAssertEqual(layout.throughputFrame.minX, layout.gpuFrame.minX)
            XCTAssertEqual(layout.itemWidth, layout.imageSize.width + 8)
            XCTAssertGreaterThan(layout.imageSize.width, previousWidth)
            previousWidth = layout.imageSize.width
        }
        XCTAssertLessThan(StatusItemPresentation.layout(availableHeight: 22).itemWidth, 140)
        XCTAssertEqual(
            StatusItemPresentation.layout(numberCharacters: 0, availableHeight: 22).imageSize,
            StatusItemPresentation.layout(numberCharacters: 3, availableHeight: 22).imageSize)
        XCTAssertEqual(
            StatusItemPresentation.layout(numberCharacters: Int.max, availableHeight: 22).imageSize,
            StatusItemPresentation.layout(numberCharacters: 7, availableHeight: 22).imageSize)
    }

    func testVisibilityRemovesWholeBlocksAndOnlyKeepsGapsBetweenVisibleGroups() {
        XCTAssertEqual(
            StatusItemVisibility(), StatusItemVisibility(showLogo: true, showTokensPerSecond: true))
        let full = StatusItemPresentation.layout(availableHeight: 22)
        for (_, visibility) in visibilityModes {
            let layout = StatusItemPresentation.layout(availableHeight: 22, visibility: visibility)
            XCTAssertEqual(layout.markFrame.isEmpty, !visibility.showLogo)
            XCTAssertEqual(layout.numberFrame.isEmpty, !visibility.showTokensPerSecond)
            XCTAssertEqual(layout.throughputFrame.width, 35)
            XCTAssertEqual(layout.gpuFrame.width, 35)
            XCTAssertEqual(layout.imageSize.height, full.imageSize.height)
            XCTAssertEqual(layout.itemWidth, layout.imageSize.width + 8)
            if !visibility.showLogo, visibility.showTokensPerSecond {
                XCTAssertEqual(layout.numberFrame.minX, 0)
                XCTAssertEqual(
                    full.imageSize.width - layout.imageSize.width, full.markFrame.width + 4)
            }
            if visibility.showLogo, !visibility.showTokensPerSecond {
                XCTAssertEqual(layout.labelX - layout.markFrame.maxX, 4)
            }
            if !visibility.showLogo, !visibility.showTokensPerSecond {
                XCTAssertEqual(layout.labelX, 0, "Meters-only must not retain a leading gap")
            }
            if !visibility.showTokensPerSecond {
                XCTAssertEqual(layout.unitOrigin, .zero)
                for characters in [3, 4, 6, 7] {
                    XCTAssertEqual(
                        StatusItemPresentation.layout(
                            numberCharacters: characters, availableHeight: 22,
                            visibility: visibility
                        ).imageSize, layout.imageSize,
                        "Hidden numeric fields must not reserve their retained width")
                }
            }
        }
    }

    func testHiddenNumericReadingsDoNotDrawDigitsOrUnitsAtAnyRetainedWidth() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        // Both stores fill the throughput meter completely, so changing only
        // the hidden numeric value and its budget must leave identical artwork.
        let threeDigits = makeStore(currentTPS: 100, gpuPercent: 42)
        let fourDigits = makeStore(currentTPS: 1_000, gpuPercent: 42)
        for showLogo in [false, true] {
            let visibility = StatusItemVisibility(showLogo: showLogo, showTokensPerSecond: false)
            let first = StatusItemPresentation.image(
                store: threeDigits, availableHeight: 22, appearance: appearance,
                numberCharacters: 3, visibility: visibility)
            let second = StatusItemPresentation.image(
                store: fourDigits, availableHeight: 22, appearance: appearance,
                numberCharacters: 7, visibility: visibility)
            XCTAssertEqual(first.size, second.size)
            let firstReps = first.representations.compactMap { $0 as? NSBitmapImageRep }
            let secondReps = second.representations.compactMap { $0 as? NSBitmapImageRep }
            XCTAssertEqual(firstReps.count, 2)
            XCTAssertEqual(secondReps.count, 2)
            for (firstRep, secondRep) in zip(firstReps, secondReps) {
                XCTAssertEqual(
                    try XCTUnwrap(firstRep.representation(using: .png, properties: [:])),
                    try XCTUnwrap(secondRep.representation(using: .png, properties: [:])))
            }
        }
    }

    func testAccessibilityReportsActivityAndKeepsTechnicalDiagnosticsInSettings() {
        let now = Date()
        let store = MetricsStore(clock: { now })
        store.beginBackendSession(kind: .ollama, epoch: UUID())
        store.updateConnection(.ready)
        let request = GenerationRequest(model: "llama3", startedAt: now.addingTimeInterval(-2))
        store.apply(.began(request))
        store.apply(
            .updated(
                requestID: request.id,
                snapshot: GenerationSnapshot(
                    outputTokens: 25, liveTPS: 12.5, elapsed: 2, timestamp: now)))
        store.sample(at: now)
        var summary = StatusItemPresentation.accessibilitySummary(store: store)
        XCTAssertTrue(summary.contains("llama3"))
        XCTAssertTrue(summary.contains("Active"))
        XCTAssertTrue(summary.contains("Approximately 12.5 tokens per second"))
        store.apply(.cancelled(requestID: request.id))
        store.proxyState = .failed
        store.proxyError = "Port is in use"
        store.updateConnection(.unavailable, at: now.addingTimeInterval(6))
        summary = StatusItemPresentation.accessibilitySummary(store: store)
        XCTAssertTrue(summary.contains("Unavailable"))
        XCTAssertTrue(summary.contains("Throughput unavailable"))
        XCTAssertFalse(summary.contains("Port is in use"))
        XCTAssertFalse(summary.contains("Proxy"))
    }

    func testMeterScaleUsesOnlyValidAvailableSamplesFromTheLastMinute() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reading = StatusMeterReading.recentPeak(
            currentValue: 50,
            samples: [
                TimeSeriesPoint(timestamp: now.addingTimeInterval(-60), value: 100),
                TimeSeriesPoint(timestamp: now.addingTimeInterval(-61), value: 1_000),
                TimeSeriesPoint(timestamp: now.addingTimeInterval(1), value: 2_000),
                TimeSeriesPoint(timestamp: now, value: 3_000, isAvailable: false),
                TimeSeriesPoint(timestamp: now, value: .nan),
                TimeSeriesPoint(timestamp: now, value: .infinity),
                TimeSeriesPoint(timestamp: now, value: -10),
            ], now: now)
        XCTAssertEqual(reading.currentValue, 50)
        XCTAssertEqual(reading.scaleMaximum, 100)
        XCTAssertEqual(reading.fillFraction, 0.5)
        let advanced = StatusMeterReading.recentPeak(
            currentValue: 120,
            samples: [TimeSeriesPoint(timestamp: now, value: 100)], now: now)
        XCTAssertEqual(advanced.scaleMaximum, 120)
        XCTAssertEqual(advanced.fillFraction, 1)
    }

    func testMetersKeepUnknownDistinctFromMeasuredZeroAndExpiredPeaks() {
        let now = Date(timeIntervalSince1970: 1_000)
        let history = [TimeSeriesPoint(timestamp: now.addingTimeInterval(-61), value: 100)]
        let zero = StatusMeterReading.recentPeak(currentValue: 0, samples: history, now: now)
        XCTAssertEqual(zero.currentValue, 0)
        XCTAssertEqual(zero.scaleMaximum, 0)
        XCTAssertEqual(zero.fillFraction, 0)
        for invalid in [nil, Double.nan, .infinity, -.infinity, -1] {
            let missing = StatusMeterReading.recentPeak(
                currentValue: invalid, samples: history, now: now)
            XCTAssertNil(missing.currentValue)
            XCTAssertNil(missing.scaleMaximum)
            XCTAssertNil(missing.fillFraction)
        }
        let missingWithHistory = StatusMeterReading.recentPeak(
            currentValue: nil, samples: [TimeSeriesPoint(timestamp: now, value: 20)], now: now)
        XCTAssertEqual(missingWithHistory.scaleMaximum, 20)
        XCTAssertNil(missingWithHistory.fillFraction)
    }

    func testGPUMeterUsesFixedCapacityAndRejectsInvalidPercentages() {
        for value in [0.0, 42, 100] {
            let reading = StatusMeterReading.percentage(value)
            XCTAssertEqual(reading.currentValue, value)
            XCTAssertEqual(reading.scaleMaximum, 100)
            XCTAssertEqual(reading.fillFraction, value / 100)
        }
        for invalid in [nil, Double.nan, .infinity, -.infinity, -1, 100.1, 175] {
            let reading = StatusMeterReading.percentage(invalid)
            XCTAssertNil(reading.currentValue)
            XCTAssertEqual(reading.scaleMaximum, 100)
            XCTAssertNil(reading.fillFraction)
        }
    }

    func testStoreMetersExpireAndDescribeLabelsUnitsAndIndependentScales() {
        let store = makeStore(currentTPS: 50, gpuPercent: 42)
        let readings = StatusItemPresentation.meterReadings(store: store)
        XCTAssertEqual(readings.throughput.currentValue, 50)
        XCTAssertEqual(readings.throughput.scaleMaximum, 100)
        XCTAssertEqual(readings.gpu.currentValue, 42)
        XCTAssertEqual(readings.gpu.scaleMaximum, 100)
        XCTAssertEqual(readings.gpu.fillFraction, 0.42)
        let summary = StatusItemPresentation.accessibilitySummary(store: store)
        XCTAssertTrue(summary.contains("T, top blue meter: token throughput"))
        XCTAssertTrue(summary.contains("G, bottom cyan meter: System GPU"))
        XCTAssertTrue(summary.contains("42.0 percent"))
        XCTAssertTrue(summary.contains("recent 60-second peak"))
        XCTAssertTrue(summary.contains("fixed 0–100 percent scale"))
        XCTAssertTrue(summary.contains("this Mac, including other apps"))
        XCTAssertFalse(summary.contains("milliseconds"))
        XCTAssertTrue(summary.contains("Combined utilization is normalized"))
        store.sample(at: store.sampleDate.addingTimeInterval(6))
        let stale = StatusItemPresentation.meterReadings(store: store)
        XCTAssertNil(stale.throughput.currentValue)
        XCTAssertNil(stale.gpu.currentValue)
        XCTAssertEqual(stale.throughput.scaleMaximum, 100)
        XCTAssertEqual(stale.gpu.scaleMaximum, 100)
    }

    func testThroughputMeterHoldsBothValueAndPeakBetweenDisplayPublications() {
        let store = makeStore(currentTPS: 50, gpuPercent: 42)
        let now = store.sampleDate
        let reading = StatusItemPresentation.meterReadings(store: store).throughput
        store.applyBackendSample(
            BackendSample(
                kind: .vllm, timestamp: now.addingTimeInterval(0.5), currentTPS: 200,
                runningRequests: 1), epoch: store.monitoringEpoch)
        store.sample(at: now.addingTimeInterval(0.5))
        XCTAssertEqual(store.currentTPS, 200)
        XCTAssertEqual(StatusItemPresentation.meterReadings(store: store).throughput, reading)
        store.sample(at: now.addingTimeInterval(1))
        let published = StatusItemPresentation.meterReadings(store: store).throughput
        XCTAssertEqual(published.currentValue, 200)
        XCTAssertEqual(published.scaleMaximum, 200)
    }

    func testProcessExecutionTimeNeverAppearsAsSystemGPUUtilization() {
        let store = MetricsStore()
        let epoch = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.beginBackendSession(kind: .ollama, epoch: epoch)
        store.applyGPUSample(
            GPUActivitySample(timestamp: now, activityPercent: 88, processIDs: [1234]),
            epoch: epoch)
        store.sample(at: now)
        XCTAssertNil(StatusItemPresentation.meterReadings(store: store).gpu.currentValue)
        XCTAssertTrue(
            StatusItemPresentation.accessibilitySummary(store: store)
                .contains("System GPU, unavailable"))
    }

    func testMetersRenderBrandColorsAndFullTracksInEveryAppearanceAndAvailabilityState() throws {
        for (name, appearanceName, highlighted) in [
            ("light", NSAppearance.Name.aqua, false),
            ("dark", .darkAqua, false),
            ("highlighted", .aqua, true),
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for (mode, visibility) in visibilityModes {
                for (state, store) in [
                    ("active", makeStore(currentTPS: 50, gpuPercent: 42)),
                    ("zero", makeStore(currentTPS: 0, gpuPercent: 0)),
                    ("unavailable", MetricsStore()),
                ] {
                    let image = StatusItemPresentation.image(
                        store: store, availableHeight: 22, appearance: appearance,
                        isHighlighted: highlighted, visibility: visibility)
                    let layout = StatusItemPresentation.layout(
                        availableHeight: 22, visibility: visibility)
                    XCTAssertEqual(image.size, layout.imageSize)
                    XCTAssertEqual(
                        image.accessibilityDescription,
                        StatusItemPresentation.accessibilitySummary(store: store))
                    let representations = image.representations.compactMap {
                        $0 as? NSBitmapImageRep
                    }
                    XCTAssertEqual(
                        Set(representations.map(\.pixelsWide)),
                        [Int(image.size.width), Int(image.size.width) * 2])
                    for representation in representations {
                        let scale = representation.pixelsWide / Int(layout.imageSize.width)
                        // The gap between the value and meters belongs to the
                        // system menu bar. Production artwork must leave it clear.
                        if layout.labelX > 0 {
                            for y in 0..<representation.pixelsHigh {
                                XCTAssertEqual(
                                    representation.colorAt(x: Int(layout.labelX - 2) * scale, y: y)?
                                        .alphaComponent,
                                    0)
                            }
                        }
                        assertMetricLabelsVisible(representation, scale: scale, layout: layout)
                        let counts = meterPixelCounts(representation, scale: scale, layout: layout)
                        if state == "active" {
                            XCTAssertGreaterThan(
                                counts.blue, 0, "Top meter must retain FluxLLM blue")
                            XCTAssertGreaterThan(
                                counts.cyan, 0, "Bottom meter must retain FluxLLM cyan")
                        } else {
                            XCTAssertEqual(counts.blue, 0)
                            XCTAssertEqual(counts.cyan, 0)
                        }
                        if state != "unavailable" {
                            XCTAssertGreaterThan(counts.opaque, 250 * scale * scale)
                        }
                        // Every state keeps two uninterrupted, full-width rails.
                        // A missing reading is visibly subdued, never a fake zero.
                        for frame in [layout.throughputFrame, layout.gpuFrame] {
                            let row = Int(layout.imageSize.height - frame.midY)
                            for x in Int(frame.minX + 2)..<Int(frame.maxX - 2) {
                                let alpha =
                                    representation.colorAt(x: x * scale, y: row * scale)?
                                    .alphaComponent ?? 0
                                if state == "unavailable" {
                                    XCTAssertEqual(alpha, 0.42, accuracy: 0.015)
                                } else {
                                    XCTAssertGreaterThan(alpha, 0.95)
                                }
                            }
                        }
                        try renderIfRequested(
                            representation,
                            named: "status-meters\(mode)-\(state)-\(name)-\(scale)x",
                            style: highlighted || name == "dark" ? .dark : .light,
                            highlighted: highlighted)
                    }
                }
            }
        }
    }

    private var visibilityModes: [(String, StatusItemVisibility)] {
        [
            ("", StatusItemVisibility()),
            ("-no-logo", StatusItemVisibility(showLogo: false)),
            ("-no-number", StatusItemVisibility(showTokensPerSecond: false)),
            ("-only", StatusItemVisibility(showLogo: false, showTokensPerSecond: false)),
        ]
    }

    func testAdaptiveWidthsRenderUnclippedAtNativeScalesAndRetainWidthWhenUnknown() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        var budget = StatusItemWidthBudget()
        for (name, rate) in [
            ("2-digits", 50.0), ("3-digits", 999.0), ("4-digits", 1_000.0),
            ("6-digits", 123_456.0), ("capped", Double.greatestFiniteMagnitude),
        ] {
            budget.observe(publishedTPS: rate)
            let store = makeStore(currentTPS: rate, gpuPercent: 42)
            let layout = StatusItemPresentation.layout(
                numberCharacters: budget.numberCharacters, availableHeight: 22)
            for (state, renderedStore) in [(name, store), ("\(name)-unknown", MetricsStore())] {
                let image = StatusItemPresentation.image(
                    store: renderedStore, availableHeight: 22, appearance: appearance,
                    numberCharacters: budget.numberCharacters)
                let highlighted = StatusItemPresentation.image(
                    store: renderedStore, availableHeight: 22, appearance: appearance,
                    isHighlighted: true, numberCharacters: budget.numberCharacters)
                XCTAssertEqual(image.size, layout.imageSize)
                XCTAssertEqual(highlighted.size, layout.imageSize)
                for representation in image.representations.compactMap({ $0 as? NSBitmapImageRep })
                {
                    let scale = representation.pixelsWide / Int(image.size.width)
                    XCTAssertTrue([1, 2].contains(scale))
                    assertMetricLabelsVisible(representation, scale: scale, layout: layout)
                    for y in 0..<representation.pixelsHigh {
                        XCTAssertEqual(
                            representation.colorAt(x: representation.pixelsWide - 1, y: y)?
                                .alphaComponent,
                            0, "The trailing edge must not clip the meter")
                    }
                    try renderIfRequested(
                        representation, named: "status-adaptive-\(state)-\(scale)x",
                        style: .light, highlighted: false)
                }
            }
        }
    }

    private func assertMetricLabelsVisible(
        _ representation: NSBitmapImageRep, scale: Int, layout: StatusItemLayout
    ) {
        for row in [0..<9, 9..<18] {
            var labelPixels = 0
            for y in (row.lowerBound * scale)..<(row.upperBound * scale) {
                for x
                    in (Int(layout.labelX) * scale)..<(Int(layout.throughputFrame.minX - 2) * scale)
                {
                    if let color = representation.colorAt(x: x, y: y),
                        color.alphaComponent > 0.7
                    {
                        labelPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(labelPixels, 5 * scale * scale, "T and G must each remain legible")
        }
    }

    private func makeStore(currentTPS: Double, gpuPercent: Double) -> MetricsStore {
        let store = MetricsStore()
        let epoch = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.beginBackendSession(kind: .vllm, epoch: epoch)
        for (date, rate, gpu) in [
            (now.addingTimeInterval(-1), 100.0, 80.0), (now, currentTPS, gpuPercent),
        ] {
            store.applyBackendSample(
                BackendSample(kind: .vllm, timestamp: date, currentTPS: rate, runningRequests: 1),
                epoch: epoch)
            store.applyGPUSample(
                GPUActivitySample(
                    timestamp: date, activityPercent: gpu, processIDs: [],
                    source: "macOS GPU device utilization", scope: .system),
                epoch: epoch)
            store.sample(at: date)
        }
        return store
    }

    private func meterPixelCounts(
        _ representation: NSBitmapImageRep, scale: Int, layout: StatusItemLayout
    ) -> (
        blue: Int, cyan: Int, opaque: Int
    ) {
        var blue = 0
        var cyan = 0
        var opaque = 0
        for y in 0..<representation.pixelsHigh {
            for x
                in (Int(layout.throughputFrame.minX) * scale)..<(Int(layout.throughputFrame.maxX)
                * scale)
            {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    color.alphaComponent > 0.95
                else { continue }
                opaque += 1
                if abs(color.redComponent - 7 / 255) < 0.04,
                    abs(color.greenComponent - 93 / 255) < 0.04,
                    abs(color.blueComponent - 254 / 255) < 0.04
                {
                    blue += 1
                }
                if abs(color.redComponent - 4 / 255) < 0.04,
                    abs(color.greenComponent - 201 / 255) < 0.04,
                    abs(color.blueComponent - 229 / 255) < 0.04
                {
                    cyan += 1
                }
            }
        }
        return (blue, cyan, opaque)
    }

    private func renderIfRequested(
        _ representation: NSBitmapImageRep, named name: String, style: StatusMarkAppearance,
        highlighted: Bool
    ) throws {
        guard ProcessInfo.processInfo.environment["FLUXLLM_RENDER_PREVIEWS"] == "1" else { return }
        let directory = URL(fileURLWithPath: "/private/tmp/fluxllm-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transparent = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try transparent.write(to: directory.appendingPathComponent("\(name)-transparent.png"))

        let neutral =
            highlighted
            ? NSColor(srgbRed: 0.15, green: 0.39, blue: 0.76, alpha: 1)
            : NSColor(calibratedWhite: style == .light ? 0.92 : 0.13, alpha: 1)
        let warm =
            style == .light
            ? NSColor(srgbRed: 237 / 255, green: 217 / 255, blue: 189 / 255, alpha: 1)
            : NSColor(srgbRed: 73 / 255, green: 56 / 255, blue: 45 / 255, alpha: 1)
        let blue =
            style == .light
            ? NSColor(srgbRed: 191 / 255, green: 215 / 255, blue: 244 / 255, alpha: 1)
            : NSColor(srgbRed: 22 / 255, green: 60 / 255, blue: 98 / 255, alpha: 1)
        let imageWidth = Int(representation.size.width)
        let itemWidth = imageWidth + 8
        let scale = representation.pixelsWide / imageWidth
        let artwork = try XCTUnwrap(representation.cgImage)
        for (suffix, background) in [("", neutral), ("-warm", warm), ("-blue", blue)] {
            let preview = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: itemWidth * scale, pixelsHigh: 26 * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: preview)).cgContext
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: itemWidth, height: 26))
            // NSImageRep.draw(in:) can copy the transparent source pixels over
            // the background. Explicit source-over preserves the review surface.
            context.setBlendMode(.normal)
            context.draw(artwork, in: CGRect(x: 4, y: 4, width: imageWidth, height: 18))
            preview.size = NSSize(width: itemWidth, height: 26)
            for y in 0..<preview.pixelsHigh {
                for x in 0..<preview.pixelsWide {
                    XCTAssertEqual(
                        preview.colorAt(x: x, y: y)?.alphaComponent, 1,
                        "Native preview surfaces must composite to opaque pixels")
                }
            }
            let data = try XCTUnwrap(preview.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(name)\(suffix).png"))
        }
    }

    func testSparklineUsesElapsedTimeRatherThanSampleIndex() {
        let now = Date(timeIntervalSince1970: 1_000)
        let points = SparklineGeometry.normalizedPoints(
            samples: [
                TimeSeriesPoint(timestamp: now, value: 20),
                TimeSeriesPoint(timestamp: now.addingTimeInterval(-60), value: 0),
                TimeSeriesPoint(timestamp: now.addingTimeInterval(-15), value: 10),
            ], now: now)
        XCTAssertEqual(points.count, 3)
        guard points.count == 3 else { return }
        XCTAssertEqual(points[0].x, 0, accuracy: 0.0001)
        XCTAssertEqual(points[1].x, 0.75, accuracy: 0.0001)
        XCTAssertEqual(points[2].x, 1, accuracy: 0.0001)
        XCTAssertEqual(points[1].y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(points[2].y, 1, accuracy: 0.0001)
    }

    func testSparklineDropsExpiredFutureAndNonfiniteSamples() {
        let now = Date(timeIntervalSince1970: 1_000)
        let points = SparklineGeometry.normalizedPoints(
            samples: [
                TimeSeriesPoint(timestamp: now.addingTimeInterval(-61), value: 10),
                TimeSeriesPoint(timestamp: now.addingTimeInterval(1), value: 10),
                TimeSeriesPoint(timestamp: now, value: .nan),
                TimeSeriesPoint(timestamp: now, value: .infinity),
                TimeSeriesPoint(timestamp: now.addingTimeInterval(-1), value: -3),
            ], now: now)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.y, 0)
    }
}
