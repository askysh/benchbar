import Foundation
import Testing
@testable import BenchBar

@Suite("Wizard")
struct WizardStateTests {
    static let home = "/Users/you"

    func report(_ name: String = "doctor-prerequisites") throws -> PrerequisiteReport {
        try BenchJSON.decode(PrerequisiteReport.self, from: try Fixture.data(name))
    }

    func profileList() throws -> ProfileList {
        try BenchJSON.decode(ProfileList.self, from: try Fixture.data("profile-list-wizard"))
    }

    func plan() throws -> InstallPlan {
        guard case .plan(let plan)? = try InstallEvent.decodeAll(try Fixture.lines("install-dry-run")).first else { throw Fixture.FixtureError.missing("plan") }
        return plan
    }

    /// A state at the New Bench page with a valid form.
    func filled() throws -> WizardState {
        var s = WizardState(home: Self.home)
        s.send(.chooseNewBench)
        s.send(.prerequisites(try report()))
        s.send(.primary)
        s.send(.profiles(try profileList()))
        s.send(.setAdminPassword("pw"))
        return s
    }

    func stream(_ s: inout WizardState, _ name: String) throws {
        for event in try InstallEvent.decodeAll(try Fixture.lines(name)) { s.send(.install(event)) }
    }

    func installing() throws -> WizardState {
        var s = try filled()
        s.send(.primary)
        s.send(.planned(try plan()))
        s.send(.primary)
        return s
    }

    @Test func welcomeLeadsToTheCheck() {
        var s = WizardState(home: Self.home)
        #expect(s.page == .welcome)
        #expect(s.primary == .init(title: "Set Up a New Bench", enabled: true))
        #expect(s.send(.primary) == [.checkPrerequisites(folder: "/Users/you/frappe-bench")])
        #expect(s.page == .check)
        #expect(s.checking)
    }

    @Test func escOnTheFirstPageLeavesAndAlreadyHavingABenchOpensFindBenches() {
        var s = WizardState(home: Self.home)
        #expect(s.send(.back) == [.leave])
        #expect(s.send(.chooseExistingBench) == [.openFindBenches])
        #expect(s.page == .welcome)
        s.send(.chooseCLIOnly)
        #expect(s.page == .cliOnly)
        s.send(.back)
        #expect(s.page == .welcome)
        s.send(.chooseCLIOnly)
        s.send(.primary)
        #expect(s.page == .welcome)
    }

    @Test func continueIsPossibleWhenNothingFails() throws {
        var s = WizardState(home: Self.home)
        s.send(.chooseNewBench)
        #expect(s.primary?.enabled == false, "no answer yet")
        var bad = try report()
        bad.prerequisites[3].level = .fail
        s.send(.prerequisites(bad))
        #expect(s.primary?.enabled == false)
        #expect(s.send(.primary).isEmpty && s.page == .check)
        s.send(.prerequisites(try report()))
        #expect(s.primary?.enabled == true, "a warning does not stop an install")
        #expect(s.send(.primary) == [.loadProfiles])
        #expect(s.page == .newBench)
        s.send(.back)
        #expect(s.page == .check)
    }

    @Test func thePortFieldAppearsOnlyWhenDefaultPortsAreTaken() throws {
        var s = try filled()
        #expect(s.showsPortField)
        #expect(s.form.portOffset == "1")
        s.send(.setPortOffset("4"))
        s.send(.prerequisites(try report()))
        #expect(s.form.portOffset == "4", "an edited value stays")
        #expect(s.request.portOffset == 4)
        var free = try report()
        free.prerequisites[8].level = .ok
        s.send(.prerequisites(free))
        #expect(!s.showsPortField)
        #expect(s.request.portOffset == nil)
    }

