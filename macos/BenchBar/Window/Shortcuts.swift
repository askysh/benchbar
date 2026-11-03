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

/// The "Open as…" shortcuts of the popover, for the default site while its
/// menu shows. Kept out of `BenchShortcut`: ⇧⌘O and the digits are a family,
/// not one key each.
nonisolated enum OpenAsShortcut: Equatable, Sendable {
    case switchBack
    /// 0 is Administrator, 1 to 9 the pins in menu order.
    case openAs(Int)

    var key: Character {
        switch self {
        case .switchBack: "o"
        case .openAs(let digit): Character(String(digit))
        }
    }

    var usesShift: Bool { self == .switchBack }

    /// "⇧⌘O", "⌘2"
    var display: String { (usesShift ? "⇧" : "") + "⌘" + String(key).uppercased() }

    /// What Settings lists for the family.
    static let summary = "⌘0  ⌘1–⌘9  \(OpenAsShortcut.switchBack.display)"
}

extension View {
    func shortcut(_ shortcut: OpenAsShortcut) -> some View {
        keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: shortcut.usesShift ? [.command, .shift] : .command)
    }
}
