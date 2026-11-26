import Foundation

// The end of a bench's life (#183): scratch benches and `bench gc`, `bench forget`, `bench remove`, `uninstall-service`, `db orphans`
// and `site hosts --prune`. Every document is read tolerantly: a field this build does not know is ignored, one that is missing is absent.

/// One scratch bench of `bench gc --dry-run --json`: when it expires, how many sites it holds, who marked it and when.
nonisolated struct ScratchBench: Decodable, Equatable, Sendable, Identifiable {
    var bench: String
    var until: Date?
    var sites: Int
    var why: String
    var markedBy: String
    var markedAt: Date?

    var id: String { bench }
    var name: String { TidyCommands.folderName(bench) }

    enum CodingKeys: String, CodingKey {
        case bench, sites, why
        case until = "scratch_until_iso"
        case markedBy = "marked_by"
        case markedAt = "marked_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bench = try c.decode(String.self, forKey: .bench)
        until = TidyText.time(c.lenient(.until, ""))
        sites = c.lenient(.sites, 0)
        why = c.lenient(.why, "")
        markedBy = c.lenient(.markedBy, "unknown")
        markedAt = TidyText.time(c.lenient(.markedAt, ""))
    }

    init(bench: String, until: Date? = nil, sites: Int = 0, why: String = "", markedBy: String = "unknown", markedAt: Date? = nil) {
        self.bench = bench; self.until = until; self.sites = sites; self.why = why; self.markedBy = markedBy; self.markedAt = markedAt
    }
}

/// The plan of `bench gc`: the benches that expired (what an apply removes), the ones still waiting and the ones kept (the default bench).
nonisolated struct GcPlan: Decodable, Equatable, Sendable {
    var expired: [ScratchBench]
    var pending: [ScratchBench]
    var skipped: [ScratchBench]
    var canApply: Bool
    var token: String?

    enum CodingKeys: String, CodingKey {
        case expired, pending, skipped, token
        case canApply = "can_apply"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // a document without its list of expired benches is not an empty list
        expired = try c.lossyList(ScratchBench.self, forKey: .expired).items
        pending = (try? c.lossyList(ScratchBench.self, forKey: .pending).items) ?? []
        skipped = (try? c.lossyList(ScratchBench.self, forKey: .skipped).items) ?? []
        canApply = c.lenient(.canApply, true)
        let text: String? = c.lenient(.token, nil)
        token = text?.isEmpty == false ? text : nil
    }
}

/// One database of `db orphans --json` and the archived site folder that names it, if any.
nonisolated struct OrphanDatabase: Decodable, Equatable, Sendable, Identifiable {
    var name: String
    var archivedSite: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case archivedSite = "archived_site"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        let site: String = c.lenient(.archivedSite, "")
        archivedSite = site.isEmpty ? nil : site
    }
}

/// `db orphans --json`: read only. BenchBar never drops a database; the CLI's note says why and what to do.
nonisolated struct OrphanList: Decodable, Equatable, Sendable {
    var checked: Int
    var note: String
    var orphans: [OrphanDatabase]

    enum CodingKeys: String, CodingKey { case checked, note, orphans }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checked = c.lenient(.checked, 0)
        note = c.lenient(.note, "")
        orphans = try c.lossyList(OrphanDatabase.self, forKey: .orphans).items
    }
}

/// What the app can do at the end of a bench's life, each one by the CLI's own plan.
nonisolated enum TidyAction: String, Equatable, Sendable {
    case gc, forget, remove, removeService

    /// The CLI command that has to be listed for the entry to show.
    var command: String {
        switch self {
        case .gc: "bench gc"
        case .forget: "bench forget"
        case .remove: "bench remove"
        case .removeService: "uninstall-service"
        }
    }

    /// `uninstall-service` has no token: its dry run is text and the apply runs after a yes.
    var hasToken: Bool { self != .removeService }

    /// The CLI allows these to a person only (the click, and for Remove the typed name, are that decision).
    var needsPerson: Bool { self == .gc || self == .remove }

    var title: String {
        switch self {
        case .gc: String(localized: "Remove Expired Scratch Benches")
        case .forget: String(localized: "Forget Bench")
        case .remove: String(localized: "Remove Bench")
        case .removeService: String(localized: "Remove Service")
        }
    }

    var confirmLabel: String {
        switch self {
        case .gc: String(localized: "Remove Benches")
        case .forget: String(localized: "Forget Bench")
        case .remove: String(localized: "Remove Bench")
        case .removeService: String(localized: "Remove Service")
        }
    }
}

