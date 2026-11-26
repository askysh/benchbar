import SwiftUI

/// Which tidy sheet is open on a bench page. One item, so Remove Expired replaces the Tidy Up sheet with its plan.
enum TidyRoute: Identifiable, Equatable {
    case tidy
    case plan(TidyAction)

    var id: String {
        switch self {
        case .tidy: "tidy"
        case .plan(let action): "plan-\(action.rawValue)"
        }
    }
}

/// Tidy Up: marks this bench scratch for a number of days or not (`bench scratch`), lists the scratch benches that expired
/// (`bench gc --dry-run`), the databases no site refers to (`db orphans`) and the hosts lines no bench has a site for
/// (`site hosts --prune --dry-run`). All of it is read. Removing the expired benches is not done here: Remove Expired opens the plan
/// of `bench gc`, which runs by its own token. BenchBar never drops a database and never edits /etc/hosts: the orphans are a list, and
/// the stale hosts lines come with the command to run in Terminal, where sudo asks for its password.
struct TidySheet: View {
    let workbench: Workbench
    let bench: BenchModel
    let removeExpired: () -> Void
    let close: () -> Void
    @State private var days = "7"
    @State private var scratchLine: String?
    @State private var confirming = false
    @State private var marking = false
    @State private var gc: Result<GcPlan, Workbench.ChangeError>?
    @State private var orphans: Result<OrphanList, Workbench.ChangeError>?
    @State private var hosts: Result<[String], Workbench.ChangeError>?

    private var chosenDays: Int? { TidyCommands.days(days) }
    private var expired: [ScratchBench] { (try? gc?.get())?.expired ?? [] }

    var body: some View {
        SheetScaffold(String(localized: "Tidy Up"),
                      explanation: String(localized: "Scratch benches, the ones that expired and what a removed bench leaves behind. Nothing here changes until you choose."),
                      phase: marking ? .running(String(localized: "Marking \(bench.name)…")) : .ready) {
            if workbench.offersScratch { scratch }
            if workbench.offersGc { scratchBenches }
            if workbench.offersOrphans { orphanSection }
            if workbench.offersHostsPrune { hostsSection }
        } actions: {
            DoneButton(title: String(localized: "Close"), action: close)
            if workbench.offersGc {
                Button("Remove Expired…", action: removeExpired)
                    .disabled(expired.isEmpty || !workbench.store.canChange(bench))
                    .help("Shows the plan of bench gc first: it backs up each site, drops its database and moves the folder aside")
            }
        }
        .task { await load() }
        .alert("Mark \(bench.name) scratch for \(chosenDays ?? 0) day(s)?", isPresented: $confirming) {
            Button("Mark Scratch") { Task { await mark(chosenDays) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Once the time is up, Remove Expired backs up its sites, drops their databases and moves its folder aside. The default bench is never removed.")
        }
    }

    private var scratch: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
            Text(bench.name).font(.headline)
            SheetNote(String(localized: "A scratch bench expires after the days you give. The default bench is never removed."))
            HStack(spacing: WindowMetrics.rowSpacing) {
                TextField("Days until it expires", text: $days).frame(width: 190)
                Button("Mark Scratch") { confirming = true }
                    .disabled(chosenDays == nil || marking || !workbench.store.canChange(bench))
                Button("Not Scratch") { Task { await mark(nil) } }
                    .disabled(marking || !workbench.store.canChange(bench))
            }
            if chosenDays == nil { SheetNote(TidyCommands.daysProblem, tint: .red) }
            if let scratchLine { SheetNote(scratchLine) }
        }
    }

    @ViewBuilder private var scratchBenches: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 2) {
            Text("Scratch benches").font(.headline)
            switch gc {
            case nil: ProgressView().controlSize(.small)
            case .failure(let error)?: SheetNote(error.message, tint: .red)
            case .success(let plan)?:
                let now = Date()
                if plan.expired.isEmpty { Text("No scratch bench has expired.").font(.callout) }
                ForEach(plan.expired) { Text(TidyText.line($0, expired: true, kept: false, now: now)).font(.callout) }
                ForEach(plan.pending) { Text(TidyText.line($0, expired: false, kept: false, now: now)).font(.callout).foregroundStyle(.secondary) }
                ForEach(plan.skipped) { Text(TidyText.line($0, expired: false, kept: true, now: now)).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var orphanSection: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 2) {
            Text("Databases no site refers to").font(.headline)
            switch orphans {
            case nil: ProgressView().controlSize(.small)
            case .failure(let error)?: SheetNote(error.message, tint: .red)
            case .success(let list)?:
                Text(TidyText.orphanSummary(list)).font(.callout)
                ForEach(list.orphans) { Text(TidyText.orphan($0)).font(.callout.monospaced()).textSelection(.enabled) }
                if !list.orphans.isEmpty, !list.note.isEmpty { SheetNote(list.note) }
            }
        }
    }

    @ViewBuilder private var hostsSection: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing + 2) {
            Text("Hosts lines no bench uses").font(.headline)
            switch hosts {
            case nil: ProgressView().controlSize(.small)
            case .failure(let error)?: SheetNote(error.message, tint: .red)
            case .success(let names)?:
                if names.isEmpty {
                    Text("Every line in benchbar's block of /etc/hosts belongs to a site.").font(.callout)
                } else {
                    Text(Wording.staleHostsLines(names.count)).font(.callout)
                    ForEach(names, id: \.self) { Text($0).font(.callout.monospaced()) }
                    SheetNote(String(localized: "BenchBar does not edit /etc/hosts. Run this in Terminal: it shows the lines, backs the file up and asks for your password."))
                    CopyableCommand(command: TidyCommands.hostsCommand, copyLabel: String(localized: "Copy the command that removes the stale hosts lines"))
                }
            }
        }
    }

    private func load() async {
        async let plan = workbench.offersGc ? workbench.tidyGc() : nil
        async let list = workbench.offersOrphans ? workbench.tidyOrphans() : nil
        async let lines = workbench.offersHostsPrune ? workbench.tidyHosts() : nil
        (gc, orphans, hosts) = await (plan, list, lines)
    }

    private func mark(_ count: Int?) async {
        marking = true
        let error = await workbench.markScratch(days: count, on: bench)
        marking = false
        scratchLine = error ?? count.map { "\(bench.name) is a scratch bench for \($0) day(s)." } ?? "\(bench.name) is not a scratch bench."
        if error == nil, workbench.offersGc { gc = await workbench.tidyGc() }
    }
}

