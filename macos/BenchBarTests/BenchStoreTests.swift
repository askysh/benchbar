import AppKit
import Foundation
import Observation
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
                if arguments.count > 1, let subcommand = answers["\(arguments[0]) \(arguments[1])"] { return subcommand }
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
        cli.answer("ports", json: #"{"schema_version":1,"conflicts":[],"mode":"automatic"}"#)
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

    /// `running` with the runner's pid, as status says while the bench runs.
    func runningJSON(pid: Int = 4242) -> String {
        statusJSON("running").replacingOccurrences(of: #""pid":null"#, with: "\"pid\":\(pid)")
    }

    /// What the runner writes to state.json.
    func fileStatus(_ state: BenchState, reason: StopReason? = nil, pid: Int32? = nil, exit: Int? = nil) -> BenchStatus {
        BenchStatus(schemaVersion: 1, bench: benchPath, state: state, stopReason: reason, pid: pid, lastExitCode: exit, source: "runner")
    }

    /// The real files by default (a temp folder without state.json), and a
    /// safety poll that only fires when a test says so. `pinged` is set when
    /// the store pings a site.
    func makeStore(ping: Int? = 200,
                   pinged: Flag? = nil,
                   snapshotter: @escaping @Sendable (Int32) async -> ProcessTree.Snapshot = { _ in ProcessTree.Snapshot(takenAt: 0, cpu: [:]) },
                   files: any BenchFiles = LiveBenchFiles(),
                   safetyPoll: any SafetyPolling = ManualSafetyPoll(),
                   sleeper: any PollSleeper = TaskSleeper(),
                   now: @escaping () -> Date = Date.init,
                   runner: (any CommandRunning)? = nil) -> BenchStore {
        let runner = runner ?? cli.runner()
        return BenchStore(
            settings: settings,
            locator: CLILocator(home: dir.url, isExecutable: { $0 == "/fake/benchbar" }),
            makeClient: { CLIClient(executable: $0, runner: runner) },
            pinger: { _, _ in pinged?.set(); return ping },
            snapshotter: snapshotter,
            files: files,
            safetyPoll: safetyPoll,
            sleeper: sleeper,
            now: now)
    }

    /// Waits (5 seconds at most) for what a loop does on its own.
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func samplesResourcesOnlyWhileRunning() async {
        let clock = SnapshotClock()
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("running").replacingOccurrences(of: #""pid":null"#, with: #""pid":4242"#))
        let store = makeStore(snapshotter: { pid in clock.next(pid) })
        await store.start(polling: false)
        let bench = store.benches[0]
        #expect(bench.resources.history.isEmpty)  // the first refresh is the baseline
        await store.refresh(bench)
        #expect(bench.resources.history.samples.count == 1)
        #expect(bench.resources.history.latest?.memoryBytes == 64 << 20)
        #expect(clock.pids == [4242, 4242])

        cli.answer("status", json: statusJSON("stopped", reason: "manual"))
        await store.refresh(bench)
        #expect(clock.pids.count == 2)
        #expect(!bench.resources.isTracking)
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

    @Test(arguments: [CLIClient.Action.up, .restart])
    func aPortConflictPreventsStarting(_ action: CLIClient.Action) async throws {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("stopped", reason: "manual"))
        cli.answer("ports", json: #"{"schema_version":1,"conflicts":["8000 is used by another app"],"mode":"automatic"}"#)
        cli.answer("up", .ok("started"))
        let store = makeStore()
        await store.start(polling: false)
        let bench = try #require(store.selected)
        await store.perform(action, on: bench)
        #expect(!cli.calls.contains { $0.first == action.rawValue })
        #expect(bench.lastError?.contains("8000") == true)
    }

    @Test(arguments: [CLIClient.Action.up, .restart])
    func ownedRunningBenchSkipsConflictsOnlyForIdempotentUp(_ action: CLIClient.Action) async throws {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("running"))
        cli.answer("ports", json: #"{"schema_version":1,"conflicts":["8000 overlaps a stopped bench"],"mode":"automatic","already_running":true}"#)
        cli.answer("up", .ok("already running"))
        let store = makeStore()
        await store.start(polling: false)
        let bench = try #require(store.selected)
        await store.perform(action, on: bench)
        #expect(cli.calls.contains { $0.first == action.rawValue } == (action == .up))
        #expect((bench.portConflict == nil) == (action == .up))
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

    // MARK: 0.6.1: events, not a clock

    /// The bench this release is for: a runner that beats. Its folder watcher
    /// tells of each transition, and nothing asks the CLI on a clock.
    @Test func aBeatingRunnerNeedsNoCLICallForTenMinutes() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(fileStatus(.running, pid: 4242), heartbeat: .beating(since: time.now), alive: [4242])
        let poll = ManualSafetyPoll()
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore(files: files, safetyPoll: poll, sleeper: time, now: { time.now })
        await store.start()
        defer { store.suspend(); time.wake() }
        let bench = try #require(store.selected)
        #expect(store.trust[benchPath] == .heartbeat)
        #expect(poll.isStarted)
        let atLaunch = cli.calls.count
        #expect(atLaunch == 2, "list and one status at launch")

        // ten minutes: the safety poll comes twice, the runner beats on
        for _ in 0..<2 {
            time.advance(by: 300)
            await poll.fire()
        }
        #expect(cli.calls.count == atLaunch, "no CLI call in ten minutes")
        #expect(time.sleeps.isEmpty, "no timer of any kind")
        #expect(bench.state == .running)

        // a transition is a new write to the folder: the file is the truth
        var alerts: [BenchAlert] = []
        store.onAlert = { _, alert in alerts.append(alert) }
        files.set(fileStatus(.crashed, reason: .crash, exit: 1))
        await store.stateFileChanged(bench)
        #expect(bench.state == .crashed)
        #expect(alerts == [.crashed(exitCode: 1)])
        #expect(store.trust[benchPath] == .terminal)
        #expect(cli.calls.count == atLaunch)
    }

    /// stopped, crashed or paused: no timer either. The safety poll asks the
    /// CLI, the only one to see a bench started by hand.
    @Test func aStoppedBenchIsTakenFromItsFileAndAskedBySafetyPollOnly() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(fileStatus(.stopped, reason: .manual))
        let poll = ManualSafetyPoll()
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("stopped", reason: "manual"))
        let store = makeStore(files: files, safetyPoll: poll, sleeper: time, now: { time.now })
        await store.start()
        defer { store.suspend(); time.wake() }
        let bench = try #require(store.selected)
        #expect(store.trust[benchPath] == .terminal)
        let atLaunch = cli.calls.count

        files.set(fileStatus(.paused, reason: .crash))
        await store.stateFileChanged(bench)
        #expect(bench.state == .paused)
        #expect(cli.calls.count == atLaunch, "a final state is taken from the file")

        for _ in 0..<2 {
            time.advance(by: 300)
            await poll.fire()
        }
        #expect(time.sleeps.isEmpty)
        #expect(cli.calls.dropFirst(atLaunch).map { $0.first } == ["status", "status"])
    }

    /// A runner from before 0.6.1 does not beat: the CLI once a minute, as
    /// long as that lasts, and never a loop that cancels a call it started.
    @Test func aRunnerWithoutAHeartbeatAsksTheCLIEveryMinute() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(fileStatus(.running, pid: 4242), alive: [4242])
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore(files: files, sleeper: time, now: { time.now })
        let start = time.now
        await store.start()
        defer { store.suspend(); time.wake() }
        #expect(store.trust[benchPath] == .legacy(.noHeartbeat))
        let atLaunch = cli.calls.count
        for _ in 0..<10 {
            await waitUntil { time.isWaiting }
            time.wake()
        }
        await waitUntil { time.isWaiting }
        let polled = cli.calls.dropFirst(atLaunch)
        #expect(polled.count == 10, "one status a minute for ten minutes")
        #expect(polled.allSatisfy { $0.first == "status" })
        #expect(time.now.timeIntervalSince(start) == 600)
        #expect(time.sleeps.allSatisfy { $0 == BenchStore.legacyInterval })
    }

    @Test func theMinuteLoopEndsWhenTheRunnerBeats() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(fileStatus(.running, pid: 4242), alive: [4242])
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore(files: files, sleeper: time, now: { time.now })
        await store.start()
        defer { store.suspend(); time.wake() }
        let bench = try #require(store.selected)
        await waitUntil { time.isWaiting }

        // benchbar restart: the new runner writes its first beat, then starting
        files.set(heartbeat: .beating(since: time.now))
        await store.stateFileChanged(bench)
        #expect(store.trust[benchPath] == .heartbeat)
        let after = cli.calls.count
        time.wake()
        await waitUntil { !time.isWaiting && !store.isRunningLegacyLoop }
        #expect(!store.isRunningLegacyLoop)
        #expect(cli.calls.count == after, "the last round found nothing to ask")
        #expect(time.sleeps.count == 1)
    }

    /// Sleep and screen lock stop the loops between rounds: the status call
    /// a round started finishes (a cancel would SIGTERM bash and show a
    /// fake "timed out").
    @Test func aSuspendNeverCancelsTheCallInFlight() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(fileStatus(.running, pid: 4242), alive: [4242])
        let held = HeldCLI(["list": listJSON(), "status": runningJSON()])
        let store = makeStore(files: files, sleeper: time, now: { time.now }, runner: held)
        await store.start()
        let bench = try #require(store.selected)
        held.hold = true
        await waitUntil { time.isWaiting }
        time.wake()
        await waitUntil { held.isHolding }
        #expect(held.isHolding, "the minute loop is in its status call")
        store.suspend()
        store.setPopoverOpen(true)
        store.setPopoverOpen(false)
        held.release()
        await waitUntil { held.finished == 1 }
        #expect(held.finished == 1)
        #expect(held.cancelled == 0)
        #expect(bench.refreshError == nil)
        #expect(bench.state == .running)
        time.wake()
    }

    /// The 0.6.0 bug: opening the popover or changing the interval cancelled
    /// the poll's task group mid call. No screen or mode change may.
    @Test func noScreenOrModeChangeCancelsTheCallInFlight() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(fileStatus(.running, pid: 4242), alive: [4242])
        let held = HeldCLI(["list": listJSON(), "status": runningJSON()])
        let store = makeStore(files: files, sleeper: time, now: { time.now }, runner: held)
        await store.start()
        defer { store.suspend(); time.wake() }
        let bench = try #require(store.selected)
        held.hold = true
        await waitUntil { time.isWaiting }
        time.wake()
        await waitUntil { held.isHolding }
        #expect(held.isHolding, "the minute loop is in its status call")

        store.setPopoverOpen(true)
        store.setPopoverOpen(false)
        store.setWindow(WindowSight(isOpen: true, isVisible: true, overview: benchPath))
        store.setWindow(WindowSight())
        // the runner beats now: the bench leaves the minute loop
        files.set(heartbeat: .beating(since: time.now))
        await store.stateFileChanged(bench)
        #expect(store.trust[benchPath] == .heartbeat)
        await settle()
        #expect(held.isHolding)

        held.release()
        await waitUntil { held.finished == 1 && time.isWaiting }
        #expect(held.finished == 1)
        #expect(held.cancelled == 0)
        #expect(bench.refreshError == nil)
        #expect(bench.state == .running)
    }

    /// The popover opened during a crash: the status call read the bench
    /// while it still ran, the runner wrote crashed before the answer came.
    /// The late answer must not bring the run back, nor a second alert.
    @Test func aTransitionDuringAStatusCallIsNotUndoneByItsAnswer() async throws {
        let files = FakeBenchFiles(fileStatus(.running, pid: 4242), heartbeat: .beating(since: Date()), alive: [4242])
        let held = HeldCLI(["list": listJSON(), "status": runningJSON()])
        let store = makeStore(files: files, runner: held)
        await store.start(polling: false)
        let bench = try #require(store.selected)
        #expect(store.trust[benchPath] == .heartbeat)
        var alerts: [BenchAlert] = []
        store.onAlert = { _, alert in alerts.append(alert) }

        held.hold = true
        let call = Task { await store.refresh(bench) }
        await waitUntil { held.isHolding }
        #expect(held.isHolding)
        files.set(fileStatus(.crashed, reason: .crash, exit: 1))
        held.answer("status", statusJSON("crashed", reason: "crash", exit: 1))
        await store.stateFileChanged(bench)
        #expect(bench.state == .crashed)

        held.release()
        await call.value
        #expect(held.finished == 1)
        #expect(bench.state == .crashed, "the answer from before the crash is dropped")
        #expect(alerts == [.crashed(exitCode: 1)])
        #expect(held.statusCalls == 3, "at launch, the held one, and one more")
    }

    /// A new run whose first write keeps the state (starting over starting,
    /// as after the Start button) still overtakes a status call under way:
    /// its answer from between the runs is dropped, not shown.
    @Test func aNewRunThatKeepsTheStateStillOvertakesAStatusCall() async throws {
        func startingJSON(pid: Int) -> String {
            statusJSON("starting").replacingOccurrences(of: #""pid":null"#, with: "\"pid\":\(pid)")
        }
        let files = FakeBenchFiles(fileStatus(.starting, pid: 4242), heartbeat: .beating(since: Date()), alive: [4242, 4243])
        let held = HeldCLI(["list": listJSON(), "status": startingJSON(pid: 4242)])
        let store = makeStore(files: files, runner: held)
        await store.start(polling: false)
        let bench = try #require(store.selected)
        #expect(bench.state == .starting)

        held.answer("status", statusJSON("stopped", reason: "manual"))
        held.hold = true
        let call = Task { await store.refresh(bench) }
        await waitUntil { held.isHolding }
        #expect(held.isHolding)
        files.set(fileStatus(.starting, pid: 4243))
        held.answer("status", startingJSON(pid: 4243))
        await store.stateFileChanged(bench)
        #expect(bench.state == .starting)
        #expect(bench.status?.pid == 4243)

        held.release()
        await call.value
        #expect(bench.state == .starting, "the stopped answer from between the runs is dropped")
        #expect(bench.status?.pid == 4243)
        #expect(held.statusCalls == 3, "at launch, the held one, and one more")
    }

    /// A status call that fails (a timeout on a cold start) leaves no bench
    /// without a timer: the files say what they can, the CLI is asked again
    /// every minute until it answers.
    @Test func aFailedStatusIsAskedAgainEveryMinute() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(fileStatus(.running, pid: 4242), heartbeat: .beating(since: time.now), alive: [4242])
        cli.answer("list", json: listJSON())
        cli.answer("status", CommandOutput(exitCode: 1, stdout: "", stderr: "[FAIL] status timed out"))
        let store = makeStore(files: files, sleeper: time, now: { time.now })
        await store.start()
        defer { store.suspend(); time.wake() }
        let bench = try #require(store.selected)
        #expect(bench.state == .running, "the beating runner's file says what the CLI could not")
        #expect(bench.refreshError != nil)
        #expect(store.trust[benchPath] == .heartbeat)
        #expect(store.isRunningLegacyLoop)
        let atLaunch = cli.calls.count

        cli.answer("status", json: runningJSON())
        await waitUntil { time.isWaiting }
        time.wake()
        await waitUntil { bench.refreshError == nil && time.isWaiting }
        #expect(bench.refreshError == nil)
        #expect(cli.calls.count == atLaunch + 1)
        time.wake()
        await waitUntil { !store.isRunningLegacyLoop }
        #expect(!store.isRunningLegacyLoop, "answered: a beating runner needs no timer")
        #expect(cli.calls.count == atLaunch + 1)
    }

    /// Power lost while the bench ran, and the agent does not start at
    /// login: state.json says running with a pid that is gone. Once the CLI
    /// says stopped, the bench costs what any stopped bench costs.
    @Test func aRunTheCLIDeniesLeavesTheMinuteLoop() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(fileStatus(.stopped, reason: .manual))
        let poll = ManualSafetyPoll()
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("stopped", reason: "manual"))
        let store = makeStore(files: files, safetyPoll: poll, sleeper: time, now: { time.now })
        await store.start()
        defer { store.suspend(); time.wake() }
        let bench = try #require(store.selected)
        var seen: [BenchState] = []
        store.onChange = { seen.append(bench.state) }
        let atLaunch = cli.calls.count

        files.set(fileStatus(.running, pid: 777))
        await store.stateFileChanged(bench)
        #expect(seen.contains(.running), "a hint until the CLI answers")
        #expect(cli.calls.count == atLaunch + 1, "a dead pid asks the CLI")
        #expect(bench.state == .stopped)
        #expect(store.trust[benchPath] == .overruled)
        // the dead pid started the minute loop; it ends at its first wake
        await waitUntil { time.isWaiting }
        time.wake()
        await waitUntil { !store.isRunningLegacyLoop }
        #expect(!store.isRunningLegacyLoop)
        #expect(cli.calls.count == atLaunch + 1)

        // ten minutes: no timer, the safety poll asks as for any stopped bench
        for _ in 0..<2 {
            time.advance(by: 300)
            await poll.fire()
        }
        #expect(time.sleeps.count == 1)
        #expect(cli.calls.count == atLaunch + 3)
        #expect(store.trust[benchPath] == .overruled)

        // another folder event, the same claim: no hint this time
        seen = []
        await store.stateFileChanged(bench)
        #expect(!seen.contains(.running))
        #expect(bench.state == .stopped)

        // the runner writes again: its file is believed once more
        files.set(alive: [4243])
        files.set(heartbeat: .beating(since: time.now))
        files.set(fileStatus(.starting, pid: 4243))
        await store.stateFileChanged(bench)
        #expect(store.trust[benchPath] == .heartbeat)
        #expect(bench.state == .starting)
    }

    /// A runner that beats but never sees a 200 (a site answering 500, a
    /// first boot past the runner's ping window) keeps `starting` in its
    /// file; the CLI calls that run running, and the safety poll keeps it.
    @Test func aStartingFileDoesNotUndoTheCLIsRunning() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(fileStatus(.starting, pid: 4242), heartbeat: .beating(since: time.now), alive: [4242])
        let poll = ManualSafetyPoll()
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore(files: files, safetyPoll: poll, sleeper: time, now: { time.now })
        await store.start()
        defer { store.suspend(); time.wake() }
        let bench = try #require(store.selected)
        #expect(bench.state == .running)
        #expect(store.trust[benchPath] == .heartbeat)
        for _ in 0..<2 {
            time.advance(by: 300)
            await poll.fire()
            #expect(bench.state == .running)
        }

        // a restart is a new run: its starting is news
        files.set(alive: [4243])
        files.set(fileStatus(.starting, pid: 4243))
        await store.stateFileChanged(bench)
        #expect(bench.state == .starting)
    }

    /// A runner that hangs stops beating: the safety poll reads its files,
    /// finds the heartbeat stale and puts the bench back in the minute loop.
    @Test func aRunnerThatStopsBeatingGoesBackToTheMinuteLoop() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(fileStatus(.running, pid: 4242), heartbeat: .beating(since: time.now), alive: [4242])
        let poll = ManualSafetyPoll()
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore(files: files, safetyPoll: poll, sleeper: time, now: { time.now })
        await store.start()
        defer { store.suspend(); time.wake() }
        let bench = try #require(store.selected)
        #expect(!store.isRunningLegacyLoop)
        let atLaunch = cli.calls.count

        files.set(heartbeat: .stoppedBeating(at: time.now))
        time.advance(by: 300)
        await poll.fire()
        #expect(store.trust[benchPath] == .legacy(.staleHeartbeat))
        #expect(store.isRunningLegacyLoop)
        #expect(cli.calls.dropFirst(atLaunch).map { $0.first } == ["status"])

        // then its pid goes without a last write, and the CLI says crashed
        files.set(alive: [])
        cli.answer("status", json: statusJSON("crashed", reason: "crash", exit: 1))
        await waitUntil { time.isWaiting }
        time.wake()
        await waitUntil { store.trust[benchPath] == .overruled }
        #expect(store.trust[benchPath] == .overruled)
        #expect(bench.state == .crashed)
        #expect(cli.calls.count == atLaunch + 2)
        await waitUntil { time.isWaiting }
        time.wake()
        await waitUntil { !store.isRunningLegacyLoop }
        #expect(!store.isRunningLegacyLoop)
        #expect(cli.calls.count == atLaunch + 2)
    }

    /// A cleanup tool deletes logs/: the folder watcher hears nothing more.
    /// The next read of the bench's files starts it again.
    @Test func aWatcherThatLostItsFolderIsStartedAgain() async throws {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("stopped", reason: "manual"))
        let store = makeStore()
        await store.start(polling: false)
        let bench = try #require(store.selected)
        #expect(!store.isWatching(benchPath), "no logs folder yet")

        try dir.write("frappe-bench/logs/.benchbar/state.json", statusJSON("stopped", reason: "manual"))
        await store.refresh(bench)
        #expect(store.isWatching(benchPath))

        try FileManager.default.removeItem(at: dir.url.appendingPathComponent("frappe-bench/logs"))
        await settle()
        #expect(!store.isWatching(benchPath))
        try dir.write("frappe-bench/logs/.benchbar/state.json", statusJSON("stopped", reason: "manual"))
        await store.refresh(bench)
        #expect(store.isWatching(benchPath))
    }

    /// The BenchBar window is kept when closed, and its views never see
    /// onDisappear: the controller's close is what turns fast mode off.
    @Test func closingTheWindowTurnsFastModeOff() async throws {
        let clock = SnapshotClock()
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore(snapshotter: { pid in clock.next(pid) })
        await store.start(polling: false)
        let controller = MainWindowController { _ in fatalError("the test shows no window") }
        controller.onSight = { store.setWindow($0) }

        store.setWindow(WindowSight(isOpen: true, isVisible: true, overview: benchPath))
        #expect(store.fastMode)
        #expect(store.isSamplingCharts, "the Overview's charts sample the running bench")

        // covered by another window: open, but nothing to draw
        store.setWindow(WindowSight(isOpen: true, isVisible: false, overview: benchPath))
        #expect(!store.fastMode)
        #expect(!store.isSamplingCharts)
        store.setWindow(WindowSight(isOpen: true, isVisible: true, overview: benchPath))
        #expect(store.isSamplingCharts)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(store.windowSight == WindowSight())
        #expect(!store.fastMode)
        #expect(!store.isSamplingCharts)
    }

    /// The speed loop's bench gets no second loop on screen.
    @Test func theSpeedBenchIsNotSampledTwice() async throws {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore()
        await store.start(polling: false)
        store.setSpeedSampled(benchPath)
        store.setPopoverOpen(true)
        #expect(store.fastMode)
        #expect(!store.isSamplingCharts)
        store.setSpeedSampled(nil)
        #expect(store.isSamplingCharts, "speed off (Low Power Mode, Reduce Motion): the popover's bench is sampled here")
        store.setPopoverOpen(false)
        #expect(!store.isSamplingCharts)
    }

    /// At rest the speed loop records quietly: the closed popover and window
    /// are kept alive, and would redraw every 2 seconds otherwise.
    @Test func samplesReachTheViewsOnlyOnScreen() async throws {
        let clock = SnapshotClock()
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore(snapshotter: { pid in clock.next(pid) })
        await store.start(polling: false)
        let bench = try #require(store.selected)

        let quiet = Flag()
        withObservationTracking { _ = bench.resources } onChange: { quiet.set() }
        store.record(clock.next(4242), bench: benchPath, root: 4242)
        store.record(clock.next(4242), bench: benchPath, root: 4242)
        #expect(!quiet.isSet)
        #expect(bench.resources.history.samples.count == 2)

        let shown = Flag()
        withObservationTracking { _ = bench.resources } onChange: { shown.set() }
        store.setPopoverOpen(true)
        #expect(shown.isSet, "what was recorded is shown when the popover opens")
        let live = Flag()
        withObservationTracking { _ = bench.resources } onChange: { live.set() }
        store.record(clock.next(4242), bench: benchPath, root: 4242)
        #expect(live.isSet)
        store.setPopoverOpen(false)
    }

    /// The same answer again writes nothing: no view and no menu bar update.
    @Test func theSameStatusAgainRedrawsNothing() async throws {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore()
        var menuBarUpdates = 0
        store.onChange = { menuBarUpdates += 1 }
        await store.start(polling: false)
        let bench = try #require(store.selected)
        let afterLaunch = menuBarUpdates
        #expect(afterLaunch > 0)

        let redrawn = Flag()
        withObservationTracking {
            _ = bench.machine
            _ = bench.refreshError
            _ = bench.summary
            _ = bench.resources
            _ = store.benches
            _ = store.listError
        } onChange: { redrawn.set() }
        await store.refresh(bench)
        await store.reloadBenches()
        #expect(!redrawn.isSet)
        #expect(menuBarUpdates == afterLaunch)
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

/// Snapshots a second apart, each process a little busier.
nonisolated final class SnapshotClock: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Int32] = []
    var pids: [Int32] { lock.withLock { calls } }

    func next(_ pid: Int32) -> ProcessTree.Snapshot {
        lock.withLock {
            calls.append(pid)
            let n = UInt64(calls.count)
            let key = ProcessTree.Key(pid: pid, startTime: 0)
            return ProcessTree.Snapshot(takenAt: n * 1_000_000_000, cpu: [key: n * 100_000_000], memory: [key: 64 << 20])
        }
    }
}

