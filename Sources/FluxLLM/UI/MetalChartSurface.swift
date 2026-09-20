import SwiftUI

/// A shared, stationary chart surface. Broad lighting provides depth without texture noise.
struct MetalChartSurface: View {
    var compact = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isDark: Bool { colorScheme == .dark }
    private var hasMaterial: Bool { contrast != .increased && !reduceTransparency }

    var body: some View {
        ZStack {
            if hasMaterial {
                LinearGradient(
                    stops: [
                        .init(
                            color: metal(dark: (0.065, 0.11, 0.19), light: (0.93, 0.96, 0.99)),
                            location: 0),
                        .init(
                            color: metal(dark: (0.035, 0.065, 0.12), light: (0.87, 0.91, 0.95)),
                            location: 0.55),
                        .init(
                            color: metal(dark: (0.055, 0.09, 0.15), light: (0.92, 0.95, 0.98)),
                            location: 1),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)

                GeometryReader { geometry in
                    RadialGradient(
                        colors: [
                            Color.white.opacity(
                                isDark ? (compact ? 0.04 : 0.07) : (compact ? 0.20 : 0.38)),
                            TelemetryPalette.fluxCyan.opacity(isDark ? 0.025 : 0.014),
                            .clear,
                        ], center: UnitPoint(x: 0.24, y: -0.1), startRadius: 0,
                        endRadius: max(geometry.size.width, geometry.size.height) * 0.85)
                }
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 5 : 8))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func metal(
        dark: (Double, Double, Double), light: (Double, Double, Double)
    ) -> Color {
        let components = isDark ? dark : light
        return Color(red: components.0, green: components.1, blue: components.2)
    }
}

/// A single subdued inset edge frames the data without a heavy seam or chrome outlines.
struct MetalChartRim: View {
    var compact = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let isDark = colorScheme == .dark
        let outline = RoundedRectangle(cornerRadius: compact ? 5 : 8)
        Group {
            if contrast == .increased || reduceTransparency {
                outline.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
            } else {
                outline.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(isDark ? 0.22 : 0.12), location: 0),
                            .init(color: .white.opacity(isDark ? 0.04 : 0.16), location: 0.5),
                            .init(color: .white.opacity(isDark ? 0.14 : 0.72), location: 1),
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: compact ? 0.5 : 0.75)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One stationary surface unites a metric's heading, value, and history.
struct FlowMetricSurface: View {
    var compact = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: compact ? 18 : 22)
        Group {
            if contrast == .increased || reduceTransparency {
                outline.fill(Color(nsColor: .textBackgroundColor))
            } else {
                outline.fill(
                    LinearGradient(
                        stops: [
                            .init(
                                color: colorScheme == .dark
                                    ? Color(red: 0.106, green: 0.133, blue: 0.188)
                                    : Color(red: 1, green: 1, blue: 1),
                                location: 0),
                            .init(
                                color: colorScheme == .dark
                                    ? Color(red: 0.075, green: 0.094, blue: 0.129)
                                    : Color(red: 0.987, green: 0.993, blue: 1),
                                location: 0.52),
                            .init(
                                color: colorScheme == .dark
                                    ? Color(red: 0.075, green: 0.094, blue: 0.129)
                                    : Color(red: 0.988, green: 0.992, blue: 1),
                                location: 1),
                        ], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A quiet static top edge gives the whole card depth without outlining the plot.
struct FlowMetricRim: View {
    var compact = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: compact ? 18 : 22)
        Group {
            if contrast == .increased || reduceTransparency {
                outline.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
            } else {
                outline.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(
                                color: colorScheme == .dark
                                    ? Color(red: 0.55, green: 0.70, blue: 0.85).opacity(0.28)
                                    : Color(red: 0.60, green: 0.69, blue: 0.82).opacity(0.32),
                                location: 0),
                            .init(
                                color: colorScheme == .dark
                                    ? Color.white.opacity(0.055)
                                    : Color(red: 0.64, green: 0.72, blue: 0.83).opacity(0.22),
                                location: 0.45),
                            .init(
                                color: colorScheme == .dark
                                    ? Color.white.opacity(0.075)
                                    : Color(red: 0.60, green: 0.69, blue: 0.82).opacity(0.30),
                                location: 1),
                        ], startPoint: .top, endPoint: .bottom),
                    lineWidth: compact ? 0.65 : 0.75)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
