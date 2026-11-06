import Foundation

/// The `benchbar share …` calls the host side makes, so tests need no process.
nonisolated protocol ShareCLI: Sendable {
    func shareStatus(bench: String, preflight: Bool) async throws(CLIError) -> ShareStatus
    func shareCode(bench: String, new: Bool) async throws(CLIError) -> ShareCode
    func shareInvite(bench: String, installURL: String?) async throws(CLIError) -> ShareInviteMessage
    func sharePeople(bench: String) async throws(CLIError) -> SharePeople
    func shareUsers(bench: String, site: String) async throws(CLIError) -> ShareUsers
    func shareLog(bench: String, device: String?, since: String?, limit: Int) async throws(CLIError) -> ShareLog
    func shareSetupPlan(bench: String, request: ShareSetupRequest) async throws(CLIError) -> ShareSetupPlan
    func shareSetup(bench: String, request: ShareSetupRequest, onStep: @escaping @Sendable (String) -> Void) async throws(CLIError)
    func shareStart(bench: String, forHours hours: Int, label: String?) async throws(CLIError)
    func shareStop(bench: String) async throws(CLIError)
    func shareExtend(bench: String, byMinutes minutes: Int) async throws(CLIError)
    func shareLock(bench: String, locked: Bool) async throws(CLIError)
    func shareRemove(bench: String, person: String, newCode: Bool) async throws(CLIError)
    func shareAssign(bench: String, person: String, seat: String) async throws(CLIError)
    func shareOpenAs(bench: String, user: String) async throws(CLIError)
    func shareTeardown(bench: String) async throws(CLIError)
    func lanGuardInstall() async throws(CLIError)
    func lanGuardAllowNode() async throws(CLIError)
}

/// What the setup sheet asks `share setup` for.
nonisolated struct ShareSetupRequest: Sendable, Equatable {
    var site: String
    var users: [String]
    /// true: back up the site now and copy that; false: the newest backup.
    var backupNow: Bool
    /// Replace the copy that is there (Refresh copy…).
    var refresh: Bool

    var arguments: [String] {
        ["--site", site, "--users", users.joined(separator: ",")]
            + (backupNow ? ["--backup-now"] : ["--from", "latest"])
            + (refresh ? ["--refresh"] : [])
    }
}

extension CLIClient: ShareCLI {
    /// The calls a person makes from the app and the CLI refuses without a
    /// terminal (setup, start, teardown, open-as, lan-guard): the app's own
    /// alert came first, so they say they come from the app (U3).
    static let personEnvironment = ["BENCHBAR_NONINTERACTIVE": "0"].merging(guiSudo) { _, new in new }

    func shareStatus(bench: String, preflight: Bool) async throws(CLIError) -> ShareStatus {
        let output = try await run(["share", "status"] + (preflight ? ["--preflight"] : []) + ["--json", "--bench-dir", bench],
                                   timeout: Timeout.doctor, acceptExitCodes: [0], qos: .utility)
        return try BenchJSON.decode(ShareStatus.self, from: Data(output.stdout.utf8))
    }

    /// The code is in this stdout and nowhere else. A failure to read it must
    /// not repeat stdout, so a decoding error carries no preview. The CLI
    /// gives the code only to a terminal or to the app (BENCHBAR_SUDO=gui).
    func shareCode(bench: String, new: Bool) async throws(CLIError) -> ShareCode {
        let output = try await run(["share", "code"] + (new ? ["--new"] : []) + ["--json", "--bench-dir", bench],
                                   timeout: Timeout.action, acceptExitCodes: [0],
                                   extraEnvironment: Self.personEnvironment)
        do throws(CLIError) {
            return try BenchJSON.decode(ShareCode.self, from: Data(output.stdout.utf8))
        } catch {
            throw .invalidJSON(detail: "share code", preview: "")
        }
    }

