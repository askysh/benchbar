import Foundation

/// The end of a bench's life (#183): Tidy Up (scratch benches, expired ones, orphan databases, stale hosts lines), Forget Bench, Remove
/// Bench and Remove Service. Every entry shows only when the CLI lists its command. A read takes no change slot; a change goes through
/// the CLI's plan and its token and takes the one slot.
extension Workbench {
    private var noTidyCLI: ChangeError { ChangeError(message: String(localized: "The benchbar command line tool is not available.")) }

    var offersScratch: Bool { commandState.catalog?.has("bench scratch") == true }
    var offersGc: Bool { commandState.catalog?.has("bench gc") == true }
    var offersOrphans: Bool { commandState.catalog?.has("db orphans") == true }
    var offersHostsPrune: Bool { commandState.catalog?.hasFlag("site hosts", "--prune") == true }
    /// Tidy Up shows when the CLI lists any of its four parts.
    var offersTidy: Bool { offersScratch || offersGc || offersOrphans || offersHostsPrune }

    func offers(_ action: TidyAction) -> Bool { commandState.catalog?.has(action.command) == true }

    private func tidyRead<T: Sendable>(_ work: (CLIClient) async throws(CLIError) -> T) async -> Result<T, ChangeError> {
        guard let client = store.cliClient else { return .failure(noTidyCLI) }
        do { return .success(try await work(client)) } catch { return .failure(ChangeError(message: error.localizedDescription)) }
    }

    func tidyGc() async -> Result<GcPlan, ChangeError> { await tidyRead { client throws(CLIError) in try await client.gcPlan() } }
    func tidyOrphans() async -> Result<OrphanList, ChangeError> { await tidyRead { client throws(CLIError) in try await client.orphans() } }
    func tidyHosts() async -> Result<[String], ChangeError> { await tidyRead { client throws(CLIError) in try await client.staleHostsLines() } }

    func tidyPlan(_ action: TidyAction, on bench: BenchModel) async -> Result<TidyPlan, ChangeError> {
        let path = bench.path
        return await tidyRead { client throws(CLIError) in try await client.tidyPlan(action, bench: path) }
    }

    /// Marks the bench scratch for `days`, or not scratch (nil). The CLI's message when it failed, nil when it worked.
    @discardableResult
    func markScratch(days: Int?, on bench: BenchModel) async -> String? {
        let title = days.map { Wording.markScratch(bench.name, days: $0) } ?? String(localized: "Mark \(bench.name) not scratch")
        return await change(title, on: bench) { client throws(CLIError) in try await client.markScratch(bench: bench.path, days: days) }
    }

    /// Runs the plan the person saw, by its own token. The CLI's message when it failed (a stale token among them), nil when it worked.
    @discardableResult
    func tidyChange(_ plan: TidyPlan, on bench: BenchModel) async -> String? {
        let title: String
        switch plan.action {
        case .gc: title = String(localized: "Remove expired scratch benches")
        case .forget: title = String(localized: "Forget \(bench.name)")
        case .remove: title = String(localized: "Remove \(bench.name)")
        case .removeService: title = String(localized: "Remove the service of \(bench.name)")
        }
        return await change(title, on: bench) { client throws(CLIError) in
            try await client.tidyApply(plan.action, bench: bench.path, token: plan.token)
        }
    }
}
