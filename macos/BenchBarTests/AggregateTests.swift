import Foundation
import Testing
@testable import BenchBar

@Suite("Several benches")
struct AggregateTests {
    @Test func worstStateWins() {
        #expect(BenchAggregate.state([.running, .crashed]) == .crashed)
        #expect(BenchAggregate.state([.running, .paused, .starting]) == .paused)
        #expect(BenchAggregate.state([.stopped, .starting, .running]) == .starting)
        #expect(BenchAggregate.state([.stopped, .running]) == .running)
        #expect(BenchAggregate.state([.stopped, .stopped]) == .stopped)
    }

    @Test func unknownOnlyWhenNothingIsKnown() {
        #expect(BenchAggregate.state([]) == .unknown)
        #expect(BenchAggregate.state([.unknown, .unknown]) == .unknown)
        #expect(BenchAggregate.state([.unknown, .running]) == .running)
        #expect(BenchAggregate.state([.unknown, .stopped]) == .stopped)
    }

    @Test func upCount() {
        #expect(BenchAggregate.upCount([.running, .starting, .stopped, .crashed]) == 2)
        #expect(BenchAggregate.upText([.running, .stopped]) == "1 of 2 up")
        #expect(BenchAggregate.upText([.stopped, .paused]) == "none up")
    }

    @Test func siteRowsPutTheDefaultFirst() {
        let sites = [
            SiteInfo(name: "v16two", isDefault: false, hostsEntry: false, pingCode: nil),
            SiteInfo(name: "v16dev", isDefault: true, hostsEntry: true, pingCode: 200),
            SiteInfo(name: "alpha", isDefault: false, hostsEntry: true, pingCode: nil),
        ]
        let rows = SiteRow.make(sites: sites, defaultSite: "v16dev", port: 8001)
        #expect(rows.map(\.name) == ["v16dev", "alpha", "v16two"])
        #expect(rows[0].url == "http://v16dev:8001")
        #expect(rows[2].needsHosts)
        #expect(SiteRow.hostsFix(rows, bench: "/Users/you/dev/v16-bench") == "benchbar site hosts --bench-dir /Users/you/dev/v16-bench")
    }

    @Test func siteRowsFromAnOlderCLI() {
        let rows = SiteRow.make(sites: nil, defaultSite: "macdev", port: 8000)
        #expect(rows == [SiteRow(name: "macdev", isDefault: true, url: "http://macdev:8000", needsHosts: false)])
        #expect(SiteRow.hostsFix(rows, bench: "/b") == nil)
    }
}

@Suite("Two benches in the store")
struct TwoBenchStoreTests {
    let base: BenchStoreTests
    let v15 = "/Users/you/frappe-bench"
    let v16 = "/Users/you/dev/v16-bench"

    init() throws { base = try BenchStoreTests() }

    func status(_ bench: String, _ state: String, reason: String? = nil, pid: Int? = nil) -> String {
        let r = reason.map { "\"\($0)\"" } ?? "null"
        let p = pid.map(String.init) ?? "null"
        return #"{"schema_version":1,"bench":"\#(bench)","state":"\#(state)","stop_reason":\#(r),"pid":\#(p),"started_at":"2026-09-26T02:00:00Z","last_exit_code":null,"web_url":"http://x:8000","web_ping_code":null}"#
    }

    func store(v15 v15State: String, v16 v16State: String, v16Reason: String? = nil) async throws -> BenchStore {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", bench: v15, json: status(v15, v15State, pid: v15State == "running" ? 4242 : nil))
        base.cli.answer("status", bench: v16, json: status(v16, v16State, reason: v16Reason, pid: v16State == "running" ? 5151 : nil))
        let store = base.makeStore()
        await store.start(polling: false)
        return store
    }

    @Test func aCrashAnywhereStumbles() async throws {
        let store = try await store(v15: "running", v16: "paused", v16Reason: "crash")
        #expect(store.selected?.path == v15)
        #expect(store.displayState == .paused)
    }