/// state.json and the heartbeat as a test wants them, without a runner.
nonisolated final class FakeBenchFiles: BenchFiles, @unchecked Sendable {
    enum Heartbeat {
        case none
        /// a runner that beats every 30 seconds since then
        case beating(since: Date)
        case stoppedBeating(at: Date)
    }

    private let lock = NSLock()
    private var state: BenchFileState.StateFile
    private var heartbeat: Heartbeat
    private var alive: Set<Int32>

    init(_ status: BenchStatus?, heartbeat: Heartbeat = .none, alive: Set<Int32> = []) {
        state = status.map { .status($0) } ?? .missing
        self.heartbeat = heartbeat
        self.alive = alive
    }

    func set(_ status: BenchStatus?) { lock.withLock { state = status.map { .status($0) } ?? .missing } }
    func set(heartbeat: Heartbeat) { lock.withLock { self.heartbeat = heartbeat } }
    func set(alive: Set<Int32>) { lock.withLock { self.alive = alive } }

    func read(stateFile: String, now: Date) -> BenchFileState {
        lock.withLock {
            let age: TimeInterval?
            switch heartbeat {
            case .none: age = nil
            case .beating(let since): age = max(0, now.timeIntervalSince(since)).truncatingRemainder(dividingBy: 30)
            case .stoppedBeating(let at): age = now.timeIntervalSince(at)
            }
            return BenchFileState(stateFile: state, heartbeatAge: age)
        }
    }

    func isAlive(_ pid: Int32) -> Bool { lock.withLock { alive.contains(pid) } }
}

