import AppKit
import CoreText
import Observation
import SwiftUI

/// Opt-in usage values use fixed native fields; the badge stays SwiftUI.
/// Usage observation belongs to this bounded coordinator, never the surrounding
/// details/grid body. All reads and publications use the existing scalar cadence.
@MainActor
final class DashboardRetainedUsageCoordinator {
    enum Field: String, CaseIterable, Sendable {
        case input, output, tools, requests, badge
    }

    struct Display: Equatable, Sendable {
        let value: String
        let help: String
    }

    @Observable
    @MainActor
    final class InputHelp {
        var text = "Input tokens reported by the backend."
    }

    let inputHelp = InputHelp()

    private struct Sink {
        let token: UUID
        let apply: (Display) -> Void
    }

    private weak var store: MetricsStore?
    private weak var presentation: DashboardPresentationState?
    private let instrumented: Bool
    private var sinks: [Field: Sink] = [:]
    private var displays: [Field: Display] = [:]
    private(set) var appliedUsage: UsageSummary?
    private(set) var appliedScope: UsageScope?
    private var epoch: UUID?
    private var generation: UInt64 = 0
    private var refreshPending = false
    private(set) var isStopped = false

    init(store: MetricsStore, presentation: DashboardPresentationState) {
        // In particular, do not read usage while a SwiftUI body constructs this
        // object: nested observation tracking could enroll the enclosing body.
        self.store = store
        self.presentation = presentation
        instrumented =
            PerformanceGraphicsDiagnostics.shared.isEnabled
            && PerformanceGraphicsDiagnostics.shared.mode.usesRetainedUsageFields
    }

    @discardableResult
    func register(_ field: Field, token: UUID, apply: @escaping (Display) -> Void) -> Bool {
        guard !isStopped, let presentation, presentation.isActive else { return false }
        if let old = sinks[field] {
            if old.token == token { return true }
            // SwiftUI may make a replacement before dismantling the old native
            // view. Retire its token first; a subsequent old-token disconnect
            // must not remove the replacement's registration.
            sinks.removeValue(forKey: field)
            if instrumented {
                PerformanceGraphicsDiagnostics.shared.retainedUsageHostDestroyed(
                    owner: presentation.scalarPerformanceOwnerID, field: field.rawValue)
            }
        }
        if instrumented {
            guard
                PerformanceGraphicsDiagnostics.shared.retainedUsageHostCreated(
                    owner: presentation.scalarPerformanceOwnerID, field: field.rawValue)
            else { return false }
        }
        sinks[field] = Sink(token: token, apply: apply)
        if let display = displays[field] { apply(display) }
        scheduleRefresh()
        return true
    }

    func unregister(_ field: Field, token: UUID) {
        guard let sink = sinks[field], sink.token == token else { return }
        sinks.removeValue(forKey: field)
        if instrumented, let presentation {
            PerformanceGraphicsDiagnostics.shared.retainedUsageHostDestroyed(
                owner: presentation.scalarPerformanceOwnerID, field: field.rawValue)
        }
        if sinks.isEmpty { stop() }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        generation &+= 1
        refreshPending = false
        if instrumented, let presentation {
            for field in sinks.keys {
                PerformanceGraphicsDiagnostics.shared.retainedUsageHostDestroyed(
                    owner: presentation.scalarPerformanceOwnerID, field: field.rawValue)
            }
        }
        sinks.removeAll(keepingCapacity: false)
        displays.removeAll(keepingCapacity: false)
        appliedUsage = nil
        appliedScope = nil
    }

    /// Called after the existing frame-anchor callback admits a live owner.
    /// It only republishes native fields already applied; it reads no telemetry.
    func publishAppliedPresentation() {
        guard instrumented, !isStopped, let presentation, presentation.isActive,
            DashboardHeldUsage.requiredFrames.isSubset(
                of: Set(presentation.scalarPerformanceFrames.keys)),
            sinks.count == Field.allCases.count, displays.count == Field.allCases.count,
            let epoch, let usage = appliedUsage, let scope = appliedScope
        else { return }
        let fields = Dictionary(
            uniqueKeysWithValues: displays.map {
                ($0.key.rawValue, ["value": $0.value.value, "help": $0.value.help])
            })
        PerformanceGraphicsDiagnostics.shared.retainedUsagePresentationApplied(
            owner: presentation.scalarPerformanceOwnerID, epoch: epoch,
            scope: scope, usage: usage, fields: fields)
    }

