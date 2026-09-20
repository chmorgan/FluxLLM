import Foundation

/// Content limits depend on the layout, never on incoming telemetry. Reserve
/// the tool-capable backend's footprint so switching backends cannot resize a window.
enum DashboardSizingPolicy {
    static let minimumWidth: CGFloat = 320
    static let narrowLayoutThreshold: CGFloat = 520
    static let horizontalInset: CGFloat = 20
    static let preferredWindowSize = CGSize(width: 740, height: 704)

    static func minimumContentSize(forWidth width: CGFloat) -> CGSize {
        let width = width.isFinite ? max(minimumWidth, width) : minimumWidth
        return CGSize(width: width, height: contentHeight(width: width, density: .condensed))
    }

    static func constrainedContentSize(_ proposed: CGSize) -> CGSize {
        let minimum = minimumContentSize(forWidth: proposed.width)
        return CGSize(
            width: minimum.width,
            height: proposed.height.isFinite ? max(minimum.height, proposed.height) : minimum.height
        )
    }

    static func roomyHeight(forWidth width: CGFloat) -> CGFloat {
        // Reach full-size controls only after the plot has room to grow too.
        let width = width.isFinite ? max(minimumWidth, width) : minimumWidth
        return contentHeight(width: width, density: .roomy) + 128
    }

    private static func contentHeight(width: CGFloat, density: DashboardHeightPolicy) -> CGFloat {
        let narrow = width < narrowLayoutThreshold
        let header =
            density.value(34, 28) + (narrow ? 54 : 14)
            + density.value(4, 3) * (narrow ? 2 : 1)
        // The native range menu and navigation buttons share one compact row.
        let history: CGFloat = 28
        let metrics =
            narrow
            ? density.metricRowHeight * 2 + density.value(12, 8) : density.metricRowHeight
        let card =
            metrics
            + LuminousActivityChart.minimumHeight(hasTools: true, compression: density.compression)
            + 12 + density.cardSpacing * 2 + density.cardPadding * 2
        let statistic = 14 + density.value(5, 2) + density.value(21, 18)
        let nativeStatistics = narrow ? statistic * 3 + density.value(12, 8) * 2 : statistic
        let usageStatistics =
            24 + density.value(8, 5)
            + (narrow ? statistic * 2 + 8 : statistic)
        // Reserve an optional storage-status line so errors cannot clip the footer.
        let statistics =
            max(nativeStatistics, usageStatistics)
            + 14 + density.value(8, 5) + 1 + density.value(8, 4)
        // At the minimum width, reserve three lines for the fixed GPU explanation.
        let footer: CGFloat = narrow ? 42 : 16
        let height =
            header + history + card + statistics + footer
            + density.rowSpacing * 4 + density.verticalInset * 2
        return ceil(height / 8) * 8
    }
}

struct DashboardWidthPolicy: Equatable {
    static let narrowLayoutThreshold = DashboardSizingPolicy.narrowLayoutThreshold

    let viewportWidth: CGFloat

    init(viewportWidth: CGFloat) {
        self.viewportWidth = viewportWidth.isFinite ? max(0, viewportWidth) : 0
    }

    var usesNarrowLayout: Bool { viewportWidth < Self.narrowLayoutThreshold }
}

/// Density follows only the viewport, so incoming telemetry cannot move controls.
struct DashboardHeightPolicy: Equatable {
    static let roomy = DashboardHeightPolicy(compression: 0)
    static let condensed = DashboardHeightPolicy(compression: 1)
    let compression: CGFloat

    private init(compression: CGFloat) {
        self.compression = compression
    }

    init(
        viewportHeight: CGFloat,
        viewportWidth: CGFloat = DashboardSizingPolicy.preferredWindowSize.width
    ) {
        let height = viewportHeight.isFinite ? max(0, viewportHeight) : 0
        let minimum = DashboardSizingPolicy.minimumContentSize(forWidth: viewportWidth).height
        let roomy = DashboardSizingPolicy.roomyHeight(forWidth: viewportWidth)
        compression = min(1, max(0, (roomy - height) / (roomy - minimum)))
    }

    func value(_ roomy: CGFloat, _ condensed: CGFloat) -> CGFloat {
        roomy + (condensed - roomy) * compression
    }

    var verticalInset: CGFloat { value(12, 6) }
    var rowSpacing: CGFloat { value(10, 6) }
    var cardPadding: CGFloat { value(18, 10) }
    var cardSpacing: CGFloat { value(14, 8) }
    var metricLabelSpacing: CGFloat { value(6, 4) }
    var metricValueHeight: CGFloat { ceil(value(50, 35)) }
    var metricRowHeight: CGFloat { 14 + metricLabelSpacing + metricValueHeight }
}
