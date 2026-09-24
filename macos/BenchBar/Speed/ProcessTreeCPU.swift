import Darwin
import Foundation

/// CPU time of a process tree, read with libproc (the API behind
/// Activity Monitor and `top`). Works for our own user's processes
/// without any entitlement.
nonisolated enum ProcessTree {
    /// A process, told apart from a later one that reuses its pid.
    struct Key: Hashable, Sendable {
        var pid: pid_t
        var startTime: UInt64
    }

    /// CPU time per process, and when it was read (both in nanoseconds).
    struct Snapshot: Equatable, Sendable {
        var takenAt: UInt64
        var cpu: [Key: UInt64]
    }

    /// `root` and all its descendants, root first.
    static func pids(under root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [root]
        var seen: Set<pid_t> = []
        while let pid = queue.first {
            queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            queue += children(of: pid)
        }
        return result
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while capacity <= 16_384 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes { raw in
                proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
            }
            if count < 0 { return [] }
            // a full buffer may mean it was cut short: try a bigger one
            if Int(count) < capacity {
                return Array(buffer.prefix(Int(count))).filter { $0 > 0 }
            }
            capacity *= 4
        }
        return []
    }

    /// Reads the CPU time of every process under `root`. Processes that
    /// exit while we read are skipped.
    static func snapshot(root: pid_t) -> Snapshot {
        var cpu: [Key: UInt64] = [:]
        for pid in pids(under: root) {
            var info = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard result == 0 else { continue }
            let key = Key(pid: pid, startTime: info.ri_proc_start_abstime)
            cpu[key] = MachTime.nanoseconds(info.ri_user_time &+ info.ri_system_time)
        }
        return Snapshot(takenAt: MachTime.nanoseconds(mach_absolute_time()), cpu: cpu)
    }

    /// CPU use between two snapshots, in percent of one core (so 250 means
    /// two and a half cores busy).
    ///
    /// A process in both counts its growth. A process only in `new` counts
    /// all its time if it started after `old` was taken, since all of it
    /// falls in the window; otherwise it is ignored this round. Processes
    /// that exited drop out instead of making the total go backwards.
    static func cpuPercent(from old: Snapshot, to new: Snapshot) -> Double {
        guard new.takenAt > old.takenAt else { return 0 }
        var busy: UInt64 = 0
        for (key, time) in new.cpu {
            if let before = old.cpu[key] {
                busy &+= time > before ? time - before : 0
            } else if MachTime.nanoseconds(key.startTime) > old.takenAt {
                busy &+= time
            }
        }
        return Double(busy) / Double(new.takenAt - old.takenAt) * 100
    }
}

/// Mach absolute time is in ticks, not nanoseconds, on Apple Silicon
/// (one tick is 125/3 ns there). rusage CPU times use the same ticks.
nonisolated enum MachTime {
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        guard timebase.numer != timebase.denom, timebase.denom != 0 else { return ticks }
        let (high, low) = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        return UInt64(timebase.denom).dividingFullWidth((high, low)).quotient
    }
}

/// The v1 speed source: CPU use of the bench's whole process tree
/// (runner, honcho, web, workers, socketio, Redis), sampled by the caller
/// every 2 seconds.
actor ProcessTreeCPUSource: SpeedSource {
    private var last: (root: pid_t, snapshot: ProcessTree.Snapshot)?

    func sample(_ target: SpeedTarget) async -> Double? {
        let now = ProcessTree.snapshot(root: target.pid)
        defer { last = (target.pid, now) }
        guard let last, last.root == target.pid, !now.cpu.isEmpty else { return nil }
        return SpeedMapping.speed(cpuPercent: ProcessTree.cpuPercent(from: last.snapshot, to: now))
    }
}
