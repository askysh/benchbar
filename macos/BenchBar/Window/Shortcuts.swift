import SwiftUI

/// The popover's keyboard shortcuts, in one table: the buttons bind their
/// key from here, their tooltips and Settings list it, so they cannot drift.
nonisolated enum BenchShortcut: String, CaseIterable, Sendable {
    case start, stop, restart, openSite, logs, folder, health, manage

    var key: Character {
        switch self {
        case .start: "u"
        case .stop: "d"
        case .restart: "r"
        case .openSite: "o"
        case .logs: "l"
        case .folder: "f"
        case .health: "k"
        case .manage: "m"
        }
    }

    var action: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        case .openSite: "Open the site"
        case .logs: "Logs"
        case .folder: "Show in Finder"
        case .health: "View Health"
        case .manage: "Apps, sites and settings"
        }
    }

    /// "⌘U"
    var display: String { "⌘" + String(key).uppercased() }

    /// "Start (⌘U)", or `text` when the tooltip says more than the action.
    func help(_ text: String? = nil) -> String { "\(text ?? action) (\(display))" }

    var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }
}

extension View {
    /// The shortcut on the button, from the table.
    func shortcut(_ shortcut: BenchShortcut) -> some View {
        keyboardShortcut(shortcut.keyEquivalent, modifiers: .command)
    }
}
