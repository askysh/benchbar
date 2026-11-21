import Foundation
import Testing
@testable import BenchBar

/// Mac app parity, part 3 (#177): the lockfile, logs, snapshots and rollback, the history, leases, services only
/// without a service and autostart from the status. The documents are the CLI's own output (recorded from the mocked CLI);
/// nothing here changes a bench.
@Suite("Mac app parity, part 3", .serialized)
struct ActivityTests {
    let base: BenchStoreTests
    let v16 = "/Users/you/dev/v16-bench"

    init() throws { base = try BenchStoreTests() }

    func workbench() async throws -> (Workbench, BenchModel, FakeRunner) {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites"))
        let runner = base.cli.runner()
        let store = BenchStore(settings: base.settings,
                               locator: CLILocator(home: base.dir.url, isExecutable: { $0 == "/fake/benchbar" }),
                               makeClient: { CLIClient(executable: $0, runner: runner) },
                               pinger: { _, _ in 200 })
        await store.start(polling: false)
        return (Workbench(store: store), try #require(store.benches.first { $0.path == v16 }), runner)
    }

    let leaseText = "[FAIL] The site acme.localhost of /Users/you/dev/v16-bench is leased by claude-qa until 2027-01-15T08:20:00Z (running the QA suite). Nothing was changed."

    // MARK: snapshots (P22)

    @Test func decodesTheSnapshotListAndTreatsAMissingLabelAsNone() throws {
        let list = try BenchJSON.decode(SiteSnapshotList.self, from: Fixture.data("snapshots"))
        #expect(list.site == "acme.localhost" && list.keep == 10 && list.snapshots.count == 2 && list.overLimit.isEmpty)
        #expect(list.snapshots[0].label == nil && list.snapshots[0].title == "20261121_090000", "the CLI printed null as a word: no label")
        #expect(list.snapshots[1].label == "Before upgrade" && list.snapshots[1].title == "Before upgrade")
        #expect(list.snapshots[1].apps.map(\.name) == ["frappe", "erpnext"] && list.snapshots[1].changedApps == ["erpnext"] && list.snapshots[1].appsMatch == false)
        #expect(list.totalBytes == 17537 && list.freeBytes != nil && !list.snapshots[1].beforeRollback && list.snapshots[1].complete)
        #expect(SnapshotText.apps(list.snapshots[1]) == "Apps changed since: erpnext")
    }

    @Test func aSnapshotListWithOddEntriesStillReads() throws {
        let json = #"{"schema_version":1,"snapshots":[{"id":"20261120_100000","size_bytes":"x","apps":"none"},{"nope":1}],"keep":"ten"}"#
        let list = try BenchJSON.decode(SiteSnapshotList.self, from: Data(json.utf8))
        #expect(list.snapshots.map(\.id) == ["20261120_100000"], "an entry without an id is skipped, the rest reads")
        #expect(list.snapshots[0].sizeBytes == 0 && list.snapshots[0].apps.isEmpty && list.snapshots[0].appsMatch == nil && list.keep == 10)
        #expect(SnapshotText.apps(list.snapshots[0]) == nil)
    }

    @Test func aLabelTheCLIWouldRefuseIsCaughtInTheForm() {
        #expect(SnapshotText.labelProblem("Before the upgrade") == nil && SnapshotText.labelProblem("") == nil)
        #expect(SnapshotText.labelProblem("a\"b") != nil && SnapshotText.labelProblem("a\\b") != nil && SnapshotText.labelProblem("a\nb") != nil)
        #expect(SnapshotText.labelProblem(String(repeating: "x", count: 121)) == "At most 120 characters.")
    }

    @Test func takingASnapshotIsOneChangeWithAnOptionalLabel() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("site snapshot", json: try Fixture.string("snapshot-take"))
        base.cli.answer("site snapshots", json: try Fixture.string("snapshots"))
        let made = await workbench.takeSnapshot(of: "v16two", label: " Before upgrade ", on: bench)
        #expect(made?.id == "20261120_160102-before-upgrade")
        #expect(base.cli.calls.contains(["site", "snapshot", "v16two", "--label", "Before upgrade", "--json", "--bench-dir", v16]))
        #expect(workbench.result == .init(title: "Take a snapshot of v16two", error: nil, scope: v16))
        #expect(workbench.snapshots(of: "v16two", on: bench)?.snapshots.count == 2, "the list is read again")
        _ = await workbench.takeSnapshot(of: "v16two", label: "", on: bench)
        #expect(base.cli.calls.contains(["site", "snapshot", "v16two", "--json", "--bench-dir", v16]), "no label, no --label")
    }

