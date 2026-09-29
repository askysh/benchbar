import Foundation
import Testing
@testable import BenchBar

@Suite("Update schedule")
struct UpdateScheduleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func atMostOncePerDay() {
        #expect(UpdateSchedule.isDue(now: now, lastCheck: nil, automatic: true, sparkle: false))
        #expect(!UpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(-60), automatic: true, sparkle: false))
        #expect(!UpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(-23 * 3600), automatic: true, sparkle: false))
        #expect(UpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(-24 * 3600), automatic: true, sparkle: false))
        #expect(UpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(-3 * 86400), automatic: true, sparkle: false))
        // a clock set back does not stop checks for good
        #expect(UpdateSchedule.isDue(now: now, lastCheck: now.addingTimeInterval(3600), automatic: true, sparkle: false))
    }

    @Test func theToggleAndSparkleTurnItOff() {
        #expect(!UpdateSchedule.isDue(now: now, lastCheck: nil, automatic: false, sparkle: false))
        #expect(!UpdateSchedule.isDue(now: now, lastCheck: nil, automatic: true, sparkle: true))
    }

    @Test func onlyANewerVersionIsOffered() {
        #expect(UpdateSchedule.offer(current: "0.5.8", latestSeen: "0.6.0") == "0.6.0")
        #expect(UpdateSchedule.offer(current: "0.5.8", latestSeen: "v0.6.0") == "0.6.0")
        #expect(UpdateSchedule.offer(current: "0.6.0", latestSeen: "0.6.0") == nil)
        #expect(UpdateSchedule.offer(current: "0.7.0", latestSeen: "0.6.0") == nil)
        #expect(UpdateSchedule.offer(current: "0.5.8", latestSeen: nil) == nil)
        #expect(UpdateSchedule.offer(current: "?", latestSeen: "0.6.0") == nil)
    }

    @Test func theBannerIsDismissedPerVersion() {
        #expect(UpdateSchedule.showsBanner(offer: "0.6.0", dismissed: nil))
        #expect(!UpdateSchedule.showsBanner(offer: "0.6.0", dismissed: "0.6.0"))
        #expect(UpdateSchedule.showsBanner(offer: "0.6.1", dismissed: "0.6.0"))
        #expect(!UpdateSchedule.showsBanner(offer: nil, dismissed: nil))
    }
}

@Suite("Update command")
struct UpdatePlanTests {
    let home = "/Users/you"

    private func env(cli: String?, app: String = "/Users/you/Applications/BenchBar.app",
                     checkouts: Set<String> = [], writable: Set<String> = ["/Applications"],
                     links: [String: String] = ["/Users/you/.local/bin/benchbar": "/Users/you/.local/share/benchbar/benchbar"]) -> UpdatePlan.Environment {
        UpdatePlan.Environment(home: home, cliPath: cli, appBundlePath: app,
                               resolve: { links[$0] ?? $0 },
                               isGitCheckout: { checkouts.contains($0) },
                               isWritable: { writable.contains($0) })
    }