/// The store's clock and its legacy loop's sleeper in one. A sleep waits
/// until the test calls `wake()`, which moves the clock on by what the
/// sleeper asked for: ten minutes of rounds take milliseconds.
nonisolated final class SimulatedTime: PollSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private var slept: [Duration] = []
    private var waiting: [(Duration, CheckedContinuation<Void, Never>)] = []

    var now: Date { lock.withLock { current } }
    var sleeps: [Duration] { lock.withLock { slept } }
    var isWaiting: Bool { lock.withLock { !waiting.isEmpty } }

    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }

    func sleep(for duration: Duration, tolerance: Duration) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                slept.append(duration)
                waiting.append((duration, continuation))
            }
        }
    }

    func wake() {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiting = [] }
            if let longest = waiting.map({ $0.0 }).max() {
                current = current.addingTimeInterval(TimeInterval(longest.components.seconds))
            }
            return waiting.map { $0.1 }
        }
        woken.forEach { $0.resume() }
    }
}

/// The safety poll, fired by the test instead of macOS.
final class ManualSafetyPoll: SafetyPolling {
    private var work: (@MainActor @Sendable () async -> Void)?
    var isStarted: Bool { work != nil }
    func start(_ work: @escaping @MainActor @Sendable () async -> Void) { self.work = work }
    func stop() { work = nil }
    func fire() async { await work?() }
}