    private func scheduleRefresh() {
        guard !isStopped, !refreshPending else { return }
        refreshPending = true
        let expected = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped, self.generation == expected else { return }
            self.refreshPending = false
            self.refresh()
        }
    }

    private func refresh() {
        guard let store, let presentation, presentation.isActive
        else {
            stop()
            return
        }
        if instrumented,
            !PerformanceGraphicsDiagnostics.shared.isEnabled
                || !PerformanceGraphicsDiagnostics.shared.mode.usesRetainedUsageFields
        {
            stop()
            return
        }
        if let epoch, epoch != store.monitoringEpoch {
            stop()
            return
        }
        let next = withObservationTracking {
            (
                store.liveScalars.usage, store.usageScope, store.monitoringEpoch,
                store.liveScalars.backendKind
            )
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.scheduleRefresh() }
        }
        guard next.3 == .ollama else {
            stop()
            return
        }
        epoch = next.2
        let previous = appliedUsage
        let projected = Self.project(next.0, previous: previous, displays: displays)
        for field in Field.allCases {
            guard let display = projected[field], let sink = sinks[field] else { continue }
            sink.apply(display)
        }
        displays = projected
        if let help = projected[.input]?.help, inputHelp.text != help { inputHelp.text = help }
        appliedUsage = next.0
        appliedScope = next.1
        publishAppliedPresentation()
    }

    /// Format only fields whose display inputs changed, after a coalesced
    /// publication. No request-history queries or per-stream-chunk work occurs.
    static func project(
        _ usage: UsageSummary, previous: UsageSummary?, displays: [Field: Display]
    ) -> [Field: Display] {
        var result = displays
        if previous?.inputTokens != usage.inputTokens
            || previous?.unknownInputRequests != usage.unknownInputRequests || result[.input] == nil
        {
            let value =
                usage.inputTokens.map {
                    $0.formatted() + (usage.unknownInputRequests > 0 ? "+" : "")
                } ?? "—"
            let help =
                usage.unknownInputRequests > 0
                ? "Input usage is unavailable for \(usage.unknownInputRequests) requests. A + marks the known subtotal."
                : "Input tokens reported by the backend."
            result[.input] = Display(value: value, help: help)
        }
        if previous?.outputTokens != usage.outputTokens
            || previous?.outputIsEstimated != usage.outputIsEstimated || result[.output] == nil
        {
            result[.output] = Display(
                value: (usage.outputIsEstimated ? "~" : "") + usage.outputTokens.formatted(),
                help: "")
        }
        if previous?.toolCalls != usage.toolCalls || result[.tools] == nil {
            result[.tools] = Display(
                value: usage.toolCalls.formatted(),
                help:
                    "Observed calls, excluding submitted results; this does not measure execution success."
            )
        }
        if previous?.requests != usage.requests || result[.requests] == nil {
            result[.requests] = Display(value: usage.requests.formatted(), help: "")
        }
        if previous?.isPartial != usage.isPartial
            || previous?.activeRequests != usage.activeRequests || result[.badge] == nil
        {
            let value =
                usage.isPartial
                ? "Partial history"
                : (usage.activeRequests > 0 ? "\(usage.activeRequests) active" : "")
            result[.badge] = Display(value: value, help: "")
        }
        return result
    }
}

struct DashboardRetainedUsageField: NSViewRepresentable {
    let coordinator: DashboardRetainedUsageCoordinator
    let field: DashboardRetainedUsageCoordinator.Field
    let density: DashboardHeightPolicy
    let colorScheme: ColorScheme
    var logicalFrame: CGRect? = nil

    func makeNSView(context: Context) -> DashboardRetainedUsageHost {
        let host = DashboardRetainedUsageHost(
            field: field, density: density, colorScheme: colorScheme)
        host.configure(density: density, colorScheme: colorScheme, environment: context.environment)
        host.setLogicalFrame(logicalFrame)
        host.connect(to: coordinator)
        return host
    }

