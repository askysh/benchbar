import Foundation

/// CPU and memory of one bench at one moment.
nonisolated struct ResourceSample: Equatable, Sendable {
    var time: Date
    /// Percent of one core, summed over the tree (250 is two and a half cores).
    var cpuPercent: Double
    var memoryBytes: UInt64
}

/// The last ten minutes of a bench's CPU and memory, in memory only.
///
/// Samples come from the runner's speed loop (every 2 seconds for the bench
/// that sets the speed), the charts' loop (every 5 seconds for another bench
/// on screen) and the status refreshes, so the spacing is uneven; a chart
/// plots them by time. The buffer is bounded twice: by age and by count.
nonisolated struct ResourceHistory: Equatable, Sendable {
    static let window: TimeInterval = 10 * 60
    /// One sample a second for ten minutes is more than the loops make.
    static let capacity = 600

    private(set) var samples: [ResourceSample] = []

    var latest: ResourceSample? { samples.last }
    var isEmpty: Bool { samples.isEmpty }

    mutating func add(_ sample: ResourceSample) {
        // the clock went back (a time zone or NTP jump): start over
        if let last = samples.last, sample.time < last.time { samples.removeAll() }
        samples.append(sample)
        let oldest = sample.time.addingTimeInterval(-Self.window)
        if let keep = samples.firstIndex(where: { $0.time >= oldest }), keep > 0 {
            samples.removeFirst(keep)
        }
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    mutating func reset() { samples.removeAll() }
}

/// Turns two process tree snapshots of one run into samples. One per
/// bench; a new runner pid (a restart) starts a new history.
nonisolated struct ResourceSampler: Sendable {
    private(set) var history = ResourceHistory()
    private var root: Int32?
    private var last: ProcessTree.Snapshot?

    /// A run is being measured.
    var isTracking: Bool { root != nil }

    /// The bench runs as `root`: add what `snapshot` says. The first
    /// snapshot of a run only sets the CPU baseline.
    mutating func record(_ snapshot: ProcessTree.Snapshot, root: Int32, at time: Date) {
        if root != self.root {
            self.root = root
            last = nil
            history.reset()
        }
        defer { last = snapshot.cpu.isEmpty ? nil : snapshot }
        guard let last, !snapshot.cpu.isEmpty else { return }
        history.add(ResourceSample(time: time, cpuPercent: ProcessTree.cpuPercent(from: last, to: snapshot),
                                   memoryBytes: snapshot.memoryBytes))
    }

    /// The bench stopped: no baseline to measure from next time. The
    /// history stays until the next run replaces it.
    mutating func stop() {
        root = nil
        last = nil
    }
}

/// The scales of the two sparklines. Pure, so the ranges are tested.
nonisolated enum ResourceScale {
    /// The time shown: from the first sample (at least a minute back) to the
    /// last, growing to ten minutes. A fixed ten minute axis drew a fresh
    /// bench as a sliver at the right edge.
    static func time(_ samples: [ResourceSample]) -> ClosedRange<Date> {
        guard let last = samples.last?.time, let first = samples.first?.time else {
            let now = Date()
            return now.addingTimeInterval(-60)...now
        }
        let span = min(max(last.timeIntervalSince(first), 60), ResourceHistory.window)
        return last.addingTimeInterval(-span)...last
    }

    /// CPU from zero: idle should look idle.
    static func cpu(_ values: [Double]) -> ClosedRange<Double> {
        0...max((values.max() ?? 0) * 1.15, 5)
    }

    /// Memory around its own range: a few MB of change on 400 MB should be
    /// visible, and a flat line sits in the middle instead of filling the chart.
    static func memory(_ values: [Double]) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.25, 32 * 1_048_576)
        return max(0, low - pad)...(high + pad)
    }
}

nonisolated enum ResourceText {
    /// "0%", "12%", "250%": percent of one core, like Activity Monitor.
    static func cpu(_ percent: Double) -> String {
        guard percent.isFinite else { return "0%" }
        return "\(Int(max(0, percent).rounded()))%"
    }

    /// "640 KB", "812 MB", "1.4 GB", in binary units like Activity Monitor.
    static func memory(_ bytes: UInt64) -> String {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        let value = Double(bytes)
        // 1000 MB and up reads as GB, so "1020 MB" is never shown
        if value >= 1000 * mb { return String(format: "%.1f GB", value / gb) }
        if value >= mb { return "\(Int((value / mb).rounded())) MB" }
        return "\(Int((value / kb).rounded())) KB"
    }
}
