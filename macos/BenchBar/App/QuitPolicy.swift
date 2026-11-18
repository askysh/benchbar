import Foundation

/// What is going on when the person (or the system) asks BenchBar to quit.
/// Plain values, so the decision is tested without an app delegate.
nonisolated struct QuitFacts: Equatable, Sendable {
    /// The lan-rooms lab is on: its three cases below only count then.
    var labOn = false
    var shareSetupRunning = false
    /// A bench this Mac hosts has people in its room: bench name and head count.
    var hostedRoom: HostedRoom?
    var guestForwarderUp = false
    /// A change holds the CLI: an install, repair, app update, site change,
    /// port setup or hosts line, or a start, stop or restart. Named for the
    /// person ("Installing macdev", "Starting frappe-bench").
    var changeRunning: String?

    struct HostedRoom: Equatable, Sendable {
        var bench: String
        var people: Int
    }
}

/// The question to ask before quitting.
nonisolated struct QuitPrompt: Equatable, Sendable {
    var title: String
    var detail: String
    /// The run can be waited for: the second button quits when it ends. When
    /// false the second button quits at once and cuts the thing short.
    var canWaitForIt: Bool
}

nonisolated enum QuitPolicy {
    /// nil: nothing stands in the way. The first thing that does is named;
    /// a change that is running comes first, since cutting it short leaves
    /// a bench half installed or half migrated.
    static func prompt(for facts: QuitFacts) -> QuitPrompt? {
        if let change = facts.changeRunning {
            return QuitPrompt(
                title: "\(change) is still running.",
                detail: "Quitting now ends it halfway and can leave the bench half installed or half migrated. "
                    + "BenchBar can quit as soon as it has finished.",
                canWaitForIt: true)
        }
        guard facts.labOn else { return nil }
        if facts.shareSetupRunning {
            return QuitPrompt(
                title: "Sharing setup is still running.",
                detail: "Quitting now stops it halfway; the copy will need setup again.",
                canWaitForIt: false)
        }
        if let room = facts.hostedRoom {
            let people = room.people == 1 ? "1 person is" : "\(room.people) people are"
            return QuitPrompt(
                title: "People are in your room.",
                detail: "\(people) in the room on \(room.bench). Quitting disconnects them.",
                canWaitForIt: false)
        }
        if facts.guestForwarderUp {
            return QuitPrompt(
                title: "You are connected to a room.",
                detail: "Quitting closes the connection to the site you opened from it.",
                canWaitForIt: false)
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
