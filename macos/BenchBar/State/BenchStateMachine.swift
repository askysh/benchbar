import Foundation

/// A notification worth showing, decided by the state machine.
nonisolated enum BenchAlert: Equatable, Sendable {
    /// running to crashed: honcho exited with an error, launchd will retry
    case crashed(exitCode: Int?)
    /// the crash guard tripped: 3 starts in 10 minutes, auto-restart paused
    case crashGuardTripped
    /// paused to running: the bench is back
    case recovered
}

/// What the store should do after a transition.
nonisolated enum BenchEffect: Equatable, Sendable {
    case alert(BenchAlert)
    /// ping the site once, to confirm a start really finished
    case pingSite
    /// ask the CLI for fresh status
    case refresh
}

/// The pure state logic for one bench: no I/O, no clocks, so it is easy to
/// test. The store feeds it events and performs the effects it returns.
///
/// States are the CLI's (stopped, starting, running, crashed, paused) plus
/// `unknown` before the first answer or when the CLI is missing.
nonisolated struct BenchStateMachine: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// `benchbar status --json`: the truth
        case status
        /// `logs/.benchbar/state.json`: a fast hint from the runner
        case stateFile
    }

    enum Event: Equatable, Sendable {
        case observed(BenchStatus, Source)
        case actionStarted(CLIClient.Action)
        case actionFinished(CLIClient.Action, succeeded: Bool)
        case cliUnavailable
    }

    private(set) var state: BenchState = .unknown
    private(set) var stopReason: StopReason?
    private(set) var pending: CLIClient.Action?
    /// The last status seen (from either source).
    private(set) var status: BenchStatus?

    mutating func handle(_ event: Event) -> [BenchEffect] {
        switch event {
        case .cliUnavailable:
            state = .unknown
            stopReason = nil
            pending = nil
            return []

        case .actionStarted(let action):
            pending = action
            // optimistic: show the walk right away, the CLI confirms later
            if action == .up || action == .restart {
                return transition(to: .starting, reason: nil)
            }
            return []

        case .actionFinished(let action, let succeeded):
            pending = nil
            if succeeded && (action == .up || action == .restart) {
                return [.pingSite, .refresh]
            }
            return [.refresh]

        case .observed(let observed, let source):
            if isStale(observed.state, source: source) {
                return []
            }
            status = observed
            return transition(to: observed.state, reason: observed.stopReason, exitCode: observed.lastExitCode)
        }
    }

    /// While a start is in flight a "stopped" answer is from before it;
    /// while a stop is in flight a "running" answer is too.
    private func isStale(_ observed: BenchState, source: Source) -> Bool {
        switch pending {
        case .up?, .restart?:
            return observed == .stopped
        case .down?:
            return observed == .running || observed == .starting
        case nil:
            return false
        }
    }

    private mutating func transition(to next: BenchState, reason: StopReason?, exitCode: Int? = nil) -> [BenchEffect] {
        let previous = state
        state = next
        stopReason = reason
        guard previous != next else { return [] }

        var effects: [BenchEffect] = []
        switch (previous, next) {
        case (.running, .crashed):
            effects.append(.alert(.crashed(exitCode: exitCode)))
        case (.running, .paused), (.starting, .paused), (.crashed, .paused):
            // a poll can miss the short crashed state between retries
            if reason == .crash { effects.append(.alert(.crashGuardTripped)) }
        case (.paused, .running):
            effects.append(.alert(.recovered))
        default:
            break
        }
        return effects
    }
}
