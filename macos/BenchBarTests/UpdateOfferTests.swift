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

    nonisolated static let brewLinks = [
        "/Users/you/.local/bin/benchbar": "/Users/you/.local/share/benchbar/benchbar",
        "/opt/homebrew/bin/benchbar": "/opt/homebrew/Cellar/benchbar/0.7.0/bin/benchbar",
        "/usr/local/bin/benchbar": "/usr/local/Cellar/benchbar/0.7.0/bin/benchbar",
    ]

    private func env(cli: String?, app: String = "/Users/you/Applications/BenchBar.app",
                     checkouts: Set<String> = [], writable: Set<String> = ["/Applications"],
                     links: [String: String] = UpdatePlanTests.brewLinks,
                     sparkle: Bool = false, existing: Set<String> = []) -> UpdatePlan.Environment {
        UpdatePlan.Environment(home: home, cliPath: cli, appBundlePath: app,
                               resolve: { links[$0] ?? $0 },
                               isGitCheckout: { checkouts.contains($0) },
                               isWritable: { writable.contains($0) },
                               sparkle: sparkle,
                               exists: { existing.contains($0) })
    }

    let cask: Set = ["/opt/homebrew/Caskroom/benchbar-app"]

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

    @Test func homebrewsCLIIsUpgradedByBrewNeverTheInstaller() throws {
        // an app from install.sh in ~/Applications, no Sparkle: brew for the CLI, the installer for the app only
        let plan = UpdatePlan.make(env(cli: "/opt/homebrew/bin/benchbar"))
        #expect(plan.cli == .homebrew(prefix: "/opt/homebrew"))
        #expect(plan.app == .installer)
        #expect(plan.command(to: "0.7.0") == "brew upgrade askysh/tap/benchbar && curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.7.0/install.sh | bash -s -- --yes --app-only --version v0.7.0")
        let script = plan.script(from: "0.6.1", to: "0.7.0")
        #expect(script.contains("\n/opt/homebrew/bin/brew upgrade askysh/tap/benchbar && curl"), "a .command file has no shell PATH: brew by its full path")
        #expect(script.contains("open /Users/you/Applications/BenchBar.app"))
        let note = try #require(plan.notes.first)
        #expect(note.contains("brew upgrade askysh/tap/benchbar"))
        // the opt link, as a 0.7.0 Settings path saves it, is Homebrew's too
        #expect(UpdatePlan.make(env(cli: "/opt/homebrew/opt/benchbar/bin/benchbar", links: [:])).cli == .homebrew(prefix: "/opt/homebrew"))
    }

    @Test func intelHomebrewUsesItsOwnBrew() {
        let plan = UpdatePlan.make(env(cli: "/usr/local/bin/benchbar", app: "/Applications/BenchBar.app",
                                       existing: ["/usr/local/Caskroom/benchbar-app"]))
        #expect(plan.cli == .homebrew(prefix: "/usr/local"))
        #expect(plan.app == .cask(prefix: "/usr/local"))
        #expect(plan.scriptCommand(to: "0.7.0") == "/usr/local/bin/brew upgrade askysh/tap/benchbar && /usr/local/bin/brew upgrade --cask --greedy askysh/tap/benchbar-app")
    }

    @Test func aCaskAppWithHomebrewsCLIIsAllBrew() {
        let plan = UpdatePlan.make(env(cli: "/opt/homebrew/bin/benchbar", app: "/Applications/BenchBar.app", existing: cask))
        #expect(plan.app == .cask(prefix: "/opt/homebrew"))
        #expect(plan.replacesApp)
        #expect(plan.command(to: "0.7.0") == "brew upgrade askysh/tap/benchbar && brew upgrade --cask --greedy askysh/tap/benchbar-app")
        #expect(plan.appDirectory == nil)
        #expect(plan.installedApp == "/Applications/BenchBar.app")
        #expect(!plan.script(from: "0.6.1", to: "0.7.0").contains("install.sh"), "never the installer over a cask app")
        #expect(UpdateBanner.explanation(plan).hasPrefix("Terminal opens and runs Homebrew. BenchBar quits"))
    }

    @Test func withSparkleTheCaskAppIsSparklesAndOnlyTheCLIRunsInTerminal() {
        let plan = UpdatePlan.make(env(cli: "/opt/homebrew/bin/benchbar", app: "/Applications/BenchBar.app", sparkle: true, existing: cask))
        #expect(plan.app == .sparkle(cask: "/opt/homebrew"))
        #expect(!plan.replacesApp)
        #expect(plan.runsInTerminal)
        #expect(plan.command(to: "0.7.0") == "brew upgrade askysh/tap/benchbar")
        let script = plan.script(from: "0.6.1", to: "0.7.0")
        #expect(!script.contains("open /Applications"), "BenchBar keeps running; Sparkle replaces it")
        #expect(!script.contains("install.sh"))
        #expect(plan.notes.contains { $0.contains("its own updater") })
        // the app from elsewhere next to Homebrew's CLI is Sparkle's too
        let elsewhere = UpdatePlan.make(env(cli: "/opt/homebrew/bin/benchbar", sparkle: true))
        #expect(elsewhere.app == .sparkle(cask: nil))
        #expect(elsewhere.command(to: "0.7.0") == "brew upgrade askysh/tap/benchbar")
    }

    @Test func aCaskAppWithTheInstallersCLIUpdatesTheCLIWithoutTheApp() {
        let plan = UpdatePlan.make(env(cli: "/Users/you/.local/bin/benchbar", app: "/Applications/BenchBar.app", existing: cask))
        #expect(plan.cli == .managed)
        #expect(plan.app == .cask(prefix: "/opt/homebrew"))
        #expect(plan.command(to: "0.7.0") == "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.7.0/install.sh | bash -s -- --yes --no-app --version v0.7.0 && brew upgrade --cask --greedy askysh/tap/benchbar-app",
                "no BENCHBAR_APP_DIR: the installer leaves the app alone")
        let sparkle = UpdatePlan.make(env(cli: "/Users/you/.local/bin/benchbar", app: "/Applications/BenchBar.app", sparkle: true, existing: cask))
        #expect(sparkle.command(to: "0.7.0") == "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.7.0/install.sh | bash -s -- --yes --no-app --version v0.7.0")
        #expect(!sparkle.replacesApp)
    }

    @Test func aCaskAppWithACheckoutAndSparkleRunsNothingInTerminal() {
        let plan = UpdatePlan.make(env(cli: "/Users/you/dev/benchbar/benchbar", app: "/Applications/BenchBar.app",
                                       checkouts: ["/Users/you/dev/benchbar"], sparkle: true, existing: cask))
        #expect(plan.steps.isEmpty)
        #expect(!plan.runsInTerminal)
        #expect(plan.command(to: "0.7.0") == "brew upgrade --cask --greedy askysh/tap/benchbar-app", "Copy Command still has something to paste")
        #expect(UpdateBanner.explanation(plan).hasPrefix("BenchBar's updater downloads"))
        // without Sparkle brew replaces it
        let brew = UpdatePlan.make(env(cli: "/Users/you/dev/benchbar/benchbar", app: "/Applications/BenchBar.app",
                                       checkouts: ["/Users/you/dev/benchbar"], existing: cask))
        #expect(brew.command(to: "0.7.0") == "brew upgrade --cask --greedy askysh/tap/benchbar-app")
        #expect(brew.notes.first?.contains("git -C /Users/you/dev/benchbar pull") == true)
    }

    @Test func noCLINextToACaskAppIsInstalledByBrew() {
        let plan = UpdatePlan.make(env(cli: nil, app: "/Applications/BenchBar.app", existing: cask))
        #expect(plan.command(to: "0.7.0") == "brew install askysh/tap/benchbar && brew upgrade --cask --greedy askysh/tap/benchbar-app")
    }

    @Test func theInstallersAppIsNotTheCasksEvenWithACaskroom() {
        // a cask installed once and an app from install.sh in ~/Applications, the one running
        let plan = UpdatePlan.make(env(cli: "/Users/you/.local/bin/benchbar", existing: cask))
        #expect(plan.app == .installer)
        #expect(plan.command(to: "0.7.0") == "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.7.0/install.sh | bash -s -- --yes --version v0.7.0")
    }

    @Test func aSparkleBuildKeepsTheInstallerForTheOtherKinds() {
        let managed = UpdatePlan.make(env(cli: "/Users/you/.local/bin/benchbar", sparkle: true))
        #expect(managed.app == .installer)
        #expect(managed.command(to: "0.7.0") == "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.7.0/install.sh | bash -s -- --yes --version v0.7.0")
        #expect(UpdateBanner.explanation(managed).hasPrefix("Terminal opens and runs the installer. BenchBar quits while it is replaced"))
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

    @Test func whenSparkleHasTheAppUpdateNowAsksSparkleAndStaysOpen() async throws {
        let model = UpdateOffer(settings: settings, currentVersion: "0.6.1", defaults: defaults, sparkle: true,
                                fetch: { _ throws(UpdateCheckError) in Data() }, now: Date.init)
        model.record(.available(version: "0.7.0", page: URL(string: "https://example.com/r")!))
        model.cliPath = { "/opt/homebrew/bin/benchbar" }
        model.environment = { path in
            UpdatePlan.Environment(home: "/Users/you", cliPath: path, appBundlePath: "/Applications/BenchBar.app",
                                   resolve: { UpdatePlanTests.brewLinks[$0] ?? $0 }, isGitCheckout: { _ in false }, isWritable: { _ in true },
                                   exists: { $0 == "/opt/homebrew/Caskroom/benchbar-app" })
        }
        let ran = Box<String?>(nil)
        let asked = Box(0)
        let quit = Box(false)
        model.runInTerminal = { _, contents in ran.value = contents }
        model.checkWithSparkle = { asked.value += 1 }
        model.quit = { quit.value = true }
        model.updateNow()
        try? await Task.sleep(for: .seconds(2))
        #expect(asked.value == 1)
        #expect(!quit.value)
        let script = try #require(ran.value)
        #expect(script.contains("/opt/homebrew/bin/brew upgrade askysh/tap/benchbar\n"))
        #expect(model.command == "brew upgrade askysh/tap/benchbar")
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

@Suite("CLI is behind")
struct CLIVersionRuleTests {
    @Test func oneMinorBehindIsTolerated() {
        #expect(!CLIVersionRule.isBehind(cli: "0.7.0", app: "0.7.0"))
        #expect(!CLIVersionRule.isBehind(cli: "0.6.1", app: "0.7.0"), "Homebrew can get a release after Sparkle")
        #expect(!CLIVersionRule.isBehind(cli: "0.6.0", app: "0.7.9"))
        #expect(!CLIVersionRule.isBehind(cli: "0.8.0", app: "0.7.0"), "a newer CLI is never behind")
        #expect(!CLIVersionRule.isBehind(cli: "1.0.0", app: "0.9.0"))
    }

    @Test func twoMinorsOrAnOlderMajorIsBehind() {
        #expect(CLIVersionRule.isBehind(cli: "0.5.9", app: "0.7.0"))
        #expect(CLIVersionRule.isBehind(cli: "0.7.0-beta.1", app: "0.9.0"))
        #expect(CLIVersionRule.isBehind(cli: "0.9.9", app: "1.0.0"))
        #expect(!CLIVersionRule.isBehind(cli: "?", app: "0.9.0"), "an unreadable version says nothing")
    }

    @Test func namesTheCommandForHowItWasInstalled() {
        #expect(CLIVersionRule.version(fromLine: "benchbar 0.6.1") == "0.6.1")
        #expect(CLIVersionRule.version(fromLine: "benchbar") == nil)
        #expect(CLIVersionRule.behind(cliLine: "benchbar 0.6.1", app: "0.8.0", homebrew: true) == "brew upgrade askysh/tap/benchbar")
        #expect(CLIVersionRule.behind(cliLine: "benchbar 0.6.1", app: "0.8.0", homebrew: false) == "benchbar self-update")
        #expect(CLIVersionRule.behind(cliLine: "benchbar 0.6.1", app: "0.7.0", homebrew: false) == nil)
        #expect(CLIVersionRule.behind(cliLine: nil, app: "0.8.0", homebrew: false) == nil)
        // 0.5.x has no self-update
        #expect(CLIVersionRule.behind(cliLine: "benchbar 0.5.8", app: "0.7.0", homebrew: false)
                == "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --no-app")
    }
}