    /// Like `shareCode`: the invite holds the code, so it is read as a person from the app
    /// and a failed read repeats nothing of stdout. Read leniently: only `text` is needed,
    /// and a missing `schema_version` is accepted.
    func shareInvite(bench: String, installURL: String?) async throws(CLIError) -> ShareInviteMessage {
        let install = installURL.flatMap { $0.isEmpty ? nil : ["--install-url", $0] } ?? []
        let output = try await run(["share", "invite"] + install + ["--json", "--bench-dir", bench],
                                   timeout: Timeout.action, acceptExitCodes: [0],
                                   extraEnvironment: Self.personEnvironment)
        do {
            return try JSONDecoder().decode(ShareInviteMessage.self, from: Data(output.stdout.utf8))
        } catch {
            throw .invalidJSON(detail: "share invite", preview: "")
        }
    }

    func sharePeople(bench: String) async throws(CLIError) -> SharePeople {
        let output = try await run(["share", "people", "--json", "--bench-dir", bench],
                                   timeout: Timeout.query, acceptExitCodes: [0], qos: .utility)
        return try BenchJSON.decode(SharePeople.self, from: Data(output.stdout.utf8))
    }

    func shareUsers(bench: String, site: String) async throws(CLIError) -> ShareUsers {
        let output = try await run(["share", "users", "--site", site, "--json", "--bench-dir", bench],
                                   timeout: Timeout.doctor, acceptExitCodes: [0])
        return try BenchJSON.decode(ShareUsers.self, from: Data(output.stdout.utf8))
    }

    func shareLog(bench: String, device: String?, since: String?, limit: Int) async throws(CLIError) -> ShareLog {
        var args = ["share", "log", "--limit", String(limit)]
        if let device { args += ["--device", device] }
        if let since { args += ["--since", since] }
        let output = try await run(args + ["--json", "--bench-dir", bench], timeout: Timeout.query, acceptExitCodes: [0], qos: .utility)
        return try BenchJSON.decode(ShareLog.self, from: Data(output.stdout.utf8))
    }

    /// `share setup --dry-run --json`: one `plan` event line; nothing changes.
    func shareSetupPlan(bench: String, request: ShareSetupRequest) async throws(CLIError) -> ShareSetupPlan {
        let output = try await run(["share", "setup"] + request.arguments + ["--dry-run", "--json", "--bench-dir", bench],
                                   timeout: Timeout.doctor, acceptExitCodes: [0], extraEnvironment: Self.personEnvironment)
        for line in output.stdout.split(separator: "\n") where line.contains("\"event\":\"plan\"") {
            return try BenchJSON.decode(ShareSetupPlan.self, from: Data(line.utf8))
        }
        throw .invalidJSON(detail: "share setup printed no plan", preview: "")
    }

    /// The copy: backup, copy, harden. `onStep` gets each step's name as it starts.
    func shareSetup(bench: String, request: ShareSetupRequest, onStep: @escaping @Sendable (String) -> Void) async throws(CLIError) {
        let args = ["share", "setup"] + request.arguments + ["--acknowledge-data", "--yes", "--json", "--bench-dir", bench]
        let collected = LineBuffer()
        let code = try await runner.stream(executable: executable, arguments: args,
                                           environment: environment().merging(Self.personEnvironment) { _, new in new },
                                           timeout: Timeout.long) { line in
            collected.append(line)
            if let step = ShareStepLine.stepName(line) { onStep(step) }
        }
        guard code == 0 else {
            throw .failed(command: "share", exitCode: code, message: ShareStepLine.failure(collected.lines) ?? "share setup failed.")
        }
    }

    func shareStart(bench: String, forHours hours: Int, label: String?) async throws(CLIError) {
        let labelArgs = label.flatMap { $0.isEmpty ? nil : ["--name", $0] } ?? []
        _ = try await run(["share", "start", "--for", "\(hours)h"] + labelArgs + ["--plain", "--bench-dir", bench],
                          timeout: Timeout.action, acceptExitCodes: [0], extraEnvironment: Self.personEnvironment)
    }

    func shareStop(bench: String) async throws(CLIError) {
        _ = try await run(["share", "stop", "--plain", "--bench-dir", bench], timeout: Timeout.action, acceptExitCodes: [0])
    }

