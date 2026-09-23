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

    enum CodingKeys: String, CodingKey {
        case web, socketio
        case redisQueue = "redis_queue"
        case redisCache = "redis_cache"
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

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, name, site, label, ports
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
    // state.json only
    var updatedAt: Date?
    var source: String?

    enum CodingKeys: String, CodingKey {
        case bench, name, site, label, state, pid, ports, log, source
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