    func updateNSView(_ host: DashboardRetainedUsageHost, context: Context) {
        host.recordRepresentableUpdate()
        host.configure(density: density, colorScheme: colorScheme, environment: context.environment)
        host.setLogicalFrame(logicalFrame)
        host.connect(to: coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView host: DashboardRetainedUsageHost, context: Context
    ) -> CGSize? {
        if field == .badge { return host.intrinsicContentSize }
        return CGSize(width: max(0, proposal.width ?? 0), height: host.fixedFieldHeight)
    }

    static func dismantleNSView(_ host: DashboardRetainedUsageHost, coordinator: ()) {
        host.disconnect()
    }
}

/// The cell's intrinsic footprint never depends on its value text. The badge
/// retains the original intrinsic width, changing it only at badge boundaries.
@MainActor
final class DashboardRetainedUsageHost: NSView {
    @Observable
    @MainActor
    final class Value {
        var text = ""
        var help = ""
    }

    let field: DashboardRetainedUsageCoordinator.Field
    private let token = UUID()
    private weak var coordinator: DashboardRetainedUsageCoordinator?
    private var density: DashboardHeightPolicy
    private var colorScheme: ColorScheme
    private var environment: EnvironmentValues?
    private var environmentKey: TextEnvironment?
    private let hosting: NSHostingView<AnyView>?
    private let nativeText: FixedUsageTextField?
    private let value = Value()
    private(set) var appliedDisplay: DashboardRetainedUsageCoordinator.Display?
    private(set) var representableUpdates: UInt64 = 0
    private(set) var intrinsicNotifications: UInt64 = 0
    private(set) var intrinsicQueries: UInt64 = 0
    var fixedFieldHeight: CGFloat { density.value(21, 18) }
    var nativeValueField: NSTextField? { nativeText }

    func setLogicalFrame(_ frame: CGRect?) { nativeText?.setLogicalFrame(frame) }

    init(
        field: DashboardRetainedUsageCoordinator.Field, density: DashboardHeightPolicy,
        colorScheme: ColorScheme
    ) {
        self.field = field
        self.density = density
        self.colorScheme = colorScheme
        hosting = field == .badge ? NSHostingView(rootView: AnyView(EmptyView())) : nil
        nativeText = field == .badge ? nil : FixedUsageTextField(frame: .zero)
        super.init(frame: .zero)
        hosting?.sizingOptions = [.intrinsicContentSize]
        // A fixed cell is a layout boundary. Child text layout must not dirty
        // the enclosing dashboard's Auto Layout constraint graph.
        let child = hosting.map { $0 as NSView } ?? nativeText!
        child.autoresizingMask = [.width, .height]
        addSubview(child)
        configureRoot()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        if let hosting, hosting.frame != bounds { hosting.frame = bounds }
        if let nativeText, nativeText.frame != bounds { nativeText.frame = bounds }
    }

    override var intrinsicContentSize: NSSize {
        intrinsicQueries &+= 1
        if field == .badge {
            return appliedDisplay?.value.isEmpty == false ? hosting?.fittingSize ?? .zero : .zero
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: fixedFieldHeight)
    }

    override func invalidateIntrinsicContentSize() {
        intrinsicNotifications &+= 1
        super.invalidateIntrinsicContentSize()
    }

    func recordRepresentableUpdate() { representableUpdates &+= 1 }

    var nativeDiagnostics: [String: UInt64] {
        [
            "representable_updates": representableUpdates,
            "outer_intrinsic_notifications": intrinsicNotifications,
            "outer_intrinsic_queries": intrinsicQueries,
            "inner_intrinsic_notifications": nativeText?.intrinsicNotifications ?? 0,
        ]
    }

