import AppKit

/// A meter with an explicit scale: a recent throughput peak or GPU capacity.
struct StatusMeterReading: Equatable {
    let currentValue: Double?
    let scaleMaximum: Double?

    var fillFraction: Double? {
        guard let currentValue else { return nil }
        guard let scaleMaximum, scaleMaximum > 0 else { return 0 }
        return min(currentValue / scaleMaximum, 1)
    }

    static func recentPeak(
        currentValue: Double?, samples: [TimeSeriesPoint], now: Date
    ) -> Self {
        let cutoff = now.addingTimeInterval(-60)
        var peak: Double?
        for sample in samples {
            guard sample.isAvailable, sample.timestamp >= cutoff, sample.timestamp <= now,
                let value = valid(sample.value)
            else { continue }
            peak = max(peak ?? 0, value)
        }
        return recentPeak(currentValue: currentValue, sampledPeak: peak)
    }

    static func recentPeak(currentValue: Double?, sampledPeak: Double?) -> Self {
        let current = valid(currentValue)
        let history = valid(sampledPeak)
        let peak = history.map { max($0, current ?? 0) } ?? current
        return Self(currentValue: current, scaleMaximum: peak)
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func percentage(_ value: Double?) -> Self {
        guard let value, value.isFinite, (0...100).contains(value) else {
            return Self(currentValue: nil, scaleMaximum: 100)
        }
        return Self(currentValue: value, scaleMaximum: 100)
    }
}

/// The controller retains this budget for its lifetime, across requests and backends.
struct StatusItemWidthBudget: Equatable {
    private(set) var numberCharacters = 3

    mutating func observe(publishedTPS: Double?) {
        guard let publishedTPS,
            let number = StatusItemPresentation.formattedNumber(publishedTPS)
        else { return }
        numberCharacters = max(numberCharacters, number.count)
    }
}

/// Independent display preferences; the labeled T/G meters always remain visible.
struct StatusItemVisibility: Equatable {
    var showLogo = true
    var showTokensPerSecond = true
}

/// Every image representation and the native status item share these measured bounds.
struct StatusItemLayout {
    let imageSize: NSSize
    let itemWidth: CGFloat
    let markFrame: NSRect
    let numberFrame: NSRect
    let unitOrigin: CGPoint
    let labelX: CGFloat
    let throughputFrame: NSRect
    let gpuFrame: NSRect
    let numberFont: NSFont
    let labelFont: NSFont
}

/// Formatting and layout are independent of the status item's lifetime.
enum StatusItemPresentation {
    struct Snapshot: Equatable {
        let number: String
        let throughput: StatusMeterReading
        let gpu: StatusMeterReading
        let accessibilitySummary: String
    }

    @MainActor
    static func snapshot(store: MetricsStore) -> Snapshot {
        let meters = meterReadings(store: store)
        return Snapshot(
            number: store.displayTPS.flatMap(formattedNumber) ?? "—",
            throughput: meters.throughput, gpu: meters.gpu,
            accessibilitySummary: accessibilitySummary(store: store, meters: meters))
    }

    static func formattedNumber(_ rate: Double) -> String? {
        guard rate.isFinite, rate >= 0 else { return nil }
        let rounded = rate.rounded()
        guard rounded <= 999_999 else { return "999999+" }
        return String(format: "%.0f", max(0, rounded))
    }

    static func compactTPS(tps: Double, active: Bool) -> String {
        guard active, let number = formattedNumber(tps) else { return "— t/s" }
        return "\(number) t/s"
    }

