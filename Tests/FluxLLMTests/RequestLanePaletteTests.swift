import Foundation
import SwiftUI
import XCTest

@testable import FluxLLM

final class RequestLanePaletteTests: XCTestCase {
    func testNativeColorsMatchTheApprovedPreviewInBothSchemes() throws {
        let previewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("design/fluxllm/previews/request-signal-rails.html")
        let preview = try String(contentsOf: previewURL, encoding: .utf8)
        // The standalone preview also defines theme colors. Compare only the
        // request fixture so surface/text colors cannot shift these ordinals.
        let start = try XCTUnwrap(preview.range(of: "const requests=["))
        let end = try XCTUnwrap(preview.range(of: "];", range: start.upperBound..<preview.endIndex))
        let requestDefinitions = String(preview[start.upperBound..<end.lowerBound])
        let pattern = try NSRegularExpression(
            pattern: #"light-dark\(#([0-9a-fA-F]{6}),#([0-9a-fA-F]{6})\)"#)
        let matches = pattern.matches(
            in: requestDefinitions,
            range: NSRange(requestDefinitions.startIndex..., in: requestDefinitions))
        XCTAssertEqual(matches.count, 10, "The approved preview defines ten request colors.")

        for (ordinal, match) in matches.enumerated() {
            for (capture, scheme) in [(1, ColorScheme.light), (2, ColorScheme.dark)] {
                let range = try XCTUnwrap(Range(match.range(at: capture), in: requestDefinitions))
                let rgb = try XCTUnwrap(UInt32(requestDefinitions[range], radix: 16))
                let expected = Color(
                    .sRGB,
                    red: Double((rgb >> 16) & 0xFF) / 255,
                    green: Double((rgb >> 8) & 0xFF) / 255,
                    blue: Double(rgb & 0xFF) / 255)
                XCTAssertEqual(
                    RequestLanePalette.color(at: ordinal, scheme: scheme), expected,
                    "Request \(ordinal + 1) must retain its approved \(scheme) color.")
            }
        }
    }

    func testRetainedRequestOrdinalsCycleWithoutChangingThePalette() {
        for scheme in [ColorScheme.light, .dark] {
            for ordinal in 0..<10 {
                XCTAssertEqual(
                    RequestLanePalette.color(at: ordinal + 10, scheme: scheme),
                    RequestLanePalette.color(at: ordinal, scheme: scheme))
                XCTAssertEqual(
                    RequestLanePalette.color(at: ordinal + 10_000, scheme: scheme),
                    RequestLanePalette.color(at: ordinal, scheme: scheme))
            }
        }
    }
}