    func shareExtend(bench: String, byMinutes minutes: Int) async throws(CLIError) {
        _ = try await run(["share", "extend", "--by", "\(minutes)m", "--plain", "--bench-dir", bench],
                          timeout: Timeout.action, acceptExitCodes: [0])
    }

    func shareLock(bench: String, locked: Bool) async throws(CLIError) {
        _ = try await run(["share", locked ? "lock" : "unlock", "--plain", "--bench-dir", bench],
                          timeout: Timeout.action, acceptExitCodes: [0])
    }

    /// `--yes`: the app's confirm alert asked. `--new-code` never prints the code.
    func shareRemove(bench: String, person: String, newCode: Bool) async throws(CLIError) {
        _ = try await run(["share", "remove", person, "--yes"] + (newCode ? ["--new-code"] : []) + ["--plain", "--bench-dir", bench],
                          timeout: Timeout.action, acceptExitCodes: [0])
    }

    func shareAssign(bench: String, person: String, seat: String) async throws(CLIError) {
        _ = try await run(["share", "assign", person, seat, "--plain", "--bench-dir", bench],
                          timeout: Timeout.action, acceptExitCodes: [0])
    }

    /// Opens the copy signed in as `user`. The sign-in link holds a session
    /// id, so the CLI opens it itself and `--json` never carries it.
    func shareOpenAs(bench: String, user: String) async throws(CLIError) {
        _ = try await run(["share", "open-as", user, "--json", "--bench-dir", bench],
                          timeout: Timeout.action, acceptExitCodes: [0], extraEnvironment: Self.personEnvironment)
    }

    func shareTeardown(bench: String) async throws(CLIError) {
        _ = try await run(["share", "teardown", "--yes", "--plain", "--bench-dir", bench],
                          timeout: Timeout.long, acceptExitCodes: [0], extraEnvironment: Self.personEnvironment)
    }

    /// UNVERIFIED: `benchbar lan-guard` was not on this branch's CLI when this
    /// was written; the words come from the share preflight's fix strings.
    /// Check them against the real command here, in one place.
    static let lanGuardArguments = (install: ["lan-guard", "install", "--yes", "--plain"],
                                    allowNode: ["lan-guard", "allow-node", "--yes", "--plain"])

    /// Network protection (the pf rules) needs root: macOS's own password
    /// dialog asks, through BENCHBAR_SUDO=gui, after the app's sheet.
    func lanGuardInstall() async throws(CLIError) {
        _ = try await run(Self.lanGuardArguments.install, timeout: Timeout.long, acceptExitCodes: [0],
                          extraEnvironment: Self.personEnvironment)
    }

    func lanGuardAllowNode() async throws(CLIError) {
        _ = try await run(Self.lanGuardArguments.allowNode, timeout: Timeout.long, acceptExitCodes: [0],
                          extraEnvironment: Self.personEnvironment)
    }
}

/// Lines a streaming command printed, collected from the runner's callback.
nonisolated final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
}

/// Reads the JSON lines of a share stream (`{"event":"step","action":…}`).
nonisolated enum ShareStepLine {
    static func stepName(_ line: String) -> String? {
        guard let object = object(line), object["event"] as? String == "step" else { return nil }
        return object["action"] as? String ?? object["step"] as? String
    }

    /// The reason the stream failed, if any: the failed step's `message` (its `[FAIL]` line) first,
    /// since the done line's `error` only names the step ("share setup stopped at: …"). A refusal
    /// before the first step (a check, an interrupted setup) has no failed step and is only in the
    /// done line's `error`.
    static func failure(_ lines: [String]) -> String? {
        let objects = lines.reversed().compactMap(object)
        let failedStep = objects.first { $0["event"] as? String == "step" && $0["status"] as? String == "failed" }
        let done = objects.first { $0["event"] as? String == "done" }
        for (object, key) in [(failedStep, "message"), (done, "error"), (done, "message")] {
            if let text = object?[key] as? String, !text.isEmpty { return CLIText.plain(text) }
        }
        return nil
    }

    private static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
