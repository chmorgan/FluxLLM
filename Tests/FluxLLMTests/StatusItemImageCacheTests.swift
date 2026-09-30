import AppKit
import XCTest

@testable import FluxLLM

@MainActor
final class StatusItemImageCacheTests: XCTestCase {
    func testUnchangedTicksReuseBothImagesAndAccessibilityChangesDoNotRender() throws {
        var cache = StatusItemImageCache()
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let snapshot = makeSnapshot()
        let initial = cache.images(
            snapshot: snapshot, availableHeight: 22, appearance: appearance,
            numberCharacters: 3, visibility: StatusItemVisibility())
        for _ in 0..<120 {
            let next = cache.images(
                snapshot: snapshot, availableHeight: 22, appearance: appearance,
                numberCharacters: 3, visibility: StatusItemVisibility())
            XCTAssertTrue(next.normal === initial.normal)
            XCTAssertTrue(next.highlighted === initial.highlighted)
        }
        let described = cache.images(
            snapshot: makeSnapshot(summary: "New model and request state"), availableHeight: 22,
            appearance: appearance, numberCharacters: 3, visibility: StatusItemVisibility())
        XCTAssertTrue(described.normal === initial.normal)
        XCTAssertTrue(described.highlighted === initial.highlighted)
        XCTAssertEqual(described.normal.accessibilityDescription, "New model and request state")
        XCTAssertEqual(cache.renderCount, 1)
        XCTAssertEqual(cache.layoutCount, 1)
        for image in [described.normal, described.highlighted] {
            XCTAssertEqual(image.representations.count, 2)
        }
    }

    func testTextAndMeterChangesReuseLayout() throws {
        var cache = StatusItemImageCache()
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let initial = cache.images(
            snapshot: makeSnapshot(), availableHeight: 22, appearance: appearance,
            numberCharacters: 3, visibility: StatusItemVisibility())
        var previous = initial
        for snapshot in [
            makeSnapshot(number: "51"), makeSnapshot(number: "999"),
            makeSnapshot(tps: 51), makeSnapshot(gpu: 43),
        ] {
            let next = cache.images(
                snapshot: snapshot, availableHeight: 22, appearance: appearance,
                numberCharacters: 3, visibility: StatusItemVisibility())
            XCTAssertFalse(next.normal === previous.normal)
            XCTAssertFalse(next.highlighted === previous.highlighted)
            XCTAssertEqual(next.itemWidth, initial.itemWidth)
            XCTAssertEqual(next.normal.size, initial.normal.size)
            XCTAssertEqual(cache.layoutCount, 1)
            previous = next
        }
        XCTAssertEqual(cache.renderCount, 5)
    }