    func nativeGeometry(relativeTo root: NSView) -> String {
        let child = hosting.map { $0 as NSView } ?? nativeText!
        return
            "\(field.rawValue): outer=\(convert(bounds, to: root)), bounds=\(bounds), inner=\(child.frame), innerBounds=\(child.bounds), backing=\(convertToBacking(bounds)), declaredHeight=\(fixedFieldHeight), logical=\(String(describing: nativeText?.logicalFrame)), render=\(String(describing: nativeText?.renderFrame)), font=\(String(describing: nativeText?.font)), metrics=\(nativeText?.fontMetrics ?? "badge")"
    }

    func connect(to next: DashboardRetainedUsageCoordinator) {
        guard coordinator !== next else { return }
        disconnect()
        // The callback needs its admitted owner while applying a cached value.
        coordinator = next
        if !next.register(
            field, token: token, apply: { [weak self] display in self?.apply(display) })
        {
            coordinator = nil
        }
    }

    func disconnect() {
        coordinator?.unregister(field, token: token)
        coordinator = nil
    }

    func configure(
        density: DashboardHeightPolicy, colorScheme: ColorScheme,
        environment: EnvironmentValues? = nil
    ) {
        let nextKey = environment.map(TextEnvironment.init)
        guard
            self.density != density || self.colorScheme != colorScheme || environmentKey != nextKey
        else { return }
        let sizeChanged = self.density != density
        self.density = density
        self.colorScheme = colorScheme
        self.environment = environment
        environmentKey = nextKey
        configureRoot()
        if sizeChanged { invalidateIntrinsicContentSize() }
    }

    private func apply(_ display: DashboardRetainedUsageCoordinator.Display) {
        let changed = appliedDisplay != display
        if changed {
            appliedDisplay = display
            if let nativeText {
                nativeText.apply(text: display.value, help: display.help)
            } else {
                if value.text != display.value { value.text = display.value }
                if value.help != display.help { value.help = display.help }
                invalidateIntrinsicContentSize()
            }
        }
        coordinator?.recordNativeApply(field: field, changed: changed)
    }

    private func configureRoot() {
        if let nativeText {
            nativeText.configure(
                size: density.value(16, 14), height: fixedFieldHeight, colorScheme: colorScheme,
                environment: environment)
            return
        }
        let content = DashboardRetainedUsageBadge(value: value)
        if let environment {
            hosting?.rootView = AnyView(
                content.environment(\.self, environment).environment(\.colorScheme, colorScheme))
        } else {
            hosting?.rootView = AnyView(content.environment(\.colorScheme, colorScheme))
        }
    }

    /// Retain the full SwiftUI environment, but do not rebuild a text graph for
    /// every parent update when typography, appearance and interaction agree.
    private struct TextEnvironment: Equatable {
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
        let direction: LayoutDirection
        let locale: Locale
        let scale: CGFloat
        let typeSize: DynamicTypeSize
        let font: Font?
        let enabled: Bool
        let reduceMotion: Bool
        let reduceTransparency: Bool
        let invertColors: Bool
        let differentiateWithoutColor: Bool

        init(_ values: EnvironmentValues) {
            scheme = values.colorScheme
            contrast = values.colorSchemeContrast
            direction = values.layoutDirection
            locale = values.locale
            scale = values.displayScale
            typeSize = values.dynamicTypeSize
            font = values.font
            enabled = values.isEnabled
            reduceMotion = values.accessibilityReduceMotion
            reduceTransparency = values.accessibilityReduceTransparency
            invertColors = values.accessibilityInvertColors
            differentiateWithoutColor = values.accessibilityDifferentiateWithoutColor
        }
    }
}

/// Native value fields have no nested SwiftUI graph. Their selectable full
/// string remains authoritative while only the displayed font shrinks to fit.
@MainActor
private final class FixedUsageTextField: NSTextField {
    private(set) var intrinsicNotifications: UInt64 = 0
    private var baseFont: NSFont = .systemFont(ofSize: 16, weight: .medium)
    private var fittedText: String?
    private var fittedWidth: CGFloat?
    private var fittedBaseFont: NSFont?
    private var declaredHeight: CGFloat = 21
    private var metricEnvironment: EnvironmentValues?
    private var metricColorScheme: ColorScheme = .light
    private(set) var logicalFrame: CGRect?
    var fontMetrics: String {
        guard let font, let cell = cell as? RoundedUsageTextCell else { return "unconfigured" }
        return
            "ascender=\(font.ascender),descender=\(font.descender),leading=\(font.leading),lineHeight=\(cell.lineHeight),baseline=\(cell.baselineOffset)"
    }

