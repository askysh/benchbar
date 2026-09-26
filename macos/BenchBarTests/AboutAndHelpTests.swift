import Foundation
import AppKit
import Testing
@testable import BenchBar

@Suite("Versions")
struct AppVersionTests {
    private func v(_ text: String) throws -> AppVersion { try #require(AppVersion(text)) }

    @Test func comparesNumbersPartByPart() throws {
        #expect(try v("0.5.0") < v("0.6.0"))
        #expect(try v("0.9.0") < v("0.10.0"))
        #expect(try v("0.5.5") < v("0.6"))
        #expect(try v("1.0.0") > v("0.99.99"))
        #expect(try !(v("0.6.0") < v("0.6.0")))
    }

    @Test func aMissingPartIsZero() throws {
        #expect(try v("0.6") == v("0.6.0"))
        #expect(try v("1") == v("1.0.0"))
    }

    @Test func readsTagsAndPrereleases() throws {
        #expect(try v("v0.6.0").description == "0.6.0")
        #expect(try v("V1.2.3").numbers == [1, 2, 3])
        #expect(try v("0.6.0-beta.1") < v("0.6.0"))
        #expect(try v("0.6.0-beta.2") < v("0.6.0-beta.10"))
        #expect(try v("0.6.0-beta.1") > v("0.5.9"))
        #expect(try v("0.6.0+build.7") == v("0.6.0"))
    }

    @Test func refusesWhatIsNotAVersion() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("0..1") == nil)
        #expect(AppVersion("?") == nil)
    }
}

@Suite("Update check")
struct UpdateCheckTests {
    @Test func aNewerReleaseIsAvailableWithItsPage() throws {
        let data = try Fixture.data("github-release-latest")
        let status = try UpdateCheck.parse(data, current: "0.5.0")
        #expect(status == .available(version: "0.6.0", page: URL(string: "https://github.com/askysh/benchbar/releases/tag/v0.6.0")!))
    }

    @Test func theSameOrANewerBuildIsUpToDate() throws {
        let data = try Fixture.data("github-release-latest")
        #expect(try UpdateCheck.parse(data, current: "0.6.0") == .upToDate(latest: "0.6.0"))
        #expect(try UpdateCheck.parse(data, current: "0.6.1") == .upToDate(latest: "0.6.0"))
        // a local build whose version does not parse is never told to update
        #expect(try UpdateCheck.parse(data, current: "?") == .upToDate(latest: "0.6.0"))
    }

    @Test func withoutAPageTheReleasesListIsUsed() throws {
        let data = Data(#"{"tag_name":"0.7.0"}"#.utf8)
        #expect(try UpdateCheck.parse(data, current: "0.5.0") == .available(version: "0.7.0", page: BenchBarLinks.releases))
    }

    @Test func unreadableAnswersThrow() {
        #expect(throws: UpdateCheckError.unreadable) { try UpdateCheck.parse(Data("{}".utf8), current: "0.5.0") }
        #expect(throws: UpdateCheckError.unreadable) { try UpdateCheck.parse(Data("<html>".utf8), current: "0.5.0") }
        #expect(throws: UpdateCheckError.unreadable) { try UpdateCheck.parse(Data(#"{"tag_name":"nightly"}"#.utf8), current: "0.5.0") }
    }

    @Test func theRequestHasAUserAgentAndATimeout() {
        let request = UpdateCheck.request(appVersion: "0.5.0")
        #expect(request.url?.absoluteString == "https://api.github.com/repos/askysh/benchbar/releases/latest")
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 10)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("BenchBar/0.5.0") == true)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    }

    @Test func theCheckerShowsTheResultOrTheError() async throws {
        let data = try Fixture.data("github-release-latest")
        let seen = Box<URLRequest?>(nil)
        let checker = UpdateChecker(currentVersion: "0.5.0") { request throws(UpdateCheckError) in
            seen.value = request
            return data
        }
        #expect(checker.state == .idle)
        await checker.check()
        #expect(checker.state == .done(.available(version: "0.6.0", page: URL(string: "https://github.com/askysh/benchbar/releases/tag/v0.6.0")!)))
        #expect(seen.value?.value(forHTTPHeaderField: "User-Agent") != nil)

        let failing = UpdateChecker(currentVersion: "0.5.0") { _ throws(UpdateCheckError) in throw .http(403) }
        await failing.check()
        #expect(failing.state == .failed("GitHub is rate limiting this Mac; try again in a while."))
    }
}

nonisolated final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite("Links")
struct LinksTests {
    @Test func theBugReportIsPrefilled() throws {
        let url = BenchBarLinks.newBugReport(macOS: "macOS 27.0 (26A123)", app: "0.5.5", cli: "benchbar 0.5.5")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "github.com")
        #expect(parts.path == "/askysh/benchbar/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["template"] == "bug_report.yml")
        #expect(items["macos-version"] == "macOS 27.0 (26A123)")
        #expect(items["benchbar-version"] == "BenchBar 0.5.5, benchbar 0.5.5")
        #expect(!url.absoluteString.contains(" "))
    }

    @Test func withoutTheCLIOnlyTheAppVersion() throws {
        let url = BenchBarLinks.newBugReport(macOS: "macOS 27.0", app: "0.5.5", cli: nil)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.queryItems?.first { $0.name == "benchbar-version" }?.value == "BenchBar 0.5.5")
    }

    @Test func docsPagesAndCheckAnchors() {
        #expect(BenchBarLinks.docs.absoluteString == "https://benchbar.akashmishra.com/")
        #expect(BenchBarLinks.install.absoluteString == "https://benchbar.akashmishra.com/install/")
        #expect(BenchBarLinks.doctorCheck("env_python").absoluteString == "https://benchbar.akashmishra.com/guides/doctor-and-repair/#env_python")
    }

    @Test func theMacOSVersionReadsLikeAboutThisMac() {
        #expect(BenchBarLinks.macOSVersion.hasPrefix("macOS "))
    }
}

