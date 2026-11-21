import Foundation

// What ran on this Mac, who holds a bench, and the log lines of a start: the CLI's history,
// lease and logs documents (0.9). Each is read tolerantly: a field this build does not know is
// ignored and one that is missing is absent, so an older or newer CLI never fails the window.

/// One line of `benchbar history --json`: a run that changed things.
nonisolated struct HistoryEntry: Decodable, Sendable, Equatable, Identifiable {
    nonisolated struct Change: Decodable, Sendable, Equatable {
        var kind: String
        var name: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = c.lenient(.kind, "")
            name = c.lenient(.name, "")
        }

        enum CodingKeys: String, CodingKey { case kind, name }
    }

    var opID: String
    /// The command's key (`site add`); nil for a record that has none.
    var command: String?
    /// The command line without `benchbar`, its secrets already `***`.
    var argv: [String]
    /// terminal, app, tray, mcp, agent or script; a new value later is shown as it is.
    var caller: String
    var mcpTool: String?
    var mcpClient: String?
    var bench: String?
    var site: String?
    var startedAt: Date?
    var endedAt: Date?
    var exit: Int
    var changed: [Change]
    var changedMore: Int
    var log: String?

    var id: String { opID }

    enum CodingKeys: String, CodingKey {
        case command, argv, caller, mcp, bench, site, exit, changed, log
        case opID = "op_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case changedMore = "changed_more"
    }

    enum McpKeys: String, CodingKey { case tool, client }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opID = try c.decode(String.self, forKey: .opID)
        command = c.lenient(.command, nil)
        argv = c.lenient(.argv, [])
        caller = c.lenient(.caller, "unknown")
        let mcp = try? c.nestedContainer(keyedBy: McpKeys.self, forKey: .mcp)
        mcpTool = mcp?.lenient(.tool, nil)
        mcpClient = mcp?.lenient(.client, nil)
        bench = c.lenient(.bench, nil)
        site = c.lenient(.site, nil)
        startedAt = c.lenient(.startedAt, nil)
        endedAt = c.lenient(.endedAt, nil)
        exit = c.lenient(.exit, 0)
        changed = (try? c.lossyList(Change.self, forKey: .changed).items) ?? []
        changedMore = c.lenient(.changedMore, 0)
        log = c.lenient(.log, nil)
    }

    init(opID: String, command: String?, caller: String, exit: Int, startedAt: Date? = nil) {
        self.opID = opID; self.command = command; self.argv = []; self.caller = caller; self.exit = exit
        self.startedAt = startedAt; changed = []; changedMore = 0
    }
}

/// `benchbar history --json`, newest first.
nonisolated struct HistoryList: Decodable, Sendable, Equatable {
    var history: [HistoryEntry]

    enum CodingKeys: String, CodingKey { case history }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        history = try c.lossyList(HistoryEntry.self, forKey: .history).items
    }
}

/// The words the History pane uses.
nonisolated enum HistoryText {
    /// "site backup acme.localhost": the command and what it was aimed at.
    static func title(_ entry: HistoryEntry) -> String {
        let command = entry.command ?? entry.argv.first ?? "a command"
        guard let site = entry.site, !site.isEmpty, !command.contains(site) else { return command }
        return "\(command) \(site)"
    }

    /// Who started it, as a person says it.
    static func who(_ entry: HistoryEntry) -> String {
        switch entry.caller {
        case "app": return "BenchBar app"
        case "terminal": return "Terminal"
        case "tray": return "Windows tray"
        case "script": return "A script"
        case "agent": return "An agent"
        case "mcp":
            let client = entry.mcpClient.map { " (\($0))" } ?? ""
            return "An agent through MCP\(client)"
        default: return entry.caller
        }
    }

    static func result(_ entry: HistoryEntry) -> String { entry.exit == 0 ? "Done" : "Failed (exit \(entry.exit))" }

    /// "site acme.localhost, snapshot acme.localhost": what the run changed, as the CLI recorded it.
    static func changes(_ entry: HistoryEntry) -> String? {
        guard !entry.changed.isEmpty else { return nil }
        var parts = entry.changed.map { "\($0.kind) \($0.name)" }
        if entry.changedMore > 0 { parts.append("\(entry.changedMore) more") }
        return parts.joined(separator: ", ")
    }
}

