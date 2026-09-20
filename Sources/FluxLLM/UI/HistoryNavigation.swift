import Foundation
import SwiftUI

/// Tracks a moving history window independently from a pinned inspection interval.
struct HistoryNavigation: Equatable, Sendable {
    static let maximumDuration: TimeInterval = 86_400

    private(set) var preset: HistoryRange
    private(set) var pinnedInterval: DateInterval?
    private var selectedDuration: TimeInterval?

    init(preset: HistoryRange = .automatic) {
        self.preset = preset
    }

    var isLive: Bool { pinnedInterval == nil }

    func interval(now: Date, historyAge: TimeInterval) -> DateInterval {
        if let pinnedInterval { return Self.bounded(pinnedInterval, now: now) }
        let duration = selectedDuration ?? preset.duration(historyAge: historyAge)
        return Self.bounded(DateInterval(end: now, duration: duration), now: now)
    }

    /// Relative presets resume a moving window. Custom starts from the current view.
    mutating func selectPreset(_ range: HistoryRange, now: Date, historyAge: TimeInterval) {
        if range == .custom {
            select(interval(now: now, historyAge: historyAge), now: now)
            return
        }
        preset = range
        selectedDuration = nil
        pinnedInterval = nil
    }

    mutating func select(_ interval: DateInterval, now: Date) {
        let bounded = Self.bounded(interval, now: now)
        preset = .custom
        pinnedInterval = bounded
        selectedDuration = bounded.duration
    }

    /// Validates explicitly entered dates instead of silently changing the user's range.
    @discardableResult
    mutating func selectCustom(start: Date, end: Date, now: Date) -> Bool {
        guard Self.customRangeError(start: start, end: end, now: now) == nil else {
            return false
        }
        select(DateInterval(start: start, end: end), now: now)
        return true
    }

    mutating func pan(by fraction: Double, now: Date, historyAge: TimeInterval) {
        guard fraction.isFinite else { return }
        let current = interval(now: now, historyAge: historyAge)
        let offset = current.duration * fraction
        guard offset.isFinite else { return }
        let shifted = DateInterval(
            start: current.start.addingTimeInterval(offset), duration: current.duration)
        pinnedInterval = Self.bounded(shifted, now: now)
        selectedDuration = current.duration
    }

    mutating func goLive() {
        if let pinnedInterval { selectedDuration = pinnedInterval.duration }
        pinnedInterval = nil
    }

    mutating func fit(_ lane: RequestLane, now: Date) {
        let start = lane.startedAt
        let end = lane.endedAt ?? now
        guard start.timeIntervalSinceReferenceDate.isFinite,
            end.timeIntervalSinceReferenceDate.isFinite
        else { return }
        let duration = max(0, end.timeIntervalSince(start))
        let padding = max(1, duration * 0.1)
        select(
            DateInterval(
                start: start.addingTimeInterval(-padding), duration: duration + padding * 2),
            now: now)
    }

    static func customRangeError(start: Date, end: Date, now: Date) -> String? {
        guard start.timeIntervalSinceReferenceDate.isFinite,
            end.timeIntervalSinceReferenceDate.isFinite,
            now.timeIntervalSinceReferenceDate.isFinite
        else { return "Enter valid start and end dates." }
        guard end > start else { return "End must be after start." }
        guard end <= now else { return "End cannot be in the future." }
        guard start >= now.addingTimeInterval(-maximumDuration) else {
            return "Choose a range within the last 24 hours."
        }
        guard end.timeIntervalSince(start) >= 1 else {
            return "Choose a range of at least one second."
        }
        return nil
    }

    private static func bounded(_ interval: DateInterval, now: Date) -> DateInterval {
        let latest =
            now.timeIntervalSinceReferenceDate.isFinite ? now : Date(timeIntervalSince1970: 0)
        let rawDuration = interval.duration
        let duration = rawDuration.isFinite ? min(max(rawDuration, 1), maximumDuration) : 60
        let earliestEnd = latest.addingTimeInterval(-maximumDuration + duration)
        let requestedEnd =
            interval.end.timeIntervalSinceReferenceDate.isFinite ? interval.end : latest
        let end = min(latest, max(earliestEnd, requestedEnd))
        return DateInterval(start: end.addingTimeInterval(-duration), duration: duration)
    }
}

extension DateInterval {
    fileprivate init(end: Date, duration: TimeInterval) {
        self.init(start: end.addingTimeInterval(-duration), duration: duration)
    }
}

/// Native range controls stay on one compact row, including in the narrow dashboard.
struct HistoryControls: View {
    @Binding var navigation: HistoryNavigation
    let now: Date
    let historyAge: TimeInterval
    let narrow: Bool

    @State private var showingCustomRange = false
    @State private var draftStart = Date()
    @State private var draftEnd = Date()

    private var current: DateInterval { navigation.interval(now: now, historyAge: historyAge) }

    var body: some View {
        HStack(spacing: narrow ? 5 : 8) {
            Text("History").font(narrow ? .subheadline.weight(.semibold) : .headline)
            Spacer(minLength: 4)
            Menu {
                ForEach(HistoryRange.allCases) { range in
                    Button(range.title) { choose(range) }
                }
            } label: {
                Text(navigation.preset.title).frame(minWidth: 44, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("History range")
            .accessibilityValue(navigation.preset.title)
            .help("Choose a time range. Auto expands as history accumulates, up to 24 hours.")
            .popover(isPresented: $showingCustomRange, arrowEdge: .bottom) { customRangeForm }

            Button {
                navigation.pan(by: -0.5, now: now, historyAge: historyAge)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(current.start <= now.addingTimeInterval(-HistoryNavigation.maximumDuration))
            .keyboardShortcut(.leftArrow, modifiers: [.option])
            .accessibilityLabel("Earlier history")
            .help("Move half a window earlier (Option–Left Arrow).")

            Button {
                navigation.pan(by: 0.5, now: now, historyAge: historyAge)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(current.end >= now)
            .keyboardShortcut(.rightArrow, modifiers: [.option])
            .accessibilityLabel("Later history")
            .help("Move half a window later (Option–Right Arrow).")

            Button("Live") { navigation.goLive() }
                .disabled(navigation.isLive)
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .accessibilityLabel(
                    navigation.isLive ? "Following live history" : "Return to live history"
                )
                .help("Follow new activity using the current window duration (Shift–Command–L).")
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history-controls")
    }

    private var customRangeForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom range").font(.headline)
            DatePicker(
                "Start", selection: $draftStart, displayedComponents: [.date, .hourAndMinute])
            DatePicker("End", selection: $draftEnd, displayedComponents: [.date, .hourAndMinute])
            if let error = HistoryNavigation.customRangeError(
                start: draftStart, end: draftEnd, now: now)
            {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Choose an interval within the last 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingCustomRange = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if navigation.selectCustom(start: draftStart, end: draftEnd, now: now) {
                        showingCustomRange = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    HistoryNavigation.customRangeError(start: draftStart, end: draftEnd, now: now)
                        != nil)
            }
        }
        .padding(16)
        .frame(width: 310)
    }

    private func choose(_ range: HistoryRange) {
        if range == .custom {
            draftStart = current.start
            draftEnd = current.end
            showingCustomRange = true
        } else {
            navigation.selectPreset(range, now: now, historyAge: historyAge)
        }
    }
}
