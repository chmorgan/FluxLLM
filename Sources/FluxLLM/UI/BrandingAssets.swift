import AppKit

/// Text follows the menu appearance; artwork keeps the same unoutlined blue/cyan fill.
enum StatusMarkAppearance: String, Sendable {
    case light
    case dark

    @MainActor
    static func resolve(appearance: NSAppearance, isHighlighted: Bool = false) -> Self {
        if isHighlighted { return .dark }
        return resolve(
            matchedName: appearance.bestMatch(from: [
                .aqua, .darkAqua, .vibrantLight, .vibrantDark,
                .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark,
            ]))
    }

    /// High-contrast names participate in matching but cannot be used to
    /// construct an NSAppearance directly, so classify the match separately.
    static func resolve(matchedName: NSAppearance.Name?) -> Self {
        switch matchedName {
        case .darkAqua, .vibrantDark,
            .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
            .dark
        default:
            .light
        }
    }

    var resourceName: String {
        switch self {
        case .light: "FluxLLMStatusLight"
        case .dark: "FluxLLMStatusDark"
        }
    }

    @MainActor
    var foregroundColor: NSColor {
        switch self {
        case .light: NSColor(calibratedWhite: 0.08, alpha: 1)
        case .dark: NSColor(calibratedWhite: 0.96, alpha: 1)
        }
    }
}

/// Load each approved bitmap representation once, at its intended logical size.
@MainActor
enum BrandingAssets {
    static let statusMarkSize = NSSize(width: 24, height: 18)
    static let brandMarkSize = NSSize(width: 48, height: 36)
    private static let resources = resourceBundle()
    private static let lightStatusMark = loadMark(named: "FluxLLMStatusLight", size: statusMarkSize)
    private static let darkStatusMark = loadMark(named: "FluxLLMStatusDark", size: statusMarkSize)
    private static let lightBrandMark = loadMark(named: "FluxLLMBrandLight", size: brandMarkSize)
    private static let darkBrandMark = loadMark(named: "FluxLLMBrandDark", size: brandMarkSize)

    static let appIcon: NSImage? = {
        guard
            let url = resources.url(
                forResource: "FluxLLM", withExtension: "icns", subdirectory: "Branding")
        else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// An installed .app carries the SwiftPM bundle in Contents/Resources.
    /// SwiftPM's development lookup remains available to executable/test runs.
    static func resourceBundle(in mainBundle: Bundle = .main) -> Bundle {
        if let url = mainBundle.url(forResource: "FluxLLM_FluxLLM", withExtension: "bundle"),
            let bundledResources = Bundle(url: url)
        {
            return bundledResources
        }
        return .module
    }

    static func statusMark(for appearance: StatusMarkAppearance) -> NSImage? {
        switch appearance {
        case .light: lightStatusMark
        case .dark: darkStatusMark
        }
    }

    /// Transparent header artwork, rendered from the vector source at both scales.
    static func brandMark(for appearance: StatusMarkAppearance) -> NSImage? {
        switch appearance {
        case .light: lightBrandMark
        case .dark: darkBrandMark
        }
    }

    private static func loadMark(named resourceName: String, size: NSSize) -> NSImage? {
        let image = NSImage(size: size)
        for scale in [1, 2] {
            let name = resourceName + (scale == 2 ? "@2x" : "")
            guard
                let url = resources.url(
                    forResource: name, withExtension: "png", subdirectory: "Branding"),
                let data = try? Data(contentsOf: url),
                let representation = NSBitmapImageRep(data: data),
                representation.pixelsWide == Int(size.width) * scale,
                representation.pixelsHigh == Int(size.height) * scale
            else { continue }
            representation.size = size
            image.addRepresentation(representation)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = false
        return image
    }
}
