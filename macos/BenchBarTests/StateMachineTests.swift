import Foundation
import Testing
@testable import BenchBar

@Suite("State machine")
struct StateMachineTests {
    func status(_ state: BenchState, _ reason: StopReason? = nil, exit: Int? = nil) -> BenchStatus {
        BenchStatus(schemaVersion: 1, bench: "/b", state: state, stopReason: reason, lastExitCode: exit)
    }

    @Test func startsUnknownAndFirstAnswerNeverAlerts() {
        var machine = BenchStateMachine()
        #expect(machine.state == .unknown)
        #expect(machine.handle(.observed(status(.paused, .crash), .status)) == [])
        #expect(machine.state == .paused)
        #expect(machine.stopReason == .crash)
    }

    @Test func runningToCrashedAlertsWithTheExitCode() {
        var machine = BenchStateMachine()
        _ = machine.handle(.observed(status(.running), .status))
        #expect(machine.handle(.observed(status(.crashed, .crash, exit: 3), .stateFile)) == [.alert(.crashed(exitCode: 3))])
    }

    @Test func crashLoopAlertsOnceWhenTheGuardTrips() {
        var machine = BenchStateMachine()
        _ = machine.handle(.observed(status(.running), .status))
        var alerts: [BenchEffect] = []
        alerts += machine.handle(.observed(status(.crashed, .crash, exit: 1), .stateFile))
        alerts += machine.handle(.observed(status(.starting), .stateFile))
        alerts += machine.handle(.observed(status(.crashed, .crash, exit: 1), .stateFile))
        alerts += machine.handle(.observed(status(.paused, .crash), .stateFile))
        #expect(alerts == [.alert(.crashed(exitCode: 1)), .alert(.crashGuardTripped)])
    }

    @Test func aPollThatMissedTheCrashStillReportsTheGuard() {
        var machine = BenchStateMachine()
        _ = machine.handle(.observed(status(.running), .status))
        #expect(machine.handle(.observed(status(.paused, .crash), .status)) == [.alert(.crashGuardTripped)])
    }

    @Test func brokenPauseIsNotACrashAlert() {
        var machine = BenchStateMachine()
        _ = machine.handle(.observed(status(.running), .status))
        #expect(machine.handle(.observed(status(.paused, .broken), .status)) == [])
    }

    @Test func pausedToRunningIsARecovery() {
        var machine = BenchStateMachine()
        _ = machine.handle(.observed(status(.paused, .crash), .status))
        _ = machine.handle(.observed(status(.starting), .status))
        #expect(machine.handle(.observed(status(.running), .status)) == [])
        var direct = BenchStateMachine()
        _ = direct.handle(.observed(status(.paused, .crash), .status))
        #expect(direct.handle(.observed(status(.running), .status)) == [.alert(.recovered)])
    }

    @Test func manualStopIsQuiet() {
        var machine = BenchStateMachine()
        _ = machine.handle(.observed(status(.running), .status))
        #expect(machine.handle(.observed(status(.stopped, .manual), .status)) == [])
    }

    @Test func startIsOptimisticAndPingsWhenDone() {
        var machine = BenchStateMachine()
        _ = machine.handle(.observed(status(.stopped, .manual), .status))
        #expect(machine.handle(.actionStarted(.up)) == [])
        #expect(machine.state == .starting)
        #expect(machine.pending == .up)
        #expect(machine.handle(.actionFinished(.up, succeeded: true)) == [.pingSite, .refresh])
        #expect(machine.pending == nil)
    }

    @Test func staleAnswersDuringAnActionAreIgnored() {
        var machine = BenchStateMachine()
        _ = machine.handle(.observed(status(.stopped, .manual), .status))
        _ = machine.handle(.actionStarted(.up))
        _ = machine.handle(.observed(status(.stopped, .manual), .status))
        #expect(machine.state == .starting)
        _ = machine.handle(.observed(status(.running), .stateFile))
        #expect(machine.state == .running)
        _ = machine.handle(.actionFinished(.up, succeeded: true))

        _ = machine.handle(.actionStarted(.down))
        _ = machine.handle(.observed(status(.running), .status))
        #expect(machine.state == .running)
        #expect(machine.pending == .down)
        _ = machine.handle(.observed(status(.stopped, .manual), .stateFile))
        #expect(machine.state == .stopped)
    }

    @Test func failedStartOnlyRefreshes() {
        var machine = BenchStateMachine()
        _ = machine.handle(.actionStarted(.restart))
        #expect(machine.handle(.actionFinished(.restart, succeeded: false)) == [.refresh])
    }

    @Test func missingCLIGoesUnknown() {
        var machine = BenchStateMachine()
        _ = machine.handle(.observed(status(.running), .status))
        _ = machine.handle(.cliUnavailable)
        #expect(machine.state == .unknown)
        #expect(machine.pending == nil)
    }
}
