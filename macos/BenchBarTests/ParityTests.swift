import Foundation
import Testing
@testable import BenchBar

/// Mac app parity, part 2 (#177): several apps in one Add App plan, doctor acknowledgements, services only,
/// the background service, autostart and the command list. The documents are the CLI's own output
/// (fixtures recorded from the mocked CLI, kept in step by tests/test-json.sh); nothing here changes a bench.
@Suite("Mac app parity, part 2", .serialized)
struct ParityTests {
    let base: BenchStoreTests
    let v16 = "/Users/you/dev/v16-bench"

    init() throws { base = try BenchStoreTests() }

    func workbench() async throws -> (Workbench, BenchModel, FakeRunner) {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites"))
        let runner = base.cli.runner()
        let store = BenchStore(settings: base.settings,
                               locator: CLILocator(home: base.dir.url, isExecutable: { $0 == "/fake/benchbar" }),
                               makeClient: { CLIClient(executable: $0, runner: runner) },
                               pinger: { _, _ in 200 })
        await store.start(polling: false)
        return (Workbench(store: store), try #require(store.benches.first { $0.path == v16 }), runner)
    }

    func catalog() throws -> CommandCatalog {
        try BenchJSON.decode(CommandCatalog.self, from: Fixture.data("commands"))
    }

    // MARK: several apps in one plan (P14)

    @Test func theArgumentsGiveEachAppItsOwnOptions() {
        let entries = [AppAddEntry(source: " acme_crm ", branch: "main", commit: "9b1d2c4e", site: "macdev"),
                       AppAddEntry(source: "https://github.com/acme/acme_hr"),
                       AppAddEntry(source: "acme_pay", site: "site2")]
        #expect(AppAddBatch.arguments(entries) == ["acme_crm", "--branch", "main", "--commit", "9b1d2c4e", "--install-on", "macdev",
                                                   "https://github.com/acme/acme_hr", "acme_pay", "--install-on", "site2"])
    }

    @Test func theFormSaysWhatTheCLIWouldRefuse() {
        #expect(AppAddBatch.problem([AppAddEntry()]) == "Enter an app name or a git URL.")
        #expect(AppAddBatch.problem([AppAddEntry(source: "acme_crm")]) == nil)
        #expect(AppAddBatch.problem([AppAddEntry(source: "acme_crm", commit: "xyz")]) == "The commit must be 7 to 40 hex characters.")
        #expect(AppAddBatch.problem([AppAddEntry(source: "a", commit: "abc123"), AppAddEntry(source: "b")]) == "App 1: The commit must be 7 to 40 hex characters.")
        #expect(AppAddBatch.problem([AppAddEntry(source: "acme_crm"), AppAddEntry(source: "https://github.com/acme/acme_crm.git")]) == "acme_crm is listed twice.")
        #expect(AppAddBatch.problem([AppAddEntry(source: "acme_crm"), AppAddEntry()]) == nil, "an empty row is left out, not an error")
        #expect(AppAddBatch.title(["acme_crm"]) == "acme_crm" && AppAddBatch.title(["a", "b"]) == "a and b" && AppAddBatch.title(["a", "b", "c"]) == "3 apps")
    }

    @Test func decodesThePlanOfSeveralApps() throws {
        let plan = try BenchJSON.decode(AppAddPlan.self, from: Fixture.data("app-add-plan-many"))
        #expect(plan.isBatch && plan.appNames == ["acme_i1", "acme_i2"] && plan.commitSource == "pin")
        #expect(plan.apps?.map(\.installOn) == [["macdev"], ["macdev", "site2"]])
        let pin = try #require(plan.apps?.first?.commit?.prefix(7))
        #expect(plan.apps?.first?.summary == "branch main, commit \(pin) (pinned), install on macdev")
        #expect(plan.apps?.last?.summary.hasSuffix("install on macdev, site2") == true)
        #expect(plan.steps.map(\.kind) == ["clone", "clone", "build", "install", "install", "install", "restart"])
        #expect(plan.touches == ["apps/ and sites/apps.txt", "the bench's Python environment", "built assets", "the database of macdev, site2"])
        #expect(plan.canRun && plan.token.count == 64)
    }

    @Test func aPlanOfOneAppHasNoRows() throws {
        let plan = try BenchJSON.decode(AppAddPlan.self, from: Fixture.data("app-add-plan"))
        #expect(!plan.isBatch && plan.apps == nil && plan.appNames == ["acme_leaf"])
    }

    @Test func severalAppsAreOnePlanAndOneToken() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("app add", json: try Fixture.string("app-add-plan-many"))
        let entries = [AppAddEntry(source: "acme_i1", commit: "44973abd", site: "macdev"), AppAddEntry(source: "acme_i2", site: "macdev")]
        guard case .success(let plan) = await workbench.addAppPlan(entries, on: bench) else { Issue.record("no plan"); return }
        #expect(base.cli.calls.contains(["app", "add", "acme_i1", "--commit", "44973abd", "--install-on", "macdev", "acme_i2", "--install-on", "macdev",
                                         "--dry-run", "--json", "--bench-dir", v16]))
        await workbench.addApp(entries, token: plan.token, on: bench)
        let applies = base.cli.calls.filter { $0.starts(with: ["app", "add"]) && $0.contains("--apply") }
        #expect(applies == [["app", "add", "acme_i1", "--commit", "44973abd", "--install-on", "macdev", "acme_i2", "--install-on", "macdev",
                             "--apply", plan.token, "--yes", "--plain", "--bench-dir", v16]], "the apply carries the plan's arguments and its token")
        #expect(workbench.result?.title == "Add acme_i1 and acme_i2")
    }

    // MARK: acknowledge a warning (P27)

    @Test func readsWhichChecksAreAcknowledged() throws {
        let report = try BenchJSON.decode(DoctorReport.self, from: Fixture.data("doctor-acked"))
        let hosts = try #require(report.checks.first { $0.id == "hosts" })
        #expect(hosts.level == .warn && hosts.acked && !hosts.canAcknowledge)
        #expect(report.acknowledged.map(\.id) == ["hosts"] && report.needsAttention.isEmpty)
        #expect(report.summary.warn == 0 && report.summary.attention == nil, "the CLI still counts it as a warning; the app lists it apart")
        let open = try BenchJSON.decode(DoctorReport.self, from: Fixture.data("doctor-warn"))
        let again = try #require(open.checks.first { $0.id == "hosts" })
        #expect(again.level == .warn && !again.acked && again.canAcknowledge)
        #expect(open.needsAttention.map(\.id) == ["hosts"] && open.summary.warn == 1)
    }

    @Test func aFailureCannotBeAcknowledged() {
        let failing = DoctorCheck(id: "assets", group: nil, label: "Built assets", level: .fail, message: "missing", fixCommand: nil, action: nil)
        #expect(!failing.canAcknowledge)
        #expect(DoctorCheck(id: "x", group: nil, label: "x", level: .ok, message: "", fixCommand: nil, action: nil).canAcknowledge == false)
    }

    @Test func aReportFromAnOlderCLIHasNothingAcknowledged() throws {
        let report = try BenchJSON.decode(DoctorReport.self, from: Fixture.data("doctor"))
        #expect(report.acknowledged.isEmpty && report.checks.allSatisfy { !$0.acked })
    }

    @Test func acknowledgeAndUndoAreOneClickThenDoctorAgain() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("doctor", json: try Fixture.string("doctor-acked"))
        let check = DoctorCheck(id: "hosts", group: nil, label: "Hosts entry", level: .warn, message: "no entry", fixCommand: nil, action: nil)
        await workbench.acknowledge(check, on: true, bench: bench)
        #expect(base.cli.calls.contains(["doctor", "--ack", "hosts", "--json", "--bench-dir", v16]))
        #expect(bench.doctor?.acknowledged.map(\.id) == ["hosts"], "doctor is asked again after the call")
        await workbench.acknowledge(check, on: false, bench: bench)
        #expect(base.cli.calls.contains(["doctor", "--unack", "hosts", "--json", "--bench-dir", v16]))
    }

    @Test func aRefusedAcknowledgementIsTheCLIsSentence() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("doctor", .init(exitCode: 1, stdout: "", stderr: "[FAIL] assets is failing: only a warning can be acknowledged"))
        await workbench.acknowledge(DoctorCheck(id: "assets", group: nil, label: "x", level: .warn, message: "", fixCommand: nil, action: nil),
                                    on: true, bench: bench)
        #expect(workbench.parityError[v16] == "assets is failing: only a warning can be acknowledged")
    }

    // MARK: the command list (P45)

    @Test func theCatalogSaysWhichCommandsAndFlagsTheCLIHas() throws {
        let catalog = try catalog()
        // the fixture is the CLI's own answer, recorded again when the command table changes: a version, not a fixed one
        let version = try #require(catalog.cliVersion)
        #expect(version.range(of: #"^\d+\.\d+\.\d+(-rc\.\d+)?$"#, options: .regularExpression) != nil, "cli_version \(version)")
        #expect(catalog.has("service") && catalog.has("autostart") && catalog.has("doctor") && !catalog.has("nosuch"))
        #expect(catalog.hasFlag("up", "--services-only") && catalog.hasFlag("doctor", "--ack") && catalog.hasFlag("doctor", "--unack"))
        #expect(!catalog.hasFlag("up", "--nosuch") && !catalog.hasFlag("nosuch", "--ack"))
    }

    @Test func aCatalogEntryItCannotReadIsSkipped() throws {
        let json = #"{"schema_version":1,"cli_version":"9.0.0","commands":[{"name":"service","flags":[{"name":"--dry-run"},{"value":"x"}]},{"flags":[]},"junk",{"name":"autostart"}]}"#
        let catalog = try BenchJSON.decode(CommandCatalog.self, from: Data(json.utf8))
        #expect(catalog.commands.map(\.name) == ["service", "autostart"] && catalog.hasFlag("service", "--dry-run"))
    }

    @Test func theCommandListIsAskedOnce() async throws {
        let (workbench, _, _) = try await workbench()
        base.cli.answer("commands", json: try Fixture.string("commands"))
        await workbench.loadCommands()
        await workbench.loadCommands()
        #expect(workbench.commandState.catalog?.has("service") == true)
        #expect(base.cli.calls.filter { $0 == ["commands", "--json"] }.count == 1)
    }

    @Test func aFailedReadIsRememberedAndNoButtonOfANewerCommandShows() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("commands", .init(exitCode: 2, stdout: "", stderr: "[FAIL] Unknown command: commands"))
        await workbench.loadCommands()
        await workbench.loadCommands()
        guard case .failed(let why) = workbench.commandState else { Issue.record("the failure was not kept"); return }
        #expect(why == "Unknown command: commands" && workbench.commandState.catalog == nil)
        #expect(base.cli.calls.filter { $0 == ["commands", "--json"] }.count == 1, "the repeat does not ask again")
        workbench.store.setWindow(WindowSight(isOpen: true, isVisible: true))
        await workbench.showAutostart(bench)
        #expect(!base.cli.calls.contains { $0.first == "autostart" }, "a command the CLI does not list is never called")
    }

    // MARK: services only (P02)

    @Test func theStatusSaysWhetherTheBenchsRedisAnswers() throws {
        let status = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-stopped-services"))
        #expect(status.redis == RedisServices(queue: .init(port: 11000, running: false), cache: .init(port: 13000, running: false)))
        #expect(status.redis?.anyRunning == false && status.redis?.allRunning == false)
        let older = try BenchJSON.decode(BenchStatus.self, from: Fixture.data("status-running"))
        #expect(older.redis == nil)
        let odd = try BenchJSON.decode(BenchStatus.self, from: Data(try Fixture.string("status-stopped-services")
            .replacingOccurrences(of: #""queue":{"port":11000,"running":false}"#, with: #""queue":"x""#).utf8))
        #expect(odd.redis?.queue == .init(port: 0, running: false), "a field it cannot read is a server that does not answer")
    }

    @Test func startServicesOnlyAndStopServicesAreOneClickEach() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("up", .ok(try Fixture.lines("up-services-only")))
        base.cli.answer("down", .ok(""))
        await workbench.setServices(true, on: bench)
        #expect(base.cli.calls.contains(["up", "--services-only", "--plain", "--bench-dir", v16]))
        #expect(workbench.result == .init(title: "Start the services of v16-bench", error: nil, scope: v16))
        await workbench.setServices(false, on: bench)
        #expect(base.cli.calls.contains(["down", "--plain", "--bench-dir", v16]))
    }

    // MARK: the service (P39)

    @Test func decodesTheServicePlanFromTheFirstLine() throws {
        let plan = try ServiceInstallPlan.parse(stream: try Fixture.lines("service-plan"))
        #expect(plan.steps.map(\.id) == ["write_procfile", "write_runner", "write_plist", "write_helpers", "write_cli_link", "hosts_entry"])
        #expect(plan.pending.count == 6 && plan.needsPassword && plan.steps.last?.sudo == true)
        #expect(plan.token.count == 64 && plan.canRun && !plan.portsMove && plan.site == "macdev")
        var done = plan
        done.steps = done.steps.map { var step = $0; step.willRun = false; return step }
        #expect(!done.canRun && !done.needsPassword)
    }

    @Test func aStreamWithoutAPlanIsAnError() {
        #expect(throws: (any Error).self) { try ServiceInstallPlan.parse(stream: #"{"schema_version":1,"event":"done","exit":0}"#) }
    }

    @Test func theServicePlanIsReadOnlyAndTheApplyCarriesItsTokenAndTheGUIPasswordDialog() async throws {
        let (workbench, bench, runner) = try await workbench()
        base.cli.answer("service", .ok(try Fixture.lines("service-plan")))
        guard case .success(let plan) = await workbench.servicePlan(on: bench) else { Issue.record("no plan"); return }
        #expect(base.cli.calls.contains(["service", "--dry-run", "--json", "--bench-dir", v16]))
        #expect(bench.activity == nil && workbench.result == nil, "reading a plan takes no change slot and leaves no banner")
        base.cli.answer("service", .ok(try Fixture.lines("service-apply")))
        let error = await workbench.installService(token: plan.token, refresh: false, on: bench)
        #expect(error == nil)
        let apply = try #require(runner.calls.first { $0.arguments.contains("--apply") })
        #expect(apply.arguments == ["service", "--apply", plan.token, "--yes", "--plain", "--bench-dir", v16])
        #expect(apply.environment["BENCHBAR_SUDO"] == "gui", "a step that needs the password asks in macOS's own dialog")
        #expect(workbench.result?.title == "Install the service of v16-bench")
    }

    @Test func aStaleServiceTokenIsTheCLIsMessage() async throws {
        let (workbench, bench, _) = try await workbench()
        base.cli.answer("service", .init(exitCode: 1, stdout: "", stderr: "[FAIL] The service plan changed since it was shown (its actions, the ports or the scheduler). Nothing was changed."))
        let error = await workbench.installService(token: "old", refresh: true, on: bench)
        #expect(error.map(StalePlan.isStale) == true)
        var flow = PlanReviewFlow<ServiceInstallPlan>()
        _ = flow.review()
        flow.read(.success(try ServiceInstallPlan.parse(stream: try Fixture.lines("service-plan"))))
        #expect(flow.apply() != nil)
        #expect(!flow.finish(error: error) && flow.stage == .stale(error ?? ""))
    }

    // MARK: autostart (P04)

    @Test func autostartIsReadFromTheWordsTheCLIPrints() throws {
        #expect(AutostartText.parse(try Fixture.text("autostart-on", ext: "txt")) == true)
        #expect(AutostartText.parse(try Fixture.text("autostart-off", ext: "txt")) == false)
        #expect(AutostartText.parse("something else") == nil && AutostartText.parse("") == nil)
    }

    @Test func autostartIsReadOnlyWhenTheCLIHasTheCommandAndSetOnAClick() async throws {
        let (workbench, bench, _) = try await workbench()
        workbench.store.setWindow(WindowSight(isOpen: true, isVisible: true))
        base.cli.answer("autostart", .ok(try Fixture.text("autostart-on", ext: "txt")))
        await workbench.showAutostart(bench)
        #expect(workbench.autostartOn[v16] == nil && !base.cli.calls.contains { $0.first == "autostart" }, "no command list yet: nothing is asked")
        base.cli.answer("commands", json: try Fixture.string("commands"))
        await workbench.loadCommands()
        await workbench.showAutostart(bench)
        #expect(base.cli.calls.contains(["autostart", "--plain", "--bench-dir", v16]))
        #expect(workbench.autostartOn[v16] == true)
        base.cli.answer("autostart", .ok("  [OK] autostart off\n"))
        await workbench.setAutostart(false, on: bench)
        #expect(base.cli.calls.contains(["autostart", "off", "--plain", "--bench-dir", v16]))
        #expect(workbench.autostartOn[v16] == false)
    }
}
