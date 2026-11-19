import Foundation

/// Restore, pull and the pending operations of a bench. Every change here
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

    /// benchbar pull ... --dry-run --json: checks the server and the bench, prints the plan.
    /// A refused check ends the stream with `done` exit 1 and the reason on stderr.
    func pullPlan(_ request: PullRequest, bench: String) async throws(CLIError) -> PullPlan {
        let output = try await run(request.arguments + ["--dry-run", "--json", "--bench-dir", bench],
                                   timeout: Timeout.action, acceptExitCodes: [0, 1, 2])
        guard output.exitCode == 0, let plan = PullStream.plan(in: output.stdout) else {
            throw .failed(command: "pull", exitCode: output.exitCode, message: PullStream.failure(output))
        }
        return plan
    }

    /// benchbar pull ... --apply TOKEN --yes --json: runs the plan the person saw. The CLI makes
    /// the plan again after its checks and refuses a token that no longer matches (a newer backup,
    /// other apps), with nothing changed. A CLI without a token (0.8) gets `--yes` alone. No password
    /// goes in: the Administrator login is then production's (the CLI says so), and the hosts line
    /// is left for Sites.
    func pull(_ request: PullRequest, token: String?, bench: String) async throws(CLIError) -> PullRun {
        let apply = token.map { ["--apply", $0] } ?? []
        let output = try await run(request.arguments + apply + ["--yes", "--json", "--bench-dir", bench],
                                   timeout: Timeout.install, acceptExitCodes: [0, 1, 2])
        guard output.exitCode == 0, let done = PullStream.done(in: output.stdout), done.exit == 0 else {
            throw .failed(command: "pull", exitCode: output.exitCode, message: PullStream.failure(output))
        }
        return PullRun(done: done, plan: PullStream.plan(in: output.stdout))
    }

    /// benchbar app update NAME --discard-pending: drops the record of an update or add that stopped
    /// part way, and stops. None of its steps run. (Resume is `app update NAME` or `app add NAME` again.)
    @discardableResult
    func discardPending(_ app: String, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["app", "update", app, "--discard-pending", "--yes", "--plain", "--bench-dir", bench],
                      timeout: Timeout.action, acceptExitCodes: [0])
    }
}
