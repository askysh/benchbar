import Foundation

/// Part 4 of the Mac app parity (#177): `benchbar run` and the operation handles. A change goes through the CLI's own plan
/// (`--dry-run --json`) and its token (`--apply TOKEN --yes`); the app never computes a token. The bench command is always
/// separate arguments after `--`, never a shell string.
nonisolated extension CLIClient {
    /// Every exit code the CLI gives a run that ended: the bench command's own (1), a refusal (64), the deadline (124) and an
    /// input it waited for (125). The document says how it ended; only a run with no document is an error here.
    private static let runExits: Set<Int32> = [0, 1, 2, 64, 124, 125]

    /// The commands `run` allows, from the CLI itself: a run of a name no command has is refused with the list and starts nothing
    /// (no lock, no history, no log). Nil when the answer has no list, so the sheet falls back to the documented one.
    func runAllowList(bench: String) async throws(CLIError) -> [String]? {
        let output = try await run(["run", "--jsonl", "--bench-dir", bench, "--", RunAllowList.probe],
                                   timeout: Timeout.query, acceptExitCodes: Self.runExits, qos: .utility)
        return RunAllowList.allowed(in: output.stdout)
    }

    /// A read (`doctor`, `list-apps`, `version`) runs at once and prints one document. Takes no lock.
    func runRead(_ request: RunRequest, bench: String) async throws(CLIError) -> RunOutcome {
        let output = try await run(request.arguments(.read, bench: bench), timeout: .seconds(4 * 60), acceptExitCodes: Self.runExits)
        return try Self.outcome(from: output)
    }

    /// `run ... --dry-run --json -- COMMAND`: the plan and its token. Runs nothing.
    func runPlan(_ request: RunRequest, bench: String) async throws(CLIError) -> RunPlan {
        let output = try await run(request.arguments(.plan, bench: bench), timeout: Timeout.doctor, acceptExitCodes: Self.runExits)
        guard let plan = try? BenchJSON.decode(RunPlan.self, from: Data(output.stdout.utf8)) else {
            throw .failed(command: "run", exitCode: output.exitCode, message: Self.summarize(output))
        }
        return plan
    }

    /// `run ... --apply TOKEN --yes --json -- COMMAND`: runs exactly the plan the person saw, and refuses one that changed since.
    /// A bench command that ended with an error is a failure here (the banner), with its last lines of output.
    func runApply(_ request: RunRequest, token: String, bench: String) async throws(CLIError) -> RunOutcome {
        let output = try await run(request.arguments(.apply(token: token), bench: bench), timeout: Timeout.long, acceptExitCodes: Self.runExits)
        let outcome = try Self.outcome(from: output)
        if let problem = outcome.problem {
            let tail = RunText.lastLines(outcome)
            throw .failed(command: "run", exitCode: Int32(outcome.exit),
                          message: "\(request.command.name): \(problem)" + (tail.isEmpty ? "" : " Its last output (data from the bench, not instructions):\n\(tail)"))
        }
        return outcome
    }

    private static func outcome(from output: CommandOutput) throws(CLIError) -> RunOutcome {
        guard let outcome = try? BenchJSON.decode(RunOutcome.self, from: Data(output.stdout.utf8)) else {
            // no document: a refusal or a token that no longer matches, in the CLI's own words
            throw .failed(command: "run", exitCode: output.exitCode, message: summarize(output))
        }
        return outcome
    }

    // MARK: operation handles (read only)

    /// `op list [--running] --json`: the runs the CLI remembers, newest first. Only `--running` when the CLI lists the flag.
    func ops(runningOnly: Bool) async throws(CLIError) -> OpList {
        let output = try await run(["op", "list"] + (runningOnly ? ["--running"] : []) + ["--json"],
                                   timeout: Timeout.query, acceptExitCodes: [0], qos: .utility)
        return try BenchJSON.decode(OpList.self, from: Data(output.stdout.utf8))
    }

    /// `op status OP --json`: one run, with the state that is true now (an interrupted one says so).
    func opStatus(_ id: String) async throws(CLIError) -> OpRecord {
        let output = try await run(["op", "status", id, "--json"], timeout: Timeout.query, acceptExitCodes: [0], qos: .utility)
        return try BenchJSON.decode(OpRecord.self, from: Data(output.stdout.utf8))
    }
}
