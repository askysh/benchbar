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
        HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
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
        case false?: return String(localized: "not reachable")
        case nil: return String(localized: "not checked")
        }
    }
}

/// A unified diff, monospaced and selectable. A code-like block, so it
/// keeps its own bounded scroll view inside a sheet.
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
        // a short diff sits top left, not centred in the box
        .defaultScrollAnchor(.topLeading)
        .frame(minHeight: 60, maxHeight: 180)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius))
    }
}

// MARK: import

struct ImportProfileSheet: View {
    @Bindable var run: ProfileImportRun
    /// Review on appear: the user picked or dropped the file themselves.
    var autoReview = false
    let close: () -> Void

    var body: some View {
        SheetScaffold(String(localized: "Import a Profile"),
                      explanation: String(localized: "Adds a profile from a .toml file or an https link, after you review it."),
                      phase: phase, width: .wide) {
            if run.phase != .done {
                form
                if let plan = run.plan { review(plan) }
                SheetNote(String(localized: "BenchBar reads the file, checks that it parses and whether this Mac can reach each repository, and shows it before anything is saved. Nothing is installed from here."))
            }
        } leading: {
            if run.phase == .done, let result = run.result {
                Button("Show in Finder") { Workspace.reveal([result.path]) }
            } else {
                Button("Review") { Task { await run.review() } }
                    .disabled(!run.canReview)
            }
        } actions: {
            if run.phase == .done {
                DoneButton(action: close)
            } else {
                CancelButton(action: close)
                    .disabled(run.phase == .running)
                Button(run.plan?.exists == true ? String(localized: "Replace Profile") : String(localized: "Add Profile")) { Task { await run.add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!run.canAdd)
            }
        }
        .task { if autoReview { await run.review() } }
    }

    private var phase: SheetPhase {
        run.phase.sheetPhase(loading: String(localized: "Reading the profile and checking its repositories…"),
                             running: String(localized: "Adding the profile…"),
                             done: run.result.map { SheetResult.success(String(localized: "Added \($0.name)"), String(localized: "Set up a bench from it with benchbar install --profile \($0.name).")) },
                             failedTitle: String(localized: "The profile was not imported"))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
            HStack(spacing: WindowMetrics.rowSpacing) {
                TextField("File or https URL", text: $run.source, prompt: Text(verbatim: "https://github.com/acme/profiles/blob/main/acme.toml"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Choose File…") { choose() }
            }
            if !run.trimmedSource.isEmpty && !run.sourceValid {
                Text("Use a .toml file on this Mac or an https URL.").font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: WindowMetrics.rowSpacing) {
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

    @ViewBuilder private func review(_ plan: ProfileImportPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                LabeledContent("Profile", value: plan.name)
                if let base = plan.base { LabeledContent("Based on", value: base) }
                LabeledContent("From") { Text(plan.source).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                Divider()
                ForEach(plan.apps) { app in
                    RepoCheckRow(app: app.name + (app.branch.map { " @ \($0)" } ?? ""), repo: app.repo, check: plan.check(for: app.name))
                }
                if !plan.skippedApps.isEmpty {
                    Text("Left out when a bench is set up from it, because this Mac cannot read their repository or they require an app that is left out: \(plan.skippedApps.joined(separator: ", ")).")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        if plan.exists {
            Text("A profile named \(plan.name) exists. Adding this one replaces it:").font(.callout)
            ProfileDiffView(diff: plan.diff ?? "(no difference)")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [tomlType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a BenchBar profile (.toml)")
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
        SheetScaffold(String(localized: "Subscribe to a Team's Profiles"),
                      explanation: String(localized: "Adds the profiles in a team's git repository to this Mac."),
                      phase: phase) {
            if run.phase != .done {
                TextField("Git repository", text: $run.repo, prompt: Text(verbatim: "git@github.com:acme/benchbar-profiles.git"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if !run.trimmedRepo.isEmpty && !ProfileSourceRule.isGitURL(run.trimmedRepo) {
                    Text("Use an https, ssh or git@host:owner/repo URL.").font(.caption).foregroundStyle(.red)
                }
                SheetNote(String(localized: "BenchBar clones the repository into ~/.config/benchbar/sources with your own git credentials and reads only its .toml files; no code from it runs. It never updates on its own: the list shows when it is behind, and Update shows the changes first."))
            }
        } leading: {
            if run.phase == .done, let result = run.result {
                Button("Show in Finder") { Workspace.reveal([result.dir]) }
            }
        } actions: {
            if run.phase == .done {
                DoneButton(action: close)
            } else {
                CancelButton(action: close)
                    .disabled(run.phase == .running)
                Button("Subscribe") { Task { await run.subscribe() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!run.canSubscribe)
            }
        }
    }

    private var phase: SheetPhase {
        run.phase.sheetPhase(loading: String(localized: "Cloning…"), running: String(localized: "Cloning…"),
                             done: run.result.map { Self.result($0) },
                             failedTitle: String(localized: "The repository was not added"))
    }

    private static func result(_ result: ProfileSubscribeResult) -> SheetResult {
        .success(String(localized: "Subscribed to \(ProfileInfo.shortRepo(result.repo))"),
                 result.profiles.isEmpty ? String(localized: "The repository has no profile yet.") : String(localized: "Profiles: \(result.profiles.joined(separator: ", "))."))
    }
}

// MARK: export

struct ExportProfileSheet: View {
    @Bindable var run: ProfileExportRun
    let close: () -> Void
    @State private var hostedURL = ""
    @State private var copied = false

    var body: some View {
        SheetScaffold(String(localized: "Export \(run.name)"),
                      explanation: String(localized: "Writes a profile file your team can import, with the branch each app is shared on."),
                      phase: phase, width: .wide) {
            switch run.phase {
            case .ready, .running:
                if let plan = run.plan { review(plan) }
            case .done:
                if let result = run.result { done(result) }
            case .idle, .loading, .failed:
                EmptyView()
            }
        } leading: {
            if run.phase == .done, let result = run.result {
                Button("Show in Finder") { Workspace.reveal([result.path]) }
            }
        } actions: {
            switch run.phase {
            case .done:
                DoneButton(action: close)
            case .failed:
                DoneButton(title: String(localized: "Close"), action: close)
            case .idle, .loading, .ready, .running:
                CancelButton(action: close)
                    .disabled(run.phase == .running)
                Button("Export…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!run.canExport)
            }
        }
        .task { if run.phase == .idle { await run.load() } }
    }

    private var phase: SheetPhase {
        run.phase.sheetPhase(idle: .loading(String(localized: "Asking each repository for its default branch and access…")),
                             loading: String(localized: "Asking each repository for its default branch and access…"),
                             running: String(localized: "Exporting…"),
                             done: run.result.map { SheetResult.success(Wording.exportedApps($0.apps), $0.path) },
                             failedTitle: String(localized: "\(run.name) was not exported"))
    }

    @ViewBuilder private func review(_ plan: ProfileExportPlan) -> some View {
        Text("Pick the branch each teammate gets, and which apps go into the file.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let problem = run.problem {
            Label(problem, systemImage: "exclamationmark.circle.fill")
                .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: WindowMetrics.spacing) {
            ForEach(plan.apps) { app in row(app) }
        }
        ForEach(plan.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
        SheetNote(String(localized: "Repository addresses are written without your SSH host aliases or any login."))
    }

    private func row(_ app: ProfileExportPlan.App) -> some View {
        let model: ProfileExportRun = run
        let keep = Binding<Bool>(get: { model.choices.keeps(app.name) }, set: { model.setKeep(app.name, $0) })
        let branch = Binding<String>(get: { model.branch(app) }, set: { model.setBranch(app.name, $0) })
        return HStack(alignment: .firstTextBaseline, spacing: WindowMetrics.rowSpacing) {
            Toggle("Keep \(app.name)", isOn: keep).labelsHidden().toggleStyle(.checkbox)
                .help("Put \(app.name) in the file")
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
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
            Text(app.currentBranch ?? String(localized: "detached")).font(.caption.monospaced()).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary).accessibilityLabel("exported as")
            TextField("Branch for \(app.name)", text: branch)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(width: 130)
                .disabled(!keep.wrappedValue)
                .help(app.branchVerified ? String(localized: "The repository has this branch") : String(localized: "Not verified on the remote"))
        }
        .opacity(keep.wrappedValue ? 1 : 0.55)
    }

    @ViewBuilder private func done(_ result: ProfileExportResult) -> some View {
        if !result.dropped.isEmpty {
            LabeledContent("Left out", value: result.dropped.joined(separator: ", "))
        }
        GroupBox("Share an import link") {
            VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                Text("Put the file where your team can read it over https (a repository, a gist), then paste its address here. Teammates click the link and review the profile before BenchBar adds it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: WindowMetrics.rowSpacing) {
                    TextField("Hosted file", text: $hostedURL, prompt: Text(verbatim: "https://github.com/acme/profiles/blob/main/acme.toml"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onChange(of: hostedURL) { copied = false }
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy Import Link")) {
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
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [tomlType]
        panel.nameFieldStringValue = "\(run.name).toml"
        panel.message = String(localized: "Save the profile to share")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await run.export(to: url.path) }
    }
}

// MARK: update

struct UpdateProfileSheet: View {
    @Bindable var run: ProfileUpdateRun
    let close: () -> Void

    var body: some View {
        SheetScaffold(String(localized: "Update \(run.name)"),
                      explanation: String(localized: "Shows what changed in the profile's source, then applies it."),
                      phase: phase, width: .wide) {
            switch run.phase {
            case .ready, .running, .done:
                if let plan = run.plan { updates(plan) }
            case .idle, .loading, .failed:
                EmptyView()
            }
        } actions: {
            switch phase {
            case .done:
                DoneButton(action: close)
            case .failed:
                DoneButton(title: String(localized: "Close"), action: close)
            case .loading, .ready, .running:
                CancelButton(action: close)
                    .disabled(run.phase == .running)
                Button("Update") { Task { await run.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!run.canApply)
            }
        }
        .task { if run.phase == .idle { await run.load() } }
    }

    /// A plan without changes leaves nothing to confirm: it reads as done.
    private var phase: SheetPhase {
        if run.phase == .ready, let plan = run.plan, !plan.hasChanges {
            return .done(.success(String(localized: "\(run.name) is up to date"), String(localized: "Nothing to change.")))
        }
        return run.phase.sheetPhase(idle: .loading(String(localized: "Fetching the source…")),
                                    loading: String(localized: "Fetching the source…"),
                                    running: String(localized: "Updating…"),
                                    done: .success(String(localized: "Updated \(run.name)")),
                                    failedTitle: String(localized: "\(run.name) was not updated"))
    }

    @ViewBuilder private func updates(_ plan: ProfileUpdatePlan) -> some View {
        ForEach(plan.updates) { update in
            VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                HStack(spacing: 6) {
                    Text(update.name).font(.body.weight(.medium))
                    Tag(text: update.kind, color: .secondary)
                    if let behind = update.behind, behind > 0 {
                        Tag(text: Wording.commitsBehind(behind), color: .orange)
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
        SheetScaffold(String(localized: "Check Access to \(run.name)"),
                      explanation: String(localized: "Tries each repository of the profile with your git credentials."),
                      phase: phase) {
            if run.phase == .done, let check = run.check {
                VStack(alignment: .leading, spacing: WindowMetrics.rowSpacing) {
                    ForEach(check.repos) { RepoCheckRow(app: $0.app, repo: $0.repo, check: $0) }
                }
            }
        } leading: {
            Button("Check Again") { Task { await run.load() } }.disabled(run.phase.isBusy)
        } actions: {
            DoneButton(action: close)
        }
        .task { if run.phase == .idle { await run.load() } }
    }

    private var phase: SheetPhase {
        let checking = String(localized: "Trying each repository with your git credentials…")
        return run.phase.sheetPhase(idle: .loading(checking), loading: checking, running: checking,
                                    done: run.check.map { Self.result($0) },
                                    failedTitle: String(localized: "Access was not checked"))
    }

    /// Every repository reachable, or how many are not and what a bench would skip.
    private static func result(_ check: ProfileCheck) -> SheetResult {
        let missing = check.repos.filter { $0.reachable != true }.count
        guard missing > 0 || !check.skippedApps.isEmpty else {
            return .success(String(localized: "This Mac can reach every repository"))
        }
        let title = missing == 0 ? String(localized: "Some apps would be left out")
            : Wording.repositoriesNotReachable(missing)
        let detail = check.skippedApps.isEmpty ? String(localized: "Ask the repository owner for access, then check again.")
            : String(localized: "A bench set up from this profile now would skip: \(check.skippedApps.joined(separator: ", ")). Ask the repository owner for access, then check again.")
        return .warning(title, detail)
    }
}
