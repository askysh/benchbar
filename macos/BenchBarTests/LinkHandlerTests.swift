import Foundation
import Testing
@testable import BenchBar

/// Records what a link made the app do, in order, as short words.
@MainActor
final class FakeLinkEffects: LinkEffects {
    var routerBenches = [
        URLRouter.Bench(path: "/b/frappe-bench", name: "frappe-bench", sites: ["macdev", "second"]),
    ]
    var selectedPath: String?
    var lanRoomsOn = false
    var confirmLinkActions = false
    var answer = true
    var roomKnown = true
    private(set) var calls: [String] = []
    private(set) var questions: [LinkConfirm.Question] = []

    func benchName(at path: String) -> String? { routerBenches.first { $0.path == path }?.name }
    func confirm(_ question: LinkConfirm.Question) -> Bool {
        questions.append(question)
        return answer
    }
    func showWindow() { calls.append("window") }
    func showNetwork() { calls.append("network") }
    func showProfiles(_ link: URLRouter.ProfileLink) { calls.append("profile \(link)") }
    func showNotice(_ message: String) { calls.append("notice \(message)") }
    func openShare(_ target: ShareDeepLink.Target) async -> Bool {
        calls.append("share \(target.fp16)\(target.path)")
        return roomKnown
    }
    func prefillInvite(_ invite: Result<ShareInvite, ShareInvite.Problem>) { calls.append("invite") }
    func start(_ path: String) { calls.append("start \(path)") }
    func stop(_ path: String, fromLink: Bool) { calls.append("stop \(path) fromLink=\(fromLink)") }
    func restart(_ path: String, fromLink: Bool) { calls.append("restart \(path) fromLink=\(fromLink)") }
    func openSite(_ path: String, site: String?) { calls.append("site \(site ?? "-")") }
    func openLogs(_ path: String) { calls.append("logs \(path)") }
    func openBenchWindow(_ path: String) { calls.append("bench \(path)") }
    func runDoctor(_ path: String) { calls.append("doctor \(path)") }
    func openShell(_ kind: TerminalScript.Kind, bench path: String, site: String?) {
        calls.append("\(kind.rawValue) \(site ?? "-")")
    }
    func openEditor(_ path: String) { calls.append("editor \(path)") }
}

@MainActor
@Suite("benchbar:// link effects")
struct LinkHandlerTests {
    let path = "/b/frappe-bench"

    func run(_ text: String, _ effects: FakeLinkEffects) async {
        await LinkHandler.handle(URL(string: text)!, effects: effects)
    }

    @Test func eachRouteCallsItsOneEffect() async {
        let expected: [(String, String)] = [
            ("up", "start \(path)"),
            ("down", "stop \(path) fromLink=true"),
            ("restart", "restart \(path) fromLink=true"),
            ("open", "site -"),
            ("logs", "logs \(path)"),
            ("window", "bench \(path)"),
            ("doctor", "doctor \(path)"),
            ("console", "console -"),
            ("db", "db -"),
            ("editor", "editor \(path)"),
        ]
        for (route, call) in expected {
            let effects = FakeLinkEffects()
            await run("benchbar://\(route)?bench=frappe-bench", effects)
            #expect(effects.calls == [call], "\(route)")
        }
    }

    @Test func siteReachesOpenAndTheShells() async {
        for route in ["open", "console", "db"] {
            let effects = FakeLinkEffects()
            await run("benchbar://\(route)?bench=frappe-bench&site=second", effects)
            #expect(effects.calls.count == 1 && effects.calls[0].hasSuffix("second"), "\(route)")
        }
    }

    @Test func noLinkRouteDoesAnythingElse() async {
        let effects = FakeLinkEffects()
        for word in ["repair", "drop", "restore", "install", "update", "migrate"] {
            await run("benchbar://\(word)?bench=frappe-bench", effects)
        }
        await run("https://example.com/up?bench=frappe-bench", effects)
        #expect(effects.calls.isEmpty)
    }