    override var isFlipped: Bool { true }

    /// SwiftUI assigns fractional frame origins/sizes before the native bridge
    /// snaps the NSView bounds to backing pixels. Draw in that original frame
    /// so independently rounded grid rows retain the original text baseline.
    var renderFrame: CGRect {
        guard let logicalFrame, let root = window?.contentView else { return bounds }
        let native = convert(bounds, to: root)
        let nativeTop = root.isFlipped ? native.minY : root.bounds.maxY - native.maxY
        return CGRect(
            x: logicalFrame.minX - native.minX,
            y: logicalFrame.minY - nativeTop,
            width: logicalFrame.width, height: logicalFrame.height)
    }

    func setLogicalFrame(_ frame: CGRect?) {
        guard logicalFrame != frame else { return }
        logicalFrame = frame
        updateFittedFont()
        (cell as? RoundedUsageTextCell)?.logicalDrawingFrame = renderFrame
        needsDisplay = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = RoundedUsageTextCell(textCell: "")
        isEditable = false
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        maximumNumberOfLines = 1
        lineBreakMode = .byTruncatingTail
        cell?.wraps = false
        // Single-line mode has a control-size baseline, independent of font.
        // The custom cell instead centers the actual font's typographic line.
        cell?.usesSingleLineMode = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func invalidateIntrinsicContentSize() { intrinsicNotifications &+= 1 }

    override func layout() {
        super.layout()
        updateFittedFont()
        (cell as? RoundedUsageTextCell)?.logicalDrawingFrame = renderFrame
    }

    override func draw(_ dirtyRect: NSRect) {
        (cell as? RoundedUsageTextCell)?.logicalDrawingFrame = renderFrame
        super.draw(dirtyRect)
    }

    override func selectText(_ sender: Any?) {
        (cell as? RoundedUsageTextCell)?.logicalDrawingFrame = renderFrame
        super.selectText(sender)
    }

    func configure(
        size: CGFloat, height: CGFloat, colorScheme: ColorScheme, environment: EnvironmentValues?
    ) {
        let system = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        let rounded = system.fontDescriptor.withDesign(.rounded) ?? system.fontDescriptor
        let descriptor = rounded.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: NSNumber(value: kNumberSpacingType),
                    NSFontDescriptor.FeatureKey.selectorIdentifier: NSNumber(
                        value: kMonospacedNumbersSelector),
                ]
            ]
        ])
        baseFont = NSFont(descriptor: descriptor, size: size) ?? system
        declaredHeight = height
        metricEnvironment = environment
        metricColorScheme = colorScheme
        fittedBaseFont = nil
        let highContrast = environment?.colorSchemeContrast == .increased
        let appearanceName: NSAppearance.Name =
            colorScheme == .dark
            ? (highContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
            : (highContrast ? .accessibilityHighContrastAqua : .aqua)
        appearance = NSAppearance(named: appearanceName)
        textColor = .labelColor
        alignment = environment?.layoutDirection == .rightToLeft ? .right : .left
        isEnabled = environment?.isEnabled ?? true
        updateFittedFont()
        needsDisplay = true
    }

    func apply(text: String, help: String) {
        if stringValue != text { stringValue = text }
        if toolTip != help { toolTip = help.isEmpty ? nil : help }
        setAccessibilityHelp(help.isEmpty ? nil : help)
        updateFittedFont()
        needsDisplay = true
    }

    private func updateFittedFont() {
        let availableWidth = logicalFrame?.width ?? bounds.width
        guard
            fittedText != stringValue || fittedWidth != availableWidth || fittedBaseFont != baseFont
        else { return }
        fittedText = stringValue
        fittedWidth = availableWidth
        fittedBaseFont = baseFont
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: stringValue, attributes: [.font: baseFont]))
        let backingScale = max(
            1, metricEnvironment?.displayScale ?? window?.backingScaleFactor ?? 1)
        let natural =
            (CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) * backingScale).rounded(.up)
            / backingScale
        var next = baseFont
        if natural > availableWidth && availableWidth > 0 {
            // The original Text fitter uses five bounded binary-search steps
            // between the minimum and original scale. Public Font.scaled(by:)
            // resolves to different quarter-point sizes, so preserve the exact
            // fractional font size used by the original rendered glyphs.
            var lower: CGFloat = 0.7
            var upper: CGFloat = 1
            for _ in 0..<5 {
                let scale = (lower + upper) / 2
                let candidate = nativeFont(at: baseFont.pointSize * scale)
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(
                        string: stringValue, attributes: [.font: candidate]))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                if (width * backingScale).rounded(.up) / backingScale <= availableWidth {
                    lower = scale
                } else {
                    upper = scale
                }
            }
            next = nativeFont(at: baseFont.pointSize * lower)
        }
        if font != next { font = next }
        if let cell = cell as? RoundedUsageTextCell {
            let metrics = OriginalUsageTextMetrics.measure(
                font: next, height: declaredHeight, scale: 1,
                colorScheme: metricColorScheme, environment: metricEnvironment)
            cell.lineHeight = metrics.height
            cell.baselineOffset = metrics.baseline
        }
    }

    private func nativeFont(at size: CGFloat) -> NSFont {
        NSFont(descriptor: baseFont.fontDescriptor, size: size) ?? baseFont
    }

}

