import Foundation
import Testing
@testable import BenchBar

@Suite("Add App and Add Site: the reviewed plan")
struct AddPlanTests {
    let base: BenchStoreTests
    let v16 = "/Users/you/dev/v16-bench"

    init() throws { base = try BenchStoreTests() }

    func store() async throws -> (BenchStore, FakeRunner) {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites"))
        let runner = base.cli.runner()
        let store = BenchStore(settings: base.settings,
                               locator: CLILocator(home: base.dir.url, isExecutable: { $0 == "/fake/benchbar" }),
                               makeClient: { CLIClient(executable: $0, runner: runner) },
                               pinger: { _, _ in 200 })
        await store.start(polling: false)
        return (store, runner)
    }

    func plan(_ name: String = "app-add-plan") throws -> AppAddPlan {
        try BenchJSON.decode(AppAddPlan.self, from: Fixture.data(name))
    }

    // MARK: decode

    @Test func decodesThePlanOfAnAppWithNoRequiredApps() throws {
        let plan = try plan()
        #expect(plan.app == "acme_leaf" && plan.branch == "main" && plan.branchSource == "policy")
        #expect(plan.steps.map(\.kind) == ["clone", "build", "restart"])
        #expect(plan.token.count == 64 && plan.canApply && plan.changes && plan.canRun)
        #expect(plan.sites.isEmpty && plan.requiredApps.isEmpty && plan.reason == nil)
        #expect(plan.reachable == true && plan.commit?.count == 40)
        #expect(plan.touches == ["apps/ and sites/apps.txt", "the bench's Python environment", "built assets"])
        #expect(plan.restarts)
    }

    @Test func decodesRequiredAppsAndTheSitesItInstallsOn() throws {
        let plan = try plan("app-add-plan-required")
        #expect(plan.steps.map(\.name) == ["Clone acme_leaf", "Clone acme_mid", "Clone acme_top", "Build", "Install on v16two", "Restart"])
        #expect(plan.missingRequired == ["acme_mid", "acme_leaf"])
        #expect(plan.requiredApps.map(\.requiredBy) == ["acme_top", "acme_mid"])
        #expect(plan.requiredApps.allSatisfy { !$0.present && $0.resolves && $0.source == "apps_tsv" })
        #expect(plan.sites == [.init(name: "v16two", installed: false)])
        #expect(plan.touches.last == "the database of v16two")
    }

    @Test func aPlanWithErrorsCannotRun() throws {
        let plan = try plan("app-add-plan-errors")
        #expect(!plan.canApply && !plan.canRun)
        #expect(plan.errors.first?.hasPrefix("branch nosuch not found in") == true)
    }

    @Test func aPlanWithNothingToDoCannotRun() throws {
        var plan = try plan()
        plan.changes = false
        plan.steps = []
        #expect(plan.canApply && !plan.canRun)
        #expect(plan.touches.isEmpty && !plan.restarts)
    }

    @Test func decodesTheSitePlan() throws {
        let plan = try BenchJSON.decode(SiteAddPlan.self, from: Fixture.data("site-add-plan"))
        #expect(plan.site == "v16three" && !plan.exists && plan.apps.isEmpty && plan.bench == "/Users/you/frappe-bench")
        #expect(plan.steps.map(\.kind) == ["new_site", "hosts"])
        #expect(plan.steps.last?.name == "Add 127.0.0.1 v16three to /etc/hosts")
        #expect(plan.token.count == 64 && plan.changes && plan.canRun)
        #expect(plan.keptDefaultSite == "macdev" && !plan.defaultMoves && !plan.hostsEntry)
        #expect(plan.touches == ["database", "site_folder", "hosts"])
        #expect(plan.touchesText == ["a new MariaDB database and user", "sites/v16three"], "the app never writes /etc/hosts")
    }

    @Test func aSitePlanWithNothingToDoCannotRun() throws {
        let plan = try BenchJSON.decode(SiteAddPlan.self, from: Fixture.data("site-add-plan-exists"))
        #expect(plan.exists && plan.hostsEntry && plan.steps.isEmpty && !plan.changes && !plan.canRun)
        #expect(plan.touchesText.isEmpty)
        var flow = PlanReviewFlow<SiteAddPlan>()
        _ = flow.review()
        flow.read(.success(plan))
        let applied = flow.apply()
        #expect(applied == nil && !flow.isRunning)
    }

