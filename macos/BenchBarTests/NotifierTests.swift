import Testing
@testable import BenchBar

@Suite("Notifications")
struct NotifierTests {
    func content(_ alert: BenchAlert) -> AlertContent {
        .make(alert, benchPath: "/Users/me/frappe-bench", name: "frappe-bench", url: "http://macdev:8000")
    }

    @Test func crashNamesTheExitCode() {
        let c = content(.crashed(exitCode: 3))
        #expect(c.title == "frappe-bench crashed")
        #expect(c.body == "honcho exited with code 3. launchd is restarting it.")
        #expect(content(.crashed(exitCode: nil)).body.contains("stopped unexpectedly"))
    }

    @Test func crashGuardSaysRestartsArePaused() {
        let c = content(.crashGuardTripped)
        #expect(c.title == "frappe-bench keeps crashing")
        #expect(c.body.contains("automatic restarts are paused"))
    }

    @Test func recoveryGivesTheURL() {
        let c = content(.recovered)
        #expect(c.title == "frappe-bench is running again")
        #expect(c.body == "http://macdev:8000 is back.")
    }

    @Test func oneIdentifierPerBenchAndKind() {
        #expect(content(.crashed(exitCode: 1)).identifier == content(.crashed(exitCode: 2)).identifier)
        #expect(content(.crashed(exitCode: 1)).identifier != content(.recovered).identifier)
        #expect(content(.recovered).thread == "/Users/me/frappe-bench")
        let other = AlertContent.make(.recovered, benchPath: "/b/other", name: "other", url: "")
        #expect(other.identifier != content(.recovered).identifier)
    }
}