/// Draw a single unpadded typographic line rather than the control-size-based
/// baseline of NSTextFieldCell's single-line mode. Native selection and AX
/// still use the cell's complete string and fitted font.
@MainActor
private final class RoundedUsageTextCell: NSTextFieldCell {
    var logicalDrawingFrame: CGRect?
    var lineHeight: CGFloat = 0
    var baselineOffset: CGFloat = 0

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        guard let font else { return rect }
        let rect = logicalDrawingFrame ?? rect
        let height = lineHeight > 0 ? lineHeight : font.ascender - font.descender + font.leading
        return NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { titleRect(forBounds: rect) }

    override func setUpFieldEditorAttributes(_ textObject: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObject)
        if let editor = editor as? NSTextView {
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
        }
        return editor
    }

    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObject: NSText,
        delegate: Any?, start: Int, length: Int
    ) {
        super.select(
            withFrame: titleRect(forBounds: rect), in: controlView, editor: textObject,
            delegate: delegate, start: start, length: length)
    }

    override func drawInterior(withFrame frame: NSRect, in controlView: NSView) {
        guard !stringValue.isEmpty, let font, let context = NSGraphicsContext.current?.cgContext
        else { return }
        let frame = logicalDrawingFrame ?? frame
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor ?? NSColor.labelColor,
        ]
        let fullLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: stringValue, attributes: attributes))
        let fullWidth = CTLineGetTypographicBounds(fullLine, nil, nil, nil)
        let token = CTLineCreateWithAttributedString(
            NSAttributedString(string: "…", attributes: attributes))
        let targetWidth = frame.width
        let line =
            fullWidth > targetWidth + 0.000_001
            ? CTLineCreateTruncatedLine(fullLine, Double(targetWidth), .end, token) ?? fullLine
            : fullLine
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let x = alignment == .right ? max(0, frame.width - width) : 0
        let baseline =
            lineHeight > 0
            ? (frame.height + lineHeight) / 2 - baselineOffset
            : (frame.height - ascent - descent - leading) / 2 + descent + leading / 2
        let target = CGPoint(
            x: frame.minX + x,
            y: controlView.isFlipped ? frame.maxY - baseline : frame.minY + baseline)
        let snappedY: CGFloat
        if controlView.window != nil {
            // Use this flipped view's backing coordinates so half-pixel ties
            // follow the drawing context's direction, including separate rows.
            var backing = controlView.convertToBacking(CGRect(origin: target, size: .zero))
            backing.origin.y = backing.origin.y.rounded()
            snappedY = controlView.convertFromBacking(backing).origin.y
        } else {
            snappedY = target.y
        }
        context.saveGState()
        context.setAllowsFontSmoothing(true)
        context.setShouldSmoothFonts(true)
        context.clip(to: frame)
        context.translateBy(x: target.x, y: snappedY)
        if controlView.isFlipped { context.scaleBy(x: 1, y: -1) }
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Only a bounded style/scale calibration uses an ephemeral SwiftUI graph.
/// Recurring native updates reuse the public original Text baseline metrics.
@MainActor
private enum OriginalUsageTextMetrics {
    private struct Key: Equatable {
        let size: CGFloat
        let height: CGFloat
        let scale: CGFloat
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
        let direction: LayoutDirection
        let locale: String
        let displayScale: CGFloat
        let typeSize: DynamicTypeSize
        let enabled: Bool
    }
    private static var cache: [(Key, OriginalUsageMetricsBox.Measurement)] = []

