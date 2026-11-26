import Foundation

/// The counts and the relative age of the main window (UI-18). The plural forms are in the
/// String Catalog, next to the ones in Wording.swift.
extension Wording {
    /// "1 difference", "3 differences": the lockfile badge.
    static func differences(_ n: Int) -> String { String(localized: "\(n) differences") }

    /// "1 scan warning", "2 scan warnings": the Find Benches pane.
    static func scanWarnings(_ n: Int) -> String { String(localized: "\(n) scan warnings") }

    /// "its 1 step", "its 3 steps": the message of Discard on a pending update.
    static func itsSteps(_ n: Int) -> String { String(localized: "its \(n) steps") }

    /// "1 new commit on main:", "3 new commits on the branch:": the heading of an update plan.
    static func newCommits(_ n: Int, on branch: String) -> String { String(localized: "\(n) new commits on \(branch):") }

    /// "2 hours ago", "yesterday". A moment after `now` counts as `now`, so a clock that is a
    /// little behind never says "in 2 minutes".
    static func relativeAge(of date: Date, now: Date, locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.locale = locale
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
