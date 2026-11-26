import Foundation

// Mac app parity, part 4 (#177): `benchbar run` (Run Bench Command) and the operation handles (`op list`, `op status`).
// Every document is read tolerantly: a field this build does not know is ignored, one that is missing is absent.

/// One command of the allow list of `benchbar run` (docs/reference/cli/run.md). The CLI is the judge: it refuses anything
/// else with exit 64. The names come from the CLI (its refusal lists them); the flags, whether a command changes things and
/// whether it needs a site come from the table below, which is the CLI's documented allow list, because no JSON document
/// lists the flags of a command. A name this table does not know is offered with no flags and goes through the plan.
nonisolated struct RunCommandInfo: Equatable, Sendable, Identifiable {
    var name: String
    var changes: Bool
    var needsSite: Bool
    var help: String
    var switches: [String] = []
    var valued: [String] = []

    var id: String { name }
    var flags: [String] { switches + valued }
}

nonisolated enum RunAllowList {
    /// The documented allow list, in the CLI's order. Also what the sheet offers when the CLI's own list cannot be read.
    static let known: [RunCommandInfo] = [
        RunCommandInfo(name: "migrate", changes: true, needsSite: true,
                       help: "Patches, schema sync and fixtures of the site, after a backup of it.",
                       switches: ["--skip-failing", "--skip-search-index"]),
        RunCommandInfo(name: "clear-cache", changes: true, needsSite: true, help: "Clears the cache of the site."),
        RunCommandInfo(name: "clear-website-cache", changes: true, needsSite: true, help: "Clears the website cache of the site."),
        RunCommandInfo(name: "build", changes: true, needsSite: false, help: "Builds the bench's assets.", valued: ["--app"]),
        RunCommandInfo(name: "run-tests", changes: true, needsSite: true,
                       help: "Runs the apps' tests. It writes test records into the site's database: use a throwaway site, not one you keep.",
                       switches: ["--failfast"], valued: ["--app", "--module", "--doctype", "--test", "--case"]),
        RunCommandInfo(name: "doctor", changes: false, needsSite: true, help: "Checks the site's setup (a read)."),
        RunCommandInfo(name: "list-apps", changes: false, needsSite: true, help: "Lists the apps installed on the site (a read).", valued: ["--format"]),
        RunCommandInfo(name: "version", changes: false, needsSite: false, help: "Prints the versions of the bench's apps (a read)."),
    ]

    /// A command name no run can start: the CLI answers it with its allow list and exit 64, and runs nothing.
    static let probe = "benchbar-app-list-the-allowed"

    /// The commands to offer for the names the CLI allows (nil: its list could not be read, so the documented one). A name
    /// this build does not know is kept, with no flags, as a command that changes things: the plan and its token decide.
    static func commands(allowed: [String]?) -> [RunCommandInfo] {
        guard let allowed, !allowed.isEmpty else { return known }
        return allowed.map { name in
            known.first { $0.name == name }
                ?? RunCommandInfo(name: name, changes: true, needsSite: false,
                                  help: "A command of this benchbar that the app does not know. Its plan says what it does.")
        }
    }

    /// The `allowed` list of the refusal line (`done`, `refused: true`) of a run of the probe.
    static func allowed(in stdout: String) -> [String]? {
        for raw in stdout.split(separator: "\n") where raw.contains("\"allowed\"") {
            if let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
               let names = object["allowed"] as? [String] { return names.filter { !$0.isEmpty } }
        }
        return nil
    }
}