/// A CLI whose held calls (status, unless the test names others) wait for
/// the test while `hold` is set, and end as a timeout when cancelled
/// meanwhile, as swift-subprocess does (SIGTERM). A call answers what was
/// true when it began, like the CLI reading the bench.
nonisolated final class HeldCLI: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String]
    private let held: Set<String>
    private var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var counts = (finished: 0, cancelled: 0, status: 0)
    private var asked: [String: Int] = [:]

    init(_ answers: [String: String], holding held: Set<String> = ["status"]) {
        self.answers = answers
        self.held = held
    }

    var hold: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }
    var isHolding: Bool { lock.withLock { !waiting.isEmpty } }
    var finished: Int { lock.withLock { counts.finished } }
    var cancelled: Int { lock.withLock { counts.cancelled } }
    var statusCalls: Int { lock.withLock { counts.status } }
    /// How many calls of a command began.
    func count(_ command: String) -> Int { lock.withLock { asked[command, default: 0] } }

    func answer(_ command: String, _ json: String) { lock.withLock { answers[command] = json } }

    func release() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = false
            defer { waiting = [] }
            return waiting
        }
        held.forEach { $0.resume() }
    }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws(CLIError) -> CommandOutput {
        let command = arguments.first ?? ""
        let answer = lock.withLock { () -> String in
            if command == "status" { counts.status += 1 }
            asked[command, default: 0] += 1
            return answers[command] ?? ""
        }
        if held.contains(command), hold {
            await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } }
            if Task.isCancelled {
                lock.withLock { counts.cancelled += 1 }
                throw .timedOut(command: command, seconds: 20)
            }
            lock.withLock { counts.finished += 1 }
        }
        return .ok(answer)
    }
}

