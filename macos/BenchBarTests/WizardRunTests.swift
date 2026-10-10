import Foundation
import Testing
@testable import BenchBar

/// A runner whose stream waits until it is cancelled, like an install that runs.
nonisolated final class HangingRunner: CommandRunning, @unchecked Sendable {
    let inner: FakeRunner
    init(_ inner: FakeRunner) { self.inner = inner }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws(CLIError) -> CommandOutput {
        try await inner.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
    }

    func stream(executable: URL, arguments: [String], environment: [String: String], timeout: Duration,
                onLine: @escaping @Sendable (String) -> Void) async throws(CLIError) -> Int32 {
        _ = try? await inner.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            throw .timedOut(command: "install", seconds: 1)
        }
        return 0
    }
}

@Suite("Wizard run", .serialized)
struct WizardRunTests {
    let base: BenchStoreTests
    init() throws {
        base = try BenchStoreTests()
        base.cli.answer("list", json: try Fixture.string("list-empty"))
        base.cli.answer("doctor", json: try Fixture.string("doctor-prerequisites"))
        base.cli.answer("profile", json: try Fixture.string("profile-list-wizard"))
    }

    func makeRun(runner: (any CommandRunning)? = nil) async -> (WizardRun, FakeRunner) {
        let fake = base.cli.runner()
        let store = base.makeStore(runner: runner ?? fake)
        await store.start(polling: false)
        return (WizardRun(store: store, state: WizardState(home: "/Users/you")), fake)
    }

    func reachReview(_ run: WizardRun) async throws {
        run.send(.chooseNewBench)
        await base.waitUntil { run.state.prerequisites != nil }
        run.send(.primary)
        await base.waitUntil { run.state.profilesLoaded }
        run.send(.setAdminPassword("s3cret pw"))
        run.send(.primary)
        await base.waitUntil { run.state.plan != nil }
    }

    func stream(_ name: String, exit: Int32 = 0) throws -> CommandOutput {
        CommandOutput(exitCode: exit, stdout: try Fixture.lines(name), stderr: "")
    }

    /// A dry run that sends its plan and then ends with exit 1 (no free port
    /// block, a profile ref that is gone) gives nothing to review.
    @Test func aDryRunThatEndsInAFailureIsNoPlan() async throws {
        let (run, _) = await makeRun()
        let plan = try Fixture.lines("install-dry-run").split(separator: "\n").first.map(String.init) ?? ""
        let done = #"{"schema_version":1,"cli_version":"0.8.0","event":"done","exit":1,"bench":"/Users/you/frappe-bench","site":"macdev","url":null,"skipped":[],"fix":"no port block between 0 and 50 is free","log":null}"#
        base.cli.answer("install", CommandOutput(exitCode: 1, stdout: plan + "\n" + done + "\n", stderr: ""))
        run.send(.chooseNewBench)
        await base.waitUntil { run.state.prerequisites != nil }
        run.send(.primary)
        await base.waitUntil { run.state.profilesLoaded }
        run.send(.setAdminPassword("s3cret pw"))
        run.send(.primary)
        await base.waitUntil { run.state.planError != nil }
        #expect(run.state.plan == nil)
        #expect(run.state.planError?.contains("no port block") == true)
    }