    @MainActor
    static func layout(
        numberCharacters: Int = 3, availableHeight: CGFloat,
        visibility: StatusItemVisibility = StatusItemVisibility()
    ) -> StatusItemLayout {
        let height = imageHeight(availableHeight: availableHeight)
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: max(1, min(height - 1, 11.5)), weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let characters = min(max(numberCharacters, 3), 7)
        let reservedNumber =
            String(repeating: "8", count: min(characters, 6))
            + (characters == 7 ? "+" : "")
        let numberSize = reservedNumber.size(withAttributes: attributes)
        let unitSize = " t/s".size(withAttributes: attributes)
        let markScale = min(height / BrandingAssets.statusMarkSize.height, 1)
        let markSize = NSSize(
            width: BrandingAssets.statusMarkSize.width * markScale,
            height: BrandingAssets.statusMarkSize.height * markScale)
        var contentX: CGFloat = 0
        let markFrame: NSRect
        if visibility.showLogo {
            markFrame = NSRect(
                x: 0, y: (height - markSize.height) / 2,
                width: markSize.width, height: markSize.height)
            contentX = markFrame.maxX
        } else {
            markFrame = .zero
        }
        let numberFrame: NSRect
        let unitOrigin: CGPoint
        if visibility.showTokensPerSecond {
            numberFrame = NSRect(
                x: contentX + (visibility.showLogo ? 4 : 0),
                y: (height - numberSize.height) / 2,
                width: ceil(numberSize.width), height: numberSize.height)
            unitOrigin = CGPoint(x: numberFrame.maxX, y: numberFrame.minY)
            contentX = ceil(unitOrigin.x + unitSize.width)
        } else {
            numberFrame = .zero
            unitOrigin = .zero
        }
        let labelFont = NSFont.systemFont(
            ofSize: min(8, max(height / 2 - 1, 1)), weight: .bold)
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: labelFont]
        let labelWidth = ceil(
            max(
                "T".size(withAttributes: labelAttributes).width,
                "G".size(withAttributes: labelAttributes).width))
        let labelX = contentX + (visibility.showLogo || visibility.showTokensPerSecond ? 4 : 0)
        let meterX = labelX + labelWidth + 3
        let meterHeight = min(5, max((height - 4) / 2, 0.5))
        let gap = min(4, max(height - meterHeight * 2, 0))
        let bottom = (height - meterHeight * 2 - gap) / 2
        let throughputFrame = NSRect(
            x: meterX, y: bottom + meterHeight + gap, width: 35, height: meterHeight)
        let gpuFrame = NSRect(x: meterX, y: bottom, width: 35, height: meterHeight)
        let imageWidth = ceil(throughputFrame.maxX + 1)
        return StatusItemLayout(
            imageSize: NSSize(width: imageWidth, height: height), itemWidth: imageWidth + 8,
            markFrame: markFrame, numberFrame: numberFrame, unitOrigin: unitOrigin,
            labelX: labelX, throughputFrame: throughputFrame, gpuFrame: gpuFrame,
            numberFont: font, labelFont: labelFont)
    }

    @MainActor
    static func accessibilitySummary(store: MetricsStore) -> String {
        accessibilitySummary(store: store, meters: meterReadings(store: store))
    }

    @MainActor
    private static func accessibilitySummary(
        store: MetricsStore, meters: (throughput: StatusMeterReading, gpu: StatusMeterReading)
    ) -> String {
        let status = MenuBarExtraView.statusLine(store: store)
        let backend = store.backendKind?.title ?? "LLM monitor"
        let throughput: String
        if let rate = store.displayTPS {
            throughput = String(
                format: "%@%.1f tokens per second",
                store.displayRateIsEstimated
                    ? "Approximately " : "",
                rate)
        } else {
            throughput = "Throughput unavailable"
        }
        let model = store.currentModel.map { ". \($0)" } ?? ""
        let throughputMeter = throughputMeterSummary(meters.throughput)
        let gpuMeter =
            meters.gpu.currentValue.map { String(format: "%.1f percent", $0) }
            ?? "unavailable"
        return "\(backend). \(status). \(throughput)\(model). "
            + "T, top blue meter: token throughput, \(throughputMeter). "
            + "Throughput scales to its recent 60-second peak. "
            + "G, bottom cyan meter: System GPU, \(gpuMeter), on a fixed 0–100 percent scale. "
            + "System GPU measures this Mac, including other apps. "
            + "Combined utilization is normalized across this Mac’s GPUs."
    }

    @MainActor
    static func meterReadings(store: MetricsStore) -> (
        throughput: StatusMeterReading, gpu: StatusMeterReading
    ) {
        let now = store.displayUpdatedAt ?? store.sampleDate
        let throughput = StatusMeterReading.recentPeak(
            currentValue: store.displayTPS,
            sampledPeak: store.peakThroughput(
                in: DateInterval(start: now.addingTimeInterval(-60), end: now)))
        let gpu = StatusMeterReading.percentage(store.systemGPUUtilizationPercent)
        return (throughput, gpu)
    }

    private static func throughputMeterSummary(_ reading: StatusMeterReading) -> String {
        guard let value = reading.currentValue else { return "unavailable" }
        return String(
            format: "%.1f tokens per second, recent peak %.1f tokens per second",
            value, reading.scaleMaximum ?? 0)
    }

