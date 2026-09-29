import Foundation
import Testing
@testable import BenchBar

@Suite("Team profiles: export, import, subscribe, update, check")
struct ProfileSharingTests {
    let base: BenchStoreTests

    init() throws { base = try BenchStoreTests() }

    func workbench() async throws -> Workbench {
        base.cli.answer("list", json: base.listJSON())
        base.cli.answer("status", json: base.statusJSON("stopped", reason: "manual"))
        base.cli.answer("profile list", json: try Fixture.string("profile-list-sharing"))
        let store = base.makeStore()
        await store.start(polling: false)
        return Workbench(store: store)
    }

    func calls(_ subcommand: String) -> [[String]] {
        base.cli.calls.filter { $0.count > 1 && $0[0] == "profile" && $0[1] == subcommand }
    }

    // MARK: decoding

    @Test func listShowsWhereEachProfileComesFrom() throws {
        let list = try BenchJSON.decode(ProfileList.self, from: Fixture.data("profile-list-sharing"))
        #expect(list.profiles.map(\.origin) == [.builtin, .user, .imported, .subscribed, .path])
        #expect(list.profiles.map(\.originText) == ["built in", "local", "imported", "subscribed · acme/benchbar-profiles", "profile path"])
        let subscribed = list.profiles[3]
        #expect(subscribed.subscription?.behind == 3 && subscribed.subscription?.dir.hasSuffix("acme-benchbar-profiles") == true)
        #expect(subscribed.subscription?.outdatedText == "Outdated · 3 commits / 12 days")
        #expect(list.profiles[2].sourceURL == "https://raw.githubusercontent.com/acme/profiles/main/acme_hr.toml")
        #expect(list.profiles[4].shadowedBy == "/Users/you/.config/benchbar/profiles/acme.toml")
        #expect(Set(list.profiles.map(\.id)).count == list.profiles.count, "a shadowed file keeps its own row")
        #expect(list.profiles[1].schema == 2 && list.profiles[0].schema == nil)
        #expect(list.profiles.map(\.canUpdate) == [false, false, true, true, false])
        #expect(list.profiles.map(\.canRemove) == [false, false, true, true, false])
        #expect(list.profiles.map(\.canExport) == [false, true, true, true, true])
    }

    @Test func aCLIBefore060StillReads() throws {
        let list = try BenchJSON.decode(ProfileList.self, from: Fixture.data("profile-list"))
        #expect(list.profiles.map(\.origin) == [.builtin, .builtin, .user, .user])
        #expect(list.profiles.allSatisfy { $0.sourceURL == nil && $0.subscription == nil && $0.shadowedBy == nil })
    }

    @Test func outdatedTextOnlyWhenBehind() {
        let dir = "/d", repo = "https://github.com/a/b"
        #expect(ProfileSubscription(repo: repo, dir: dir, behind: 0, days: 4).outdatedText == nil)
        #expect(ProfileSubscription(repo: repo, dir: dir, behind: nil, days: nil).outdatedText == nil)
        #expect(ProfileSubscription(repo: repo, dir: dir, behind: 1, days: nil).outdatedText == "Outdated · 1 commit")
        #expect(ProfileSubscription(repo: repo, dir: dir, behind: 2, days: 1).outdatedText == "Outdated · 2 commits / 1 day")
    }

