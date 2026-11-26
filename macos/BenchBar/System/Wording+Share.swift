import Foundation

/// The counts of the Share and Network panes (UI-18). The plural forms are in the String
/// Catalog, next to the ones in Wording.swift.
nonisolated extension Wording {
    /// "1 person is connected and will be signed out.", "3 people are connected and will be ...".
    static func peopleConnected(_ n: Int) -> String { String(localized: "\(n) people are connected and will be signed out.") }

    /// "Stop sharing? 1 person is connected and will be signed out." and its plural.
    static func stopSharing(online n: Int) -> String { String(localized: "Stop sharing? \(n) people are connected and will be signed out.") }

    /// "Restart sharing? 1 person is connected and will be signed out." and its plural.
    static func restartSharing(online n: Int) -> String { String(localized: "Restart sharing? \(n) people are connected and will be signed out.") }

    /// "The room you opened closes on this Mac.", "The 2 rooms you opened close on this Mac."
    static func roomsClose(_ n: Int) -> String { String(localized: "The \(n) rooms you opened close on this Mac.") }

    /// The line above the people while somebody waits: "1 person waits for a seat. ..." and its plural.
    static func peopleWaiting(_ n: Int) -> String {
        String(localized: "\(n) people wait for a seat. Choose Give a Seat next to each name.")
    }

    /// "3 of 5 seats taken", "1 of 1 seat taken".
    static func seatsTaken(_ taken: Int, of total: Int) -> String { String(localized: "\(taken) of \(total) seats taken") }
}
