import Foundation
import Observation

/// One approval covers the complete allocation, revalidated by the CLI under its lock.
@Observable
final class PortSetupRun: Identifiable {
    enum Phase: Equatable { case planning, review, running, finished, failed(String) }
    private(set) var phase: Phase = .planning
    private(set) var plan: PortPlan?
    private(set) var output = ""
    private(set) var modeError: String?
    let summaries: [BenchSummary]
    let startAfterSetup: Bool
    let store: BenchStore

    init(summaries: [BenchSummary], store: BenchStore, startAfterSetup: Bool = false) {
        self.summaries = summaries
        self.store = store
        self.startAfterSetup = startAfterSetup && summaries.count == 1
    }

    var title: String { startAfterSetup ? "Resolve port conflict" : "Set up selected benches" }
    var isBusy: Bool { phase == .planning || phase == .running }

    func loadPlan() async {
        guard let client = store.cliClient else { phase = .failed("The benchbar command is unavailable."); return }
        phase = .planning
        plan = nil
        do {
            plan = try await client.portPlan(benches: summaries.map(\.path))
            phase = .review
        } catch { phase = .failed(error.localizedDescription) }
    }

    func setMode(_ mode: PortMode, path: String) async {
        guard phase == .review, let summary = summaries.first(where: { $0.path == path }) else { return }
        phase = .running; modeError = nil
        let anchor = store.benches.first(where: { $0.path == path }) ?? BenchModel(summary: summary)
        modeError = await store.runChange("Saving port mode", on: anchor) { client throws(CLIError) in
            try await client.setPortMode(mode, bench: path)
        }
        await loadPlan()
    }

    func apply() async {
        guard phase == .review, let plan, plan.canApply, let summary = summaries.first else { return }
        phase = .running
        let anchor = store.benches.first(where: { $0.path == summary.path }) ?? BenchModel(summary: summary)
        let error = await store.runChange("Setting up benches", on: anchor) { client throws(CLIError) in
            let result = try await client.applyPortPlan(plan)
            self.output = result.stdout + result.stderr
            guard result.exitCode == 0 else {
                let failures = self.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("[FAIL]") }.suffix(3)
                throw CLIError.failed(command: "ports apply", exitCode: result.exitCode,
                    message: failures.isEmpty ? CLIClient.summarize(result) : failures.joined(separator: "\n"))
            }
            if self.startAfterSetup {
                let check = try await client.portCheck(bench: summary.path)
                guard check.conflicts.isEmpty else {
                    throw CLIError.failed(command: "ports", exitCode: 1,
                        message: "Setup completed, but a port is now occupied. The bench was not started. " + check.conflicts.joined(separator: "\n"))
                }
                let started = try await client.perform(.up, bench: summary.path)
                self.output += "\n" + started.stdout + started.stderr
            }
        }
        if let error {
            // A batch may have completed earlier entries. Always refresh what actually exists.
            await store.reloadBenches()
            phase = .failed(error)
        } else if summaries.allSatisfy({ summary in store.benches.contains { $0.path == summary.path && !$0.needsService } }) {
            for bench in store.benches where summaries.contains(where: { $0.path == bench.path }) {
                bench.portConflict = nil; bench.lastError = nil
            }
            phase = .finished
        } else {
            phase = .failed("Setup returned, but some services were not found. Review the output and run Doctor.")
        }
    }
}