    @Test func decodesEveryProfileDocument() throws {
        let plan = try BenchJSON.decode(ProfileExportPlan.self, from: Fixture.data("profile-export-plan"))
        #expect(plan.apps.map(\.name) == ["acme_core", "acme_erp", "my_tools"])
        #expect(plan.apps[0].exportedRepo == "git@github.com:acme/acme_core.git" && plan.apps[0].currentBranch == "feature/invoices")
        #expect(plan.apps[1].requires == ["acme_core"] && plan.apps[2].access == "personal" && !plan.apps[2].branchVerified)
        #expect(plan.warnings.count == 1)

        let exported = try BenchJSON.decode(ProfileExportResult.self, from: Fixture.data("profile-export"))
        #expect(exported.apps == 2 && exported.dropped == ["my_tools"])

        let refusal = try JSONDecoder().decode(ProfileExportRefusal.self, from: Fixture.data("profile-export-blocked"))
        #expect(refusal.blocked == [.init(app: "acme_core", requiredBy: ["acme_erp"])])

        let importPlan = try BenchJSON.decode(ProfileImportPlan.self, from: Fixture.data("profile-import-plan"))
        #expect(importPlan.exists && importPlan.diff?.contains("+branch = \"develop\"") == true)
        #expect(importPlan.check(for: "acme_core")?.mark == "✗")
        #expect(importPlan.check(for: "acme_erp")?.mark == "✓")
        #expect(importPlan.check(for: "acme_labs")?.mark == "?")
        #expect(importPlan.skippedApps == ["acme_core", "acme_erp"])

        let imported = try BenchJSON.decode(ProfileImportResult.self, from: Fixture.data("profile-import"))
        #expect(imported.path.hasSuffix("profiles/acme.toml"))

        let subscribed = try BenchJSON.decode(ProfileSubscribeResult.self, from: Fixture.data("profile-subscribe"))
        #expect(subscribed.profiles == ["acme-erp", "acme-hr"])

        let update = try BenchJSON.decode(ProfileUpdatePlan.self, from: Fixture.data("profile-update-plan"))
        #expect(update.hasChanges && update.applied == nil && update.updates[0].kind == "subscribed")
        let applied = try BenchJSON.decode(ProfileUpdatePlan.self, from: Fixture.data("profile-update"))
        #expect(applied.applied == true)

        let removed = try BenchJSON.decode(ProfileRemoveResult.self, from: Fixture.data("profile-remove"))
        #expect(removed.movedTo.contains("/removed/"))

        let check = try BenchJSON.decode(ProfileCheck.self, from: Fixture.data("profile-check"))
        #expect(check.repos.map(\.reachable) == [true, false] && check.skippedApps == ["acme_erp"])
    }

    // MARK: rules

