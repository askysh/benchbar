import Foundation
import Testing
@testable import BenchBar

@Suite("Popover logic")
struct PresentationTests {
    func controls(_ state: BenchState, _ reason: StopReason? = nil, pending: CLIClient.Action? = nil,
                  needsService: Bool = false, cliReady: Bool = true) -> BenchControls {
        .make(state: state, reason: reason, pending: pending, needsService: needsService, cliReady: cliReady)
    }

    @Test func buttonsFollowTheState() {
        #expect(controls(.stopped, .manual) == BenchControls(canStart: true))
        #expect(controls(.starting) == BenchControls(canStop: true, canRestart: true))
        #expect(controls(.running) == BenchControls(canStop: true, canRestart: true))
        #expect(controls(.crashed, .crash) == BenchControls(canStop: true, canRestart: true))
        #expect(controls(.paused, .crash) == BenchControls(canStart: true))
        #expect(controls(.unknown) == BenchControls(canStart: true, canStop: true))
    }

    @Test func brokenBenchCannotStart() {
        #expect(controls(.stopped, .broken) == .none)
        #expect(controls(.paused, .broken) == .none)
    }

    @Test func nothingWhileBusyOrWithoutAgentOrCLI() {
        #expect(controls(.running, pending: .restart) == BenchControls(busy: .restart))
        #expect(controls(.stopped, needsService: true) == .none)
        #expect(controls(.stopped, cliReady: false) == .none)
    }

    @Test func headlines() {
        #expect(BenchText.headline(.stopped, reason: .manual, exitCode: nil) == "Stopped")
        #expect(BenchText.headline(.stopped, reason: .broken, exitCode: nil) == "Stopped: needs repair")
        #expect(BenchText.headline(.crashed, reason: .crash, exitCode: 3) == "Crashed (exit 3), restarting")
        #expect(BenchText.headline(.paused, reason: .crash, exitCode: nil) == "Paused after repeated crashes")
        #expect(BenchText.headline(.paused, reason: .broken, exitCode: nil) == "Paused: needs repair")
        #expect(BenchText.headline(.running, reason: nil, exitCode: nil) == "Running")
    }

    @Test func uptimeIsShortAndReadable() {
        let start = Date(timeIntervalSince1970: 0)
        func up(_ seconds: TimeInterval) -> String { BenchText.uptime(since: start, now: start + seconds) }
        #expect(up(-5) == "0s")
        #expect(up(45) == "45s")
        #expect(up(12 * 60 + 5) == "12m")
        #expect(up(3 * 3600 + 5 * 60) == "3h 05m")
        #expect(up(2 * 86400 + 4 * 3600 + 59) == "2d 4h")
    }

    @Test func doctorPutsFailuresFirstAndSplitsPassing() throws {
        let report = try BenchJSON.decode(DoctorReport.self, from: Fixture.data("doctor"))
        let levels = report.needsAttention.map(\.level)
        #expect(levels == levels.sorted { rank($0) < rank($1) })
        #expect(!levels.contains(.ok))
        #expect(report.passing.allSatisfy { $0.level == .ok })
        #expect(report.needsAttention.count + report.passing.count == report.checks.count)
    }

    func rank(_ level: CheckLevel) -> Int { [.fail: 0, .warn: 1, .unknown: 2, .ok: 3][level]! }

    @Test func shellQuotingIsSafe() {
        #expect(Shell.quote("/Users/me/frappe-bench") == "/Users/me/frappe-bench")
        #expect(Shell.quote("/Users/me/my bench") == "'/Users/me/my bench'")
        #expect(Shell.quote("it's") == "'it'\\''s'")
        #expect(Shell.quote("") == "''")
        #expect(Shell.quote("a;rm -rf x") == "'a;rm -rf x'")
    }

    @Test func logsScriptFollowsTheLogThroughTheCLI() {
        let script = LogsScript.contents(cli: "/Users/me/.local/bin/benchbar", bench: "/Users/me/my bench")
        #expect(script.hasPrefix("#!/bin/zsh\n"))
        #expect(script.contains("exec /Users/me/.local/bin/benchbar logs -n200 --bench-dir '/Users/me/my bench'"))
    }

    @Test func repairCommandForTheBanner() {
        #expect(BenchText.command("repair", bench: "/b/x") == "benchbar repair --bench-dir /b/x")
    }

    @Test func launchAtLoginStatusMapping() {
        #expect(LaunchAtLogin.map(.enabled) == .enabled)
        #expect(LaunchAtLogin.map(.notRegistered) == .disabled)
        #expect(LaunchAtLogin.map(.requiresApproval) == .requiresApproval)
        #expect(LaunchAtLogin.map(.notFound) == .notFound)
    }
}
