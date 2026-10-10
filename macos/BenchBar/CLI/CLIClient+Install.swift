import Foundation

/// What the first run wizard chose, as the flags `install` takes. No
/// password here: the Administrator password goes in the environment.
nonisolated struct InstallRequest: Equatable, Sendable {
    var benchDir: String
    var profile: String
    var bundle: String
    var site: String
    var portOffset: Int?

    /// `--bench-dir ... --profile ... --bundle ... --site ... [--port-offset N]`
    var flags: [String] {
        ["--bench-dir", benchDir, "--profile", profile, "--bundle", bundle, "--site", site]
            + (portOffset.map { ["--port-offset", String($0)] } ?? [])
    }
}

/// Install, adopt and the checks before them (CLI 0.8). The passwords of an
/// install go in the environment of that one process, as `addSite`'s do,
/// never on a command line, to disk or to a log.
extension CLIClient {
    /// `doctor --prerequisites --json`: what the Mac needs before an install,
    /// with no bench. Exit 1 means a check fails; the report is still printed.
    func prerequisites(bench: String?) async throws(CLIError) -> PrerequisiteReport {
        var args = ["doctor", "--prerequisites", "--json"]
        if let bench { args += ["--bench-dir", bench] }
        let output = try await run(args, timeout: Timeout.doctor, acceptExitCodes: [0, 1])
        return try BenchJSON.decode(PrerequisiteReport.self, from: Data(output.stdout.utf8))
    }

    /// `install --dry-run --json`: the plan line only, nothing changes. The
    /// Administrator password is in its environment too: a CLI that checks its
    /// inputs before the dry run would refuse the plan without it. The privileged
    /// steps do not run here, so no BENCHBAR_SUDO.
    func installPlan(_ request: InstallRequest, adminPassword: String) async throws(CLIError) -> InstallPlan {
        let args = ["install", "--dry-run", "--json"] + request.flags
        let output = try await run(args, timeout: Timeout.doctor, acceptExitCodes: [0, 1],
                                   extraEnvironment: ["ADMIN_PASSWORD": adminPassword])
        let events = try InstallEvent.decodeAll(output.stdout)
        for case .plan(let plan) in events { return plan }
        for case .done(let done) in events {
            throw .failed(command: "install", exitCode: Int32(done.exit), message: done.error ?? done.fix ?? Self.summarize(output))
        }
        throw .failed(command: "install", exitCode: output.exitCode, message: Self.summarize(output))
    }

    /// `install --yes --json`, every event handed over as it arrives. The
    /// user started it from the Review page, which is the confirmation, so
    /// `--yes` is passed here and nowhere else. The two privileged steps ask in
    /// macOS's password dialog (BENCHBAR_SUDO=gui). `rootPassword` is the MariaDB
    /// root password, only after the CLI answered exit 2.
    /// Returns the process's exit code; cancelling the task stops the process
    /// (SIGTERM, which the CLI forwards to its process group).
    func install(_ request: InstallRequest, adminPassword: String, rootPassword: String? = nil,
                 onEvent: @escaping @Sendable (InstallEvent) -> Void) async throws(CLIError) -> Int32 {
        var env = environment().merging(Self.guiSudo) { _, new in new }
        env["ADMIN_PASSWORD"] = adminPassword
        if let rootPassword, !rootPassword.isEmpty { env["MARIADB_ROOT_PASSWORD"] = rootPassword }
        return try await stream(["install", "--yes", "--json"] + request.flags, environment: env,
                                timeout: Timeout.install, onEvent: onEvent)
    }

    /// `adopt PATH --yes --json`: the same stream as an install, the service
    /// steps of a bench that already exists.
    func adopt(bench: String, onEvent: @escaping @Sendable (InstallEvent) -> Void) async throws(CLIError) -> Int32 {
        try await stream(["adopt", bench, "--yes", "--json"], environment: environment().merging(Self.guiSudo) { _, new in new },
                         timeout: Timeout.install, onEvent: onEvent)
    }

    /// `site hosts --yes`: adds the missing hosts lines. The password dialog is
    /// macOS's own (BENCHBAR_SUDO=gui); a cancelled dialog is a [WARN] line, not
    /// a failed command. The caller classifies the output (`HostsOutcome`).
    func siteHosts(bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["site", "hosts", "--yes", "--bench-dir", bench], timeout: Timeout.action, acceptExitCodes: [0, 1],
                      extraEnvironment: Self.guiSudo)
    }

    private func stream(_ arguments: [String], environment: [String: String], timeout: Duration,
                        onEvent: @escaping @Sendable (InstallEvent) -> Void) async throws(CLIError) -> Int32 {
        let issue = StreamIssue()
        let code = try await runner.stream(executable: executable, arguments: arguments, environment: environment,
                                           timeout: timeout) { line in
            do throws(CLIError) {
                if let event = try InstallEvent.decode(line) { onEvent(event) }
            } catch {
                issue.record(error)
            }
        }
        // lines of a newer schema were not read: say so once the run is over
        if let error = issue.error { throw error }
        return code
    }
}

/// The first error a stream's lines raised, kept until the run ends.
nonisolated final class StreamIssue: @unchecked Sendable {
    private let lock = NSLock()
    private var first: CLIError?

    func record(_ error: CLIError) { lock.withLock { if first == nil { first = error } } }
    var error: CLIError? { lock.withLock { first } }
}

/// What `site hosts` did, from its output.
nonisolated enum HostsOutcome: Equatable, Sendable {
    case added
    /// The password dialog was cancelled, or the step was skipped: the line is not there.
    case skipped(String)
    case failed(String)

    static func classify(_ output: CommandOutput) -> HostsOutcome {
        let lines = (output.stdout + "\n" + output.stderr).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let warns = lines.filter { $0.hasPrefix("[WARN]") }
        let cancelled = warns.first { $0.localizedCaseInsensitiveContains("cancel") || $0.localizedCaseInsensitiveContains("skipped") }
        if let cancelled { return .skipped(cancelled) }
        if output.exitCode == 0 { return .added }
        return .failed(CLIClient.summarize(output))
    }
}
