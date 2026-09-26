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
            Section {
                if let report = bench.doctor {
                    if report.needsAttention.isEmpty {
                        Label("Every check passes.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    ForEach(report.needsAttention) { CheckRow(check: $0) }
                    DisclosureGroup("\(report.passing.count) passing") {
                        ForEach(report.passing) { CheckRow(check: $0) }
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
                    Button("Repair…") { startRepair() }
                        .disabled(!repairable || bench.activity != nil || store.waitsForOtherBench(bench))
                        .help(repairable ? "Shows the plan first; nothing changes until you confirm" : "Nothing repair can fix")
                }
            } footer: {
                Text("Doctor is read only. Repair shows its plan, and runs only after you confirm, with a backup before each change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: bench.path) {
            if bench.doctor == nil { await store.runDoctor(on: bench) }
            if router.repairRequested { router.repairRequested = false; startRepair() }
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

/// The plan, a confirmation, then each step as it runs.
struct RepairSheet: View {
    let run: RepairRun
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Repair \(run.bench.name)").font(.headline)
            switch run.phase {
            case .planning:
                HStack { ProgressView().controlSize(.small); Text("Reading the plan (benchbar repair --dry-run)…").foregroundStyle(.secondary) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            default:
                if run.steps.isEmpty {
                    Label("Nothing to repair.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    stepList
                }
            }
            if run.phase == .review {
                Text("A backup is taken before every change (.benchbar/backups). Broken folders are moved aside, never deleted.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if run.hasSudoSteps {
                    Text("Steps that need your password are skipped here; run them in Terminal with benchbar repair afterwards.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if case .finished(let code) = run.phase {
                Label(code == 0 ? "Repair finished; every check passes." : "Repair finished with problems left; see the steps and the log.",
                      systemImage: code == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(code == 0 ? .green : .orange)
            }
            if let log = run.log, run.phase != .review {
                HStack {
                    Text(log).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log)]) }
                        .controlSize(.small)
                }
            }
            HStack {
                Spacer()
                switch run.phase {
                case .review:
                    Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                    Button("Repair") { Task { await run.run() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(run.steps.isEmpty)
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Running…").foregroundStyle(.secondary)
                default:
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(run.phase == .running)
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(run.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StepIcon(status: step.status)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(step.label)
                            if step.sudo { Tag(text: "needs password", color: .orange) }
                        }
                        if !step.message.isEmpty, step.status != "done" {
                            Text(step.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
}
