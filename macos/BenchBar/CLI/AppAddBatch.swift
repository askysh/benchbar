import Foundation

/// One app of the Add App form: where it comes from, an optional branch and
/// commit pin, and the site it is installed on after the clone.
nonisolated struct AppAddEntry: Equatable, Sendable, Identifiable {
    var id = UUID()
    var source = ""
    var branch = ""
    var commit = ""
    /// Empty: the app is only added to the bench.
    var site = ""

    init(source: String = "", branch: String = "", commit: String = "", site: String = "") {
        self.source = source
        self.branch = branch
        self.commit = commit
        self.site = site
    }

    var trimmedSource: String { source.trimmingCharacters(in: .whitespaces) }
    var displayName: String { AppSource.displayName(trimmedSource) }
    var isEmpty: Bool { trimmedSource.isEmpty }

    /// What the CLI would refuse before it reads anything: a pin that is not 7 to 40 hex characters.
    var problem: String? {
        if isEmpty { return String(localized: "Enter an app name or a git URL.") }
        let pin = commit.trimmingCharacters(in: .whitespaces)
        if !pin.isEmpty, !(7...40).contains(pin.count) || pin.contains(where: { !$0.isHexDigit }) {
            return String(localized: "The commit must be 7 to 40 hex characters.")
        }
        return nil
    }
}

/// The apps of one Add App form, in the CLI's own words: one plan, one token. An option
/// belongs to the app before it (docs/reference/cli/app.md, "Several apps at once").
nonisolated enum AppAddBatch {
    static let maxApps = 8

    /// `NAME [--branch B] [--commit C] [--install-on S] NAME ...`, without the mode or the bench.
    static func arguments(_ entries: [AppAddEntry]) -> [String] {
        var args: [String] = []
        for entry in entries {
            args.append(entry.trimmedSource)
            let branch = entry.branch.trimmingCharacters(in: .whitespaces)
            let commit = entry.commit.trimmingCharacters(in: .whitespaces)
            if !branch.isEmpty { args += ["--branch", branch] }
            if !commit.isEmpty { args += ["--commit", commit] }
            if !entry.site.isEmpty { args += ["--install-on", entry.site] }
        }
        return args
    }

    /// The first problem of the form, naming the app when there are several; nil when a plan can be asked for.
    static func problem(_ entries: [AppAddEntry]) -> String? {
        let filled = entries.filter { !$0.isEmpty }
        if filled.isEmpty { return String(localized: "Enter an app name or a git URL.") }
        for (index, entry) in entries.enumerated() {
            guard let problem = entry.problem, !(entry.isEmpty && entries.count > 1) else { continue }
            return entries.count == 1 ? problem : String(localized: "App \(index + 1): \(problem)")
        }
        var seen = Set<String>()
        for entry in filled where !seen.insert(entry.displayName.lowercased()).inserted {
            return String(localized: "\(entry.displayName) is listed twice.")
        }
        return nil
    }

    /// "acme_crm", "acme_crm and acme_hr", "3 apps".
    static func title(_ names: [String]) -> String {
        switch names.count {
        case 0: "apps"
        case 1: names[0]
        case 2: String(localized: "\(names[0]) and \(names[1])")
        default: Wording.apps(names.count)
        }
    }
}
