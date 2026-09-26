import Foundation
import Observation

/// One repair from the app: the plan from `repair --dry-run --json`, the
/// user's yes, then `repair --yes --json` with a live step list. The app
/// never repairs on its own and passes --yes nowhere else in this flow.
@Observable
final class RepairRun {
    enum Phase: Equatable {
        case planning
        case review
        case running
        case finished(exitCode: Int)
        case failed(String)
    }

    nonisolated struct StepState: Equatable, Sendable, Identifiable {
        var id: String
        var label: String
        var sudo: Bool
        var status: String = "pending"
        var message: String = ""
    }

    private(set) var phase: Phase = .planning
    private(set) var steps: [StepState] = []
    private(set) var log: String?

    let bench: BenchModel
    private let store: BenchStore

    init(bench: BenchModel, store: BenchStore) {
        self.bench = bench
        self.store = store
    }

    var hasSudoSteps: Bool { steps.contains(where: \.sudo) }
    var succeeded: Bool { phase == .finished(exitCode: 0) }

    func loadPlan() async {
        guard let client = store.cliClient else { phase = .failed("The benchbar command line tool is not available."); return }
        phase = .planning
        do {
            let actions = try await client.repairPlan(bench: bench.path)
            steps = actions.map { StepState(id: $0.id, label: $0.label, sudo: $0.sudo) }
            phase = .review
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// The user said yes to the plan.
    func run() async {
        guard phase == .review else { return }
        phase = .running
        var exit: Int32 = 1
        let error = await store.runChange("Repair", on: bench) { client throws(CLIError) in
            exit = try await client.repair(bench: bench.path) { event in
                Task { @MainActor in self.apply(event) }
            }
        }
        // let the last events land before the phase settles
        await Task.yield()
        if let error, phase == .running {
            phase = .failed(error)
        } else if phase == .running {
            phase = .finished(exitCode: Int(exit))
        }
        await store.runDoctor(on: bench)
    }

    func apply(_ event: RepairEvent) {
        switch event {
        case .plan(let actions, let log):
            self.log = log
            // the real run's plan wins: the bench may have changed since the dry run
            steps = actions.map { a in
                steps.first { $0.id == a.id }.map { var s = $0; s.label = a.label; return s }
                    ?? StepState(id: a.id, label: a.label, sudo: a.sudo)
            }
        case .step(let action, let status, let message):
            if let i = steps.firstIndex(where: { $0.id == action }) {
                steps[i].status = status
                if !message.isEmpty, status != "running" { steps[i].message = message }
            }
        case .done(let exitCode, let log):
            if let log { self.log = log }
            phase = .finished(exitCode: exitCode)
        }
    }
}