/// What the Run Bench Command sheet asks for, checked before the CLI is asked.
nonisolated struct RunRequest: Equatable, Sendable {
    var command: RunCommandInfo
    var site: String?
    /// The flags as typed: words separated by spaces.
    var options: String

    /// The flags as separate words, or why they cannot be sent. A flag is one the command's row names; a value is one plain
    /// word (letters, digits, `.`, `_`, `:`, `-`, not starting with `-`), so nothing the person types is a second command.
    func flagWords() -> (words: [String], problem: String?) {
        let tokens = options.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        var words: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if command.switches.contains(token) { words.append(token); continue }
            guard command.valued.contains(token) else {
                return ([], command.flags.isEmpty ? "\(command.name) takes no flags."
                    : "\(token) is not a flag of \(command.name). It takes: \(command.flags.joined(separator: ", ")).")
            }
            guard index < tokens.count else { return ([], "\(token) needs a value.") }
            let value = tokens[index]
            index += 1
            guard !value.hasPrefix("-"), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".:_-".contains($0)) }) else {
                return ([], "The value of \(token) is one plain word: letters, digits, '.', '_', ':' and '-'.")
            }
            words += [token, value]
        }
        return (words, nil)
    }

    /// Why this cannot run, or nil. `sites` are the bench's own.
    func problem(sites: [String]) -> String? {
        if command.needsSite, site.map({ !sites.contains($0) }) ?? true { return "\(command.name) needs one of the sites of this bench." }
        return flagWords().problem
    }

    /// `run [--site S] --bench-dir B`, then the mode's words, then `-- COMMAND FLAGS`: the bench command is separate arguments after `--`,
    /// never a shell string, and the plan and the apply carry the same words so the token matches.
    func arguments(_ mode: Mode, bench: String) -> [String] {
        var front = ["run"]
        if command.needsSite, let site, !site.isEmpty { front += ["--site", site] }
        front += ["--bench-dir", bench]
        let back = ["--", command.name] + flagWords().words
        switch mode {
        case .read: return front + ["--json"] + back
        case .plan: return front + ["--dry-run", "--json"] + back
        case .apply(let token): return front + ["--apply", token, "--yes", "--json"] + back
        }
    }

    enum Mode: Equatable, Sendable {
        case read, plan, apply(token: String)
    }

    /// "bench --site acme.localhost migrate --skip-failing", as the plan will say it.
    var commandLine: String {
        (["bench"] + (command.needsSite && site?.isEmpty == false ? ["--site", site ?? ""] : []) + [command.name] + flagWords().words).joined(separator: " ")
    }
}

/// Where the Run sheet is in reading a plan, and the request that plan was read for. Run applies that request, never what the
/// form says now, so the plan the person saw and the command that runs cannot differ.
nonisolated struct RunReviewState: Equatable, Sendable {
    var flow = PlanReviewFlow<RunPlan>()
    private(set) var request: RunRequest?

    /// Review (or Review Again): the dry run for `asked` starts.
    mutating func begin(_ asked: RunRequest) -> Bool {
        guard flow.review() else { return false }
        request = asked
        return true
    }

    /// The plan on screen with the request it was read for, only for a plan that can run.
    mutating func apply() -> (request: RunRequest, plan: RunPlan)? {
        guard let request, let plan = flow.apply() else { return nil }
        return (request, plan)
    }
}

