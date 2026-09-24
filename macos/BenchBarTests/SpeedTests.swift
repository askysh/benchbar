import Darwin
import Foundation
import Testing
@testable import BenchBar

@Suite("Speed")
struct SpeedTests {
    @Test func cpuMapsToSpeedWithinOneToTwelve() {
        #expect(SpeedMapping.speed(cpuPercent: 0) == 1)
        #expect(SpeedMapping.speed(cpuPercent: 5) == 1.5)
        #expect(SpeedMapping.speed(cpuPercent: 50) == 6)
        #expect(SpeedMapping.speed(cpuPercent: 110) == 12)
        #expect(SpeedMapping.speed(cpuPercent: 800) == 12)
        #expect(SpeedMapping.speed(cpuPercent: -3) == 1)
        #expect(SpeedMapping.speed(cpuPercent: .nan) == 1)
    }

    @Test func smootherMovesPartWayAndResets() {
        var smoother = SpeedSmoother(alpha: 0.5)
        #expect(smoother.value == 1)
        let steps = [11.0, 11, 1].map { smoother.add($0) }
        #expect(steps == [6, 8.5, 4.75])
        smoother.reset()
        #expect(smoother.value == 1)
    }

    @Test func oneSpikeDoesNotReachTopSpeed() {
        var smoother = SpeedSmoother()
        let after = smoother.add(12)
        #expect(after > 1 && after < 6)
    }

    // MARK: CPU delta math, with made up snapshots

    typealias Key = ProcessTree.Key

    @Test func cpuPercentCountsGrowthOverTheWindow() {
        let a = Key(pid: 10, startTime: 1), b = Key(pid: 11, startTime: 1)
        let old = ProcessTree.Snapshot(takenAt: 1_000_000_000, cpu: [a: 100, b: 500])
        // one second later: a used 0.5 s, b used 0.25 s
        let new = ProcessTree.Snapshot(takenAt: 2_000_000_000, cpu: [a: 500_000_100, b: 250_000_500])
        #expect(abs(ProcessTree.cpuPercent(from: old, to: new) - 75) < 0.001)
    }

    @Test func exitedProcessesDoNotMakeItNegative() {
        let a = Key(pid: 10, startTime: 1), gone = Key(pid: 12, startTime: 1)
        let old = ProcessTree.Snapshot(takenAt: 0, cpu: [a: 0, gone: 9_000_000_000])
        let new = ProcessTree.Snapshot(takenAt: 1_000_000_000, cpu: [a: 100_000_000])
        #expect(abs(ProcessTree.cpuPercent(from: old, to: new) - 10) < 0.001)
    }

    @Test func reusedPidIsANewProcess() {
        // pid 10 exited and a new pid 10 started inside the window: count all its time
        let old = ProcessTree.Snapshot(takenAt: 1_000, cpu: [Key(pid: 10, startTime: 1): 999_999])
        let reborn = Key(pid: 10, startTime: UInt64.max / 1_000_000)
        let new = ProcessTree.Snapshot(takenAt: 1_000 + 1_000_000_000, cpu: [reborn: 200_000_000])
        let percent = ProcessTree.cpuPercent(from: old, to: new)
        #expect(percent > 0)
    }

    @Test func sameInstantIsZero() {
        let snap = ProcessTree.Snapshot(takenAt: 5, cpu: [:])
        #expect(ProcessTree.cpuPercent(from: snap, to: snap) == 0)
    }

    // MARK: the real thing, against a busy child process

    @Test func liveTreeSeesABusyChild() async throws {
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        busy.standardOutput = FileHandle.nullDevice
        try busy.run()
        defer { busy.terminate(); busy.waitUntilExit() }

        let me = getpid()
        #expect(ProcessTree.pids(under: me).contains(busy.processIdentifier))

        let source = ProcessTreeCPUSource()
        let target = SpeedTarget(bench: "/tmp/x", pid: busy.processIdentifier)
        #expect(await source.sample(target) == nil, "the first sample is only a baseline")
        try await Task.sleep(for: .milliseconds(600))
        let speed = try #require(await source.sample(target))
        // yes keeps one core busy: close to 100%, so near the top speed
        #expect(speed > 5, "speed was \(speed)")
    }

    @Test func missingProcessGivesNoSpeed() async {
        let source = ProcessTreeCPUSource()
        let target = SpeedTarget(bench: "/tmp/x", pid: 999_999)
        #expect(await source.sample(target) == nil)
        #expect(await source.sample(target) == nil)
    }

    @Test func machTimeConvertsToNanoseconds() {
        let start = MachTime.nanoseconds(mach_absolute_time())
        Thread.sleep(forTimeInterval: 0.05)
        let elapsed = MachTime.nanoseconds(mach_absolute_time()) - start
        #expect(elapsed > 40_000_000 && elapsed < 500_000_000)
    }
}

@Suite("Activity gate")
struct ActivityGateTests {
    @Test func idleUntilEveryReasonClears() {
        var gate = ActivityGate()
        #expect(gate.isActive)
        let flips = [
            gate.set(.screenLocked, idle: true),   // active to idle
            gate.set(.systemSleep, idle: true),    // already idle
            gate.set(.systemSleep, idle: false),   // still locked
        ]
        #expect(flips == [true, false, false])
        #expect(!gate.isActive)
        let unlocked = gate.set(.screenLocked, idle: false)
        #expect(unlocked)
        #expect(gate.isActive)
    }

    @Test func aWakeWithoutASleepChangesNothing() {
        var gate = ActivityGate()
        let flipped = gate.set(.screenSleep, idle: false)
        #expect(!flipped)
        #expect(gate.isActive)
    }
}
