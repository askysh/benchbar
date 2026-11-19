import Foundation
import Testing
@testable import BenchBar

/// Restore and the unfinished operations: models read from the CLI's own output (fixtures
/// recorded from the mocked CLI, kept in step by tests/test-json.sh), the arguments, and the
/// window's calls. Nothing here changes a bench.
@Suite("Restore and pending operations", .serialized)
struct RestorePendingTests {
    let base: BenchStoreTests
    let v16 = "/Users/you/dev/v16-bench"

    init() throws { base = try BenchStoreTests() }

    func workbench() async throws -> (Workbench, BenchModel) {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites"))
        base.cli.answer("site backups", json: try Fixture.string("site-backups"))
        let store = base.makeStore()
        await store.start(polling: false)
        return (Workbench(store: store), try #require(store.benches.first { $0.path == v16 }))
    }

    func restorePlan(_ name: String = "site-restore-plan") throws -> SiteRestorePlan {
        try BenchJSON.decode(SiteRestorePlan.self, from: Fixture.data(name))
    }

    // MARK: restore plan

    @Test func decodesTheRestorePlanOfASite() throws {
        let plan = try restorePlan()
        #expect(plan.site == "acme.localhost" && !plan.new && plan.exists)
        #expect(plan.source.set?.stamp == "20260902_090000" && plan.source.restoresFiles && plan.source.encryptionKey)
        #expect(plan.backupFirst.willRun && plan.backupFirst.withFiles)
        #expect(plan.steps.map(\.id) == ["local_backup", "restore", "encryption_key", "migrate", "clear_cache", "verify"])
        #expect(plan.token.count == 64 && plan.canApply && plan.canRun)
        #expect(plan.touchesText == ["a backup of acme.localhost with its files, first", "the database of acme.localhost",
                                     "the public and private files of acme.localhost", "sites/acme.localhost/site_config.json (the encryption key)"])
    }

    @Test func decodesTheRestorePlanOfACopy() throws {
        let plan = try restorePlan("site-restore-plan-new")
        #expect(plan.site == "copy.localhost" && plan.new && !plan.exists && !plan.backupFirst.willRun)
        #expect(plan.steps.first?.id == "new_site")
        #expect(plan.touchesText == ["a new database for copy.localhost", "sites/copy.localhost/site_config.json (the encryption key)"],
                "the hosts line is the CLI's step, never the app's")
    }

    @Test func aRestorePlanWithErrorsOrNeedsCannotRun() throws {
        let broken = try restorePlan("site-restore-plan-errors")
        #expect(!broken.canApply && !broken.canRun && broken.source.set == nil, "a stamp that is not there: the plan has no set")
        #expect(broken.errors.first?.contains("no complete database backup with the stamp 20260101_000000") == true)
        var needing = try restorePlan()
        needing.needs = ["MARIADB_ROOT_PASSWORD"]
        #expect(needing.canApply && !needing.canRun, "a run without a terminal cannot answer what the CLI would ask")
        #expect(SiteRestoreText.needsText(needing.needs).contains("never asks for or reads it"))
    }

    @Test func theRestoreArgumentsAreTheSameForThePlanAndTheApply() {
        let into = SiteRestoreRequest(target: "acme.localhost", stamp: "20260902_090000", fromSite: "acme.localhost",
                                      asNew: false, withFiles: true, noMigrate: false)
        #expect(into.arguments == ["acme.localhost", "--from", "20260902_090000", "--with-files"])
        let copy = SiteRestoreRequest(target: "copy.localhost", stamp: "20260901_090000", fromSite: "acme.localhost",
                                      asNew: true, withFiles: false, noMigrate: true)
        #expect(copy.arguments == ["copy.localhost", "--from", "20260901_090000", "--from-site", "acme.localhost", "--new", "--no-migrate"])
    }

    @Test func onlyAPlainCompleteBackupIsOffered() throws {
        let list = try BenchJSON.decode(SiteBackupList.self, from: Fixture.data("site-backups"))
        #expect(list.backups.allSatisfy(SiteRestoreText.restorable))
        var encrypted = list.backups[0]
        encrypted.encrypted = true
        var partial = list.backups[0]
        partial.partial = true
        #expect(!SiteRestoreText.restorable(encrypted) && !SiteRestoreText.restorable(partial))
        let label = SiteRestoreText.label(list.backups[0], now: ISO8601DateFormatter().date(from: "2026-09-29T10:45:00Z")!)
        #expect(label == "6 hours ago, 5.2 MB, with files")
    }

    // MARK: restore through the window

    @Test func theRestoreIsReadOnlyUntilTheTokenIsApplied() async throws {
        let (workbench, bench) = try await workbench()
        base.cli.answer("site restore", json: try Fixture.string("site-restore-plan"))
        let request = SiteRestoreRequest(target: "v16two", stamp: "20260902_090000", fromSite: "v16two", asNew: false, withFiles: true, noMigrate: false)
        guard case .success(let plan) = await workbench.restorePlan(request, on: bench) else { Issue.record("no plan"); return }
        #expect(base.cli.calls.last == ["site", "restore", "v16two", "--from", "20260902_090000", "--with-files", "--dry-run", "--json", "--bench-dir", v16])
        #expect(workbench.result == nil, "a plan is not a change")

        base.cli.answer("site restore", .ok("[OK] restored"))
        let error = await workbench.restoreSite(request, token: plan.token, on: bench)
        #expect(error == nil)
        let apply = try #require(base.cli.calls.last { $0.starts(with: ["site", "restore"]) })
        #expect(apply == ["site", "restore", "v16two", "--from", "20260902_090000", "--with-files", "--apply", plan.token, "--yes", "--plain", "--bench-dir", v16])
        #expect(workbench.result == Workbench.ChangeResult(title: "Restore v16two", error: nil, scope: v16))
        #expect(base.cli.calls.suffix(3).contains { $0.starts(with: ["site", "backups"]) }, "the backup the CLI took first is listed again")
    }

    @Test func aStaleTokenIsAnsweredInTheSheetAndACopyIsNamedAsOne() async throws {
        let (workbench, bench) = try await workbench()
        base.cli.answer("site restore", CommandOutput(exitCode: 1, stdout: "", stderr: "[FAIL] The site restore plan changed since it was shown. Nothing was changed."))
        let request = SiteRestoreRequest(target: "copy", stamp: "20260901_090000", fromSite: "v16two", asNew: true, withFiles: false, noMigrate: false)
        let error = try #require(await workbench.restoreSite(request, token: String(repeating: "a", count: 64), on: bench))
        #expect(StalePlan.isStale(error))
        #expect(workbench.result?.title == "Copy v16two to copy" && workbench.result?.succeeded == false)
        var flow = PlanReviewFlow<SiteRestorePlan>(stage: .applying(try restorePlan()))
        let closes = flow.finish(error: error)
        #expect(!closes, "the sheet stays on its stale message")
    }

    // MARK: unfinished operations

    @Test func statusListsTheOperationsThatStoppedPartWay() throws {
        let status = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-pending"))
        let operation = try #require(status.pendingOperations?.first)
        #expect(status.pendingOperations?.count == 1 && operation.isUpdate && operation.app == "acme_crm")
        #expect(operation.failedStep == "migrate" && operation.steps.map(\.name) == ["Migrate macdev", "Build"])
        #expect(operation.updatedAt != nil && operation.branch == "main" && operation.to?.count == 40)
        #expect(operation.title == "Update of acme_crm stopped at migrate")
        #expect(operation.detail == "bench --site macdev migrate failed with exit code 1 after 1s. Left to run: Migrate macdev, Build.")
    }

    @Test func aStatusWithoutTheListOrWithAnOddEntryStillReads() throws {
        let old = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-running"))
        #expect(old.pendingOperations == nil)
        let odd = #"{"schema_version":1,"bench":"/b","state":"stopped","pending_operations":[{"op":"app_add"},{"op":"app_add","app":"crm","steps":[],"failed_step":null}]}"#
        let status = try BenchJSON.decode(BenchStatus.self, from: Data(odd.utf8))
        #expect(status.pendingOperations?.count == 2)
        let entries = (status.pendingOperations ?? []).filter { !$0.app.isEmpty }
        #expect(entries.map(\.app) == ["crm"], "an entry without an app is not shown")
        #expect(entries[0].title == "Adding crm did not finish")
    }

    @Test func anUpdatePlanWithARecordIsNotUpToDate() throws {
        var plan = try BenchJSON.decode(AppUpdatePlan.self, from: Fixture.data("app-update-plan-pending"))
        #expect(plan.pending?.failedStep == "migrate" && plan.steps.map(\.name) == ["Migrate macdev", "Build"] && !plan.isUpToDate)
        plan.to = plan.from
        #expect(!plan.isUpToDate, "the code is at `to`, but the steps of the record still run")
        plan.pending = nil
        #expect(plan.isUpToDate)
    }

    @Test func droppingTheRecordRunsNoStepAndSaysSo() async throws {
        let (workbench, bench) = try await workbench()
        base.cli.answer("app", .ok("[WARN] dropping the unfinished app_update of acme_crm"))
        let status = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-pending"))
        let operation = try #require(status.pendingOperations?.first)
        await workbench.discardPending(operation, on: bench)
        #expect(base.cli.calls.contains(["app", "update", "acme_crm", "--discard-pending", "--yes", "--plain", "--bench-dir", v16]))
        #expect(workbench.result?.title == "Drop the unfinished update of acme_crm" && workbench.result?.succeeded == true)
        #expect(PendingText.discardMessage(operation).contains("its 2 steps"))
        #expect(PendingText.discardMessage(operation).contains("nothing runs now"))
    }
}
