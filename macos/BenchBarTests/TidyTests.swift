import Foundation
import Testing
@testable import BenchBar

/// The end of a bench's life in the Mac app (#183): scratch benches and `bench gc`, `bench forget`, `bench remove`, `db orphans`,
/// `site hosts --prune` and `uninstall-service`, plus the three follow-ups of the Run Bench Command review. The documents are the
/// CLI's own (the tray's recorded fixtures); nothing here changes a bench, a database or /etc/hosts.
@Suite("Mac app tidy up (#183)", .serialized)
struct TidyTests {
    let base: BenchStoreTests
    let v16 = "/Users/you/dev/v16-bench"

    init() throws { base = try BenchStoreTests() }

    static let catalog = #"{"schema_version":1,"commands":[{"name":"bench scratch","flags":[]},{"name":"bench gc","flags":[]},{"name":"bench forget","flags":[]},{"name":"bench remove","flags":[]},{"name":"db orphans","flags":[]},{"name":"site hosts","flags":[{"name":"--prune"}]},{"name":"uninstall-service","flags":[]},{"name":"op","flags":[]}]}"#
    static let oldCatalog = #"{"schema_version":1,"commands":[{"name":"lock","flags":[]}]}"#

    func workbench(catalog: String? = nil) async throws -> (Workbench, BenchModel, FakeRunner) {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites"))
        let runner = base.cli.runner()
        let store = BenchStore(settings: base.settings,
                               locator: CLILocator(home: base.dir.url, isExecutable: { $0 == "/fake/benchbar" }),
                               makeClient: { CLIClient(executable: $0, runner: runner) },
                               pinger: { _, _ in 200 })
        await store.start(polling: false)
        store.setWindow(WindowSight(isOpen: true, isVisible: true))
        let workbench = Workbench(store: store)
        if let catalog {
            base.cli.answer("commands", json: catalog)
            await workbench.loadCommands()
        }
        return (workbench, try #require(store.benches.first { $0.path == v16 }), runner)
    }

    // MARK: the documents

    @Test func theGcPlanListsWhatExpiredWhatWaitsAndWhatIsKept() throws {
        let plan = try BenchJSON.decode(GcPlan.self, from: Fixture.data("bench-gc-plan"))
        #expect(plan.expired.map(\.name) == ["scratch-qa"] && plan.pending.map(\.name) == ["scratch-next"] && plan.skipped.map(\.name) == ["frappe-bench"])
        #expect(plan.expired.first?.sites == 2 && plan.expired.first?.markedBy == "person" && plan.expired.first?.until != nil)
        #expect(plan.skipped.first?.markedBy == "unknown" && plan.skipped.first?.markedAt == nil && plan.skipped.first?.why == "it is the default bench")
        let tidy = TidyPlan.gc(plan)
        #expect(tidy.canRun && tidy.token?.count == 64 && tidy.rows == ["scratch-qa: 2 sites, marked scratch by person"])
        let now = try #require(TidyText.time("2026-11-23T10:00:00Z"))
        #expect(TidyText.line(plan.expired[0], expired: true, kept: false, now: now).hasPrefix("scratch-qa: 2 sites, expired "))
        #expect(TidyText.line(plan.pending[0], expired: false, kept: false, now: now) == "scratch-next: expires 2026-11-30")
        #expect(TidyText.line(plan.skipped[0], expired: false, kept: true, now: now) == "frappe-bench: kept, it is the default bench")
    }

    @Test func aGcPlanWithNothingExpiredOrNoTokenIsNeverApplied() throws {
        let empty = TidyPlan.gc(try BenchJSON.decode(GcPlan.self, from: Fixture.data("bench-gc-plan-empty")))
        #expect(empty.rows.isEmpty && !empty.canRun)
        var noToken = TidyPlan.gc(try BenchJSON.decode(GcPlan.self, from: Fixture.data("bench-gc-plan")))
        noToken.token = nil
        #expect(!noToken.canRun, "no --apply with an empty token")
        #expect(throws: (any Error).self) { try BenchJSON.decode(GcPlan.self, from: Data(#"{"schema_version":1,"pending":[]}"#.utf8)) }
        let odd = try BenchJSON.decode(GcPlan.self, from: Data(#"{"schema_version":1,"expired":[{"bench":"/a/b","sites":"x","future":1},{"sites":1}],"token":""}"#.utf8))
        #expect(odd.expired.map(\.bench) == ["/a/b"] && odd.expired[0].sites == 0 && odd.token == nil, "a bad row is skipped, a field of another type is absent")
    }

    @Test func theRemovePlanListsItsStepsAndTheDefaultBenchIsRefusedByTheCLIsOwnError() throws {
        let plan = try TidyPlan.decode(.remove, bench: "/home/akash/scratch-qa", from: Fixture.data("bench-remove-plan"))
        #expect(plan.canRun && plan.rows.count == 5 && plan.rows[0].hasPrefix("Back up qa.localhost"))
        #expect(plan.trashIn == "/home/akash/.benchbar-trash" && plan.keeps.first == "the hosts lines")
        let refused = try TidyPlan.decode(.remove, bench: "/home/akash/frappe-bench", from: Fixture.data("bench-remove-default"))
        #expect(!refused.canRun && refused.errors.first?.contains("is the default bench") == true, "the plan has a token and still never runs")
        let forget = try TidyPlan.decode(.forget, bench: "/home/akash/scratch-qa", from: Fixture.data("bench-forget-plan"))
        #expect(forget.canRun && forget.rows.count == 2 && forget.trashIn == nil && forget.keeps.count == 3)
    }

    @Test func orphanDatabasesAreAListThatNamesTheArchivedSite() throws {
        let list = try BenchJSON.decode(OrphanList.self, from: Fixture.data("db-orphans"))
        #expect(list.checked == 3 && list.orphans.count == 2 && list.note.contains("does not drop them"))
        #expect(TidyText.orphan(list.orphans[0]) == "_7f3a9c1e5b2d4a60, named by the archived site old.localhost")
        #expect(TidyText.orphan(list.orphans[1]) == "_c2d4e6f8a0b1c3d5")
        #expect(TidyText.orphanSummary(list) == "2 databases of 3 have no site in any bench benchbar knows.")
        #expect(TidyText.orphanSummary(OrphanList.empty) == "No orphan database among 0 of frappe's shape.")
    }

    @Test func theStaleHostsLinesAreReadFromTheDryRunAndTheServicePlanFromItsText() throws {
        #expect(HostsPrune.names(in: try Fixture.text("site-hosts-prune-dry-run", ext: "txt")) == ["gone.localhost", "two.localhost"])
        #expect(HostsPrune.names(in: "  .. unchanged: every line belongs to a site\n").isEmpty)
        let plan = TidyPlan.service(bench: v16, from: try Fixture.text("uninstall-service-dry-run", ext: "txt"))
        #expect(plan.canRun && plan.token == nil && plan.rows.count == 3 && plan.rows[0].hasPrefix("This removes the launchd agent"))
        #expect(!plan.rows.contains { $0.contains("service uninstalled") }, "nothing was removed by a dry run")
        let failed = TidyPlan.service(bench: v16, from: "  [FAIL] No bench at /x\n\nAborting. Check the path\n")
        #expect(!failed.canRun && failed.errors == ["No bench at /x"])
    }

    // MARK: the arguments

    @Test func daysAreWholeFromOneToNinetyAndEveryApplyCarriesItsPlansToken() {
        #expect(TidyCommands.days("7") == 7 && TidyCommands.days(" 90 ") == 90)
        for bad in ["", "0", "91", "-1", "1.5", "1e1", "٣", "1000", "a"] { #expect(TidyCommands.days(bad) == nil, "\(bad)") }
        #expect(TidyCommands.scratch(bench: v16, days: 3) == ["bench", "scratch", v16, "--ttl", "3", "--yes", "--json"])
        #expect(TidyCommands.clearScratch(bench: v16) == ["bench", "scratch", v16, "--clear", "--yes", "--json"])
        #expect(TidyCommands.plan(.gc, bench: v16) == ["bench", "gc", "--dry-run", "--json"])
        #expect(TidyCommands.plan(.forget, bench: v16) == ["bench", "forget", v16, "--dry-run", "--json"])
        #expect(TidyCommands.apply(.gc, bench: v16, token: "T") == ["bench", "gc", "--apply", "T", "--yes", "--jsonl"])
        #expect(TidyCommands.apply(.forget, bench: v16, token: "T") == ["bench", "forget", v16, "--apply", "T", "--yes", "--jsonl"])
        #expect(TidyCommands.apply(.remove, bench: v16, token: "T")
                == ["bench", "remove", v16, "--confirm-bench", "v16-bench", "--apply", "T", "--yes", "--jsonl"])
        #expect(TidyCommands.plan(.removeService, bench: v16) == ["uninstall-service", "--bench-dir", v16, "--dry-run", "--yes", "--plain"])
        #expect(TidyCommands.apply(.removeService, bench: v16, token: nil) == ["uninstall-service", "--bench-dir", v16, "--yes", "--plain"])
        #expect(!TidyCommands.apply(.removeService, bench: v16, token: nil).contains("--all"), "never every bench")
        #expect(TidyCommands.hostsRead == ["site", "hosts", "--prune", "--dry-run", "--plain"], "a dry run: nothing is written")
    }

    // MARK: through the workbench

    @Test func eachEntryShowsOnlyWhenTheCLIListsItsCommand() async throws {
        let (old, _, _) = try await workbench(catalog: Self.oldCatalog)
        #expect(!old.offersTidy && !old.offers(.forget) && !old.offers(.remove) && !old.offers(.removeService) && !old.offers(.gc))
        let (newer, _, _) = try await workbench(catalog: Self.catalog)
        #expect(newer.offersTidy && newer.offersHostsPrune && newer.offers(.forget) && newer.offers(.remove) && newer.offers(.removeService))
        let (partial, _, _) = try await workbench(catalog: #"{"schema_version":1,"commands":[{"name":"db orphans","flags":[]},{"name":"site hosts","flags":[]}]}"#)
        #expect(partial.offersTidy && partial.offersOrphans && !partial.offersHostsPrune && !partial.offersGc && !partial.offersScratch, "site hosts without --prune is not the prune")
    }

    @Test func theReadsTakeNoChangeSlotAndGcRemovesByTheTokenOfItsOwnPlanAsAPerson() async throws {
        let (workbench, bench, runner) = try await workbench(catalog: Self.catalog)
        base.cli.answer("bench gc", json: try Fixture.string("bench-gc-plan"))
        let plan = try await workbench.tidyPlan(.gc, on: bench).get()
        #expect(plan.canRun && base.cli.calls.last == ["bench", "gc", "--dry-run", "--json"] && workbench.result == nil)
        base.cli.answer("db orphans", json: try Fixture.string("db-orphans"))
        #expect(try await workbench.tidyOrphans().get().orphans.count == 2 && base.cli.calls.last == ["db", "orphans", "--json"])
        base.cli.answer("site hosts", .ok(try Fixture.text("site-hosts-prune-dry-run", ext: "txt")))
        #expect(try await workbench.tidyHosts().get() == ["gone.localhost", "two.localhost"])
        #expect(base.cli.calls.last == ["site", "hosts", "--prune", "--dry-run", "--plain"])
        #expect(workbench.result == nil && !runner.calls.contains { $0.arguments.contains("--apply") }, "reading changes nothing")

        base.cli.answer("bench gc", json: try Fixture.lines("bench-gc-apply"))
        #expect(await workbench.tidyChange(plan, on: bench) == nil && workbench.result?.succeeded == true)
        let apply = try #require(runner.calls.last { $0.arguments.contains("--apply") })
        #expect(apply.arguments == ["bench", "gc", "--apply", try #require(plan.token), "--yes", "--jsonl"])
        #expect(apply.environment["BENCHBAR_NONINTERACTIVE"] == "0" && apply.environment["BENCHBAR_CALLER"] == "app" && apply.environment["BENCHBAR_APP_PID"] != nil,
                "removing data runs as the person, who clicked")
    }

    @Test func removeCarriesTheTypedFolderNameAndForgetRunsWithoutThePersonsWord() async throws {
        let (workbench, bench, runner) = try await workbench(catalog: Self.catalog)
        base.cli.answer("bench remove", json: try Fixture.string("bench-remove-plan"))
        let remove = try await workbench.tidyPlan(.remove, on: bench).get()
        base.cli.answer("bench remove", json: try Fixture.lines("bench-retire-result"))
        #expect(await workbench.tidyChange(remove, on: bench) == nil)
        let applied = try #require(runner.calls.last { $0.arguments.contains("--apply") })
        #expect(applied.arguments == ["bench", "remove", v16, "--confirm-bench", "v16-bench", "--apply", try #require(remove.token), "--yes", "--jsonl"])
        #expect(applied.environment["BENCHBAR_NONINTERACTIVE"] == "0")

        base.cli.answer("bench forget", json: try Fixture.string("bench-forget-plan"))
        let forget = try await workbench.tidyPlan(.forget, on: bench).get()
        base.cli.answer("bench forget", json: try Fixture.lines("bench-retire-result"))
        #expect(await workbench.tidyChange(forget, on: bench) == nil)
        #expect(runner.calls.last { $0.arguments.contains("--apply") }?.environment["BENCHBAR_NONINTERACTIVE"] == nil, "an agent may forget, so it is not claimed as a person's")
    }

    @Test func theServiceIsRemovedForThisBenchOnlyAfterItsDryRun() async throws {
        let (workbench, bench, runner) = try await workbench(catalog: Self.catalog)
        base.cli.answer("uninstall-service", .ok(try Fixture.text("uninstall-service-dry-run", ext: "txt")))
        let plan = try await workbench.tidyPlan(.removeService, on: bench).get()
        #expect(plan.canRun && base.cli.calls.last == ["uninstall-service", "--bench-dir", v16, "--dry-run", "--yes", "--plain"])
        #expect(await workbench.tidyChange(plan, on: bench) == nil)
        #expect(runner.calls.last { $0.arguments.first == "uninstall-service" }?.arguments == ["uninstall-service", "--bench-dir", v16, "--yes", "--plain"])
        #expect(workbench.result?.title == "Remove the service of v16-bench")
    }

    @Test func markingScratchSaysItIsAPersonsMarkAndAStaleGcTokenIsAnswered() async throws {
        let (workbench, bench, runner) = try await workbench(catalog: Self.catalog)
        base.cli.answer("bench scratch", json: try Fixture.string("bench-scratch"))
        #expect(await workbench.markScratch(days: 3, on: bench) == nil)
        let marked = runner.calls.last { $0.arguments.first == "bench" }
        #expect(marked?.arguments == ["bench", "scratch", v16, "--ttl", "3", "--yes", "--json"])
        #expect(marked?.environment["BENCHBAR_NONINTERACTIVE"] == "0" && workbench.result?.title == "Mark v16-bench scratch for 3 days")
        #expect(await workbench.markScratch(days: nil, on: bench) == nil)
        #expect(runner.calls.last { $0.arguments.first == "bench" }?.arguments == ["bench", "scratch", v16, "--clear", "--yes", "--json"]
                && workbench.result?.title == "Mark v16-bench not scratch")

        base.cli.answer("bench gc", .init(exitCode: 1, stdout: "", stderr: "[FAIL] The plan changed since it was shown. Nothing was changed."))
        let plan = TidyPlan.gc(try BenchJSON.decode(GcPlan.self, from: Fixture.data("bench-gc-plan")))
        let stale = try #require(await workbench.tidyChange(plan, on: bench))
        #expect(StalePlan.isStale(stale))
        var flow = PlanReviewFlow<TidyPlan>()
        _ = flow.review()
        flow.read(.success(plan))
        _ = flow.apply()
        let closes = flow.finish(error: stale)
        #expect(closes == false, "the sheet stays open on Review Again")
    }

    // MARK: follow-ups of the Run Bench Command review

    @Test func runAppliesTheRequestItsPlanWasReadForNotWhatTheFormSaysNow() throws {
        let migrate = try #require(RunAllowList.known.first { $0.name == "migrate" })
        let read = RunRequest(command: migrate, site: "acme.localhost", options: "--skip-failing")
        var state = RunReviewState()
        let early = state.apply()
        #expect(early == nil, "nothing was read yet")
        let began = state.begin(read)
        #expect(began)
        state.flow.read(.success(try BenchJSON.decode(RunPlan.self, from: Fixture.data("run-plan"))))
        let edited = RunRequest(command: migrate, site: "other.localhost", options: "--skip-search-index")
        let applying = state.apply()
        let applied = try #require(applying)
        #expect(applied.request == read && applied.request != edited)
        #expect(applied.request.arguments(.apply(token: "T"), bench: v16).contains("acme.localhost"))
    }

    @Test func aPathThroughASymlinkIsTheSameBench() throws {
        let real = try TempDir()
        let folder = real.url.appendingPathComponent("bench")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = real.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(OpList.samePath(link.path, folder.path) && OpList.samePath(folder.path, link.path))
        #expect(!OpList.samePath(link.path, real.url.path) && !OpList.samePath(nil, folder.path))
        let list = OpList(ops: [OpRecord(opID: "a", state: "running", bench: link.path)])
        #expect(list.running(on: folder.path).count == 1)
    }

    @Test func aCancelledReadOfTheOperationsKeepsTheListTheOverviewHas() async throws {
        let (workbench, bench, _) = try await workbench(catalog: Self.catalog)
        base.cli.answer("op list", json: try Fixture.string("op-list"))
        #expect(await workbench.showOps(bench))
        let before = try #require(workbench.runningOps[v16])
        #expect(!before.isEmpty)
        base.cli.answer("op list", .init(exitCode: 2, stdout: "", stderr: "[FAIL] cancelled"))
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return await workbench.showOps(bench)
        }
        task.cancel()
        #expect(await task.value == false, "the poll still ends")
        #expect(workbench.runningOps[v16] == before, "a cancelled read says nothing about the bench")
        #expect(await workbench.showOps(bench) == false && workbench.runningOps[v16]?.isEmpty == true, "a read that failed on its own clears the list")
    }
}

private extension OrphanList {
    static let empty = try! BenchJSON.decode(OrphanList.self, from: Data(#"{"schema_version":1,"checked":0,"orphans":[]}"#.utf8))
}
