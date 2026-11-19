import Foundation

// Codable models for the benchbar JSON API, schema version 1.
// docs/json-schema.md is the source of truth; field names map with
// explicit CodingKeys so a rename on either side is a compile error here.
//
// Rules from the schema: ignore unknown fields (Codable does), and treat
// an unknown enum value as .unknown instead of failing the whole decode.

// Tolerant reading (MAC-9): a field a view can live without is optional or
// has a default, and only the identity of a thing (a path, a name, a state)
// is required. The init(from:) of each model sits in an extension so the
// memberwise init stays. Field names stay exactly as the CLI prints them.
nonisolated extension KeyedDecodingContainer {
    /// A field the view can live without: missing, null or the wrong type gives `fallback`.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// A list read element by element: an element that does not decode is
    /// skipped and named in `skipped`, so one bad entry never hides the rest.
    /// A list that is missing, null or not an array throws (keyNotFound, valueNotFound
    /// or typeMismatch): a document without its list is not an empty list.
    func lossyList<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> (items: [T], skipped: [String]) {
        var list = try nestedUnkeyedContainer(forKey: key)
        var items: [T] = []
        var skipped: [String] = []
        while !list.isAtEnd {
            let index = list.currentIndex
            do {
                items.append(try list.decode(T.self))
            } catch {
                skipped.append("entry \(index): \(BenchJSON.describe(error))")
                _ = try? list.decode(Skipped.self)
            }
        }
        return (items, skipped)
    }
}

/// Decodes any JSON value and keeps nothing: moves a list past an entry that failed.
nonisolated private struct Skipped: Decodable {}

nonisolated enum BenchState: String, Codable, Sendable, CaseIterable {
    case stopped, starting, running, crashed, paused, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BenchState(rawValue: raw) ?? .unknown
    }
}

nonisolated enum StopReason: String, Codable, Sendable {
    case manual, crash, broken, unknown
    /// Added in 0.7.3: another program held one of the bench's ports when the runner started.
    case portConflict = "port_conflict"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StopReason(rawValue: raw) ?? .unknown
    }
}

nonisolated struct BenchPorts: Codable, Sendable, Equatable, Hashable {
    var web: Int
    var socketio: Int
    var redisQueue: Int
    var redisCache: Int
    /// Added in 0.4. bench keeps it equal to redis_cache; nil from an older CLI.
    var redisSocketio: Int? = nil

    enum CodingKeys: String, CodingKey {
        case web, socketio
        case redisQueue = "redis_queue"
        case redisCache = "redis_cache"
        case redisSocketio = "redis_socketio"
    }
}

nonisolated extension BenchPorts {
    /// A port the CLI left out reads 0: no bench listens there, so nothing is mistaken for a port.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(web: c.lenient(.web, 0), socketio: c.lenient(.socketio, 0),
                  redisQueue: c.lenient(.redisQueue, 0), redisCache: c.lenient(.redisCache, 0),
                  redisSocketio: c.lenient(.redisSocketio, nil))
    }
}

/// One site of a bench (`sites[]` in list and status, added in 0.4).
nonisolated struct SiteInfo: Codable, Sendable, Equatable, Hashable, Identifiable {
    var name: String
    var isDefault: Bool
    var hostsEntry: Bool
    var pingCode: Int?
    /// Added with Open as; nil from an older CLI, which hides the menu.
    var developerMode: Bool? = nil
    /// The person's per site opt-in (`site open-as on`); nil from a CLI older than the field.
    var openAsEnabled: Bool? = nil
    /// Whether `open --as` will sign in here (developer mode, and the site
    /// bench serve answers as); nil from a CLI older than the field.
    var openAs: Bool? = nil

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case isDefault = "default"
        case hostsEntry = "hosts_entry"
        case pingCode = "ping_code"
        case developerMode = "developer_mode"
        case openAsEnabled = "open_as_enabled"
        case openAs = "open_as"
    }
}

nonisolated extension SiteInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  isDefault: c.lenient(.isDefault, false), hostsEntry: c.lenient(.hostsEntry, false),
                  pingCode: c.lenient(.pingCode, nil), developerMode: c.lenient(.developerMode, nil),
                  openAsEnabled: c.lenient(.openAsEnabled, nil), openAs: c.lenient(.openAs, nil))
    }
}

