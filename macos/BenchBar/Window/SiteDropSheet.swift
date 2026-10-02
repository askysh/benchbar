import SwiftUI

/// Dropping a site: the plan from `site drop --dry-run --json` first, then
/// the user types the site name, then `site drop --confirm-site <typed>`.
/// The CLI checks the typed name itself, so a slip here cannot drop the
/// wrong site. The sheet stays until the run has finished.
struct SiteDropSheet: View {
    let workbench: Workbench
    let bench: BenchModel
    let site: String
    let close: () -> Void

    private enum Phase: Equatable {
        case review, running, done(SiteDropResult), failed(String)
    }

    @State private var phase = Phase.review
    @State private var plan: SiteDropPlan?
    @State private var planError: String?
    @State private var typed = ""
    @State private var newDefault: String?

    private var isDefault: Bool { bench.siteRows.first { $0.name == site }?.isDefault == true }
    private var otherSites: [String] { bench.siteRows.map(\.name).filter { $0 != site } }
    private var canDrop: Bool {
        phase == .review && plan != nil && typed == site && (!isDefault || newDefault != nil)
    }

    private var sheetPhase: SheetPhase {
        switch phase {
        case .review: .ready
        case .running: .running("Backing up and dropping \(site)…")
        case .done: .done(.success("Dropped \(site)"))
        case .failed(let message): .failed(message, title: "\(site) was not dropped")
        }
    }

    var body: some View {
        SheetScaffold("Drop \(site)",
                      explanation: "Backs the site up with its files, drops its database and moves its folder to archived/sites. Nothing is deleted from disk.",
                      phase: sheetPhase) {
            switch phase {
            case .review: review
            case .running:
                SheetNote("A backup with files can take a few minutes on a big site.")
            case .done(let result): done(result)
            case .failed: EmptyView()
            }
        } actions: {
            switch phase {
            case .review:
                CancelButton(action: close)
                // destructive: never the default button, and only after the typed name
                Button("Drop Site", role: .destructive) { Task { await drop() } }
                    .disabled(!canDrop)
            case .running:
                EmptyView()
            case .done:
                DoneButton(action: close)
            case .failed:
                DoneButton(title: "Close", action: close)
            }
        }
        .task(id: newDefault) { await loadPlan() }
        .onAppear { if isDefault { newDefault = otherSites.first } }
    }

    @ViewBuilder private var review: some View {
        if isDefault {
            if otherSites.isEmpty {
                Text("\(site) is the only site of \(bench.name). Add another site before dropping it.")
                    .font(.callout).foregroundStyle(.red)
            } else {
                Picker("New default site", selection: $newDefault) {
                    ForEach(otherSites, id: \.self) { Text($0).tag(Optional($0)) }
                }
                SheetNote("\(site) is the default site: the site you pick becomes the default first.")
            }
        }
        GroupBox("What happens") {
            VStack(alignment: .leading, spacing: 6) {
                if let plan {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.title).fixedSize(horizontal: false, vertical: true)
                                Text(step.needsPassword ? "needs your password: BenchBar shows the command to run in Terminal" : step.command)
                                    .font(.caption).foregroundStyle(step.needsPassword ? .orange : .secondary)
                            }
                        }
                    }
                } else if let planError {
                    Text(planError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        TextField("Type \(site) to confirm", text: $typed)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
    }

    @ViewBuilder private func done(_ result: SiteDropResult) -> some View {
        if let backup = result.backup {
            LabeledContent("Backup") {
                HStack {
                    Text(URL(fileURLWithPath: backup.path).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Show in Finder") { Workspace.reveal(backup.parts) }
                }
            }
        } else if let archived = result.archivedPath {
            LabeledContent("Site folder") {
                Button("Show in Finder") { Workspace.reveal([archived]) }
            }
        }
        if let newDefault = result.newDefault {
            LabeledContent("Default site", value: newDefault)
        }
        if let manual = result.manualStep {
            Text("The /etc/hosts line for \(site) is still there. Removing it needs your Mac password; run this in Terminal:")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            CopyableCommand(command: manual, copyLabel: "Copy the command that removes the hosts line")
        }
    }

    private func loadPlan() async {
        // the default site waits for its successor (none: it cannot be dropped)
        if isDefault && newDefault == nil { plan = nil; planError = nil; return }
        plan = nil
        planError = nil
        switch await workbench.dropPlan(site, newDefault: newDefault, on: bench) {
        case .success(let loaded): plan = loaded
        case .failure(let error): planError = error.message
        }
    }

    private func drop() async {
        phase = .running
        switch await workbench.dropSite(site, confirm: typed, newDefault: isDefault ? newDefault : nil, on: bench) {
        case .success(let result): phase = .done(result)
        case .failure(let error): phase = .failed(error.message)
        }
    }
}
