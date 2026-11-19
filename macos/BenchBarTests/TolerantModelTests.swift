import Foundation
import Testing
@testable import BenchBar

/// MAC-9: only the identity of a thing is required. Every other field can
/// be missing without failing the document, and one bad list entry never
/// hides the others. Field names are the CLI's own.
@Suite("Tolerant models")
struct TolerantModelTests {
    private static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// Decodes `object` once for each key of it that is not an identity key, with that key removed.
    private static func decodeWithoutEach<T: Decodable>(_ type: T.Type, _ object: [String: Any], keeping identity: Set<String>,
                                                        check: (T, String) -> Void) throws {
        for key in object.keys.sorted() where !identity.contains(key) {
            var copy = object
            copy.removeValue(forKey: key)
            check(try BenchJSON.decode(type, from: data(copy)), key)
        }
    }

    private static let site: [String: Any] = ["name": "macdev", "default": true, "hosts_entry": true, "ping_code": 200,
                                              "developer_mode": true, "open_as_enabled": true, "open_as": true]
    private static let ports: [String: Any] = ["web": 8000, "socketio": 9000, "redis_queue": 11000, "redis_cache": 13000, "redis_socketio": 13000]
    private static let summary: [String: Any] = [
        "path": "/Users/you/dev/v16", "name": "v16", "site": "v16.localhost", "label": "com.benchbar.v16",
        "web_url": "http://v16.localhost:8001", "ports": ports, "default": false, "service_installed": true,
        "state_file": "/Users/you/dev/v16/logs/.benchbar/state.json", "lock_file": "/x/benchbar.toml", "sites": [site],
    ]

    @Test func aBenchWithoutAnyFieldButItsPathStillDecodes() throws {
        var count = 0
        try Self.decodeWithoutEach(BenchSummary.self, ["schema_version": 1].merging(Self.summary) { a, _ in a }, keeping: ["path", "schema_version"]) { bench, key in
            #expect(bench.path == "/Users/you/dev/v16", "without \(key)")
            count += 1
        }
        #expect(count >= 10)
        let bare = try BenchJSON.decode(BenchSummary.self, from: Self.data(["schema_version": 1, "path": "/Users/you/dev/v16"]))
        #expect(bare.name == "v16")
        #expect(bare.site == "")
        #expect(bare.ports == BenchPorts(web: 0, socketio: 0, redisQueue: 0, redisCache: 0))
        #expect(bare.stateFile == "/Users/you/dev/v16/logs/.benchbar/state.json")
        #expect(bare.isDefault == false && bare.serviceInstalled == false && bare.sites == nil)
    }

