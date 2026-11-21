import Foundation

/// Part 3 of the Mac app parity (#177): the team lockfile, site snapshots and rollback, the action
/// history, leases and the log reads. A change goes through the CLI's own plan (`--dry-run --json`)
/// and its token (`--apply TOKEN --yes`); the app never computes a token and never holds a lease.
nonisolated extension CLIClient {
    /// The same client, going ahead although a lease stands: `--break-lease` on every command and the person's
    /// `BENCHBAR_NONINTERACTIVE=0` that the CLI wants for it (a person's decision, asked for in the app first).
    func breakingLease() -> CLIClient {
        var copy = self
        copy.breakLease = true
        return copy
    }

    /// `--break-lease` before a `--` that ends the options, else last.
    static func withBreakLease(_ arguments: [String]) -> [String] {
        var out = arguments
        out.insert("--break-lease", at: arguments.firstIndex(of: "--") ?? arguments.count)
        return out
    }

    /// The environment of a run a person decided on: the CLI refuses a lease break, a rollback of the default
    /// site and a snapshot drop for an agent, and takes the app's word only with the app's process id.
    static let person = ["BENCHBAR_NONINTERACTIVE": "0"].merging(appCaller) { _, new in new }

    // MARK: history and leases (read only)

    /// benchbar history --json: what ran on this Mac that changed things, newest first.
    func history(bench: String?, limit: Int) async throws(CLIError) -> HistoryList {
        let output = try await run(["history", "--json", "--limit", String(limit)] + (bench.map { ["--bench", $0] } ?? []),
                                   timeout: Timeout.query, acceptExitCodes: [0], qos: .utility)
        return try BenchJSON.decode(HistoryList.self, from: Data(output.stdout.utf8))
    }

    /// benchbar lease list --bench PATH --json: who holds this bench or one of its sites. No lease is taken or released here.
    func leases(bench: String) async throws(CLIError) -> LeaseList {
        let output = try await run(["lease", "list", "--bench", bench, "--json"], timeout: Timeout.query, acceptExitCodes: [0], qos: .utility)
        return try BenchJSON.decode(LeaseList.self, from: Data(output.stdout.utf8))
    }

    // MARK: logs

    /// benchbar logs --json --no-follow: one read of the bench's log. `since` is the poll's cursor (only newer
    /// lines come back), `sinceRestart` the lines of the current start. `--previous` has no worker file, so it is left out there.
    func logs(_ request: LogRequest, bench: String) async throws(CLIError) -> LogChunk {
        let output = try await run(request.arguments + ["--bench-dir", bench], timeout: Timeout.query, acceptExitCodes: [0], qos: .utility)
        return try BenchJSON.decode(LogChunk.self, from: Data(output.stdout.utf8))
    }

    // MARK: snapshots and rollback

    /// benchbar site snapshots NAME --json. Read only.
    func snapshots(site: String, bench: String) async throws(CLIError) -> SiteSnapshotList {
        let output = try await run(["site", "snapshots", site, "--json", "--bench-dir", bench], timeout: Timeout.query, acceptExitCodes: [0], qos: .utility)
        return try BenchJSON.decode(SiteSnapshotList.self, from: Data(output.stdout.utf8))
    }

    /// benchbar site snapshot NAME [--label TEXT] --json: a backup with files kept out of frappe's pruning. Changes nothing in the site.
    func takeSnapshot(site: String, label: String, bench: String) async throws(CLIError) -> SiteSnapshotResult {
        let tag = label.trimmingCharacters(in: .whitespaces)
        let output = try await run(["site", "snapshot", site] + (tag.isEmpty ? [] : ["--label", tag]) + ["--json", "--bench-dir", bench],
                                   timeout: Timeout.long, acceptExitCodes: [0])
        return try BenchJSON.decode(SiteSnapshotResult.self, from: Data(output.stdout.utf8))
    }

    /// benchbar site rollback NAME --to ID --dry-run --json: the plan and its token. Read only. The person's
    /// environment is in it because the plan of the default site is an agent's refusal and a person's plan.
    func rollbackPlan(site: String, snapshot: String, noMigrate: Bool, bench: String) async throws(CLIError) -> SiteRestorePlan {
        let output = try await run(["site", "rollback", site, "--to", snapshot] + (noMigrate ? ["--no-migrate"] : []) + ["--dry-run", "--json", "--bench-dir", bench],
                                   timeout: Timeout.doctor, acceptExitCodes: [0], extraEnvironment: Self.person)
        return try BenchJSON.decode(SiteRestorePlan.self, from: Data(output.stdout.utf8))
    }

    /// benchbar site rollback NAME --to ID --apply TOKEN --yes --json: runs the plan the person saw. The CLI
    /// snapshots the current state first, so the rollback can be undone, and refuses a token that no longer matches.
    func rollback(site: String, snapshot: String, noMigrate: Bool, token: String, bench: String) async throws(CLIError) -> RollbackResult {
        let output = try await run(["site", "rollback", site, "--to", snapshot] + (noMigrate ? ["--no-migrate"] : []) + ["--apply", token, "--yes", "--json", "--bench-dir", bench],
                                   timeout: Timeout.install, acceptExitCodes: [0], extraEnvironment: Self.person)
        return (try? BenchJSON.decode(RollbackResult.self, from: Data(output.stdout.utf8))) ?? RollbackResult()
    }

    /// benchbar site snapshot drop NAME ID --yes: removes one snapshot. A person's decision in the CLI (an agent is refused),
    /// and the app asks first. The undo point of a rollback needs `--force-undo-point`, which the app never passes.
    @discardableResult
    func dropSnapshot(site: String, snapshot: String, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["site", "snapshot", "drop", site, snapshot, "--yes", "--plain", "--bench-dir", bench],
                      timeout: Timeout.action, acceptExitCodes: [0], extraEnvironment: Self.person)
    }

    // MARK: the team lockfile

    /// benchbar lock write --dry-run: the file it would write or the changes to it, as text. Read only.
    func lockWritePlan(bench: String) async throws(CLIError) -> LockPlan {
        let output = try await run(["lock", "write", "--dry-run", "--plain", "--bench-dir", bench], timeout: Timeout.doctor, acceptExitCodes: [0])
        return LockPlan.parse(output)
    }

    /// benchbar lock write --yes: writes benchbar.toml (an existing one is backed up first) and remembers it as this bench's lockfile.
    @discardableResult
    func writeLock(bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["lock", "write", "--yes", "--plain", "--bench-dir", bench], timeout: Timeout.action, acceptExitCodes: [0])
    }

    /// benchbar lock apply --dry-run --json: the changes to the apps, as text, and the token when the CLI has one (0.9 and later
    /// with plan tokens). Read only.
    func lockApplyPlan(bench: String) async throws(CLIError) -> LockPlan {
        let output = try await run(["lock", "apply", "--dry-run", "--json", "--bench-dir", bench], timeout: Timeout.doctor, acceptExitCodes: [0])
        return LockPlan.parse(output)
    }

    /// benchbar lock apply --apply TOKEN --yes, or `lock apply --yes` for a CLI that gives no token: the person saw the plan
    /// in the app, and the CLI clones missing apps, switches branches and fast forwards to the pins. No site is touched.
    @discardableResult
    func applyLock(token: String?, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["lock", "apply"] + (token.map { ["--apply", $0] } ?? []) + ["--yes", "--plain", "--bench-dir", bench],
                      timeout: Timeout.long, acceptExitCodes: [0])
    }
}

