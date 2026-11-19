import Foundation

/// Restore and the pending operations of a bench. Every change here
/// goes through the CLI's own review: a plan first (`--dry-run --json`),
/// then the run. The app never touches the bench's files or MariaDB.
nonisolated extension CLIClient {
    /// benchbar site restore ... --dry-run --json: the plan and its token. Read only.
    /// A plan with errors still comes back (exit 0): `canRun` says it cannot run.
    func restorePlan(_ request: SiteRestoreRequest, bench: String) async throws(CLIError) -> SiteRestorePlan {
        let output = try await run(["site", "restore"] + request.arguments + ["--dry-run", "--json", "--bench-dir", bench],
                                   timeout: Timeout.doctor, acceptExitCodes: [0])
        return try BenchJSON.decode(SiteRestorePlan.self, from: Data(output.stdout.utf8))
    }

    /// benchbar site restore ... --apply TOKEN --yes: runs the plan the person saw. The CLI
    /// recomputes it, backs an existing site up first, and refuses a token that no longer
    /// matches the bench or the backup. The MariaDB password is the CLI's own business.
    @discardableResult
    func restoreSite(_ request: SiteRestoreRequest, token: String, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["site", "restore"] + request.arguments + ["--apply", token, "--yes", "--plain", "--bench-dir", bench],
                      timeout: Timeout.install, acceptExitCodes: [0])
    }

    /// benchbar app update NAME --discard-pending: drops the record of an update or add that stopped
    /// part way, and stops. None of its steps run. (Resume is `app update NAME` or `app add NAME` again.)
    @discardableResult
    func discardPending(_ app: String, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["app", "update", app, "--discard-pending", "--yes", "--plain", "--bench-dir", bench],
                      timeout: Timeout.action, acceptExitCodes: [0])
    }
}
