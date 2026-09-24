import Foundation

/// What a speed source measures: one running bench.
nonisolated struct SpeedTarget: Equatable, Sendable {
    var bench: String
    /// The runner process launchd started; every bench process descends from it.
    var pid: Int32
    var ports: BenchPorts?
}

/// Something that turns a bench's load into a runner speed.
///
/// v1 has one source, CPU use of the bench's process tree. Queue depth and
/// requests per second (v0.3) plug in here without touching the animator.
nonisolated protocol SpeedSource: Sendable {
    /// A raw speed from 1 (idle) to 12 for this moment, or nil when the
    /// source cannot tell yet (the first CPU sample only sets a baseline).
    func sample(_ target: SpeedTarget) async -> Double?
}

nonisolated enum SpeedMapping {
    static let range = 1.0...12.0

    /// speed = clamp(1 + cpu% / 10, 1...12). cpu% is summed over cores, so
    /// 110% (a bit more than one busy core) is already the top speed.
    static func speed(cpuPercent: Double) -> Double {
        guard cpuPercent.isFinite else { return range.lowerBound }
        return min(max(1 + cpuPercent / 10, range.lowerBound), range.upperBound)
    }
}

/// An exponential moving average, so one busy sample does not make the
/// runner sprint and stop: value = alpha * new + (1 - alpha) * value.
nonisolated struct SpeedSmoother: Equatable, Sendable {
    var alpha: Double = 0.35
    private(set) var value: Double = SpeedMapping.range.lowerBound

    @discardableResult
    mutating func add(_ sample: Double) -> Double {
        value = alpha * sample + (1 - alpha) * value
        return value
    }

    mutating func reset() {
        value = SpeedMapping.range.lowerBound
    }
}
