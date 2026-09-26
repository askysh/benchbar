import Foundation

/// The only door from the app to the bench. Every method runs
/// `benchbar <command> ...` by absolute path and decodes its JSON.
///
/// The app never writes plists, never edits bench files, and never runs
/// bench, brew or launchctl itself: that is the CLI's job.
nonisolated struct CLIClient: Sendable {
    let executable: URL
    var runner: any CommandRunning = SubprocessRunner()
    var locator = CLILocator()

    /// Timeouts per kind of call. `up` and `restart` wait for the site to
    /// answer (45 seconds in the CLI), so they get more room.
    enum Timeout {
        static let query: Duration = .seconds(20)
        static let doctor: Duration = .seconds(90)
        static let action: Duration = .seconds(120)
        /// get-app, new-site, an update with migrate and build: minutes, not seconds
        static let long: Duration = .seconds(45 * 60)
    }

    /// Environment for the CLI: an explicit PATH (Finder launched apps do
    /// not get the shell's), no colors, no spinners.
    func environment() -> [String: String] {
        [
            "PATH": locator.searchPath(),
            "NO_COLOR": "1",
            "TERM": "dumb",
            "LANG": "en_US.UTF-8",
        ]
    }

    // MARK: queries (read only, safe to poll)

    func list() async throws(CLIError) -> BenchList {
        let output = try await run(["list", "--json"], timeout: Timeout.query, acceptExitCodes: [0])
        return try BenchJSON.decode(BenchList.self, from: Data(output.stdout.utf8))
    }

    func status(bench: String) async throws(CLIError) -> BenchStatus {
        let output = try await run(["status", "--json", "--bench-dir", bench], timeout: Timeout.query, acceptExitCodes: [0])
        return try BenchJSON.decode(BenchStatus.self, from: Data(output.stdout.utf8))
    }

    /// doctor exits 1 when a check fails but still prints the full report.
    func doctor(bench: String) async throws(CLIError) -> DoctorReport {
        let output = try await run(["doctor", "--json", "--bench-dir", bench], timeout: Timeout.doctor, acceptExitCodes: [0, 1])
        return try BenchJSON.decode(DoctorReport.self, from: Data(output.stdout.utf8))
    }

    func version() async throws(CLIError) -> String {
        let output = try await run(["--version"], timeout: Timeout.query, acceptExitCodes: [0])
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: actions

    enum Action: String, Sendable, CaseIterable {
        case up, down, restart
    }

    /// Runs up, down or restart. No --yes: if the CLI would need to ask
    /// (for example a port clash), it answers no and fails with a message.
    @discardableResult
    func perform(_ action: Action, bench: String) async throws(CLIError) -> CommandOutput {
        try await run([action.rawValue, "--plain", "--bench-dir", bench], timeout: Timeout.action, acceptExitCodes: [0])
    }

    /// benchbar service --with-schedule (or --without-schedule). --yes because
    /// the app asked the user already: service shows a plan and asks, and
    /// with stdin closed it would answer no.
    @discardableResult
    func setScheduler(_ on: Bool, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["service", "--yes", "--plain", on ? "--with-schedule" : "--without-schedule", "--bench-dir", bench],
                      timeout: Timeout.action, acceptExitCodes: [0])
    }

    // MARK: 0.5: apps, sites, profiles, repair
    //
    // Every command that changes something asks for confirmation in the CLI.
    // The app asks first in its own dialog, so these pass --yes; stdin stays
    // closed, and nothing here needs sudo (a hosts line is shown as a
    // Terminal command instead).

    func apps(bench: String, liveSites: Bool = true) async throws(CLIError) -> AppList {
        var args = ["app", "list", "--json", "--bench-dir", bench]
        if !liveSites { args.insert("--no-sites", at: 3) }
        let output = try await run(args, timeout: liveSites ? Timeout.doctor : Timeout.query, acceptExitCodes: [0])
        return try BenchJSON.decode(AppList.self, from: Data(output.stdout.utf8))
    }

    /// benchbar app add SOURCE: a name from the app registry or any git URL.
    @discardableResult
    func addApp(_ source: String, branch: String?, site: String?, bench: String) async throws(CLIError) -> CommandOutput {
        var args = ["app", "add", source, "--yes", "--plain", "--bench-dir", bench]
        if let branch, !branch.isEmpty { args += ["--branch", branch] }
        if let site, !site.isEmpty { args += ["--site", site] }
        return try await run(args, timeout: Timeout.long, acceptExitCodes: [0])
    }

    @discardableResult
    func installApp(_ app: String, site: String, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["app", "install", app, "--site", site, "--yes", "--plain", "--bench-dir", bench],
                      timeout: Timeout.long, acceptExitCodes: [0])
    }

    func updatePlan(app: String, bench: String) async throws(CLIError) -> AppUpdatePlan {
        let output = try await run(["app", "update", app, "--dry-run", "--json", "--bench-dir", bench],
                                   timeout: Timeout.doctor, acceptExitCodes: [0])
        return try BenchJSON.decode(AppUpdatePlan.self, from: Data(output.stdout.utf8))
    }

    @discardableResult
    func updateApp(_ app: String, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["app", "update", app, "--yes", "--plain", "--bench-dir", bench], timeout: Timeout.long, acceptExitCodes: [0])
    }

    /// benchbar site add NAME: the Administrator password goes in the
    /// environment of that one process (ADMIN_PASSWORD, as the CLI reads it),
    /// never on a command line. The hosts line needs sudo, which a process
    /// without a terminal cannot ask for: the CLI skips it and says so.
    @discardableResult
    func addSite(_ name: String, adminPassword: String, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["site", "add", name, "--yes", "--plain", "--bench-dir", bench],
                      timeout: Timeout.long, acceptExitCodes: [0], extraEnvironment: ["ADMIN_PASSWORD": adminPassword])
    }

    @discardableResult
    func setDefaultSite(_ name: String, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["site", "default", name, "--plain", "--bench-dir", bench], timeout: Timeout.action, acceptExitCodes: [0])
    }

    func profiles() async throws(CLIError) -> ProfileList {
        let output = try await run(["profile", "list", "--json"], timeout: Timeout.query, acceptExitCodes: [0])
        return try BenchJSON.decode(ProfileList.self, from: Data(output.stdout.utf8))
    }

    @discardableResult
    func createProfile(_ name: String, fromBench bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["profile", "create", name, "--from-bench", bench, "--yes", "--plain"], timeout: Timeout.doctor, acceptExitCodes: [0])
    }

    /// The repair plan only (repair --dry-run --json prints one plan line).
    func repairPlan(bench: String) async throws(CLIError) -> [RepairEvent.Action] {
        let output = try await run(["repair", "--dry-run", "--json", "--bench-dir", bench], timeout: Timeout.doctor, acceptExitCodes: [0, 1])
        for line in output.stdout.split(separator: "\n") {
            if case .plan(let actions, _)? = RepairEvent.parse(String(line)) { return actions }
        }
        throw .failed(command: "repair", exitCode: output.exitCode, message: Self.summarize(output))
    }

    /// repair --yes --json, with every event handed over as it arrives.
    func repair(bench: String, onEvent: @escaping @Sendable (RepairEvent) -> Void) async throws(CLIError) -> Int32 {
        try await runner.stream(executable: executable, arguments: ["repair", "--yes", "--json", "--bench-dir", bench],
                                environment: environment(), timeout: Timeout.long) { line in
            if let event = RepairEvent.parse(line) { onEvent(event) }
        }
    }

    // MARK: plumbing

    func run(_ arguments: [String], timeout: Duration, acceptExitCodes: Set<Int32>,
             extraEnvironment: [String: String] = [:]) async throws(CLIError) -> CommandOutput {
        let env = environment().merging(extraEnvironment) { _, new in new }
        let output = try await runner.run(executable: executable, arguments: arguments, environment: env, timeout: timeout)
        guard acceptExitCodes.contains(output.exitCode) else {
            throw .failed(command: arguments.first ?? "", exitCode: output.exitCode, message: Self.summarize(output))
        }
        return output
    }

    /// The most useful lines of a failed run: [FAIL] and [WARN] lines first,
    /// then the last lines of stderr and stdout.
    static func summarize(_ output: CommandOutput) -> String {
        let lines = (output.stderr + "\n" + output.stdout)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let flagged = lines.filter { $0.hasPrefix("[FAIL]") || $0.hasPrefix("[WARN]") || $0.hasPrefix("Aborting.") }
        let chosen = flagged.isEmpty ? Array(lines.suffix(3)) : Array(flagged.prefix(3))
        return chosen.joined(separator: "\n")
    }
}