    @Test func aRollbackPlanIsReadOnlyAndSaysWhatIsTakenFirst() async throws {
        let (workbench, bench, runner) = try await workbench()
        base.cli.answer("site rollback", json: try Fixture.string("snapshot-rollback-plan"))
        guard case .success(let plan) = await workbench.rollbackPlan(of: "v16two", to: "20261120_160102-before-upgrade", noMigrate: false, on: bench) else {
            Issue.record("no plan"); return
        }
        #expect(base.cli.calls.contains(["site", "rollback", "v16two", "--to", "20261120_160102-before-upgrade", "--dry-run", "--json", "--bench-dir", v16]))
        #expect(bench.activity == nil && workbench.result == nil, "reading a plan takes no change slot and leaves no banner")
        #expect(plan.rollback?.snapshotFirst == "before rollback" && plan.rollback?.appsMatch == false && plan.rollback?.changedApps == ["erpnext"])
        #expect(plan.rollback?.defaultSite == false && plan.canRun && plan.token.count == 64 && plan.migrate)
        #expect(plan.steps.first?.id == "snapshot")
        let facts = RollbackText.facts(plan)
        #expect(facts.map(\.label) == ["Replaced", "Taken first", "Apps", "Migrate", "Left alone"])
        #expect(facts[1].text.contains("before rollback") && facts[2].text.contains("erpnext"))
        let call = try #require(runner.calls.first { $0.arguments.contains("--dry-run") && $0.arguments.contains("rollback") })
        #expect(call.environment["BENCHBAR_NONINTERACTIVE"] == "0" && call.environment["BENCHBAR_APP_PID"] != nil, "the app's person, as the default site's plan needs")
    }

    @Test func theDefaultSitesPlanSaysSoAndAnOlderPlanHasNoRollbackKey() throws {
        let plan = try BenchJSON.decode(SiteRestorePlan.self, from: Fixture.data("snapshot-rollback-plan-default"))
        #expect(plan.rollback?.defaultSite == true && plan.canRun)
        #expect(SnapshotText.defaultSiteNote.contains("default site"))
        let restore = try BenchJSON.decode(SiteRestorePlan.self, from: Fixture.data("site-restore-plan"))
        #expect(restore.rollback == nil, "a restore plan has no rollback key")
    }

    @Test func theApplyCarriesTheTokenAndTheNoteNamesTheWayBack() async throws {
        let (workbench, bench, runner) = try await workbench()
        base.cli.answer("site rollback", json: try Fixture.string("snapshot-rollback"))
        base.cli.answer("site backups", json: try Fixture.string("site-backups"))
        base.cli.answer("site snapshots", json: try Fixture.string("snapshots"))
        let error = await workbench.rollBack("v16two", to: "20261120_160102-before-upgrade", noMigrate: true, token: "TOKEN", on: bench)
        #expect(error == nil)
        let apply = try #require(runner.calls.first { $0.arguments.contains("--apply") })
        #expect(apply.arguments == ["site", "rollback", "v16two", "--to", "20261120_160102-before-upgrade", "--no-migrate", "--apply", "TOKEN", "--yes", "--json", "--bench-dir", v16])
        #expect(apply.environment["BENCHBAR_NONINTERACTIVE"] == "0")
        #expect(workbench.result?.title == "Roll back v16two")
        #expect(workbench.result?.note?.contains("20260929_100003-before-rollback") == true, "the undo point is named")
    }

