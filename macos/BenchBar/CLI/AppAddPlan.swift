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

    var schemaVersion: Int
    var bench: String
    var profile: String?
    var target: String
    var app: String
    var package: String?
    var repo: String
    var branch: String?
    var commit: String?
    /// given, policy, remote_default or present
    var branchSource: String?
    var present: Bool
    var reachable: Bool?
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
        case bench, profile, target, app, package, repo, branch, commit, present, reachable, sites
        case order, steps, errors, changes, reason, token
        case schemaVersion = "schema_version"
        case branchSource = "branch_source"
        case sitesError = "sites_error"
        case requiredApps = "required_apps"
        case missingRequired = "missing_required"
        case canApply = "can_apply"
    }

    /// Where the branch came from, in words.
    var branchSourceText: String? {
        switch branchSource {
        case "given": "the one you asked for"
        case "policy": "the profile's branch for this app"
        case "remote_default": "the repository's default"
        case "present": "the branch of the app already in the bench"
        default: nil
        }
    }

    /// What the steps touch, from their kinds, for the "Touches" line.
    var touches: [String] {
        var out: [String] = []
        if steps.contains(where: { $0.kind == "clone" || $0.kind == "clone_required" }) {
            out += ["apps/ and sites/apps.txt", "the bench's Python environment"]
        }
        if steps.contains(where: { $0.kind == "build" }) { out.append("built assets") }
        let installs = steps.filter { $0.kind == "install" }.map { $0.name.replacingOccurrences(of: "Install on ", with: "") }
        if !installs.isEmpty { out.append("the database of " + installs.joined(separator: ", ")) }
        return out
    }

    /// The bench is restarted by the last step, when it is running.
    var restarts: Bool { steps.contains { $0.kind == "restart" } }
}

/// The CLI refuses a token whose plan no longer matches the bench: another
/// change to apps.txt, apps/ or the sites, or a branch that moved. Add App's
/// and Add Site's refusals share the sentence.
nonisolated enum StalePlan {
    static func isStale(_ message: String) -> Bool { message.contains("plan changed since it was shown") }
}
