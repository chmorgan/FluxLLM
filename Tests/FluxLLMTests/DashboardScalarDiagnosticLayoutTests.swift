import AppKit
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class DashboardScalarDiagnosticLayoutTests: XCTestCase {
    func testInstrumentationPreservesNativeFixedAndFlexibleRowGeometryInBothModes() throws {
        let normal = try frames(mode: .normal, size: CGSize(width: 740, height: 600))
        let held = try frames(mode: .runtimeFrozenScalars, size: CGSize(width: 740, height: 600))
        XCTAssertEqual(held.frames, normal.frames)
        for capture in [normal, held] {
            XCTAssertGreaterThan(capture.sizeCalls, 0)
            XCTAssertGreaterThan(capture.placeCalls, 0)
            XCTAssertGreaterThanOrEqual(
                capture.measurements, 2 * (capture.sizeCalls + capture.placeCalls))
        }
        let taller = try frames(mode: .runtimeFrozenScalars, size: CGSize(width: 740, height: 900))
        XCTAssertEqual(taller.frames["fixed"], held.frames["fixed"])
        XCTAssertEqual(
            try XCTUnwrap(taller.frames["flexible"]).height
                - XCTUnwrap(held.frames["flexible"]).height, 300, accuracy: 0.5)
    }

    func testUnspecifiedWidthCountsBothIntrinsicAndFinalChildMeasurements() throws {
        try PerformanceGraphicsDiagnostics.shared.enable(mode: .normal)
        defer { try? PerformanceGraphicsDiagnostics.shared.disable() }
        let renderer = ImageRenderer(
            content:
                DashboardStackLayout(
                    spacing: 8,
                    layoutCounters: PerformanceGraphicsDiagnostics.shared
                        .layoutCountersForPresentation
                ) {
                    Color.red.frame(width: 70, height: 20)
                    Color.blue.frame(width: 120, height: 30)
                })
        renderer.proposedSize = .unspecified
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 58)
        let sizes = try counter("layout_size_calls")
        let places = try counter("layout_place_calls")
        let measurements = try counter("layout_child_measurements")
        XCTAssertGreaterThan(sizes, 0)
        XCTAssertGreaterThan(
            measurements, 2 * (sizes + places),
            "Unspecified sizing must also count the first intrinsic-width query for every child")
    }

    func testOrdinaryDisabledLayoutHasNoDiagnosticSideEffects() throws {
        try PerformanceGraphicsDiagnostics.shared.disable()
        let before = PerformanceGraphicsDiagnostics.shared.snapshot() as NSDictionary
        let renderer = ImageRenderer(
            content: DashboardStackLayout(
                spacing: 8,
                layoutCounters: PerformanceGraphicsDiagnostics.shared.layoutCountersForPresentation
            ) {
                Color.red.frame(width: 70, height: 20)
                Color.blue.frame(width: 120, height: 30)
            })
        renderer.proposedSize = .unspecified
        XCTAssertNotNil(renderer.cgImage)
        XCTAssertEqual(PerformanceGraphicsDiagnostics.shared.snapshot() as NSDictionary, before)
    }

    private struct Capture {
        let frames: [String: CGRect]
        let sizeCalls: UInt64
        let placeCalls: UInt64
        let measurements: UInt64
    }

    private func frames(mode: PerformanceGraphicsDiagnostics.Mode, size: CGSize) throws -> Capture {
        _ = NSApplication.shared
        try PerformanceGraphicsDiagnostics.shared.enable(mode: mode)
        defer { try? PerformanceGraphicsDiagnostics.shared.disable() }
        let measurements = ScalarLayoutFrameMeasurements()
        var host: NSHostingView<ScalarLayoutFrameProbe>? = NSHostingView(
            rootView: ScalarLayoutFrameProbe(measurements: measurements))
        host!.sizingOptions = []
        host!.setFrameSize(size)
        for _ in 0..<5 {
            host!.needsLayout = true
            host!.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(Set(measurements.frames.keys), ["fixed", "flexible"])
        let result = try Capture(
            frames: measurements.frames,
            sizeCalls: counter("layout_size_calls"), placeCalls: counter("layout_place_calls"),
            measurements: counter("layout_child_measurements"))
        host = nil
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return result
    }

    private func counter(_ key: String) throws -> UInt64 {
        let namespace = try XCTUnwrap(
            PerformanceGraphicsDiagnostics.shared.snapshot()["scalar_presentation"]
                as? [String: Any])
        return try XCTUnwrap(namespace[key] as? NSNumber, "Missing \(key)").uint64Value
    }
}

@MainActor
private final class ScalarLayoutFrameMeasurements {
    var frames: [String: CGRect] = [:]
}

private struct ScalarLayoutFramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct ScalarLayoutFrameProbe: View {
    let measurements: ScalarLayoutFrameMeasurements
    var body: some View {
        GeometryReader { viewport in
            DashboardStackLayout(
                spacing: 8,
                layoutCounters: PerformanceGraphicsDiagnostics.shared.layoutCountersForPresentation
            ) {
                Color.red.frame(height: 40).scalarLayoutFrame("fixed")
                Color.blue.frame(minHeight: 100, maxHeight: .infinity)
                    .layoutValue(key: DashboardFlexibleRow.self, value: true)
                    .scalarLayoutFrame("flexible")
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .coordinateSpace(name: "scalar-layout-test")
            .onPreferenceChange(ScalarLayoutFramePreference.self) { frames in
                Task { @MainActor in measurements.frames = frames }
            }
        }
    }
}

extension View {
    fileprivate func scalarLayoutFrame(_ key: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ScalarLayoutFramePreference.self,
                    value: [key: geometry.frame(in: .named("scalar-layout-test"))])
            }
        }
    }
}
