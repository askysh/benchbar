import Foundation
import Testing
@testable import BenchBar

@Suite("Port setup", .serialized)
struct PortSetupTests {
    let base: BenchStoreTests
    init() throws { base = try BenchStoreTests() }

    func planJSON(blocked: Bool = false, mode: String = "automatic") -> String {
        """
        {"schema_version":1,"token":"reviewed-token","can_apply":\(!blocked),"entries":[
        {"path":"\(base.benchPath)","name":"frappe-bench","site":"macdev","mode":"\(mode)",
        "current":{"web":8000,"socketio":9000,"redis_queue":11000,"redis_cache":13000},
        "proposed":{"web":8001,"socketio":9001,"redis_queue":11001,"redis_cache":13001},
        "conflicts":["8000 has a listener"],"blocked":\(blocked ? "\"Fixed ports conflict\"" : "null"),"service_installed":true,"setup_plan":"Write Procfile.lean, runner and LaunchAgent; add hosts entry"}]}
        """
    }

    func setup(start: Bool = false, blocked: Bool = false) async throws -> (BenchStore, PortSetupRun) {
        base.cli.answer("list", json: base.listJSON())
        base.cli.answer("status", json: base.statusJSON("stopped"))
        base.cli.answer("ports plan", json: planJSON(blocked: blocked))
        base.cli.answer("ports apply", .ok("Completed: bench"))
        base.cli.answer("ports check", json: #"{"schema_version":1,"conflicts":[],"mode":"automatic"}"#)
        base.cli.answer("up", .ok("bench is up"))
        let store = base.makeStore()
        await store.start(polling: false)
        let bench = try #require(store.selected)
        return (store, PortSetupRun(summaries: [bench.summary], store: store, startAfterSetup: start))
    }

    @Test func previewDoesNotApplyAndApplyRequiresReview() async throws {
        let (_, run) = try await setup()
        await run.apply()
        #expect(!base.cli.calls.contains { $0.starts(with: ["ports", "apply"]) })
        await run.loadPlan()
        #expect(run.phase == .review)
        #expect(run.plan?.entries.first?.setupPlan == "Write Procfile.lean, runner and LaunchAgent; add hosts entry")
        #expect(run.plan?.entries.first?.currentURL == "http://macdev:8000")
        #expect(run.plan?.entries.first?.proposedURL == "http://macdev:8001")
        #expect(!base.cli.calls.contains { $0.contains("--yes") })
        await run.apply()
        #expect(run.phase == .finished)
        #expect(base.cli.calls.contains(["ports", "apply", "reviewed-token", "--yes", "--plain", "--", base.benchPath]))
        #expect(!base.cli.calls.contains { $0.first == "up" })
    }

    @Test func missingServicePreviewPreventsApproval() async throws {
        let (_, run) = try await setup()
        base.cli.answer("ports plan", json: planJSON().replacingOccurrences(of: ",\"setup_plan\":\"Write Procfile.lean, runner and LaunchAgent; add hosts entry\"", with: ""))
        await run.loadPlan()
        await run.apply()
        guard case .failed(let message) = run.phase else { Issue.record("Expected missing-preview failure"); return }
        #expect(message.contains("Upgrade benchbar"))
        #expect(!base.cli.calls.contains { $0.starts(with: ["ports", "apply"]) })
    }

    @Test func fixedConflictBlocksApply() async throws {
        let (_, run) = try await setup(blocked: true)
        await run.loadPlan()
        await run.apply()
        #expect(run.phase == .review)
        #expect(!base.cli.calls.contains { $0.starts(with: ["ports", "apply"]) })
    }

    @Test func stalePlanFailureDoesNotStartAndRefreshesActualState() async throws {
        let (_, run) = try await setup(start: true)
        base.cli.answer("ports apply", CommandOutput(exitCode: 1, stdout: "", stderr: "[FAIL] The port plan changed. Review a fresh preview."))
        await run.loadPlan()
        await run.apply()
        guard case .failed(let message) = run.phase else { Issue.record("Expected failure"); return }
        #expect(message.contains("plan changed"))
        #expect(!base.cli.calls.contains { $0.first == "up" })
        #expect(base.cli.calls.filter { $0.first == "list" }.count >= 2)
    }

    @Test func batchFailureKeepsCompletedOutputAndFinalFailure() async throws {
        let (_, run) = try await setup()
        let output = "  [WARN] one\n  [WARN] two\n  [WARN] three\n  [OK] Completed: first\n  [FAIL] Setup failed: second. Earlier completed benches remain configured."
        base.cli.answer("ports apply", CommandOutput(exitCode: 1, stdout: output, stderr: ""))
        await run.loadPlan()
        await run.apply()
        guard case .failed(let message) = run.phase else { Issue.record("Expected failure"); return }
        #expect(message.contains("Setup failed: second"))
        #expect(run.output.contains("Completed: first"))
    }

    @Test func detachedModelsForSamePathCannotOverlapChanges() async throws {
        let (store, _) = try await setup()
        let summary = try #require(store.selected).summary
        let first = BenchModel(summary: summary)
        let second = BenchModel(summary: summary)
        let result = await store.runChange("First", on: first) { _ throws(CLIError) in
            let secondResult = await store.runChange("Second", on: second) { _ throws(CLIError) in
                Issue.record("A second detached model must not acquire the same change slot")
            }
            #expect(secondResult?.contains("Another change") == true)
            #expect(store.busyBench === first)
        }
        #expect(result == nil)
        #expect(store.busyBench == nil)
    }

    @Test func resolveAndStartChecksAgainAfterApply() async throws {
        let (_, run) = try await setup(start: true)
        base.cli.answer("ports check", json: #"{"schema_version":1,"conflicts":["8001 was just occupied"],"mode":"automatic"}"#)
        await run.loadPlan()
        await run.apply()
        guard case .failed(let message) = run.phase else { Issue.record("Expected failure"); return }
        #expect(message.contains("not started"))
        #expect(!base.cli.calls.contains { $0.first == "up" })
    }

    @Test func confirmedResolveStartsOnlyAfterApplyAndCheck() async throws {
        let (_, run) = try await setup(start: true)
        await run.loadPlan()
        await run.apply()
        #expect(run.phase == .finished)
        let commands = base.cli.calls.filter { $0.first == "ports" || $0.first == "up" }.map { $0.prefix(2).joined(separator: " ") }
        #expect(commands == ["ports plan", "ports apply", "ports check", "up --plain"])
    }

    @Test func savingModeRefreshesPreviewWithoutApplying() async throws {
        let (_, run) = try await setup()
        base.cli.answer("ports mode", .ok("Saved"))
        await run.loadPlan()
        await run.setMode(.fixed, path: base.benchPath)
        #expect(base.cli.calls.contains(["ports", "mode", "fixed", "--bench-dir", base.benchPath, "--plain"]))
        #expect(base.cli.calls.filter { $0.starts(with: ["ports", "plan"]) }.count == 2)
        #expect(!base.cli.calls.contains { $0.starts(with: ["ports", "apply"]) })
    }
}
