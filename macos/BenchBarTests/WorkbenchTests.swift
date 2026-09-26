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
        #expect(workbench.result == .init(title: "Add acme_erp", error: nil))
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
        for _ in 0..<20 { await Task.yield() }
        #expect(base.cli.calls.contains(["repair", "--yes", "--json", "--bench-dir", v16]))
        #expect(run.steps.map(\.status) == ["done", "skipped"])
        #expect(run.steps[1].message.contains("sudo"))
        #expect(run.phase == .finished(exitCode: 0) && run.log == "/logs/r.log")
        #expect(bench.activity == nil)
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