/// One entry of `benchbar list --json`.
nonisolated struct BenchSummary: Codable, Sendable, Equatable, Hashable, Identifiable {
    var path: String
    var name: String
    var site: String
    var label: String
    var webURL: String
    var ports: BenchPorts
    var isDefault: Bool
    var serviceInstalled: Bool
    var stateFile: String
    /// Added in 0.4; nil from an older CLI.
    var sites: [SiteInfo]? = nil
    /// The lockfile `lock check` compares with (0.5), nil without one.
    var lockFile: String? = nil

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, name, site, label, ports, sites
        case lockFile = "lock_file"
        case webURL = "web_url"
        case isDefault = "default"
        case serviceInstalled = "service_installed"
        case stateFile = "state_file"
    }
}

nonisolated extension BenchSummary {
    /// Only `path` is the identity. The rest has a default a row can show: the
    /// folder name, no site, the state file where the runner writes it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decode(String.self, forKey: .path)
        let name = c.lenient(.name, (path as NSString).lastPathComponent)
        self.init(path: path, name: name, site: c.lenient(.site, ""), label: c.lenient(.label, ""),
                  webURL: c.lenient(.webURL, ""),
                  ports: c.lenient(.ports, BenchPorts(web: 0, socketio: 0, redisQueue: 0, redisCache: 0)),
                  isDefault: c.lenient(.isDefault, false), serviceInstalled: c.lenient(.serviceInstalled, false),
                  stateFile: c.lenient(.stateFile, path + "/logs/.benchbar/state.json"),
                  sites: c.lenient(.sites, nil), lockFile: c.lenient(.lockFile, nil))
    }
}

/// `benchbar scan PATH --json`: discoveries and any skipped-folder warnings.
nonisolated struct BenchScan: Codable, Sendable {
    var root: String
    var benches: [BenchSummary]
    var warnings: [String]
}

/// `benchbar list --json`.
nonisolated struct BenchList: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var cliVersion: String
    var defaultBench: String?
    var benches: [BenchSummary]
    /// Entries of `benches` that did not decode, one line each (not part of the JSON).
    var skipped: [String] = []

    enum CodingKeys: String, CodingKey {
        case benches
        case schemaVersion = "schema_version"
        case cliVersion = "cli_version"
        case defaultBench = "default_bench"
    }

    /// One entry without a path is skipped and named, it does not fail the list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = try c.lossyList(BenchSummary.self, forKey: .benches)
        self.init(schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
                  cliVersion: c.lenient(.cliVersion, ""), defaultBench: c.lenient(.defaultBench, nil),
                  benches: list.items, skipped: list.skipped)
    }

    init(schemaVersion: Int, cliVersion: String, defaultBench: String?, benches: [BenchSummary], skipped: [String] = []) {
        self.schemaVersion = schemaVersion
        self.cliVersion = cliVersion
        self.defaultBench = defaultBench
        self.benches = benches
        self.skipped = skipped
    }
}

/// `benchbar status --json`, and also `logs/.benchbar/state.json`, which
/// carries the same core fields (the status only fields are optional).
nonisolated struct BenchStatus: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var cliVersion: String?
    var bench: String
    var name: String?
    var site: String?
    var label: String?
    var state: BenchState
    var stopReason: StopReason?
    var pid: Int32?
    var startedAt: Date?
    var lastExitCode: Int?
    var webURL: String?
    var webPingCode: Int?
    // status --json only
    var ports: BenchPorts?
    var stateFile: String?
    var log: String?
    var agentLoaded: Bool?
    var agentState: String?
    var processesRunning: Bool?
    /// Added in 0.4.
    var sites: [SiteInfo]?
    var scheduler: Bool?
    // state.json only
    var updatedAt: Date?
    var source: String?

    enum CodingKeys: String, CodingKey {
        case bench, name, site, label, state, pid, ports, log, source, sites, scheduler
        case schemaVersion = "schema_version"
        case cliVersion = "cli_version"
        case stopReason = "stop_reason"
        case startedAt = "started_at"
        case lastExitCode = "last_exit_code"
        case webURL = "web_url"
        case webPingCode = "web_ping_code"
        case stateFile = "state_file"
        case agentLoaded = "agent_loaded"
        case agentState = "agent_state"
        case processesRunning = "processes_running"
        case updatedAt = "updated_at"
    }
}

