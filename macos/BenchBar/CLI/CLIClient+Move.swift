import Foundation

/// Move a site to another registered bench (#183). A plan first (`--dry-run --json`), then the run by that plan's own token
/// (`--apply TOKEN --yes --jsonl`). The app never computes a token and never touches the bench's files or MariaDB.
nonisolated extension CLIClient {
    /// benchbar site move NAME --to-bench PATH --dry-run --json: the plan and its token. Read only.
    /// A plan with errors still comes back (exit 0): `canRun` says it cannot run.
    func movePlan(_ request: SiteMoveRequest, bench: String) async throws(CLIError) -> SiteMovePlan {
        let output = try await run(request.planArguments(bench: bench), timeout: Timeout.doctor, acceptExitCodes: [0])
        return try BenchJSON.decode(SiteMovePlan.self, from: Data(output.stdout.utf8))
    }

    /// benchbar site move ... --apply TOKEN --yes --jsonl: runs the plan the person saw and hands each step to `onStep` as it
    /// starts and ends. The CLI plans again under its lock and refuses a token that no longer matches ("plan changed since it
    /// was shown"), with nothing changed. The drop is the last step and never runs after a failed one. The MariaDB password is
    /// the CLI's own business; a step that needs the Mac's password asks in macOS's own dialog (BENCHBAR_SUDO=gui).
    /// Not a `person` run: the CLI does not refuse an agent here, and the click plus the typed site name are the decision.
    func moveSite(_ request: SiteMoveRequest, token: String, bench: String,
                  onStep: @escaping @Sendable (InstallStep) -> Void) async throws(CLIError) -> SiteMoveOutcome {
        let lines = MoveLines()
        let code = try await runner.stream(executable: executable, arguments: request.applyArguments(token: token, bench: bench),
                                           environment: environment().merging(Self.guiSudo) { _, new in new },
                                           timeout: Timeout.install) { line in
            lines.add(line)
            if case .step(let step)? = try? InstallEvent.decode(line) { onStep(step) }
        }
        let outcome = SiteMoveOutcome(envelope: ResultEnvelope.parse(lines.text), steps: lines.steps)
        guard code == 0, outcome.envelope.exit == 0 else {
            let said = outcome.envelope.error ?? "The move did not finish. Nothing after the failed step ran."
            throw .failed(command: "site move", exitCode: code == 0 ? Int32(outcome.envelope.exit ?? 1) : code, message: said)
        }
        return outcome
    }
}

/// The lines of a run, kept until it ends (the done line is the last).
nonisolated final class MoveLines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []

    func add(_ line: String) { lock.withLock { all.append(line) } }

    var text: String { lock.withLock { all.joined(separator: "\n") } }

    /// The steps as they last stood: a step's end line replaces its start line.
    var steps: [InstallStep] {
        var order: [String] = []
        var latest: [String: InstallStep] = [:]
        for line in lock.withLock({ all }) {
            guard case .step(let step)? = try? InstallEvent.decode(line) else { continue }
            if latest[step.id] == nil { order.append(step.id) }
            latest[step.id] = step
        }
        return order.compactMap { latest[$0] }
    }
}
