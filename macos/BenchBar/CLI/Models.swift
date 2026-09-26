import Foundation

// Codable models for the benchbar JSON API, schema version 1.
// docs/json-schema.md is the source of truth; field names map with
// explicit CodingKeys so a rename on either side is a compile error here.
//
// Rules from the schema: ignore unknown fields (Codable does), and treat
// an unknown enum value as .unknown instead of failing the whole decode.

nonisolated enum BenchState: String, Codable, Sendable, CaseIterable {
    case stopped, starting, running, crashed, paused, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BenchState(rawValue: raw) ?? .unknown
    }
}

nonisolated enum StopReason: String, Codable, Sendable {
    case manual, crash, broken, unknown

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

/// One site of a bench (`sites[]` in list and status, added in 0.4).
nonisolated struct SiteInfo: Codable, Sendable, Equatable, Hashable, Identifiable {
    var name: String
    var isDefault: Bool
    var hostsEntry: Bool
    var pingCode: Int?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case isDefault = "default"
        case hostsEntry = "hosts_entry"
        case pingCode = "ping_code"
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

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, name, site, label, ports, sites
        case webURL = "web_url"
        case isDefault = "default"
        case serviceInstalled = "service_installed"
        case stateFile = "state_file"
    }
}

/// `benchbar list --json`.
nonisolated struct BenchList: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var cliVersion: String
    var defaultBench: String?
    var benches: [BenchSummary]

    enum CodingKeys: String, CodingKey {
        case benches
        case schemaVersion = "schema_version"
        case cliVersion = "cli_version"
        case defaultBench = "default_bench"
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

nonisolated struct DoctorSummary: Codable, Sendable, Equatable {
    var ok: Int
    var warn: Int
    var fail: Int
}

/// `benchbar doctor --json`.
nonisolated struct DoctorReport: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var cliVersion: String?
    var bench: String
    var site: String?
    var profile: String?
    var checks: [DoctorCheck]
    var summary: DoctorSummary

    enum CodingKeys: String, CodingKey {
        case bench, site, profile, checks, summary
        case schemaVersion = "schema_version"
        case cliVersion = "cli_version"
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

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, repo, branch, commit, dirty, version, sites
        case inAppsTxt = "in_apps_txt"
        case policyBranch = "policy_branch"
    }
}

/// `benchbar app list --json`.
nonisolated struct AppList: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var bench: String
    var sitesError: String?
    var apps: [AppInfo]

    enum CodingKeys: String, CodingKey {
        case bench, apps
        case schemaVersion = "schema_version"
        case sitesError = "sites_error"
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
nonisolated struct ProfileInfo: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var kind: String
    var source: String
    var file: String
    var base: String?
    var label: String?
    var frappeBranch: String?
    var valid: Bool
    var error: String?

    var id: String { name }
    var isTeam: Bool { kind == "team" }

    enum CodingKeys: String, CodingKey {
        case name, kind, source, file, base, label, valid, error
        case frappeBranch = "frappe_branch"
    }
}

nonisolated struct ProfileList: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var profiles: [ProfileInfo]

    enum CodingKeys: String, CodingKey {
        case profiles
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
