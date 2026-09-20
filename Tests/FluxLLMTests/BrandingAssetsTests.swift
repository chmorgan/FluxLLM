import AppKit
import XCTest

@testable import FluxLLM

@MainActor
final class BrandingAssetsTests: XCTestCase {
    func testPackagedResourcesRemainDiscoverableAfterMovingApp() throws {
        let manager = FileManager.default
        let temporaryDirectory = manager.temporaryDirectory
            .appendingPathComponent("FluxLLMBrandingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: temporaryDirectory) }

        let stagedApp = temporaryDirectory.appendingPathComponent("Staging/FluxLLM.app")
        let contents = stagedApp.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        let appInfo: [String: String] = [
            "CFBundleIdentifier": "test.fluxllm.relocated",
            "CFBundleName": "FluxLLM",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: appInfo, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let sourceBundle = BrandingAssets.resourceBundle()
        let bundleName = "FluxLLM_FluxLLM.bundle"
        try manager.copyItem(
            at: sourceBundle.bundleURL,
            to: resources.appendingPathComponent(bundleName, isDirectory: true))

        let installedDirectory = temporaryDirectory.appendingPathComponent(
            "Applications", isDirectory: true)
        try manager.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
        let movedApp = installedDirectory.appendingPathComponent("FluxLLM.app", isDirectory: true)
        try manager.moveItem(at: stagedApp, to: movedApp)

        let mainBundle = try XCTUnwrap(Bundle(url: movedApp))
        let resolvedBundle = BrandingAssets.resourceBundle(in: mainBundle)
        let expectedURL = movedApp.appendingPathComponent("Contents/Resources/\(bundleName)")
        XCTAssertEqual(canonicalURL(resolvedBundle.bundleURL), canonicalURL(expectedURL))
        XCTAssertNotEqual(
            canonicalURL(resolvedBundle.bundleURL), canonicalURL(sourceBundle.bundleURL))

        // Confirm that lookups reach the relocated copy, rather than succeeding
        // through SwiftPM's development bundle elsewhere on the machine.
        for resource in ["FluxLLMStatusLight@2x", "FluxLLMBrandDark@2x"] {
            let imageURL = try XCTUnwrap(
                resolvedBundle.url(
                    forResource: resource, withExtension: "png", subdirectory: "Branding"))
            XCTAssertTrue(
                canonicalURL(imageURL).path.hasPrefix(canonicalURL(expectedURL).path + "/"))
            XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: imageURL)))
        }
    }

    func testBothStatusVariantsLoadOriginalColorAtBothDisplayScales() throws {
        for appearance in [StatusMarkAppearance.light, .dark] {
            let image = try XCTUnwrap(BrandingAssets.statusMark(for: appearance))
            XCTAssertFalse(image.isTemplate, "The approved gradient must retain its colors.")
            XCTAssertEqual(image.size, NSSize(width: 24, height: 18))

            let representations = image.representations.compactMap { $0 as? NSBitmapImageRep }
            XCTAssertEqual(representations.count, 2)
            XCTAssertEqual(Set(representations.map(\.pixelsWide)), Set([24, 48]))
            for representation in representations {
                XCTAssertEqual(representation.size, image.size)
                XCTAssertEqual(representation.pixelsWide * 3, representation.pixelsHigh * 4)
                XCTAssertTrue(representation.hasAlpha)
                XCTAssertTrue(
                    hasChromaticPixel(in: representation), "The menu mark must remain blue/cyan.")
                for x in [0, representation.pixelsWide - 1] {
                    for y in [0, representation.pixelsHigh - 1] {
                        let corner = try XCTUnwrap(representation.colorAt(x: x, y: y))
                        XCTAssertEqual(
                            corner.alphaComponent, 0, accuracy: 0.001,
                            "The menu mark must not acquire an opaque tile.")
                    }
                }
            }
        }
    }

    func testAppIconCanBeDecodedFromBundledResources() throws {
        let image = try XCTUnwrap(BrandingAssets.appIcon)
        XCTAssertTrue(image.isValid)
        XCTAssertFalse(image.representations.isEmpty)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testHeaderMarkLoadsTransparentOriginalColorAtBothDisplayScales() throws {
        for appearance in [StatusMarkAppearance.light, .dark] {
            let image = try XCTUnwrap(BrandingAssets.brandMark(for: appearance))
            XCTAssertFalse(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 48, height: 36))
            let representations = image.representations.compactMap { $0 as? NSBitmapImageRep }
            XCTAssertEqual(representations.count, 2)
            XCTAssertEqual(Set(representations.map(\.pixelsWide)), Set([48, 96]))
            for representation in representations {
                XCTAssertEqual(representation.size, image.size)
                XCTAssertEqual(representation.pixelsWide * 3, representation.pixelsHigh * 4)
                XCTAssertTrue(hasChromaticPixel(in: representation))
                for x in [0, representation.pixelsWide - 1] {
                    for y in [0, representation.pixelsHigh - 1] {
                        let corner = try XCTUnwrap(representation.colorAt(x: x, y: y))
                        XCTAssertEqual(
                            corner.alphaComponent, 0, accuracy: 0.001,
                            "Headers use the transparent mark, not the app-icon tile.")
                    }
                }
            }
        }
    }

    func testStatusAppearanceFollowsAppearanceAndSelection() throws {
        let cases: [(NSAppearance.Name, StatusMarkAppearance)] = [
            (.aqua, .light),
            (.darkAqua, .dark),
            (.vibrantLight, .light),
            (.vibrantDark, .dark),
        ]
        for (name, expected) in cases {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            XCTAssertEqual(StatusMarkAppearance.resolve(appearance: appearance), expected)
            XCTAssertEqual(
                StatusMarkAppearance.resolve(appearance: appearance, isHighlighted: true), .dark)
        }

        // AppKit supplies these names through matching; it does not allow
        // constructing high-contrast appearances with NSAppearance(named:).
        let highContrastCases: [(NSAppearance.Name, StatusMarkAppearance)] = [
            (.accessibilityHighContrastAqua, .light),
            (.accessibilityHighContrastDarkAqua, .dark),
            (.accessibilityHighContrastVibrantLight, .light),
            (.accessibilityHighContrastVibrantDark, .dark),
        ]
        for (name, expected) in highContrastCases {
            XCTAssertEqual(StatusMarkAppearance.resolve(matchedName: name), expected)
        }
        XCTAssertEqual(StatusMarkAppearance.resolve(matchedName: nil), .light)
    }

    func testStatusRendererPreservesColoredMarkAtBothDisplayScales() throws {
        let store = MetricsStore()
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let image = StatusItemPresentation.image(
                store: store, availableHeight: 22, appearance: appearance)
            XCTAssertFalse(image.isTemplate)
            let representations = image.representations.compactMap { $0 as? NSBitmapImageRep }
            XCTAssertEqual(representations.count, 2)
            XCTAssertEqual(
                Set(representations.map(\.pixelsWide)),
                Set([Int(image.size.width), Int(image.size.width) * 2]))
            for representation in representations {
                let scale = representation.pixelsWide / Int(image.size.width)
                XCTAssertEqual(representation.pixelsHigh, Int(image.size.height) * scale)
                XCTAssertEqual(representation.size, image.size)
                XCTAssertTrue(
                    hasChromaticPixel(in: representation, columns: 24 * scale),
                    "The composed status item must draw the approved colored artwork.")
            }
        }
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func hasChromaticPixel(in representation: NSBitmapImageRep, columns: Int? = nil) -> Bool
    {
        for y in 0..<representation.pixelsHigh {
            for x in 0..<min(columns ?? representation.pixelsWide, representation.pixelsWide) {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    color.alphaComponent > 0.5
                else { continue }
                let components = [color.redComponent, color.greenComponent, color.blueComponent]
                if let minimum = components.min(), let maximum = components.max(),
                    maximum - minimum > 0.2
                {
                    return true
                }
            }
        }
        return false
    }
}