nonisolated enum CheckLevel: String, Codable, Sendable {
    case ok, warn, fail, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CheckLevel(rawValue: raw) ?? .unknown
    }
}

nonisolated struct DoctorCheck: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var group: String?
    var label: String
    var level: CheckLevel
    var message: String
    var fixCommand: String?
    var action: String?

    enum CodingKeys: String, CodingKey {
        case id, group, label, level, message, action
        case fixCommand = "fix_command"
    }
}

nonisolated extension DoctorCheck {
    /// `id` is the identity; a check with no level reads as unknown, not as a pass.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        self.init(id: id, group: c.lenient(.group, nil), label: c.lenient(.label, id),
                  level: c.lenient(.level, .unknown), message: c.lenient(.message, ""),
                  fixCommand: c.lenient(.fixCommand, nil), action: c.lenient(.action, nil))
    }
}

nonisolated struct DoctorSummary: Codable, Sendable, Equatable {
    var ok: Int
    var warn: Int
    var fail: Int

    enum CodingKeys: String, CodingKey { case ok, warn, fail }

    /// "1 failure · 2 warnings", nil when nothing needs attention: the
    /// popover and the Health tab say it the same way.
    var attention: String? {
        let parts = [Self.count(fail, "failure"), Self.count(warn, "warning")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "45 passing · 1 failure · 2 warnings", for the Health tab's header.
    var text: String { (["\(ok) passing"] + [attention].compactMap { $0 }).joined(separator: " · ") }

    private static func count(_ n: Int, _ word: String) -> String? {
        n > 0 ? "\(n) \(word)\(n == 1 ? "" : "s")" : nil
    }
}

nonisolated extension DoctorSummary {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ok: c.lenient(.ok, 0), warn: c.lenient(.warn, 0), fail: c.lenient(.fail, 0))
    }

    /// The counts of a list of checks, for a report that came without them.
    init(counting checks: [DoctorCheck]) {
        self.init(ok: checks.filter { $0.level == .ok }.count, warn: checks.filter { $0.level == .warn }.count,
                  fail: checks.filter { $0.level == .fail }.count)
    }
}

/// `benchbar doctor --json`.
nonisolated struct DoctorReport: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var cliVersion: String?
    var bench: String
    var site: String?
    var profile: String?
    /// Added in 0.7.3: where the profile came from (flag, team, stored,
    /// detected, default). "default" means no profile matches the bench.
    var profileSource: String? = nil
    var checks: [DoctorCheck]
    var summary: DoctorSummary
    /// Entries of `checks` that did not decode (not part of the JSON).
    var skipped: [String] = []

    /// The profile is only the default: no profile matches this bench's Frappe.
    var profileIsDefault: Bool { profileSource == "default" }

    enum CodingKeys: String, CodingKey {
        case bench, site, profile, checks, summary
        case schemaVersion = "schema_version"
        case cliVersion = "cli_version"
        case profileSource = "profile_source"
    }

    /// `bench` is the identity. A missing summary is counted from the checks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = try c.lossyList(DoctorCheck.self, forKey: .checks)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        cliVersion = c.lenient(.cliVersion, nil)
        bench = try c.decode(String.self, forKey: .bench)
        site = c.lenient(.site, nil)
        profile = c.lenient(.profile, nil)
        profileSource = c.lenient(.profileSource, nil)
        checks = list.items
        summary = c.lenient(.summary, DoctorSummary(counting: list.items))
        skipped = list.skipped
    }
}

/// Anything with a schema version, decoded first to refuse a newer major.
nonisolated struct SchemaProbe: Decodable {
    var schemaVersion: Int
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version" }
}