/// Set once from any thread, for observation callbacks.
nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Suite("Bench trust")
struct BenchTrustTests {
    let alive: (Int32) -> Bool = { $0 == 4242 }

    func file(_ state: BenchState, pid: Int32? = 4242, heartbeat: TimeInterval? = 12) -> BenchFileState {
        BenchFileState(stateFile: .status(BenchStatus(schemaVersion: 1, bench: "/b", state: state, pid: pid)), heartbeatAge: heartbeat)
    }

    @Test(arguments: [BenchState.running, .starting])
    func aLiveRunnerThatBeatsIsTheTruth(_ state: BenchState) {
        #expect(BenchTrust.evaluate(file(state), pidAlive: alive) == .heartbeat)
        #expect(BenchTrust.evaluate(file(state, heartbeat: 0), pidAlive: alive) == .heartbeat)
        #expect(BenchTrust.evaluate(file(state, heartbeat: 89.9), pidAlive: alive) == .heartbeat)
    }

    @Test(arguments: [BenchState.stopped, .crashed, .paused])
    func aFinalStateIsTheTruthWithoutPidOrHeartbeat(_ state: BenchState) {
        #expect(BenchTrust.evaluate(file(state, pid: nil, heartbeat: nil), pidAlive: alive) == .terminal)
        #expect(BenchTrust.evaluate(file(state, pid: 999, heartbeat: 4000), pidAlive: alive) == .terminal)
    }

