import Foundation
import XCTest

@testable import FluxLLM

@MainActor
final class DashboardMetricDiagnosticsTests: XCTestCase {
    private typealias Diagnostics = PerformanceGraphicsDiagnostics

    func testIndependentCallbacksMergeOnlyActuallyPresentedLabels() throws {
        let diagnostics = Diagnostics()
        let owner = UUID()
        try diagnostics.enable(mode: .normal)
        diagnostics.recordScalarLeafBody(.metrics, owner: owner)
        diagnostics.recordScalarMetricBody(.rate, owner: owner, value: "12.3")
        XCTAssertNil(try presented(diagnostics, owner: owner)["metrics"])
        diagnostics.recordScalarMetricBody(.gpu, owner: owner, value: "42")
        XCTAssertEqual(
            try presented(diagnostics, owner: owner)["metrics"] as? [String: String],
            ["rate": "12.3", "gpu": "42"])
        diagnostics.recordScalarMetricBody(.rate, owner: owner, value: "14.5")
        XCTAssertEqual(
            try presented(diagnostics, owner: owner)["metrics"] as? [String: String],
            ["rate": "14.5", "gpu": "42"])
        XCTAssertEqual(try counts(diagnostics), ["rate": 2, "gpu": 1])
        XCTAssertEqual(try counts(diagnostics, owner: owner), ["rate": 2, "gpu": 1])
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 0)
    }

    func testOwnersCannotBorrowAnotherOwnersDisplayedValue() throws {
        let diagnostics = Diagnostics()
        let first = UUID()
        let second = UUID()
        try diagnostics.enable(mode: .normal)
        for owner in [first, second] { diagnostics.recordScalarLeafBody(.metrics, owner: owner) }
        diagnostics.recordScalarMetricBody(.rate, owner: first, value: "1.0")
        diagnostics.recordScalarMetricBody(.gpu, owner: second, value: "42")
        XCTAssertNil(try presented(diagnostics, owner: first)["metrics"])
        XCTAssertNil(try presented(diagnostics, owner: second)["metrics"])
        diagnostics.recordScalarMetricBody(.gpu, owner: first, value: "13")
        XCTAssertEqual(
            try presented(diagnostics, owner: first)["metrics"] as? [String: String],
            ["rate": "1.0", "gpu": "13"])
        XCTAssertEqual(try counts(diagnostics), ["rate": 1, "gpu": 2])
    }

    func testReleasedOwnerCannotResurrectAndFreshOwnerNeedsBothFields() throws {
        let diagnostics = Diagnostics()
        let owner = UUID()
        try diagnostics.enable(mode: .normal)
        diagnostics.recordScalarLeafBody(.metrics, owner: owner)
        diagnostics.recordScalarMetricBody(.rate, owner: owner, value: "1.0")
        diagnostics.recordScalarMetricBody(.gpu, owner: owner, value: "42")
        diagnostics.frozenScalarPresentationReleased(owner: owner)
        let before = try counts(diagnostics)
        diagnostics.recordScalarMetricBody(.rate, owner: owner, value: "9.0")
        XCTAssertEqual(try counts(diagnostics), before)
        XCTAssertTrue(try owners(diagnostics).isEmpty)
        diagnostics.recordScalarLeafBody(.metrics, owner: owner)
        diagnostics.recordScalarMetricBody(.rate, owner: owner, value: "2.0")
        XCTAssertNil(try presented(diagnostics, owner: owner)["metrics"])
        diagnostics.recordScalarMetricBody(.gpu, owner: owner, value: "42")
        XCTAssertEqual(
            try presented(diagnostics, owner: owner)["metrics"] as? [String: String],
            ["rate": "2.0", "gpu": "42"])
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 1)
    }

    func testOversizedOrUnknownOwnerCallbacksCannotMutateWorkOrReceipts() throws {
        let diagnostics = Diagnostics()
        let owner = UUID()
        try diagnostics.enable(mode: .normal)
        diagnostics.recordScalarLeafBody(.metrics, owner: owner)
        diagnostics.recordScalarMetricBody(
            .rate, owner: owner, value: String(repeating: "é", count: 2049))
        diagnostics.recordScalarMetricBody(.gpu, owner: UUID(), value: "42")
        XCTAssertEqual(try counts(diagnostics), ["rate": 0, "gpu": 0])
        XCTAssertTrue(try presented(diagnostics, owner: owner).isEmpty)
        XCTAssertEqual(try owners(diagnostics).count, 1)
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 2)
    }

    func testDisabledUnrelatedAndFrozenModesKeepTheirExistingWitnessPolicy() throws {
        let disabled = Diagnostics()
        let owner = UUID()
        let initial = disabled.snapshot() as NSDictionary
        disabled.recordScalarMetricBody(.rate, owner: owner, value: "1.0")
        XCTAssertEqual(disabled.snapshot() as NSDictionary, initial)
        for mode in Diagnostics.Mode.allCases {
            let diagnostics = Diagnostics()
            try diagnostics.enable(mode: mode)
            diagnostics.recordScalarLeafBody(.metrics, owner: owner)
            diagnostics.recordScalarMetricBody(.rate, owner: owner, value: "1.0")
            diagnostics.recordScalarMetricBody(.gpu, owner: owner, value: "42")
            let instrumented = [
                .normal, .runtimeFrozenScalars, .runtimeHeldUsage, .runtimeRetainedUsage,
            ].contains(mode)
            XCTAssertEqual(
                try counts(diagnostics),
                ["rate": instrumented ? 1 : 0, "gpu": instrumented ? 1 : 0])
            if instrumented {
                let witness = try presented(diagnostics, owner: owner)["metrics"]
                XCTAssertEqual(witness != nil, mode != .runtimeFrozenScalars)
            }
            diagnostics.frozenScalarPresentationReleased(owner: owner)
            try diagnostics.disable()
            XCTAssertEqual(diagnostics.snapshot() as NSDictionary, initial)
        }
    }

    private func scalar(_ diagnostics: Diagnostics) throws -> [String: Any] {
        try XCTUnwrap(diagnostics.snapshot()["scalar_presentation"] as? [String: Any])
    }

    private func owners(_ diagnostics: Diagnostics) throws -> [String: [String: Any]] {
        try XCTUnwrap(try scalar(diagnostics)["presentation_owners"] as? [String: [String: Any]])
    }

    private func counts(_ diagnostics: Diagnostics, owner: UUID? = nil) throws -> [String: UInt64] {
        let receipt: [String: Any]
        if let owner {
            receipt = try XCTUnwrap(try owners(diagnostics)[owner.uuidString])
        } else {
            receipt = try scalar(diagnostics)
        }
        return try XCTUnwrap(receipt["metric_body_updates"] as? [String: UInt64])
    }

    private func presented(_ diagnostics: Diagnostics, owner: UUID) throws -> [String: Any] {
        try XCTUnwrap(
            try owners(diagnostics)[owner.uuidString]?["presented_values"] as? [String: Any])
    }
}