    @MainActor
    static func image(
        store: MetricsStore,
        availableHeight: CGFloat,
        appearance: NSAppearance,
        isHighlighted: Bool = false,
        numberCharacters: Int = 3,
        visibility: StatusItemVisibility = StatusItemVisibility()
    ) -> NSImage {
        let snapshot = snapshot(store: store)
        let layout = layout(
            numberCharacters: max(numberCharacters, snapshot.number.count),
            availableHeight: availableHeight,
            visibility: visibility)
        let style = StatusMarkAppearance.resolve(
            appearance: appearance, isHighlighted: isHighlighted)
        return image(snapshot: snapshot, layout: layout, style: style)
    }

    @MainActor
    static func image(snapshot: Snapshot, layout: StatusItemLayout, style: StatusMarkAppearance)
        -> NSImage
    {
        let size = layout.imageSize
        let image = NSImage(size: size)

        // Explicit representations keep the text, meters, and approved artwork
        // sharp on both display scales, regardless of the current main screen.
        for scale in [1, 2] {
            guard
                let representation = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(size.width) * scale,
                    pixelsHigh: Int(size.height) * scale,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: representation)
            else { continue }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.cgContext.clear(CGRect(origin: .zero, size: size))
            drawContents(
                number: snapshot.number, throughput: snapshot.throughput, gpu: snapshot.gpu,
                layout: layout, style: style)
            NSGraphicsContext.restoreGraphicsState()

            representation.size = size
            image.addRepresentation(representation)
        }
        image.isTemplate = false
        image.accessibilityDescription = snapshot.accessibilitySummary
        return image
    }

    static func imageHeight(availableHeight: CGFloat) -> CGFloat {
        let menuHeight = availableHeight.isFinite ? availableHeight : 22
        return max(1, min(18, floor(menuHeight - 4)))
    }

    @MainActor
    private static func drawContents(
        number: String, throughput: StatusMeterReading, gpu: StatusMeterReading,
        layout: StatusItemLayout, style: StatusMarkAppearance
    ) {
        if !layout.markFrame.isEmpty {
            BrandingAssets.statusMark(for: style)?.draw(in: layout.markFrame)
        }

        let foreground = style.foregroundColor
        foreground.setStroke()
        if !layout.numberFrame.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: layout.numberFont,
                .foregroundColor: foreground,
            ]
            let numberSize = number.size(withAttributes: attributes)
            number.draw(
                at: CGPoint(
                    x: layout.numberFrame.maxX - numberSize.width, y: layout.numberFrame.minY),
                withAttributes: attributes)
            " t/s".draw(at: layout.unitOrigin, withAttributes: attributes)
        }

        // Keep a compact, stable gap from the changing number to the T/G
        // labels. Two continuous bars read as aggregate metrics, not GPU cores.
        drawMeterLabel(
            "T", centeredAt: layout.throughputFrame.midY, layout: layout, color: foreground)
        drawMeterLabel("G", centeredAt: layout.gpuFrame.midY, layout: layout, color: foreground)
        drawMeter(
            throughput, frame: layout.throughputFrame,
            fill: NSColor(srgbRed: 7 / 255, green: 93 / 255, blue: 254 / 255, alpha: 1),
            style: style)
        drawMeter(
            gpu, frame: layout.gpuFrame,
            fill: NSColor(srgbRed: 4 / 255, green: 201 / 255, blue: 229 / 255, alpha: 1),
            style: style)
    }

    @MainActor
    private static func drawMeterLabel(
        _ label: String, centeredAt centerY: CGFloat, layout: StatusItemLayout, color: NSColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: layout.labelFont,
            .foregroundColor: color,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(x: layout.labelX, y: centerY - size.height / 2), withAttributes: attributes)
    }

    @MainActor
    private static func drawMeter(
        _ reading: StatusMeterReading, frame: NSRect, fill: NSColor, style: StatusMarkAppearance
    ) {
        let track =
            style == .light
            ? NSColor(srgbRed: 21 / 255, green: 35 / 255, blue: 55 / 255, alpha: 1)
            : NSColor(calibratedWhite: 0.3, alpha: 1)
        let fraction = reading.fillFraction
        let radius = frame.height / 2
        // A missing reading keeps the same full-width rail as a measured zero,
        // with lower opacity so availability remains truthful without a dash.
        track.withAlphaComponent(fraction == nil ? 0.42 : 1).setFill()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
        guard let fraction, fraction > 0 else { return }
        let filled = NSRect(
            x: frame.minX, y: frame.minY, width: frame.width * fraction, height: frame.height)
        fill.setFill()
        NSBezierPath(
            roundedRect: filled, xRadius: min(radius, filled.width / 2), yRadius: radius
        ).fill()
    }
}
