import Foundation
import Testing
@testable import BenchBar

@Suite("JSON models")
struct ModelTests {
    @Test func decodesList() throws {
        let list = try BenchJSON.decode(BenchList.self, from: Fixture.data("list"))
        #expect(list.schemaVersion == 1)
        #expect(list.defaultBench == "/Users/you/frappe-bench")
        #expect(list.benches.count == 2)
        let second = list.benches[1]
        #expect(second.name == "v16")
        #expect(second.ports == BenchPorts(web: 8001, socketio: 9001, redisQueue: 11001, redisCache: 13001, redisSocketio: 13001))
        #expect(second.isDefault == false)
        #expect(second.serviceInstalled == false)
        #expect(second.id == "/Users/you/dev/v16")
    }

    @Test func portsFromACLIBefore04HaveNoSocketioRedis() throws {
        let json = Data(#"{"web":8000,"socketio":9000,"redis_queue":11000,"redis_cache":13000}"#.utf8)
        let ports = try JSONDecoder().decode(BenchPorts.self, from: json)
        #expect(ports.redisSocketio == nil)
        #expect(ports.web == 8000)
    }

    @Test func decodesEmptyList() throws {
        let list = try BenchJSON.decode(BenchList.self, from: Fixture.data("list-empty"))
        #expect(list.benches.isEmpty)
        #expect(list.defaultBench == nil)
    }

    @Test func decodesRunningStatus() throws {
        let status = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-running"))
        #expect(status.state == .running)
        #expect(status.stopReason == nil)
        #expect(status.pid == 4242)
        #expect(status.webPingCode == 200)
        #expect(status.lastExitCode == 0)
        #expect(status.agentLoaded == true)
        let started = try #require(status.startedAt)
        #expect(started == ISO8601DateFormatter().date(from: "2026-09-23T10:00:00Z"))
    }

    @Test func decodesStoppedAndPaused() throws {
        let stopped = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-stopped"))
        #expect(stopped.state == .stopped)
        #expect(stopped.stopReason == .manual)
        #expect(stopped.pid == nil)
        #expect(stopped.webPingCode == nil)
        let paused = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-paused"))
        #expect(paused.state == .paused)
        #expect(paused.stopReason == .crash)
        #expect(paused.lastExitCode == 1)
        #expect(paused.ports == nil)
    }

    @Test func unknownValuesAndFieldsAreTolerated() throws {
        let status = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-future"))
        #expect(status.state == .unknown)
        #expect(status.stopReason == .unknown)
    }

    @Test func newerSchemaIsRefused() throws {
        #expect(throws: CLIError.unsupportedSchema(found: 2, supported: 1)) {
            try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-schema2"))
        }
    }

    @Test func garbageIsInvalidJSON() {
        #expect {
            try BenchJSON.decode(BenchStatus.self, from: Data("[FAIL] No bench at /nope".utf8))
        } throws: { error in
            guard case CLIError.invalidJSON(_, let preview) = error else { return false }
            return preview.hasPrefix("[FAIL]")
        }
    }

    @Test func missingFieldIsNamed() {
        #expect {
            try BenchJSON.decode(BenchStatus.self, from: Data(#"{"schema_version":1,"bench":"/x"}"#.utf8))
        } throws: { error in
            guard case CLIError.invalidJSON(let detail, _) = error else { return false }
            return detail.contains("state")
        }
    }

    @Test func decodesRunnerStateFile() throws {
        let state = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("state-runner"))
        #expect(state.state == .crashed)
        #expect(state.source == "runner")
        #expect(state.updatedAt != nil)
    }

    @Test func decodesDoctor() throws {
        let report = try BenchJSON.decode(DoctorReport.self, from: Fixture.data("doctor"))
        #expect(report.checks.count == 3)
        #expect(report.summary == DoctorSummary(ok: 1, warn: 1, fail: 1))
        let assets = try #require(report.checks.first { $0.id == "assets" })
        #expect(assets.level == .fail)
        #expect(assets.fixCommand == "cd /Users/you/frappe-bench && bench build")
        #expect(report.checks.first?.fixCommand == nil)
    }
}
