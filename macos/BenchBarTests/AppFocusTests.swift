import Foundation
import Testing
@testable import BenchBar

@Suite("Focus apps and dependency freshness")
struct AppFocusTests {
    let base: BenchStoreTests
    let v16 = "/Users/you/dev/v16-bench"

    init() throws { base = try BenchStoreTests() }

    @Test func decodesFocusAndFreshness() throws {
        let list = try BenchJSON.decode(AppList.self, from: Fixture.data("app-list-focus"))
        let apps = Dictionary(uniqueKeysWithValues: list.apps.map { ($0.name, $0) })
        let ecr = try #require(apps["exponent_ecr"])
        #expect(ecr.isFocus && ecr.pin == .auto && ecr.requires == ["exponent_custom_v1"])
        #expect(ecr.focusSummary == "focus app: local changes, on feature/ecr-import, not develop, your commit today")
        #expect(ecr.dependencySummary == nil && !ecr.isStaleDependency, "a focus app is never a stale dependency")

        let dep = try #require(apps["exponent_custom_v1"])
        #expect(!dep.isFocus && dep.isStaleDependency)
        #expect(dep.dependencySummary == "needed by exponent_ecr, 30 commits / 12 days behind upstream/develop")

        let frappe = try #require(apps["frappe"])
        #expect(!frappe.isStaleDependency && frappe.dependencySummary == nil, "behind, but no focus app needs it")

        let hrms = try #require(apps["hrms"])
        #expect(hrms.pin == .ignore && hrms.behind == nil && hrms.upstream == nil)
    }

    @Test func anOlderCLIHasNoFocusFields() throws {
        let list = try BenchJSON.decode(AppList.self, from: Fixture.data("app-list"))
        #expect(list.apps.allSatisfy { $0.focus == nil && $0.pin == .auto && !$0.isFocus && $0.focusSummary == nil && $0.dependencySummary == nil })
    }

    @Test func pinsMapToTheCLIWords() {
        #expect(FocusPin.focus.arguments(app: "x") == ["app", "focus", "x"])
        #expect(FocusPin.ignore.arguments(app: "x") == ["app", "unfocus", "x"])
        #expect(FocusPin.auto.arguments(app: "x") == ["app", "focus", "x", "--auto"])
        var one = try? BenchJSON.decode(AppList.self, from: Fixture.data("app-list-focus")).apps[0]
        one?.focusPin = "something-new"
        #expect(one?.pin == .auto, "an unknown pin reads as auto")
    }

    @Test func dependencyWarningsKeepOneRowEach() throws {
        let report = try BenchJSON.decode(DoctorReport.self, from: Fixture.data("doctor-dependency-behind"))
        let rows = report.needsAttention.filter { $0.id == "dependency_behind" }
        #expect(rows.count == 2)
        #expect(Set(report.checks.map(\.rowKey)).count == report.checks.count, "rows are unique in a list")
        #expect(rows.allSatisfy { $0.level == .warn && $0.action == nil && $0.fixCommand?.hasPrefix("benchbar app update ") == true })
        #expect(report.passing.map(\.id) == ["apps_behind"])
    }

    @Test func settingAPinCallsTheCLIAndReadsTheListAgain() async throws {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites"))
        base.cli.answer("app", json: try Fixture.string("app-list-focus"))
        let store = base.makeStore()
        await store.start(polling: false)
        let bench = try #require(store.benches.first { $0.path == v16 })
        let workbench = Workbench(store: store)
        await workbench.setFocus(.ignore, app: "exponent_ecr", on: bench)
        #expect(base.cli.calls.contains(["app", "unfocus", "exponent_ecr", "--plain", "--bench-dir", v16]))
        #expect(base.cli.calls.contains(["app", "list", "--json", "--no-sites", "--bench-dir", v16]), "read again without asking MariaDB")
        #expect(workbench.result == nil, "a pin is not a change: no banner")
        #expect(bench.activity == nil)
        #expect(workbench.apps[v16]?.apps.count == 4)
    }

    @Test func checkRemotesFetchesThenReadsTheListAndDoctorNeverFetches() async throws {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites"))
        base.cli.answer("app", json: try Fixture.string("app-list-focus"))
        base.cli.answer("doctor", json: try Fixture.string("doctor-dependency-behind"))
        let store = base.makeStore()
        await store.start(polling: false)
        let bench = try #require(store.benches.first { $0.path == v16 })
        let workbench = Workbench(store: store)
        await workbench.checkRemotes(bench)
        #expect(base.cli.calls.contains(["app", "focus", "--fetch", "--json", "--bench-dir", v16]))
        #expect(base.cli.calls.contains(["app", "list", "--json", "--no-sites", "--bench-dir", v16]))
        #expect(workbench.checkingRemotes.isEmpty && workbench.result == nil)
        await store.runDoctor(on: bench)
        #expect(!base.cli.calls.contains { $0.first == "doctor" && $0.contains("--fetch") }, "doctor from the app stays read only")
    }

    @Test func aFailedPinShowsTheCLIMessage() async throws {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites"))
        base.cli.answer("app", .init(exitCode: 1, stdout: "[FAIL] nosuch is not an app of this bench.", stderr: ""))
        let store = base.makeStore()
        await store.start(polling: false)
        let bench = try #require(store.benches.first { $0.path == v16 })
        let workbench = Workbench(store: store)
        await workbench.setFocus(.focus, app: "nosuch", on: bench)
        #expect(workbench.appsError[v16]?.contains("not an app of this bench") == true)
    }
}
