import AppKit
import SwiftUI
import XCTest

@testable import FluxLLM

/// Exercise the production Layout through SwiftUI's native sizing and placement
/// passes. The measured children expose whether extra window height reaches the
/// plot, without duplicating the Layout's size calculations in the test.
@MainActor
final class DashboardStackLayoutTests: XCTestCase {
    func testTallerWindowGrowsThePlotWhileChromeKeepsItsIntrinsicHeight() throws {
        let normal = try measure(width: 740, height: 600)
        let tall = try measure(width: 740, height: 1000)

        for key in ["header", "summary", "chart-label", "footer"] {
            XCTAssertEqual(
                try frame(key, in: normal).height, try frame(key, in: tall).height,
                accuracy: 0.5, "\(key) must retain its intrinsic height")
        }
        XCTAssertGreaterThan(
            try frame("plot", in: tall).height, try frame("plot", in: normal).height + 250,
            "A taller viewport must give its additional space to the chart")
        XCTAssertEqual(
            try frame("content", in: tall).maxY, 1000, accuracy: 1,
            "Content should fill the taller viewport, rather than ending above blank space")
        XCTAssertEqual(
            try frame("plot", in: normal).width, try frame("plot", in: tall).width,
            accuracy: 0.5)
    }

    func testShrinkingViewportShrinksPlotAndKeepsFooterInsideContent() throws {
        let small = try measure(width: 740, height: 450)
        let normal = try measure(width: 740, height: 600)

        XCTAssertGreaterThanOrEqual(try frame("plot", in: small).height, 128)
        XCTAssertEqual(try frame("content", in: small).height, 450, accuracy: 0.5)
        XCTAssertLessThanOrEqual(try frame("footer", in: small).maxY, 450)
        XCTAssertEqual(
            try frame("plot", in: normal).height - frame("plot", in: small).height,
            150, accuracy: 0.5, "The flexible plot must absorb the height reduction")
        XCTAssertEqual(
            try frame("header", in: small).height, try frame("header", in: normal).height,
            accuracy: 0.5)
    }

    func testWideWindowAddsPlotWidthWithoutStretchingTheHeaderOrPlotHeight() throws {
        let normal = try measure(width: 740, height: 600)
        let wide = try measure(width: 1100, height: 600)

        XCTAssertGreaterThan(
            try frame("plot", in: wide).width, try frame("plot", in: normal).width + 300)
        XCTAssertEqual(
            try frame("plot", in: wide).height, try frame("plot", in: normal).height,
            accuracy: 0.5)
        XCTAssertEqual(
            try frame("header", in: wide).height, try frame("header", in: normal).height,
            accuracy: 0.5)
    }

    private func measure(width: CGFloat, height: CGFloat) throws -> [String: CGRect] {
        _ = NSApplication.shared
        let measurements = LayoutMeasurements()
        let view = NSHostingView(rootView: DashboardLayoutProbe(measurements: measurements))
        view.sizingOptions = []
        view.setFrameSize(NSSize(width: width, height: height))
        // Preference updates may be delivered on the next run-loop turn, after
        // AppKit has supplied the host's final bounds to the GeometryReader.
        for _ in 0..<5 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(view.bounds.size, NSSize(width: width, height: height))
        XCTAssertEqual(
            Set(measurements.frames.keys),
            ["header", "summary", "chart-label", "plot", "footer", "content"])
        return measurements.frames
    }

    private func frame(_ key: String, in frames: [String: CGRect]) throws -> CGRect {
        try XCTUnwrap(frames[key], "SwiftUI did not report the \(key) frame")
    }
}

@MainActor
private final class LayoutMeasurements {
    var frames: [String: CGRect] = [:]
}

private struct DashboardLayoutProbe: View {
    let measurements: LayoutMeasurements

    var body: some View {
        GeometryReader { geometry in
            DashboardStackLayout(spacing: 18) {
                Text("FluxLLM")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 42)
                    .recordFrame("header")
                Text("42.0 tok/s")
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .frame(height: 80)
                    .recordFrame("summary")
                VStack(alignment: .leading, spacing: 8) {
                    Text("LLM GPU activity")
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize()
                        .recordFrame("chart-label")
                    Rectangle()
                        .fill(.cyan)
                        .frame(minHeight: 128, maxHeight: .infinity)
                        .recordFrame("plot")
                }
                .padding(12)
                .layoutValue(key: DashboardFlexibleRow.self, value: true)
                Text("GPU time for the selected backend")
                    .font(.system(size: 11))
                    .frame(height: 30)
                    .recordFrame("footer")
            }
            .padding(20)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .recordFrame("content")
            .coordinateSpace(name: "dashboard-layout-probe")
            .onPreferenceChange(DashboardFramesPreference.self) { frames in
                Task { @MainActor in measurements.frames = frames }
            }
        }
    }
}

private struct DashboardFramesPreference: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    fileprivate func recordFrame(_ name: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: DashboardFramesPreference.self,
                    value: [name: geometry.frame(in: .named("dashboard-layout-probe"))])
            }
        }
    }
}
