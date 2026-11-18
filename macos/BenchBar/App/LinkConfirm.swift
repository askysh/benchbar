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
        case .up: ("Start \(bench)?", "Start")
        case .down: ("Stop \(bench)?", "Stop")
        case .restart: ("Restart \(bench)?", "Restart")
        case .console: ("Open a Frappe console for \(bench)?", "Open Terminal")
        case .db: ("Open a database session for \(bench)?", "Open Terminal")
        default: ("Open \(bench)?", "Open")
        }
        return Question(title: title,
                        detail: "A benchbar:// link asked for this. A web page or another app can open such a link, so check that you expected it.",
                        button: button)
    }
}