    @Test func theManagedInstallUpdatesCLIAndApp() {
        // install.sh's checkout is a git checkout too; where it is decides
        let plan = UpdatePlan.make(env(cli: "/Users/you/.local/bin/benchbar", checkouts: ["/Users/you/.local/share/benchbar"]))
        #expect(plan.cli == .managed)
        #expect(!plan.appOnly)
        #expect(plan.appDirectory == nil)
        #expect(plan.notes.isEmpty)
        #expect(plan.command(to: "0.6.1") == "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.6.1/install.sh | bash -s -- --yes --version v0.6.1",
                "the installer and the app are the release the prompt offered, not whatever is latest later")
        #expect(plan.installedApp == "/Users/you/Applications/BenchBar.app")
    }

    @Test func anOddVersionFallsBackToMainWithoutAPin() {
        let plan = UpdatePlan.make(env(cli: "/Users/you/.local/bin/benchbar", checkouts: ["/Users/you/.local/share/benchbar"]))
        #expect(UpdatePlan.isReleaseVersion("0.7.0-beta.1"))
        #expect(plan.command(to: "v0.6.1; rm -rf ~") == "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --yes",
                "nothing from the version string reaches the shell unless it is a plain release number")
    }

    @Test func aDeveloperCheckoutGetsAppOnlyAndAGitPull() throws {
        let plan = UpdatePlan.make(env(cli: "/Users/you/dev/benchbar/benchbar", checkouts: ["/Users/you/dev/benchbar"]))
        #expect(plan.cli == .checkout("/Users/you/dev/benchbar"))
        #expect(plan.appOnly)
        #expect(plan.command(to: "0.6.1").hasSuffix("| bash -s -- --yes --app-only --version v0.6.1"))
        let note = try #require(plan.notes.first)
        #expect(note.contains("git -C /Users/you/dev/benchbar pull"))
    }

    @Test func aLinkIntoACheckoutIsFollowed() {
        let plan = UpdatePlan.make(env(cli: "/Users/you/.local/bin/benchbar", checkouts: ["/Users/you/dev/benchbar"],
                                       links: ["/Users/you/.local/bin/benchbar": "/Users/you/dev/benchbar/benchbar"]))
        #expect(plan.cli == .checkout("/Users/you/dev/benchbar"))
    }

    @Test func someOtherInstallIsLeftAlone() {
        let plan = UpdatePlan.make(env(cli: "/opt/tools/benchbar"))
        #expect(plan.cli == .other("/opt/tools"))
        #expect(plan.appOnly)
        #expect(plan.notes.first?.contains("the way you installed it") == true)
    }

    @Test func noCLIInstallsIt() {
        let plan = UpdatePlan.make(env(cli: nil))
        #expect(plan.cli == .missing)
        #expect(!plan.appOnly)
    }

    @Test func anAppInApplicationsIsReplacedThere() {
        let plan = UpdatePlan.make(env(cli: "/Users/you/.local/bin/benchbar", app: "/Applications/BenchBar.app"))
        #expect(plan.appDirectory == "/Applications")
        #expect(plan.command(to: "0.6.1") == "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.6.1/install.sh | BENCHBAR_APP_DIR=/Applications bash -s -- --yes --version v0.6.1")
        #expect(plan.installedApp == "/Applications/BenchBar.app")
        #expect(plan.notes.isEmpty)
    }

    @Test func aReadOnlyFolderOrADevBuildGoesToUserApplications() {
        let readOnly = UpdatePlan.make(env(cli: "/Users/you/.local/bin/benchbar", app: "/Applications/BenchBar.app", writable: []))
        #expect(readOnly.appDirectory == nil)
        #expect(readOnly.installedApp == "/Users/you/Applications/BenchBar.app")
        #expect(readOnly.notes.first?.contains("Trash") == true)
        let dev = UpdatePlan.make(env(cli: "/Users/you/.local/bin/benchbar", app: "/Users/you/dev/benchbar/macos/build/BenchBar.app"))
        #expect(dev.appDirectory == nil)
        #expect(dev.notes.count == 1)
    }

    @Test func theScriptRunsTheInstallerThenOpensTheApp() {
        let plan = UpdatePlan.make(env(cli: "/Users/you/dev/benchbar/benchbar", app: "/Applications/BenchBar.app", checkouts: ["/Users/you/dev/benchbar"]))
        let script = plan.script(from: "0.5.8", to: "0.6.0")
        #expect(script.hasPrefix("#!/bin/bash\n"))
        #expect(script.contains("set -o pipefail"))
        #expect(script.contains("curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.6.0/install.sh | BENCHBAR_APP_DIR=/Applications bash -s -- --yes --app-only --version v0.6.0\n"))
        #expect(script.contains("git -C /Users/you/dev/benchbar pull"))
        #expect(script.contains("open /Applications/BenchBar.app"))
        #expect(script.contains("rm -f \"$0\""))
        #expect(!script.contains("sudo"))
        #expect(!script.contains("bench update"))
    }
}

@Suite("Update offer", .serialized)
struct UpdateOfferTests {
    let defaults: UserDefaults
    let settings: AppSettings

    init() {
        defaults = UserDefaults(suiteName: "benchbar-update-tests-\(UUID().uuidString)")!
        settings = AppSettings(defaults: defaults)
    }

    private func offer(current: String = "0.5.8", clock: Box<Date>, calls: Box<Int>, tag: String = "v0.6.0") -> UpdateOffer {
        let body = Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/askysh/benchbar/releases/tag/\#(tag)"}"#.utf8)
        return UpdateOffer(settings: settings, currentVersion: current, defaults: defaults, sparkle: false,
                           fetch: { _ throws(UpdateCheckError) in calls.value += 1; return body },
                           now: { clock.value })
    }