    @Test func aStaleRollbackTokenIsTheCLIsMessage() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("site rollback", .init(exitCode: 1, stdout: "", stderr: "[FAIL] The rollback plan changed since it was shown. Nothing was changed."))
        let error = await workbench.rollBack("v16two", to: "x", noMigrate: false, token: "old", on: bench)
        #expect(error.map(StalePlan.isStale) == true)
    }

    @Test func removingASnapshotAsksFirstInTheSheetAndRunsAsAPerson() async throws {
        let (workbench, bench, runner) = try await workbench()
        let snapshot = try BenchJSON.decode(SiteSnapshotList.self, from: Fixture.data("snapshots")).snapshots[1]
        base.cli.answer("site snapshot", .ok(""))
        base.cli.answer("site snapshots", json: try Fixture.string("snapshots"))
        let error = await workbench.dropSnapshot(snapshot, of: "v16two", on: bench)
        #expect(error == nil)
        let drop = try #require(runner.calls.first { $0.arguments.starts(with: ["site", "snapshot", "drop"]) })
        #expect(drop.arguments == ["site", "snapshot", "drop", "v16two", "20261120_160102-before-upgrade", "--yes", "--plain", "--bench-dir", v16])
        #expect(drop.environment["BENCHBAR_NONINTERACTIVE"] == "0", "removing is a person's decision in the CLI")
        #expect(!drop.arguments.contains("--force-undo-point"), "the undo point is never removed from the app")
    }

    @Test func theRollbackResultReadsTheWayBack() throws {
        let result = try BenchJSON.decode(RollbackResult.self, from: Fixture.data("snapshot-rollback"))
        #expect(result.beforeRollback == "20260929_100003-before-rollback" && result.undo?.contains("site rollback") == true && result.warnings.count == 2)
        #expect(try BenchJSON.decode(RollbackResult.self, from: Data(#"{"schema_version":1}"#.utf8)) == RollbackResult())
    }

    // MARK: history (P24)

    @Test func decodesTheHistoryAndSaysWhoStartedEachRun() throws {
        let history = try BenchJSON.decode(HistoryList.self, from: Fixture.data("history")).history
        #expect(history.count == 5 && history[0].command == "site snapshot drop" && history[0].exit == 0)
        #expect(history[1].argv.contains("***"), "the CLI already hid the token")
        #expect(HistoryText.who(history[0]) == "A script" && HistoryText.result(history[0]) == "Done")
        #expect(HistoryText.changes(history[1]) == "snapshot acme.localhost, site acme.localhost")
        let entries = try [#"{"op_id":"a","command":"restart","caller":"app","exit":1}"#, #"{"op_id":"b","caller":"mcp","mcp":{"tool":"benchbar_up","client":"claude 1.0"},"exit":0,"future":true}"#,
                           #"{"op_id":"c","caller":"robot","exit":0,"changed_more":3,"changed":[{"kind":"site","name":"x"}]}"#, #"{"no":"id"}"#]
            .map { try BenchJSON.decode(HistoryList.self, from: Data(#"{"schema_version":1,"history":[\#($0)]}"#.utf8)).history }
        #expect(HistoryText.who(entries[0][0]) == "BenchBar app" && HistoryText.result(entries[0][0]) == "Failed (exit 1)")
        #expect(HistoryText.who(entries[1][0]) == "An agent through MCP (claude 1.0)")
        #expect(HistoryText.who(entries[2][0]) == "robot" && HistoryText.changes(entries[2][0]) == "site x, 3 more", "a caller this build does not know is shown as it is")
        #expect(entries[3].isEmpty, "a line without an op id is skipped")
    }

    @Test func theHistoryIsReadOnlyAndAFailureIsKept() async throws {
        let (workbench, _, _) = try await workbench()
        base.cli.answer("history", json: try Fixture.string("history"))
        await workbench.loadHistory(limit: 50)
        #expect(base.cli.calls.contains(["history", "--json", "--limit", "50"]))
        #expect(workbench.history.count == 5 && workbench.historyError == nil && workbench.result == nil)
        base.cli.answer("history", .init(exitCode: 2, stdout: "", stderr: "[FAIL] Unknown command: history"))
        await workbench.loadHistory()
        #expect(workbench.historyError == "Unknown command: history", "an older CLI: the pane says so")
    }

    // MARK: leases (P25)

    @Test func decodesTheLeasesAndNeverNeedsTheId() throws {
        let leases = try BenchJSON.decode(LeaseList.self, from: Fixture.data("lease-list")).leases
        #expect(leases.count == 1 && leases[0].holder == "claude-qa" && leases[0].scope == "site" && leases[0].site == "acme.localhost")
        #expect(leases[0].id == nil && !leases[0].yours && leases[0].note == "running the QA suite")
        let end = try #require(leases[0].expiresAt)
        #expect(leases[0].isActive(at: end.addingTimeInterval(-60)) && !leases[0].isActive(at: end.addingTimeInterval(60)))
        #expect(LeaseText.line(leases[0], now: end).hasPrefix("Site acme.localhost is held by claude-qa until ") && LeaseText.line(leases[0], now: end).hasSuffix(": running the QA suite"))
        #expect(LeaseText.place(LeaseInfo(scope: "bench", bench: "/b", holder: "h")) == "The whole bench")
    }

    @Test func theLeasesOfABenchAreReadOnTheOverviewAndAnExpiredOneIsLeftOut() async throws {
        let (workbench, bench, _) = try await workbench()
        workbench.store.setWindow(WindowSight(isOpen: true, isVisible: true))
        base.cli.answer("lease", json: try Fixture.string("lease-list"))
        base.cli.answer("commands", json: Self.catalogWithLease)
        await workbench.loadCommands()
        let end = try #require(try BenchJSON.decode(LeaseList.self, from: Fixture.data("lease-list")).leases.first?.expiresAt)
        await workbench.showLeases(bench, now: end.addingTimeInterval(-600))
        #expect(base.cli.calls.contains(["lease", "list", "--bench", v16, "--json"]))
        #expect(workbench.leases[v16]?.map(\.holder) == ["claude-qa"], "who holds it, while it holds")
        await workbench.showLeases(bench, now: end.addingTimeInterval(60))
        #expect(workbench.leases[v16]?.isEmpty == true, "a lease that ended is not shown")
        base.cli.answer("lease", .init(exitCode: 2, stdout: "", stderr: "[FAIL] Unknown command: lease"))
        await workbench.showLeases(bench)
        #expect(workbench.leases[v16]?.isEmpty == true, "an older CLI has no leases to show")
    }

    static let catalogWithLease = #"{"schema_version":1,"commands":[{"name":"lease","flags":[]},{"name":"lock","flags":[]}]}"#
    static let catalogWithoutLease = #"{"schema_version":1,"commands":[{"name":"lock","flags":[]}]}"#

    @Test func anOlderCLIWithoutLeaseIsNeverAskedAndAFailureEndsThePoll() async throws {
        let (workbench, bench, _) = try await workbench()
        workbench.store.setWindow(WindowSight(isOpen: true, isVisible: true))
        base.cli.answer("lease", json: try Fixture.string("lease-list"))
        // no command list read yet: nothing is run
        await workbench.showLeases(bench)
        base.cli.answer("commands", json: Self.catalogWithoutLease)
        await workbench.pollLeases(bench)
        #expect(!base.cli.calls.contains { $0.first == "lease" }, "the catalog has no lease: no process is started")
        // a CLI that lists it but fails: one call, then the poll ends
        let fresh = Workbench(store: workbench.store)
        base.cli.answer("commands", json: Self.catalogWithLease)
        base.cli.answer("lease", .init(exitCode: 1, stdout: "", stderr: "[FAIL] broken"))
        await fresh.pollLeases(bench)
        #expect(base.cli.calls.filter { $0.first == "lease" }.count == 1 && fresh.leases[v16]?.isEmpty == true)
    }

    @Test func theDefaultSiteNoteAlsoShowsForAnOlderCLIThatSendsNoField() throws {
        var plan = try BenchJSON.decode(SiteRestorePlan.self, from: Fixture.data("snapshot-rollback-plan"))
        #expect(!SnapshotText.isDefaultSite(plan, benchDefault: "macdev"))
        #expect(SnapshotText.isDefaultSite(plan, benchDefault: plan.site))
        plan.rollback = nil
        #expect(SnapshotText.isDefaultSite(plan, benchDefault: plan.site) && !SnapshotText.isDefaultSite(plan, benchDefault: nil))
        let withField = try BenchJSON.decode(SiteRestorePlan.self, from: Fixture.data("snapshot-rollback-plan-default"))
        #expect(SnapshotText.isDefaultSite(withField, benchDefault: nil))
    }

    @Test func aFractionalLogTimeIsATimeNotAnUntimedLine() throws {
        let json = #"{"schema_version":1,"lines":["a","b","c"],"ts":["2026-11-21T04:30:01.250Z","2026-11-21T04:30:02Z",null]}"#
        let chunk = try BenchJSON.decode(LogChunk.self, from: Data(json.utf8))
        #expect(chunk.times[0] != nil && chunk.times[1] != nil && chunk.times[2] == nil)
        var cursor = LogCursor()
        #expect(cursor.take(chunk).count == 3 && cursor.take(chunk).isEmpty, "the same read again adds nothing")
    }

    @Test func readsWhoHoldsTheLeaseFromTheSentenceACommandEndsWith() throws {
        let refusal = try #require(LeaseRefusal.parse(CLIText.plain(leaseText)))
        #expect(refusal.holder == "claude-qa" && refusal.note == "running the QA suite" && refusal.untilText == "2027-01-15T08:20:00Z" && refusal.until != nil)
        #expect(refusal.sentence.hasPrefix("Held by claude-qa until ") && refusal.sentence.hasSuffix("(running the QA suite)."))
        let recorded = try Fixture.text("lease-refused", ext: "txt")
        #expect(LeaseRefusal.parse(CLIClient.summarize(.init(exitCode: 1, stdout: recorded, stderr: "")))?.holder == "claude-qa", "as the CLI prints it")
        #expect(LeaseRefusal.parse("The bench /b is leased by agent-7 until 2027-01-15T08:20:00Z. Nothing was changed.")?.note == nil)
        #expect(LeaseRefusal.parse("Another change is still running") == nil && LeaseRefusal.parse("x is leased by two words until now") == nil)
    }

    @Test func aChangeALeaseRefusedCanBeRunAgainOnlyByAPersonsBreakLease() async throws {
        let (workbench, bench, runner) = try await workbench()
        base.cli.answer("site default", .init(exitCode: 1, stdout: "", stderr: leaseText))
        let error = await workbench.setDefaultSite("v16two", on: bench)
        _ = error
        let result = try #require(workbench.result)
        #expect(!result.succeeded && result.lease?.holder == "claude-qa" && workbench.leaseRetry != nil)
        #expect(runner.calls.allSatisfy { !$0.arguments.contains("--break-lease") && $0.environment["BENCHBAR_NONINTERACTIVE"] != "0" }, "nothing breaks a lease on its own")
        base.cli.answer("site default", .ok(""))
        await workbench.breakLease()
        let again = try #require(runner.calls.last { $0.arguments.starts(with: ["site", "default"]) })
        #expect(again.arguments == ["site", "default", "v16two", "--plain", "--bench-dir", v16, "--break-lease"])
        #expect(again.environment["BENCHBAR_NONINTERACTIVE"] == "0" && again.environment["BENCHBAR_APP_PID"] != nil, "a person's run")
        #expect(workbench.result?.succeeded == true && workbench.leaseRetry == nil)
    }

    @Test func aFailureThatIsNoLeaseOffersNothingToBreak() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("site default", .init(exitCode: 1, stdout: "", stderr: "[FAIL] No site 'x'"))
        await workbench.setDefaultSite("x", on: bench)
        #expect(workbench.result?.lease == nil && workbench.leaseRetry == nil)
        await workbench.breakLease()
        #expect(!base.cli.calls.contains { $0.contains("--break-lease") })
    }

    @Test func breakLeaseGoesBeforeTheDoubleDashThatEndsTheOptions() {
        #expect(CLIClient.withBreakLease(["service", "--yes"]) == ["service", "--yes", "--break-lease"])
        #expect(CLIClient.withBreakLease(["ports", "apply", "T", "--", "/a"]) == ["ports", "apply", "T", "--break-lease", "--", "/a"])
    }

    @Test func aRefusedRestartRemembersTheActionForTheBreakLeaseButton() async throws {
        let (workbench, bench, runner) = try await workbench()
        base.cli.answer("restart", .init(exitCode: 1, stdout: "", stderr: leaseText))
        base.cli.answer("ports", json: #"{"schema_version":1,"conflicts":[],"mode":"automatic"}"#)
        await workbench.store.perform(.restart, on: bench)
        #expect(bench.leaseRefusedAction == .restart && LeaseRefusal.parse(bench.lastError ?? "")?.holder == "claude-qa")
        base.cli.answer("restart", .ok(""))
        await workbench.store.perform(.restart, on: bench, breakLease: true)
        let again = try #require(runner.calls.last { $0.arguments.first == "restart" })
        #expect(again.arguments.contains("--break-lease") && again.environment["BENCHBAR_NONINTERACTIVE"] == "0")
        #expect(bench.leaseRefusedAction == nil)
    }

    // MARK: logs (P29)

    @Test func theLogReadsAskForTheLinesSinceARestartOrSinceTheCursor() {
        #expect(LogRequest().arguments == ["logs", "--json", "--no-follow", "-n", "2000"])
        #expect(LogRequest(process: "web", sinceRestart: true).arguments == ["logs", "--json", "--no-follow", "-n", "2000", "--process", "web", "--since-restart"])
        let cursor = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LogRequest(sinceRestart: true, since: cursor).arguments.suffix(2) == ["--since", "2027-01-15T08:00:00Z"], "the cursor wins over the start once the first read is done")
        #expect(LogRequest(process: "worker", previous: true).arguments.contains("--previous") == false, "there is no previous worker log")
        #expect(LogRequest(previous: true).arguments.contains("--previous"))
    }

    @Test func decodesALogReadWithItsTimes() throws {
        let chunk = try BenchJSON.decode(LogChunk.self, from: Fixture.data("logs-first"))
        #expect(chunk.lines.count == 3 && chunk.times.count == 3 && chunk.times.allSatisfy { $0 != nil })
        let since = try BenchJSON.decode(LogChunk.self, from: Fixture.data("logs-since"))
        #expect(since.lines == ["10:00:05 web.1    | GET /"] && since.since != nil)
        let older = try BenchJSON.decode(LogChunk.self, from: Data(#"{"schema_version":1,"lines":["a","b"]}"#.utf8))
        #expect(older.lines == ["a", "b"] && older.times == [nil, nil], "an older CLI sends no times")
    }

    @Test func theCursorTakesOnlyWhatIsNew() throws {
        let t = { (s: Double) in Date(timeIntervalSince1970: 1_800_000_000 + s) }
        var cursor = LogCursor()
        let first = LogChunk(lines: ["a", "b", "  trace", "c"], times: [t(0), t(1), nil, t(1)])
        #expect(cursor.take(first) == ["a", "b", "  trace", "c"] && cursor.time == t(1))
        // the CLI keeps the lines at or after the cursor: the newest second comes again
        let second = LogChunk(lines: ["b", "  trace", "c", "d", "  more", "c"], times: [t(1), nil, t(1), t(2), nil, t(2)])
        #expect(cursor.take(second) == ["d", "  more", "c"], "the untimed line under a line it skipped is skipped with it; a repeat in a newer second is new")
        #expect(cursor.take(LogChunk(lines: ["d", "  more", "c"], times: [t(2), nil, t(2)])).isEmpty)
        #expect(cursor.take(LogChunk(lines: ["d", "d2"], times: [t(2), t(2)])) == ["d2"])
        var untimed = LogCursor()
        #expect(untimed.take(LogChunk(lines: ["x", "y"])) == ["x", "y"] && untimed.take(LogChunk(lines: ["x", "y", "z"])) == ["z"])
    }

    @Test func theLogWindowReadsSinceTheRestartThenOnlyNewLines() async throws {
        let model = LogViewModel(benchName: "b", benchPath: "/b")
        let requests = Locked<[LogRequest]>([])
        let t = { (s: Double) in Date(timeIntervalSince1970: 1_800_000_000 + s) }
        model.pollInterval = .milliseconds(5)
        model.fetch = { request in
            requests.mutate { $0.append(request) }
            return request.since == nil ? LogChunk(lines: ["l1", "l2"], times: [t(0), t(1)]) : LogChunk(lines: ["l2", "l3"], times: [t(1), t(2)])
        }
        model.sinceRestart = true
        #expect(model.usesCLI)
        for _ in 0..<200 where model.buffer.lines.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        model.stop()
        #expect(model.buffer.lines.map(\.text) == ["l1", "l2", "l3"], "the second read's repeat of l2 is not shown again")
        let seen = requests.value
        #expect(seen.first?.sinceRestart == true && seen.first?.since == nil)
        #expect(seen.dropFirst().first?.since == t(1) && seen.dropFirst().first?.sinceRestart == false)
    }

    @Test func theWorkerLogComesFromTheCLIWithoutTheProcessFilterOnTop() async throws {
        let model = LogViewModel(benchName: "b", benchPath: "/b")
        model.pollInterval = .milliseconds(5)
        model.fetch = { _ in LogChunk(lines: ["2026-11-21 10:00:00 worker started"], times: [Date(timeIntervalSince1970: 1_800_000_000)]) }
        model.query.process = "worker"
        #expect(model.usesCLI)
        for _ in 0..<200 where model.buffer.lines.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        model.stop()
        #expect(model.visible.map(\.text) == ["2026-11-21 10:00:00 worker started"], "the lines have no honcho prefix: the CLI chose the file")
    }

    @Test func aFailedCLIReadIsASentenceAboveTheLogNotAnEmptyWindow() async throws {
        let model = LogViewModel(benchName: "b", benchPath: "/b")
        model.pollInterval = .seconds(30)
        model.fetch = { _ in throw CLIError.failed(command: "logs", exitCode: 1, message: "This bench has no recorded start") }
        model.sinceRestart = true
        for _ in 0..<200 where model.note == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.stop()
        #expect(model.note?.contains("no recorded start") == true)
    }

    // MARK: the team lockfile (P23)

    @Test func theLockPlanIsTheCLIsTextWithoutTheHeaderBox() throws {
        let write = LockPlan.parse(.ok(try Fixture.text("lock-write-plan", ext: "txt")))
        #expect(write.lines.first == "New file /Users/you/frappe-bench/benchbar.toml" && write.text.contains("name = \"acme_crm\"") && write.token == nil && !write.unchanged)
        #expect(!write.text.contains("+--") && !write.text.contains("| mode") && write.canRun)
        let apply = LockPlan.parse(CommandOutput(exitCode: 0, stdout: try Fixture.lines("lock-apply-plan"), stderr: try Fixture.text("lock-apply-plan-stderr", ext: "txt")))
        #expect(apply.lines.first == "Plan" && apply.text.contains("NEW REPO, not in this bench") && apply.text.contains("apply will run code from these repos") && apply.canRun)
        #expect(!apply.text.contains("\"event\"") && apply.token == nil, "this CLI gives no token for the lock file yet")
        let unchanged = LockPlan.parse(.ok(try Fixture.text("lock-apply-unchanged", ext: "txt")))
        #expect(unchanged.unchanged && !unchanged.canRun)
    }

    @Test func aPlanEventWithATokenIsUsedWhenTheCLIGivesOne() {
        let stdout = #"{"schema_version":1,"event":"plan","command":"lock apply","token":"ABC","dry_run":true}"# + "\n" + #"{"schema_version":1,"event":"done","exit":0}"#
        let plan = LockPlan.parse(CommandOutput(exitCode: 0, stdout: stdout, stderr: "Plan\n  1  acme  fast forward\n"))
        #expect(plan.token == "ABC" && plan.lines == ["Plan", "  1  acme  fast forward"])
    }

    @Test func writingAndApplyingTheLockFileAreOneConfirmedChangeEach() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("lock", .ok(try Fixture.text("lock-write-plan", ext: "txt")))
        guard case .success(let plan) = await workbench.lockWritePlan(on: bench) else { Issue.record("no plan"); return }
        #expect(base.cli.calls.contains(["lock", "write", "--dry-run", "--plain", "--bench-dir", v16]) && plan.canRun)
        #expect(bench.activity == nil && workbench.result == nil, "reading the plan changes nothing")
        #expect(await workbench.writeLock(on: bench) == nil)
        #expect(base.cli.calls.contains(["lock", "write", "--yes", "--plain", "--bench-dir", v16]) && workbench.result?.title == "Write the lockfile of v16-bench")
        base.cli.answer("app", json: try Fixture.string("app-list"))
        #expect(await workbench.applyLock(token: nil, on: bench) == nil)
        #expect(base.cli.calls.contains(["lock", "apply", "--yes", "--plain", "--bench-dir", v16]), "no token on this CLI: --yes after the person's OK")
        #expect(await workbench.applyLock(token: "TOK", on: bench) == nil)
        #expect(base.cli.calls.contains(["lock", "apply", "--apply", "TOK", "--yes", "--plain", "--bench-dir", v16]))
    }

    // MARK: services only and autostart (the part 2 leftovers)

    @Test func servicesOnlyIsOfferedForABenchWithoutAServiceUnlessItRuns() {
        #expect(ServicesOnly.notRunning(needsService: true, state: .unknown, processesRunning: false))
        #expect(ServicesOnly.notRunning(needsService: true, state: .unknown, processesRunning: nil))
        #expect(!ServicesOnly.notRunning(needsService: true, state: .unknown, processesRunning: true))
        #expect(ServicesOnly.notRunning(needsService: false, state: .stopped, processesRunning: false))
        #expect(!ServicesOnly.notRunning(needsService: false, state: .running, processesRunning: true))
        #expect(!ServicesOnly.notRunning(needsService: false, state: .crashed, processesRunning: false), "a crashed bench restarts itself: not offered")
    }

    @Test func autostartIsReadFromTheStatusAndTheTextIsOnlyTheFallback() async throws {
        let status = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-noservice"))
        #expect(status.autostart == true && status.state == .unknown, "an unmanaged bench: the CLI's not_adopted is no state of ours")
        #expect(try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-running")).autostart == nil)
        let off = Data(try Fixture.string("status-noservice").replacingOccurrences(of: "\"autostart\":true", with: "\"autostart\":false").utf8)
        #expect(try BenchJSON.decode(BenchStatus.self, from: off).autostart == false)
        let (workbench, bench, _) = try await workbench()
        workbench.store.setWindow(WindowSight(isOpen: true, isVisible: true))
        base.cli.answer("commands", json: try Fixture.string("commands"))
        base.cli.answer("autostart", .ok(try Fixture.text("autostart-off", ext: "txt")))
        await workbench.loadCommands()
        await workbench.showAutostart(bench)
        #expect(workbench.autostartSetting(for: bench) == false, "this status has no field: the words are read")
        // a change reads the status again; this one says autostart is on, while the change itself wrote "off"
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites").replacingOccurrences(of: "\"scheduler\":", with: "\"autostart\":true,\"scheduler\":"))
        base.cli.answer("autostart", .ok("  [OK] autostart off\n"))
        await workbench.setAutostart(false, on: bench)
        #expect(bench.status?.autostart == true && workbench.autostartSetting(for: bench) == true, "the status wins over what was read before")
        let before = base.cli.calls.filter { $0.first == "autostart" }.count
        await workbench.showAutostart(bench)
        #expect(base.cli.calls.filter { $0.first == "autostart" }.count == before, "no command is run when the status says it")
    }
}

/// A value two tasks touch: a lock around it.
nonisolated final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