    static func measure(
        font: NSFont, height: CGFloat, scale: CGFloat,
        colorScheme: ColorScheme, environment: EnvironmentValues?
    ) -> OriginalUsageMetricsBox.Measurement {
        let values = environment ?? EnvironmentValues()
        let key = Key(
            size: font.pointSize, height: height, scale: scale, colorScheme: colorScheme,
            contrast: values.colorSchemeContrast, direction: values.layoutDirection,
            locale: values.locale.identifier, displayScale: values.displayScale,
            typeSize: values.dynamicTypeSize, enabled: values.isEnabled)
        if let existing = cache.first(where: { $0.0 == key }) { return existing.1 }
        let literal = scale < 1 ? String(repeating: "0", count: 30) : "0"
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: literal, attributes: [.font: font]))
        let width =
            scale < 1 ? CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) * scale : 64
        let box = OriginalUsageMetricsBox()
        let text = OriginalUsageMetricsLayout(result: box) {
            Text(literal)
                .font(.system(size: font.pointSize, weight: .medium, design: .rounded))
                .monospacedDigit().textSelection(.enabled)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(height: height).frame(width: width, alignment: .leading)
        let hosting = NSHostingView(
            rootView: text.environment(\.self, values).environment(\.colorScheme, colorScheme))
        hosting.sizingOptions = []
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        _ = hosting.fittingSize
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        guard let measured = box.read() else {
            preconditionFailure("The original SwiftUI Text did not provide public baseline metrics")
        }
        if cache.count == 8 { cache.removeFirst() }
        cache.append((key, measured))
        return measured
    }
}

private final class OriginalUsageMetricsBox: @unchecked Sendable {
    struct Measurement: Sendable {
        let height: CGFloat
        let baseline: CGFloat
    }
    private let lock = NSLock()
    private var measurement: Measurement?

    func record(height: CGFloat, baseline: CGFloat) {
        guard height.isFinite, height > 0, baseline.isFinite, baseline >= 0, baseline <= height
        else { return }
        lock.lock()
        defer { lock.unlock() }
        measurement = Measurement(height: height, baseline: baseline)
    }

    func read() -> Measurement? {
        lock.lock()
        defer { lock.unlock() }
        return measurement
    }
}

private struct OriginalUsageMetricsLayout: Layout {
    let result: OriginalUsageMetricsBox
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let dimensions = text.dimensions(in: proposal)
        result.record(height: dimensions.height, baseline: dimensions[.firstTextBaseline])
        return CGSize(width: dimensions.width, height: dimensions.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard let text = subviews.first else { return }
        let dimensions = text.dimensions(in: proposal)
        result.record(height: dimensions.height, baseline: dimensions[.firstTextBaseline])
        text.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}

extension DashboardRetainedUsageCoordinator {
    fileprivate func recordNativeApply(field: Field, changed: Bool) {
        guard instrumented, !isStopped, let presentation, presentation.isActive, sinks[field] != nil
        else { return }
        PerformanceGraphicsDiagnostics.shared.retainedUsageValueApplied(
            owner: presentation.scalarPerformanceOwnerID, field: field.rawValue, changed: changed)
    }
}

private struct DashboardRetainedUsageBadge: View {
    let value: DashboardRetainedUsageHost.Value
    var body: some View { Text(value.text).font(.system(size: 10)).foregroundStyle(.secondary) }
}
