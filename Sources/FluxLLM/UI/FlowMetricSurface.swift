import SwiftUI

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
