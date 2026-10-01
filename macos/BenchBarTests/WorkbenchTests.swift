import Foundation
import Testing
@testable import BenchBar

@Suite("BenchBar window: apps, sites, profiles, repair")
struct WorkbenchTests {
    let base: BenchStoreTests
    let v16 = "/Users/you/dev/v16-bench"

    init() throws { base = try BenchStoreTests() }

    /// A store over the two bench fixture, with the runner kept so a test can
    /// read the environment each call got.
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

    // MARK: models

    @Test func decodesTheAppList() throws {
        let list = try BenchJSON.decode(AppList.self, from: Fixture.data("app-list"))
        #expect(list.apps.map(\.name) == ["frappe", "erpnext", "acme_erp"])
        let custom = list.apps[2]
        #expect(custom.dirty && custom.policyBranch == nil && custom.sites.isEmpty)
        #expect(AppSource.sitesWithout(list.apps[1], among: ["v16dev", "v16two"]) == ["v16two"])
    }

    @Test func decodesTheUpdatePlan() throws {
        let plan = try BenchJSON.decode(AppUpdatePlan.self, from: Fixture.data("app-update-plan"))
        #expect(plan.commitsTotal == 12 && plan.commits.count == 2)
        #expect(!plan.isUpToDate)
        #expect(plan.steps.first?.name == "Back up v16dev")
    }

    @Test func decodesProfilesIncludingBrokenOnes() throws {
        let list = try BenchJSON.decode(ProfileList.self, from: Fixture.data("profile-list"))
        #expect(list.profiles.filter(\.isTeam).map(\.name) == ["acme", "broken"])
        #expect(list.profiles.last?.valid == false)
        #expect(list.profiles.last?.error?.contains("frapee_branch") == true)
    }

    @Test func repairEventsParseAndUnknownLinesAreIgnored() {
        let plan = RepairEvent.parse(#"{"event":"plan","actions":[{"id":"build","label":"bench build","fixes":["Built assets"],"sudo":false},{"id":"hosts_entry","label":"add x","fixes":[],"sudo":true}],"log":"/l"}"#)
        guard case .plan(let actions, let log)? = plan else { Issue.record("no plan"); return }
        #expect(actions.map(\.id) == ["build", "hosts_entry"] && actions[1].sudo && log == "/l")
        #expect(RepairEvent.parse(#"{"event":"step","action":"build","status":"failed","message":"[FAIL] x"}"#)
                == .step(action: "build", status: "failed", message: "[FAIL] x"))
        #expect(RepairEvent.parse(#"{"event":"done","exit_code":0,"log":"/l"}"#) == .done(exitCode: 0, log: "/l"))
        #expect(RepairEvent.parse(#"{"event":"progress","pct":40}"#) == nil)
        #expect(RepairEvent.parse("[OK] human text") == nil)
    }

    @Test func appSourcesAndSiteNames() {
        #expect(AppSource.displayName("https://github.com/acme/acme_erp.git") == "acme_erp")
        #expect(AppSource.displayName("git@work-gh:acme/acme_hr.git") == "acme_hr")
        #expect(AppSource.displayName("erpnext") == "erpnext")
        #expect(AppSource.isURL("git@github.com:acme/x.git") && AppSource.isURL("https://github.com/a/b") && !AppSource.isURL("hrms"))
        #expect(SiteName.isValid("v16two") && SiteName.isValid("a.b-c") && !SiteName.isValid("Bad") && !SiteName.isValid("-x") && !SiteName.isValid(""))
    }

    // MARK: changes

