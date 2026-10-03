import Foundation
import SwiftUI
import XCTest

@testable import FluxLLM

/// These tests validate a diagnostic drawing hold, not a production optimization
/// or on-screen CPU/GPU cost. New chart publications must still be prepared.
@MainActor
final class HeldStaticChartTests: XCTestCase {
    func testFirstUsableDrawUsesTheLatestPublicationRatherThanAPrelayoutClosure() throws {
        let hold = HeldStaticChartDrawing<Int, Int>()
        let initial = hold.request(key: 1, drawing: 10)
        XCTAssertFalse(initial.resetForKey)
        XCTAssertNil(hold.drawing(for: .zero, generation: initial.generation))
        let next = hold.request(key: 1, drawing: 20)
        XCTAssertTrue(next.applied)
        XCTAssertEqual(next.generation, initial.generation)
        XCTAssertFalse(next.resetForKey)
        XCTAssertEqual(
            try XCTUnwrap(hold.drawing(for: size, generation: next.generation)).drawing, 20)
        XCTAssertFalse(hold.request(key: 1, drawing: 30).applied)
        XCTAssertEqual(
            try XCTUnwrap(hold.drawing(for: size, generation: next.generation)).drawing, 20)
    }

    func testNewPublicationsKeepTheOriginalDrawingUntilTheLayoutChanges() throws {
        let hold = HeldStaticChartDrawing<Int, Int>()
        let initial = hold.request(key: 1, drawing: 101)
        XCTAssertTrue(initial.applied)
        let first = try XCTUnwrap(hold.drawing(for: size, generation: initial.generation))
        XCTAssertEqual(first.drawing, 101)
        XCTAssertFalse(first.resetForSize)

        for revision in 102...110 {
            let requested = hold.request(key: 1, drawing: revision)
            XCTAssertFalse(requested.applied)
            XCTAssertEqual(requested.generation, initial.generation)
            let drawn = try XCTUnwrap(hold.drawing(for: size, generation: initial.generation))
            XCTAssertEqual(drawn.drawing, 101)
            XCTAssertFalse(drawn.resetForSize)
        }

        let resized = try XCTUnwrap(
            hold.drawing(for: CGSize(width: 80, height: 30), generation: initial.generation))
        XCTAssertEqual(resized.drawing, 110, "Resizing must use the latest prepared drawing")
        XCTAssertTrue(resized.resetForSize)
        let next = hold.request(key: 1, drawing: 111)
        XCTAssertFalse(next.applied)
        XCTAssertEqual(next.generation, initial.generation)
        XCTAssertEqual(
            try XCTUnwrap(
                hold.drawing(for: CGSize(width: 80, height: 30), generation: initial.generation)
            ).drawing, 110)
    }

    func testEnvironmentAndCropChangesReleaseTheHoldAndAcceptTheLatestDrawing() throws {
        struct Key: Equatable {
            let environment: NativeGPUChartCanvas.DrawingEnvironment
            let crop: CGRect?
        }
        var environment = EnvironmentValues()
        environment.displayScale = 1
        environment.colorScheme = .light
        let hold = HeldStaticChartDrawing<Key, Int>()
        let key = Key(environment: .init(environment), crop: nil)
        let initial = hold.request(key: key, drawing: 1)
        _ = hold.drawing(for: size, generation: initial.generation)
        XCTAssertFalse(hold.request(key: key, drawing: 2).applied)

        environment.colorScheme = .dark
        environment.displayScale = 2
        let changedEnvironment = Key(environment: .init(environment), crop: nil)
        let environmentRequest = hold.request(key: changedEnvironment, drawing: 3)
        XCTAssertTrue(environmentRequest.applied)
        XCTAssertTrue(environmentRequest.resetForKey)
        XCTAssertNotEqual(environmentRequest.generation, initial.generation)
        XCTAssertEqual(
            try XCTUnwrap(hold.drawing(for: size, generation: environmentRequest.generation))
                .drawing, 3)

        let changedCrop = Key(
            environment: .init(environment), crop: CGRect(x: 3, y: 2, width: 40, height: 20))
        let croppedRequest = hold.request(key: changedCrop, drawing: 4)
        XCTAssertTrue(croppedRequest.applied)
        XCTAssertTrue(croppedRequest.resetForKey)
        XCTAssertNotEqual(croppedRequest.generation, environmentRequest.generation)
        XCTAssertEqual(
            try XCTUnwrap(hold.drawing(for: size, generation: croppedRequest.generation)).drawing, 4
        )
    }