    func testGeometryChangesInvalidateLayout() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        for (snapshot, height, width, visibility) in [
            (makeSnapshot(), 19.0, 3, StatusItemVisibility()),
            (makeSnapshot(), 22.0, 4, StatusItemVisibility()),
            (makeSnapshot(number: "9999"), 22.0, 3, StatusItemVisibility()),
            (makeSnapshot(), 22.0, 3, StatusItemVisibility(showLogo: false)),
            (makeSnapshot(), 22.0, 3, StatusItemVisibility(showTokensPerSecond: false)),
        ] {
            var cache = StatusItemImageCache()
            _ = cache.images(
                snapshot: makeSnapshot(), availableHeight: 22, appearance: appearance,
                numberCharacters: 3, visibility: StatusItemVisibility())
            let next = cache.images(
                snapshot: snapshot, availableHeight: height, appearance: appearance,
                numberCharacters: width, visibility: visibility)
            let expected = StatusItemPresentation.layout(
                numberCharacters: max(width, snapshot.number.count), availableHeight: height,
                visibility: visibility)
            XCTAssertEqual(cache.layoutCount, 2)
            XCTAssertEqual(next.itemWidth, expected.itemWidth)
            XCTAssertEqual(next.normal.size, expected.imageSize)
            let repeated = cache.images(
                snapshot: snapshot, availableHeight: height, appearance: appearance,
                numberCharacters: width, visibility: visibility)
            XCTAssertEqual(cache.layoutCount, 2)
            XCTAssertTrue(next.normal === repeated.normal)
        }
    }

    func testAppearanceChangesReuseLayoutAndIdenticalDarkArtwork() throws {
        var cache = StatusItemImageCache()
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightImages = cache.images(
            snapshot: makeSnapshot(), availableHeight: 22, appearance: light,
            numberCharacters: 3, visibility: StatusItemVisibility())
        XCTAssertFalse(lightImages.normal === lightImages.highlighted)
        let darkImages = cache.images(
            snapshot: makeSnapshot(), availableHeight: 22, appearance: dark,
            numberCharacters: 3, visibility: StatusItemVisibility())
        XCTAssertTrue(darkImages.normal === darkImages.highlighted)
        XCTAssertFalse(darkImages.normal === lightImages.normal)
        XCTAssertEqual(darkImages.normal.representations.count, 2)
        XCTAssertEqual(cache.layoutCount, 1)
        XCTAssertEqual(cache.renderCount, 2)

        let described = cache.images(
            snapshot: makeSnapshot(summary: "Updated dark reading"), availableHeight: 22,
            appearance: dark, numberCharacters: 3, visibility: StatusItemVisibility())
        XCTAssertTrue(described.normal === darkImages.normal)
        XCTAssertTrue(described.normal === described.highlighted)
        XCTAssertEqual(described.highlighted.accessibilityDescription, "Updated dark reading")
        XCTAssertEqual(cache.renderCount, 2)

        let restored = cache.images(
            snapshot: makeSnapshot(), availableHeight: 22, appearance: light,
            numberCharacters: 3, visibility: StatusItemVisibility())
        XCTAssertFalse(restored.normal === restored.highlighted)
        XCTAssertEqual(restored.itemWidth, lightImages.itemWidth)
        XCTAssertEqual(cache.layoutCount, 1)
        XCTAssertEqual(cache.renderCount, 3)
    }

    func testEveryDrawnInputInvalidatesImages() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        for (snapshot, height, appearance, width, visibility) in [
            (makeSnapshot(number: "51"), 22.0, light, 3, StatusItemVisibility()),
            (makeSnapshot(tps: 51), 22.0, light, 3, StatusItemVisibility()),
            (makeSnapshot(gpu: 43), 22.0, light, 3, StatusItemVisibility()),
            (makeSnapshot(), 19.0, light, 3, StatusItemVisibility()),
            (makeSnapshot(), 22.0, dark, 3, StatusItemVisibility()),
            (makeSnapshot(), 22.0, light, 4, StatusItemVisibility()),
            (makeSnapshot(), 22.0, light, 3, StatusItemVisibility(showLogo: false)),
            (makeSnapshot(), 22.0, light, 3, StatusItemVisibility(showTokensPerSecond: false)),
        ] {
            var cache = StatusItemImageCache()
            let initial = cache.images(
                snapshot: makeSnapshot(), availableHeight: 22, appearance: light,
                numberCharacters: 3, visibility: StatusItemVisibility())
            let next = cache.images(
                snapshot: snapshot, availableHeight: height, appearance: appearance,
                numberCharacters: width, visibility: visibility)
            XCTAssertFalse(next.normal === initial.normal)
            XCTAssertFalse(next.highlighted === initial.highlighted)
            XCTAssertEqual(cache.renderCount, 2)
        }
    }

    func testHiddenNumberAndWidthChangesDoNotInvalidatePixels() throws {
        var cache = StatusItemImageCache()
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let visibility = StatusItemVisibility(showTokensPerSecond: false)
        let initial = cache.images(
            snapshot: makeSnapshot(), availableHeight: 22, appearance: appearance,
            numberCharacters: 3, visibility: visibility)
        let next = cache.images(
            snapshot: makeSnapshot(number: "999999+"), availableHeight: 22, appearance: appearance,
            numberCharacters: 7, visibility: visibility)
        XCTAssertTrue(initial.normal === next.normal)
        XCTAssertEqual(initial.itemWidth, next.itemWidth)
        XCTAssertEqual(cache.renderCount, 1)
        XCTAssertEqual(cache.layoutCount, 1)
    }

    func testScalarMeterPeakKeepsUnavailableDistinctFromZero() {
        XCTAssertEqual(
            StatusMeterReading.recentPeak(currentValue: 50, sampledPeak: 100),
            StatusMeterReading(currentValue: 50, scaleMaximum: 100))
        XCTAssertEqual(
            StatusMeterReading.recentPeak(currentValue: 120, sampledPeak: 100),
            StatusMeterReading(currentValue: 120, scaleMaximum: 120))
        XCTAssertEqual(
            StatusMeterReading.recentPeak(currentValue: 0, sampledPeak: nil).fillFraction, 0)
        XCTAssertNil(
            StatusMeterReading.recentPeak(currentValue: nil, sampledPeak: 100).fillFraction)
        XCTAssertNil(
            StatusMeterReading.recentPeak(currentValue: .nan, sampledPeak: .infinity).scaleMaximum)
    }

    private func makeSnapshot(
        number: String = "50", tps: Double = 50, gpu: Double = 42, summary: String = "Reading"
    ) -> StatusItemPresentation.Snapshot {
        .init(
            number: number, throughput: StatusMeterReading(currentValue: tps, scaleMaximum: 100),
            gpu: StatusMeterReading.percentage(gpu), accessibilitySummary: summary)
    }
}