    @Test func checksOnceADayAndRemembersWhatItSaw() async {
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let calls = Box(0)
        let model = offer(clock: clock, calls: calls)
        #expect(settings.checkUpdatesAutomatically, "on by default")
        #expect(model.version == nil)
        await model.checkIfDue()
        #expect(calls.value == 1)
        #expect(model.version == "0.6.0")
        #expect(model.page?.absoluteString == "https://github.com/askysh/benchbar/releases/tag/v0.6.0")
        clock.value = clock.value.addingTimeInterval(3600)
        await model.checkIfDue()
        #expect(calls.value == 1, "not again within a day")
        clock.value = clock.value.addingTimeInterval(24 * 3600)
        await model.checkIfDue()
        #expect(calls.value == 2)
        // a new launch knows the version before any check
        let again = offer(clock: clock, calls: calls)
        #expect(again.version == "0.6.0")
        #expect(again.showsBanner)
    }

    @Test func theToggleStopsAutomaticChecks() async {
        settings.checkUpdatesAutomatically = false
        let calls = Box(0)
        let model = offer(clock: Box(Date()), calls: calls)
        await model.checkIfDue()
        #expect(calls.value == 0)
        #expect(AppSettings(defaults: defaults).checkUpdatesAutomatically == false, "kept in UserDefaults")
    }

    @Test func dismissingHidesTheBannerForThisVersionOnly() async {
        let calls = Box(0)
        let model = offer(clock: Box(Date()), calls: calls)
        await model.checkIfDue()
        model.dismiss()
        #expect(!model.showsBanner)
        #expect(model.version == "0.6.0", "the menu item stays")
        model.record(.available(version: "0.6.1", page: URL(string: "https://example.com/r")!))
        #expect(model.showsBanner)
    }

    @Test func aManualCheckFeedsTheOffer() async {
        let calls = Box(0)
        let model = offer(clock: Box(Date()), calls: calls)
        let body = Data(#"{"tag_name":"v0.7.0"}"#.utf8)
        let about = AboutModel(store: BenchStore(settings: settings),
                               updates: UpdateChecker(currentVersion: "0.5.8") { _ throws(UpdateCheckError) in body },
                               offer: model)
        await about.updates.check()
        #expect(model.version == "0.7.0")
        // after updating, the running version is the latest: nothing to offer
        let updated = offer(current: "0.7.0", clock: Box(Date()), calls: calls)
        #expect(updated.version == nil)
        #expect(!updated.showsBanner)
    }

    @Test func updateNowOpensTerminalThenQuits() async throws {
        let calls = Box(0)
        let model = offer(clock: Box(Date()), calls: calls)
        await model.checkIfDue()
        let ran = Box<(String, String)?>(nil)
        let copied = Box<String?>(nil)
        model.cliPath = { "/Users/you/dev/benchbar/benchbar" }
        model.environment = { path in
            UpdatePlan.Environment(home: "/Users/you", cliPath: path, appBundlePath: "/Users/you/Applications/BenchBar.app",
                                   resolve: { $0 }, isGitCheckout: { $0 == "/Users/you/dev/benchbar" }, isWritable: { _ in true })
        }
        model.runInTerminal = { name, contents in ran.value = (name, contents) }
        model.copy = { copied.value = $0 }
        await confirmation("quits") { quit in
            model.quit = { quit() }
            model.updateNow()
            try? await Task.sleep(for: .seconds(2))
        }
        let (name, script) = try #require(ran.value)
        #expect(name == "update-benchbar")
        #expect(script.contains("--yes --app-only"))
        model.copyCommand()
        #expect(script.contains("--version v0.6.0"), "Update Now installs the offered release")
        #expect(copied.value == "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.6.0/install.sh | bash -s -- --yes --app-only --version v0.6.0")
    }

    @Test func aTerminalThatDoesNotOpenIsShownAndNothingQuits() async {
        let calls = Box(0)
        let model = offer(clock: Box(Date()), calls: calls)
        await model.checkIfDue()
        struct Nope: Error {}
        model.runInTerminal = { _, _ in throw Nope() }
        let quit = Box(false)
        model.quit = { quit.value = true }
        model.updateNow()
        try? await Task.sleep(for: .seconds(2))
        #expect(!quit.value)
        #expect(model.error?.contains("Copy the command") == true)
    }
}