/// A plan the sheet shows before one of the actions runs: the rows it touches, what stays and the CLI's own errors.
nonisolated struct TidyPlan: ReviewablePlan {
    var action: TidyAction
    var bench: String
    /// What the plan will do, one line each: the sites with their databases, the benches that expired, the steps of the service.
    var rows: [String]
    var keeps: [String]
    var trashIn: String?
    var warnings: [String]
    var errors: [String]
    var canApply: Bool
    var token: String?

    /// Only a plan with something to do, no error, `can_apply` and (when the action has one) a token runs: with no token there is
    /// nothing to hold the CLI to, and the app never applies without one (no `--apply ""`).
    var canRun: Bool { canApply && errors.isEmpty && !rows.isEmpty && (!action.hasToken || token != nil) }

    /// The plan of `bench gc`: one row per expired bench.
    static func gc(_ plan: GcPlan) -> TidyPlan {
        TidyPlan(action: .gc, bench: "", rows: plan.expired.map { String(localized: "\($0.name): \(TidyText.sites($0.sites)), marked scratch by \($0.markedBy)") },
                 keeps: [], trashIn: nil, warnings: [], errors: [], canApply: plan.canApply && !plan.expired.isEmpty, token: plan.token)
    }

    /// The plan of `bench forget` or `bench remove`.
    static func decode(_ action: TidyAction, bench: String, from data: Data) throws(CLIError) -> TidyPlan {
        try BenchJSON.decode(Document.self, from: data).plan(action, bench: bench)
    }

    /// `uninstall-service --dry-run` prints text: its info and dry-run lines are the plan (without the `..` marker), a [FAIL] line is an error,
    /// and the [OK] line that ends a dry run is left out, because nothing was removed.
    static func service(bench: String, from text: String) -> TidyPlan {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("Aborting.") }
        let failures = lines.filter { $0.hasPrefix("[FAIL]") }.map { CLIText.plain($0) }
        let rows = lines.filter { !$0.hasPrefix("[FAIL]") && !$0.hasPrefix("[OK]") }
            .map { CLIText.plain($0.hasPrefix(".. ") ? String($0.dropFirst(3)) : $0) }
            // `--yes` answers the CLI's own question; that answer is not a step of the plan
            .filter { !$0.hasPrefix("auto-confirmed:") }
        return TidyPlan(action: .removeService, bench: bench, rows: rows, keeps: [], trashIn: nil, warnings: [], errors: failures,
                        canApply: failures.isEmpty, token: nil)
    }

    /// The document of `bench forget` and `bench remove`: the steps in order, what stays and where the folder goes.
    nonisolated struct Document: Decodable {
        struct Step: Decodable {
            var name: String
        }

        var steps: [Step]
        var keeps: [String]
        var trashIn: String
        var errors: [String]
        var warnings: [String]
        var canApply: Bool
        var token: String?

        enum CodingKeys: String, CodingKey {
            case steps, keeps, errors, warnings, token
            case trashIn = "trash_in"
            case canApply = "can_apply"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            steps = try c.lossyList(Step.self, forKey: .steps).items
            keeps = c.lenient(.keeps, [])
            trashIn = c.lenient(.trashIn, "")
            errors = c.lenient(.errors, [])
            warnings = c.lenient(.warnings, [])
            canApply = c.lenient(.canApply, true)
            let text: String? = c.lenient(.token, nil)
            token = text?.isEmpty == false ? text : nil
        }

        func plan(_ action: TidyAction, bench: String) -> TidyPlan {
            TidyPlan(action: action, bench: bench, rows: steps.map(\.name), keeps: keeps, trashIn: trashIn.isEmpty ? nil : trashIn,
                     warnings: warnings, errors: errors, canApply: canApply, token: token)
        }
    }
}

