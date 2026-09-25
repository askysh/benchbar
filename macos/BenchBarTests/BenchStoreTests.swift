import Foundation
import Testing
@testable import BenchBar

/// A CLI whose answers a test can change between calls.
nonisolated final class ScriptedCLI: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: CommandOutput] = [:]
    private var log: [[String]] = []

    func answer(_ command: String, _ output: CommandOutput) { lock.withLock { answers[command] = output } }
    func answer(_ command: String, json: String) { answer(command, .ok(json)) }
    /// An answer for one bench only (matched on --bench-dir), before the general one.
    func answer(_ command: String, bench: String, json: String) { answer("\(command)|\(bench)", .ok(json)) }
    var calls: [[String]] { lock.withLock { log } }

    func runner() -> FakeRunner {
        FakeRunner { [self] arguments throws(CLIError) in
            lock.withLock {
                log.append(arguments)
                if let i = arguments.firstIndex(of: "--bench-dir"), i + 1 < arguments.count,
                   let perBench = answers["\(arguments[0])|\(arguments[i + 1])"] {
                    return perBench
                }
                return answers[arguments[0]] ?? CommandOutput(exitCode: 1, stdout: "", stderr: "[FAIL] no scripted answer for \(arguments[0])")
            }
        }
    }
}

@Suite("Bench store", .serialized)
struct BenchStoreTests {
    let dir: TempDir
    let cli = ScriptedCLI()
    let settings: AppSettings

    init() throws {
        dir = try TempDir()
        let defaults = UserDefaults(suiteName: "benchbar-tests-\(UUID().uuidString)")!
        settings = AppSettings(defaults: defaults)
        settings.cliPath = "/fake/benchbar"
    }

    var benchPath: String { dir.url.appendingPathComponent("frappe-bench").path }

    func listJSON(installed: Bool = true) -> String {
        """
        {"schema_version":1,"cli_version":"0.3.0","default_bench":"\(benchPath)","benches":[{"path":"\(benchPath)","name":"frappe-bench","site":"macdev","label":"com.benchbar.frappe-bench","web_url":"http://macdev:8000","ports":{"web":8000,"socketio":9000,"redis_queue":11000,"redis_cache":13000},"default":true,"service_installed":\(installed),"state_file":"\(benchPath)/logs/.benchbar/state.json"}]}
        """
    }

    func statusJSON(_ state: String, reason: String? = nil, exit: Int? = nil) -> String {
        let r = reason.map { "\"\($0)\"" } ?? "null"
        let e = exit.map(String.init) ?? "null"
        return #"{"schema_version":1,"bench":"\#(benchPath)","state":"\#(state)","stop_reason":\#(r),"pid":null,"started_at":"2026-09-23T10:00:00Z","last_exit_code":\#(e),"web_url":"http://macdev:8000","web_ping_code":null}"#
    }

    func makeStore(ping: Int? = 200) -> BenchStore {
        let runner = cli.runner()
        return BenchStore(
            settings: settings,
            locator: CLILocator(home: dir.url, isExecutable: { $0 == "/fake/benchbar" }),
            makeClient: { CLIClient(executable: $0, runner: runner) },
            pinger: { _, _ in ping })
    }

    func settle() async {
        for _ in 0..<10 { await Task.yield(); try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func loadsBenchesAndTheirState() async {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("running"))
        let store = makeStore()
        await store.start(polling: false)
        #expect(store.cli == .ready(URL(fileURLWithPath: "/fake/benchbar")))
        #expect(store.benches.map(\.name) == ["frappe-bench"])
        #expect(store.selected?.path == benchPath)
        #expect(store.displayState == .running)
        #expect(settings.selectedBench == benchPath)
    }

    @Test func missingCLIShowsUnknown() async {
        settings.cliPath = ""
        let store = makeStore()
        await store.start(polling: false)
        guard case .missing = store.cli else { Issue.record("expected missing CLI"); return }
        #expect(store.displayState == .unknown)
        #expect(cli.calls.isEmpty)
    }

    @Test func startRunsUpThenPingsAndRefreshes() async {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("stopped", reason: "manual"))
        cli.answer("up", .ok("[OK] bench is up"))
        let store = makeStore()
        await store.start(polling: false)
        let bench = try! #require(store.selected)
        #expect(bench.state == .stopped)

        cli.answer("status", json: statusJSON("running"))
        await store.perform(.up, on: bench)
        await settle()
        #expect(cli.calls.contains(["up", "--plain", "--bench-dir", benchPath]))
        #expect(bench.state == .running)
        #expect(bench.lastError == nil)
    }

    @Test func failedActionKeepsTheMessage() async {
        cli.answer("list", json: listJSON(installed: false))
        cli.answer("status", json: statusJSON("stopped", reason: "manual"))
        cli.answer("up", CommandOutput(exitCode: 1, stdout: "", stderr: "Aborting. The background service for frappe-bench is not installed."))
        let store = makeStore()
        await store.start(polling: false)
        let bench = try! #require(store.selected)
        #expect(bench.needsService)
        await store.perform(.up, on: bench)
        await settle()
        #expect(bench.lastError?.contains("not installed") == true)
        #expect(bench.state == .stopped)
    }

    @Test func stateFileChangesAlertOnCrash() async throws {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("running"))
        let store = makeStore()
        var alerts: [BenchAlert] = []
        store.onAlert = { _, alert in alerts.append(alert) }
        await store.start(polling: false)
        let bench = try #require(store.selected)

        // the runner writes crashed; the CLI agrees
        try dir.write("frappe-bench/logs/.benchbar/state.json", statusJSON("crashed", reason: "crash", exit: 1))
        cli.answer("status", json: statusJSON("crashed", reason: "crash", exit: 1))
        await store.stateFileChanged(bench)
        #expect(bench.state == .crashed)
        #expect(alerts == [.crashed(exitCode: 1)])

        cli.answer("status", json: statusJSON("paused", reason: "crash"))
        await store.refresh(bench)
        #expect(alerts == [.crashed(exitCode: 1), .crashGuardTripped])
    }

    @Test func doctorReportIsKept() async throws {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("stopped", reason: "manual"))
        cli.answer("doctor", CommandOutput(exitCode: 1, stdout: try Fixture.string("doctor"), stderr: ""))
        let store = makeStore()
        await store.start(polling: false)
        let bench = try #require(store.selected)
        await store.runDoctor(on: bench)
        #expect(bench.doctor?.summary.fail == 1)
        #expect(bench.isRunningDoctor == false)
    }
}
