import Foundation

/// The `plan` line of `benchbar pull ... --dry-run --json` (a stream of JSON
/// lines, see docs/json-schema.md): which backup is copied into which new
/// site, the apps that differ, and what the copy loses. Its `token` is a hash
/// of the plan: `pull --apply TOKEN --yes` makes the plan again after its
/// checks and stops, with nothing changed, when it is not the one shown.
nonisolated struct PullPlan: ReviewablePlan, Codable {
    nonisolated struct Backup: Codable, Sendable, Equatable {
        var name: String?
        /// `--new-backup`: the backup does not exist yet.
        var new: Bool
        var bytes: Int64?
        var ageHours: Int?
        var encrypted: Bool

        enum CodingKeys: String, CodingKey {
            case name, new, bytes, encrypted
            case ageHours = "age_hours"
        }
    }

    nonisolated struct AppStatus: Codable, Sendable, Equatable, Identifiable {
        var app: String
        var productionVersion: String?
        var localVersion: String?
        /// ok, missing, skipped, branch differs, local older or local newer
        var status: String
        var id: String { app }

        enum CodingKeys: String, CodingKey {
            case app, status
            case productionVersion = "production_version"
            case localVersion = "local_version"
        }
    }

    var source: String
    var host: String?
    var remoteSite: String?
    var fromDir: String?
    var bench: String
    var site: String
    var replace: Bool
    var backup: Backup?
    var encryptionKey: Bool
    /// The copy has its integrations switched off and its stored secrets cleared (`--keep-secrets` makes it false).
    var neutralise: Bool
    var apps: [AppStatus]
    var migrate: Bool
    var createSite: Bool
    var steps: [String]
    /// What `--apply` takes. Nil for a CLI older than the token (0.8): the run then has no
    /// reviewed plan to hold the CLI to, and `differences(from:)` is the app's fallback.
    var token: String?

    enum CodingKeys: String, CodingKey {
        case source, host, bench, site, replace, backup, neutralise, apps, migrate, steps, token
        case remoteSite = "remote_site"
        case fromDir = "from_dir"
        case encryptionKey = "encryption_key"
        case createSite = "create_site"
    }

    var canRun: Bool { true }

    /// Only for a CLI without a plan token: what the run does that the plan the person reviewed did
    /// not say, told after the fact. With a token the CLI refuses a changed plan before it starts.
    func differences(from reviewed: PullPlan) -> [String] {
        var out = steps.filter { !reviewed.steps.contains($0) }.map { "a step the plan did not show: \($0)" }
        if let name = backup?.name, name != reviewed.backup?.name { out.append("another backup than the one reviewed: \(name)") }
        return out
    }

    /// Apps whose version or branch differs from production's: worth a look before the migrate.
    var differingApps: [AppStatus] { apps.filter { $0.status != "ok" && $0.status != "skipped" } }
}

nonisolated extension PullPlan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try c.decode(String.self, forKey: .source), host: c.lenient(.host, nil),
                  remoteSite: c.lenient(.remoteSite, nil), fromDir: c.lenient(.fromDir, nil), bench: c.lenient(.bench, ""),
                  site: try c.decode(String.self, forKey: .site), replace: c.lenient(.replace, false),
                  backup: c.lenient(.backup, nil), encryptionKey: c.lenient(.encryptionKey, false),
                  // an older CLI neutralised nothing: its absence is "not neutralised", never "neutralised"
                  neutralise: c.lenient(.neutralise, false), apps: c.lenient(.apps, []), migrate: c.lenient(.migrate, true),
                  createSite: c.lenient(.createSite, true), steps: c.lenient(.steps, []),
                  token: c.lenient(.token, nil))
    }
}

/// A pull that ran: how it ended, and the plan line it started with.
nonisolated struct PullRun: Sendable, Equatable {
    var done: PullDone
    var plan: PullPlan?
}

/// The `done` line of a pull: how it ended, with the words for what the
/// neutralisation changed.
nonisolated struct PullDone: Codable, Sendable, Equatable {
    nonisolated struct Neutralised: Codable, Sendable, Equatable {
        var on: Bool
        var counts: [String: Int]?
        var labels: [String: String]?

        /// "7 stored secrets cleared, 2 webhooks switched off": only the parts that changed something.
        var summary: String {
            guard on, let counts else { return "" }
            return counts.filter { $0.value > 0 }.keys.sorted().map { "\(counts[$0] ?? 0) \(labels?[$0] ?? $0)" }.joined(separator: ", ")
        }
    }

    var exit: Int
    var site: String?
    var url: String?
    var warnings: [String]
    var neutralised: Neutralised?
}

/// The JSON lines of `pull --json`, as the app reads them.
nonisolated enum PullStream {
    /// The plan line, nil when the run stopped before it (a refused check).
    static func plan(in stdout: String) -> PullPlan? {
        line(event: "plan", in: stdout).flatMap { try? BenchJSON.decoder().decode(PullPlan.self, from: $0) }
    }

    static func done(in stdout: String) -> PullDone? {
        line(event: "done", in: stdout).flatMap { try? BenchJSON.decoder().decode(PullDone.self, from: $0) }
    }

    private static func line(event: String, in stdout: String) -> Data? {
        for raw in stdout.split(separator: "\n") where raw.contains("\"event\":\"\(event)\"") { return Data(raw.utf8) }
        return nil
    }

    /// Why a run that exited non zero stopped: the CLI's own `[FAIL]` lines
    /// (stderr), else its `next_actions` reasons from the done line.
    static func failure(_ output: CommandOutput) -> String {
        let text = CLIClient.summarize(CommandOutput(exitCode: output.exitCode, stdout: "", stderr: output.stderr))
        return text.isEmpty ? "benchbar pull stopped with exit code \(output.exitCode)." : text
    }
}

/// What the Pull sheet asks for.
nonisolated struct PullRequest: Equatable, Sendable {
    nonisolated enum Source: Equatable, Sendable {
        /// HOST:SITE, HOST from `~/.ssh/config`
        case ssh(String)
        /// a backup set downloaded by hand
        case folder(String)
    }

    var source: Source
    /// The new local site's name.
    var name: String
    /// `--keep-secrets`: the copy keeps production's integrations and passwords. Off unless chosen.
    var keepSecrets = false

    /// HOST:SITE with nothing else in it: the CLI splits on the first colon.
    static func isValidSSH(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return text.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "._-:".contains($0) }
    }

    /// The default local name: the production site's name, with `.local` (the CLI's own default).
    static func defaultName(for source: String) -> String {
        let site = source.split(separator: ":").dropFirst().first.map(String.init) ?? ""
        return site.isEmpty ? "" : site.lowercased() + ".local"
    }

    var arguments: [String] {
        var args: [String]
        switch source {
        case .ssh(let target): args = ["pull", target, "--as", name]
        case .folder(let path): args = ["pull", "--from-dir", path, "--as", name]
        }
        if keepSecrets { args.append("--keep-secrets") }
        return args
    }
}