    @Test func profileNamesFollowTheCLIRule() {
        for good in ["acme", "acme_hr", "acme-erp", "v16.lts", "0day", "a"] { #expect(ProfileName.isValid(good), "\(good)") }
        for bad in ["", "_acme", "-acme", ".acme", "Acme", "acme hr", "acme/hr", "acmé", "ACME"] { #expect(!ProfileName.isValid(bad), "\(bad)") }
        #expect(!SiteName.isValid("acme_hr"), "sites keep their own rule")
    }

    @Test func importSourcesAreHttpsOrALocalToml() {
        for good in ["https://raw.githubusercontent.com/acme/p/main/acme.toml", "https://gist.github.com/you/abc123",
                     " https://example.com/acme.toml ", "/Users/you/Downloads/acme.toml"] {
            #expect(ProfileSourceRule.isImportSource(good), "\(good)")
        }
        for bad in ["http://example.com/acme.toml", "file:///etc/passwd", "ftp://x/y.toml", "https://", "-x", "--as=evil",
                    "acme.toml", "/Users/you/acme.txt", "javascript:alert(1)", "https://a b.com/x"] {
            #expect(!ProfileSourceRule.isImportSource(bad), "\(bad)")
        }
        #expect(!ProfileSourceRule.isImportURL("/Users/you/acme.toml"), "a link never names a local file")
    }

    @Test func subscribeTakesOnlyGitRemotes() {
        for good in ["git@github.com:acme/benchbar-profiles.git", "https://github.com/acme/profiles", "ssh://git@gitlab.com/acme/p.git",
                     "git@work-gh:acme/p"] {
            #expect(ProfileSourceRule.isGitURL(good), "\(good)")
        }
        for bad in ["", "file:///tmp/repo", "/tmp/repo", "../repo", "ext::sh -c touch% /tmp/x", "--upload-pack=touch /tmp/x",
                    "-oProxyCommand=x", "git@github.com:", "git@:acme/p", "http://github.com/acme/p", "https://github.com",
                    "git@github.com:/etc/passwd", "acme/profiles"] {
            #expect(!ProfileSourceRule.isGitURL(bad), "\(bad)")
        }
    }

    @Test func importLinksRoundTripThroughTheRouter() throws {
        let hosted = "https://raw.githubusercontent.com/acme/p/main/acme.toml?token=a&b=c"
        let link = try #require(ProfileSourceRule.importLink(for: hosted))
        #expect(link.hasPrefix("benchbar://profile/import?url=https%3A%2F%2F"))
        #expect(URLRouter.route(try #require(URL(string: link)), benches: [], selected: nil) == .profile(.importProfile(hosted)))
        #expect(ProfileSourceRule.importLink(for: "http://example.com/a.toml") == nil)
        #expect(ProfileSourceRule.importLink(for: "/Users/you/a.toml") == nil)
    }

    // MARK: export

    @Test func droppingARequiredAppBlocksExport() throws {
        let plan = try BenchJSON.decode(ProfileExportPlan.self, from: Fixture.data("profile-export-plan"))
        var choices = ProfileExportChoices(plan: plan)
        #expect(choices.problem(in: plan) == nil && choices.arguments(for: plan).isEmpty)

        choices.keep["acme_core"] = false
        #expect(choices.blocked(in: plan) == [.init(app: "acme_core", requiredBy: ["acme_erp"])])
        #expect(choices.problem(in: plan)?.hasPrefix("acme_core is required by acme_erp") == true)

        choices.keep["acme_erp"] = false
        #expect(choices.problem(in: plan) == nil, "dropping both is fine")
        #expect(choices.arguments(for: plan) == ["--drop", "acme_core", "--drop", "acme_erp"])

        choices.keep["my_tools"] = false
        #expect(choices.problem(in: plan) == "Keep at least one app.")
    }

    @Test func editedBranchesBecomeBranchArguments() throws {
        let plan = try BenchJSON.decode(ProfileExportPlan.self, from: Fixture.data("profile-export-plan"))
        var choices = ProfileExportChoices(plan: plan)
        choices.branches["acme_core"] = " feature/invoices "
        choices.keep["my_tools"] = false
        #expect(choices.arguments(for: plan) == ["--branch", "acme_core=feature/invoices", "--drop", "my_tools"])
        for bad in ["", "-x", "a b", "a..b", "a=b"] {
            choices.branches["acme_erp"] = bad
            #expect(choices.problem(in: plan) == "acme_erp needs a branch name.", "\(bad)")
        }
    }

    @Test func exportRunsThePlanThenWritesWithTheChoices() async throws {
        let workbench = try await workbench()
        base.cli.answer("profile export", json: try Fixture.string("profile-export-plan"))
        let run = ProfileExportRun(name: "acme", workbench: workbench)
        await run.load()
        #expect(run.phase == .ready && run.canExport)
        #expect(calls("export") == [["profile", "export", "acme", "--plan", "--json"]])

        run.setBranch("acme_erp", "main")
        run.setKeep("my_tools", false)
        base.cli.answer("profile export", json: try Fixture.string("profile-export"))
        await run.export(to: "/Users/you/Desktop/acme.toml")
        #expect(run.phase == .done && run.result?.dropped == ["my_tools"])
        #expect(calls("export").last == ["profile", "export", "acme", "--out", "/Users/you/Desktop/acme.toml",
                                         "--branch", "acme_erp=main", "--drop", "my_tools", "--yes", "--json"])
    }

    @Test func blockedExportIsNotSentAndARefusalIsShown() async throws {
        let workbench = try await workbench()
        base.cli.answer("profile export", json: try Fixture.string("profile-export-plan"))
        let run = ProfileExportRun(name: "acme", workbench: workbench)
        await run.load()
        run.setKeep("acme_core", false)
        #expect(!run.canExport)
        await run.export(to: "/tmp/acme.toml")
        #expect(calls("export").count == 1, "the sheet does not send a blocked export")

        run.setKeep("acme_core", true)
        base.cli.answer("profile export", CommandOutput(exitCode: 1, stdout: try Fixture.string("profile-export-blocked"), stderr: ""))
        await run.export(to: "/tmp/acme.toml")
        #expect(run.phase == .failed("acme_core is required by acme_erp: keep it or drop acme_erp too"))
    }

    // MARK: import

    @Test func importReviewsFirstAndAddsOnlyWhatWasReviewed() async throws {
        let workbench = try await workbench()
        let url = "https://raw.githubusercontent.com/acme/profiles/main/acme.toml"
        base.cli.answer("profile import", json: try Fixture.string("profile-import-plan"))
        let run = ProfileImportRun(source: url, workbench: workbench)
        #expect(!run.canAdd, "nothing to add before a review")
        await run.review()
        #expect(run.phase == .ready && run.plan?.exists == true && run.canAdd)
        #expect(calls("import") == [["profile", "import", url, "--plan", "--json"]])

        run.saveAs = "acme_team"
        #expect(!run.canAdd, "a changed field needs a new review")
        await run.review()
        #expect(calls("import").last == ["profile", "import", url, "--as", "acme_team", "--plan", "--json"])

        base.cli.answer("profile import", json: try Fixture.string("profile-import"))
        await run.add()
        #expect(run.phase == .done && run.result?.name == "acme")
        #expect(calls("import").last == ["profile", "import", url, "--as", "acme_team", "--yes", "--json"])
        #expect(calls("list").count >= 1, "the list reloads")
    }

