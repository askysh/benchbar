import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The profile sharing sheets. Each one shows the CLI's plan before it
// writes anything, and none of them installs an app or touches a bench.

private let tomlType = UTType(filenameExtension: "toml") ?? .plainText

// MARK: shared pieces

/// ✓, ✗ or ? and the repository, for import and Check Access.
struct RepoCheckRow: View {
    let app: String
    let repo: String
    let check: ProfileRepoCheck?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(check?.mark ?? "?")
                .font(.body.weight(.semibold).monospaced())
                .foregroundStyle(color)
                .accessibilityLabel(accessibility)
            VStack(alignment: .leading, spacing: 1) {
                Text(app).font(.body.weight(.medium))
                Text(repo).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let reason = check?.reason, check?.reachable != true {
                    Text(reason).font(.caption).foregroundStyle(color)
                }
            }
        }
    }

    /// A scroll view in a sheet takes no height of its own: room for every
    /// row (two lines, a third for a reason), up to a limit.
    static func listHeight(_ rows: Int, reasons: Int, limit: CGFloat = 240) -> CGFloat {
        min(CGFloat(rows) * 42 + CGFloat(reasons) * 16, limit)
    }

    private var color: Color {
        switch check?.reachable {
        case true?: return .green
        case false?: return .red
        case nil: return .orange
        }
    }

    private var accessibility: String {
        switch check?.reachable {
        case true?: return "reachable"
        case false?: return "not reachable"
        case nil: return "not checked"
        }
    }
}

