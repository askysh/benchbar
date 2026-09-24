import Foundation

/// One set of frames in a runner. The raw values are the keys of a custom
/// runner's manifest.json (Phase 7), so they are part of the runner format.
nonisolated enum RunnerPose: String, CaseIterable, Codable, Sendable {
    case sleeping, starting, running, crashed, alert, unknown

    /// Frames per second at speed 1. Only `running` speeds up with load:
    /// at the top speed of 12 it plays 5 x 12 = 60 frames per second.
    var baseFPS: Double {
        switch self {
        case .sleeping: 2
        case .starting: 6
        case .running: 5
        case .crashed: 8
        case .alert, .unknown: 2
        }
    }
}

/// What the status item should play for one state. Pure data, so the
/// mapping from bench state to animation is easy to test.
nonisolated enum RunnerPlan: Equatable, Sendable {
    /// Loop the pose's frames forever.
    case loop(RunnerPose)
    /// Play the stumble `times` times, then hold the alert pose.
    case stumble(times: Int, then: RunnerPose)
    /// One frame, no animation (Reduce Motion).
    case still(RunnerPose)

    static let stumbleTimes = 3

    /// The table from the brief:
    ///
    ///   stopped            sleeping pose
    ///   starting           walking
    ///   running            running, speed from load
    ///   crashed, paused    stumble loop, then a still alert pose
    ///   unknown            a question pose
    ///
    /// With Reduce Motion every state shows one still frame instead.
    static func forState(_ state: BenchState, reduceMotion: Bool) -> RunnerPlan {
        switch (state, reduceMotion) {
        case (.stopped, false): .loop(.sleeping)
        case (.stopped, true): .still(.sleeping)
        case (.starting, false): .loop(.starting)
        case (.starting, true): .still(.starting)
        case (.running, false): .loop(.running)
        case (.running, true): .still(.running)
        case (.crashed, false), (.paused, false): .stumble(times: stumbleTimes, then: .alert)
        case (.crashed, true), (.paused, true): .still(.alert)
        case (.unknown, false): .loop(.unknown)
        case (.unknown, true): .still(.unknown)
        }
    }

    /// Only the running loop follows the speed source; everything else
    /// plays at its own fixed pace.
    var followsSpeed: Bool {
        self == .loop(.running)
    }
}