    @Test func addAppSendsTheSourceBranchAndSiteWithYes() async throws {
        let (store, _) = try await store()
        base.cli.answer("app", json: try Fixture.string("app-list"))
        let bench = try #require(store.benches.first { $0.path == v16 })
        let workbench = Workbench(store: store)
        await workbench.addApp(" https://github.com/acme/acme_erp ", branch: "develop", site: "v16two", on: bench)
        #expect(base.cli.calls.contains(["app", "add", "https://github.com/acme/acme_erp", "--yes", "--plain", "--bench-dir", v16,
                                         "--branch", "develop", "--site", "v16two"]))
        #expect(workbench.result == .init(title: "Add acme_erp", error: nil, scope: v16), "the banner shows on this bench only")
        #expect(bench.activity == nil, "the slot is free again")
    }

    @Test func theAdministratorPasswordNeverGoesOnACommandLine() async throws {
        let (store, runner) = try await store()
        base.cli.answer("site", json: "")
        let bench = try #require(store.benches.first { $0.path == v16 })
        await Workbench(store: store).addSite("v16three", adminPassword: "s3cret pw", on: bench)
        let call = try #require(runner.calls.first { $0.arguments.starts(with: ["site", "add"]) })
        #expect(call.arguments == ["site", "add", "v16three", "--yes", "--plain", "--bench-dir", v16])
        #expect(!call.arguments.joined(separator: " ").contains("s3cret"))
        #expect(call.environment["ADMIN_PASSWORD"] == "s3cret pw")
        #expect(!runner.calls.filter { !$0.arguments.starts(with: ["site", "add"]) }.contains { $0.environment["ADMIN_PASSWORD"] != nil },
                "no other call carries it")
    }

    @Test func aChangeWaitsWhileAnotherBenchHoldsTheSlot() async throws {
        let (store, _) = try await store()
        let v15 = try #require(store.benches.first { $0.path != v16 })
        let bench = try #require(store.benches.first { $0.path == v16 })
        v15.activity = "Add something"
        let workbench = Workbench(store: store)
        await workbench.installApp("erpnext", site: "v16two", on: bench)
        #expect(!base.cli.calls.contains { $0.starts(with: ["app", "install"]) })
        #expect(workbench.result?.succeeded == false)
    }

    @Test func aFailedChangeReportsTheCLIMessage() async throws {
        let (store, _) = try await store()
        base.cli.answer("app", .init(exitCode: 1, stdout: "[FAIL] cannot read git@github.com:acme/private.git (no SSH key)", stderr: ""))
        let bench = try #require(store.benches.first { $0.path == v16 })
        let workbench = Workbench(store: store)
        await workbench.addApp("git@github.com:acme/private.git", branch: "", site: nil, on: bench)
        #expect(workbench.result?.error?.contains("no SSH key") == true)
        #expect(!base.cli.calls.contains { $0.contains("--branch") }, "an empty branch is left to the CLI")
    }

    @Test func profilesLoadAndCreateFromABench() async throws {
        let (store, _) = try await store()
        base.cli.answer("profile", json: try Fixture.string("profile-list"))
        let bench = try #require(store.benches.first { $0.path == v16 })
        let workbench = Workbench(store: store)
        await workbench.loadProfiles()
        #expect(workbench.profiles.count == 4)
        await workbench.createProfile("acme", from: bench)
        #expect(base.cli.calls.contains(["profile", "create", "acme", "--from-bench", v16, "--yes", "--plain"]))
    }

    // MARK: repair

    @Test func repairShowsThePlanThenRunsWithLiveSteps() async throws {
        let (store, _) = try await store()
        let bench = try #require(store.benches.first { $0.path == v16 })
        base.cli.answer("doctor", json: try Fixture.string("doctor"))
        base.cli.answer("repair", json: #"{"event":"plan","actions":[{"id":"build","label":"bench build","fixes":["Built assets"],"sudo":false},{"id":"hosts_entry","label":"add v16two to /etc/hosts (sudo)","fixes":["/etc/hosts entry"],"sudo":true}],"log":null}"#)
        let run = RepairRun(bench: bench, store: store)
        await run.loadPlan()
        #expect(run.phase == .review)
        #expect(run.steps.map(\.id) == ["build", "hosts_entry"] && run.hasSudoSteps)
        #expect(base.cli.calls.contains(["repair", "--dry-run", "--json", "--bench-dir", v16]))
        #expect(!base.cli.calls.contains { $0.contains("--yes") }, "nothing runs before the user says yes")

        base.cli.answer("repair", json: """
        {"event":"plan","actions":[{"id":"build","label":"bench build","fixes":[],"sudo":false},{"id":"hosts_entry","label":"add v16two to /etc/hosts (sudo)","fixes":[],"sudo":true}],"log":"/logs/r.log"}
        {"event":"step","action":"build","status":"running","message":"bench build"}
        {"event":"step","action":"build","status":"done","message":"bench build"}
        {"event":"step","action":"hosts_entry","status":"running","message":""}
        {"event":"step","action":"hosts_entry","status":"skipped","message":"[WARN] skipped without sudo"}
        {"event":"done","exit_code":0,"log":"/logs/r.log"}
        """)
        await run.run()
        // no waiting: every event is applied before run() returns
        #expect(base.cli.calls.contains(["repair", "--yes", "--json", "--bench-dir", v16]))
        #expect(run.steps.map(\.status) == ["done", "skipped"])
        #expect(run.steps[1].message.contains("sudo"))
        #expect(run.phase == .finished(exitCode: 0) && run.log == "/logs/r.log")
        #expect(bench.activity == nil)
    }

    @Test func aFailedRunIsNotOverwrittenByItsEvents() async throws {
        let (store, _) = try await store()
        let bench = try #require(store.benches.first { $0.path == v16 })
        base.cli.answer("doctor", json: try Fixture.string("doctor"))
        base.cli.answer("repair", json: #"{"event":"plan","actions":[{"id":"build","label":"bench build","fixes":[],"sudo":false}],"log":null}"#)
        let run = RepairRun(bench: bench, store: store)
        await run.loadPlan()
        // the run prints a step, then the CLI fails (exit 1 is not accepted by runChange's stream? it is: the error comes from the lock)
        let other = try #require(store.benches.first { $0.path != v16 })
        other.activity = "Something else"
        await run.run()
        guard case .failed = run.phase else { Issue.record("expected failed, got \(run.phase)"); return }
        other.activity = nil
    }

    @Test func aPlanThatCannotBeReadFails() async throws {
        let (store, _) = try await store()
        let bench = try #require(store.benches.first { $0.path == v16 })
        base.cli.answer("repair", .init(exitCode: 1, stdout: "", stderr: "[FAIL] No bench at /x."))
        let run = RepairRun(bench: bench, store: store)
        await run.loadPlan()
        guard case .failed(let message) = run.phase else { Issue.record("expected failed, got \(run.phase)"); return }
        #expect(message.contains("No bench"))
    }
}

/// Doctor and the app list are asked for on demand by the window's pages,
/// and kept per bench for the window session.
@Suite("Window session: doctor and the app list", .serialized)
struct OnDemandTests {
    let base: BenchStoreTests

    init() throws { base = try BenchStoreTests() }

    func count(_ command: String) -> Int { base.cli.calls.filter { $0.first == command }.count }

    func store() async throws -> (BenchStore, Workbench, BenchModel) {
        base.cli.answer("list", json: base.listJSON())
        base.cli.answer("status", json: base.statusJSON("stopped", reason: "manual"))
        base.cli.answer("doctor", json: try Fixture.string("doctor"))
        base.cli.answer("app", json: try Fixture.string("app-list"))
        base.cli.answer("up", .ok("[OK] bench is up"))
        base.cli.answer("down", .ok("[OK] bench is down"))
        let store = base.makeStore()
        await store.start(polling: false)
        return (store, Workbench(store: store), try #require(store.selected))
    }

    func show(_ store: BenchStore, _ workbench: Workbench, _ bench: BenchModel) async {
        await store.showDoctor(on: bench)
        await workbench.showApps(bench)
    }

    /// Switching tabs, or between benches, and back asks nothing again.
    @Test func aPageShownAgainKeepsItsAnswer() async throws {
        let (store, workbench, bench) = try await store()
        await show(store, workbench, bench)
        #expect(count("doctor") == 0 && count("app") == 0, "the window is not open: its pages live on, but ask nothing")

        store.setWindow(WindowSight(isOpen: true, isVisible: true))
        await show(store, workbench, bench)
        #expect(count("doctor") == 1 && count("app") == 1)
        #expect(bench.doctor != nil && workbench.apps[bench.path] != nil)
        #expect(base.cli.calls.contains(["app", "list", "--json", "--no-sites", "--bench-dir", base.benchPath]))
        await show(store, workbench, bench)
        await show(store, workbench, bench)
        #expect(count("doctor") == 1 && count("app") == 1)
    }

    /// Run Doctor and Refresh always ask, window or not.
    @Test func theButtonsAlwaysAsk() async throws {
        let (store, workbench, bench) = try await store()
        await store.runDoctor(on: bench)
        await store.runDoctor(on: bench)
        await workbench.loadApps(bench, liveSites: true)
        #expect(count("doctor") == 2)
        #expect(base.cli.calls.contains(["app", "list", "--json", "--bench-dir", base.benchPath]), "Refresh asks MariaDB")
    }

    /// An action on the bench makes its answers old, and so does the next
    /// window session; a closed window asks nothing meanwhile.
    @Test func anActionOrTheNextSessionAsksAgain() async throws {
        let (store, workbench, bench) = try await store()
        store.setWindow(WindowSight(isOpen: true, isVisible: true))
        await show(store, workbench, bench)
        let before = store.stamp(for: bench)

        await store.perform(.up, on: bench)
        #expect(store.stamp(for: bench) != before, "the page's task id moves")
        await show(store, workbench, bench)
        await show(store, workbench, bench)
        #expect(count("doctor") == 2 && count("app") == 2)

        store.setWindow(WindowSight())
        await store.perform(.down, on: bench)
        await show(store, workbench, bench)
        #expect(count("doctor") == 2 && count("app") == 2, "closed: nothing")

        store.setWindow(WindowSight(isOpen: true, isVisible: false))
        await show(store, workbench, bench)
        #expect(count("doctor") == 3 && count("app") == 3, "a new session asks once")
        await show(store, workbench, bench)
        #expect(count("doctor") == 3 && count("app") == 3)
    }

    /// While a change runs on the bench its pages wait; the end of the
    /// change moves the stamp, and that asks.
    @Test func aPageWaitsWhileItsBenchChanges() async throws {
        let (store, workbench, bench) = try await store()
        store.setWindow(WindowSight(isOpen: true, isVisible: true))
        bench.activity = "Add an app"
        await show(store, workbench, bench)
        #expect(count("doctor") == 0 && count("app") == 0)
        bench.activity = nil
        await show(store, workbench, bench)
        #expect(count("doctor") == 1 && count("app") == 1)
    }

    /// Every change from the window ends by making the bench's answers old:
    /// a site, the scheduler, a focus pin, a fetch of the remotes. The last
    /// two read the app list themselves, under the new stamp.
    @Test func everyChangeFromTheWindowAsksAgain() async throws {
        let (store, workbench, bench) = try await store()
        base.cli.answer("site", .ok("[OK] site added"))
        base.cli.answer("service", json: "")
        store.setWindow(WindowSight(isOpen: true, isVisible: true))
        await show(store, workbench, bench)
        var doctor = 1, apps = 1
        let changes: [(name: String, listsApps: Bool, run: () async -> Void)] = [
            ("a site", false, { await workbench.addSite("two.localhost", adminPassword: "x", on: bench) }),
            ("a raw change", false, { _ = await store.runChange("Something", on: bench) { _ throws(CLIError) in } }),
            ("the scheduler", false, { await store.setScheduler(true, on: bench) }),
            ("a focus pin", true, { await workbench.setFocus(.ignore, app: "erpnext", on: bench) }),
            ("Check Remotes", true, { await workbench.checkRemotes(bench) }),
        ]
        for change in changes {
            let before = store.stamp(for: bench)
            await change.run()
            #expect(store.stamp(for: bench) != before, "\(change.name) moves the stamp")
            if change.listsApps { apps += 1 }
            await show(store, workbench, bench)
            doctor += 1
            if !change.listsApps { apps += 1 }
            #expect(count("doctor") == doctor, "\(change.name): doctor asks again")
            #expect(appLists() == apps, "\(change.name): the app list is read once more")
        }
    }

    func appLists() -> Int { base.cli.calls.filter { $0.starts(with: ["app", "list"]) }.count }

    /// After a change to the apps the list is read with the live site lists,
    /// even though the page asks too when the change ends.
    @Test func aChangeToTheAppsReadsTheLiveSites() async throws {
        let (store, workbench, bench) = try await store()
        store.setWindow(WindowSight(isOpen: true, isVisible: true))
        await workbench.showApps(bench)
        await workbench.addApp("hrms", branch: "", site: nil, on: bench)
        await workbench.showApps(bench)
        let lists = base.cli.calls.filter { $0.starts(with: ["app", "list"]) }
        #expect(lists.count == 2)
        #expect(lists.last == ["app", "list", "--json", "--bench-dir", base.benchPath])
    }

    /// The person switches tab while doctor runs: SwiftUI cancels the page's
    /// task, but not the call, which finishes; its answer is kept. Coming
    /// back meanwhile joins the call instead of starting another.
    @Test func aCancelledPageDoesNotStopItsCall() async throws {
        let held = HeldCLI(["list": base.listJSON(), "status": base.statusJSON("stopped", reason: "manual"),
                            "doctor": try Fixture.string("doctor")], holding: ["doctor"])
        let store = base.makeStore(runner: held)
        await store.start(polling: false)
        let bench = try #require(store.selected)
        store.setWindow(WindowSight(isOpen: true, isVisible: true))
        held.hold = true
        let page = Task { await store.showDoctor(on: bench) }
        await base.waitUntil { held.isHolding }
        #expect(bench.isRunningDoctor)
        page.cancel()
        let back = Task { await store.showDoctor(on: bench) }
        await base.settle()
        #expect(held.count("doctor") == 1, "joined, not doubled")

        held.release()
        await page.value
        await back.value
        #expect(held.finished == 1)
        #expect(held.cancelled == 0, "no SIGTERM: the call is not the page's to cancel")
        #expect(bench.doctor != nil)
        #expect(bench.doctorError == nil)
        await store.showDoctor(on: bench)
        #expect(held.count("doctor") == 1, "the answer was kept")
    }

    /// An action that ends while a call runs makes its answer old: the page
    /// asked again by the new stamp waits for the call, then asks once more.
    @Test func anActionDuringTheCallAsksOnceMore() async throws {
        let held = HeldCLI(["list": base.listJSON(), "status": base.statusJSON("stopped", reason: "manual"),
                            "doctor": try Fixture.string("doctor")], holding: ["doctor"])
        let store = base.makeStore(runner: held)
        await store.start(polling: false)
        let bench = try #require(store.selected)
        store.setWindow(WindowSight(isOpen: true, isVisible: true))
        held.hold = true
        let first = Task { await store.showDoctor(on: bench) }
        await base.waitUntil { held.isHolding }
        bench.markChanged()
        let second = Task { await store.showDoctor(on: bench) }
        await base.settle()
        #expect(held.count("doctor") == 1)
        held.release()
        await first.value
        await second.value
        #expect(held.count("doctor") == 2)
        await store.showDoctor(on: bench)
        #expect(held.count("doctor") == 2)
    }
}
