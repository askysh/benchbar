import Darwin
import Foundation

/// How far the store may trust a bench's `logs/.benchbar/state.json`
/// without asking the CLI. Pure, so every case is a unit test.
///
/// Since 0.6.1 a running runner rewrites `logs/.benchbar/heartbeat` in
/// place every 30 seconds (docs/json-schema.md). An in place write wakes no
/// folder watcher, so the store reads the heartbeat's age only when it
/// decides, never on a clock of its own.
nonisolated enum BenchTrust: Equatable, Sendable {
    /// running or starting, the runner's pid is alive and its heartbeat is
    /// fresh: state.json is the truth until it changes
    case heartbeat
    /// stopped, crashed or paused: the next change is a new write, which the
    /// folder watcher sees (the safety poll still asks the CLI, the only one
    /// to see a bench started by hand)
    case terminal
    /// the CLI has to say: every minute while this lasts
    case legacy(Reason)
    /// state.json still claims a run (its pid gone, or no fresh heartbeat)
    /// that the CLI has called stopped, crashed or paused: the file is not
    /// taken, and only the safety poll asks again, until the file changes.
    /// The store decides this from the CLI's answer; `evaluate` never does.
    case overruled

    enum Reason: String, Sendable {
        case noFile = "no state.json"
        case unreadable = "state.json unreadable"
        case deadPid = "the runner's pid is gone"
        case noHeartbeat = "no heartbeat (a runner from before 0.6.1)"
        case staleHeartbeat = "a stale heartbeat"
    }

    /// Three missed beats: the runner writes one every 30 seconds.
    static let freshness: TimeInterval = 90
    /// A beat written between reading the clock and the stat is a little in
    /// the future. More than this is a clock that moved back: a runner that
    /// beats fixes it within 30 seconds, one that hangs never does.
    static let futureSkew: TimeInterval = 5

    var isLegacy: Bool { if case .legacy = self { true } else { false } }

    /// What the store logs when a bench changes mode.
    var word: String {
        switch self {
        case .heartbeat: "heartbeat"
        case .terminal: "terminal"
        case .overruled: "overruled (state.json claims a run the CLI denies)"
        case .legacy(let reason): "legacy (\(reason.rawValue))"
        }
    }

    /// A state the runner writes last: nothing changes until the next write.
    static func isFinal(_ state: BenchState) -> Bool {
        state == .stopped || state == .crashed || state == .paused
    }

    static func evaluate(_ file: BenchFileState, pidAlive: (Int32) -> Bool) -> BenchTrust {
        let status: BenchStatus
        switch file.stateFile {
        case .missing: return .legacy(.noFile)
        case .unreadable: return .legacy(.unreadable)
        case .status(let value): status = value
        }
        switch status.state {
        case .stopped, .crashed, .paused:
            return .terminal
        case .running, .starting:
            guard let pid = status.pid, pid > 0, pidAlive(pid) else { return .legacy(.deadPid) }
            guard let age = file.heartbeatAge else { return .legacy(.noHeartbeat) }
            return age < freshness && age > -futureSkew ? .heartbeat : .legacy(.staleHeartbeat)
        case .unknown:
            return .legacy(.unreadable)
        }
    }
}

/// What a bench's `logs/.benchbar` folder says at one moment.
nonisolated struct BenchFileState: Equatable, Sendable {
    enum StateFile: Equatable, Sendable {
        case missing
        case unreadable
        case status(BenchStatus)
    }

    var stateFile: StateFile
    /// Seconds since the heartbeat file was last written; nil without one.
    var heartbeatAge: TimeInterval?

    var status: BenchStatus? {
        if case .status(let value) = stateFile { value } else { nil }
    }
}

/// Reads the files the trust rule needs. A protocol, so the store tests
/// run without a runner, a real pid or a clock.
nonisolated protocol BenchFiles: Sendable {
    /// state.json and the heartbeat next to it; `stateFile` is its path.
    func read(stateFile: String, now: Date) -> BenchFileState
    func isAlive(_ pid: Int32) -> Bool
}

nonisolated struct LiveBenchFiles: BenchFiles {
    func read(stateFile: String, now: Date) -> BenchFileState {
        let state: BenchFileState.StateFile
        if let data = FileManager.default.contents(atPath: stateFile) {
            if let status = try? BenchJSON.decode(BenchStatus.self, from: data) {
                state = .status(status)
            } else {
                state = .unreadable
            }
        } else {
            state = FileManager.default.fileExists(atPath: stateFile) ? .unreadable : .missing
        }
        let heartbeat = (stateFile as NSString).deletingLastPathComponent + "/heartbeat"
        return BenchFileState(stateFile: state, heartbeatAge: Self.modified(heartbeat).map { now.timeIntervalSince($0) })
    }

    /// kill(pid, 0): 0 means the process exists and is ours to signal
    func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// The file's modification time from one stat call; nil when it is missing.
    static func modified(_ path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let spec = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }
}

extension BenchStatus {
    /// state.json carries the core fields only: keep what the last full
    /// status said about ports, sites and the scheduler, so a transition
    /// from the file does not blank them in the window.
    nonisolated func merged(over previous: BenchStatus?) -> BenchStatus {
        guard let previous else { return self }
        var merged = self
        merged.ports = ports ?? previous.ports
        merged.stateFile = stateFile ?? previous.stateFile
        merged.log = log ?? previous.log
        merged.agentLoaded = agentLoaded ?? previous.agentLoaded
        merged.agentState = agentState ?? previous.agentState
        merged.sites = sites ?? previous.sites
        merged.scheduler = scheduler ?? previous.scheduler
        merged.processesRunning = processesRunning ?? (state == .running || state == .starting)
        return merged
    }
}