    @Test func noFileOrOneThatDoesNotReadAsksTheCLI() {
        #expect(BenchTrust.evaluate(BenchFileState(stateFile: .missing, heartbeatAge: 1), pidAlive: alive) == .legacy(.noFile))
        #expect(BenchTrust.evaluate(BenchFileState(stateFile: .unreadable, heartbeatAge: 1), pidAlive: alive) == .legacy(.unreadable))
        #expect(BenchTrust.evaluate(file(.unknown), pidAlive: alive) == .legacy(.unreadable))
    }

    @Test func aRunnerThatIsGoneAsksTheCLI() {
        #expect(BenchTrust.evaluate(file(.running, pid: 999), pidAlive: alive) == .legacy(.deadPid))
        #expect(BenchTrust.evaluate(file(.running, pid: nil), pidAlive: alive) == .legacy(.deadPid))
        #expect(BenchTrust.evaluate(file(.starting, pid: 0), pidAlive: alive) == .legacy(.deadPid))
    }

    @Test func aRunnerWithoutAFreshHeartbeatIsLegacy() {
        #expect(BenchTrust.evaluate(file(.running, heartbeat: nil), pidAlive: alive) == .legacy(.noHeartbeat))
        #expect(BenchTrust.evaluate(file(.running, heartbeat: 90), pidAlive: alive) == .legacy(.staleHeartbeat))
        #expect(BenchTrust.evaluate(file(.starting, heartbeat: 3600), pidAlive: alive) == .legacy(.staleHeartbeat))
        // dated in the future: the clock moved back, and a beating runner
        // would have rewritten it by now
        #expect(BenchTrust.evaluate(file(.running, heartbeat: -2), pidAlive: alive) == .heartbeat)
        #expect(BenchTrust.evaluate(file(.running, heartbeat: -5), pidAlive: alive) == .legacy(.staleHeartbeat))
        #expect(BenchTrust.evaluate(file(.running, heartbeat: -3600), pidAlive: alive) == .legacy(.staleHeartbeat))
        #expect(BenchTrust.legacy(.staleHeartbeat).isLegacy)
        #expect(!BenchTrust.heartbeat.isLegacy && !BenchTrust.terminal.isLegacy)
    }

