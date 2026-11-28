import Foundation

/// `benchbar app add SOURCE --dry-run --json`: the reviewed plan of an app
/// add (CLI 0.6.0) and the token `--apply TOKEN --yes` needs. Read only.
nonisolated struct AppAddPlan: Codable, Sendable, Equatable {
    nonisolated struct Site: Codable, Sendable, Equatable, Identifiable {
        var name: String
        var installed: Bool
        var id: String { name }
    }

    nonisolated struct Required: Codable, Sendable, Equatable, Identifiable {
        var name: String
        var requiredBy: String
        var present: Bool
        var resolves: Bool
        var source: String?
        var repo: String?
        var branch: String?
        var commit: String?
        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, present, resolves, source, repo, branch, commit
            case requiredBy = "required_by"
        }
    }

    nonisolated struct Step: Codable, Sendable, Equatable, Identifiable {
        /// clone_required, clone, requirements_python, build, install or restart
        var kind: String
        var name: String
        var command: String
        var note: String
        var id: String { kind + "|" + name }
    }

    /// One target of a plan with several apps (`apps[]`, CLI 0.8.3): its own repo, branch, pin and sites.
    nonisolated struct Target: Codable, Sendable, Equatable, Identifiable {
        var app: String
        var repo: String?
        var branch: String?
        var commit: String?
        /// `pin` (the commit was asked for) or `branch`
        var commitSource: String?
        var present: Bool
        var installOn: [String]
        var id: String { app }

        enum CodingKeys: String, CodingKey {
            case app, repo, branch, commit, present
            case commitSource = "commit_source"
            case installOn = "install_on"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            app = try c.decode(String.self, forKey: .app)
            repo = c.lenient(.repo, nil)
            branch = c.lenient(.branch, nil)
            commit = c.lenient(.commit, nil)
            commitSource = c.lenient(.commitSource, nil)
            present = c.lenient(.present, false)
            installOn = c.lenient(.installOn, [])
        }

        /// "main at 9b1d2c4 (pinned), install on macdev, site2", for the plan's row of this app.
        var summary: String {
            var parts: [String] = []
            if let branch { parts.append(String(localized: "branch \(branch)")) }
            if let commit {
                let short = String(commit.prefix(7))
                parts.append(commitSource == "pin" ? String(localized: "commit \(short) (pinned)") : String(localized: "commit \(short)"))
            }
            if present { parts.append(String(localized: "already in the bench")) }
            parts.append(installOn.isEmpty ? String(localized: "no site") : String(localized: "install on \(installOn.joined(separator: ", "))"))
            return parts.joined(separator: ", ")
        }
    }

    var schemaVersion: Int
    var bench: String
    var profile: String?
    var target: String
    var app: String
    var package: String?
    var repo: String
    var branch: String?
    var commit: String?
    /// `pin` or `branch`
    var commitSource: String?
    /// given, policy, remote_default or present
    var branchSource: String?
    var present: Bool
    var reachable: Bool?
    /// One entry per app, only when several were given (CLI 0.8.3).
    var apps: [Target]?
    var sites: [Site]
    var sitesError: String?
    var requiredApps: [Required]
    var missingRequired: [String]
    var order: [String]
    var steps: [Step]
    var errors: [String]
    var changes: Bool
    var canApply: Bool
    var reason: String?
    var token: String

    enum CodingKeys: String, CodingKey {
        case bench, profile, target, app, package, repo, branch, commit, present, reachable, sites, apps
        case commitSource = "commit_source"
        case order, steps, errors, changes, reason, token
        case schemaVersion = "schema_version"
        case branchSource = "branch_source"
        case sitesError = "sites_error"
        case requiredApps = "required_apps"
        case missingRequired = "missing_required"
        case canApply = "can_apply"
    }

    /// The plan is for several apps: it lists each one's own branch, pin and sites.
    var isBatch: Bool { (apps?.count ?? 0) > 1 }

    /// The apps the plan adds, by name: one for a single add.
    var appNames: [String] { isBatch ? (apps ?? []).map(\.app) : [app] }

    /// Where the branch came from, in words.
    var branchSourceText: String? {
        switch branchSource {
        case "given": String(localized: "the one you asked for")
        case "policy": String(localized: "the profile's branch for this app")
        case "remote_default": String(localized: "the repository's default")
        case "present": String(localized: "the branch of the app already in the bench")
        default: nil
        }
    }

    /// What the steps touch, from their kinds, for the "Touches" line.
    var touches: [String] {
        var out: [String] = []
        if steps.contains(where: { $0.kind == "clone" || $0.kind == "clone_required" }) {
            out += [String(localized: "apps/ and sites/apps.txt"), String(localized: "the bench's Python environment")]
        }
        if steps.contains(where: { $0.kind == "build" }) { out.append(String(localized: "built assets")) }
        // "Install on SITE", or "Install APP on SITE" when several apps are added
        var installs: [String] = []
        for step in steps where step.kind == "install" {
            let site = step.name.components(separatedBy: " on ").last ?? step.name
            if !installs.contains(site) { installs.append(site) }
        }
        if !installs.isEmpty { out.append(String(localized: "the database of \(installs.joined(separator: ", "))")) }
        return out
    }

    /// The bench is restarted by the last step, when it is running.
    var restarts: Bool { steps.contains { $0.kind == "restart" } }
}

/// The CLI refuses a token whose plan no longer matches the bench: another
/// change to apps.txt, apps/ or the sites, or a branch that moved. Add App's
/// and Add Site's refusals share the sentence.
nonisolated enum StalePlan {
    static func isStale(_ message: String) -> Bool {
        message.contains("plan changed since it was shown") || message.contains("plan token expired")
    }
}
