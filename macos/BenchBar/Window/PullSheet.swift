import SwiftUI
import AppKit

/// What the pull plan says, kept out of the view so a test can read it.
nonisolated enum PullText {
    /// "20260925_020000-erp_example_com-database.sql.gz, 7.0 MB, 31 hours old"
    static func backupLine(_ backup: PullPlan.Backup) -> String {
        guard let name = backup.name else { return "A new backup is taken on the server first." }
        var parts = [name]
        if let bytes = backup.bytes { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        if let hours = backup.ageHours { parts.append(hours >= 48 ? "\(hours / 24) days old" : "\(hours) hours old") }
        if backup.encrypted { parts.append("encrypted, decrypted here with gpg") }
        return parts.joined(separator: ", ")
    }

    /// "erpnext: 15.30.0 here, 15.40.0 on production (local older)"
    static func appLine(_ app: PullPlan.AppStatus) -> String {
        let versions = [app.localVersion.map { "\($0) here" }, app.productionVersion.map { "\($0) on production" }].compactMap { $0 }
        return "\(app.app): " + (versions.isEmpty ? app.status : versions.joined(separator: ", ") + " (\(app.status))")
    }

    static let neutralisedText = "Integrations are switched off and stored passwords are cleared on the copy; the Administrator login is kept. Email is muted and the scheduler paused. Customer data is not touched."
    static let keptText = "Production's passwords, webhooks and integrations stay on the copy. Email is muted and the scheduler paused, but the copy can still talk to the outside."
}

/// The plan of a pull: where the copy comes from, what it loses, the apps that differ, the steps.
struct PullPlanView: View {
    let plan: PullPlan

    private var facts: [(label: String, text: String)] {
        var out: [(label: String, text: String)] = []
        if let backup = plan.backup { out.append(("Backup", PullText.backupLine(backup))) }
        out.append(("Local site", plan.createSite ? "\(plan.site) is created on this bench." : "\(plan.site) is replaced, after a backup."))
        out.append(("The copy", plan.neutralise ? PullText.neutralisedText : PullText.keptText))
        if plan.encryptionKey { out.append(("Encryption key", "Production's key comes over, so stored passwords that are kept still decrypt.")) }
        if !plan.differingApps.isEmpty { out.append(("Apps that differ", plan.differingApps.map(PullText.appLine).joined(separator: "\n"))) }
        out.append(("Hosts line", "BenchBar never asks for your password, so /etc/hosts is not changed here. Sites has Add Hosts Lines."))
        out.append(("Left alone", "Production (nothing is written there) and every other site of this bench."))
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
                Text(plan.site).font(.headline)
                Text("a copy of \(plan.source)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !plan.neutralise {
                SheetOutcome(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "The copy keeps production's secrets",
                             detail: "Do not start its scheduler or workers unless you mean to reach the same services as production.")
            }
            PlanFacts(facts: facts)
            if !plan.steps.isEmpty {
                Text("In order:").font(.callout)
                PlanStepList(rows: plan.steps.map { PlanStepList.Row(name: $0, command: nil, note: nil) })
            }
        }
    }
}

/// Fill in where production is, Review reads the CLI's plan (`pull --dry-run --json`), Pull runs
/// exactly that plan by its token (`--apply TOKEN --yes`). A plan that changed in between (a newer
/// backup, other apps) is refused by the CLI and answered here with Review Again, as the restore
/// sheet does. The copy is neutralised by default; keeping production's secrets is an explicit
/// choice with a warning.
struct PullSheet: View {
    /// What the sheet starts with: empty for a person, filled for a render.
    struct Start {
        var fromFolder = false
        var target = ""
        var folder = ""
        var name = ""
        var keepSecrets = false
        var flow = PlanReviewFlow<PullPlan>()
    }

    let workbench: Workbench
    let bench: BenchModel
    let close: () -> Void
    @State private var fromFolder: Bool
    @State private var target: String
    @State private var folder: String
    @State private var name: String
    @State private var keepSecrets: Bool
    @State private var choosing = false
    @State private var flow: PlanReviewFlow<PullPlan>

    init(workbench: Workbench, bench: BenchModel, start: Start = Start(), close: @escaping () -> Void) {
        self.workbench = workbench
        self.bench = bench
        self.close = close
        _fromFolder = State(initialValue: start.fromFolder)
        _target = State(initialValue: start.target)
        _folder = State(initialValue: start.folder)
        _name = State(initialValue: start.name)
        _keepSecrets = State(initialValue: start.keepSecrets)
        _flow = State(initialValue: start.flow)
    }

