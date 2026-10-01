import Foundation

/// One set of frames in a runner. The raw values are the keys of a custom
/// runner's manifest.json (Phase 7), so they are part of the runner format.
nonisolated enum RunnerPose: String, CaseIterable, Codable, Sendable {
    case sleeping, starting, running, crashed, alert, unknown

    /// Frames per second at speed 1. Only `running` speeds up with load,
    /// up to `maxFPS` (6 times its own 5).
    var baseFPS: Double {
        switch self {
        case .sleeping: 2
        case .starting: 6
        case .running: 5
        case .crashed: 8
        case .alert, .unknown: 2
        }
    }

    /// The fastest any pose plays, whatever speed the load asks for: a menu
    /// bar glyph gains nothing from more, and each frame costs the render
    /// server a composite.
    static let maxFPS: Double = 30
}

/// What the status item should play for one state. Pure data, so the
/// mapping from bench state to animation is easy to test.
nonisolated enum RunnerPlan: Equatable, Sendable {
    /// Loop the pose's frames forever.
    case loop(RunnerPose)
    /// Loop the pose's frames `times` times, then hold its first frame: a
    /// bench at rest costs no frames after that.
    case settle(RunnerPose, times: Int)
    /// Play the stumble `times` times, then hold the alert pose.
    case stumble(times: Int, then: RunnerPose)
    /// One frame, no animation (Reduce Motion).
    case still(RunnerPose)

    static let stumbleTimes = 3
    static let settleTimes = 3

    /// The table from the brief:
    ///
    ///   stopped            sleeping pose, three loops, then still
    ///   starting           walking
    ///   running            running, speed from load
    ///   crashed, paused    stumble loop, then a still alert pose
    ///   unknown            a question pose, three loops, then still
    ///
    /// With Reduce Motion every state shows one still frame instead. A new
    /// state is a new plan, so it plays again from the start.
    static func forState(_ state: BenchState, reduceMotion: Bool) -> RunnerPlan {
        switch (state, reduceMotion) {
        case (.stopped, false): .settle(.sleeping, times: settleTimes)
        case (.stopped, true): .still(.sleeping)
        case (.starting, false): .loop(.starting)
        case (.starting, true): .still(.starting)
        case (.running, false): .loop(.running)
        case (.running, true): .still(.running)
        case (.crashed, false), (.paused, false): .stumble(times: stumbleTimes, then: .alert)
        case (.crashed, true), (.paused, true): .still(.alert)
        case (.unknown, false): .settle(.unknown, times: settleTimes)
        case (.unknown, true): .still(.unknown)
        }
    }

    /// Only the running loop follows the speed source; everything else
    /// plays at its own fixed pace.
    var followsSpeed: Bool {
        self == .loop(.running)
    }
}