    @Test func theStaleTokenMessageIsTheCLIs() {
        #expect(StalePlan.isStale("The app add plan changed since it was shown (apps.txt, apps/, the sites or the remote). Nothing was changed."))
        #expect(StalePlan.isStale("The site add plan changed since it was shown (the sites, apps.txt or the default site). Nothing was changed."))
        #expect(!StalePlan.isStale("[FAIL] cannot read git@github.com:acme/private.git (no SSH key)"))
    }

    // MARK: the CLI calls

    @Test func theDryRunAsksForJSONAndTheApplyCarriesTheSameOptions() async throws {
        let (store, _) = try await store()
        base.cli.answer("app add", json: try Fixture.string("app-add-plan"))
        let bench = try #require(store.benches.first { $0.path == v16 })
        let workbench = Workbench(store: store)
        guard case .success(let plan) = await workbench.addAppPlan(" acme_leaf ", branch: " develop ", site: "v16two", on: bench) else {
            Issue.record("no plan"); return
        }
        #expect(base.cli.calls.contains(["app", "add", "acme_leaf", "--dry-run", "--json", "--bench-dir", v16, "--branch", "develop", "--site", "v16two"]))
        #expect(bench.activity == nil && workbench.result == nil, "reading a plan takes no change slot and leaves no banner")
        await workbench.addApp("acme_leaf", branch: "develop", site: "v16two", token: plan.token, on: bench)
        #expect(base.cli.calls.contains(["app", "add", "acme_leaf", "--apply", plan.token, "--yes", "--plain", "--bench-dir", v16,
                                         "--branch", "develop", "--site", "v16two"]))
    }

    @Test func aRefusedDryRunIsTheCLIsMessage() async throws {
        let (store, _) = try await store()
        base.cli.answer("app add", .init(exitCode: 1, stdout: "", stderr: "[FAIL] Unknown app 'nosuch'"))
        let bench = try #require(store.benches.first { $0.path == v16 })
        let result = await Workbench(store: store).addAppPlan("nosuch", branch: "", site: nil, on: bench)
        #expect(result == .failure(.init(message: "Unknown app 'nosuch'")))
    }

    @Test func aStaleTokenComesBackAsTheCLIsMessage() async throws {
        let (store, _) = try await store()
        let stale = "[FAIL] The app add plan changed since it was shown (apps.txt, apps/, the sites or the remote). Nothing was changed."
        base.cli.answer("app add", .init(exitCode: 1, stdout: stale, stderr: ""))
        let bench = try #require(store.benches.first { $0.path == v16 })
        let error = await Workbench(store: store).addApp("acme_leaf", branch: "", site: nil, token: "old", on: bench)
        #expect(error.map(StalePlan.isStale) == true)
    }

    @Test func theSitePlanIsTheCLIsDryRunAndTheApplyCarriesItsToken() async throws {
        let (store, runner) = try await store()
        base.cli.answer("site add", json: try Fixture.string("site-add-plan"))
        let bench = try #require(store.benches.first { $0.path == v16 })
        let workbench = Workbench(store: store)
        guard case .success(let plan) = await workbench.addSitePlan("v16three", on: bench) else { Issue.record("no plan"); return }
        #expect(base.cli.calls.contains(["site", "add", "v16three", "--dry-run", "--json", "--bench-dir", v16]))
        #expect(bench.activity == nil && workbench.result == nil, "reading a plan takes no change slot and leaves no banner")
        #expect(runner.calls.allSatisfy { $0.environment["ADMIN_PASSWORD"] == nil }, "the review has no password to carry")
        await workbench.addSite("v16three", adminPassword: "s3cret pw", token: plan.token, on: bench)
        let apply = try #require(runner.calls.first { $0.arguments.contains("--apply") })
        #expect(apply.arguments == ["site", "add", "v16three", "--apply", plan.token, "--yes", "--plain", "--bench-dir", v16])
        #expect(apply.environment["ADMIN_PASSWORD"] == "s3cret pw" && !apply.arguments.joined(separator: " ").contains("s3cret"))
        #expect(base.cli.calls.filter { $0.starts(with: ["site", "add"]) && !$0.contains("--dry-run") }.count == 1,
                "the only run of site add without --dry-run is the apply")
    }

    @Test func aRefusedSiteDryRunIsTheCLIsMessage() async throws {
        let (store, _) = try await store()
        base.cli.answer("site add", .init(exitCode: 1, stdout: "", stderr: "[FAIL] Invalid site name"))
        let bench = try #require(store.benches.first { $0.path == v16 })
        #expect(await Workbench(store: store).addSitePlan("Bad_Name", on: bench) == .failure(.init(message: "Invalid site name")))
    }

    @Test func aStaleSiteTokenComesBackAsTheCLIsMessage() async throws {
        let (store, _) = try await store()
        // the CLI's own words, captured from the mock run
        let stale = """
          [FAIL] The site add plan changed since it was shown (the sites, apps.txt or the default site). Nothing was changed.

        Aborting. Review a fresh plan: benchbar site add v16three --dry-run --json, then pass its token.
        """
        base.cli.answer("site add", .init(exitCode: 1, stdout: stale, stderr: ""))
        let bench = try #require(store.benches.first { $0.path == v16 })
        let error = await Workbench(store: store).addSite("v16three", adminPassword: "pw", token: "old", on: bench)
        #expect(error.map(StalePlan.isStale) == true)
    }

    // MARK: the sheet's state machine

    @Test func reviewReadsThenShowsThePlanThenApplies() throws {
        var flow = PlanReviewFlow<AppAddPlan>()
        #expect(flow.stage == .form && flow.plan == nil)
        let early = flow.apply()
        #expect(early == nil, "Add is not available before a plan")
        let started = flow.review()
        #expect(started && flow.stage == .reading)
        let again = flow.review()
        #expect(!again, "a second Review while reading does nothing")
        let plan = try plan()
        flow.read(.success(plan))
        #expect(flow.stage == .reviewing(plan) && flow.plan == plan)
        let applied = flow.apply()
        #expect(applied == plan && flow.isRunning)
        let twice = flow.apply()
        #expect(twice == nil, "a second Add does nothing")
        let closes = flow.finish(error: nil)
        #expect(closes, "done: the sheet closes")
    }

    @Test func aFailedDryRunStaysOnTheFormWithItsMessage() {
        var flow = PlanReviewFlow<AppAddPlan>()
        _ = flow.review()
        flow.read(.failure(.init(message: "Unknown app 'nosuch'")))
        #expect(flow.stage == .form && flow.readError == "Unknown app 'nosuch'")
        _ = flow.review()
        #expect(flow.readError == nil, "a new Review clears the old message")
    }

    @Test func backReturnsToTheFormAndAPlanThatCannotRunIsNotApplied() throws {
        var flow = PlanReviewFlow<AppAddPlan>()
        _ = flow.review()
        flow.read(.success(try plan("app-add-plan-errors")))
        let applied = flow.apply()
        #expect(applied == nil && !flow.isRunning)
        flow.edit()
        #expect(flow.stage == .form)
    }

    @Test func aStaleTokenKeepsTheSheetOpenAndReviewAgainReadsANewPlan() throws {
        var flow = PlanReviewFlow<AppAddPlan>()
        _ = flow.review()
        flow.read(.success(try plan()))
        _ = flow.apply()
        let message = "The app add plan changed since it was shown. Nothing was changed."
        let closes = flow.finish(error: message)
        #expect(!closes, "the sheet stays open")
        #expect(flow.stage == .stale(message) && flow.plan == nil)
        let again = flow.review()
        #expect(again && flow.stage == .reading)
        flow.read(.success(try plan("app-add-plan-required")))
        #expect(flow.plan?.app == "acme_top")
    }

    @Test func anotherFailureClosesTheSheetForTheBanner() throws {
        var flow = PlanReviewFlow<AppAddPlan>()
        _ = flow.review()
        flow.read(.success(try plan()))
        _ = flow.apply()
        let closes = flow.finish(error: "[FAIL] get-app failed")
        #expect(closes)
        let late = flow.finish(error: nil)
        #expect(late, "the stage is still applying: nothing else moved it")
    }

    @Test func aPlanThatArrivesAfterTheFormWasLeftIsIgnored() throws {
        var flow = PlanReviewFlow<AppAddPlan>()
        flow.read(.success(try plan()))
        #expect(flow.stage == .form)
    }

    @Test func aStaleSiteTokenKeepsTheSheetOpenAndReviewAgainReadsANewPlan() throws {
        let plan = try BenchJSON.decode(SiteAddPlan.self, from: Fixture.data("site-add-plan"))
        var flow = PlanReviewFlow<SiteAddPlan>()
        _ = flow.review()
        flow.read(.success(plan))
        #expect(flow.apply() == plan)
        let message = "The site add plan changed since it was shown. Nothing was changed."
        let closes = flow.finish(error: message)
        #expect(!closes && flow.stage == .stale(message) && flow.plan == nil)
        let again = flow.review()
        #expect(again && flow.stage == .reading)
        flow.read(.success(plan))
        #expect(flow.plan == plan)
    }
}
