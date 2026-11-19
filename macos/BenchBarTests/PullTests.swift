import Foundation
import Testing
@testable import BenchBar

/// Pull: the plan and the end of a run read from the CLI's JSON lines (fixtures recorded from the
/// mocked CLI, kept in step by tests/test-pull.sh), the arguments, and the window's calls. Nothing
/// here copies a site.
@Suite("Pull", .serialized)
struct PullTests {
    let base: BenchStoreTests
    let v16 = "/Users/you/dev/v16-bench"

    init() throws { base = try BenchStoreTests() }

    func workbench() async throws -> (Workbench, BenchModel) {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites"))
        let store = base.makeStore()
        await store.start(polling: false)
        return (Workbench(store: store), try #require(store.benches.first { $0.path == v16 }))
    }

    @Test func readsThePlanOfAPullFromTheStream() throws {
        let plan = try #require(PullStream.plan(in: try Fixture.lines("pull-plan")))
        #expect(plan.source == "prod:erp.example.com" && plan.host == "prod" && plan.remoteSite == "erp.example.com")
        #expect(plan.site == "erpcopy" && plan.createSite && !plan.replace && plan.neutralise && plan.encryptionKey)
        #expect(plan.backup?.name == "20260925_020000-erp_example_com-database.sql.gz" && plan.backup?.bytes == 8319)
        #expect(plan.apps.map(\.app) == ["frappe", "erpnext", "hrms"] && plan.differingApps.map(\.app) == ["frappe", "erpnext"], "hrms is skipped, so not a difference")
        #expect(plan.steps.contains { $0.hasPrefix("Neutralise") } && plan.canRun)
        #expect(PullText.appLine(plan.differingApps[0]) == "frappe: 15.41.0 here, 15.40.0 on production (local newer)")
        #expect(PullText.appLine(plan.differingApps[1]) == "erpnext: 15.30.0 here, 15.30.0 on production (branch differs)")
        #expect(PullStream.done(in: try Fixture.lines("pull-plan"))?.exit == 0)
    }

    @Test func aPlanThatKeepsSecretsSaysSo() throws {
        let kept = try #require(PullStream.plan(in: try Fixture.lines("pull-plan-keep-secrets")))
        #expect(!kept.neutralise)
        #expect(PullRequest(source: .ssh("prod:erp.example.com"), name: "erpcopy").arguments == ["pull", "prod:erp.example.com", "--as", "erpcopy"],
                "the copy is neutralised unless the person chose otherwise")
        #expect(PullRequest(source: .ssh("prod:erp.example.com"), name: "erpcopy", keepSecrets: true).arguments.last == "--keep-secrets")
        #expect(PullRequest(source: .folder("/Users/you/dl"), name: "dl").arguments == ["pull", "--from-dir", "/Users/you/dl", "--as", "dl"])
    }

    @Test func theHostAndSiteAreCheckedBeforeAnythingIsAsked() {
        #expect(PullRequest.isValidSSH("prod:erp.example.com") && PullRequest.isValidSSH("my-host_1:shop.example.com"))
        for bad in ["", "prod", "prod:", ":erp", "a:b:c", "prod: erp.example.com", "prod:erp;ls", "prod:erp$(x)"] {
            #expect(!PullRequest.isValidSSH(bad), "\(bad)")
        }
        #expect(PullRequest.defaultName(for: "prod:ERP.example.com") == "erp.example.com.local")
        #expect(PullRequest.defaultName(for: "prod") == "")
    }

    @Test func aRefusedPullPlanShowsTheCLIsReason() async throws {
        let (workbench, bench) = try await workbench()
        base.cli.answer("pull", CommandOutput(exitCode: 1, stdout: try Fixture.lines("pull-plan-missing-app"),
                                              stderr: "[FAIL] this bench lacks apps the production site has installed: hrms\n"))
        let request = PullRequest(source: .ssh("prod:erp.example.com"), name: "erpcopy")
        guard case .failure(let error) = await workbench.pullPlan(request, on: bench) else { Issue.record("a plan"); return }
        #expect(error.message.contains("lacks apps the production site has installed"))
        #expect(!error.message.contains("{"), "no JSON line in the message")
        #expect(base.cli.calls.last == ["pull", "prod:erp.example.com", "--as", "erpcopy", "--dry-run", "--json", "--bench-dir", v16])
    }

    @Test func aPullRunsWithYesAfterThePlanAndReportsWhatWasNeutralised() async throws {
        let (workbench, bench) = try await workbench()
        base.cli.answer("pull", .ok(try Fixture.lines("pull-done")))
        let request = PullRequest(source: .folder("/Users/you/dl"), name: "erpdl")
        let reviewed = try #require(PullStream.plan(in: try Fixture.lines("pull-plan")))
        let error = await workbench.pull(request, reviewed: reviewed, on: bench)
        #expect(error == nil)
        #expect(base.cli.calls.last { $0.first == "pull" } == ["pull", "--from-dir", "/Users/you/dl", "--as", "erpdl", "--yes", "--json", "--bench-dir", v16])
        #expect(workbench.result?.title == "Pull erpdl" && workbench.result?.succeeded == true)
        let note = try #require(workbench.result?.note)
        #expect(note.contains("Neutralised: 1 email accounts switched off, 7 stored secrets cleared, 2 webhooks switched off."))
        #expect(note.contains("Administrator") && note.contains("Add Hosts Lines"))
        // the run listed a plan of its own: a step the reviewed plan lacked, and a backup it did not name, are said
        #expect(note.contains("The run differed from the plan you reviewed: a step the plan did not show: Create the site erpdl (bench new-site)"))
    }

    @Test func aRunThatMatchesTheReviewedPlanSaysNothingAboutIt() throws {
        let plan = try #require(PullStream.plan(in: try Fixture.lines("pull-plan")))
        #expect(plan.differences(from: plan).isEmpty)
        var newer = plan
        newer.backup?.name = "20260926_020000-erp_example_com-database.sql.gz"
        newer.steps.append("Delete everything")
        #expect(newer.differences(from: plan) == ["a step the plan did not show: Delete everything",
                                                  "another backup than the one reviewed: 20260926_020000-erp_example_com-database.sql.gz"])
    }

    @Test func aFailedPullIsAFailureWithTheCLIsWords() async throws {
        let (workbench, bench) = try await workbench()
        base.cli.answer("pull", CommandOutput(exitCode: 2, stdout: "", stderr: "[FAIL] The MariaDB root password is needed for the restore."))
        let error = await workbench.pull(PullRequest(source: .ssh("prod:erp.example.com"), name: "erpcopy"), on: bench)
        #expect(error?.contains("MariaDB root password") == true)
        #expect(workbench.result?.succeeded == false && workbench.result?.note == nil)
    }
}
