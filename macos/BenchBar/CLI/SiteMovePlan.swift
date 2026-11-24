import Foundation

/// `benchbar site move NAME --to-bench PATH --dry-run --json`: the reviewed plan of a move (CLI 0.9.0) and the token
/// `--apply TOKEN --yes` needs. Read only: nothing is backed up, restored or dropped by reading it. Every field is read
/// on its own, so a newer CLI's extra field or a missing list never costs the rest.
nonisolated struct SiteMovePlan: ReviewablePlan, Decodable {
    nonisolated struct Step: Decodable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var touches: [String]

        enum CodingKeys: String, CodingKey { case id, name, touches }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = c.lenient(.name, id)
            touches = c.lenient(.touches, [])
        }
    }

    /// What the address does: the name stays (its hosts line is kept), the port is the other bench's.
    nonisolated struct Address: Decodable, Sendable, Equatable {
        var line: String
        var urlBefore: String
        var urlAfter: String
        var portChanges: Bool

        enum CodingKeys: String, CodingKey {
            case line
            case urlBefore = "url_before"
            case urlAfter = "url_after"
            case portChanges = "port_changes"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            line = c.lenient(.line, "")
            urlBefore = c.lenient(.urlBefore, "")
            urlAfter = c.lenient(.urlAfter, "")
            portChanges = c.lenient(.portChanges, false)
        }
    }

    /// A command the CLI suggests, with why (the plan's `next_actions`).
    nonisolated struct Suggestion: Decodable, Sendable, Equatable {
        var command: String
        var why: String

        enum CodingKeys: String, CodingKey { case command, why }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(String.self, forKey: .command)
            why = c.lenient(.why, "")
        }
    }

    var bench: String
    var site: String
    var toBench: String
    var apps: [String]
    var missingApps: [String]
    var migrate: Bool
    var steps: [Step]
    /// What stays: the backups of the site.
    var stays: [String]
    var address: Address?
    var warnings: [String]
    /// Inputs a terminal would ask for (MARIADB_ROOT_PASSWORD): an app run cannot answer them.
    var needs: [String]
    var errors: [String]
    var nextActions: [Suggestion]
    var canApply: Bool
    var token: String

    enum CodingKeys: String, CodingKey {
        case bench, site, apps, migrate, steps, stays, warnings, needs, errors, token
        case toBench = "to_bench"
        case missingApps = "missing_apps"
        case address = "hosts"
        case nextActions = "next_actions"
        case canApply = "can_apply"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bench = c.lenient(.bench, "")
        site = try c.decode(String.self, forKey: .site)
        toBench = c.lenient(.toBench, "")
        apps = c.lenient(.apps, [])
        missingApps = c.lenient(.missingApps, [])
        migrate = c.lenient(.migrate, true)
        steps = (try? c.lossyList(Step.self, forKey: .steps).items) ?? []
        stays = c.lenient(.stays, [])
        address = c.lenient(.address, nil)
        warnings = c.lenient(.warnings, [])
        needs = c.lenient(.needs, [])
        errors = c.lenient(.errors, [])
        nextActions = (try? c.lossyList(Suggestion.self, forKey: .nextActions).items) ?? []
        canApply = c.lenient(.canApply, false)
        token = try c.decode(String.self, forKey: .token)
    }

    /// Only a plan the CLI says can be applied, with no error, nothing it still has to ask for, a token and a step, runs.
    var canRun: Bool { canApply && errors.isEmpty && needs.isEmpty && !token.isEmpty && !steps.isEmpty }

    /// The bench has to be stopped first: the CLI's own `benchbar down` suggestion, answered by the sheet's Stop Bench button.
    var needsStop: Bool { nextActions.contains { SiteMoveText.isStop($0.command) } }

    /// The errors without the "Stop the bench first" line, which the sheet answers with its own button.
    var otherErrors: [String] { errors.filter { !$0.hasPrefix(SiteMoveText.stopPrefix) } }
}

