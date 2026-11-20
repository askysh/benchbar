import Foundation
import Testing
@testable import BenchBar

/// The result envelope (docs/json-schema.md): one decoder for the done line of a stream, the document of
/// a command that changed things and the document of a read.
@Suite struct ResultEnvelopeTests {
    @Test func doneLineWithObjectsReadsEveryField() {
        let stdout = """
        {"schema_version":1,"cli_version":"0.9.0","event":"step","id":"x","status":"done"}
        {"schema_version":1,"cli_version":"0.9.0","event":"done","exit":0,"changed":[{"kind":"site","name":"a.localhost","detail":"created"}],"warnings":["one"],"next_actions":[{"command":"benchbar up","why":"start it","quoted":true}],"state_after":null}
        """
        let e = ResultEnvelope.parse(stdout)
        #expect(e.exit == 0)
        #expect(e.succeeded)
        #expect(e.error == nil)
        #expect(e.changed == [.init(kind: "site", name: "a.localhost", detail: "created")])
        #expect(e.warnings == ["one"])
        #expect(e.nextActions == [.init(command: "benchbar up", why: "start it", quoted: true)])
    }

    @Test func failureCarriesTheErrorAndTheMissingInputs() {
        let stdout = #"{"schema_version":1,"cli_version":"0.9.0","event":"done","exit":2,"error":"Cannot start, missing: --yes","missing":["--yes","ADMIN_PASSWORD"],"error_id":"sudo_password_wrong","changed":[],"warnings":[],"next_actions":[]}"#
        let e = ResultEnvelope.parse(stdout)
        #expect(e.exit == 2)
        #expect(!e.succeeded)
        #expect(e.error == "Cannot start, missing: --yes")
        #expect(e.missing == ["--yes", "ADMIN_PASSWORD"])
        #expect(e.errorID == "sudo_password_wrong")
    }

    @Test func aReadDocumentWithExitIsAnEnvelopeToo() {
        let e = ResultEnvelope.parse(#"{"schema_version":1,"cli_version":"0.9.0","labs":[],"exit":0}"#)
        #expect(e.exit == 0)
        #expect(e.changed.isEmpty && e.warnings.isEmpty && e.nextActions.isEmpty)
    }

    @Test func aFieldOfAnotherTypeCostsOnlyThatField() {
        // a newer CLI: warnings as an object, changed as a number; the exit and the next actions still read
        let e = ResultEnvelope.parse(#"{"event":"done","exit":1,"warnings":{"a":1},"changed":3,"next_actions":["benchbar doctor"],"error":"x"}"#)
        #expect(e.exit == 1)
        #expect(e.warnings.isEmpty && e.changed.isEmpty)
        #expect(e.nextActions == [.init(command: "benchbar doctor", why: "", quoted: false)])
    }

    @Test func noLineWithAnExitIsAnEmptyEnvelope() {
        #expect(ResultEnvelope.parse("").exit == nil)
        #expect(ResultEnvelope.parse("[OK] fine\nnot json").exit == nil)
        // a line of text after the document does not hide it
        #expect(ResultEnvelope.parse("{\"exit\":0}\n[OK] later").exit == 0)
    }

    @Test func aFailedRunSaysWhatTheEnvelopeSays() async {
        let out = CommandOutput(exitCode: 1, stdout: #"{"schema_version":1,"cli_version":"0.9.0","event":"done","exit":1,"error":"No bench at /x."}"# + "\n", stderr: "[FAIL] noise\n")
        let runner = FakeRunner { _ in out }
        let client = CLIClient(executable: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
        await #expect {
            try await client.run(["up", "--json"], timeout: .seconds(5), acceptExitCodes: [0])
        } throws: { error in
            guard case CLIError.failed(_, let code, let message) = error else { return false }
            return code == 1 && message == "No bench at /x."
        }
    }
}
