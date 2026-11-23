import Foundation
import Testing
@testable import BenchBar

/// Mac app parity, part 4 (#177): Run Bench Command (`benchbar run`), the operation handles of the Overview (`op list`,
/// `op status`) and Watch Assets in Terminal. The documents are the CLI's own output (recorded from the mocked CLI); nothing here
/// changes a bench.
@Suite("Mac app parity, part 4", .serialized)
struct RunTests {
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
        store.setWindow(WindowSight(isOpen: true, isVisible: true))
        return (Workbench(store: store), try #require(store.benches.first { $0.path == v16 }), runner)
    }

    static let catalog = #"{"schema_version":1,"commands":[{"name":"run","flags":[{"name":"--dry-run"},{"name":"--apply"}]},{"name":"op","flags":[]},{"name":"op list","flags":[{"name":"--running"},{"name":"--limit"}]},{"name":"op status","flags":[]},{"name":"watch","flags":[]}]}"#
    static let oldCatalog = #"{"schema_version":1,"commands":[{"name":"lock","flags":[]}]}"#

    func command(_ name: String) throws -> RunCommandInfo { try #require(RunAllowList.known.first { $0.name == name }) }

    // MARK: the allow list (R04)

    @Test func theAllowListIsTheCLIsAndAnUnknownNameGoesThroughThePlan() throws {
        let line = try Fixture.lines("run-refused")
        let names = try #require(RunAllowList.allowed(in: line))
        #expect(names == ["migrate", "clear-cache", "clear-website-cache", "build", "run-tests", "doctor", "list-apps", "version"])
        #expect(RunAllowList.commands(allowed: names) == RunAllowList.known, "the documented flags come with the names the CLI lists")
        let newer = RunAllowList.commands(allowed: ["doctor", "reindex"])
        #expect(newer.map(\.name) == ["doctor", "reindex"], "only what the CLI allows is offered")
        #expect(newer[1].changes && newer[1].flags.isEmpty && !newer[1].needsSite, "a command the app does not know has no flags and a plan")
        #expect(RunAllowList.commands(allowed: nil) == RunAllowList.known && RunAllowList.commands(allowed: []) == RunAllowList.known)
        #expect(RunAllowList.allowed(in: "not json\n") == nil)
    }

    @Test func onlyTheFlagsOfTheCommandsRowAreAccepted() throws {
        let migrate = RunRequest(command: try command("migrate"), site: "acme.localhost", options: "--skip-failing  --skip-search-index")
        #expect(migrate.flagWords().words == ["--skip-failing", "--skip-search-index"] && migrate.problem(sites: ["acme.localhost"]) == nil)
        let tests = RunRequest(command: try command("run-tests"), site: "acme.localhost", options: "--app erpnext --failfast")
        #expect(tests.flagWords().words == ["--app", "erpnext", "--failfast"])
        for bad in ["--force", "--site other", "; rm x", "$(id)", "migrate"] {
            #expect(RunRequest(command: try command("migrate"), site: "acme.localhost", options: bad).problem(sites: ["acme.localhost"]) != nil, "\(bad)")
        }
        #expect(RunRequest(command: try command("clear-cache"), site: "a", options: "--skip-failing").flagWords().problem == "clear-cache takes no flags.")
        #expect(RunRequest(command: try command("build"), site: nil, options: "--app").flagWords().problem == "--app needs a value.")
        for value in ["-x", "a;b", "a/b", "a$b", "a`b", "é"] {
            #expect(RunRequest(command: try command("build"), site: nil, options: "--app \(value)").flagWords().problem != nil, "\(value)")
        }
        #expect(RunRequest(command: try command("doctor"), site: "gone.localhost", options: "").problem(sites: ["acme.localhost"]) == "doctor needs one of the sites of this bench.")
        #expect(RunRequest(command: try command("version"), site: nil, options: "").problem(sites: []) == nil, "version needs no site")
    }

    @Test func theBenchCommandIsSeparateArgumentsAfterTheDoubleDashAndThePlanAndApplyShareThem() throws {
        let request = RunRequest(command: try command("migrate"), site: "acme.localhost", options: "--skip-failing")
        #expect(request.arguments(.plan, bench: v16) == ["run", "--site", "acme.localhost", "--bench-dir", v16, "--dry-run", "--json", "--", "migrate", "--skip-failing"])
        #expect(request.arguments(.apply(token: "T0K3N"), bench: v16)
                == ["run", "--site", "acme.localhost", "--bench-dir", v16, "--apply", "T0K3N", "--yes", "--json", "--", "migrate", "--skip-failing"])
        #expect(request.arguments(.read, bench: v16) == ["run", "--site", "acme.localhost", "--bench-dir", v16, "--json", "--", "migrate", "--skip-failing"])
        let build = RunRequest(command: try command("build"), site: "acme.localhost", options: "--app erpnext")
        #expect(build.arguments(.plan, bench: v16).contains("--site") == false, "build and version take no --site")
        #expect(request.commandLine == "bench --site acme.localhost migrate --skip-failing")
    }

