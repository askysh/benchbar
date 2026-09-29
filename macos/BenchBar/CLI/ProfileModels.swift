import Foundation

// Profile sharing (0.6.0): the JSON of `benchbar profile export | import |
// subscribe | update | remove | check --json`. Field names follow the
// contract in docs/json-schema.md; every document carries schema_version.

/// Where a subscribed profile comes from and how far behind it is
/// (`profile list --json`, `subscription`).
nonisolated struct ProfileSubscription: Codable, Sendable, Equatable {
    var repo: String
    var dir: String
    var behind: Int?
    var days: Int?
    var fetchedAt: String?

    enum CodingKeys: String, CodingKey {
        case repo, dir, behind, days
        case fetchedAt = "fetched_at"
    }

    var isOutdated: Bool { (behind ?? 0) > 0 }

    /// "Outdated · 3 commits / 12 days"
    var outdatedText: String? {
        guard let behind, behind > 0 else { return nil }
        var text = "Outdated · \(behind) commit\(behind == 1 ? "" : "s")"
        if let days, days > 0 { text += " / \(days) day\(days == 1 ? "" : "s")" }
        return text
    }
}

/// The access words the CLI uses for a repository.
nonisolated enum RepoAccess {
    static func label(_ access: String?) -> String {
        switch access {
        case "public": return "public"
        case "private": return "private"
        case "personal": return "personal account"
        default: return "unknown"
        }
    }
}

// MARK: export

/// `profile export NAME --plan --json`: read only.
nonisolated struct ProfileExportPlan: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var name: String
    var base: String?
    var apps: [App]
    var warnings: [String]

    nonisolated struct App: Codable, Sendable, Equatable, Identifiable {
        var name: String
        var repo: String
        var exportedRepo: String
        var currentBranch: String?
        var exportedBranch: String
        var defaultBranch: String?
        var branchVerified: Bool
        var access: String
        var requires: [String]
        var keep: Bool

        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, repo, access, requires, keep
            case exportedRepo = "exported_repo"
            case currentBranch = "current_branch"
            case exportedBranch = "exported_branch"
            case defaultBranch = "default_branch"
            case branchVerified = "branch_verified"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, base, apps, warnings
        case schemaVersion = "schema_version"
    }
}

/// `profile export NAME --out FILE ... --yes --json`
nonisolated struct ProfileExportResult: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var path: String
    var apps: Int
    var dropped: [String]

    enum CodingKeys: String, CodingKey {
        case path, apps, dropped
        case schemaVersion = "schema_version"
    }
}

/// The refusal of an export (exit 1): dropping an app a kept app requires.
nonisolated struct ProfileExportRefusal: Codable, Sendable, Equatable {
    var error: String
    var blocked: [Blocked]

    nonisolated struct Blocked: Codable, Sendable, Equatable {
        var app: String
        var requiredBy: [String]

        enum CodingKeys: String, CodingKey {
            case app
            case requiredBy = "required_by"
        }
    }
}

// MARK: import, check

/// One repository's reachability with the user's own credentials:
/// `reachable` is nil when the Mac is offline.
nonisolated struct ProfileRepoCheck: Codable, Sendable, Equatable, Identifiable {
    var app: String
    var repo: String
    var reachable: Bool?
    var reason: String?

    var id: String { app }

    /// ✓, ✗ or ?
    var mark: String {
        switch reachable {
        case true?: return "✓"
        case false?: return "✗"
        case nil: return "?"
        }
    }
}

/// `profile import SRC [--as NAME] --plan --json`: nothing is written.
nonisolated struct ProfileImportPlan: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var name: String
    var source: String
    var exists: Bool
    var diff: String?
    var base: String?
    var apps: [App]
    var check: Check
    var skippedApps: [String]
    /// sha256 of the file this plan would write; import with `--expect` refuses other content (0.6.0)
    var digest: String?

    nonisolated struct App: Codable, Sendable, Equatable, Identifiable {
        var name: String
        var repo: String
        var branch: String?
        var access: String?
        var requires: [String]?

        var id: String { name }
    }

    nonisolated struct Check: Codable, Sendable, Equatable {
        var repos: [ProfileRepoCheck]
    }

    func check(for app: String) -> ProfileRepoCheck? { check.repos.first { $0.app == app } }

    enum CodingKeys: String, CodingKey {
        case name, source, exists, diff, base, apps, check, digest
        case schemaVersion = "schema_version"
        case skippedApps = "skipped_apps"
    }
}

