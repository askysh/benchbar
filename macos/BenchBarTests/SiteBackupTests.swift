import Foundation
import Testing
@testable import BenchBar

@Suite("Site backups and drop", .serialized)
struct SiteBackupTests {
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

    // MARK: models (the fixtures test-json.sh keeps in step with the CLI)

    @Test func decodesTheBackupList() throws {
        let list = try BenchJSON.decode(SiteBackupList.self, from: Fixture.data("site-backups"))
        #expect(list.backups.map(\.stamp) == ["20260929_101500", "20260928_180000"])
        let full = list.backups[0]
        #expect(full.withFiles && full.sizeBytes == 5_242_880 && full.parts.count == 4)
        #expect(full.time == ISO8601DateFormatter().date(from: "2026-09-29T04:45:00Z"))
        #expect(list.backups[1].files == nil && list.backups[1].parts.count == 2)
    }

    @Test func decodesABackupAndTheDrop() throws {
        let made = try BenchJSON.decode(SiteBackupResult.self, from: Fixture.data("site-backup"))
        #expect(made.backup?.withFiles == false)
        let plan = try BenchJSON.decode(SiteDropPlan.self, from: Fixture.data("site-drop-plan"))
        #expect(!plan.isDefault && plan.newDefault == nil)
        #expect(plan.steps.map(\.needsPassword) == [false, true])
        let dropped = try BenchJSON.decode(SiteDropResult.self, from: Fixture.data("site-drop"))
        #expect(dropped.dropped && !dropped.hostsRemoved)
        #expect(dropped.backup?.config == nil && dropped.backup?.withFiles == true)
        #expect(dropped.manualStep?.hasPrefix("sudo sed -i ''") == true)
    }

    // MARK: arguments

    /// The typed text goes to --confirm-site as it is: the CLI refuses a
    /// mismatch, so the app never fills it in with the real name.
    @Test func dropPassesWhatWasTyped() {
        #expect(CLIClient.dropArguments(site: "bbtest.localhost", confirm: "bbtest", newDefault: nil, bench: v16)
                == ["site", "drop", "bbtest.localhost", "--confirm-site", "bbtest", "--json", "--bench-dir", v16])
        #expect(CLIClient.dropArguments(site: "v16dev", confirm: "v16dev", newDefault: "v16two", bench: v16)
                == ["site", "drop", "v16dev", "--confirm-site", "v16dev", "--new-default", "v16two", "--json", "--bench-dir", v16])
    }

    // MARK: the window's calls

    @Test func backUpRunsInTheChangeSlotAndRereadsTheList() async throws {
        let (workbench, bench) = try await workbench()
        base.cli.answer("site backup", json: try Fixture.string("site-backup"))
        base.cli.answer("site backups", json: try Fixture.string("site-backups"))
        let made = await workbench.backUpSite("v16two", withFiles: true, on: bench)
        #expect(made?.stamp == "20260929_101500")
        #expect(base.cli.calls.contains(["site", "backup", "v16two", "--with-files", "--json", "--bench-dir", v16]))
        #expect(workbench.result == Workbench.ChangeResult(title: "Back up v16two with files", error: nil, scope: v16))
        #expect(workbench.backups(of: "v16two", on: bench)?.backups.count == 2)
    }

    @Test func aFailedBackupShowsInTheBanner() async throws {
        let (workbench, bench) = try await workbench()
        base.cli.answer("site backup", CommandOutput(exitCode: 1, stdout: "", stderr: "[FAIL] The backup of v16two failed."))
        let made = await workbench.backUpSite("v16two", withFiles: false, on: bench)
        #expect(made == nil)
        #expect(workbench.result?.error?.contains("The backup of v16two failed") == true)
    }

    @Test func dropPlanIsReadOnlyAndTheDropReportsTheBackup() async throws {
        let (workbench, bench) = try await workbench()
        base.cli.answer("site drop", json: try Fixture.string("site-drop-plan"))
        guard case .success(let plan) = await workbench.dropPlan("v16two", newDefault: nil, on: bench) else {
            Issue.record("no plan"); return
        }
        #expect(plan.steps.count == 2)
        #expect(base.cli.calls.last?.contains("--dry-run") == true)
        #expect(workbench.result == nil)  // a plan is not a change

        base.cli.answer("site drop", json: try Fixture.string("site-drop"))
        guard case .success(let result) = await workbench.dropSite("v16two", confirm: "v16two", newDefault: nil, on: bench) else {
            Issue.record("not dropped"); return
        }
        #expect(result.backup != nil && result.manualStep != nil)
        #expect(base.cli.calls.last?.contains("--dry-run") == false)
        #expect(workbench.result?.succeeded == true)
    }

    @Test func aRefusedDropIsAFailure() async throws {
        let (workbench, bench) = try await workbench()
        base.cli.answer("site drop", CommandOutput(exitCode: 1, stdout: "",
            stderr: "[FAIL] Refusing to drop v16two: --confirm-site must repeat the site name exactly."))
        guard case .failure(let error) = await workbench.dropSite("v16two", confirm: "v16tw", newDefault: nil, on: bench) else {
            Issue.record("a refusal counted as a drop"); return
        }
        #expect(error.message.contains("--confirm-site"))
    }
}

