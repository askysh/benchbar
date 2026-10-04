import SwiftUI

/// Doctor for one bench, and Repair when doctor found something repair can fix.
struct BenchHealth: View {
    let store: BenchStore
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
                        Label("Every check passes.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    ForEach(report.needsAttention, id: \.rowKey) { CheckRow(check: $0) }
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
            } header: {
                HStack {
                    Text("Doctor")
                    if let report = bench.doctor {
                        Text("\(report.summary.ok) ok, \(report.summary.warn) warn, \(report.summary.fail) fail")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Run Doctor") { Task { await store.runDoctor(on: bench) } }
                        .disabled(bench.isRunningDoctor)
                    // the main action only when doctor found something repair can fix
                    Button("Repair…") { startRepair() }
                        .primaryAction(repairable)
                        .disabled(!repairable || !store.canChange(bench))
                        .help(repairable ? "Shows the plan first; nothing changes until you confirm" : "Nothing repair can fix")
                }
            } footer: {
                Text("Doctor is read only. Repair shows its plan, and runs only after you confirm, with a backup before each change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // the answer is kept for the window session: asked again after an
        // action on the bench or in the next session, not on every visit
        .task(id: store.stamp(for: bench)) {
            if router.repairRequested { router.repairRequested = false; startRepair() }
            await store.showDoctor(on: bench)
        }
        .sheet(item: $repair) { run in
            RepairSheet(run: run) { repair = nil }
        }
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
        case .planning: .loading("Reading the plan (benchbar repair --dry-run)…")
        case .review: .ready
        case .running: .running("Repairing…")
        case .finished(let code):
            .done(code == 0 ? .success("Repair finished; every check passes.")
                  : .warning("Repair finished with problems left", "See the steps below and the log."))
        case .failed(let message): .failed(message, title: steps.isEmpty ? "No repair plan" : "Repair stopped")
        }
    }
}

/// The plan, a confirmation, then each step as it runs.
struct RepairSheet: View {
    let run: RepairRun
    let close: () -> Void

    var body: some View {
        SheetScaffold("Repair \(run.bench.name)",
                      explanation: "Runs the fixes doctor found, in order, with a backup before each change.",
                      phase: run.sheetPhase) {
            if run.phase != .planning {
                if run.steps.isEmpty {
                    if run.phase == .review {
                        SheetOutcome(symbol: "checkmark.circle.fill", tint: .green, title: "Nothing to repair.")
                    }
                } else {
                    stepList
                }
            }
            if run.phase == .review {
                SheetNote("A backup is taken before every change (.benchbar/backups). Broken folders are moved aside, never deleted.")
                if run.hasSudoSteps {
                    SheetNote("Steps that need your password are skipped here; run them in Terminal with benchbar repair afterwards.", tint: .orange)
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
                            if step.sudo { Tag(text: "needs password", color: .orange) }
                        }
                        if !step.message.isEmpty, step.status != "done" {
                            Text(step.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
        default: "not started"
        }
    }
}