    @Test func runningWhenOneRuns() async throws {
        let store = try await store(v15: "stopped", v16: "running")
        #expect(store.displayState == .running)
        // the selected bench is stopped, so the running one sets the speed
        #expect(store.speedBench?.path == v16)
    }

    @Test func speedFromTheSelectedBenchWhileItRuns() async throws {
        let store = try await store(v15: "running", v16: "running")
        #expect(store.speedBench?.path == v15)
        store.selectedPath = v16
        #expect(store.speedBench?.path == v16)
    }

    @Test func sitesOfTheSecondBench() async throws {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", bench: v15, json: status(v15, "stopped"))
        base.cli.answer("status", bench: v16, json: try Fixture.string("status-v16-two-sites"))
        let store = base.makeStore()
        await store.start(polling: false)
        let bench = try #require(store.benches.first { $0.path == v16 })
        #expect(bench.siteRows.map(\.name) == ["v16dev", "v16two"])
        #expect(bench.siteRows[1].url == "http://v16two:8001")
        #expect(SiteRow.hostsFix(bench.siteRows, bench: v16) == "benchbar site hosts --bench-dir /Users/you/dev/v16-bench")
        #expect(bench.schedulerOn == true)
    }

    @Test func schedulerRunsServiceThenRestartsARunningBench() async throws {
        let store = try await store(v15: "stopped", v16: "running")
        base.cli.answer("service", json: "")
        base.cli.answer("restart", json: "")
        let bench = try #require(store.benches.first { $0.path == v16 })
        await store.setScheduler(true, on: bench)
        let calls = base.cli.calls
        #expect(calls.contains(["service", "--yes", "--plain", "--with-schedule", "--bench-dir", v16]))
        #expect(calls.contains(["restart", "--plain", "--bench-dir", v16]))
        #expect(!calls.contains { $0.first == "restart" && $0.last == v15 })
    }

    @Test func noActionWhileTheSchedulerChanges() {
        let c = BenchControls.make(state: .running, reason: nil, pending: nil, needsService: false, cliReady: true, otherWork: true)
        #expect(c == .none)
    }

    @Test func aSecondSchedulerChangeWaitsForTheFirst() async throws {
        let store = try await store(v15: "stopped", v16: "stopped")
        base.cli.answer("service", json: "")
        let bench = try #require(store.benches.first { $0.path == v16 })
        bench.isChangingScheduler = true
        await store.setScheduler(true, on: bench)
        #expect(!base.cli.calls.contains { $0.first == "service" }, "ignored while one runs")
        bench.isChangingScheduler = false
        await store.setScheduler(true, on: bench)
        #expect(base.cli.calls.contains { $0.first == "service" })
        #expect(bench.isChangingScheduler == false, "cleared when done")
    }

    @Test func oneChangeAtATimeAcrossBenches() async throws {
        // the CLI's lock covers the checkout: a change on one bench blocks the others
        let store = try await store(v15: "stopped", v16: "stopped")
        base.cli.answer("up", json: "")
        let first = try #require(store.benches.first { $0.path == v15 })
        let second = try #require(store.benches.first { $0.path == v16 })
        first.isChangingScheduler = true
        #expect(store.waitsForOtherBench(second))
        #expect(!store.waitsForOtherBench(first))
        await store.perform(.up, on: second)
        #expect(!base.cli.calls.contains { $0.first == "up" }, "no second CLI run while one holds the lock")
        first.isChangingScheduler = false
        #expect(!store.waitsForOtherBench(second))
        await store.perform(.up, on: second)
        #expect(base.cli.calls.contains { $0.first == "up" })
    }

    @Test func schedulerLeavesAStoppedBenchStopped() async throws {
        let store = try await store(v15: "stopped", v16: "stopped")
        base.cli.answer("service", json: "")
        let bench = try #require(store.benches.first { $0.path == v16 })
        await store.setScheduler(false, on: bench)
        #expect(base.cli.calls.contains(["service", "--yes", "--plain", "--without-schedule", "--bench-dir", v16]))
        #expect(!base.cli.calls.contains { $0.first == "restart" })
    }
}