    @Test func theFormNeedsEverythingBeforeReview() throws {
        var s = try filled()
        #expect(s.formProblem == nil)
        #expect(s.request == InstallRequest(benchDir: "/Users/you/frappe-bench", profile: "v15-lts", bundle: "minimal", site: "macdev", portOffset: 1))
        s.send(.setAdminPassword(""))
        #expect(s.primary?.enabled == false)
        s.send(.setAdminPassword("pw"))
        s.send(.setSite("Bad Name"))
        #expect(s.siteProblem == SiteName.rule)
        #expect(s.primary?.enabled == false)
        s.send(.setSite("mysite"))
        s.send(.setPortOffset("x"))
        #expect(s.formProblem != nil)
        s.send(.setPortOffset("2"))
        s.send(.setFolder("~/benches/a"))
        #expect(s.request.benchDir == NSHomeDirectory() + "/benches/a")
        #expect(s.send(.commitFolder) == [.checkPrerequisites(folder: NSHomeDirectory() + "/benches/a")])
        var failing = try report()
        failing.prerequisites[5].level = .fail
        s.send(.prerequisites(failing))
        #expect(s.primary?.enabled == false, "the folder's own failure stops Review")
    }

    @Test func profilesOfferTheBuiltInAndTheValidTeamOnes() throws {
        let s = try filled()
        #expect(s.profileChoices.map(\.name) == ["v15-lts", "v16-lts", "acme"])
        #expect(s.profileChoices[0].versions == "Python 3.11, Node 22, MariaDB 10.11")
        #expect(s.bundles.map(\.name) == ["minimal", "common", "extended"])
    }

    @Test func reviewThenInstallIsTheConfirmation() throws {
        var s = try filled()
        let effects = s.send(.primary)
        #expect(effects == [.planInstall(s.request)])
        #expect(s.page == .review && s.planning)
        #expect(s.primary?.enabled == false)
        s.send(.planned(try plan()))
        #expect(s.primary == .init(title: "Install", enabled: true))
        let start = s.send(.primary)
        #expect(start == [.startInstall(s.request, withRootPassword: false)])
        #expect(s.page == .install && s.isInstalling)
        #expect(s.send(.back).isEmpty, "Esc does not cancel a running install")
        #expect(s.page == .install)
    }

    @Test func aPlanThatFailsKeepsReviewOnItsPage() throws {
        var s = try filled()
        s.send(.primary)
        s.send(.planFailed("no"))
        #expect(s.planError == "no")
        #expect(s.primary?.enabled == false)
        s.send(.back)
        #expect(s.page == .newBench)
        s.send(.planned(try plan()))
        #expect(s.plan == nil, "an answer after leaving is dropped")
    }

    @Test func aSuccessfulInstallEndsOnDone() throws {
        var s = try installing()
        try stream(&s, "install-stream-success")
        s.send(.installEnded(exitCode: 0, error: nil))
        #expect(s.page == .done)
        #expect(s.installPhase == .succeeded)
        #expect(s.siteURL == "http://macdev:8000")
        #expect(s.primary == .init(title: "Open Site", enabled: true))
        #expect(s.send(.primary) == [.openSite("http://macdev:8000")])
        #expect(s.send(.back) == [.finished], "Esc on Done is Done")
        #expect(s.send(.finish) == [.finished])
    }

    @Test func aCancelledDialogSurfacesOnDone() throws {
        var s = try installing()
        try stream(&s, "install-stream-cancelled")
        s.send(.installEnded(exitCode: 0, error: nil))
        #expect(s.page == .done)
        #expect(s.skippedCommands.map(\.command) == ["benchbar site hosts --bench-dir /Users/you/frappe-bench"])
    }

    @Test func aFailedStepCanBeRetriedWithTheSameFlags() throws {
        var s = try installing()
        let request = s.request
        try stream(&s, "install-stream-failed")
        s.send(.installEnded(exitCode: 1, error: nil))
        guard case .failed(let failure) = s.installPhase else { Issue.record("failed"); return }
        #expect(failure.step == "GET_APPS")
        #expect(failure.message.contains("bench get-app"))
        #expect(failure.fix != nil)
        #expect(s.primary == .init(title: "Retry", enabled: true))
        #expect(s.send(.primary) == [.startInstall(request, withRootPassword: false)])
        #expect(s.isInstalling && s.progress.rows.isEmpty, "a retry starts the list over")
    }