    @Test func aMissingPathIsTheOnlyThingThatFailsABench() {
        var noPath = Self.summary
        noPath.removeValue(forKey: "path")
        #expect(throws: CLIError.self) {
            try BenchJSON.decode(BenchSummary.self, from: Self.data(noPath.merging(["schema_version": 1]) { a, _ in a }))
        }
    }

    @Test func portsAndSitesLoseFieldsOneByOne() throws {
        try Self.decodeWithoutEach(BenchPorts.self, Self.ports.merging(["schema_version": 1]) { a, _ in a }, keeping: ["schema_version"]) { ports, key in
            #expect(ports.web == (key == "web" ? 0 : 8000), "without \(key)")
        }
        try Self.decodeWithoutEach(SiteInfo.self, Self.site.merging(["schema_version": 1]) { a, _ in a }, keeping: ["name", "schema_version"]) { site, key in
            #expect(site.name == "macdev", "without \(key)")
        }
    }

    @Test func oneBadBenchDoesNotHideTheList() throws {
        var broken = Self.summary
        broken.removeValue(forKey: "path")
        let document: [String: Any] = ["schema_version": 1, "benches": [Self.summary, broken, "not an object", Self.summary.merging(["path": "/b"]) { _, n in n }]]
        let list = try BenchJSON.decode(BenchList.self, from: Self.data(document))
        #expect(list.benches.map(\.path) == ["/Users/you/dev/v16", "/b"])
        #expect(list.skipped.count == 2)
        #expect(list.skipped[0].contains("path"))
        #expect(list.cliVersion == "" && list.defaultBench == nil)
    }

    /// A document without its list is not an empty list: only a bad entry inside a list is skipped.
    @Test func aListThatIsMissingOrNotAnArrayThrows() throws {
        func rejects<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> Bool {
            do {
                _ = try JSONDecoder().decode(type, from: Self.data(object))
                return false
            } catch let error as DecodingError {
                switch error {
                case .keyNotFound, .typeMismatch, .valueNotFound: return true
                default: return false
                }
            }
        }
        #expect(try rejects(BenchList.self, ["schema_version": 1]), "no benches key")
        #expect(try rejects(BenchList.self, ["schema_version": 1, "benches": "none"]), "benches is a string")
        #expect(try rejects(BenchList.self, ["schema_version": 1, "benches": ["a": 1]]), "benches is an object")
        #expect(try rejects(BenchList.self, ["schema_version": 1, "benches": NSNull()]), "benches is null")
        #expect(try rejects(DoctorReport.self, ["schema_version": 1, "bench": "/b"]), "no checks key")
        #expect(try rejects(AppList.self, ["schema_version": 1, "bench": "/b", "apps": 3]), "apps is a number")
        #expect(try rejects(LabsDocument.self, ["schema_version": 1]), "no labs key")
        // through the app's own door the failure is the CLI error with the preview
        #expect(throws: CLIError.self) { try BenchJSON.decode(BenchList.self, from: Self.data(["schema_version": 1])) }
        // an empty list is a list
        let empty = try BenchJSON.decode(BenchList.self, from: Self.data(["schema_version": 1, "benches": []]))
        #expect(empty.benches.isEmpty && empty.skipped.isEmpty)
    }

    @Test func aLabWithoutItsDescriptionsStillShows() throws {
        let lab: [String: Any] = ["name": "share", "title": "Share", "description": "d", "warning": "w", "since": "0.8.2",
                                  "enabled": true, "commands": ["share"], "platforms": ["macos"], "available": true]
        try Self.decodeWithoutEach(LabEntry.self, lab.merging(["schema_version": 1]) { a, _ in a }, keeping: ["name", "schema_version"]) { entry, key in
            #expect(entry.name == "share", "without \(key)")
        }
        let document: [String: Any] = ["schema_version": 1, "labs": [lab.filter { $0.key != "since" }, ["title": "no name"], lab]]
        let labs = try BenchJSON.decode(LabsDocument.self, from: Self.data(document)).labs
        #expect(labs.count == 2)
        #expect(labs[0].since == "")
        #expect(labs[0].title == "Share")
    }

    @Test func doctorKeepsGoodChecksAndCountsWhenTheSummaryIsMissing() throws {
        let check: [String: Any] = ["id": "assets", "group": "bench", "label": "Built assets", "level": "fail",
                                    "message": "m", "fix_command": "bench build", "action": "build"]
        try Self.decodeWithoutEach(DoctorCheck.self, check.merging(["schema_version": 1]) { a, _ in a }, keeping: ["id", "schema_version"]) { value, key in
            #expect(value.id == "assets", "without \(key)")
        }
        let document: [String: Any] = ["schema_version": 1, "bench": "/b", "checks": [check, ["level": "ok"], check.merging(["id": "env", "level": "ok"]) { _, n in n }]]
        let report = try BenchJSON.decode(DoctorReport.self, from: Self.data(document))
        #expect(report.checks.map(\.id) == ["assets", "env"])
        #expect(report.skipped.count == 1)
        #expect(report.summary == DoctorSummary(ok: 1, warn: 0, fail: 1))
        let level = try BenchJSON.decode(DoctorCheck.self, from: Self.data(["schema_version": 1, "id": "x"]))
        #expect(level.level == .unknown, "a check with no level is not a pass")
    }

    @Test func appsAndProfilesLoseFieldsOneByOne() throws {
        let app: [String: Any] = ["name": "erpnext", "in_apps_txt": true, "repo": "r", "branch": "b", "policy_branch": "b", "commit": "c",
                                  "dirty": true, "version": "1", "sites": ["a"], "focus": true, "focus_pin": "p", "focus_reasons": ["x"],
                                  "requires": ["frappe"], "needed_by": ["y"], "upstream": "u", "behind": 2, "behind_days": 3]
        try Self.decodeWithoutEach(AppInfo.self, app.merging(["schema_version": 1]) { a, _ in a }, keeping: ["name", "schema_version"]) { value, key in
            #expect(value.name == "erpnext", "without \(key)")
        }
        let apps = try BenchJSON.decode(AppList.self, from: Self.data(["schema_version": 1, "bench": "/b", "apps": [app, ["repo": "no name"]]]))
        #expect(apps.apps.map(\.name) == ["erpnext"])
        #expect(apps.skipped.count == 1)

        let profile: [String: Any] = ["name": "acme", "kind": "team", "source": "user", "file": "/f", "base": "v15-lts", "label": "Acme",
                                      "frappe_branch": "version-15", "valid": false, "error": "bad", "source_url": "https://x/y.toml",
                                      "shadowed_by": "z", "schema": 1, "python": "3.11", "node": "22", "mariadb": "10.11"]
        try Self.decodeWithoutEach(ProfileInfo.self, profile.merging(["schema_version": 1]) { a, _ in a }, keeping: ["name", "schema_version"]) { value, key in
            #expect(value.name == "acme", "without \(key)")
        }
        let plain = try BenchJSON.decode(ProfileInfo.self, from: Self.data(["schema_version": 1, "name": "p"]))
        #expect(plain.valid, "no error, so valid")
        let bad = try BenchJSON.decode(ProfileInfo.self, from: Self.data(["schema_version": 1, "name": "p", "error": "x"]))
        #expect(!bad.valid)
        let bundle = try BenchJSON.decode(AppBundle.self, from: Self.data(["schema_version": 1, "name": "hr"]))
        #expect(bundle.label == "hr" && bundle.apps.isEmpty)
    }

    @Test func aChangedSchemaStillWins() {
        #expect(throws: CLIError.unsupportedSchema(found: 2, supported: 1)) {
            try BenchJSON.decode(BenchList.self, from: Self.data(["schema_version": 2, "benches": []]))
        }
    }

    @Test func theSchemaHintIsForAUser() {
        #expect(CLIError.unsupportedSchema(found: 2, supported: 1).recoverySuggestion == "Update BenchBar, or choose a different benchbar in Settings.")
    }

    // MARK: skipped entries are logged where the document is decoded

    private nonisolated final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [(source: String, entries: [String])] = []
        func add(_ source: String, _ entries: [String]) { lock.withLock { rows.append((source, entries)) } }
        var all: [(source: String, entries: [String])] { lock.withLock { rows } }
    }

    private func client(returning stdout: String, into reports: Reports) -> CLIClient {
        var client = CLIClient(executable: URL(fileURLWithPath: "/Users/you/.local/bin/benchbar"), runner: FakeRunner { _ in .ok(stdout) })
        client.onSkipped = { source, entries in reports.add(source, entries) }
        return client
    }

    private static func text(_ object: Any) throws -> String {
        String(decoding: try data(object), as: UTF8.self)
    }

    @Test func doctorAppsAndLabsNameTheEntriesTheyLeftOut() async throws {
        let reports = Reports()
        let check: [String: Any] = ["id": "env", "level": "ok"]
        let report = try await client(returning: Self.text(["schema_version": 1, "bench": "/b", "checks": [check, ["level": "ok"]]]), into: reports).doctor(bench: "/b")
        #expect(report.checks.map(\.id) == ["env"])
        let apps = try await client(returning: Self.text(["schema_version": 1, "bench": "/b", "apps": [["name": "erpnext"], ["repo": "x"], "oops"]]), into: reports).apps(bench: "/b")
        #expect(apps.apps.map(\.name) == ["erpnext"])
        let labs = try await client(returning: Self.text(["schema_version": 1, "labs": [["name": "share"], ["title": "no name"]]]), into: reports).labs()
        #expect(labs.map(\.name) == ["share"])
        let all = reports.all
        #expect(all.map(\.source) == ["doctor", "app list", "labs list"])
        #expect(all.map(\.entries.count) == [1, 2, 1])
        #expect(all[0].entries[0].hasPrefix("entry 1"))
    }

    @Test func aDocumentWithNothingLeftOutLogsNothing() async throws {
        let reports = Reports()
        _ = try await client(returning: Self.text(["schema_version": 1, "bench": "/b", "checks": [["id": "env", "level": "ok"]]]), into: reports).doctor(bench: "/b")
        _ = try await client(returning: Self.text(["schema_version": 1, "bench": "/b", "apps": []]), into: reports).apps(bench: "/b")
        #expect(reports.all.isEmpty)
    }
}