/// A unified diff, monospaced and selectable.
struct ProfileDiffView: View {
    let diff: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(String(line).isEmpty ? " " : String(line))
                        .font(.caption.monospaced())
                        .foregroundStyle(line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : .primary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .frame(minHeight: 60, maxHeight: 180)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct FailureText: View {
    let message: String
    var body: some View {
        ScrollView {
            Text(message).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
    }
}

// MARK: import

struct ImportProfileSheet: View {
    @Bindable var run: ProfileImportRun
    /// Review on appear: the user picked or dropped the file themselves.
    var autoReview = false
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import a profile", systemImage: "square.and.arrow.down").font(.headline)
            if run.phase == .done, let result = run.result {
                done(result)
            } else {
                form
                content
                buttons
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(run.phase.isBusy)
        .task { if autoReview { await run.review() } }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("File or https URL", text: $run.source, prompt: Text(verbatim: "https://github.com/acme/profiles/blob/main/acme.toml"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Choose File…") { choose() }
            }
            if !run.trimmedSource.isEmpty && !run.sourceValid {
                Text("Use a .toml file on this Mac or an https URL.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("Save as")
                TextField("Save as", text: $run.saveAs, prompt: Text("optional: the name in the file"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            if !run.nameValid {
                Text("Lower case letters, digits, '.', '_' or '-', starting with a letter or digit.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch run.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the profile and checking its repositories…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            FailureText(message: message)
        default:
            if let plan = run.plan { review(plan) } else {
                Text("BenchBar reads the file, checks that it parses and whether this Mac can reach each repository, and shows it before anything is saved. Nothing is installed from here.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func review(_ plan: ProfileImportPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Profile", value: plan.name)
                if let base = plan.base { LabeledContent("Based on", value: base) }
                LabeledContent("From") { Text(plan.source).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.apps) { app in
                            RepoCheckRow(app: app.name + (app.branch.map { " @ \($0)" } ?? ""), repo: app.repo, check: plan.check(for: app.name))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: RepoCheckRow.listHeight(plan.apps.count, reasons: plan.check.repos.filter { $0.reachable != true }.count))
                if !plan.skippedApps.isEmpty {
                    Text("Left out when a bench is set up from it, because this Mac cannot read their repository or they require an app that is left out: \(plan.skippedApps.joined(separator: ", ")).")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(4)
        }
        if plan.exists {
            Text("A profile named \(plan.name) exists. Adding this one replaces it:").font(.callout)
            ProfileDiffView(diff: plan.diff ?? "(no difference)")
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
            Button("Review") { Task { await run.review() } }
                .disabled(!run.canReview)
            Button(run.plan?.exists == true ? "Replace Profile" : "Add Profile") { Task { await run.add() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!run.canAdd)
        }
    }

    @ViewBuilder private func done(_ result: ProfileImportResult) -> some View {
        Label("Added \(result.name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        Text("Set up a bench from it with benchbar install --profile \(result.name).")
            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        HStack {
            Button("Show in Finder") { Workspace.reveal([result.path]) }
            Spacer()
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [tomlType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a BenchBar profile (.toml)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run.source = url.path
        Task { await run.review() }
    }
}

// MARK: subscribe

struct SubscribeProfilesSheet: View {
    @Bindable var run: ProfileSubscribeRun
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Subscribe to a team's profiles", systemImage: "arrow.triangle.2.circlepath").font(.headline)
            switch run.phase {
            case .done:
                if let result = run.result { done(result) }
            default:
                TextField("Git repository", text: $run.repo, prompt: Text(verbatim: "git@github.com:acme/benchbar-profiles.git"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if !run.trimmedRepo.isEmpty && !ProfileSourceRule.isGitURL(run.trimmedRepo) {
                    Text("Use an https, ssh or git@host:owner/repo URL.").font(.caption).foregroundStyle(.red)
                }
                Text("BenchBar clones the repository into ~/.config/benchbar/sources with your own git credentials and reads only its .toml files; no code from it runs. It never updates on its own: the list shows when it is behind, and Update shows the changes first.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = run.phase { FailureText(message: message) }
                HStack {
                    if run.phase == .running {
                        ProgressView().controlSize(.small)
                        Text("Cloning…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                    Button("Subscribe") { Task { await run.subscribe() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!run.canSubscribe)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(run.phase.isBusy)
    }

    @ViewBuilder private func done(_ result: ProfileSubscribeResult) -> some View {
        Label("Subscribed to \(ProfileInfo.shortRepo(result.repo))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        Text(result.profiles.isEmpty ? "The repository has no profile yet."
             : "Profiles: \(result.profiles.joined(separator: ", ")).")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Show in Finder") { Workspace.reveal([result.dir]) }
            Spacer()
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: export

struct ExportProfileSheet: View {
    @Bindable var run: ProfileExportRun
    let close: () -> Void
    @State private var hostedURL = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Export \(run.name)", systemImage: "square.and.arrow.up").font(.headline)
            switch run.phase {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking each repository for its default branch and access…").foregroundStyle(.secondary)
                }
                buttons
            case .failed(let message):
                FailureText(message: message)
                HStack {
                    Spacer()
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                }
            case .done:
                if let result = run.result { done(result) }
            case .ready, .running:
                if let plan = run.plan { review(plan) }
                buttons
            }
        }
        .padding(20)
        .frame(width: 640)
        .interactiveDismissDisabled(run.phase.isBusy)
        .task { if run.phase == .idle { await run.load() } }
    }

    @ViewBuilder private func review(_ plan: ProfileExportPlan) -> some View {
        Text("Pick the branch each teammate gets, and which apps go into the file. Repository addresses are written without your SSH host aliases or any login.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.apps) { app in row(app) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: min(CGFloat(plan.apps.count) * 58 + CGFloat(plan.apps.filter { !$0.requires.isEmpty }.count) * 18, 320))
        ForEach(plan.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }

    private func row(_ app: ProfileExportPlan.App) -> some View {
        let model: ProfileExportRun = run
        let keep = Binding<Bool>(get: { model.choices.keeps(app.name) }, set: { model.setKeep(app.name, $0) })
        let branch = Binding<String>(get: { model.branch(app) }, set: { model.setBranch(app.name, $0) })
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Keep \(app.name)", isOn: keep).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name).font(.body.weight(.medium))
                    Tag(text: RepoAccess.label(app.access), color: app.access == "public" ? .green : app.access == "unknown" ? .secondary : .orange)
                }
                Text(app.exportedRepo).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !app.requires.isEmpty {
                    Text("requires \(app.requires.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(app.currentBranch ?? "detached").font(.caption.monospaced()).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary).accessibilityLabel("exported as")
            TextField("Branch for \(app.name)", text: branch)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(width: 130)
                .disabled(!keep.wrappedValue)
                .help(app.branchVerified ? "The repository has this branch" : "Not verified on the remote")
        }
        .opacity(keep.wrappedValue ? 1 : 0.55)
    }

    private var buttons: some View {
        HStack(alignment: .firstTextBaseline) {
            if let problem = run.problem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if run.phase == .running {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
            Button("Export…") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!run.canExport)
        }
    }

    @ViewBuilder private func done(_ result: ProfileExportResult) -> some View {
        Label("Exported \(result.apps) app\(result.apps == 1 ? "" : "s")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        LabeledContent("File") {
            HStack {
                Text(result.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Button("Show in Finder") { Workspace.reveal([result.path]) }
            }
        }
        if !result.dropped.isEmpty {
            LabeledContent("Left out", value: result.dropped.joined(separator: ", "))
        }
        GroupBox("Share an import link") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Put the file where your team can read it over https (a repository, a gist), then paste its address here. Teammates click the link and review the profile before BenchBar adds it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Hosted file", text: $hostedURL, prompt: Text(verbatim: "https://github.com/acme/profiles/blob/main/acme.toml"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onChange(of: hostedURL) { copied = false }
                    Button(copied ? "Copied" : "Copy Import Link") {
                        if let link = ProfileSourceRule.importLink(for: hostedURL) {
                            Workspace.copy(link)
                            copied = true
                        }
                    }
                    .disabled(ProfileSourceRule.importLink(for: hostedURL) == nil)
                }
            }
            .padding(4)
        }
        HStack {
            Spacer()
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [tomlType]
        panel.nameFieldStringValue = "\(run.name).toml"
        panel.message = "Save the profile to share"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await run.export(to: url.path) }
    }
}

// MARK: update

struct UpdateProfileSheet: View {
    @Bindable var run: ProfileUpdateRun
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Update \(run.name)", systemImage: "arrow.down.circle").font(.headline)
            switch run.phase {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching the source…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                FailureText(message: message)
            case .ready, .running, .done:
                if let plan = run.plan { updates(plan) }
            }
            HStack {
                if run.phase == .running { ProgressView().controlSize(.small) }
                Spacer()
                if run.phase == .done {
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                    Button("Update") { Task { await run.apply() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!run.canApply)
                }
            }
        }
        .padding(20)
        .frame(width: 580)
        .interactiveDismissDisabled(run.phase.isBusy)
        .task { if run.phase == .idle { await run.load() } }
    }

    @ViewBuilder private func updates(_ plan: ProfileUpdatePlan) -> some View {
        if run.phase == .done {
            Label("Updated", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if !plan.hasChanges {
            Label("Up to date: nothing to change.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
        ForEach(plan.updates) { update in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(update.name).font(.body.weight(.medium))
                    Tag(text: update.kind, color: .secondary)
                    if let behind = update.behind, behind > 0 {
                        Tag(text: "\(behind) commit\(behind == 1 ? "" : "s") behind", color: .orange)
                    }
                }
                if let diff = update.diff, !diff.isEmpty, run.phase != .done { ProfileDiffView(diff: diff) }
            }
        }
    }
}

// MARK: check access

struct CheckAccessSheet: View {
    @Bindable var run: ProfileCheckRun
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Access to \(run.name)'s repositories", systemImage: "key").font(.headline)
            switch run.phase {
            case .idle, .loading, .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Trying each repository with your git credentials…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                FailureText(message: message)
            case .ready, .done:
                if let check = run.check {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(check.repos) { RepoCheckRow(app: $0.app, repo: $0.repo, check: $0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: RepoCheckRow.listHeight(check.repos.count, reasons: check.repos.filter { $0.reachable != true }.count, limit: 280))
                    if !check.skippedApps.isEmpty {
                        Text("A bench set up from this profile now would skip: \(check.skippedApps.joined(separator: ", ")). Ask the repository owner for access, then check again.")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Button("Check Again") { Task { await run.load() } }.disabled(run.phase.isBusy)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { if run.phase == .idle { await run.load() } }
    }
}
