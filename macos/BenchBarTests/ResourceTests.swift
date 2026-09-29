import Darwin
import Foundation
import Testing
@testable import BenchBar

@Suite("Resource history")
struct ResourceTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func sample(_ seconds: TimeInterval, cpu: Double = 10, memory: UInt64 = 100) -> ResourceSample {
        ResourceSample(time: start.addingTimeInterval(seconds), cpuPercent: cpu, memoryBytes: memory)
    }

    func key(_ pid: pid_t) -> ProcessTree.Key { ProcessTree.Key(pid: pid, startTime: 0) }

    /// Two processes; the clock and CPU times in nanoseconds.
    func snapshot(at seconds: UInt64, cpu: [pid_t: UInt64], memory: [pid_t: UInt64]) -> ProcessTree.Snapshot {
        ProcessTree.Snapshot(
            takenAt: seconds * 1_000_000_000,
            cpu: Dictionary(uniqueKeysWithValues: cpu.map { (key($0.key), $0.value) }),
            memory: Dictionary(uniqueKeysWithValues: memory.map { (key($0.key), $0.value) }))
    }

    @Test func keepsTenMinutes() {
        var history = ResourceHistory()
        for second in stride(from: 0.0, through: 900, by: 30) { history.add(sample(second)) }
        #expect(history.samples.first?.time == start.addingTimeInterval(300))
        #expect(history.samples.last?.time == start.addingTimeInterval(900))
        #expect(history.samples.count == 21)
    }

    @Test func boundedByCount() {
        var history = ResourceHistory()
        for i in 0..<(ResourceHistory.capacity + 50) { history.add(sample(Double(i) * 0.1)) }
        #expect(history.samples.count == ResourceHistory.capacity)
        #expect(history.latest?.time == start.addingTimeInterval(Double(ResourceHistory.capacity + 49) * 0.1))
    }

    @Test func clockGoingBackStartsOver() {
        var history = ResourceHistory()
        history.add(sample(100))
        history.add(sample(130))
        history.add(sample(50))
        #expect(history.samples == [sample(50)])
    }

    @Test func memoryIsTheSumOfTheTree() {
        let snap = snapshot(at: 1, cpu: [1: 0, 2: 0, 3: 0], memory: [1: 300 << 20, 2: 200 << 20, 3: 12 << 20])
        #expect(snap.memoryBytes == 512 << 20)
        #expect(ProcessTree.Snapshot(takenAt: 0, cpu: [:]).memoryBytes == 0)
    }

    @Test func realProcessHasMemory() {
        let snap = ProcessTree.snapshot(root: getpid())
        #expect(snap.memoryBytes > 1 << 20)
        #expect(snap.memory.keys == snap.cpu.keys)
    }

    @Test func samplerNeedsABaselineThenMeasures() {
        var sampler = ResourceSampler()
        sampler.record(snapshot(at: 10, cpu: [1: 0, 2: 0], memory: [1: 100, 2: 50]), root: 1, at: start)
        #expect(sampler.history.isEmpty)
        #expect(sampler.isTracking)
        // 1.5 s of CPU in 10 s: 15%
        sampler.record(snapshot(at: 20, cpu: [1: 1_000_000_000, 2: 500_000_000], memory: [1: 120, 2: 60]),
                       root: 1, at: start.addingTimeInterval(10))
        #expect(sampler.history.samples.count == 1)
        #expect(abs((sampler.history.latest?.cpuPercent ?? 0) - 15) < 0.001)
        #expect(sampler.history.latest?.memoryBytes == 180)
    }

    @Test func aNewRunStartsANewHistory() {
        var sampler = ResourceSampler()
        sampler.record(snapshot(at: 10, cpu: [1: 0], memory: [1: 100]), root: 1, at: start)
        sampler.record(snapshot(at: 20, cpu: [1: 1_000_000_000], memory: [1: 100]), root: 1, at: start.addingTimeInterval(10))
        #expect(sampler.history.samples.count == 1)
        sampler.stop()
        #expect(!sampler.isTracking)
        #expect(sampler.history.samples.count == 1)
        sampler.record(snapshot(at: 30, cpu: [9: 0], memory: [9: 100]), root: 9, at: start.addingTimeInterval(20))
        #expect(sampler.history.isEmpty)
    }

    @Test func anEmptyTreeIsNotASample() {
        var sampler = ResourceSampler()
        sampler.record(snapshot(at: 10, cpu: [1: 0], memory: [1: 100]), root: 1, at: start)
        sampler.record(snapshot(at: 20, cpu: [:], memory: [:]), root: 1, at: start.addingTimeInterval(10))
        #expect(sampler.history.isEmpty)
    }

    @Test func text() {
        #expect(ResourceText.cpu(0) == "0%")
        #expect(ResourceText.cpu(12.4) == "12%")
        #expect(ResourceText.cpu(250.6) == "251%")
        #expect(ResourceText.cpu(-3) == "0%")
        #expect(ResourceText.cpu(.nan) == "0%")
        #expect(ResourceText.memory(640 << 10) == "640 KB")
        #expect(ResourceText.memory(812 << 20) == "812 MB")
        #expect(ResourceText.memory(UInt64(1.4 * Double(1 << 30))) == "1.4 GB")
        #expect(ResourceText.memory(999 << 20) == "999 MB")
        #expect(ResourceText.memory(1020 << 20) == "1.0 GB")
    }
}

@Suite("Resource chart scales")
struct ResourceScaleTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func samples(_ seconds: [TimeInterval]) -> [ResourceSample] {
        seconds.map { ResourceSample(time: start.addingTimeInterval($0), cpuPercent: 1, memoryBytes: 1) }
    }

    /// A fresh bench fills the width: the axis starts at its first sample.
    @Test func timeGrowsFromTheFirstSampleToTenMinutes() {
        let fresh = ResourceScale.time(samples([0, 30, 90]))
        #expect(fresh.lowerBound == start && fresh.upperBound == start.addingTimeInterval(90))
        let tiny = ResourceScale.time(samples([0, 5]))
        #expect(tiny.upperBound.timeIntervalSince(tiny.lowerBound) == 60)
        let long = ResourceScale.time(samples([0, 900]))
        #expect(long.upperBound.timeIntervalSince(long.lowerBound) == ResourceHistory.window)
    }

    @Test func cpuStartsAtZeroMemoryAroundItsRange() {
        #expect(ResourceScale.cpu([0.2, 1]) == 0...5)
        #expect(ResourceScale.cpu([100]).upperBound > 100)
        let mb = 1_048_576.0
        let flat = ResourceScale.memory([424 * mb, 425 * mb])
        #expect(flat.lowerBound > 0 && flat.lowerBound < 424 * mb && flat.upperBound > 425 * mb)
        // a flat line sits near the middle, not on the top edge
        let middle = (flat.lowerBound + flat.upperBound) / 2
        #expect(abs(middle - 424.5 * mb) < mb)
    }
}
