import SwiftUI

/// A chart row receives spare window height; controls keep their intrinsic sizes.
struct DashboardFlexibleRow: LayoutValueKey {
    static let defaultValue = false
}

struct DashboardStackLayout: Layout {
    var spacing: CGFloat = 18

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width =
            proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let sizes = measurements(width: width, subviews: subviews)
        let naturalHeight = sizes.reduce(0) { $0 + $1.height } + gapHeight(subviews.count)
        return CGSize(width: width, height: max(naturalHeight, proposal.height ?? 0))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let sizes = measurements(width: bounds.width, subviews: subviews)
        let naturalHeight = sizes.reduce(0) { $0 + $1.height } + gapHeight(subviews.count)
        let flexibleCount = subviews.filter { $0[DashboardFlexibleRow.self] }.count
        let extra =
            flexibleCount > 0
            ? max(0, bounds.height - naturalHeight) / CGFloat(flexibleCount) : 0
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let height = sizes[index].height + (subview[DashboardFlexibleRow.self] ? extra : 0)
            subview.place(
                at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }

    private func measurements(width: CGFloat, subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    }

    private func gapHeight(_ count: Int) -> CGFloat {
        CGFloat(max(0, count - 1)) * spacing
    }
}