/// What the sheet asks for: the site, the bench it goes to and the one option. The same arguments make the plan and the apply,
/// because `--no-migrate` is part of the plan the token stands for.
nonisolated struct SiteMoveRequest: Equatable, Sendable {
    var site: String
    var target: String
    var noMigrate: Bool

    /// The arguments after `site move`, shared by the plan and the apply.
    var arguments: [String] {
        var args = [site, "--to-bench", target]
        if noMigrate { args.append("--no-migrate") }
        return args
    }

    func planArguments(bench: String) -> [String] {
        ["site", "move"] + arguments + ["--dry-run", "--json", "--bench-dir", bench]
    }

    /// The run of the plan the person saw: its own token, `--yes`, the JSON lines.
    func applyArguments(token: String, bench: String) -> [String] {
        ["site", "move"] + arguments + ["--apply", token, "--yes", "--jsonl", "--bench-dir", bench]
    }
}

/// How a move ended, from the stream: the steps as they ended and the done line's envelope.
nonisolated struct SiteMoveOutcome: Equatable, Sendable {
    var envelope: ResultEnvelope
    var steps: [InstallStep]
}

/// The words of the move sheet and the gating of its entry, kept out of the views so a test can read them.
nonisolated enum SiteMoveText {
    static let stopPrefix = "Stop the bench first"

    /// The plan's suggestion is `benchbar down --bench-dir SRC`.
    static func isStop(_ command: String) -> Bool {
        let words = command.split(separator: " ").map(String.init)
        return words.contains("down") && words.contains { $0 == "benchbar" || $0.hasSuffix("/benchbar") }
    }

    /// The benches a site can go to: every registered bench but this one.
    static func targets(from benches: [BenchModel], excluding bench: BenchModel) -> [BenchModel] {
        benches.filter { $0.path != bench.path }
    }

    /// The entry shows when the CLI lists `site move` and another bench is registered.
    static func offered(catalog: CommandCatalog?, others: Int) -> Bool { catalog?.has("site move") == true && others > 0 }

    /// The default site never moves (the CLI refuses it); its entry stays disabled.
    static func canMove(_ row: SiteRow) -> Bool { !row.isDefault }

    static func facts(_ plan: SiteMovePlan) -> [(label: String, text: String)] {
        var out: [(label: String, text: String)] = []
        out.append(("From", plan.bench))
        out.append(("To", plan.toBench))
        if !plan.apps.isEmpty { out.append(("Apps", plan.apps.joined(separator: ", "))) }
        if let address = plan.address {
            out.append(("Address", address.portChanges
                        ? "\(address.urlBefore) becomes \(address.urlAfter). The name stays, so its hosts line is kept."
                        : "\(address.urlAfter), as before."))
        }
        out.append(("Migrate", plan.migrate ? "bench migrate runs after the restore." : "Not run: the site arrives on the schema it had."))
        if !plan.stays.isEmpty { out.append(("Stays", plan.stays.joined(separator: "\n"))) }
        out.append(("Left alone", "The default site of both benches and every other site."))
        return out
    }

    /// Stop Bench is clickable when the store allows a change and its own stop is not already running.
    static func canStop(canChange: Bool, stopping: Bool) -> Bool { canChange && !stopping }

    /// The progress line while Stop Bench runs.
    static func stopping(_ bench: String) -> String { "Stopping \(bench)…" }

    /// What a stream's step line says while it runs.
    static func progress(_ step: InstallStep) -> String {
        step.status == .running ? step.name : "\(step.name): \(step.status.rawValue)"
    }

    /// The end of a run in words: the title, then the CLI's warnings and next actions, the new address among them.
    static func result(site: String, target: String, outcome: SiteMoveOutcome) -> SheetResult {
        let name = URL(fileURLWithPath: target).lastPathComponent
        let notes = outcome.envelope.nextActions.map { $0.why.isEmpty ? $0.command : "\($0.why)\n\($0.command)" }
        let detail = (outcome.envelope.warnings + notes).joined(separator: "\n\n")
        let more = detail.isEmpty ? nil : detail
        return outcome.envelope.warnings.isEmpty ? .success("\(site) moved to \(name)", more) : .warning("\(site) moved to \(name)", more)
    }
}
