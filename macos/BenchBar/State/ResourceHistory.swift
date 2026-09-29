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
/// Samples come from the store's status refreshes (every 30 seconds, every
/// 5 while the popover is open), so the spacing is uneven; a chart plots
/// them by time. The buffer is bounded twice: by age and by count.
nonisolated struct ResourceHistory: Equatable, Sendable {
    static let window: TimeInterval = 10 * 60
    /// One sample a second for ten minutes is far more than the polls make.
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