/// `profile import SRC --yes --json`
nonisolated struct ProfileImportResult: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var name: String
    var path: String
    var source: String

    enum CodingKeys: String, CodingKey {
        case name, path, source
        case schemaVersion = "schema_version"
    }
}

/// `profile check NAME --json`
nonisolated struct ProfileCheck: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var name: String
    var repos: [ProfileRepoCheck]
    var skippedApps: [String]

    enum CodingKeys: String, CodingKey {
        case name, repos
        case schemaVersion = "schema_version"
        case skippedApps = "skipped_apps"
    }
}

// MARK: subscribe, update, remove

/// `profile subscribe GIT_URL --yes --json`
nonisolated struct ProfileSubscribeResult: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var repo: String
    var dir: String
    var profiles: [String]

    enum CodingKeys: String, CodingKey {
        case repo, dir, profiles
        case schemaVersion = "schema_version"
    }
}

/// `profile update NAME --plan --json`, and with `--yes` the same plus `applied`.
nonisolated struct ProfileUpdatePlan: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var updates: [Update]
    var applied: Bool?
    /// The reviewed content and commits; update with `--expect` refuses anything newer (0.6.0)
    var digest: String?

    nonisolated struct Update: Codable, Sendable, Equatable, Identifiable {
        var name: String
        var kind: String
        var behind: Int?
        var diff: String?

        var id: String { name }
        var hasChanges: Bool { (behind ?? 0) > 0 || !(diff ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var hasChanges: Bool { updates.contains(where: \.hasChanges) }

    enum CodingKeys: String, CodingKey {
        case updates, applied, digest
        case schemaVersion = "schema_version"
    }
}

/// `profile remove NAME --yes --json`
nonisolated struct ProfileRemoveResult: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var name: String
    var movedTo: String

    enum CodingKeys: String, CodingKey {
        case name
        case movedTo = "moved_to"
        case schemaVersion = "schema_version"
    }
}

// MARK: rules

nonisolated enum ProfileName {
    /// The CLI's rule (fl_team_profile_valid_name): ^[a-z0-9][a-z0-9._-]*$.
    /// Unlike a site name, `_` is allowed.
    static func isValid(_ name: String) -> Bool {
        guard let first = name.first, isLowerOrDigit(first) else { return false }
        return name.allSatisfy { isLowerOrDigit($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    private static func isLowerOrDigit(_ c: Character) -> Bool {
        guard let ascii = c.asciiValue else { return false }
        return (ascii >= 97 && ascii <= 122) || (ascii >= 48 && ascii <= 57)
    }
}

/// What may be imported or subscribed to, from a text field or a link.
/// The CLI checks again; this keeps an odd string (a flag, a local path, an
/// `ext::` transport) from ever reaching its argument list.
nonisolated enum ProfileSourceRule {
    /// An https URL with a host: the only remote source import accepts.
    static func isImportURL(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.hasPrefix("-"), !s.contains(where: \.isWhitespace),
              let url = URL(string: s), url.scheme?.lowercased() == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        return true
    }

    /// A local .toml file, as the open panel or a drop gives it.
    static func isLocalFile(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("/") && s.lowercased().hasSuffix(".toml")
    }

    static func isImportSource(_ text: String) -> Bool { isImportURL(text) || isLocalFile(text) }

    /// A git remote: https or ssh URL, or scp style `user@host:owner/repo`.
    /// No file://, no local paths, no `ext::` or other transports.
    static func isGitURL(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("-"), !s.contains(where: \.isWhitespace), !s.contains("::") else { return false }
        if s.contains("://") {
            guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["https", "ssh"].contains(scheme),
                  let host = url.host(percentEncoded: false), !host.isEmpty,
                  url.path(percentEncoded: false).count > 1 else { return false }
            return true
        }
        // scp style: user@host:path
        guard let at = s.firstIndex(of: "@"), let colon = s[at...].firstIndex(of: ":") else { return false }
        let user = s[..<at], host = s[s.index(after: at)..<colon], path = s[s.index(after: colon)...]
        return !user.isEmpty && !host.isEmpty && !host.contains("/") && !path.isEmpty && !path.hasPrefix("/")
    }

    /// `benchbar://profile/import?url=ENC`, to paste into a team chat.
    static func importLink(for hostedURL: String) -> String? {
        let s = hostedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isImportURL(s) else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = s.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "benchbar://profile/import?url=\(encoded)"
    }
}

// MARK: a profile's origin

nonisolated extension ProfileInfo {
    enum Origin: String, Sendable {
        case builtin, user, imported, subscribed, path
    }

    /// `source`; a value this app does not know reads as a local file.
    var origin: Origin {
        if kind == "builtin" { return .builtin }
        return source.flatMap(Origin.init(rawValue:)) ?? .user
    }

    /// "built in", "local", "imported", "subscribed · acme/profiles"
    var originText: String {
        switch origin {
        case .builtin: return "built in"
        case .user: return "local"
        case .imported: return "imported"
        case .path: return "profile path"
        case .subscribed:
            guard let repo = subscription?.repo else { return "subscribed" }
            return "subscribed · \(Self.shortRepo(repo))"
        }
    }

    var canExport: Bool { isTeam && valid }
    var canCheck: Bool { isTeam && valid }
    var canUpdate: Bool { origin == .imported || origin == .subscribed }
    var canRemove: Bool { origin == .imported || origin == .subscribed }

    /// "https://github.com/acme/profiles.git" -> "acme/profiles"
    static func shortRepo(_ repo: String) -> String {
        var s = repo.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(whereSeparator: { $0 == "/" || $0 == ":" })
        guard parts.count >= 2 else { return repo }
        return parts.suffix(2).joined(separator: "/")
    }
}

// MARK: export choices

/// What the user picked in the export sheet: a branch per app and which
/// apps to keep. Pure, so the rules are tested without the sheet.
nonisolated struct ProfileExportChoices: Equatable, Sendable {
    var branches: [String: String]
    var keep: [String: Bool]

    init(branches: [String: String] = [:], keep: [String: Bool] = [:]) {
        self.branches = branches
        self.keep = keep
    }

    init(plan: ProfileExportPlan) {
        branches = Dictionary(uniqueKeysWithValues: plan.apps.map { ($0.name, $0.exportedBranch) })
        keep = Dictionary(uniqueKeysWithValues: plan.apps.map { ($0.name, $0.keep) })
    }

    func keeps(_ app: String) -> Bool { keep[app] ?? true }

    /// Dropped apps that a kept app still lists in `requires`.
    func blocked(in plan: ProfileExportPlan) -> [ProfileExportRefusal.Blocked] {
        plan.apps.filter { !keeps($0.name) }.compactMap { dropped in
            let by = plan.apps.filter { keeps($0.name) && $0.requires.contains(dropped.name) }.map(\.name)
            return by.isEmpty ? nil : .init(app: dropped.name, requiredBy: by)
        }
    }

    /// Why Export is off, or nil when it can run.
    func problem(in plan: ProfileExportPlan) -> String? {
        if let first = blocked(in: plan).first {
            return "\(first.app) is required by \(first.requiredBy.joined(separator: ", ")): keep it, or drop those too."
        }
        if !plan.apps.contains(where: { keeps($0.name) }) { return "Keep at least one app." }
        for app in plan.apps where keeps(app.name) {
            let branch = (branches[app.name] ?? "").trimmingCharacters(in: .whitespaces)
            if !Self.isBranch(branch) { return "\(app.name) needs a branch name." }
        }
        return nil
    }

    /// `--branch APP=BR` for every changed branch, `--drop APP` for every dropped app.
    func arguments(for plan: ProfileExportPlan) -> [String] {
        var args: [String] = []
        for app in plan.apps where keeps(app.name) {
            let branch = (branches[app.name] ?? app.exportedBranch).trimmingCharacters(in: .whitespaces)
            if branch != app.exportedBranch { args += ["--branch", "\(app.name)=\(branch)"] }
        }
        for app in plan.apps where !keeps(app.name) { args += ["--drop", app.name] }
        return args
    }

    /// A git branch name, loosely: no spaces, no leading dash, no "..".
    static func isBranch(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix("-") && !text.contains("..") && !text.contains(where: { $0.isWhitespace || $0 == "=" })
    }
}