nonisolated enum BenchJSON {
    /// The schema version this build understands.
    static let supportedSchema = 1

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Decodes a benchbar JSON document, refusing a schema this app does not know.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(CLIError) -> T {
        let decoder = decoder()
        let probe: SchemaProbe
        do {
            probe = try decoder.decode(SchemaProbe.self, from: data)
        } catch {
            throw .invalidJSON(detail: Self.describe(error), preview: Self.preview(data))
        }
        guard probe.schemaVersion <= supportedSchema else {
            throw .unsupportedSchema(found: probe.schemaVersion, supported: supportedSchema)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw .invalidJSON(detail: Self.describe(error), preview: Self.preview(data))
        }
    }

    static func preview(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _):
            return "missing field \(key.stringValue)"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "wrong type at \(path.isEmpty ? "top level" : path)"
        case DecodingError.dataCorrupted(let context):
            return context.debugDescription
        default:
            return error.localizedDescription
        }
    }
}

// MARK: 0.5: apps, profiles, repair events

/// One app of a bench (`benchbar app list --json`).
nonisolated struct AppInfo: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var inAppsTxt: Bool
    var repo: String?
    var branch: String?
    var policyBranch: String?
    var commit: String?
    var dirty: Bool
    var version: String?
    var sites: [String]
    // 0.6: focus apps and freshness (nil from an older CLI), see AppFocus.swift
    var focus: Bool?
    var focusPin: String?
    var focusReasons: [String]?
    var requires: [String]?
    var neededBy: [String]?
    var upstream: String?
    var behind: Int?
    var behindDays: Int?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, repo, branch, commit, dirty, version, sites
        case focus, requires, upstream, behind
        case inAppsTxt = "in_apps_txt"
        case policyBranch = "policy_branch"
        case focusPin = "focus_pin"
        case focusReasons = "focus_reasons"
        case neededBy = "needed_by"
        case behindDays = "behind_days"
    }
}

nonisolated extension AppInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), inAppsTxt: c.lenient(.inAppsTxt, false),
                  repo: c.lenient(.repo, nil), branch: c.lenient(.branch, nil), policyBranch: c.lenient(.policyBranch, nil),
                  commit: c.lenient(.commit, nil), dirty: c.lenient(.dirty, false), version: c.lenient(.version, nil),
                  sites: c.lenient(.sites, []), focus: c.lenient(.focus, nil), focusPin: c.lenient(.focusPin, nil),
                  focusReasons: c.lenient(.focusReasons, nil), requires: c.lenient(.requires, nil),
                  neededBy: c.lenient(.neededBy, nil), upstream: c.lenient(.upstream, nil),
                  behind: c.lenient(.behind, nil), behindDays: c.lenient(.behindDays, nil))
    }
}

/// `benchbar app list --json`.
nonisolated struct AppList: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var bench: String
    /// When bench was last asked which sites have which app; nil when it
    /// never was, and then every app's `sites` is empty, not known.
    var sitesCheckedAt: String?
    var sitesError: String?
    var apps: [AppInfo]
    /// Entries of `apps` that did not decode (not part of the JSON).
    var skipped: [String] = []

    var sitesKnown: Bool { sitesCheckedAt != nil }

    enum CodingKeys: String, CodingKey {
        case bench, apps
        case schemaVersion = "schema_version"
        case sitesCheckedAt = "sites_checked_at"
        case sitesError = "sites_error"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = try c.lossyList(AppInfo.self, forKey: .apps)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        bench = try c.decode(String.self, forKey: .bench)
        sitesCheckedAt = c.lenient(.sitesCheckedAt, nil)
        sitesError = c.lenient(.sitesError, nil)
        apps = list.items
        skipped = list.skipped
    }
}

/// `benchbar app update NAME --dry-run --json`: what an update would do.
nonisolated struct AppUpdatePlan: Codable, Sendable, Equatable {
    nonisolated struct Commit: Codable, Sendable, Equatable, Identifiable {
        var sha: String
        var subject: String
        var id: String { sha }
    }
    nonisolated struct Step: Codable, Sendable, Equatable, Identifiable {
        var name: String
        var command: String
        var id: String { name }
    }

    var schemaVersion: Int
    var app: String
    var branch: String?
    var from: String
    var to: String
    var commits: [Commit]
    var commitsTotal: Int
    var sites: [String]
    var steps: [Step]

    var isUpToDate: Bool { from == to || steps.isEmpty }

    enum CodingKeys: String, CodingKey {
        case app, branch, from, to, commits, sites, steps
        case schemaVersion = "schema_version"
        case commitsTotal = "commits_total"
    }
}