/// Forget Bench, Remove Bench, Remove Service and Remove Expired: the CLI's plan first, then the run by that plan's own token. Remove
/// asks for the folder name again, as the CLI wants it. A token the CLI refuses shows here, with Review Again.
struct TidyPlanSheet: View {
    let workbench: Workbench
    let bench: BenchModel
    let action: TidyAction
    let close: () -> Void
    @State private var flow = PlanReviewFlow<TidyPlan>()
    @State private var typed = ""

    private var folder: String { TidyCommands.folderName(bench.path) }
    private var needsName: Bool { action == .remove }

    private var explanation: String {
        switch action {
        case .gc: "Backs up each site of every expired scratch bench, drops its database and moves the bench folder aside. Nothing is deleted, and the default bench is never touched."
        case .forget: "Takes \(bench.name) out of benchbar's list and removes its service files, each backed up first. The folder, its sites, apps, databases and hosts lines stay."
        case .remove: "Backs up each site of \(bench.name) with its files, drops its database, takes the bench out of benchbar's list and moves the folder to a trash folder next to it. Nothing is deleted."
        case .removeService: "Stops \(bench.name) and removes its background service: the unit, the runner and Procfile.lean, each backed up first. The bench, its sites, apps and databases are not touched."
        }
    }

    private var phase: SheetPhase {
        switch flow.stage {
        case .form: flow.readError.map { .failed($0, title: String(localized: "No plan to \(action.title.lowercased())")) } ?? .loading(String(localized: "Reading the plan…"))
        case .reading: .loading(String(localized: "Reading the plan…"))
        case .reviewing: .ready
        case .applying: .running(String(localized: "\(action.title)…"))
        case .stale: .failed(String(localized: "Nothing was changed. Review the plan again to see what it is now."), title: String(localized: "The bench changed since this plan was shown"))
        }
    }

    var body: some View {
        SheetScaffold(action == .gc ? action.title : String(localized: "\(action.title): \(bench.name)"), explanation: explanation, phase: phase, width: .wide) {
            if let plan = flow.plan { planView(plan) }
        } actions: {
            switch flow.stage {
            case .form where flow.readError != nil:
                CancelButton(title: String(localized: "Close"), action: close)
                Button("Try Again") { review() }.keyboardShortcut(.defaultAction)
            case .form, .reading:
                CancelButton(action: close)
            case .reviewing(let plan):
                CancelButton(action: close)
                // data goes: never the default button, and Remove only after the typed folder name
                Button(action.confirmLabel, role: .destructive) { apply() }
                    .disabled(!plan.canRun || (needsName && typed != folder))
            case .applying:
                EmptyView()
            case .stale:
                CancelButton(action: close)
                Button("Review Again") { review() }.keyboardShortcut(.defaultAction)
            }
        }
        .task { if flow.stage == .form, flow.readError == nil { review() } }
    }

    @ViewBuilder private func planView(_ plan: TidyPlan) -> some View {
        VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
            ForEach(plan.errors, id: \.self) { SheetOutcome(symbol: "xmark.octagon.fill", tint: .red, title: $0) }
            ForEach(plan.warnings, id: \.self) { SheetOutcome(symbol: "exclamationmark.triangle.fill", tint: .orange, title: $0) }
            if plan.rows.isEmpty, plan.errors.isEmpty {
                SheetOutcome(symbol: "checkmark.circle.fill", tint: .green, title: String(localized: "Nothing to do"),
                             detail: action == .gc ? String(localized: "No scratch bench has expired.") : String(localized: "The CLI listed no step."))
            } else {
                Text("In order:").font(.callout)
                PlanStepList(rows: plan.rows.map { PlanStepList.Row(name: $0, command: nil, note: nil) })
            }
            if !plan.keeps.isEmpty { PlanFacts(facts: [("Stays", plan.keeps.joined(separator: ", ") + ".")]) }
            if let trash = plan.trashIn { PlanFacts(facts: [("Trash", "The folder moves to \(trash). Empty it yourself when you are sure.")]) }
            if plan.token == nil, action.hasToken, plan.errors.isEmpty, !plan.rows.isEmpty {
                SheetNote(String(localized: "This plan has no token, so BenchBar does not run it. Run it in Terminal with benchbar, or update benchbar."), tint: .orange)
            }
            if needsName, plan.canRun {
                TextField("Type \(folder) to confirm", text: $typed).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            }
        }
    }

    private func review() {
        guard flow.review() else { return }
        Task { flow.read(await workbench.tidyPlan(action, on: bench)) }
    }

    private func apply() {
        guard let plan = flow.apply() else { return }
        Task {
            let error = await workbench.tidyChange(plan, on: bench)
            // a stale token is answered here, with Review Again, not in the banner
            if flow.finish(error: error) { close() } else { workbench.result = nil }
        }
    }
}
