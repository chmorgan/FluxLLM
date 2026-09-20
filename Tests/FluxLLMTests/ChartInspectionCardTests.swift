import AppKit
import SwiftUI
import XCTest

@testable import FluxLLM

@MainActor
final class ChartInspectionCardTests: XCTestCase {
    func testNativeCardsKeepTheirFootprintWithLongNamesAndDenseToolActivity() {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let shortRequest = RequestLane(id: UUID(), startedAt: date, model: "model")
        let longRequest = RequestLane(
            id: UUID(), startedAt: date,
            model: "provider/" + String(repeating: "Long-Context-Reasoning-Model-", count: 15),
            outputTokens: Int.max)
        let completedRequest = RequestLane(
            id: UUID(), startedAt: date, endedAt: date.addingTimeInterval(12.4),
            model: "provider/Qwen3-8B", outputTokens: 645, outputIsEstimated: false,
            terminal: true)
        let longCompletedRequest = RequestLane(
            id: UUID(), startedAt: date, endedAt: date.addingTimeInterval(5_400),
            model: longRequest.model, outputTokens: Int.max, outputIsEstimated: false,
            terminal: true)
        let bucket = ToolActivityBucket(
            start: date, end: date.addingTimeInterval(3), callCount: 100,
            callsPerMinute: 2_000,
            toolNames: (0..<100).map { "tool_\($0)_" + String(repeating: "long_name_", count: 15) })
        let results = (0..<100).map { _ in
            ToolActivityEvent(kind: .resultSubmission, timestamp: date)
        }
        let contents = [
            ChartInspectionContent.request(shortRequest, at: date.addingTimeInterval(12.4)),
            ChartInspectionContent.request(longRequest, at: date.addingTimeInterval(12.4)),
            ChartInspectionContent.request(completedRequest, at: date.addingTimeInterval(20)),
            ChartInspectionContent.request(
                longCompletedRequest, at: date.addingTimeInterval(6_000)),
            ChartInspectionContent.plot(at: date, generated: 5_000, gpu: nil, requestCount: 100),
            ChartInspectionContent.tools(at: date, bucket: bucket, results: results),
            ChartInspectionContent.overflow(at: date, lanes: [shortRequest, longRequest]),
        ]

        for scheme in [ColorScheme.light, .dark] {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            for width: CGFloat in [180, 230] {
                for content in contents {
                    let view = NSHostingView(
                        rootView: ChartInspectionCard(
                            content: content, width: width, color: { _ in .primary },
                            hasEffects: true
                        ).environment(\.colorScheme, scheme))
                    view.appearance = appearance
                    let size = view.fittingSize
                    view.setFrameSize(size)
                    view.layoutSubtreeIfNeeded()

                    XCTAssertEqual(size.width, width, accuracy: 1)
                    XCTAssertEqual(
                        size.height, ChartInspectionCard.height(for: content), accuracy: 1,
                        "Card placement must use the actual native height, including row spacing")
                    XCTAssertLessThanOrEqual(
                        size.height, 104,
                        "Even dense activity must fit in one header and at most four detail rows")
                    if content.requestMetrics != nil {
                        XCTAssertEqual(
                            size.height, 50, accuracy: 1,
                            "Requests must stay two lines even with long names, rates, and counters"
                        )
                    }
                }
            }
        }
    }
}
