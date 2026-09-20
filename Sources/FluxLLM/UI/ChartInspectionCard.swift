import SwiftUI

/// The scroll viewport is expressed in SwiftUI's global coordinate space.
private struct ChartInspectionViewportKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    var chartInspectionViewport: CGRect? {
        get { self[ChartInspectionViewportKey.self] }
        set { self[ChartInspectionViewportKey.self] = newValue }
    }
}

struct ChartInspectionCard: View {
    let content: ChartInspectionContent
    let width: CGFloat
    let color: (ChartInspectionContent.Accent) -> Color
    let hasEffects: Bool

    static let rowHeight: CGFloat = 14
    static let rowSpacing: CGFloat = 4
    static let inset: CGFloat = 9

    static func height(for content: ChartInspectionContent) -> CGFloat {
        let detailRows = content.rows.count + (content.requestMetrics == nil ? 0 : 1)
        return inset * 2 + rowHeight + CGFloat(detailRows) * (rowHeight + rowSpacing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            HStack(spacing: 8) {
                Text(content.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(color(content.accent))
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let badge = content.badge {
                    Text(badge).foregroundStyle(.secondary).fixedSize()
                }
            }
            .frame(height: Self.rowHeight)
            if let metrics = content.requestMetrics {
                requestSummary(metrics)
            }
            ForEach(content.rows.indices, id: \.self) { index in
                let row = content.rows[index]
                HStack(spacing: 8) {
                    Text(row.label).foregroundStyle(color(row.accent)).fixedSize()
                    Spacer(minLength: 0)
                    Text(row.value).monospacedDigit().truncationMode(.middle)
                }
                .frame(height: Self.rowHeight)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(Self.inset)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(hasEffects ? 0.16 : 0), radius: 6, y: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func requestSummary(_ metrics: ChartInspectionContent.RequestMetrics) -> some View {
        let average = Text(metrics.averageRate) + Text(" avg").foregroundColor(.secondary)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Text(metrics.duration).fixedSize()
                Spacer(minLength: 5)
                Text("·").foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 5)
                average.fixedSize()
                Spacer(minLength: 5)
                Text("·").foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 5)
                Text(metrics.outputTokens).fixedSize()
            }
            // Keep duration and average readable when a narrow viewport or a
            // very large counter cannot accommodate the auxiliary token total.
            HStack(spacing: 8) {
                Text(metrics.duration)
                Spacer(minLength: 0)
                average
            }
        }
        .monospacedDigit()
        .truncationMode(.middle)
        .frame(height: Self.rowHeight)
    }
}