    @Test func exitTwoAsksForTheRootPasswordAndRetriesWithIt() throws {
        var s = try installing()
        try stream(&s, "install-stream-exit2")
        s.send(.installEnded(exitCode: 2, error: nil))
        guard case .needsRootPassword(let fix) = s.installPhase else { Issue.record("exit 2"); return }
        #expect(fix?.contains("MARIADB_ROOT_PASSWORD") == true)
        #expect(s.primary == .init(title: "Retry", enabled: false))
        #expect(s.send(.retry).isEmpty)
        s.send(.setRootPassword("root"))
        #expect(s.send(.primary) == [.startInstall(s.request, withRootPassword: true)])
    }

    @Test func stopEndsTheRunAndOffersRunAgain() throws {
        var s = try installing()
        #expect(s.send(.stop) == [.stopInstall])
        #expect(s.send(.stop).isEmpty, "once")
        try stream(&s, "install-stream-failed")
        s.send(.installEnded(exitCode: 143, error: nil))
        #expect(s.installPhase == .stopped, "a stop is not a failure, whatever the stream said")
        #expect(s.primary == .init(title: "Run Again", enabled: true))
        #expect(s.send(.primary) == [.startInstall(s.request, withRootPassword: false)])
        var t = try installing()
        t.send(.installEnded(exitCode: 1, error: "boom"))
        t.send(.back)
        #expect(t.page == .newBench, "Esc after a failure goes back to the form")
    }

    @Test func aRunThatEndsWithoutDoneIsAFailure() throws {
        var s = try installing()
        s.send(.installEnded(exitCode: 9, error: nil))
        guard case .failed(let failure) = s.installPhase else { Issue.record("failed"); return }
        #expect(failure.message.contains("exit code 9"))
    }

    @Test func pollingOnlyOnTheCheckPageWhileCommandLineToolsFail() throws {
        var s = WizardState(home: Self.home)
        #expect(!s.shouldPoll)
        s.send(.chooseNewBench)
        var r = try report()
        r.prerequisites[2].level = .fail
        s.send(.prerequisites(r))
        #expect(s.shouldPoll)
        s.send(.prerequisites(try report()))
        #expect(!s.shouldPoll)
        s.send(.prerequisites(r))
        s.send(.back)
        #expect(!s.shouldPoll, "not on the page")
    }

    @Test func passwordsNeverPrint() throws {
        var s = try filled()
        s.send(.setAdminPassword("hunter2"))
        s.send(.setRootPassword("rootpw"))
        let text = "\(s.form) \(s) \(String(reflecting: s.form.adminPassword))"
        #expect(!text.contains("hunter2") && !text.contains("rootpw"))
    }
}

@Suite("Prerequisites")
struct PrerequisiteTests {
    func report() throws -> PrerequisiteReport {
        try BenchJSON.decode(PrerequisiteReport.self, from: try Fixture.data("doctor-prerequisites"))
    }

    @Test func theFixtureDecodes() throws {
        let r = try report()
        #expect(r.prerequisites.count == 9)
        #expect(r.check("disk_free")?.freeGB == 212)
        #expect(r.portOffsetToUse == 1)
        #expect(r.canContinue)
        #expect(r.summary?.warn == 1)
    }

    @Test func rowsCarryDoctorsWordsAndTheRightAction() throws {
        var r = try report()
        r.prerequisites[2] = Prerequisite(id: "command_line_tools", label: "Xcode Command Line Tools", level: .fail,
                                          message: "not installed", fixCommand: "xcode-select --install")
        r.prerequisites[3] = Prerequisite(id: "homebrew", label: "Homebrew", level: .fail, message: "brew was not found",
                                          fixCommand: "/bin/bash -c \"$(curl -fsSL https://example.test/install.sh)\"")
        let rows = PrerequisiteRows.rows(r)
        #expect(rows[2].action == .installCommandLineTools)
        #expect(rows[3].action == .copy("/bin/bash -c \"$(curl -fsSL https://example.test/install.sh)\""))
        #expect(rows[3].message == "brew was not found")
        #expect(rows[0].action == .none)
        #expect(!r.canContinue)
        #expect(r.failing.map(\.id) == ["command_line_tools", "homebrew"])
    }

