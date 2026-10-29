import Foundation

/// What `site add NAME` does, for the review before it runs. The CLI has no
/// JSON plan or token for it (its `--dry-run` prints text and checks the
/// name, the half made site and MariaDB's password), so the steps are the
/// app's, written from the command's code (`fl_cmd_site_add`); the dry run
/// is what refuses a site the CLI would refuse.
nonisolated struct SiteAddPlan: ReviewablePlan, Codable {
    nonisolated struct Step: Codable, Sendable, Equatable, Identifiable {
        var name: String
        var note: String
        var id: String { name }
    }

    var site: String
    /// The bench's default site, which stays.
    var defaultSite: String?
    var steps: [Step]

    var canRun: Bool { true }

    /// The steps of `benchbar site add NAME --yes` with no apps: a new site
    /// with only Frappe on it.
    static func make(site: String, defaultSite: String?) -> SiteAddPlan {
        SiteAddPlan(site: site, defaultSite: defaultSite, steps: [
            Step(name: "Create \(site)",
                 note: "bench new-site on the bench's own MariaDB, with the root password from your Keychain and the Administrator password you typed. Only Frappe is installed."),
            Step(name: "Start the bench's Redis for the setup",
                 note: "only the servers nothing listens on yet, and they stop again afterwards. A running bench's Redis is used as it is."),
            Step(name: "Hosts line for \(site)",
                 note: "needs your Mac's password, which BenchBar never asks for: the line is not added here. The Sites tab's Add Hosts Lines shows the command for Terminal."),
        ])
    }

    /// What the steps touch.
    var touches: [String] { ["sites/\(site)", "a new MariaDB database and user"] }
}