    @Test func thePasswordAndGuiSudoGoToTheInstallProcessOnly() async throws {
        let (run, fake) = await makeRun()
        base.cli.answer("install", try stream("install-dry-run"))
        try await reachReview(run)
        #expect(run.state.page == .review)
        base.cli.answer("install", try stream("install-stream-success"))
        run.send(.primary)
        await base.waitUntil { run.state.page == .done }
        #expect(run.state.page == .done)
        #expect(run.state.siteURL == "http://macdev:8000")

        let real = try #require(fake.calls.last { $0.arguments.starts(with: ["install", "--yes"]) })
        #expect(real.arguments == ["install", "--yes", "--json", "--bench-dir", "/Users/you/frappe-bench", "--profile", "v15-lts",
                                   "--bundle", "minimal", "--site", "macdev", "--port-offset", "1"])
        #expect(real.environment["ADMIN_PASSWORD"] == "s3cret pw")
        #expect(real.environment["BENCHBAR_SUDO"] == "gui")
        #expect(real.environment["MARIADB_ROOT_PASSWORD"] == nil)
        #expect(!fake.calls.flatMap(\.arguments).contains { $0.contains("s3cret") })

        let dry = try #require(fake.calls.first { $0.arguments.contains("--dry-run") })
        #expect(dry.arguments.starts(with: ["install", "--dry-run", "--json"]))
        #expect(dry.environment["ADMIN_PASSWORD"] == "s3cret pw")
        #expect(dry.environment["BENCHBAR_SUDO"] == nil)
        for call in fake.calls where call != real && call != dry {
            #expect(call.environment["ADMIN_PASSWORD"] == nil, "\(call.arguments) must not carry the password")
            #expect(call.environment["BENCHBAR_SUDO"] == nil, "\(call.arguments) must not ask for the dialog")
        }
        #expect(fake.calls.contains { $0.arguments.starts(with: ["doctor", "--prerequisites", "--json", "--bench-dir", "/Users/you/frappe-bench"]) })
        #expect(base.cli.calls.contains(["profile", "list", "--json"]))
    }

    @Test func exitTwoThenRetryWithTheRootPassword() async throws {
        let (run, fake) = await makeRun()
        base.cli.answer("install", try stream("install-dry-run"))
        try await reachReview(run)
        base.cli.answer("install", try stream("install-stream-exit2", exit: 2))
        run.send(.primary)
        await base.waitUntil { if case .needsRootPassword = run.state.installPhase { true } else { false } }
        guard case .needsRootPassword = run.state.installPhase else { Issue.record("exit 2 expected"); return }
        #expect(run.store.busyBench == nil, "the change slot is free again")
        run.send(.setRootPassword("root pw"))
        base.cli.answer("install", try stream("install-stream-success"))
        run.send(.retry)
        await base.waitUntil { run.state.page == .done }
        let installs = fake.calls.filter { $0.arguments.starts(with: ["install", "--yes"]) }
        #expect(installs.count == 2)
        #expect(installs[0].environment["MARIADB_ROOT_PASSWORD"] == nil)
        #expect(installs[1].environment["MARIADB_ROOT_PASSWORD"] == "root pw")
        #expect(!installs[1].arguments.joined().contains("root pw"))
    }

    @Test func theInstallHoldsTheChangeSlotAndStopFreesIt() async throws {
        let fake = base.cli.runner()
        let (run, _) = await makeRun(runner: HangingRunner(fake))
        base.cli.answer("install", try stream("install-dry-run"))
        try await reachReview(run)
        run.send(.primary)
        await base.waitUntil { run.store.busyBench != nil }
        #expect(run.store.busyBench != nil)
        #expect(!run.canStartChange)
        #expect(run.store.busyBench?.activity == "Installing macdev")
        run.send(.stop)
        await base.waitUntil { run.state.installPhase == .stopped }
        #expect(run.state.installPhase == .stopped)
        await base.waitUntil { run.store.busyBench == nil }
        #expect(run.store.busyBench == nil)
    }

    @Test func aStopBeforeTheProcessStartsMeansNoInstallCall() async throws {
        let (run, fake) = await makeRun()
        base.cli.answer("install", try stream("install-dry-run"))
        try await reachReview(run)
        base.cli.answer("install", try stream("install-stream-success"))
        run.send(.primary)
        run.send(.stop)
        await base.waitUntil { run.state.installPhase == .stopped }
        #expect(run.state.installPhase == .stopped)
        #expect(!fake.calls.contains { $0.arguments.starts(with: ["install", "--yes"]) }, "the install never started")
        await base.waitUntil { run.store.busyBench == nil }
        #expect(run.store.busyBench == nil)
    }

    @Test func commandLineToolsArePolledOnlyWhileTheRowFailsAndThePageShows() async throws {
        let (run, _) = await makeRun()
        run.pollInterval = .milliseconds(20)
        run.windowIsVisible = { true }
        var failing = try BenchJSON.decode(PrerequisiteReport.self, from: try Fixture.data("doctor-prerequisites"))
        failing.prerequisites[2].level = .fail
        failing.prerequisites[2].fixCommand = "xcode-select --install"
        let failJSON = String(decoding: try JSONEncoder().encode(failing), as: UTF8.self)
        base.cli.answer("doctor", json: failJSON)
        run.send(.chooseNewBench)
        await base.waitUntil { run.state.shouldPoll }
        #expect(run.isPolling)
        base.cli.answer("doctor", json: try Fixture.string("doctor-prerequisites"))
        await base.waitUntil { !run.state.shouldPoll }
        #expect(!run.state.shouldPoll)
        await base.waitUntil { !run.isPolling }
        #expect(!run.isPolling)
        let count = base.cli.calls.filter { $0.first == "doctor" }.count
        try await Task.sleep(for: .milliseconds(120))
        #expect(base.cli.calls.filter { $0.first == "doctor" }.count == count, "no more calls once the row passes")
    }

    @Test func theLogTailIsBounded() async {
        let (run, _) = await makeRun()
        run.append((1...450).map { "line \($0)" }.joined(separator: "\n") + "\n")
        #expect(run.logLines.count == WizardRun.logLineLimit)
        #expect(run.logLines.last == "line 450")
        run.append(String(repeating: "x", count: 900) + "\n")
        #expect(run.logLines.last?.count == WizardRun.logLineLength + 1)
    }

    @Test func repairAsksForTheDialogToo() async throws {
        let fake = base.cli.runner()
        base.cli.answer("repair", CommandOutput.ok(#"{"event":"done","exit_code":0}"# + "\n"))
        let client = CLIClient(executable: URL(fileURLWithPath: "/fake/benchbar"), runner: fake)
        _ = try await client.repair(bench: "/b") { _ in }
        #expect(fake.calls.last?.environment["BENCHBAR_SUDO"] == "gui")
    }
}

@Suite("Add hosts lines", .serialized)
struct HostsTests {
    let base: BenchStoreTests
    init() throws { base = try BenchStoreTests() }

    func store() async throws -> (BenchStore, FakeRunner) {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", json: try Fixture.string("status-v16-two-sites"))
        let runner = base.cli.runner()
        let store = base.makeStore(runner: runner)
        await store.start(polling: false)
        return (store, runner)
    }

    @Test func classifiesTheOutput() {
        #expect(HostsOutcome.classify(.ok("[OK] added\n")) == .added)
        #expect(HostsOutcome.classify(.ok("[WARN] the password dialog was cancelled; the line was not added\n")) != .added)
        #expect(HostsOutcome.classify(CommandOutput(exitCode: 1, stdout: "", stderr: "[FAIL] no sudo")) == .failed("[FAIL] no sudo"))
    }

    @Test func runsSiteHostsWithTheDialogAndFallsBackToTheCommand() async throws {
        let (store, runner) = try await store()
        let bench = try #require(store.benches.first { $0.path == "/Users/you/dev/v16-bench" })
        base.cli.answer("site", .ok("[WARN] the password dialog was cancelled; the line was not added\n"))
        let run = HostsRun(bench: bench, store: store)
        await run.run()
        guard case .skipped = run.phase else { Issue.record("skipped expected, got \(run.phase)"); return }
        #expect(run.command == "benchbar site hosts --bench-dir /Users/you/dev/v16-bench")
        let call = try #require(runner.calls.first { $0.arguments.starts(with: ["site", "hosts"]) })
        #expect(call.arguments == ["site", "hosts", "--yes", "--bench-dir", "/Users/you/dev/v16-bench"])
        #expect(call.environment["BENCHBAR_SUDO"] == "gui")
        #expect(runner.calls.filter { $0.environment["BENCHBAR_SUDO"] != nil }.count == 1)
        base.cli.answer("site", .ok("[OK] added\n"))
        await run.run()
        #expect(run.phase == .added)
        #expect(bench.activity == nil)
    }
}
