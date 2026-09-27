import SwiftUI

struct PortSetupSheet: View {
    let run: PortSetupRun
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(run.title).font(.title2.bold())
            switch run.phase {
            case .planning: ProgressView("Checking ports and preparing the selection…")
            case .running: ProgressView("Applying changes…")
            case .review:
                Text("Review every address before applying. Existing apps and databases are preserved. Stop any previous manager’s automatic startup first.")
                    .font(.callout)
            case .finished:
                Label(run.startAfterSetup ? "Setup completed and the start command succeeded." : "Management is set up. Start the benches when you are ready.", systemImage: "checkmark.circle")
            case .failed(let error):
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            }
            if let error = run.modeError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let plan = run.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(plan.entries) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.name).font(.headline)
                                Text(entry.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                LabeledContent("Current address", value: entry.currentURL)
                                LabeledContent(entry.changesPorts ? "New address" : "Address stays", value: entry.proposedURL)
                                Text("Web \(entry.proposed.web) · Socket.IO \(entry.proposed.socketio) · Redis \(entry.proposed.redisQueue)/\(entry.proposed.redisCache)")
                                    .font(.caption).monospacedDigit()
                                Picker("Port mode", selection: Binding(get: { entry.mode }, set: { mode in
                                    Task { await run.setMode(mode, path: entry.path) }
                                })) {
                                    ForEach(PortMode.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                                .disabled(run.phase != .review || run.store.busyBench != nil)
                                .help("Fixed keeps the current ports. Automatic can propose new ports for your approval.")
                                if let blocked = entry.blocked, !blocked.isEmpty {
                                    Label(blocked, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                                } else if entry.changesPorts {
                                    Label("Port conflict resolved by the proposed allocation", systemImage: "arrow.triangle.swap").foregroundStyle(.secondary)
                                }
                                if !entry.conflicts.isEmpty {
                                    DisclosureGroup("Conflict details") {
                                        ForEach(entry.conflicts, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
                if run.phase == .review && !plan.canApply {
                    Text("Resolve the blocked benches before applying. Fixed mode keeps the current ports; Automatic allows a new allocation after review.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !run.output.isEmpty {
                DisclosureGroup("Setup output") {
                    ScrollView {
                        Text(run.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.frame(height: 140)
                }
            }
            Text("Changing the mode saves your preference immediately; ports change only when you apply. Hosts entries that need a password are reported as a Terminal command.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(run.phase == .review ? "Cancel" : "Done", action: close).disabled(run.phase == .running)
                Spacer()
                if !run.isBusy && run.phase != .finished {
                    Button("Refresh Preview") { Task { await run.loadPlan() } }
                }
                if run.phase == .review {
                    Button(run.startAfterSetup ? "Resolve & Start" : "Set Up Selected Benches") { Task { await run.apply() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(run.plan?.canApply != true || run.store.busyBench != nil)
                }
            }
        }
        .padding(24).frame(width: 660)
        .interactiveDismissDisabled(run.phase == .running)
    }
}

/// Shared by the main window and menu bar so a failed Start always has a way forward.
struct PortConflictAction: View {
    let store: BenchStore
    let bench: BenchModel
    @State private var run: PortSetupRun?
    var body: some View {
        if bench.portConflict != nil {
            Button("Review Port Conflict…") {
                let next = PortSetupRun(summaries: [bench.summary], store: store, startAfterSetup: true)
                run = next
                Task { await next.loadPlan() }
            }
            .disabled(store.busyBench != nil)
            .sheet(item: $run) { current in PortSetupSheet(run: current) { run = nil } }
        }
    }
}
