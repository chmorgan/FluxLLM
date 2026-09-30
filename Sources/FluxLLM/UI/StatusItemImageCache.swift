import AppKit

/// Retains one layout and at most two images. Repeated samples reuse geometry;
/// identical drawn values and accessibility changes do not require bitmap rendering.
@MainActor
struct StatusItemImageCache {
    struct Images {
        let normal: NSImage
        let highlighted: NSImage
        let itemWidth: CGFloat
    }

    private struct Key: Equatable {
        let number: String
        let throughputFill: Double?
        let gpuFill: Double?
        let imageHeight: CGFloat
        let numberCharacters: Int
        let visibility: StatusItemVisibility
        let appearance: StatusMarkAppearance
    }

    private struct LayoutKey: Equatable {
        let imageHeight: CGFloat
        let numberCharacters: Int
        let visibility: StatusItemVisibility
    }

    private var key: Key?
    private var cached: Images?
    private var layoutKey: LayoutKey?
    private var cachedLayout: StatusItemLayout?
    private var accessibilitySummary: String?
    private(set) var renderCount = 0
    private(set) var layoutCount = 0

    mutating func images(
        snapshot: StatusItemPresentation.Snapshot, availableHeight: CGFloat,
        appearance: NSAppearance, numberCharacters: Int,
        visibility: StatusItemVisibility
    ) -> Images {
        let style = StatusMarkAppearance.resolve(appearance: appearance)
        let newKey = Key(
            number: visibility.showTokensPerSecond ? snapshot.number : "",
            throughputFill: snapshot.throughput.fillFraction,
            gpuFill: snapshot.gpu.fillFraction,
            imageHeight: StatusItemPresentation.imageHeight(availableHeight: availableHeight),
            numberCharacters: visibility.showTokensPerSecond
                ? min(max(max(numberCharacters, snapshot.number.count), 3), 7) : 0,
            visibility: visibility, appearance: style)
        if key != newKey || cached == nil {
            let newLayoutKey = LayoutKey(
                imageHeight: newKey.imageHeight, numberCharacters: newKey.numberCharacters,
                visibility: visibility)
            if layoutKey != newLayoutKey || cachedLayout == nil {
                cachedLayout = StatusItemPresentation.layout(
                    numberCharacters: newKey.numberCharacters, availableHeight: availableHeight,
                    visibility: visibility)
                layoutKey = newLayoutKey
                layoutCount += 1
            }
            let layout = cachedLayout!
            let normal = StatusItemPresentation.image(
                snapshot: snapshot, layout: layout, style: style)
            cached = Images(
                normal: normal,
                highlighted: style == .dark
                    ? normal
                    : StatusItemPresentation.image(
                        snapshot: snapshot, layout: layout, style: .dark),
                itemWidth: layout.itemWidth)
            key = newKey
            renderCount += 1
        }
        let images = cached!
        if accessibilitySummary != snapshot.accessibilitySummary {
            images.normal.accessibilityDescription = snapshot.accessibilitySummary
            images.highlighted.accessibilityDescription = snapshot.accessibilitySummary
            accessibilitySummary = snapshot.accessibilitySummary
        }
        return images
    }
}