    @Test func liveFilesReadTheStateAndTheHeartbeatsAge() throws {
        let dir = try TempDir()
        let stateFile = dir.url.appendingPathComponent("logs/.benchbar/state.json").path
        let files = LiveBenchFiles()
        let now = Date()
        #expect(files.read(stateFile: stateFile, now: now) == BenchFileState(stateFile: .missing, heartbeatAge: nil))
        try dir.write("logs/.benchbar/state.json", "not json")
        #expect(files.read(stateFile: stateFile, now: now).stateFile == .unreadable)

        try dir.write("logs/.benchbar/state.json", #"{"schema_version":1,"bench":"/b","state":"running","stop_reason":null,"pid":4242,"started_at":"2026-09-30T10:00:00Z","last_exit_code":null,"web_url":"http://x:8000","web_ping_code":200,"updated_at":"2026-09-30T10:00:14Z","source":"runner"}"#)
        let heartbeat = try dir.write("logs/.benchbar/heartbeat", "42\n")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-45)], ofItemAtPath: heartbeat.path)
        let read = files.read(stateFile: stateFile, now: now)
        #expect(read.status?.state == .running)
        #expect(read.status?.pid == 4242)
        let age = try #require(read.heartbeatAge)
        #expect(abs(age - 45) < 1)

        #expect(files.isAlive(getpid()))
        #expect(!files.isAlive(999_999), "above the highest pid macOS hands out")
    }

    @Test func theFileKeepsWhatOnlyStatusKnows() {
        let ports = BenchPorts(web: 8000, socketio: 9000, redisQueue: 11000, redisCache: 13000)
        let sites = [SiteInfo(name: "macdev", isDefault: true, hostsEntry: true, pingCode: 200)]
        let full = BenchStatus(schemaVersion: 1, bench: "/b", state: .stopped, ports: ports, stateFile: "/b/logs/.benchbar/state.json",
                               log: "/b/logs/bench.log", agentLoaded: true, agentState: "running", processesRunning: false,
                               sites: sites, scheduler: true)
        let fromFile = BenchStatus(schemaVersion: 1, bench: "/b", state: .running, pid: 4242, webPingCode: 200, source: "runner")
        let merged = fromFile.merged(over: full)
        #expect(merged.state == .running)
        #expect(merged.pid == 4242)
        #expect(merged.ports == ports)
        #expect(merged.sites == sites)
        #expect(merged.scheduler == true)
        #expect(merged.agentState == "running")
        #expect(merged.processesRunning == true, "the file's state, not the last status's")
        #expect(fromFile.merged(over: nil) == fromFile)
    }
}
