import Foundation

/// The end of a bench's life (#183). A change goes through the CLI's own plan (`--dry-run --json`) and its token
/// (`--apply TOKEN --yes`); the app never computes a token. `bench gc` and `bench remove` remove data and the CLI allows them to a
/// person only, so they run with the person's environment: the click, and for Remove the typed folder name, are that decision.
nonisolated extension CLIClient {
    // MARK: reads (change nothing)

    /// `bench gc --dry-run --json`: the scratch benches that expired, the ones that wait and the ones kept.
    func gcPlan() async throws(CLIError) -> GcPlan {
        let output = try await run(TidyCommands.gcRead, timeout: Timeout.doctor, acceptExitCodes: [0])
        return try BenchJSON.decode(GcPlan.self, from: Data(output.stdout.utf8))
    }

    /// `db orphans --json`: the databases no site refers to. Read only; benchbar never drops them.
    func orphans() async throws(CLIError) -> OrphanList {
        let output = try await run(TidyCommands.orphansRead, timeout: Timeout.doctor, acceptExitCodes: [0], qos: .utility)
        return try BenchJSON.decode(OrphanList.self, from: Data(output.stdout.utf8))
    }

    /// `site hosts --prune --dry-run`: the names of the hosts lines no bench has a site for. Nothing is written.
    func staleHostsLines() async throws(CLIError) -> [String] {
        let output = try await run(TidyCommands.hostsRead, timeout: Timeout.query, acceptExitCodes: [0], qos: .utility)
        return HostsPrune.names(in: output.stdout + "\n" + output.stderr)
    }

    // MARK: scratch

    /// `bench scratch PATH --ttl DAYS --yes` (or `--clear`). The mark records who made it, so it says it is a person's.
    @discardableResult
    func markScratch(bench: String, days: Int?) async throws(CLIError) -> CommandOutput {
        try await run(days.map { TidyCommands.scratch(bench: bench, days: $0) } ?? TidyCommands.clearScratch(bench: bench),
                      timeout: Timeout.query, acceptExitCodes: [0], extraEnvironment: Self.person)
    }

    // MARK: plans and applies

    /// The plan of one action, read only. Nothing is changed and no token is applied.
    func tidyPlan(_ action: TidyAction, bench: String) async throws(CLIError) -> TidyPlan {
        let output = try await run(TidyCommands.plan(action, bench: bench), timeout: Timeout.doctor,
                                   acceptExitCodes: action == .removeService ? [0, 1] : [0])
        let data = Data(output.stdout.utf8)
        switch action {
        case .gc: return TidyPlan.gc(try BenchJSON.decode(GcPlan.self, from: data))
        case .forget, .remove: return try TidyPlan.decode(action, bench: bench, from: data)
        case .removeService: return TidyPlan.service(bench: bench, from: output.stdout + "\n" + output.stderr)
        }
    }

    /// Runs exactly the plan the person saw, by its own token (the CLI recomputes the plan and refuses one that changed since).
    /// A step that needs a password asks in macOS's own dialog (BENCHBAR_SUDO=gui), never in the app.
    @discardableResult
    func tidyApply(_ action: TidyAction, bench: String, token: String?) async throws(CLIError) -> CommandOutput {
        try await run(TidyCommands.apply(action, bench: bench, token: token), timeout: Timeout.long, acceptExitCodes: [0],
                      extraEnvironment: action.needsPerson ? Self.person.merging(Self.guiSudo) { _, new in new } : Self.guiSudo)
    }
}