/// One profile (`benchbar profile list --json`): built in or a team's.
/// `source` says where it lives (builtin, user, imported, subscribed, path);
/// since 0.6.0 `source_url` is the URL an import or subscription came from.
nonisolated struct ProfileInfo: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var kind: String
    var source: String?
    var file: String
    var base: String?
    var label: String?
    var frappeBranch: String?
    var valid: Bool
    var error: String?
    var sourceURL: String?
    var subscription: ProfileSubscription?
    var shadowedBy: String?
    var schema: Int?
    /// 0.8: the versions the profile brings ("3.11", "22", "10.11"); nil from an older CLI.
    var python: String?
    var node: String?
    var mariadb: String?

    /// A shadowed file has the same name as the one that wins, so the file is part of the id.
    var id: String { "\(name)\t\(file)" }
    var isTeam: Bool { kind == "team" }

    enum CodingKeys: String, CodingKey {
        case name, kind, source, file, base, label, valid, error, subscription, schema, python, node, mariadb
        case frappeBranch = "frappe_branch"
        case sourceURL = "source_url"
        case shadowedBy = "shadowed_by"
    }
}

nonisolated extension ProfileInfo {
    /// `name` is the identity. A profile that does not say whether it is valid
    /// is valid unless it carries an error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let error: String? = c.lenient(.error, nil)
        self.init(name: try c.decode(String.self, forKey: .name), kind: c.lenient(.kind, ""),
                  source: c.lenient(.source, nil), file: c.lenient(.file, ""), base: c.lenient(.base, nil),
                  label: c.lenient(.label, nil), frappeBranch: c.lenient(.frappeBranch, nil),
                  valid: c.lenient(.valid, error == nil), error: error, sourceURL: c.lenient(.sourceURL, nil),
                  subscription: c.lenient(.subscription, nil), shadowedBy: c.lenient(.shadowedBy, nil),
                  schema: c.lenient(.schema, nil), python: c.lenient(.python, nil), node: c.lenient(.node, nil),
                  mariadb: c.lenient(.mariadb, nil))
    }
}

/// One app bundle `install --bundle` takes (`profile list --json`, 0.8).
nonisolated struct AppBundle: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var label: String
    var apps: [String]
    var description: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, label, apps, description }
}

nonisolated extension AppBundle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        self.init(name: name, label: c.lenient(.label, name), apps: c.lenient(.apps, []),
                  description: c.lenient(.description, nil))
    }
}

nonisolated struct ProfileList: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var profiles: [ProfileInfo]
    /// 0.8; nil from an older CLI.
    var bundles: [AppBundle]?

    enum CodingKeys: String, CodingKey {
        case profiles, bundles
        case schemaVersion = "schema_version"
    }
}

/// One line of `benchbar repair --json` (docs/json-schema.md).
nonisolated enum RepairEvent: Equatable, Sendable {
    nonisolated struct Action: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var label: String
        var fixes: [String]
        var sudo: Bool
    }

    case plan(actions: [Action], log: String?)
    case step(action: String, status: String, message: String)
    case done(exitCode: Int, log: String?)

    /// nil for a line that is not an event this reader knows (ignored, per the schema rules).
    static func parse(_ line: String) -> RepairEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        switch event {
        case "plan":
            let raw = (object["actions"] as? [[String: Any]]) ?? []
            let actions = raw.compactMap { a -> Action? in
                guard let id = a["id"] as? String else { return nil }
                return Action(id: id, label: a["label"] as? String ?? id,
                              fixes: a["fixes"] as? [String] ?? [], sudo: a["sudo"] as? Bool ?? false)
            }
            return .plan(actions: actions, log: object["log"] as? String)
        case "step":
            guard let action = object["action"] as? String, let status = object["status"] as? String else { return nil }
            return .step(action: action, status: status, message: object["message"] as? String ?? "")
        case "done":
            return .done(exitCode: object["exit_code"] as? Int ?? 1, log: object["log"] as? String)
        default:
            return nil
        }
    }
}

/// `benchbar report --json` (CLI 0.5.5): where the zip went and how many
/// lines had something replaced.
nonisolated struct BugReportFile: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var zip: String
    var redactions: Int

    enum CodingKeys: String, CodingKey {
        case zip, redactions
        case schemaVersion = "schema_version"
    }
}