@Suite("Lockfile badge", .serialized)
struct LockBadgeTests {
    let base: BenchStoreTests

    init() throws { base = try BenchStoreTests() }

    @Test func decodesAndWordsTheDrift() throws {
        let check = try BenchJSON.decode(LockCheck.self, from: Fixture.data("lock-check"))
        #expect(!check.inSync && check.drift.count == 2)
        #expect(LockText.badge(check) == "2 differences")
        #expect(check.drift[0].text == "erpnext: commit behind (is a1b2c3d, lock b5f7846)")
        #expect(check.drift[1].text == "hrms on v16two: site app missing (lock hrms)")
        var synced = check
        synced.inSync = true; synced.drift = []
        #expect(LockText.badge(synced) == "In sync")
        synced.inSync = false; synced.drift = [check.drift[0]]
        #expect(LockText.badge(synced) == "1 difference")
    }

    @Test func listCarriesTheLockfile() throws {
        let list = try BenchJSON.decode(BenchList.self, from: Fixture.data("list"))
        #expect(list.benches.map(\.lockFile) == ["/Users/you/frappe-bench/apps/acme/benchbar.toml", nil])
    }

    /// Drift exits 1 with the JSON: still a result, not an error.
    @Test func driftIsAResultAndOnlyBenchesWithALockAreChecked() async throws {
        base.cli.answer("list", json: try Fixture.string("list"))
        base.cli.answer("status", json: try Fixture.string("status-running"))
        base.cli.answer("lock", CommandOutput(exitCode: 1, stdout: try Fixture.string("lock-check"), stderr: ""))
        let store = base.makeStore()
        await store.start(polling: false)
        let workbench = Workbench(store: store)
        for bench in store.benches { await workbench.checkLock(bench) }
        let locked = try #require(store.benches.first { $0.summary.lockFile != nil })
        #expect(workbench.lockChecks[locked.path]?.drift.count == 2)
        #expect(workbench.lockChecks.count == 1)
        #expect(base.cli.calls.filter { $0.first == "lock" } == [["lock", "check", "--json", "--bench-dir", locked.path]])
    }

    /// A failed Check Again must not leave the last "In sync" on screen.
    @Test func aFailedRecheckClearsTheOldResult() async throws {
        base.cli.answer("list", json: try Fixture.string("list"))
        base.cli.answer("status", json: try Fixture.string("status-running"))
        base.cli.answer("lock", CommandOutput(exitCode: 1, stdout: try Fixture.string("lock-check"), stderr: ""))
        let store = base.makeStore()
        await store.start(polling: false)
        let workbench = Workbench(store: store)
        let locked = try #require(store.benches.first { $0.summary.lockFile != nil })
        await workbench.checkLock(locked)
        #expect(workbench.lockChecks[locked.path] != nil)
        base.cli.answer("lock", CommandOutput(exitCode: 2, stdout: "", stderr: "[FAIL] benchbar.toml: parse error"))
        await workbench.checkLock(locked)
        #expect(workbench.lockChecks[locked.path] == nil)
        #expect(workbench.lockErrors[locked.path]?.contains("parse error") == true)
    }
}