    @Test func importRefusesBadSourcesWithoutCallingTheCLI() async throws {
        let workbench = try await workbench()
        for bad in ["http://example.com/a.toml", "--yes", "file:///etc/hosts", ""] {
            let run = ProfileImportRun(source: bad, workbench: workbench)
            await run.review()
            #expect(run.phase == .idle)
        }
        let run = ProfileImportRun(source: "/Users/you/acme.toml", workbench: workbench)
        run.saveAs = "Bad Name"
        await run.review()
        #expect(run.phase == .idle && calls("import").isEmpty)
    }

    // MARK: subscribe, update, remove, check

    @Test func subscribeClonesOnClickOnly() async throws {
        let workbench = try await workbench()
        base.cli.answer("profile subscribe", json: try Fixture.string("profile-subscribe"))
        let bad = ProfileSubscribeRun(repo: "ext::sh -c x", workbench: workbench)
        await bad.subscribe()
        #expect(calls("subscribe").isEmpty && bad.phase == .idle)

        let run = ProfileSubscribeRun(repo: " git@github.com:acme/benchbar-profiles.git ", workbench: workbench)
        #expect(run.phase == .idle && calls("subscribe").isEmpty, "a prefilled sheet does nothing on its own")
        await run.subscribe()
        #expect(calls("subscribe") == [["profile", "subscribe", "git@github.com:acme/benchbar-profiles.git", "--yes", "--json"]])
        #expect(run.phase == .done && run.result?.profiles == ["acme-erp", "acme-hr"])
        #expect(!run.canSubscribe, "done once")
    }

    @Test func updateShowsThePlanThenApplies() async throws {
        let workbench = try await workbench()
        base.cli.answer("profile update", json: try Fixture.string("profile-update-plan"))
        let run = ProfileUpdateRun(name: "acme-erp", workbench: workbench)
        await run.load()
        #expect(run.canApply && calls("update") == [["profile", "update", "acme-erp", "--plan", "--json"]])
        base.cli.answer("profile update", json: try Fixture.string("profile-update"))
        await run.apply()
        #expect(run.phase == .done && run.plan?.applied == true)
        #expect(calls("update").last == ["profile", "update", "acme-erp", "--yes", "--json"])
    }

    @Test func updateWithNothingNewCannotApply() async throws {
        let workbench = try await workbench()
        base.cli.answer("profile update", json: #"{"schema_version":1,"updates":[{"name":"acme_hr","kind":"imported","behind":null,"diff":null}]}"#)
        let run = ProfileUpdateRun(name: "acme_hr", workbench: workbench)
        await run.load()
        #expect(run.phase == .ready && !run.canApply)
    }

    @Test func removeReportsInTheBanner() async throws {
        let workbench = try await workbench()
        base.cli.answer("profile remove", json: try Fixture.string("profile-remove"))
        await workbench.removeProfile("acme_hr")
        #expect(calls("remove") == [["profile", "remove", "acme_hr", "--yes", "--json"]])
        #expect(workbench.result?.succeeded == true && workbench.result?.scope == Workbench.profilesScope)
        #expect(workbench.result?.title.contains("/removed/") == true)

        base.cli.answer("profile remove", CommandOutput(exitCode: 1, stdout: "", stderr: "[FAIL] acme is a local profile"))
        await workbench.removeProfile("acme")
        #expect(workbench.result?.error == "[FAIL] acme is a local profile")
    }

    @Test func checkAccessListsEachRepository() async throws {
        let workbench = try await workbench()
        base.cli.answer("profile check", json: try Fixture.string("profile-check"))
        let run = ProfileCheckRun(name: "acme", workbench: workbench)
        await run.load()
        #expect(calls("check") == [["profile", "check", "acme", "--json"]])
        #expect(run.phase == .done && run.check?.repos.map(\.mark) == ["✓", "✗"])
    }
}
