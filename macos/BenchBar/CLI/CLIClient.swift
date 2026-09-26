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

    // MARK: plumbing

    func run(_ arguments: [String], timeout: Duration, acceptExitCodes: Set<Int32>) async throws(CLIError) -> CommandOutput {
        let output = try await runner.run(executable: executable, arguments: arguments, environment: environment(), timeout: timeout)
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