    func testInvalidSizesDoNotApplyAPendingDrawingOrResetTheHold() throws {
        let hold = HeldStaticChartDrawing<Int, Int>()
        let initial = hold.request(key: 1, drawing: 10)
        XCTAssertEqual(
            try XCTUnwrap(hold.drawing(for: size, generation: initial.generation)).drawing, 10)
        _ = hold.request(key: 1, drawing: 20)
        for invalid in [
            CGSize.zero, CGSize(width: -1, height: 20),
            CGSize(width: 20, height: -1), CGSize(width: CGFloat.nan, height: 20),
            CGSize(width: 20, height: CGFloat.infinity),
        ] {
            XCTAssertNil(hold.drawing(for: invalid, generation: initial.generation))
        }
        let unchanged = try XCTUnwrap(hold.drawing(for: size, generation: initial.generation))
        XCTAssertEqual(unchanged.drawing, 10)
        XCTAssertFalse(unchanged.resetForSize)
        XCTAssertEqual(hold.request(key: 1, drawing: 30).generation, initial.generation)
    }

    func testResetReleasesHeldAndPendingDrawingAndReopenGetsANewGeneration() throws {
        let hold = HeldStaticChartDrawing<Int, LifetimeProbe>()
        weak var first: LifetimeProbe?
        weak var pending: LifetimeProbe?
        let initialGeneration: UInt64
        do {
            let drawing = LifetimeProbe()
            first = drawing
            initialGeneration = hold.request(key: 1, drawing: drawing).generation
            _ = hold.drawing(for: size, generation: initialGeneration)
        }
        do {
            let drawing = LifetimeProbe()
            pending = drawing
            _ = hold.request(key: 1, drawing: drawing)
        }
        XCTAssertNotNil(first)
        XCTAssertNotNil(pending)
        hold.reset()
        XCTAssertNil(first)
        XCTAssertNil(pending)
        XCTAssertNil(hold.drawing(for: size, generation: initialGeneration))

        let reopened = hold.request(key: 1, drawing: LifetimeProbe())
        XCTAssertTrue(reopened.applied)
        XCTAssertNotEqual(reopened.generation, initialGeneration)
        XCTAssertNotNil(hold.drawing(for: size, generation: reopened.generation))
        XCTAssertNil(
            hold.drawing(for: size, generation: initialGeneration),
            "Pre-hide callbacks must remain stale")
    }

    func testOnlyOriginalAndLatestPublicationAreRetained() throws {
        var hold: HeldStaticChartDrawing<Int, LifetimeProbe>? = .init()
        weak var first: LifetimeProbe?
        weak var superseded: LifetimeProbe?
        weak var latest: LifetimeProbe?
        do {
            let drawing = LifetimeProbe()
            first = drawing
            let generation = try XCTUnwrap(hold?.request(key: 1, drawing: drawing)).generation
            _ = hold?.drawing(for: size, generation: generation)
        }
        do {
            let drawing = LifetimeProbe()
            superseded = drawing
            _ = hold?.request(key: 1, drawing: drawing)
        }
        do {
            let drawing = LifetimeProbe()
            latest = drawing
            _ = hold?.request(key: 1, drawing: drawing)
        }
        XCTAssertNotNil(first)
        XCTAssertNil(superseded, "Suppression must not accumulate every incoming chart snapshot")
        XCTAssertNotNil(latest)
        hold = nil
        XCTAssertNil(first)
        XCTAssertNil(latest)
    }

