import Foundation
import Testing
@testable import BenchBar

/// MAC-3, MAC-4 and MAC-10: what a benchbar:// link may do without a click, what
/// the app's own CLI runs say about themselves, and what a rejected link leaves in the log.
@Suite("Link and caller trust")
struct LinkTrustTests {
    // MARK: MAC-3, the confirm setting

    @Test func theConfirmSettingIsOffByDefaultAndKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "benchbar-link-trust-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, findEditors: { [] })
        #expect(settings.confirmLinkActions == false, "off by default: Raycast and Shortcuts keep working")
        settings.confirmLinkActions = true
        #expect(AppSettings(defaults: defaults, findEditors: { [] }).confirmLinkActions == true, "kept in UserDefaults")
    }

    @Test func onlyStartStopRestartAndShellsAskAndOnlyWhenTheSettingIsOn() {
        let asking: Set<URLRouter.Route> = [.up, .down, .restart, .console, .db]
        for route in URLRouter.Route.allCases {
            #expect(LinkConfirm.needsAsking(route, setting: false) == false, "\(route) never asks with the setting off")
            #expect(LinkConfirm.needsAsking(route, setting: true) == asking.contains(route), "\(route)")
        }
    }

    @Test func theQuestionNamesTheBenchAndTheActionAndSaysItCameFromALink() {
        for route in [URLRouter.Route.up, .down, .restart, .console, .db] {
            let question = LinkConfirm.question(route, bench: "frappe-bench")
            #expect(question.title.contains("frappe-bench"), "\(route)")
            #expect(question.detail.localizedCaseInsensitiveContains("link"), "\(route)")
            #expect(!question.button.isEmpty)
        }
        #expect(LinkConfirm.question(.down, bench: "b").button == "Stop")
        #expect(LinkConfirm.question(.restart, bench: "b").button == "Restart")
        #expect(LinkConfirm.question(.up, bench: "b").button == "Start")
        #expect(LinkConfirm.question(.console, bench: "b").button == "Open Terminal")
    }

    // MARK: MAC-10, the log

    @Test func aLoggedLinkHoldsTheActionAndNeverTheQueryOrTheUserinfo() {
        let secret = "https://user:token123@team.example.com/team.toml"
        let profile = URL(string: "benchbar://profile/import?url=\(secret)")!
        let label = URLRouter.logLabel(profile)
        #expect(label == "benchbar://profile/import")
        #expect(URLRouter.logLabel(URL(string: "benchbar://down?bench=frappe-bench")!) == "benchbar://down")
        #expect(URLRouter.logLabel(URL(string: "benchbar:up?bench=x")!) == "benchbar://up")
        #expect(URLRouter.logLabel(URL(string: "benchbar://share/join?v=1&c=482913")!) == "benchbar://share")
    }

    @Test func aLinkWithAnUnknownRouteOrAnotherSchemeIsOnlyAHash() {
        let odd = URL(string: "benchbar://drop-everything?bench=x&token=secret")!
        let other = URL(string: "https://user:token123@host.example.com/a?b=c")!
        for url in [odd, other] {
            let label = URLRouter.logLabel(url)
            for leak in ["secret", "token123", "drop-everything", "host.example.com", "bench=x"] {
                #expect(!label.contains(leak), "\(label) leaks \(leak)")
            }
            #expect(label.hasPrefix("other link, hash "))
        }
        #expect(URLRouter.logLabel(odd) == URLRouter.logLabel(odd), "the same link gives the same hash")
        #expect(URLRouter.logLabel(odd) != URLRouter.logLabel(other))
        #expect(URLRouter.logLabel(odd).count < 40)
    }

    @Test func aRejectedProfileLinkLogsNoAddress() {
        // the router explains this one (no https address); the log line must still hold no query
        let url = URL(string: "benchbar://profile/import?url=ftp://user:token123@host/x.toml")!
        guard case .explain = URLRouter.route(url, benches: [], selected: nil) else { Issue.record("expected explain"); return }
        #expect(!URLRouter.logLabel(url).contains("token123"))
    }

    // MARK: MAC-4, the app says it is the app

    @Test func everyPersonRunCarriesTheAppsProcessId() async throws {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        #expect(CLIClient.guiSudo["BENCHBAR_APP_PID"] == pid)
        #expect(CLIClient.personEnvironment["BENCHBAR_APP_PID"] == pid)

        let runner = FakeRunner { _ in .ok("") }
        let client = CLIClient(executable: URL(fileURLWithPath: "/bin/benchbar"), runner: runner)
        try await client.setOpenAs(true, site: "macdev", bench: "/b")
        // a call that says BENCHBAR_NONINTERACTIVE=0 (open --as, from the app's click) is marked by run()
        _ = try await client.run(["open", "--print-url"], timeout: .seconds(5), acceptExitCodes: [0],
                                 extraEnvironment: ["BENCHBAR_NONINTERACTIVE": "0"])
        #expect(runner.calls.count == 2)
        #expect(runner.calls.allSatisfy { $0.environment["BENCHBAR_APP_PID"] == pid })
    }

    @Test func aPlainReadCarriesNoAppMarker() async throws {
        let runner = FakeRunner { _ in .ok("") }
        let client = CLIClient(executable: URL(fileURLWithPath: "/bin/benchbar"), runner: runner)
        _ = try await client.run(["status", "--json"], timeout: .seconds(5), acceptExitCodes: [0])
        #expect(runner.calls[0].environment["BENCHBAR_APP_PID"] == nil)
    }
}
