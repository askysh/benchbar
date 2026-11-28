import Foundation

/// Move a site to another registered bench (#183). The entry shows only when the CLI lists `site move` and another bench is
/// registered. A read takes no change slot; the move goes through the CLI's plan and its token and takes the one slot.
extension Workbench {
    /// The registered benches this bench's sites can go to.
    func moveTargets(for bench: BenchModel) -> [BenchModel] { SiteMoveText.targets(from: store.benches, excluding: bench) }

    func offersMove(from bench: BenchModel) -> Bool {
        SiteMoveText.offered(catalog: commandState.catalog, others: moveTargets(for: bench).count)
    }

    /// The reviewed plan of a move, read only. Nothing is backed up, restored or dropped and no change slot is taken.
    func movePlan(_ request: SiteMoveRequest, on bench: BenchModel) async -> Result<SiteMovePlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(ChangeError(message: String(localized: "The benchbar command line tool is not available."))) }
        do {
            return .success(try await client.movePlan(request, bench: bench.path))
        } catch {
            return .failure(ChangeError(message: error.localizedDescription))
        }
    }

    /// Runs the plan the person saw, by its own token, and shows each step to `onStep`. The CLI's message when it failed (a
    /// stale token among them), else how it ended. Both benches are read again: the site is gone from one and in the other.
    func moveSite(_ request: SiteMoveRequest, token: String, on bench: BenchModel,
                  onStep: @escaping @Sendable (InstallStep) -> Void) async -> Result<SiteMoveOutcome, ChangeError> {
        var ended: SiteMoveOutcome?
        let error = await change(String(localized: "Move \(request.site) to \(URL(fileURLWithPath: request.target).lastPathComponent)"), on: bench) { client throws(CLIError) in
            ended = try await client.moveSite(request, token: token, bench: bench.path, onStep: onStep)
        }
        await loadBackups(bench)
        if let target = store.benches.first(where: { $0.path == request.target }) {
            await store.refresh(target)
            await loadBackups(target)
        }
        if let ended, error == nil { return .success(ended) }
        return .failure(ChangeError(message: error ?? String(localized: "The site was not moved.")))
    }

    /// Stop Bench on the sheet: the app's own stop, the one the Stop button runs. The CLI's message when it failed.
    func stopForMove(_ bench: BenchModel) async -> String? { await store.perform(.down, on: bench) }
}
