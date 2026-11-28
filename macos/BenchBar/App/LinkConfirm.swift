import Foundation

/// The optional confirm for a benchbar:// link that starts, stops or restarts a bench or opens a
/// console (Settings, "Ask before a link acts", off by default). Any web page or app can open
/// such a link, and a browser's "always allow" removes its own question, so this is the app's.
/// Pure: the alert itself is shown by the app delegate.
nonisolated enum LinkConfirm {
    /// The routes that act on a bench. The others only show a window, a log or a page.
    static func needsAsking(_ route: URLRouter.Route, setting: Bool) -> Bool {
        guard setting else { return false }
        switch route {
        case .up, .down, .restart, .console, .db: return true
        case .open, .logs, .window, .doctor, .editor: return false
        }
    }

    struct Question: Equatable, Sendable {
        var title: String
        var detail: String
        var button: String
    }

    static func question(_ route: URLRouter.Route, bench: String) -> Question {
        let (title, button): (String, String) = switch route {
        case .up: (String(localized: "Start \(bench)?"), String(localized: "Start"))
        case .down: (String(localized: "Stop \(bench)?"), String(localized: "Stop"))
        case .restart: (String(localized: "Restart \(bench)?"), String(localized: "Restart"))
        case .console: (String(localized: "Open a Frappe console for \(bench)?"), String(localized: "Open Terminal"))
        case .db: (String(localized: "Open a database session for \(bench)?"), String(localized: "Open Terminal"))
        default: (String(localized: "Open \(bench)?"), String(localized: "Open"))
        }
        return Question(title: title,
                        detail: String(localized: "A benchbar:// link asked for this. A web page or another app can open such a link, so check that you expected it."),
                        button: button)
    }
}
