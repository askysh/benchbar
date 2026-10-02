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

@Suite("Update plan")
struct UpdatePlanTests {
    private func env(app: String, sparkle: Bool = true, existing: Set<String> = []) -> UpdatePlan.Environment {
        UpdatePlan.Environment(home: "/Users/you", appBundlePath: app, sparkle: sparkle, exists: { existing.contains($0) })
    }

    let cask: Set = ["/opt/homebrew/Caskroom/benchbar-app"]

    @Test func sparkleUpdatesTheAppAndItsCLI() {
        let plan = UpdatePlan.make(env(app: "/Users/you/Applications/BenchBar.app"))
        #expect(plan == UpdatePlan(channel: .sparkle, cask: nil))
        #expect(plan.command == nil, "nothing to copy")
        #expect(plan.notes.isEmpty)
        #expect(plan.summary.contains("with its command line tool"))
        #expect(!plan.summary.contains("Terminal"))
    }

    @Test func theCasksAppUpdatesWithSparkleAndOffersBrewToo() {
        let plan = UpdatePlan.make(env(app: "/Applications/BenchBar.app", existing: cask))
        #expect(plan == UpdatePlan(channel: .sparkle, cask: "/opt/homebrew"))
        #expect(plan.command == "brew upgrade askysh/tap/benchbar-app", "no --greedy: the cask has auto_updates")
        #expect(plan.notes.first?.contains("brew upgrade askysh/tap/benchbar-app") == true)
        let intel = UpdatePlan.make(env(app: "/Applications/BenchBar.app", existing: ["/usr/local/Caskroom/benchbar-app"]))
        #expect(intel.cask == "/usr/local")
    }

    @Test func anAppInHomeApplicationsIsNeverTheCasks() {
        // install.sh puts the app there, even on a Mac that has the cask
        let plan = UpdatePlan.make(env(app: "/Users/you/Applications/BenchBar.app", existing: cask))
        #expect(plan.cask == nil)
    }

    @Test func aBuildWithoutSparkleOpensTheReleasePage() {
        let plan = UpdatePlan.make(env(app: "/Users/you/dev/benchbar/macos/build/BenchBar.app", sparkle: false))
        #expect(plan.channel == .releasePage)
        #expect(plan.summary.contains("release page"))
    }
}

@Suite("App CLI link")
struct AppCLILinkTests {
    let bundled = "/Applications/BenchBar.app/Contents/Resources/cli/benchbar"

    @Test func onlyAnInstalledAppRegisters() {
        #expect(AppCLILink.target(appBundlePath: "/Applications/BenchBar.app", home: "/Users/you", bundled: bundled) == bundled)
        let home = "/Users/you/Applications/BenchBar.app/Contents/Resources/cli/benchbar"
        #expect(AppCLILink.target(appBundlePath: "/Users/you/Applications/BenchBar.app", home: "/Users/you", bundled: home) == home)
        for elsewhere in ["/Users/you/dev/benchbar/macos/build/BenchBar.app", "/Volumes/BenchBar/BenchBar.app",
                          "/private/var/folders/xy/T/AppTranslocation/1234/d/BenchBar.app", "/Users/you/Downloads/BenchBar.app"] {
            #expect(AppCLILink.target(appBundlePath: elsewhere, home: "/Users/you", bundled: bundled) == nil, "\(elsewhere)")
        }
        #expect(AppCLILink.target(appBundlePath: "/Applications/BenchBar.app", home: "/Users/you", bundled: nil) == nil,
                "a build without its CLI")
    }

    @Test func registerMakesThenKeepsThenRepointsTheLink() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("benchbar-link-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: home) }
        let app = home + "/Applications/BenchBar.app"
        let link = AppCLILink.linkPath(home: home)
        #expect(link == home + "/.local/state/benchbar/bin/benchbar")
        #expect(AppCLILink.register(appBundlePath: app, home: home, bundled: app + "/Contents/Resources/cli/benchbar"))
        #expect(try fm.destinationOfSymbolicLink(atPath: link) == app + "/Contents/Resources/cli/benchbar")
        #expect(!AppCLILink.register(appBundlePath: app, home: home, bundled: app + "/Contents/Resources/cli/benchbar"),
                "already right: untouched")
        #expect(AppCLILink.register(appBundlePath: app, home: home, bundled: app + "/Contents/Resources/cli/other"))
        #expect(try fm.destinationOfSymbolicLink(atPath: link) == app + "/Contents/Resources/cli/other")
        let leftovers = try fm.contentsOfDirectory(atPath: (link as NSString).deletingLastPathComponent)
        #expect(leftovers == ["benchbar"], "no temporary link left behind")
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

    @Test func updateNowAsksSparkleAndCopyCommandIsTheCasks() async {
        let model = UpdateOffer(settings: settings, currentVersion: "0.7.0", defaults: defaults, sparkle: true,
                                fetch: { _ throws(UpdateCheckError) in Data() }, now: Date.init)
        model.record(.available(version: "0.7.1", page: URL(string: "https://example.com/r")!))
        model.environment = {
            UpdatePlan.Environment(home: "/Users/you", appBundlePath: "/Applications/BenchBar.app",
                                   exists: { $0 == "/opt/homebrew/Caskroom/benchbar-app" })
        }
        let asked = Box(0)
        let opened = Box<URL?>(nil)
        let copied = Box<String?>(nil)
        model.checkWithSparkle = { asked.value += 1 }
        model.openURL = { opened.value = $0 }
        model.copy = { copied.value = $0 }
        model.updateNow()
        #expect(asked.value == 1)
        #expect(opened.value == nil)
        #expect(model.command == "brew upgrade askysh/tap/benchbar-app")
        model.copyCommand()
        #expect(copied.value == "brew upgrade askysh/tap/benchbar-app")
    }

    @Test func withoutSparkleUpdateNowOpensTheReleasePage() async {
        let calls = Box(0)
        let model = offer(clock: Box(Date()), calls: calls)
        await model.checkIfDue()
        model.environment = { UpdatePlan.Environment(home: "/Users/you", appBundlePath: "/Users/you/Applications/BenchBar.app") }
        let opened = Box<URL?>(nil)
        let asked = Box(0)
        model.openURL = { opened.value = $0 }
        model.checkWithSparkle = { asked.value += 1 }
        model.updateNow()
        #expect(opened.value?.absoluteString == "https://github.com/askysh/benchbar/releases/tag/v0.6.0")
        #expect(asked.value == 0)
        #expect(model.command == nil, "no command to copy")
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