    private var sourceValid: Bool { fromFolder ? !folder.trimmingCharacters(in: .whitespaces).isEmpty : PullRequest.isValidSSH(target) }
    private var nameValid: Bool { SiteName.isValid(name) && !bench.siteRows.contains { $0.name == name } }
    private var isStale: Bool { if case .stale = flow.stage { true } else { false } }

    private var request: PullRequest {
        PullRequest(source: fromFolder ? .folder(folder.trimmingCharacters(in: .whitespaces)) : .ssh(target), name: name, keepSecrets: keepSecrets)
    }

    private var phase: SheetPhase {
        switch flow.stage {
        case .form:
            if let error = flow.readError { .failed(error, title: "No plan to pull \(name)") } else { .ready }
        case .reading: .loading(fromFolder ? "Reading the backup and the bench…" : "Checking the server and the bench…")
        case .reviewing: .ready
        case .applying: .running("Pulling \(name): download, restore and migrate can take a while…")
        case .stale: .failed("Nothing was changed. Review the plan again to see what it is now.", title: "The plan changed since it was shown")
        }
    }

    var body: some View {
        SheetScaffold("Pull a Site into \(bench.name)",
                      explanation: flow.plan == nil
                          ? "Copies a production site, or a backup you downloaded, into a new site of this bench. Production is only read. You see the plan first."
                          : "Nothing has run yet. These are the steps; Pull runs this plan.",
                      phase: phase, width: flow.plan == nil ? .regular : .wide) {
            if let plan = flow.plan {
                PullPlanView(plan: plan)
            } else if flow.stage != .reading, !isStale {
                form
            }
        } leading: {
            if case .reviewing = flow.stage { Button("Back") { flow.edit() } }
        } actions: {
            switch flow.stage {
            case .form, .reading:
                CancelButton(action: close)
                Button("Review") { review() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!sourceValid || !nameValid || flow.stage == .reading)
            case .reviewing:
                CancelButton(action: close)
                Button("Pull") { apply() }.keyboardShortcut(.defaultAction)
            case .applying:
                EmptyView()
            case .stale:
                CancelButton(action: close)
                Button("Review Again") { review() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var form: some View {
        Form {
            Picker("Copy from", selection: $fromFolder) {
                Text("A server over SSH").tag(false)
                Text("A downloaded backup").tag(true)
            }
            if fromFolder {
                HStack {
                    TextField("Backup folder", text: $folder, prompt: Text(verbatim: "/Users/you/Downloads/backup"))
                    Button("Choose…") { choosing = true }
                }
            } else {
                // verbatim: a string literal Text reads markdown
                TextField("Host and site", text: $target, prompt: Text(verbatim: "prod:erp.example.com"))
                    // the name follows the host until it is typed over
                    .onChange(of: target) { old, new in
                        if name.isEmpty || name == PullRequest.defaultName(for: old) { name = PullRequest.defaultName(for: new) }
                    }
            }
            TextField("New local site", text: $name, prompt: Text("erp.local"))
            if !name.isEmpty && !nameValid {
                Text(SiteName.isValid(name) ? "A site with that name exists. Pull never overwrites it here." : SiteName.rule)
                    .font(.caption).foregroundStyle(.red)
            }
            Toggle("Keep production's passwords and integrations", isOn: $keepSecrets)
        }
        .formStyle(.columns)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { picked in
            if case .success(let url) = picked { folder = url.path }
        }
        if keepSecrets {
            SheetNote(PullText.keptText, tint: .orange)
        } else {
            SheetNote(PullText.neutralisedText)
        }
        SheetNote(fromFolder
                  ? "The folder holds the backup set Frappe Cloud or bench gave you. Nothing is read from a server."
                  : "The host is a Host of your ~/.ssh/config. The latest backup on the server is used and nothing is written there.")
    }

    private func review() {
        guard flow.review() else { return }
        Task { flow.read(await workbench.pullPlan(request, on: bench)) }
    }

    private func apply() {
        guard let plan = flow.apply() else { return }
        Task {
            let error = await workbench.pull(request, reviewed: plan, on: bench)
            if flow.finish(error: error) { close() } else { workbench.result = nil }
        }
    }
}
