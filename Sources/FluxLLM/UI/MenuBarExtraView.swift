import Observation
import SwiftUI

/// The visible dashboard menu and native context menu share one command list.
enum MenuCommand: CaseIterable, Identifiable {
    case dashboard, settings, about, quit

    var id: Self { self }
    var title: String {
        switch self {
        case .dashboard: "Open Dashboard Window"
        case .settings: "Settings…"
        case .about: "About FluxLLM"
        case .quit: "Quit FluxLLM"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .settings: ","
        case .quit: "q"
        default: ""
        }
    }

    var hasSeparatorBefore: Bool { self == .settings || self == .quit }
}

@Observable
@MainActor
final class MenuActions {
    var onOpenDashboardWindow: () -> Void = {}
    var onShowSettings: () -> Void = {}
    var onShowAbout: () -> Void = {}
    var onQuit: () -> Void = {}

    func perform(_ command: MenuCommand) {
        switch command {
        case .dashboard: onOpenDashboardWindow()
        case .settings: onShowSettings()
        case .about: onShowAbout()
        case .quit: onQuit()
        }
    }
}

struct CommandMenu: View {
    let actions: MenuActions

    var body: some View {
        Menu {
            ForEach(MenuCommand.allCases) { command in
                if command.hasSeparatorBefore { Divider() }
                commandButton(command)
            }
        } label: {
            Label("Application commands", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Dashboard, Settings, About, and Quit")
        .accessibilityLabel("Application commands")
    }

    @ViewBuilder private func commandButton(_ command: MenuCommand) -> some View {
        if let key = command.keyEquivalent.first {
            Button(command.title) { actions.perform(command) }
                .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            Button(command.title) { actions.perform(command) }
        }
    }
}

/// The anchored surface provides a compact summary and a visible dashboard action.
public struct MenuBarExtraView: View {
    private let actions: MenuActions

    public init() {
        actions = MenuActions()
    }

    init(actions: MenuActions) {
        self.actions = actions
    }

    public static let appTitle = "FluxLLM"
    public static let quitTitle = "Quit FluxLLM"

    public static func tpsLabel(tps: Double) -> String {
        String(format: "TPS: %.1f", tps.isFinite ? max(tps, 0) : 0)
    }

    public static func statusLine(store: MetricsStore?) -> String {
        guard let store else { return "Configure" }
        return BackendPresentation.statusTitle(store: store)
    }

    public var body: some View {
        DashboardView(actions: actions, isCompact: true)
    }
}

#Preview {
    MenuBarExtraView()
        .environment(MetricsStore())
}