    @Test func aLinkWithNoBenchAsksNothingAndExplains() async {
        let effects = FakeLinkEffects()
        effects.routerBenches = []
        await run("benchbar://up", effects)
        #expect(effects.calls.count == 1 && effects.calls[0].hasPrefix("notice "))
        #expect(effects.questions.isEmpty)
    }

    @Test func aWindowLinkOnlyShowsTheWindow() async {
        let effects = FakeLinkEffects()
        effects.routerBenches = [effects.routerBenches[0], .init(path: "/b/v16", name: "v16", sites: [])]
        await run("benchbar://window", effects)
        // two benches and none selected: the router explains or shows the window, never picks one
        #expect(effects.calls.count == 1)
        #expect(!effects.calls[0].hasPrefix("bench "))
    }

    // MARK: ask before a link acts

    @Test func confirmedActionRunsAfterOneQuestionAndLeavesTheRoomConfirmToTheAlert() async {
        let effects = FakeLinkEffects()
        effects.confirmLinkActions = true
        await run("benchbar://down?bench=frappe-bench", effects)
        #expect(effects.questions.map(\.title) == ["Stop frappe-bench?"])
        // the link's own alert asked, so the store is told it came from the alert, not silently from a link
        #expect(effects.calls == ["stop \(path) fromLink=false"])
    }

    @Test func declinedActionDoesNothing() async {
        for route in ["up", "down", "restart", "console", "db"] {
            let effects = FakeLinkEffects()
            effects.confirmLinkActions = true
            effects.answer = false
            await run("benchbar://\(route)?bench=frappe-bench", effects)
            #expect(effects.questions.count == 1, "\(route)")
            #expect(effects.calls.isEmpty, "\(route)")
        }
    }

    @Test func showingRoutesAreNeverAsked() async {
        let effects = FakeLinkEffects()
        effects.confirmLinkActions = true
        for route in ["open", "logs", "window", "doctor", "editor"] {
            await run("benchbar://\(route)?bench=frappe-bench", effects)
        }
        #expect(effects.questions.isEmpty)
        #expect(effects.calls.count == 5)
    }

    @Test func noQuestionWhenTheSettingIsOff() async {
        let effects = FakeLinkEffects()
        await run("benchbar://up?bench=frappe-bench", effects)
        #expect(effects.questions.isEmpty)
        #expect(effects.calls == ["start \(path)"])
    }

    // MARK: profiles and rooms

    @Test func aProfileLinkOpensTheSheetWithoutFetching() async {
        let effects = FakeLinkEffects()
        await run("benchbar://profile/import?url=https%3A%2F%2Fexample.com%2Fp.toml", effects)
        #expect(effects.calls == ["profile importProfile(\"https://example.com/p.toml\")"])
    }

    @Test func shareLinksNeedTheLab() async {
        let effects = FakeLinkEffects()
        await run("benchbar://share/0011223344556677/app/todo", effects)
        #expect(effects.calls.isEmpty)
    }

    @Test func aKnownRoomOpensItsPage() async {
        let effects = FakeLinkEffects()
        effects.lanRoomsOn = true
        await run("benchbar://share/0011223344556677/app/todo", effects)
        #expect(effects.calls == ["share 0011223344556677/app/todo"])
    }

    @Test func anUnknownRoomOnlyShowsThePane() async {
        let effects = FakeLinkEffects()
        effects.lanRoomsOn = true
        effects.roomKnown = false
        await run("benchbar://share/0011223344556677/app/todo", effects)
        #expect(effects.calls == ["share 0011223344556677/app/todo", "network"])
    }

    @Test func anInviteFillsTheJoinSheetAndShowsThePane() async {
        let effects = FakeLinkEffects()
        effects.lanRoomsOn = true
        await run("benchbar://share/join?code=123456", effects)
        #expect(effects.calls == ["invite", "network"])
    }
}