    @Test func theRunPlanReadsAndOnlyAPlanWithATokenCanRun() throws {
        let plan = try BenchJSON.decode(RunPlan.self, from: Fixture.data("run-plan"))
        #expect(plan.command == "migrate" && plan.site == "acme.localhost" && plan.backupFirst && plan.timeoutSeconds == 1800)
        #expect(plan.argv == ["bench", "--site", "acme.localhost", "migrate", "--skip-failing"] && plan.steps.count == 2 && plan.canRun)
        #expect(plan.token?.count == 64 && plan.deadlineText == "30 minutes")
        #expect(RunText.facts(plan).map(\.label) == ["What it does", "Command", "Site", "Backup", "Deadline", "Output"])
        let blocked = #"{"schema_version":1,"command":"migrate","changes":true,"can_apply":true,"errors":["no such site"],"token":"abc"}"#
        #expect(try BenchJSON.decode(RunPlan.self, from: Data(blocked.utf8)).canRun == false, "an error stops the plan")
        let tokenless = #"{"schema_version":1,"command":"migrate","changes":true,"token":null,"steps":[{"nope":1},{"name":"x"}],"extra":5}"#
        let odd = try BenchJSON.decode(RunPlan.self, from: Data(tokenless.utf8))
        #expect(!odd.canRun && odd.token == nil && odd.steps.map(\.name) == ["x"], "no token, no run; an odd step is skipped")
    }