@Suite("Report a bug", .serialized)
struct BugReportTests {
    let base: BenchStoreTests
    init() throws { base = try BenchStoreTests() }

    @Test func theClientReadsReportJSON() async throws {
        let json = try Fixture.string("report")
        let runner = FakeRunner { _ in .ok(json) }
        let client = CLIClient(executable: URL(fileURLWithPath: "/fake/benchbar"), runner: runner)
        let file = try await client.report(bench: "/Users/you/frappe-bench")
        #expect(file.zip == "/Users/you/Desktop/benchbar-report-20260926-101500.zip")
        #expect(file.redactions == 14)
        #expect(runner.calls.first?.arguments == ["report", "--json", "--bench-dir", "/Users/you/frappe-bench"])
    }

    @Test func versionIsTheFirstLine() async throws {
        let runner = FakeRunner { _ in .ok("benchbar 0.5.5\nBenchBar app 0.5.5 (/Applications/BenchBar.app)\n") }
        let client = CLIClient(executable: URL(fileURLWithPath: "/fake/benchbar"), runner: runner)
        #expect(try await client.version() == "benchbar 0.5.5")
        #expect(CLIClient.firstLine("benchbar 0.5.0\n") == "benchbar 0.5.0")
    }

    @Test func createRevealsTheZipAndOpensTheIssue() async throws {
        base.cli.answer("list", json: base.listJSON())
        base.cli.answer("status", json: base.statusJSON("running"))
        base.cli.answer("--version", json: "benchbar 0.5.5\n")
        base.cli.answer("report", json: try Fixture.string("report"))
        let store = base.makeStore()
        await store.start(polling: false)
        let report = BugReport(store: store)
        report.macOS = "macOS 27.0"
        report.appVersion = "0.5.5"
        var revealed: [URL] = [], opened: [URL] = []
        report.reveal = { revealed.append($0) }
        report.openURL = { opened.append($0) }

        await report.create()

        let call = try #require(base.cli.calls.first { $0.first == "report" })
        #expect(call == ["report", "--json", "--bench-dir", base.benchPath])
        #expect(revealed == [URL(fileURLWithPath: "/Users/you/Desktop/benchbar-report-20260926-101500.zip")])
        let issue = try #require(opened.first)
        #expect(issue.absoluteString.contains("template=bug_report.yml"))
        #expect(issue.absoluteString.contains("benchbar-version=BenchBar%200.5.5,%20benchbar%200.5.5"))
        guard case .done(let file, _) = report.state else { Issue.record("expected done, got \(report.state)"); return }
        #expect(file.redactions == 14)
    }

    @Test func anOldCLISaysToUseTheTerminal() async throws {
        base.cli.answer("list", json: base.listJSON())
        base.cli.answer("status", json: base.statusJSON("running"))
        // 0.5.0 ignores --json and prints text and the path
        base.cli.answer("report", json: "[OK] report written: /Users/you/Desktop/benchbar-report.zip\n/Users/you/Desktop/benchbar-report.zip\n")
        let store = base.makeStore()
        await store.start(polling: false)
        let report = BugReport(store: store)
        var opened: [URL] = []
        report.reveal = { _ in Issue.record("nothing to reveal") }
        report.openURL = { opened.append($0) }
        await report.create()
        guard case .failed(let message, _) = report.state else { Issue.record("expected failed, got \(report.state)"); return }
        #expect(message.contains("Run benchbar report in Terminal"))
        #expect(opened.isEmpty, "the issue page opens only from the sheet's button after a failure")
        report.reset()
        #expect(report.state == .ready)
    }

    @Test func withoutTheCLIThereIsNoReport() async throws {
        base.settings.cliPath = ""
        let store = base.makeStore()
        await store.start(polling: false)
        let report = BugReport(store: store)
        await report.create()
        guard case .failed(let message, let issue) = report.state else { Issue.record("expected failed"); return }
        #expect(message.contains("not found"))
        #expect(issue.absoluteString.contains("macos-version="))
    }
}

@Suite("Menus")
struct MenuTests {
    @Test func theMainMenuEndsWithHelp() throws {
        let menu = AppDelegate().makeMainMenu()
        #expect(menu.items.map(\.title) == ["BenchBar", "Edit", "Window", "Help"])
        let help = try #require(menu.items.last?.submenu)
        #expect(help.items.filter { !$0.isSeparatorItem }.map(\.title) == ["BenchBar Documentation", "Keyboard Shortcuts", "Release Notes", "Report a Bug…"])
        let docs = try #require(help.items.first)
        #expect(docs.keyEquivalent == "?")
        #expect(docs.keyEquivalentModifierMask.contains(.command))
        #expect(NSApp.helpMenu === help)
        let app = try #require(menu.items.first?.submenu)
        #expect(app.items.map(\.title).contains("About BenchBar"))
        #expect(app.items.map(\.title).contains("Check for Updates…"))
    }

    @Test func theStatusItemMenuHasDocumentation() {
        let titles = AppDelegate().makeStatusMenu().items.map(\.title)
        #expect(titles.contains("Documentation"))
        #expect(titles.contains("About BenchBar"))
        #expect(titles.last == "Quit BenchBar")
    }
}
