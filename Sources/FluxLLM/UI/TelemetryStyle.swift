import AppKit
import SwiftUI

/// A native material with a neutral tint stays legible over light and dark wallpapers.
struct TelemetryPanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if !reduceTransparency { NativePopoverMaterial() }
            Color(nsColor: .windowBackgroundColor)
                .opacity(reduceTransparency || contrast == .increased ? 1 : 0.45)
        }
    }
}

private struct NativePopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

enum TelemetryPalette {
    static let fluxBlue = Color(red: 7 / 255, green: 93 / 255, blue: 254 / 255)
    static let fluxCyan = Color(red: 4 / 255, green: 201 / 255, blue: 229 / 255)

    static func throughput(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.40, green: 0.88, blue: 1)
            : Color(red: 0, green: 0.53, blue: 0.74)
    }
    static func gpu(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.71, green: 0.61, blue: 1)
            : Color(red: 0.55, green: 0.33, blue: 0.83)
    }
}

/// Saturated categorical colors for request rails. The caller retains each
/// request's color ordinal so track reuse and history expiry cannot recolor it.
/// The ten-color sequence matches the accepted signal-rails preview exactly.
enum RequestLanePalette {
    private static let darkColors: [UInt32] = [
        0xFF138F, 0x00F58B, 0x9E3CFF, 0xFFB300, 0x00D4FF,
        0x267CFF, 0xFFD000, 0xFF344D, 0x00FFD0, 0xC13BFF,
    ]

    private static let lightColors: [UInt32] = [
        0xE6007E, 0x00A65B, 0x7B12F4, 0xD48300, 0x0096C8,
        0x005FFF, 0xC38B00, 0xEE003B, 0x00A58B, 0x9F00F5,
    ]

    static func color(at index: Int, scheme: ColorScheme) -> Color {
        let colors = scheme == .dark ? darkColors : lightColors
        let ordinal = (index % colors.count + colors.count) % colors.count
        let rgb = colors[ordinal]
        return Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}

enum GPUActivityPresentation {
    static let summary = "Combined GPU usage on this Mac, including inference and other apps."

    static let explanation =
        "Combined GPU utilization on this Mac, reported by macOS: summed device utilization divided by summed available capacity. Each GPU contributes 100% capacity; GPUs are not weighted by computing power. Includes inference and other applications; remote backend GPU activity is not included."

    static func utilizationPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    static func valueLabel(_ activityPercent: Double?) -> String {
        guard let value = utilizationPercent(activityPercent) else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    static func chartSamples(_ samples: [TimeSeriesPoint]) -> [TimeSeriesPoint] {
        samples.map { sample in
            let validated = utilizationPercent(sample.value)
            return TimeSeriesPoint(
                timestamp: sample.timestamp, value: validated ?? 0,
                isAvailable: sample.isAvailable && validated != nil)
        }
    }
}
