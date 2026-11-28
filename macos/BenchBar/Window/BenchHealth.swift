import SwiftUI

/// Doctor for one bench, and Repair when doctor found something repair can fix.
struct BenchHealth: View {
    let store: BenchStore
    let workbench: Workbench
    let bench: BenchModel
    @Bindable var router: WindowRouter
    @State private var repair: RepairRun?

    private var repairable: Bool {
        bench.doctor?.checks.contains { $0.level != .ok && $0.action != nil } ?? false
    }

    var body: some View {
        Form {
            if let error = bench.lastError ?? bench.refreshError {
                Section("Last operation or connection error") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section {
                if let report = bench.doctor {
                    if report.profileIsDefault, let profile = report.profile {
                        Label("Profile \(profile) is only the default: no profile matches this bench's Frappe, so the env checks warn instead of offering a rebuild.",
                              systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    if report.needsAttention.isEmpty {
                        Label(report.acknowledged.isEmpty ? String(localized: "Every check passes.") : String(localized: "Nothing needs attention."), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    ForEach(report.needsAttention, id: \.rowKey) { check in row(check) }
                    if !report.acknowledged.isEmpty {
                        DisclosureGroup("\(report.acknowledged.count) acknowledged") {
                            ForEach(report.acknowledged, id: \.rowKey) { check in row(check) }
                        }
                    }
                    DisclosureGroup("\(report.passing.count) passing") {
                        ForEach(report.passing, id: \.rowKey) { CheckRow(check: $0) }
                    }
                } else if bench.isRunningDoctor {
                    HStack { ProgressView().controlSize(.small); Text("Running doctor…").foregroundStyle(.secondary) }
                } else {
                    Text("Doctor has not run yet.").foregroundStyle(.secondary)
                }
                if let error = bench.doctorError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let error = workbench.parityError[bench.path] {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                HStack {
                    Text("Doctor")
                    if let report = bench.doctor {
                        Text(report.summary.text)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // a report on screen hides the "Running doctor…" row: the spinner says it runs again
                    if bench.isRunningDoctor && bench.doctor != nil {
                        ProgressView().controlSize(.small).accessibilityLabel("Running doctor")
                    }
                    Button("Run Doctor") { Task { await store.runDoctor(on: bench) } }
                        .disabled(bench.isRunningDoctor)
                    // the main action only when doctor found something repair can fix
                    Button("Repair…") { startRepair() }
                        .primaryAction(repairable)
                        .disabled(!repairable || !store.canChange(bench))
                        .help(repairable ? String(localized: "Shows the plan first; nothing changes until you confirm") : String(localized: "Nothing repair can fix"))
                }
            } footer: {
                Text("Doctor is read only. Repair shows its plan, and runs only after you confirm, with a backup before each change. Acknowledge silences one warning for this bench until its message changes; failures cannot be acknowledged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // the answer is kept for the window session: asked again after an
        // action on the bench or in the next session, not on every visit
        .task(id: store.stamp(for: bench)) {
            if router.repairRequested { router.repairRequested = false; startRepair() }
            await workbench.loadCommands()
            await store.showDoctor(on: bench)
        }
        .sheet(item: $repair) { run in
            RepairSheet(run: run) { repair = nil }
        }
    }

    /// Acknowledge and Undo only when this CLI's doctor has the flag (`commands --json`), and never for a failure.
    private func row(_ check: DoctorCheck) -> CheckRow {
        let offered = workbench.commandState.catalog?.hasFlag("doctor", "--ack") == true
        return CheckRow(check: check, acknowledge: offered ? { on in Task { await workbench.acknowledge(check, on: on, bench: bench) } } : nil,
                        busy: store.busyBench != nil || bench.isRunningDoctor)
    }

    private func startRepair() {
        let run = RepairRun(bench: bench, store: store)
        repair = run
        Task { await run.loadPlan() }
    }
}

extension RepairRun: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension RepairRun {
    /// The sheet's state. The steps stay on screen while repair runs, after
    /// it and after a failure, so nothing that happened scrolls away.
    var sheetPhase: SheetPhase {
        switch phase {
        case .planning: .loading(String(localized: "Reading the plan (benchbar repair --dry-run)…"))
        case .review: .ready
        case .running: .running(String(localized: "Repairing…"))
        case .finished(let code):
            .done(code == 0 ? .success(String(localized: "Repair finished; every check passes."))
                  : .warning(String(localized: "Repair finished with problems left"), String(localized: "See the steps below and the log.")))
        case .failed(let message): .failed(message, title: steps.isEmpty ? String(localized: "No repair plan") : String(localized: "Repair stopped"))
        case .stale: .failed(String(localized: "Nothing was changed. Review the plan again to see what it is now."), title: String(localized: "The bench changed since this plan was shown"))
        }
    }
}

/// The plan, a confirmation, then each step as it runs.
struct RepairSheet: View {
    let run: RepairRun
    let close: () -> Void

    var body: some View {
        SheetScaffold(String(localized: "Repair \(run.bench.name)"),
                      explanation: String(localized: "Runs the fixes doctor found, in order, with a backup before each change."),
                      phase: run.sheetPhase) {
            if run.phase != .planning, !run.isStale {
                if run.steps.isEmpty {
                    if run.phase == .review {
                        SheetOutcome(symbol: "checkmark.circle.fill", tint: .green, title: String(localized: "Nothing to repair."))
                    }
                } else {
                    stepList
                }
            }
            if run.phase == .review {
                SheetNote(String(localized: "A backup is taken before every change (.benchbar/backups). Broken folders are moved aside, never deleted."))
                if run.hasSudoSteps {
                    SheetNote(String(localized: "Steps that ask for your password show macOS's own dialog; BenchBar never sees the password. Cancel it and that step is skipped, with the command to run yourself."), tint: .orange)
                }
            }
            if let log = run.log, run.phase != .review {
                Text(log).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        } leading: {
            if let log = run.log, run.phase != .review, run.phase != .running {
                Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log)]) }
            }
        } actions: {
            switch run.phase {
            case .review:
                CancelButton(action: close)
                Button("Repair") { Task { await run.run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(run.steps.isEmpty)
            case .planning:
                CancelButton(action: close)
            case .running:
                EmptyView()
            case .stale:
                CancelButton(action: close)
                Button("Review Again") { Task { await run.loadPlan() } }.keyboardShortcut(.defaultAction)
            case .finished, .failed:
                DoneButton(action: close)
            }
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
            ForEach(run.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
                    StepIcon(status: step.status).accessibilityLabel(StepIcon.label(step.status))
                    VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
                        HStack(spacing: 6) {
                            Text(step.label)
                            if step.sudo { Tag(text: String(localized: "Asks for your password"), color: .orange) }
                            if step.unreviewed { Tag(text: String(localized: "Not in the plan you reviewed"), color: .orange) }
                        }
                        if !step.message.isEmpty, step.status != "done" {
                            Text(CLIText.plain(step.message)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

struct StepIcon: View {
    let status: String
    var body: some View {
        switch status {
        case "running": ProgressView().controlSize(.mini).frame(width: 14)
        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "skipped": Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
        case "failed": Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        default: Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    /// What VoiceOver reads for the icon.
    static func label(_ status: String) -> String {
        switch status {
        case "running": "running"
        case "done": "done"
        case "skipped": "skipped"
        case "failed": "failed"
        default: String(localized: "not started")
        }
    }
}