/// One lease: a bench or a site held for a while by a named caller.
nonisolated struct LeaseInfo: Decodable, Sendable, Equatable, Identifiable {
    /// Only for a lease the caller holds; the app never holds one, so it never has an id.
    var id: String?
    /// bench or site
    var scope: String
    var bench: String
    var site: String?
    var holder: String
    var note: String?
    var since: Date?
    var expiresAt: Date?
    var yours: Bool

    enum CodingKeys: String, CodingKey {
        case id, scope, bench, site, holder, note, since, yours
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(.id, nil)
        scope = c.lenient(.scope, "bench")
        bench = c.lenient(.bench, "")
        site = c.lenient(.site, nil)
        holder = c.lenient(.holder, "someone")
        note = c.lenient(.note, nil)
        since = c.lenient(.since, nil)
        expiresAt = c.lenient(.expiresAt, nil)
        yours = c.lenient(.yours, false)
    }

    init(scope: String, bench: String, site: String? = nil, holder: String, note: String? = nil, expiresAt: Date? = nil) {
        self.id = nil; self.scope = scope; self.bench = bench; self.site = site; self.holder = holder
        self.note = note; since = nil; self.expiresAt = expiresAt; yours = false
    }

    /// Still holding at `now`: the CLI lists active leases only, and a list read a while ago may be past its end.
    func isActive(at now: Date) -> Bool { expiresAt.map { $0 > now } ?? true }
}

/// `benchbar lease list --json`.
nonisolated struct LeaseList: Decodable, Sendable, Equatable {
    var leases: [LeaseInfo]

    enum CodingKeys: String, CodingKey { case leases }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leases = try c.lossyList(LeaseInfo.self, forKey: .leases).items
    }
}

/// The words for a lease, and the reading of the sentence a command that a lease stops ends with.
nonisolated enum LeaseText {
    static func place(_ lease: LeaseInfo) -> String {
        lease.scope == "site" ? "Site \(lease.site ?? "?")" : "The whole bench"
    }

    /// "Site acme.localhost is held by claude-qa until 3:20 PM: running the QA suite".
    static func line(_ lease: LeaseInfo, now: Date = .now) -> String {
        var text = "\(place(lease)) is held by \(lease.holder)"
        if let end = lease.expiresAt { text += " until \(end.formatted(date: Calendar.current.isDate(end, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened))" }
        if let note = lease.note, !note.isEmpty { text += ": \(note)" }
        return text
    }
}

/// "The site acme.localhost of /path is leased by claude-qa until 2026-11-19T15:20:00Z (running the QA suite)."
/// is what a command a lease stands in front of ends with (error id `lease_held`, exit 1, nothing changed).
nonisolated struct LeaseRefusal: Equatable, Sendable {
    var holder: String
    var until: Date?
    var untilText: String
    var note: String?

    /// nil when the message is not a lease refusal. Several leases in one message: the first is named.
    static func parse(_ message: String) -> LeaseRefusal? {
        guard let marker = message.range(of: " is leased by ") else { return nil }
        let rest = message[marker.upperBound...]
        guard let untilMarker = rest.range(of: " until ") else { return nil }
        let holder = String(rest[..<untilMarker.lowerBound])
        guard !holder.isEmpty, !holder.contains(" ") else { return nil }
        let after = rest[untilMarker.upperBound...]
        let untilText = String(after.prefix { !$0.isWhitespace })
        var note: String?
        let tail = after.dropFirst(untilText.count)
        if tail.hasPrefix(" ("), let close = tail.range(of: ").") {
            note = String(tail[tail.index(tail.startIndex, offsetBy: 2)..<close.lowerBound])
        }
        let trimmed = untilText.hasSuffix(".") ? String(untilText.dropLast()) : untilText
        return LeaseRefusal(holder: holder, until: ISO8601DateFormatter().date(from: trimmed), untilText: trimmed, note: note)
    }

    var sentence: String {
        var text = "Held by \(holder)"
        if let until {
            text += " until \(until.formatted(date: .abbreviated, time: .shortened))"
        } else if !untilText.isEmpty {
            text += " until \(untilText)"
        }
        if let note, !note.isEmpty { text += " (\(note))" }
        return text + "."
    }
}

/// `benchbar logs --json`: the lines of one read and the time of each (CLI 0.8). `ts` has one entry
/// per line, null where the line carries no time (a traceback line).
nonisolated struct LogChunk: Decodable, Sendable, Equatable {
    var file: String?
    var lines: [String]
    var times: [Date?]
    /// The cut off the CLI used, when `--since` or `--since-restart` was given.
    var since: Date?

    enum CodingKeys: String, CodingKey {
        case file, lines, since
        case times = "ts"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = c.lenient(.file, nil)
        lines = try c.decode([String].self, forKey: .lines)
        // an older CLI sends no ts: every line is untimed, and a poll then reads the whole tail again
        let raw: [String?] = c.lenient(.times, [])
        times = (0..<lines.count).map { i in i < raw.count ? raw[i].flatMap(Self.date) : nil }
        since = c.lenient(.since, nil)
    }

    /// An ISO 8601 time, with or without fractional seconds: a fractional one must not read as untimed, or every poll reads it again.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    init(lines: [String], times: [Date?] = [], file: String? = nil, since: Date? = nil) {
        self.lines = lines; self.file = file; self.since = since
        self.times = (0..<lines.count).map { $0 < times.count ? times[$0] : nil }
    }
}