    @Test func theRunnerWakesAsRowsPass() throws {
        func state(_ levels: [CheckLevel]) -> BenchState {
            PrerequisiteRows.runnerState(levels.enumerated().map { Prerequisite(id: "c\($0.offset)", label: "", level: $0.element, message: "") })
        }
        #expect(state([]) == .stopped)
        #expect(state([.fail, .fail]) == .stopped)
        #expect(state([.ok, .fail]) == .starting)
        #expect(state([.ok, .warn]) == .starting)
        #expect(state([.ok, .ok]) == .running)
        #expect(try report().runnerState == .starting, "one warning is not all ok")
    }

    @Test func profilesCarryVersionsAndBundlesAndAnOlderCLIStillDecodes() throws {
        let list = try BenchJSON.decode(ProfileList.self, from: try Fixture.data("profile-list-wizard"))
        #expect(list.profiles[0].python == "3.11" && list.profiles[0].mariadb == "10.11")
        #expect(list.bundles?.map(\.name) == ["minimal", "common", "extended"])
        #expect(list.bundles?[1].apps == ["erpnext", "hrms", "payments"])
        let old = try BenchJSON.decode(ProfileList.self, from: try Fixture.data("profile-list"))
        #expect(old.bundles == nil && old.profiles[0].python == nil)
        #expect(ProfileChoice.choices(from: old.profiles).map(\.name) == ["v15-lts", "v16-lts", "acme"], "the invalid one is not offered")
    }

    @Test func xcodeSelectIsTheOnlyOtherCommand() async {
        let ok = FakeRunner { _ in .ok("") }
        #expect(await CommandLineTools.install(runner: ok) == nil)
        #expect(ok.calls.first?.executable == "/usr/bin/xcode-select")
        #expect(ok.calls.first?.arguments == ["--install"])
        let busy = FakeRunner { _ in CommandOutput(exitCode: 1, stdout: "", stderr: "xcode-select: error: command line tools are already installed") }
        #expect(await CommandLineTools.install(runner: busy)?.contains("already installed") == true)
    }
}

@Suite("Sidebar and site names")
struct SidebarTests {
    func input(_ path: String, _ name: String, sites: [String] = ["macdev"]) -> SidebarModel.Input {
        .init(path: path, name: name, state: .running, isBusy: false, sites: sites.enumerated().map { .init(name: $0.element, isDefault: $0.offset == 0) })
    }

    @Test func zeroBenches() {
        let m = SidebarModel([])
        #expect(m.isEmpty && m.benches.isEmpty)
        #expect(SidebarModel.emptyText == "No bench yet")
    }

    @Test func oneBenchWithItsSites() {
        let m = SidebarModel([input("/Users/you/frappe-bench", "frappe-bench", sites: ["macdev", "second.localhost"])])
        #expect(m.benches.count == 1)
        #expect(m.benches[0].hint == nil)
        #expect(m.benches[0].sites.map(\.name) == ["macdev", "second.localhost"])
        #expect(m.benches[0].sites.map(\.isDefault) == [true, false])
    }

    @Test func severalBenchesKeepTheOrderAndDuplicateNamesShowTheirFolder() {
        let m = SidebarModel([input("/a/work/bench", "bench"), input("/a/play/bench", "bench"), input("/a/other", "other")])
        #expect(m.benches.map(\.name) == ["bench", "bench", "other"])
        #expect(m.benches.map(\.hint) == ["work", "play", nil])
        #expect(Set(m.benches.map(\.id)).count == 3)
    }

    @Test func addSiteAndTheWizardShareOneRule() {
        for name in ["macdev", "a-b.localhost", "9lives"] { #expect(SiteName.isValid(name)) }
        for name in ["", "Mac", "-x", "a b", "é"] { #expect(!SiteName.isValid(name)) }
        var s = WizardState(home: "/h")
        s.send(.setSite("Bad"))
        #expect(s.siteProblem == SiteName.rule)
        s.send(.setSite("good"))
        #expect(s.siteProblem == nil)
    }
}