/// The exact arguments of the tidy commands. A bench is named by its path, which the CLI takes as the first word.
nonisolated enum TidyCommands {
    static let maxDays = 90

    static let gcRead = ["bench", "gc", "--dry-run", "--json"]
    static let orphansRead = ["db", "orphans", "--json"]
    static let hostsRead = ["site", "hosts", "--prune", "--dry-run", "--plain"]
    /// What a person types in Terminal to remove the stale hosts lines: the CLI asks for sudo there itself.
    static let hostsCommand = "benchbar site hosts --prune"

    static func folderName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    /// Whole days from 1 to 90, or nil. The CLI refuses anything else, so it is not sent.
    static func days(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard (1...3).contains(t.count), t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber), let n = Int(t), (1...maxDays).contains(n) else { return nil }
        return n
    }

    static let daysProblem = String(localized: "Whole days from 1 to \(maxDays).")

    /// Marking asks nothing more here: the click and the alert are the CLI's question, and `--yes` says so.
    static func scratch(bench: String, days: Int) -> [String] { ["bench", "scratch", bench, "--ttl", String(days), "--yes", "--json"] }
    static func clearScratch(bench: String) -> [String] { ["bench", "scratch", bench, "--clear", "--yes", "--json"] }

    /// The arguments of the plan and of the apply of one action. The apply carries the plan's own token; for Remove, the folder name again.
    static func plan(_ action: TidyAction, bench: String) -> [String] {
        switch action {
        case .gc: gcRead
        case .forget: ["bench", "forget", bench, "--dry-run", "--json"]
        case .remove: ["bench", "remove", bench, "--dry-run", "--json"]
        case .removeService: ["uninstall-service", "--bench-dir", bench, "--dry-run", "--yes", "--plain"]
        }
    }

    static func apply(_ action: TidyAction, bench: String, token: String?) -> [String] {
        switch action {
        case .gc: ["bench", "gc", "--apply", token ?? "", "--yes", "--jsonl"]
        case .forget: ["bench", "forget", bench, "--apply", token ?? "", "--yes", "--jsonl"]
        case .remove: ["bench", "remove", bench, "--confirm-bench", folderName(bench), "--apply", token ?? "", "--yes", "--jsonl"]
        case .removeService: ["uninstall-service", "--bench-dir", bench, "--yes", "--plain"]
        }
    }
}

/// `site hosts --prune --dry-run` prints text: the names of the lines in benchbar's block that no bench has a site for.
nonisolated enum HostsPrune {
    static func names(in text: String) -> [String] {
        let marker = "name no site of any bench:"
        for raw in text.split(separator: "\n") {
            guard let range = raw.range(of: marker) else { continue }
            return raw[range.upperBound...].split(separator: " ").map(String.init)
        }
        return []
    }
}

/// The words of the tidy surfaces, kept out of the views so a test can read them.
nonisolated enum TidyText {
    static func sites(_ n: Int) -> String { Wording.sites(n) }

    static func time(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        return plain.date(from: text)
    }

    static func orphan(_ d: OrphanDatabase) -> String {
        d.archivedSite.map { String(localized: "\(d.name), named by the archived site \(TidyCommands.folderName($0))") } ?? d.name
    }

    static func orphanSummary(_ list: OrphanList) -> String {
        let n = list.orphans.count
        return n == 0 ? String(localized: "No orphan database among \(list.checked) of frappe's shape.")
            : Wording.orphanDatabases(n, checked: list.checked)
    }

    /// "expired 5 days ago", or "expires 2026-11-30" for a bench that waits.
    static func expiry(_ b: ScratchBench, now: Date) -> String {
        guard let until = b.until else { return String(localized: "no time known") }
        return until > now ? String(localized: "expires \(until.formatted(.iso8601.year().month().day()))")
            : String(localized: "expired \(SnapshotText.relativeAge(of: until, now: now))")
    }

    /// One line of the scratch list: the expired ones say who marked them, a kept one says why.
    static func line(_ b: ScratchBench, expired: Bool, kept: Bool, now: Date) -> String {
        if kept { return b.why.isEmpty ? String(localized: "\(b.name): kept, not removed") : String(localized: "\(b.name): kept, \(b.why)") }
        return expired ? String(localized: "\(b.name): \(sites(b.sites)), \(expiry(b, now: now)), marked by \(b.markedBy)") : String(localized: "\(b.name): \(expiry(b, now: now))")
    }
}
