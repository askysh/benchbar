import Foundation

/// `benchbar site add NAME --dry-run --json`: the reviewed plan of a site
/// add (CLI 0.8.0) and the token `--apply TOKEN --yes` needs. Read only.
nonisolated struct SiteAddPlan: ReviewablePlan, Codable {
    nonisolated struct Step: Codable, Sendable, Equatable, Identifiable {
        /// new_site, install or hosts
        var kind: String
        var name: String
        var command: String
        var id: String { kind + "|" + name }
    }

    var schemaVersion: Int
    var bench: String
    var site: String
    /// The site folder is already there: then there is no new_site step.
    var exists: Bool
    var apps: [String]
    /// The bench's default site now; it stays (`default_moves` is always false).
    var defaultSite: String?
    var defaultMoves: Bool
    /// The hosts line is already in /etc/hosts (so no hosts step).
    var hostsEntry: Bool
    var steps: [Step]
    /// database, site_folder or hosts
    var touches: [String]
    var changes: Bool
    var token: String

    enum CodingKeys: String, CodingKey {
        case bench, site, exists, apps, steps, touches, changes, token
        case schemaVersion = "schema_version"
        case defaultSite = "default_site"
        case defaultMoves = "default_moves"
        case hostsEntry = "hosts_entry"
    }

    var canRun: Bool { changes }

    /// The default site, when the bench has one.
    var keptDefaultSite: String? { defaultSite.flatMap { $0.isEmpty ? nil : $0 } }

    /// What the plan touches, in words. The hosts line is left out: the app
    /// cannot ask for the Mac's password, so it never writes /etc/hosts.
    var touchesText: [String] {
        touches.compactMap { kind in
            switch kind {
            case "database": exists ? "the database of \(site)" : "a new MariaDB database and user"
            case "site_folder": "sites/\(site)"
            case "hosts": nil
            default: kind
            }
        }
    }
}
