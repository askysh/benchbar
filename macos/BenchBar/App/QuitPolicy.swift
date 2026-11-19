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
    }

    struct Question: Equatable {
        var title: String
        var detail: String
    }

    /// nil: quit at once. The order is the order of the damage: a half made copy, then people in a room, then a connection.
    static func question(_ facts: Facts) -> Question? {
        guard facts.labOn else { return nil }
        if facts.setupRunning {
            return Question(title: "Sharing setup is still running.",
                            detail: "Quitting now stops it halfway; the copy will need setup again.")
        }
        if let bench = facts.hostedBench {
            let who = facts.people == 1 ? "1 person is" : "\(facts.people) people are"
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
