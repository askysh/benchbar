import Foundation

/// When quitting needs a question, and what it says. Pure, so the rules are
/// tested without an NSAlert or a running share (MAC-13, taken out of
/// `AppDelegate.applicationShouldTerminate`, which only asks and carries out).
nonisolated enum QuitPolicy {
    struct Facts: Equatable {
        /// The lan-rooms lab is on. With it off, nothing of sharing asks.
        var labOn: Bool
        /// A share setup or teardown is running (quitting stops it halfway).
        var setupRunning: Bool
        /// The first bench path that hosts guests, and how many people are in its room.
        var hostedBench: String?
        var people: Int = 0
        /// A guest forwarder to a joined room is up.
        var guestForwarder: Bool
        /// A change holds the CLI: an install, repair, app update, site change,
        /// port setup or hosts line, or a start, stop or restart. Named for the
        /// person ("Installing macdev", "Starting frappe-bench") (MAC-1).
        var changeRunning: String?
    }

    struct Question: Equatable {
        var title: String
        var detail: String
        /// The run can be waited for: the second button quits when it ends.
        /// When false the second button quits at once and cuts it short.
        var canWaitForIt = false
    }

    /// nil: quit at once. A change that runs comes first, since cutting it short
    /// leaves a bench half installed or half migrated, and it asks with the lab
    /// off too. Then the order is the order of the damage: a half made copy,
    /// then people in a room, then a connection.
    static func question(_ facts: Facts) -> Question? {
        if let change = facts.changeRunning {
            return Question(title: "\(change) is still running.",
                            detail: "Quitting now ends it halfway and can leave the bench half installed or half migrated. "
                                + "BenchBar can quit as soon as it has finished.",
                            canWaitForIt: true)
        }
        guard facts.labOn else { return nil }
        if facts.setupRunning {
            return Question(title: "Sharing setup is still running.",
                            detail: "Quitting now stops it halfway; the copy will need setup again.")
        }
        if let bench = facts.hostedBench {
            let who = Wording.peopleAre(facts.people)
            return Question(title: "People are in your room.",
                            detail: "\(who) in the room on \(URL(fileURLWithPath: bench).lastPathComponent). Quitting disconnects them.")
        }
        if facts.guestForwarder {
            return Question(title: "You are connected to a room.",
                            detail: "Quitting closes the connection to the site you opened from it.")
        }
        return nil
    }
}

/// "Quit when it finishes": remembers the person's choice and says when the
/// time has come. The change slot of the store ends it, whatever started it.
nonisolated struct QuitAfterChange: Equatable, Sendable {
    private(set) var armed = false

    mutating func arm() { armed = true }
    /// The person keeps running, or quits some other way.
    mutating func disarm() { armed = false }

    /// True once, when armed and nothing runs any more.
    mutating func shouldQuitNow(changeRunning: Bool) -> Bool {
        guard armed, !changeRunning else { return false }
        armed = false
        return true
    }
}
