import SwiftUI

extension PortSetupRun {
    var sheetPhase: SheetPhase {
        switch phase {
        case .planning: .loading("Checking ports and preparing the selection…")
        case .review: .ready
        case .running: .running("Applying changes…")
        case .finished:
            .done(.success(startAfterSetup ? "Setup completed and the start command succeeded."
                           : "Management is set up. Start the benches when you are ready."))
        case .failed(let error): .failed(error, title: "Setup did not finish")
        }
    }
}

struct PortSetupSheet: View {
    let run: PortSetupRun
    let close: () -> Void

    var body: some View {
        SheetScaffold(run.title,
                      explanation: "Review the addresses and service changes before applying. Existing apps and databases are preserved.",
                      phase: run.sheetPhase, width: .wide) {
            if let error = run.modeError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if run.phase == .review {
                SheetNote("Stop any previous manager's automatic startup first.")
            }
            if let plan = run.plan {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(plan.entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.name).font(.headline)
                            Text((entry.path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(entry.path)
                                .textSelection(.enabled)
                            LabeledContent("Current address", value: entry.currentURL)
                            LabeledContent(entry.changesPorts ? "New address" : "Address stays", value: entry.proposedURL)
                            Text("Web \(String(entry.proposed.web)) · Socket.IO \(String(entry.proposed.socketio)) · Redis \(String(entry.proposed.redisQueue))/\(String(entry.proposed.redisCache))")
                                .font(.caption).monospacedDigit()
                            if let setupPlan = entry.setupPlan, !setupPlan.isEmpty {
                                HStack(spacing: 6) {
                                    Text("Service changes").font(.subheadline.bold())
                                    if PortSetupHints.asksForPassword(setupPlan: setupPlan) {
                                        Tag(text: "Asks for your password", color: .orange)
                                    }
                                }
                                .padding(.top, 6)
                                Text(setupPlan)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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
                if run.phase == .review && !plan.canApply {
                    Text("Resolve the blocked benches before applying. Fixed mode keeps the current ports; Automatic allows a new allocation after review.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !run.output.isEmpty {
                DisclosureGroup("Setup output") {
                    Text(run.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !run.hostsFallbacks.isEmpty {
                VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                    Text("The password dialog was cancelled, so the hosts lines are not in. Run this in Terminal instead:")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(run.hostsFallbacks, id: \.self) { CopyableCommand(command: $0, copyLabel: "Copy the command that adds the hosts lines") }
                }
            }
            SheetNote("Changing the mode saves your preference immediately; ports change only when you apply. A hosts line asks for your password in macOS's own dialog, after you apply; cancel it and the line is left for you to add.")
        } leading: {
            if !run.isBusy && run.phase != .finished {
                Button("Refresh Preview") { Task { await run.loadPlan() } }
            }
        } actions: {
            if run.phase == .review {
                CancelButton(action: close)
                Button(run.startAfterSetup ? "Resolve & Start" : "Set Up Selected Benches") { Task { await run.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(run.plan?.canApply != true || run.store.busyBench != nil)
            } else if run.phase == .planning {
                CancelButton(action: close)
            } else if run.phase != .running {
                DoneButton(action: close)
            }
        }
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