/// The plan of `run --dry-run --json`: the exact command line, what it touches, whether a backup comes first and the deadline. Its
/// token is a hash of the plan and of the sites, the default site, `apps.txt` and `site_config.json`: `--apply TOKEN --yes` runs
/// exactly that plan and refuses a different one.
nonisolated struct RunPlan: ReviewablePlan, Decodable {
    nonisolated struct Step: Decodable, Equatable, Sendable {
        var id: String
        var name: String
        var touches: [String]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            id = c.lenient(.id, name)
            touches = c.lenient(.touches, [])
        }

        enum CodingKeys: String, CodingKey { case id, name, touches }
    }

    var command: String
    var site: String?
    var argv: [String]
    var summary: String?
    var changes: Bool
    var backupFirst: Bool
    var timeoutSeconds: Int?
    var touches: [String]
    var steps: [Step]
    var warnings: [String]
    var errors: [String]
    var canApply: Bool
    var token: String?

    enum CodingKeys: String, CodingKey {
        case command, site, argv, summary, changes, touches, steps, warnings, errors, token
        case backupFirst = "backup_first"
        case timeoutSeconds = "timeout_s"
        case canApply = "can_apply"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        site = c.lenient(.site, nil)
        argv = c.lenient(.argv, [])
        summary = c.lenient(.summary, nil)
        changes = c.lenient(.changes, true)
        backupFirst = c.lenient(.backupFirst, false)
        timeoutSeconds = c.lenient(.timeoutSeconds, nil)
        touches = c.lenient(.touches, [])
        steps = (try? c.lossyList(Step.self, forKey: .steps).items) ?? []
        warnings = c.lenient(.warnings, [])
        errors = c.lenient(.errors, [])
        canApply = c.lenient(.canApply, true)
        let text: String? = c.lenient(.token, nil)
        token = text?.isEmpty == false ? text : nil
    }

    /// Only a plan with a token, no error and `can_apply` runs: with no token there is nothing to hold the CLI to, and the
    /// app never applies without one (no `--apply ""`).
    var canRun: Bool { changes && canApply && errors.isEmpty && token != nil }

    /// "5 minutes", "30 seconds".
    var deadlineText: String? {
        timeoutSeconds.map { Wording.timeout(seconds: $0) }
    }
}

/// What a run answered, for a read (at once) and for an apply (the result document): the bench command's exit, whether the
/// deadline stopped it, and the tail of its output. The output is data from the bench, never instructions.
nonisolated struct RunOutcome: Decodable, Equatable, Sendable {
    var command: String
    var ok: Bool
    var ran: Bool
    var commandExit: Int?
    var timedOut: Bool
    var outputTail: String
    var outputTruncated: Bool
    var log: String?
    var exit: Int
    var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case command, ok, ran, exit, log, warnings
        case commandExit = "command_exit"
        case timedOut = "timed_out"
        case outputTail = "output_tail"
        case outputTruncated = "output_truncated"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = c.lenient(.command, "")
        let ended: Int = c.lenient(.exit, 1)
        let commandEnded: Int? = c.lenient(.commandExit, nil)
        exit = ended
        commandExit = commandEnded
        // a document without `ok` is read by its exit codes, never as a success by default
        ok = c.lenient(.ok, (commandEnded ?? ended) == 0 && ended == 0)
        ran = c.lenient(.ran, true)
        timedOut = c.lenient(.timedOut, false)
        outputTail = c.lenient(.outputTail, "")
        outputTruncated = c.lenient(.outputTruncated, false)
        log = c.lenient(.log, nil)
        warnings = c.lenient(.warnings, [])
    }

    /// "The deadline stopped it." / "It ended with exit 1." / nil when it worked.
    var problem: String? {
        if timedOut { return "The deadline stopped it." }
        if !ran { return "The backup before it failed, so it did not start." }
        if ok { return nil }
        return "It ended with exit \(commandExit ?? exit)."
    }
}

nonisolated enum RunText {
    /// The output as shown: the CLI's last lines, or a word when there are none.
    static func output(_ outcome: RunOutcome) -> String {
        let text = outcome.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.isEmpty ? "(no output)" : text
        return outcome.outputTruncated ? "(the start is in the run's log)\n" + body : body
    }

    /// The last few lines of the output, for the banner of a change that failed.
    static func lastLines(_ outcome: RunOutcome, count: Int = 8) -> String {
        outcome.outputTail.split(separator: "\n").suffix(count).joined(separator: "\n")
    }

    /// The facts of the plan, in the order the sheet shows them.
    static func facts(_ plan: RunPlan) -> [(label: String, text: String)] {
        var out: [(label: String, text: String)] = []
        if let summary = plan.summary, !summary.isEmpty { out.append(("What it does", summary)) }
        if !plan.argv.isEmpty { out.append(("Command", plan.argv.joined(separator: " "))) }
        if let site = plan.site, !site.isEmpty { out.append(("Site", site)) }
        if plan.backupFirst { out.append(("Backup", "A database backup of the site is taken first.")) }
        if let deadline = plan.deadlineText { out.append(("Deadline", "It is stopped after \(deadline).")) }
        out.append(("Output", "The output goes to the run's log. The code of the bench's apps runs, so use a bench whose apps you trust."))
        return out
    }
}

