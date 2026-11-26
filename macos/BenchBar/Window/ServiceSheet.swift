import SwiftUI

/// The plan of installing or refreshing the background service: what is written, which step needs the
/// Mac's password, and what stays alone.
struct ServiceInstallPlanView: View {
    let plan: ServiceInstallPlan
    let refresh: Bool

    private var rows: [PlanStepList.Row] {
        plan.pending.map { step in
            PlanStepList.Row(name: step.name, command: nil,
                             note: step.sudo ? String(localized: "Needs your Mac's password. macOS asks in its own dialog; BenchBar never sees it. If you cancel it, this step is skipped.") : nil)
        }
    }

    private var facts: [(label: String, text: String)] {
        [(String(localized: "Writes"), String(localized: "Procfile.lean, the runner script and the launchd agent of this bench, and the helper block of your shell file.")),
         (String(localized: "Left alone"), String(localized: "Your sites, apps and databases. This never runs migrate, build or update."))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
                Text(refresh ? String(localized: "Refresh the service") : String(localized: "Install the service")).font(.headline)
                Text("\(plan.bench)\(plan.site.map { ", site \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            if plan.portsMove {
                SheetNote(String(localized: "This plan moves the bench to another block of ports (offset \(plan.portOffset))."), tint: .orange)
            }
            if plan.pending.isEmpty {
                SheetOutcome(symbol: "checkmark.circle.fill", tint: .green, title: String(localized: "Nothing to do"),
                             detail: String(localized: "The service files of this bench are already as benchbar writes them."))
            } else {
                PlanFacts(facts: facts)
                Text("In order:").font(.callout)
                PlanStepList(rows: rows)
            }
        }
    }
}

/// Install Service or Refresh Service: the CLI's plan first (`service --dry-run --json`), then the
/// run by its token. A token the CLI refuses shows here, with Review Again.
struct ServiceSheet: View {
    struct Start {
        var flow = PlanReviewFlow<ServiceInstallPlan>()
    }

    let workbench: Workbench
    let bench: BenchModel
    let close: () -> Void
    @State private var flow: PlanReviewFlow<ServiceInstallPlan>

    init(workbench: Workbench, bench: BenchModel, start: Start = Start(), close: @escaping () -> Void) {
        self.workbench = workbench
        self.bench = bench
        self.close = close
        _flow = State(initialValue: start.flow)
    }

    private var refresh: Bool { !bench.needsService }
    private var verb: String { refresh ? String(localized: "Refresh Service") : String(localized: "Install Service") }

    private var phase: SheetPhase {
        switch flow.stage {
        case .form: flow.readError.map { .failed($0, title: String(localized: "No plan for the service")) } ?? .loading(String(localized: "Reading the plan (benchbar service --dry-run)…"))
        case .reading: .loading(String(localized: "Reading the plan (benchbar service --dry-run)…"))
        case .reviewing: .ready
        case .applying: .running(refresh ? String(localized: "Refreshing the service…") : String(localized: "Installing the service…"))
        case .stale: .failed(String(localized: "Nothing was changed. Review the plan again to see what it is now."), title: String(localized: "The bench changed since this plan was shown"))
        }
    }

    var body: some View {
        SheetScaffold(String(localized: "\(verb) for \(bench.name)"),
                      explanation: String(localized: "Writes the files that run the bench in the background. You see the plan first; nothing runs until you confirm."),
                      phase: phase) {
            if let plan = flow.plan {
                ServiceInstallPlanView(plan: plan, refresh: refresh)
            }
        } actions: {
            switch flow.stage {
            case .form where flow.readError != nil:
                CancelButton(action: close)
                Button("Try Again") { review() }.keyboardShortcut(.defaultAction)
            case .form, .reading:
                CancelButton(action: close)
            case .reviewing(let plan):
                CancelButton(action: close)
                Button(verb) { apply() }.keyboardShortcut(.defaultAction).disabled(!plan.canRun)
            case .applying:
                EmptyView()
            case .stale:
                CancelButton(action: close)
                Button("Review Again") { review() }.keyboardShortcut(.defaultAction)
            }
        }
        .task { if flow.stage == .form, flow.readError == nil { review() } }
    }

    private func review() {
        guard flow.review() else { return }
        Task { flow.read(await workbench.servicePlan(on: bench)) }
    }

    private func apply() {
        guard let plan = flow.apply() else { return }
        Task {
            let error = await workbench.installService(token: plan.token, refresh: refresh, on: bench)
            if flow.finish(error: error) { close() } else { workbench.result = nil }
        }
    }
}
