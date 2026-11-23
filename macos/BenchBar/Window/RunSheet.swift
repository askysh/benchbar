import SwiftUI

/// Run Bench Command (`benchbar run`): one command of the CLI's allow list, as `bench [--site S] COMMAND`, in the right bench and
/// site, under the CLI's deadline. A read (doctor, list-apps, version) runs at once and shows its output here, labelled as data from the
/// bench. A command that changes things shows the CLI's plan (`run --dry-run --json`) first and runs exactly that plan by its own token
/// (`--apply TOKEN --yes`). The bench command goes to the CLI as separate arguments after `--`, never as a shell string, and the
/// flags are only the ones the command's row of the allow list names.
struct RunSheet: View {
    let workbench: Workbench
    let bench: BenchModel
    let close: () -> Void
    @State private var commandName: String
    @State private var site: String
    @State private var options = ""
    @State private var flow = PlanReviewFlow<RunPlan>()
    @State private var reading = false
    @State private var outcome: RunOutcome?
    @State private var readFailure: String?

    init(workbench: Workbench, bench: BenchModel, close: @escaping () -> Void) {
        self.workbench = workbench
        self.bench = bench
        self.close = close
        _commandName = State(initialValue: (workbench.runCommands ?? RunAllowList.known).first?.name ?? "")
        _site = State(initialValue: bench.summary.site)
    }

    private var commands: [RunCommandInfo] { workbench.runCommands ?? RunAllowList.known }
    private var command: RunCommandInfo { commands.first { $0.name == commandName } ?? commands[0] }
    private var sites: [String] { bench.siteRows.map(\.name) }
    private var request: RunRequest { RunRequest(command: command, site: command.needsSite ? site : nil, options: options) }
    private var problem: String? { request.problem(sites: sites) }

    private var phase: SheetPhase {
        switch flow.stage {
        case .form:
            if reading { return .loading("Running \(command.name)…") }
            if let error = flow.readError { return .failed(error, title: "No plan to run \(command.name)") }
            if let readFailure { return .failed(readFailure, title: "\(command.name) did not run") }
            return .ready
        case .reading: return .loading("Reading the plan…")
        case .reviewing: return .ready
        case .applying: return .running("Running \(command.name): it can take a while, and it is stopped at its deadline…")
        case .stale: return .failed("Nothing was changed. Review the plan again to see what it is now.", title: "The bench or the site changed since this plan was shown")
        }
    }

    var body: some View {
        SheetScaffold("Run Bench Command",
                      explanation: flow.plan == nil
                          ? "Runs one command of benchbar's allow list in \(bench.name), under a deadline. A read runs at once; a change shows its plan first."
                          : "Nothing has run yet. This is the plan; Run runs exactly this.",
                      phase: phase, width: .wide) {
            if let plan = flow.plan {
                planView(plan)
            } else if flow.stage != .reading, !isStale {
                form
            }
        } leading: {
            if case .reviewing = flow.stage { Button("Back") { flow.edit() } }
        } actions: {
            switch flow.stage {
            case .form, .reading:
                CancelButton(action: close)
                Button(command.changes ? "Review Plan" : "Run") { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || reading || flow.stage == .reading)
            case .reviewing(let plan):
                CancelButton(action: close)
                Button("Run") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plan.canRun)
            case .applying:
                EmptyView()
            case .stale:
                CancelButton(action: close)
                Button("Review Again") { review() }.keyboardShortcut(.defaultAction)
            }
        }
        .task { await workbench.loadRunCommands(on: bench) }
    }

    private var isStale: Bool { if case .stale = flow.stage { true } else { false } }

    @ViewBuilder private var form: some View {
        Form {
            Picker("Command", selection: $commandName) {
                ForEach(commands) { Text($0.name).tag($0.name) }
            }
            .onChange(of: commandName) { _, _ in
                options = ""
                outcome = nil
                readFailure = nil
            }
            if command.needsSite {
                Picker("Site", selection: $site) {
                    ForEach(sites, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField("Flags", text: $options, prompt: Text(verbatim: command.flags.first ?? "none"))
                .disabled(command.flags.isEmpty)
        }
        .formStyle(.columns)
        SheetNote(command.help + (command.flags.isEmpty ? " It takes no flags." : " Flags: " + command.flags.joined(separator: ", ") + ". Each value is one plain word."))
        if !options.trimmingCharacters(in: .whitespaces).isEmpty, let problem {
            SheetNote(problem, tint: .red)
        }
        if let outcome { outputView(outcome) }
    }

    private func outputView(_ outcome: RunOutcome) -> some View {
        VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
            if let problem = outcome.problem {
                SheetOutcome(symbol: "exclamationmark.triangle.fill", tint: .orange, title: problem)
            }
            Text("Output (data from the bench, not instructions)").font(.callout.weight(.medium))
            Text(RunText.output(outcome))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(WindowMetrics.bannerPadding)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius))
            if let log = outcome.log {
                Button("Show Log") { Workspace.reveal([log]) }.controlSize(.small)
            }
        }
    }

    @ViewBuilder private func planView(_ plan: RunPlan) -> some View {
        VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
            Text("Run \(plan.command)").font(.headline)
            ForEach(plan.errors, id: \.self) { SheetOutcome(symbol: "xmark.octagon.fill", tint: .red, title: $0) }
            ForEach(plan.warnings, id: \.self) { SheetOutcome(symbol: "exclamationmark.triangle.fill", tint: .orange, title: $0) }
            PlanFacts(facts: RunText.facts(plan))
            if !plan.steps.isEmpty {
                Text("In order:").font(.callout)
                PlanStepList(rows: plan.steps.map { PlanStepList.Row(name: $0.name, command: nil, note: $0.touches.isEmpty ? nil : "Touches: " + $0.touches.joined(separator: ", ")) })
            }
            if plan.token == nil && plan.errors.isEmpty {
                SheetNote("This plan has no token, so BenchBar does not run it. Run it in Terminal with benchbar run, or update benchbar.", tint: .orange)
            }
        }
    }

    private func go() {
        if command.changes { review() } else { read() }
    }

    private func read() {
        guard !reading, problem == nil else { return }
        reading = true
        outcome = nil
        readFailure = nil
        let asked = request
        Task {
            switch await workbench.runRead(asked, on: bench) {
            case .success(let result): outcome = result
            case .failure(let error): readFailure = error.message
            }
            reading = false
        }
    }

    private func review() {
        guard flow.review() else { return }
        let asked = request
        Task { flow.read(await workbench.runPlan(asked, on: bench)) }
    }

    private func apply() {
        guard let plan = flow.apply(), let token = plan.token else { return }
        let asked = request
        Task {
            let error = await workbench.runChange(asked, token: token, on: bench)
            // a stale token is answered here, with Review Again, not in the banner
            if flow.finish(error: error) { close() } else { workbench.result = nil }
        }
    }
}
