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
/// install go to that one process, never on a command line, to disk or to a
/// log: on its standard input when the CLI lists `--secrets-stdin`, else in its
/// environment, as `addSite`'s do.
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
        let stdinBytes = await takesSecretsStdin("install") ? Self.secretList([("ADMIN_PASSWORD", adminPassword)]) : nil
        let args = ["install", "--dry-run", "--json"] + request.flags + (stdinBytes == nil ? [] : ["--secrets-stdin"])
        let output = try await run(args, timeout: Timeout.doctor, acceptExitCodes: [0, 1],
                                   extraEnvironment: stdinBytes == nil ? ["ADMIN_PASSWORD": adminPassword] : [:], input: stdinBytes)
        let events = try InstallEvent.decodeAll(output.stdout)
        // a dry run that ends unsuccessfully (no free port block, a profile
        // ref that is gone) has no plan to review, even when it sent one
        for case .done(let done) in events where done.exit != 0 {
            throw .failed(command: "install", exitCode: Int32(done.exit), message: done.error ?? done.fix ?? Self.summarize(output))
        }
        guard output.exitCode == 0 else {
            throw .failed(command: "install", exitCode: output.exitCode, message: Self.summarize(output))
        }
        for case .plan(let plan) in events { return plan }
        throw .failed(command: "install", exitCode: output.exitCode, message: Self.summarize(output))
    }

    /// `install --yes --json`, every event handed over as it arrives. The
    /// user started it from the Review page, which is the confirmation, so
    /// `--yes` is passed here and nowhere else. The two privileged steps ask in
    /// macOS's password dialog (BENCHBAR_SUDO=gui). `rootPassword` is the MariaDB
    /// root password, only after the CLI answered exit 2. `token` is the plan the
    /// user reviewed: with it the CLI refuses a plan that changed since, before any
    /// dialog or step; a run again after a failure passes none.
    /// Returns the process's exit code; cancelling the task stops the process
    /// (SIGTERM, which the CLI forwards to its process group).
    func install(_ request: InstallRequest, adminPassword: String, rootPassword: String? = nil, token: String? = nil,
                 onEvent: @escaping @Sendable (InstallEvent) -> Void) async throws(CLIError) -> Int32 {
        var env = environment().merging(Self.guiSudo) { _, new in new }
        // a CLI that lists --secrets-stdin gets the passwords on its standard input, in no environment; an older one keeps the variables
        let stdinBytes = await takesSecretsStdin("install") ? Self.secretList([("ADMIN_PASSWORD", adminPassword), ("MARIADB_ROOT_PASSWORD", rootPassword)]) : nil
        if stdinBytes == nil {
            env["ADMIN_PASSWORD"] = adminPassword
            if let rootPassword, !rootPassword.isEmpty { env["MARIADB_ROOT_PASSWORD"] = rootPassword }
        }
        let apply = token.map { ["--apply", $0] } ?? []
        return try await stream(["install", "--yes", "--json"] + apply + request.flags + (stdinBytes == nil ? [] : ["--secrets-stdin"]), environment: env,
                                timeout: Timeout.install, input: stdinBytes, onEvent: onEvent)
    }

    /// `adopt PATH --yes --json`: the same stream as an install, the service
    /// steps of a bench that already exists.
    func adopt(bench: String, onEvent: @escaping @Sendable (InstallEvent) -> Void) async throws(CLIError) -> Int32 {
        try await stream(["adopt", bench, "--yes", "--json"], environment: environment().merging(Self.guiSudo) { _, new in new },
                         timeout: Timeout.install, onEvent: onEvent)
    }

    /// `site hosts --yes`: adds the missing hosts lines. The password dialog is
    /// macOS's own (BENCHBAR_SUDO=gui); a cancelled dialog is a [WARN] line, not
    /// a failed command. The caller classifies the output (`HostsOutcome`). It waits on a
    /// person at the dialog, so it gets the long timeout: a timeout would kill the dialog.
    func siteHosts(bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["site", "hosts", "--yes", "--bench-dir", bench], timeout: Timeout.install, acceptExitCodes: [0, 1],
                      extraEnvironment: Self.guiSudo)
    }

    /// The CLI lists `--secrets-stdin` for `command`. An older CLI, or no answer, means no: the environment path then runs as before.
    func takesSecretsStdin(_ command: String) async -> Bool {
        guard let catalog = try? await self.commands() else { return false }
        return catalog.hasFlag(command, "--secrets-stdin")
    }

    /// The bytes of the list `--secrets-stdin` reads: one `KEY=VALUE` line per password, each ended by LF, then the empty line that ends
    /// the list (UTF-8, no byte order mark). `nil` when there is no password, or one holds a line break (a list is one line each, and
    /// the environment path has the CLI's own refusal for such a password).
    static func secretList(_ entries: [(key: String, value: String?)]) -> [UInt8]? {
        var text = ""
        for entry in entries {
            guard let secret = entry.value, !secret.isEmpty else { continue }
            if secret.contains("\n") || secret.contains("\r") { return nil }
            text += "\(entry.key)=\(secret)\n"
        }
        return text.isEmpty ? nil : Array((text + "\n").utf8)
    }

    private func stream(_ arguments: [String], environment: [String: String], timeout: Duration, input: [UInt8]? = nil,
                        onEvent: @escaping @Sendable (InstallEvent) -> Void) async throws(CLIError) -> Int32 {
        let issue = StreamIssue()
        let code = try await runner.stream(executable: executable, arguments: arguments, environment: environment,
                                           timeout: timeout, input: input) { line in
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