/// One read of the log: which file, which process and since when.
nonisolated struct LogRequest: Equatable, Sendable {
    var process: String?
    var previous = false
    var sinceRestart = false
    /// The poll's cursor: the time of the newest line seen. The CLI keeps lines at or after it.
    var since: Date?
    var lines = 2000

    var arguments: [String] {
        var args = ["logs", "--json", "--no-follow", "-n", String(lines)]
        if let process { args += ["--process", process] }
        // there is no previous worker log: `--process worker` reads logs/worker.log
        if previous && process != "worker" { args.append("--previous") }
        if let since {
            args += ["--since", ISO8601DateFormatter().string(from: since)]
        } else if sinceRestart {
            args.append("--since-restart")
        }
        return args
    }
}

/// `lock write` and `lock apply` print their plan as text (the CLI has no JSON plan for the lockfile yet); a CLI that
/// gives `lock apply --dry-run --json` a `plan` event with a token has the app apply by it.
nonisolated struct LockPlan: Equatable, Sendable {
    /// The plan's lines, without the header box and the run's own bookkeeping.
    var lines: [String]
    var token: String?
    /// "unchanged": nothing to write or apply.
    var unchanged: Bool

    static func parse(_ output: CommandOutput) -> LockPlan {
        var token: String?
        for line in output.stdout.split(separator: "\n") where line.contains("\"event\":\"plan\"") {
            token = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["token"] as? String
        }
        let text = CLIText.plain((output.stderr + "\n" + (token == nil && !output.stdout.contains("\"event\"") ? output.stdout : "")))
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !(t.hasPrefix("+-") || t.hasPrefix("| ") || t.hasPrefix("..") && t.contains("lockfile "))
        }
        var lines = Array(kept.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return LockPlan(lines: lines, token: token, unchanged: text.contains("unchanged:"))
    }

    var text: String { lines.joined(separator: "\n") }
}