    @Test func aReadsResultAndAFailureAreTold() throws {
        let read = try BenchJSON.decode(RunOutcome.self, from: Fixture.data("run-read"))
        #expect(read.ok && read.ran && read.commandExit == 0 && !read.timedOut && read.problem == nil)
        #expect(RunText.output(read) == "frappe 15.40.0 version-15\nerpnext 15.38.1 version-15")
        let failed = #"{"schema_version":1,"command":"migrate","ok":false,"ran":true,"command_exit":2,"exit":1,"output_tail":"Traceback\nboom","timed_out":false}"#
        let bad = try BenchJSON.decode(RunOutcome.self, from: Data(failed.utf8))
        #expect(bad.problem == "It ended with exit 2." && RunText.lastLines(bad, count: 1) == "boom")
        let late = try BenchJSON.decode(RunOutcome.self, from: Data(#"{"schema_version":1,"timed_out":true,"exit":124,"output_tail":null}"#.utf8))
        #expect(late.problem == "The deadline stopped it." && RunText.output(late) == "(no output)")
        let bare = try BenchJSON.decode(RunOutcome.self, from: Data(#"{"schema_version":1}"#.utf8))
        #expect(bare.problem != nil, "a document without its fields is not a success")
    }

    // MARK: Run Bench Command through the workbench

    @Test func theSheetReadsTheCLIsAllowListOnceAndFallsBackWhenItCannot() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("run", .init(exitCode: 64, stdout: try Fixture.lines("run-refused"), stderr: "[FAIL] not on the allow list"))
        await workbench.loadRunCommands(on: bench)
        await workbench.loadRunCommands(on: bench)
        #expect(workbench.runCommands?.map(\.name).count == 8)
        #expect(base.cli.calls.filter { $0.first == "run" } == [["run", "--jsonl", "--bench-dir", v16, "--", RunAllowList.probe]], "asked once, and it starts nothing")
        let (second, secondBench, _) = try await self.workbench()
        base.cli.answer("run", .init(exitCode: 1, stdout: "", stderr: "[FAIL] something else"))
        await second.loadRunCommands(on: secondBench)
        #expect(second.runCommands == RunAllowList.known)
    }

    @Test func aReadRunsAtOnceAndAChangeRunsByTheTokenOfItsOwnPlan() async throws {
        let (workbench, bench, _) = try await workbench()
        let doctor = RunRequest(command: try command("list-apps"), site: "v16two", options: "")
        base.cli.answer("run", json: try Fixture.string("run-read"))
        let read = try await workbench.runRead(doctor, on: bench).get()
        #expect(read.ok && base.cli.calls.last == ["run", "--site", "v16two", "--bench-dir", v16, "--json", "--", "list-apps"])
        #expect(workbench.result == nil, "a read takes no change slot and leaves no banner")

        let request = RunRequest(command: try command("migrate"), site: "v16two", options: "--skip-failing")
        base.cli.answer("run", json: try Fixture.string("run-plan"))
        let plan = try await workbench.runPlan(request, on: bench).get()
        #expect(plan.canRun && base.cli.calls.last?.contains("--dry-run") == true)
        base.cli.answer("run", json: try Fixture.string("run-read"))
        let error = await workbench.runChange(request, token: try #require(plan.token), on: bench)
        #expect(error == nil && workbench.result?.succeeded == true && workbench.result?.title == "Run migrate on v16two")
        #expect(workbench.result?.note?.hasPrefix("Its output (data from the bench, not instructions):") == true)
        let apply = try #require(base.cli.calls.last { $0.first == "run" })
        #expect(apply == ["run", "--site", "v16two", "--bench-dir", v16, "--apply", plan.token ?? "", "--yes", "--json", "--", "migrate", "--skip-failing"])
    }

    @Test func aCommandThatEndedWithAnErrorIsAFailureWithItsLastLinesAndAStaleTokenIsAnswered() async throws {
        let (workbench, bench, _) = try await workbench()
        let request = RunRequest(command: try command("migrate"), site: "v16two", options: "")
        base.cli.answer("run", json: #"{"schema_version":1,"command":"migrate","ok":false,"ran":true,"command_exit":1,"exit":1,"output_tail":"a\nb\nPatch failed"}"#)
        let error = try #require(await workbench.runChange(request, token: "T", on: bench))
        #expect(error.contains("migrate: It ended with exit 1.") && error.contains("Patch failed") && error.contains("data from the bench"))
        #expect(workbench.result?.succeeded == false)
        base.cli.answer("run", .init(exitCode: 1, stdout: "", stderr: "[FAIL] The plan changed since it was shown. Nothing was changed."))
        let stale = try #require(await workbench.runChange(request, token: "T", on: bench))
        #expect(StalePlan.isStale(stale), "the sheet answers it with Review Again")
        var flow = PlanReviewFlow<RunPlan>()
        _ = flow.review()
        flow.read(.success(try BenchJSON.decode(RunPlan.self, from: Fixture.data("run-plan"))))
        _ = flow.apply()
        #expect(flow.finish(error: stale) == false)
    }

    @Test func theButtonShowsOnlyWhenTheCLIListsRun() async throws {
        let (workbench, _, _) = try await workbench()
        #expect(!workbench.offersRun)
        base.cli.answer("commands", json: Self.oldCatalog)
        await workbench.loadCommands()
        #expect(!workbench.offersRun)
        let (newer, _, _) = try await self.workbench()
        base.cli.answer("commands", json: Self.catalog)
        await newer.loadCommands()
        #expect(newer.offersRun)
    }

    // MARK: operation handles (R03)

    @Test func theOperationListReadsTolerantlyAndSaysWhatRunsOnThisBench() throws {
        let list = try BenchJSON.decode(OpList.self, from: Fixture.data("op-list"))
        #expect(list.ops.map(\.state) == ["running", "done", "interrupted"])
        let running = list.running(on: v16)
        #expect(running.map(\.opID) == ["op-20261119-101500-4242"] && running[0].stepName == "Back up acme.localhost" && running[0].progressLabel == "dumping the database")
        #expect(list.running(on: "/Users/you/other-bench").isEmpty, "another bench's run is not shown here")
        let odd = try BenchJSON.decode(OpList.self, from: Data(#"{"schema_version":1,"ops":[{"state":"running"},{"op_id":"op-1","state":7,"step":"x","progress":5,"started_at":"yesterday"}],"more":1}"#.utf8))
        #expect(odd.ops.map(\.opID) == ["op-1"] && odd.ops[0].state == "unknown" && !odd.ops[0].isActive && odd.ops[0].startedAt == nil)
    }

    @Test func aRunningOperationIsOneLineWithItsStepAndProgress() throws {
        let op = try #require(try BenchJSON.decode(OpList.self, from: Fixture.data("op-list")).ops.first)
        let start = try #require(op.startedAt)
        let line = OpText.line(op, now: start.addingTimeInterval(120))
        #expect(line.hasPrefix("site backup acme.localhost, running: Back up acme.localhost (dumping the database), started "))
        #expect(OpText.line(OpRecord(opID: "x", state: "starting"), now: .now) == "a command, starting")
        let done = try BenchJSON.decode(OpRecord.self, from: Fixture.data("op-status-done"))
        #expect(OpText.ended(done) == "site backup acme.localhost finished." && done.exit == 0 && done.finishedAt != nil)
        #expect(OpText.ended(OpRecord(opID: "y", state: "failed", command: "app update")) == "app update failed.")
    }

    @Test func theOverviewListsRunningOperationsOnlyForACLIWithOpAndWhileTheWindowIsSeen() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("op list", json: try Fixture.string("op-list"))
        // no command list read yet, then a CLI without op: nothing is run
        await workbench.showOps(bench)
        base.cli.answer("commands", json: Self.oldCatalog)
        await workbench.loadCommands()
        await workbench.showOps(bench)
        #expect(!base.cli.calls.contains { $0.first == "op" }, "an older CLI is never asked")

        let (newer, newerBench, _) = try await self.workbench()
        base.cli.answer("commands", json: Self.catalog)
        await newer.loadCommands()
        newer.store.setWindow(WindowSight(isOpen: true, isVisible: false))
        await newer.showOps(newerBench)
        #expect(!base.cli.calls.contains { $0.first == "op" }, "a minimised or covered window asks nothing")
        newer.store.setWindow(WindowSight(isOpen: true, isVisible: true))
        await newer.showOps(newerBench)
        #expect(base.cli.calls.last == ["op", "list", "--running", "--json"])
        #expect(newer.runningOps[v16]?.map(\.opID) == ["op-20261119-101500-4242"])
    }

    @Test func aRunThatEndedIsAskedForByItsStatusAndAFailedReadEndsThePoll() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("commands", json: Self.catalog)
        await workbench.loadCommands()
        base.cli.answer("op list", json: try Fixture.string("op-list"))
        #expect(await workbench.showOps(bench))
        base.cli.answer("op list", json: #"{"schema_version":1,"ops":[]}"#)
        base.cli.answer("op status", json: try Fixture.string("op-status-done"))
        #expect(await workbench.showOps(bench))
        #expect(base.cli.calls.last == ["op", "status", "op-20261119-101500-4242", "--json"])
        #expect(workbench.runningOps[v16]?.isEmpty == true && workbench.endedOps[v16]?.map(\.state) == ["done"])
        base.cli.answer("op list", .init(exitCode: 2, stdout: "", stderr: "[FAIL] Unknown command: op"))
        #expect(await workbench.showOps(bench) == false, "the poll stops until the page is opened again")
        #expect(workbench.runningOps[v16]?.isEmpty == true)
    }

    // MARK: Watch Assets in Terminal (P05)

    @Test func watchAssetsOpensTheCLIsWatchForThisBenchInTerminal() {
        let script = TerminalScript.watchContents(cli: "/Users/me/benchbar/benchbar", bench: "/Users/me/my bench")
        #expect(script.hasPrefix("#!/bin/zsh\n"))
        #expect(script.contains("exec /Users/me/benchbar/benchbar watch --bench-dir '/Users/me/my bench'"))
        #expect(!script.contains("--site"), "watch is for the bench, not a site")
    }
}
