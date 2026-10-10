import Foundation
import Testing
@testable import BenchBar

@Suite("Install and adopt streams")
struct InstallStreamTests {
    private func events(_ name: String) throws -> [InstallEvent] {
        try InstallEvent.decodeAll(try Fixture.lines(name))
    }

    private func progress(_ name: String) throws -> InstallProgress {
        var progress = InstallProgress()
        for event in try events(name) { progress.apply(event) }
        return progress
    }

    @Test func aSuccessfulInstallReadsPlanStepsProgressAndDone() throws {
        let all = try events("install-stream-success")
        guard case .plan(let plan)? = all.first else { Issue.record("the plan comes first"); return }
        #expect(plan.bench == "/Users/you/frappe-bench")
        #expect(plan.site == "macdev")
        #expect(plan.profile == "v15-lts")
        #expect(plan.teamProfile == nil)
        #expect(plan.bundle == "minimal")
        #expect(plan.portOffset == 0)
        #expect(plan.webURL == "http://macdev:8000")
        #expect(!plan.dryRun)
        #expect(plan.sudoMode == "gui")
        #expect(plan.steps.map(\.id) == ["wkhtmltopdf_install", "hosts_entry", "system_deps", "bench_site", "service"])
        #expect(plan.privilegedSteps.map(\.id) == ["wkhtmltopdf_install", "hosts_entry"])
        #expect(plan.steps[0].n == nil && plan.steps[2].n == 1)
        #expect(plan.log == "/Users/you/.local/state/benchbar/logs/20261010-101500-4242.log")

        let lines = all.compactMap { event -> InstallProgressLine? in if case .progress(let l) = event { l } else { nil } }
        #expect(lines.first == InstallProgressLine(step: "wkhtmltopdf_install", label: "download wkhtmltopdf 0.12.6-2 (about 50 MB)",
                                                   elapsed: 10, bytes: 31_457_280, total: nil))
        guard case .done(let done)? = all.last else { Issue.record("done comes last"); return }
        #expect(done.exit == 0)
        #expect(done.url == "http://macdev:8000")
        #expect(done.skipped.isEmpty)
        #expect(done.fix == nil)
    }

    @Test func nestedStepsSitUnderTheirParentWithTimings() throws {
        let p = try progress("install-stream-success")
        #expect(p.topLevel.map(\.id) == ["wkhtmltopdf_install", "hosts_entry", "system_deps", "bench_site", "service"])
        #expect(p.children(of: "system_deps").map(\.id) == ["python", "node"])
        #expect(p.children(of: "service").map(\.id) == ["build"])
        #expect(p.topLevel.first?.secs == 41)
        #expect(p.children(of: "system_deps").map(\.status) == [.done, .unchanged])
        #expect(p.topLevel.allSatisfy { $0.status == .done })
        #expect(p.done?.exit == 0)
        #expect(p.log == "/Users/you/.local/state/benchbar/logs/20261010-101500-4242.log")
    }

    @Test func theSameSectionIdUnderTwoParentsIsTwoRows() {
        var p = InstallProgress()
        p.apply(.step(InstallStep(id: "plan", parent: "system_deps", name: "PLAN", status: .done)))
        p.apply(.step(InstallStep(id: "plan", parent: "bench_site", name: "PLAN", status: .running)))
        #expect(p.rows.count == 2)
        #expect(Set(p.rows.map(\.key)).count == 2)
    }

    @Test func aProgressLineShowsUnderTheStepThatRuns() {
        var p = InstallProgress()
        p.apply(.plan(InstallPlan(bench: "/b", site: "s", steps: [InstallPlanStep(n: 1, id: "bench_site", name: "Bench and site")])))
        p.apply(.step(InstallStep(n: 1, id: "bench_site", name: "Bench and site", status: .running)))
        p.apply(.progress(InstallProgressLine(step: "bench_init", label: "bench init", elapsed: 30)))
        let row = p.topLevel[0]
        #expect(p.progress(for: row)?.label == "bench init", "a line for a step the stream never announced shows under the running one")
        p.apply(.step(InstallStep(n: 1, id: "bench_site", name: "Bench and site", status: .done, secs: 5)))
        #expect(p.progress(for: p.topLevel[0]) == nil)
    }

    @Test func aFailedInstallNamesTheStepItsMessageAndTheFix() throws {
        let p = try progress("install-stream-failed")
        let failed = try #require(p.failedStep)
        #expect(failed.id == "get_apps", "the nested step, not its parent")
        #expect(failed.message == "[FAIL] bench get-app erpnext failed (exit 1): see the log")
        #expect(p.done?.exit == 1)
        #expect(p.done?.fix?.contains("run the wizard again") == true)
    }

    @Test func aCancelledPasswordDialogIsASkippedStepWithItsCommand() throws {
        let p = try progress("install-stream-cancelled")
        let hosts = try #require(p.topLevel.first { $0.id == "hosts_entry" })
        #expect(hosts.status == .skipped)
        #expect(hosts.message?.contains("cancelled") == true)
        #expect(hosts.command == "benchbar site hosts --bench-dir /Users/you/frappe-bench")
        #expect(p.skippedWithCommand == [SkippedStep(id: "hosts_entry", command: "benchbar site hosts --bench-dir /Users/you/frappe-bench")])
        #expect(p.done?.exit == 0, "the run went on")
    }

    @Test func exitTwoIsTheMariaDBRootPassword() throws {
        let p = try progress("install-stream-exit2")
        #expect(p.done?.exit == 2)
        #expect(p.done?.fix?.contains("MARIADB_ROOT_PASSWORD") == true)
    }

    @Test func aDryRunIsThePlanThenDone() throws {
        let all = try events("install-dry-run")
        #expect(all.count == 2)
        guard case .plan(let plan) = all[0] else { Issue.record("plan"); return }
        #expect(plan.dryRun)
        #expect(plan.sudoMode == "terminal")
        #expect(plan.steps.count == 5)
        guard case .done(let done) = all[1] else { Issue.record("done"); return }
        #expect(done.exit == 0)
    }

    @Test func adoptIsTheSameStream() throws {
        let all = try events("adopt-stream-success")
        guard case .plan(let plan)? = all.first else { Issue.record("plan"); return }
        #expect(plan.portsMove == false)
        #expect(plan.steps.map(\.id) == ["runner", "launchagent", "hosts_entry"])
        #expect(plan.steps.map(\.n) == [1, 2, 3])
        #expect(plan.steps.last?.sudo == true)
        var p = InstallProgress()
        all.forEach { p.apply($0) }
        #expect(p.topLevel.map(\.status) == [.done, .done, .done])
        #expect(p.done?.url == "http://macdev:8000")
    }

    @Test func aPlanStepThatHasNothingToDoIsAlreadyDone() {
        var p = InstallProgress()
        p.apply(.plan(InstallPlan(bench: "/b", site: "s", steps: [
            InstallPlanStep(id: "hosts_entry", name: "Add the hosts line", sudo: true, willRun: false),
            InstallPlanStep(id: "wkhtmltopdf_install", name: "Install the package", sudo: true, willRun: true)])))
        #expect(p.rows.map(\.alreadyDone) == [true, false])
        #expect(p.rows.map(\.sudo) == [true, true])
    }

    // MARK: the schema rules

    @Test func unknownEventsFieldsAndStatusesAreIgnored() throws {
        #expect(try InstallEvent.decode(#"{"schema_version":1,"event":"heartbeat","n":3}"#) == nil)
        #expect(try InstallEvent.decode("not json at all") == nil)
        #expect(try InstallEvent.decode(#"{"schema_version":1}"#) == nil)
        let step = try #require(try InstallEvent.decode(#"{"schema_version":1,"event":"step","id":"x","name":"X","status":"paused-for-tea","colour":"red","secs":2.6}"#))
        guard case .step(let decoded) = step else { Issue.record("step"); return }
        #expect(decoded.status == .unknown)
        #expect(decoded.secs == 3, "a number with a fraction is rounded")
        let plan = try #require(try InstallEvent.decode(#"{"schema_version":1,"event":"plan","bench":"/b","site":"s","new_field":[1],"steps":[{"id":"a","name":"A","sudo":false,"will_run":true,"extra":1}]}"#))
        guard case .plan(let p) = plan else { Issue.record("plan"); return }
        #expect(p.steps.map(\.id) == ["a"])
        #expect(p.profile == nil)
    }

    @Test func aNewerSchemaIsRefusedLikeEverywhereElse() {
        #expect(throws: CLIError.unsupportedSchema(found: 2, supported: 1)) {
            try InstallEvent.decode(#"{"schema_version":2,"event":"step","id":"x","status":"done"}"#)
        }
    }

    @Test func theClientReportsANewerSchemaAfterTheRun() async throws {
        let runner = FakeRunner { _ in .ok(#"{"schema_version":2,"event":"done","exit":0}"# + "\n") }
        let client = CLIClient(executable: URL(fileURLWithPath: "/fake/benchbar"), runner: runner)
        await #expect(throws: CLIError.unsupportedSchema(found: 2, supported: 1)) {
            _ = try await client.install(InstallRequest(benchDir: "/b", profile: "v15-lts", bundle: "minimal", site: "s"),
                                         adminPassword: "pw") { _ in }
        }
    }

    // MARK: words

    @Test func durationsAndProgressRead() {
        #expect(InstallText.duration(41) == "41 s")
        #expect(InstallText.duration(95) == "1 min 35 s")
        #expect(InstallText.duration(3900) == "1 h 05 min")
        #expect(InstallText.progress(InstallProgressLine(step: "x", label: "download wkhtmltopdf", elapsed: 10, bytes: 31_457_280, total: 52_428_800))
                == "download wkhtmltopdf, 10 s, 31.5 MB of 52.4 MB")
        #expect(InstallText.progress(InstallProgressLine(step: "x", label: "bench init", elapsed: 30)) == "bench init, 30 s")
    }
}
