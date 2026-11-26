import Foundation
import Testing
@testable import BenchBar

/// Answers `list` and `status` for N benches, slowly, and notes how many
/// `status` calls ran at the same time.
nonisolated final class BusyCLI: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let paths: [String]
    private var running = 0
    private var peak = 0
    private var listCalls = 0

    init(paths: [String]) { self.paths = paths }

    var maxParallelStatus: Int { lock.withLock { peak } }
    var lists: Int { lock.withLock { listCalls } }
    /// The standard input of every call that sent some (`--secrets-stdin`), in order.
    var inputs: [[UInt8]] { lock.withLock { sentInputs } }
    private var sentInputs: [[UInt8]] = []

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration,
             qos: QualityOfService, input: [UInt8]?) async throws(CLIError) -> CommandOutput {
        if let input { lock.withLock { sentInputs.append(input) } }
        return try await run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
    }

    func stream(executable: URL, arguments: [String], environment: [String: String], timeout: Duration, input: [UInt8]?,
                onLine: @escaping @Sendable (String) -> Void) async throws(CLIError) -> Int32 {
        if let input { lock.withLock { sentInputs.append(input) } }
        return try await stream(executable: executable, arguments: arguments, environment: environment, timeout: timeout, onLine: onLine)
    }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws(CLIError) -> CommandOutput {
        switch arguments.first {
        case "list":
            lock.withLock { listCalls += 1 }
            let entries = paths.enumerated().map { index, path in
                #"{"path":"\#(path)","name":"b\#(index)","site":"s\#(index)","label":"com.benchbar.b\#(index)","web_url":"http://s\#(index):8000","ports":{"web":8000,"socketio":9000,"redis_queue":11000,"redis_cache":13000},"default":\#(index == 0),"service_installed":true,"state_file":"\#(path)/logs/.benchbar/state.json"}"#
            }
            return .ok(#"{"schema_version":1,"cli_version":"0.3.0","default_bench":"\#(paths[0])","benches":[\#(entries.joined(separator: ","))]}"#)
        case "status":
            let bench = arguments.firstIndex(of: "--bench-dir").map { arguments[$0 + 1] } ?? ""
            lock.withLock { running += 1; peak = max(peak, running) }
            try? await Task.sleep(for: .milliseconds(40))
            lock.withLock { running -= 1 }
            return .ok(#"{"schema_version":1,"bench":"\#(bench)","state":"stopped","stop_reason":"manual","pid":null,"started_at":null,"last_exit_code":null,"web_url":"http://s:8000","web_ping_code":null}"#)
        default:
            return .ok("{}")
        }
    }
}

extension BenchStoreTests {
    // MARK: MAC-1: a running change is named, and the store says when it ends

    @Test func aRunningChangeIsNamedAndTheStoreSaysWhenItEnds() async throws {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("stopped", reason: "manual"))
        let store = makeStore()
        await store.start(polling: false)
        let bench = try #require(store.selected)
        #expect(store.runningChangeLabel == nil)

        var idle = 0
        store.onIdle = { idle += 1 }
        var during: String?
        let result = await store.runChange("Updating erpnext", on: bench) { _ throws(CLIError) in
            during = store.runningChangeLabel
        }
        #expect(result == nil)
        #expect(during == "Updating erpnext")
        #expect(store.runningChangeLabel == nil)
        #expect(idle >= 1, "the quit that waited for the change is told")
    }

    @Test func aStartIsAChangeToo() async throws {
        let held = HeldCLI(["list": listJSON(), "status": statusJSON("stopped", reason: "manual"), "ports": #"{"schema_version":1,"conflicts":[],"mode":"automatic"}"#, "up": ""],
                           holding: ["up"])
        let store = makeStore(runner: held)
        await store.start(polling: false)
        let bench = try #require(store.selected)
        held.hold = true
        let started = Task { await store.perform(.up, on: bench) }
        await waitUntil { held.isHolding }
        #expect(store.runningChangeLabel == "Starting frappe-bench")
        held.release()
        _ = await started.value
        #expect(store.runningChangeLabel == nil)
    }

    // MARK: MAC-7: watchers stay while the Mac is locked, a crash away is still told

    @Test func lockingKeepsTheFolderWatcherAndAsksNoCLI() async throws {
        try dir.write("frappe-bench/logs/.benchbar/placeholder", "")
        let time = SimulatedTime()
        let files = FakeBenchFiles(fileStatus(.running, pid: 4242), heartbeat: .beating(since: time.now), alive: [4242])
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore(files: files, sleeper: time, now: { time.now })
        await store.start(polling: false)
        let bench = try #require(store.selected)
        #expect(store.isWatching(benchPath))
        store.suspend()
        defer { time.wake() }
        #expect(store.isWatching(benchPath), "the watcher costs nothing without events")

        var alerts: [BenchAlert] = []
        store.onAlert = { _, alert in alerts.append(alert) }
        let calls = cli.calls.count
        files.set(fileStatus(.crashed, reason: .crash, exit: 1))
        await store.stateFileChanged(bench)
        #expect(alerts == [.crashed(exitCode: 1)], "told at once, not after the unlock")
        #expect(cli.calls.count == calls, "no CLI call while locked")
    }

    @Test func aCrashHeardWhileLockedIsNotToldAgainAtWake() async throws {
        let files = FakeBenchFiles(fileStatus(.running, pid: 4242), heartbeat: .beating(since: Date()), alive: [4242])
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore(files: files)
        await store.start(polling: false)
        let bench = try #require(store.selected)
        store.suspend()
        var alerts: [BenchAlert] = []
        store.onAlert = { _, alert in alerts.append(alert) }
        files.set(fileStatus(.crashed, reason: .crash, exit: 1))
        await store.stateFileChanged(bench)
        // launchd restarted it: a new run with the failing exit code
        cli.answer("status", json: awayJSON(started: "2026-09-23T10:30:00Z", exit: 1))
        files.set(fileStatus(.running, pid: 4243))
        store.resume()
        await waitUntil { bench.status?.startedAt != nil && bench.status?.lastExitCode == 1 }
        await settle()
        #expect(alerts == [.crashed(exitCode: 1)])
    }

    /// The bench crashed at 12:05 and launchd had it up by 12:06; the unlock at 13:00 sees `running`.
    @Test func aCrashThatCameAndWentWhileAwayIsToldAtWake() async throws {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore()
        await store.start(polling: false)
        let bench = try #require(store.selected)
        #expect(bench.state == .running)
        var alerts: [BenchAlert] = []
        store.onAlert = { _, alert in alerts.append(alert) }
        store.suspend()
        cli.answer("status", json: awayJSON(started: "2026-09-23T10:30:00Z", exit: 1))
        store.resume()
        await waitUntil { !alerts.isEmpty }
        #expect(alerts == [.crashed(exitCode: 1)])
    }

    @Test func aBenchThatRanOnWithoutARestartIsNotToldAbout() async throws {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore()
        await store.start(polling: false)
        var alerts: [BenchAlert] = []
        store.onAlert = { _, alert in alerts.append(alert) }
        store.suspend()
        store.resume()
        await settle()
        #expect(alerts.isEmpty)
    }

    @Test func aRestartThatWasNotACrashIsNotToldAbout() async throws {
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore()
        await store.start(polling: false)
        var alerts: [BenchAlert] = []
        store.onAlert = { _, alert in alerts.append(alert) }
        store.suspend()
        cli.answer("status", json: awayJSON(started: "2026-09-23T10:30:00Z", exit: 0))
        store.resume()
        await settle()
        #expect(alerts.isEmpty, "a new run after a clean stop is not a crash")
    }

    func awayJSON(started: String, exit: Int) -> String {
        runningJSON().replacingOccurrences(of: #""started_at":"2026-09-23T10:00:00Z""#, with: #""started_at":"\#(started)""#)
            .replacingOccurrences(of: #""last_exit_code":null"#, with: #""last_exit_code":\#(exit)"#)
            .replacingOccurrences(of: #""pid":4242"#, with: #""pid":4343"#)
    }

    // MARK: MAC-8: a limit on parallel CLI children, no duplicate reloads, no minute loop for a bench that never ran

    @Test func statusCallsRunAtMostThreeAtATime() async throws {
        let paths = (0..<8).map { dir.url.appendingPathComponent("bench\($0)").path }
        let busy = BusyCLI(paths: paths)
        let store = makeStore(runner: busy)
        await store.start(polling: false)
        #expect(store.benches.count == 8)
        #expect(busy.maxParallelStatus >= 2, "the calls still overlap")
        #expect(busy.maxParallelStatus <= BenchStore.maxParallelStatus)
        #expect(BenchStore.maxParallelStatus == 3)
    }

    @Test func aClickWhileAReloadRunsStartsNoSecondReload() async throws {
        let held = HeldCLI(["list": listJSON(), "status": statusJSON("stopped", reason: "manual")], holding: ["list"])
        let store = makeStore(runner: held)
        await store.start(polling: false)
        #expect(held.count("list") == 1)
        held.hold = true
        store.setPopoverOpen(true)
        store.setWindow(WindowSight(isOpen: true, isVisible: true, overview: benchPath))
        await waitUntil { held.isHolding }
        #expect(held.isHolding)
        store.setPopoverOpen(false)
        store.setPopoverOpen(true)
        store.appBecameActive()
        await settle()
        #expect(held.count("list") == 2, "one reload for the popover and the window together")
        held.release()
        await waitUntil { !store.isLoading }
        await settle()
        #expect(held.count("list") == 2)
    }

    @Test func aBenchThatNeverRanIsNotAskedEveryMinuteOnceTheCLIAnswered() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(nil)
        cli.answer("list", json: listJSON())
        cli.answer("status", json: statusJSON("stopped", reason: "manual"))
        let store = makeStore(files: files, sleeper: time, now: { time.now })
        await store.start()
        defer { store.suspend(); time.wake() }
        #expect(store.trust[benchPath] == .legacy(.noFile))
        #expect(store.selected?.state == .stopped)
        #expect(!store.isRunningLegacyLoop, "no minute loop for a bench with no files that the CLI called stopped")
        await settle()
        #expect(time.sleeps.isEmpty)
    }

    @Test func aBenchStartedByHandWithoutFilesStaysInTheMinuteLoop() async throws {
        let time = SimulatedTime()
        let files = FakeBenchFiles(nil)
        cli.answer("list", json: listJSON())
        cli.answer("status", json: runningJSON())
        let store = makeStore(files: files, sleeper: time, now: { time.now })
        await store.start()
        defer { store.suspend(); time.wake() }
        #expect(store.selected?.state == .running)
        #expect(store.isRunningLegacyLoop, "benchfg leaves no state.json: only the CLI can see it stop")
    }
}