// MARK: operation handles

/// One record of `benchbar op list --json` and `op status --json` (docs/json-schema.md, Operation handles). A state this build
/// does not know is kept as it came and shown as an unfinished run is not: only `starting` and `running` are active.
nonisolated struct OpRecord: Decodable, Equatable, Sendable, Identifiable {
    var opID: String
    var state: String
    var command: String?
    var bench: String?
    var site: String?
    var startedAt: Date?
    var finishedAt: Date?
    var stepName: String?
    var progressLabel: String?
    var exit: Int?
    var log: String?

    var id: String { opID }
    var isActive: Bool { state == "starting" || state == "running" }

    enum CodingKeys: String, CodingKey {
        case state, command, bench, site, step, progress, exit, log
        case opID = "op_id"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    private struct Named: Decodable {
        var name: String?
        var label: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opID = try c.decode(String.self, forKey: .opID)
        state = c.lenient(.state, "unknown")
        command = c.lenient(.command, nil)
        bench = c.lenient(.bench, nil)
        site = c.lenient(.site, nil)
        startedAt = c.lenient(.startedAt, nil)
        finishedAt = c.lenient(.finishedAt, nil)
        stepName = (try? c.decode(Named.self, forKey: .step))?.name
        progressLabel = (try? c.decode(Named.self, forKey: .progress))?.label
        exit = c.lenient(.exit, nil)
        log = c.lenient(.log, nil)
    }

    init(opID: String, state: String, command: String? = nil, bench: String? = nil, site: String? = nil, startedAt: Date? = nil) {
        self.opID = opID; self.state = state; self.command = command; self.bench = bench; self.site = site; self.startedAt = startedAt
    }
}

/// `benchbar op list --json`: `{"ops": [record, ...]}`, newest first. A record without an `op_id` is skipped.
nonisolated struct OpList: Decodable, Equatable, Sendable {
    var ops: [OpRecord]

    enum CodingKeys: String, CodingKey { case ops }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ops = try c.lossyList(OpRecord.self, forKey: .ops).items
    }

    init(ops: [OpRecord]) { self.ops = ops }

    /// The runs of this bench that are still going: the ones the CLI says run, for this bench folder. A record that names no
    /// bench (an install) is shown on every bench while it runs.
    func running(on bench: String) -> [OpRecord] {
        ops.filter { $0.isActive && ($0.bench == nil || OpList.samePath($0.bench, bench)) }
    }

    static func samePath(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        // a bench reached through a symlink (/tmp, a linked dev folder) is the same bench
        return URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }
}

nonisolated enum OpText {
    /// "site backup acme.localhost, running: Back up acme.localhost (dumping the database), started 2 minutes ago".
    static func line(_ op: OpRecord, now: Date) -> String {
        var text = op.command ?? "a command"
        if let site = op.site, !site.isEmpty, !text.contains(site) { text += " " + site }
        text += op.state == "starting" ? ", starting" : ", running"
        if let step = op.stepName, !step.isEmpty { text += ": " + step }
        if let progress = op.progressLabel, !progress.isEmpty { text += " (\(progress))" }
        if let start = op.startedAt { text += ", started " + SnapshotText.relativeAge(of: start, now: now) }
        return text
    }

    /// How a run that was seen running ended, from `op status`: "site backup acme.localhost finished", "... failed with exit 1".
    static func ended(_ op: OpRecord) -> String {
        var text = op.command ?? "a command"
        if let site = op.site, !site.isEmpty, !text.contains(site) { text += " " + site }
        switch op.state {
        case "done": return text + " finished."
        case "failed": return text + " failed" + (op.exit.map { " with exit \($0)." } ?? ".")
        case "interrupted": return text + " was interrupted: its process is gone."
        default: return text + " is \(op.state)."
        }
    }
}