    func testOwnerHoldsOnlyTheStaticChartRoleAndKeepsItsOriginalRevision() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeHeldStaticChart)
        for role in PerformanceGraphicsDiagnostics.Role.allCases {
            let owner = NativeGPUChartCanvasOwner(diagnostics: diagnostics)
            let first = prepare(owner, role: role, revision: 10, hold: true)
            if role == .staticChart {
                let generation = try XCTUnwrap(first.heldGeneration)
                XCTAssertNotEqual(first.revision, AnyHashable(10))
                XCTAssertNotNil(owner.heldDrawing(for: size, generation: generation))
                let next = prepare(owner, role: role, revision: 20, hold: true)
                XCTAssertEqual(next.revision, first.revision)
                XCTAssertEqual(next.heldGeneration, first.heldGeneration)
            } else {
                XCTAssertEqual(first.revision, AnyHashable(10))
                XCTAssertNil(first.heldGeneration)
                let next = prepare(owner, role: role, revision: 20, hold: true)
                XCTAssertEqual(next.revision, AnyHashable(20))
                XCTAssertNil(next.heldGeneration)
            }
            owner.stop()
        }
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 0)
    }

    func testNormalControlPreservesEveryRoleRevisionAndDoesNotRetainDrawing() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .normal)
        for role in PerformanceGraphicsDiagnostics.Role.allCases {
            let owner = NativeGPUChartCanvasOwner(diagnostics: diagnostics)
            weak var retained: LifetimeProbe?
            do {
                let probe = LifetimeProbe()
                retained = probe
                let first = prepare(owner, role: role, revision: 10, hold: false) { _, _ in
                    withExtendedLifetime(probe) {}
                }
                XCTAssertEqual(first.revision, AnyHashable(10))
                XCTAssertNil(first.heldGeneration)
            }
            XCTAssertNil(retained)
            let next = prepare(owner, role: role, revision: 20, hold: false)
            XCTAssertEqual(next.revision, AnyHashable(20))
            XCTAssertNil(next.heldGeneration)
            owner.stop()
        }
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 0)
    }

    func testHideReopenAndStopReleasePayloadsAndRejectOldCallbacks() throws {
        let diagnostics = PerformanceGraphicsDiagnostics()
        try diagnostics.enable(mode: .runtimeHeldStaticChart)
        let owner = NativeGPUChartCanvasOwner(diagnostics: diagnostics)
        owner.appeared(role: .staticChart)
        weak var held: LifetimeProbe?
        let firstGeneration: UInt64
        do {
            let probe = LifetimeProbe()
            held = probe
            let first = prepare(owner, revision: 10, hold: true) { _, _ in
                withExtendedLifetime(probe) {}
            }
            firstGeneration = try XCTUnwrap(first.heldGeneration)
            XCTAssertNotNil(owner.heldDrawing(for: size, generation: firstGeneration))
        }
        XCTAssertNotNil(held)
        owner.disappeared()
        XCTAssertNil(held)
        XCTAssertNil(owner.heldDrawing(for: size, generation: firstGeneration))
        XCTAssertNil(prepare(owner, revision: 20, hold: true).heldGeneration)
        XCTAssertEqual(diagnostics.snapshot()["live_canvases"] as? UInt64, 0)

        owner.appeared(role: .staticChart)
        let reopened = prepare(owner, revision: 30, hold: true)
        let reopenedGeneration = try XCTUnwrap(reopened.heldGeneration)
        XCTAssertNotEqual(reopenedGeneration, firstGeneration)
        XCTAssertNil(owner.heldDrawing(for: size, generation: firstGeneration))
        XCTAssertNotNil(owner.heldDrawing(for: size, generation: reopenedGeneration))
        owner.stop()
        owner.appeared(role: .staticChart)
        XCTAssertNil(owner.heldDrawing(for: size, generation: reopenedGeneration))
        XCTAssertNil(prepare(owner, revision: 40, hold: true).heldGeneration)
        XCTAssertEqual(diagnostics.snapshot()["live_canvases"] as? UInt64, 0)
        XCTAssertEqual(diagnostics.snapshot()["invalid_events"] as? UInt64, 0)
    }

    func testChangingRolesDropsTheHeldPayloadAndReturningStartsFresh() throws {
        let owner = NativeGPUChartCanvasOwner(diagnostics: PerformanceGraphicsDiagnostics())
        weak var held: LifetimeProbe?
        let firstGeneration: UInt64
        do {
            let probe = LifetimeProbe()
            held = probe
            let first = prepare(owner, revision: 10, hold: true) { _, _ in
                withExtendedLifetime(probe) {}
            }
            firstGeneration = try XCTUnwrap(first.heldGeneration)
            XCTAssertNotNil(owner.heldDrawing(for: size, generation: firstGeneration))
        }
        XCTAssertNotNil(held)
        XCTAssertNil(prepare(owner, role: .cursor, revision: 20, hold: true).heldGeneration)
        XCTAssertNil(held)
        XCTAssertNil(owner.heldDrawing(for: size, generation: firstGeneration))
        let next = prepare(owner, revision: 30, hold: true)
        XCTAssertNotEqual(try XCTUnwrap(next.heldGeneration), firstGeneration)
        owner.stop()
    }

    private func prepare(
        _ owner: NativeGPUChartCanvasOwner,
        role: PerformanceGraphicsDiagnostics.Role = .staticChart,
        revision: Int, hold: Bool, drawing: @escaping ChartCanvas.Drawing = { _, _ in }
    ) -> NativeGPUChartCanvasOwner.PreparedDrawing {
        owner.prepareDrawing(
            role: role, revision: AnyHashable(revision), drawingBounds: nil,
            environment: .init(EnvironmentValues()), drawing: drawing, holdStatic: hold)
    }

    private let size = CGSize(width: 40, height: 20)

    private final class LifetimeProbe {}
}
