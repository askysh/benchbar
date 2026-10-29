import Foundation

/// A plan the Add App and Add Site sheets can show before anything runs.
nonisolated protocol ReviewablePlan: Equatable, Sendable {
    /// The plan can run and has something to do.
    var canRun: Bool { get }
}

nonisolated extension AppAddPlan: ReviewablePlan {
    var canRun: Bool { canApply && changes }
}

/// Where an Add App or Add Site sheet is: the form, reading the plan, the
/// plan on screen, the run, or a plan the CLI no longer accepts. Pure state,
/// no I/O: the sheet does the calls and sends what came back.
nonisolated struct PlanReviewFlow<Plan: ReviewablePlan>: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case form
        case reading
        case reviewing(Plan)
        case applying(Plan)
        /// the CLI refused the token; the message is its own
        case stale(String)
    }

    private(set) var stage = Stage.form
    /// Why the last dry run gave no plan, shown on the form.
    private(set) var readError: String?

    init(stage: Stage = .form, readError: String? = nil) {
        self.stage = stage
        self.readError = readError
    }

    var plan: Plan? {
        switch stage {
        case .reviewing(let plan), .applying(let plan): plan
        default: nil
        }
    }

    var isRunning: Bool { if case .applying = stage { true } else { false } }

    /// Review (or Review Again): the dry run starts. Only from the form or a stale plan.
    mutating func review() -> Bool {
        switch stage {
        case .form, .stale:
            stage = .reading
            readError = nil
            return true
        default:
            return false
        }
    }

    /// The dry run ended: a plan to look at, or the reason there is none.
    mutating func read(_ result: Result<Plan, Workbench.ChangeError>) {
        guard stage == .reading else { return }
        switch result {
        case .success(let plan): stage = .reviewing(plan)
        case .failure(let error): stage = .form; readError = error.message
        }
    }

    /// Back to the form from the plan.
    mutating func edit() {
        if case .reviewing = stage { stage = .form }
    }

    /// Add (or Apply): only for a plan that can run.
    mutating func apply() -> Plan? {
        guard case .reviewing(let plan) = stage, plan.canRun else { return nil }
        stage = .applying(plan)
        return plan
    }

    /// The run ended. A stale token keeps the sheet open on its message; any
    /// other outcome leaves the sheet to close (the change banner has the result).
    mutating func finish(error: String?) -> Bool {
        guard case .applying = stage else { return false }
        if let error, StalePlan.isStale(error) {
            stage = .stale(error)
            return false
        }
        return true
    }
}
