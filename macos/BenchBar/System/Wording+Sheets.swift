import Foundation

/// The counts of the sheets and of the tidy and profile surfaces (UI-18). The plural forms
/// are in the String Catalog, next to the ones in Wording.swift.
nonisolated extension Wording {
    /// "Exported 1 app", "Exported 3 apps": the result of a profile export.
    static func exportedApps(_ n: Int) -> String { String(localized: "Exported \(n) apps") }

    /// "1 commit behind", "4 commits behind": the tag of an app in the profile export.
    static func commitsBehind(_ n: Int) -> String { String(localized: "\(n) commits behind") }

    /// "1 repository is not reachable", "2 repositories are not reachable".
    static func repositoriesNotReachable(_ n: Int) -> String { String(localized: "\(n) repositories are not reachable") }

    /// "1 line in /etc/hosts names no site of any bench:", "3 lines in /etc/hosts name no site of any bench:".
    static func staleHostsLines(_ n: Int) -> String { String(localized: "\(n) lines in /etc/hosts name no site of any bench:") }

    /// "Mark acme scratch for 1 day", "Mark acme scratch for 3 days".
    static func markScratch(_ bench: String, days count: Int) -> String { String(localized: "Mark \(bench) scratch for \(count) days") }

    /// "1 database of 3 has no site in any bench benchbar knows.", "2 databases of 3 have no site ...".
    static func orphanDatabases(_ n: Int, checked: Int) -> String {
        String(localized: "\(n) databases of \(checked) have no site in any bench benchbar knows.")
    }

    /// "3 apps": the title of an Add for three or more apps.
    static func apps(_ n: Int) -> String { String(localized: "\(n) apps") }
}
