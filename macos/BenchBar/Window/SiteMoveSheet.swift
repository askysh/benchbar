import SwiftUI

/// The plan of a move: where it goes, the apps, the new address, the steps, what stays, then the plan's own errors. A running source
/// is answered with the CLI's own "Stop the bench first" and a Stop Bench button in the footer.
struct SiteMovePlanView: View {
    let plan: SiteMovePlan

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
            Text(plan.site).font(.headline)
            if plan.needsStop {
                SheetOutcome(symbol: "stop.circle.fill", tint: .orange, title: SiteMoveText.stopPrefix,
                             detail: plan.nextActions.first { SiteMoveText.isStop($0.command) }?.why)
            }
            if !plan.otherErrors.isEmpty {
                SheetOutcome(symbol: "xmark.octagon.fill", tint: .red, title: "This plan cannot run", detail: plan.otherErrors.joined(separator: "\n"))
            }
            if !plan.needs.isEmpty {
                SheetNote("benchbar needs \(plan.needs.joined(separator: ", ")), which it does not have, and BenchBar never asks for or reads it. Run this move in Terminal, where benchbar can ask.", tint: .orange)
            }
            ForEach(plan.warnings, id: \.self) { SheetNote($0, tint: .orange) }
            if plan.errors.isEmpty {
                PlanFacts(facts: SiteMoveText.facts(plan))
                Text("In order:").font(.callout)
                PlanStepList(rows: plan.steps.map { PlanStepList.Row(name: $0.name, command: nil, note: nil) })
            }
        }
    }
}

/// Pick the bench the site goes to, Review Plan reads the CLI's plan (`site move --dry-run --json`), Move runs it by its token. The move
/// drops the site in this bench (after a second backup), so it needs the site's name typed first and is never the default button. A token
/// the CLI refuses (the bench or a site changed since) shows here with Review Again; a running bench is answered with Stop Bench.
struct SiteMoveSheet: View {
    let workbench: Workbench
    let bench: BenchModel
    let site: String
    let close: () -> Void
    @State private var targetPath = ""
    @State private var noMigrate = false
    @State private var typed = ""
    @State private var flow = PlanReviewFlow<SiteMovePlan>()
    @State private var step = ""
    @State private var finished: SheetResult?
    @State private var failure: String?
    /// Stop Bench was clicked and the stop has not ended: one click only.
    @State private var stopping = false

    private var targets: [BenchModel] { workbench.moveTargets(for: bench) }
    private var chosen: String { targets.contains { $0.path == targetPath } ? targetPath : (targets.first?.path ?? "") }
    private var request: SiteMoveRequest { SiteMoveRequest(site: site, target: chosen, noMigrate: noMigrate) }
    private var isStale: Bool { if case .stale = flow.stage { true } else { false } }

    private var phase: SheetPhase {
        if let finished { return .done(finished) }
        if let failure { return .failed(failure, title: "\(site) was not moved") }
        if stopping { return .loading(SiteMoveText.stopping(bench.name)) }
        switch flow.stage {
        case .form: return flow.readError.map { .failed($0, title: "No plan to move \(site)") } ?? .ready
        case .reading: return .loading("Reading the plan…")
        case .reviewing: return .ready
        case .applying: return .running(step.isEmpty ? String(localized: "Moving \(site)…") : step)
        case .stale: return .failed("Nothing was changed. Review the plan again to see what it is now.", title: "A bench or a site changed since this plan was shown")
        }
    }

    var body: some View {
        SheetScaffold("Move \(site) to Another Bench",
                      explanation: flow.plan == nil
                          ? "Backs the site up, restores it in another bench, checks it there, then drops it here. You see the plan first; nothing runs before you confirm."
                          : "Nothing has run yet. These are the steps; Move runs exactly this plan. The backups stay.",
                      phase: phase, width: .wide) {
            if finished == nil, failure == nil {
                if let plan = flow.plan {
                    VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
                        SiteMovePlanView(plan: plan)
                        if plan.canRun, !flow.isRunning {
                            TextField("Type \(site) to confirm", text: $typed).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                        }
                    }
                } else if flow.stage != .reading, !isStale {
                    form
                }
            }
        } leading: {
            if case .reviewing = flow.stage, finished == nil { Button("Back") { flow.edit() } }
        } actions: {
            if finished != nil || failure != nil {
                DoneButton(title: "Close", action: close)
            } else {
                stageActions
            }
        }
    }

    @ViewBuilder private var stageActions: some View {
        switch flow.stage {
        case .form, .reading:
            CancelButton(action: close)
            Button("Review Plan") { review() }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || flow.stage == .reading)
        case .reviewing(let plan):
            CancelButton(action: close)
            if plan.needsStop {
                Button("Stop Bench") { stopThenReview() }
                    .disabled(!SiteMoveText.canStop(canChange: workbench.store.canChange(bench), stopping: stopping))
                    .help("Stops \(bench.name), then reads the plan again")
            }
            Button("Move", role: .destructive) { apply() }
                .disabled(!plan.canRun || typed != site)
        case .applying:
            EmptyView()
        case .stale:
            CancelButton(action: close)
            Button("Review Again") { review() }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var form: some View {
        Form {
            Picker("Move to", selection: Binding(get: { chosen }, set: { targetPath = $0 })) {
                ForEach(targets) { Text($0.name).tag($0.path) }
            }
            Toggle("Skip migrate", isOn: $noMigrate)
        }
        .formStyle(.columns)
        SheetNote("The site keeps its name. \(bench.name) must be stopped first, and its site is dropped there once the copy checks out; the backups stay.")
        SheetNote("The MariaDB password comes from your Keychain; BenchBar never reads it.")
    }

    private func review() {
        guard flow.review() else { return }
        typed = ""
        Task { flow.read(await workbench.movePlan(request, on: bench)) }
    }

    private func stopThenReview() {
        guard !stopping else { return }
        // set before the task starts: a second click in the same moment finds it already set
        stopping = true
        Task {
            defer { stopping = false }
            if let error = await workbench.stopForMove(bench) {
                failure = error
                return
            }
            flow.edit()
            review()
        }
    }

    private func apply() {
        guard let plan = flow.apply() else { return }
        let request = request
        step = ""
        Task {
            let result = await workbench.moveSite(request, token: plan.token, on: bench) { event in
                Task { @MainActor in step = SiteMoveText.progress(event) }
            }
            switch result {
            case .success(let outcome):
                _ = flow.finish(error: nil)
                finished = SiteMoveText.result(site: site, target: request.target, outcome: outcome)
            case .failure(let error):
                // a stale token is answered here, with Review Again, not in the banner
                if flow.finish(error: error.message) {
                    failure = error.message
                } else {
                    workbench.result = nil
                }
            }
        }
    }
}
